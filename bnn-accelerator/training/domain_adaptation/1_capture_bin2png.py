# =============================================================================
# bin2png.py — XSCT 덤프(bin) → PNG 변환 + 밝기 통계
#
# 사용법 (인자 없이 실행하면 이 파일 옆 capture/ 폴더를 읽음):
#   python bin2png.py
#   python bin2png.py --tag 복도            # 시나리오 태그를 이름에 추가
#   python bin2png.py --in ./capture --out ./pcam_raw/unsorted
#
# PNG 이름 = [태그_]캡처시각_capXXX.png  (배치마다 시각이 달라 덮어써도 안 겹침)
#   예) 20260608_143012_cap000.png  또는  복도_20260608_143012_cap000.png
# 캡처시각 = 해당 bin 파일의 생성/수정 시각 (XSDB 덤프 시각 ≈ 캡처 직후)
#
# 변환 후 pcam_raw/unsorted 의 PNG를 보면서 직접 분류:
#   pcam_raw/0/  ← 사람 없는 배경
#   pcam_raw/1/  ← 사람 있는 장면
# (이후 2_label/label_pcam.py 실행)
# =============================================================================
import argparse, glob, os, datetime
import numpy as np
import cv2

def main():
    # 기본 입력 = 이 스크립트 옆 capture/ 폴더 (dump_captures.tcl 출력 위치와 동일)
    here = os.path.dirname(os.path.abspath(__file__))
    default_in = os.path.join(here, "capture")
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_dir", default=default_in)
    ap.add_argument("--out", dest="out_dir", default=os.path.join(here, "pcam_raw", "unsorted"))
    ap.add_argument("--tag", default="", help="시나리오 태그 (예: 복도, 복잡배경_사람없음)")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    files = sorted(glob.glob(os.path.join(args.in_dir, "cap_*.bin")))
    if not files:
        print(f"[ERROR] {args.in_dir} 에 cap_*.bin 없음"); return

    tag = (args.tag.strip() + "_") if args.tag.strip() else ""

    stats = []
    for fp in files:
        data = np.fromfile(fp, dtype=np.uint8)
        if data.size != 65536:
            print(f"[SKIP] {fp}: 크기 {data.size} != 65536"); continue
        img = data.reshape(256, 256)
        idx = os.path.splitext(os.path.basename(fp))[0].replace("cap_", "cap")  # cap_000 → cap000
        # 캡처 시각 = bin 파일 수정 시각 (XSDB 덤프 시점)
        ts = datetime.datetime.fromtimestamp(os.path.getmtime(fp)).strftime("%Y%m%d_%H%M%S")
        name = f"{tag}{ts}_{idx}"
        cv2.imwrite(os.path.join(args.out_dir, name + ".png"), img)
        stats.append((name, img.min(), img.max(), img.mean()))

    if not stats:
        print("[ERROR] 변환된 이미지 없음 (크기 불일치 등)"); return

    print(f"\n[변환 완료] {len(stats)}장 → {args.out_dir}")
    if tag:
        print(f"[태그] {args.tag.strip()}  (파일명 예: {stats[0][0]}.png)")
    avgs = [s[3] for s in stats]
    print(f"[밝기 통계] 전체 평균={np.mean(avgs):.1f}  min_avg={min(avgs):.1f}  max_avg={max(avgs):.1f}")
    print("(참고: 기존 학습 데이터 평균 ≈ 168 — 차이가 크면 domain gap 큼)")

    # 중복/정지 프레임 감지: 인접 프레임과 완전 동일하면 경고
    dup = 0
    prev = None
    for fp in files:
        cur = np.fromfile(fp, dtype=np.uint8)
        if prev is not None and cur.size == prev.size and np.array_equal(cur, prev):
            dup += 1
        prev = cur
    if dup:
        print(f"[주의] 인접 중복 프레임 {dup}건 — 캡처 간격 동안 VDMA 갱신이 없었을 수 있음")

if __name__ == "__main__":
    main()
