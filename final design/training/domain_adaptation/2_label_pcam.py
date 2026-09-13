# =============================================================================
# label_pcam.py - PCAM 캡처 자동 라벨링 (YOLO_12.py 방식)
#
# 폴더 규칙:
#   - 단일 정수 폴더 (1,2,3,4 ...)        -> 배경 (사람 없음, label=0)
#   - '-' 붙은 폴더 (1-1,3-2,4-1 ...)     -> 사람 있음 (label=1, YOLO grid 생성)
#   * 파일명 cap_000.png 가 폴더마다 겹치므로 출력에 폴더명 prefix 로 충돌 방지
#
# 철학: "신뢰 못 할 라벨"은 만들지 않는다. YOLO가 확신 있게 못 잡은 사람 이미지는
#       자동 라벨하지 않고 review/ 로 보내, 사람이 (수동 라벨 / 폐기) 판단하게 한다.
#       못 잡은 이미지를 전부 버리면 어려운 케이스가 빠져 selection bias 가 생기므로,
#       폐기 여부는 review 를 보고 사람이 결정.
#
# --escalate 단계 (미검출 회복 강도):
#   off        : 1차 conf 만 (가장 보수적, 오라벨 위험 최소)
#   safe(기본) : 1차 + 완만한 2차(conf 약간↓, imgsz 640). 위치 신뢰 비교적 유지
#   aggressive : 저conf+TTA+큰 imgsz+fallback 까지 총동원 (recall 최대, 오라벨 위험↑)
#
# 입력:  pcam_raw/<폴더>/*.png (256x256 gray)
# 출력:  bnn_dataset/7/images,labels,visuals,review
#
# 사용법:
#   python label_pcam.py --raw E:/final/pcam_raw --fresh
#   python label_pcam.py --raw E:/final/pcam_raw --escalate off        # 확실한 것만
#   python label_pcam.py --raw E:/final/pcam_raw --escalate aggressive # 최대 회복
# =============================================================================
import argparse, os, re, shutil
import numpy as np
import cv2
from ultralytics import YOLO

def classify_folder(name):
    if re.fullmatch(r"\d+", name):
        return "bg"
    if "-" in name and re.fullmatch(r"[\d\-]+", name):
        return "person"
    return None

def person_boxes(results):
    out = []
    for r in results:
        for b in r.boxes:
            if int(b.cls) == 0:
                out.append(b)
    return out

def build_passes(model, fallback, base_conf, level):
    p0 = [dict(model=model, conf=base_conf, imgsz=512, augment=False)]
    if level == "off":
        return p0
    if level == "safe":
        return p0 + [dict(model=model, conf=max(0.25, base_conf*0.7), imgsz=640, augment=False)]
    # aggressive
    passes = p0 + [
        dict(model=model, conf=max(0.15, base_conf*0.5), imgsz=640,  augment=False),
        dict(model=model, conf=0.10, imgsz=960,  augment=True),
        dict(model=model, conf=0.08, imgsz=1280, augment=True),
    ]
    if fallback is not None:
        passes += [
            dict(model=fallback, conf=0.15, imgsz=960,  augment=True),
            dict(model=fallback, conf=0.08, imgsz=1280, augment=True),
        ]
    return passes

def detect(passes, img_bgr):
    for i, p in enumerate(passes):
        p = dict(p); mdl = p.pop("model")
        boxes = person_boxes(mdl(img_bgr, verbose=False, **p))
        if boxes:
            return boxes, i
    return [], -1

def main():
    BASE = "E:/final"
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=f"{BASE}/pcam_raw")
    ap.add_argument("--dataset", default=f"{BASE}/bnn_dataset")
    ap.add_argument("--folder", default="7")
    ap.add_argument("--conf", type=float, default=0.35)
    ap.add_argument("--conf_map", default="", help='폴더별 1차 conf 예: "3-1:0.3"')
    ap.add_argument("--escalate", choices=["off", "safe", "aggressive"], default="safe")
    ap.add_argument("--yolo", default=f"{BASE}/training code/yolov8x.pt", help="없으면 자동 다운로드")
    ap.add_argument("--yolo_fallback", default="", help="aggressive 시 추가 모델(선택)")
    ap.add_argument("--fresh", action="store_true")
    args = ap.parse_args()

    conf_map = {}
    for kv in args.conf_map.split(","):
        if ":" in kv:
            k, v = kv.split(":"); conf_map[k.strip()] = float(v)

    model = YOLO(args.yolo)
    fallback = YOLO(args.yolo_fallback) if args.yolo_fallback else None

    out_base   = os.path.join(args.dataset, args.folder)
    img_dir    = os.path.join(out_base, "images")
    label_dir  = os.path.join(out_base, "labels")
    visual_dir = os.path.join(out_base, "visuals")
    review_dir = os.path.join(out_base, "review")
    if args.fresh:
        for d in [img_dir, label_dir, visual_dir, review_dir]:
            if os.path.exists(d): shutil.rmtree(d)
        print("[fresh] 출력 폴더 초기화")
    for d in [img_dir, label_dir, visual_dir, review_dir]:
        os.makedirs(d, exist_ok=True)

    print(f"escalate 단계: {args.escalate}")
    subdirs = sorted(d for d in os.listdir(args.raw) if os.path.isdir(os.path.join(args.raw, d)))
    plan = [(d, classify_folder(d)) for d in subdirs]
    print("입력 폴더 분류:")
    for d, kind in plan:
        print(f"  {d:>6} -> {kind if kind else '무시'}")
    print()

    total_bg, total_person, no_det = 0, 0, 0
    summary = []

    for folder, kind in plan:
        if kind is None:
            continue
        in_dir = os.path.join(args.raw, folder)
        files = sorted(f for f in os.listdir(in_dir) if f.lower().endswith((".png", ".jpg", ".jpeg")))
        saved, missed, escalated = 0, 0, 0
        label_type = "0" if kind == "bg" else "1"
        base_conf = conf_map.get(folder, args.conf)
        passes = build_passes(model, fallback, base_conf, args.escalate)

        for f in files:
            img = cv2.imread(os.path.join(in_dir, f), 0)
            if img is None:
                continue
            img_256 = cv2.resize(img, (256, 256)) if img.shape != (256, 256) else img
            img_512 = cv2.resize(img_256, (512, 512))
            img_512_bgr = cv2.cvtColor(img_512, cv2.COLOR_GRAY2BGR)
            img_vis = img_512_bgr.copy()

            base_name = os.path.splitext(f)[0]
            save_name = f"L{label_type}_pcam_{folder}__{base_name}"
            grid_label = np.zeros((16, 16), dtype=np.float32)

            if kind == "person":
                boxes, pidx = detect(passes, img_512_bgr)
                if not boxes:
                    no_det += 1; missed += 1
                    cv2.imwrite(os.path.join(review_dir, f"{save_name}.png"), img_256)
                    continue
                if pidx > 0:
                    escalated += 1
                for b in boxes:
                    x1, y1, x2, y2 = b.xyxy[0].cpu().numpy().astype(int)
                    cv2.rectangle(img_vis, (x1, y1), (x2, y2), (0, 0, 255), 2)
                    gx1, gy1 = int(x1 / 32), int(y1 / 32)
                    gx2, gy2 = int(x2 / 32), int(y2 / 32)
                    grid_label[max(0, gy1):min(16, gy2 + 1), max(0, gx1):min(16, gx2 + 1)] = 1.0

            for gy in range(16):
                for gx in range(16):
                    if grid_label[gy, gx] > 0.5:
                        overlay = img_vis.copy()
                        cv2.rectangle(overlay, (gx*32, gy*32), (gx*32+32, gy*32+32), (0, 255, 0), -1)
                        cv2.addWeighted(overlay, 0.3, img_vis, 0.7, 0, img_vis)
            for i in range(1, 16):
                cv2.line(img_vis, (i*32, 0), (i*32, 512), (100, 100, 100), 1)
                cv2.line(img_vis, (0, i*32), (512, i*32), (100, 100, 100), 1)

            cv2.imwrite(os.path.join(img_dir, f"{save_name}.png"), img_256)
            np.save(os.path.join(label_dir, f"{save_name}.npy"), grid_label)
            cv2.imwrite(os.path.join(visual_dir, f"vis_{save_name}.jpg"), img_vis)
            saved += 1
            if kind == "bg": total_bg += 1
            else:            total_person += 1

        summary.append((folder, kind, saved, missed, escalated))
        extra = f", review {missed}, 격상회복 {escalated}" if kind == "person" else ""
        print(f"  [{folder}] {kind}: 라벨 {saved}{extra}")

    print(f"\n[완료] 배경 {total_bg} + 사람 {total_person} = {total_bg+total_person}장 -> {out_base}")
    print(f"       미검출(review로 보냄) {no_det}장 -> {review_dir}")
    print("\n폴더별 요약:")
    for folder, kind, saved, missed, escalated in summary:
        if kind == "person":
            tot = saved + missed
            rate = (missed / tot * 100) if tot else 0
            print(f"  {folder:>6}: 사람 {saved}/{tot} (review {rate:.0f}%, 격상회복 {escalated})")
        else:
            print(f"  {folder:>6}: 배경 {saved}")
    print("\nreview/ 의 미검출 = 어려운 케이스. 보고 (수동 라벨 / 폐기) 판단.")
    print("자동 라벨도 visuals/ 로 오라벨 검수(특히 격상회복 건).")

if __name__ == "__main__":
    main()
