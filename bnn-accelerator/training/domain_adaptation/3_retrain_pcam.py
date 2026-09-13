# =============================================================================
# retrain_pcam.py — 기존 데이터 + PCAM 혼합 fine-tune (domain adaptation)
#
# 전략 (prompt_retrain.md 단계 3):
#   - final_res_bnn_ema.pth 에서 시작 (89.67% 모델 보존)
#   - 기존 폴더 1~6 + PCAM 폴더 7 혼합, 배치 내 PCAM 비율 ≈ 30% (oversampling)
#   - photometric augmentation (밝기/대비/감마) 추가
#     → 기존 sRGB 데이터와 PCAM 리니어 데이터 간 분포 차이에 강건하게
#   - 낮은 LR + EMA로 기존 정확도 붕괴 방지
#   - 검증은 기존(OLD) / PCAM 분리 측정 → 둘 다 모니터링
#
# 사용법 (인자 없이 실행하면 E:\final 레이아웃 기준):
#   python retrain_pcam.py
#
# 출력:
#   final_res_bnn_pcam.pth  (best EMA 가중치 → 4_export/export_weights_hls.py 입력)
# =============================================================================
import os, re, random, argparse
import numpy as np
import cv2
import torch, torch.nn as nn, torch.optim as optim
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler

# ---------------------------------------------------------
# 1. 모델 (v2_final_bnn_256_gray.py 와 100% 동일 구조)
# ---------------------------------------------------------
class BinarizeSTE(torch.autograd.Function):
    @staticmethod
    def forward(ctx, input):
        ctx.save_for_backward(input)
        return torch.where(input >= 0, torch.tensor(1.0).to(input.device), torch.tensor(-1.0).to(input.device))
    @staticmethod
    def backward(ctx, grad_output):
        input, = ctx.saved_tensors
        grad_input = grad_output.clone()
        grad_input[input.abs() > 1.0] = 0
        return grad_input

def binarize(x): return BinarizeSTE.apply(x)

class BinaryConv2d(nn.Conv2d):
    def forward(self, input):
        w = self.weight
        scaling_factor = torch.mean(torch.abs(w), dim=[1, 2, 3], keepdim=True)
        bw = binarize(w) * scaling_factor
        return nn.functional.conv2d(input, bw, self.bias, self.stride, self.padding)

class HardwareResBNN_v6(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 32, kernel_size=7, stride=2, padding=3, bias=False)
        self.bn1 = nn.BatchNorm2d(32)
        self.bconv1 = BinaryConv2d(32, 64, 3, padding=1, bias=False)
        self.bn2 = nn.BatchNorm2d(64)
        self.shortcut1 = nn.Conv2d(32, 64, 1, stride=1, bias=False)
        self.bconv2 = BinaryConv2d(64, 128, 3, padding=1, bias=False)
        self.bn3 = nn.BatchNorm2d(128)
        self.shortcut2 = nn.Conv2d(64, 128, 1, stride=1, bias=False)
        self.bconv3 = BinaryConv2d(128, 256, 3, padding=1, bias=False)
        self.bn4 = nn.BatchNorm2d(256)
        self.shortcut3 = nn.Conv2d(128, 256, 1, stride=1, bias=False)
        self.pool = nn.MaxPool2d(2)
        self.relu = nn.ReLU(inplace=True)
        self.head = nn.Conv2d(256, 1, kernel_size=1)

    def forward(self, x):
        x = self.relu(self.bn1(self.conv1(x)))
        res = self.shortcut1(x); x = binarize(self.bn2(self.bconv1(x)) + res); x = self.pool(x)
        res = self.shortcut2(x); x = binarize(self.bn3(self.bconv2(x)) + res); x = self.pool(x)
        res = self.shortcut3(x); x = binarize(self.bn4(self.bconv3(x)) + res); x = self.pool(x)
        return self.head(x)

# ---------------------------------------------------------
# 2. EMA
# ---------------------------------------------------------
class ExponentialMovingAverage:
    def __init__(self, model, decay=0.99):
        self.model, self.decay = model, decay
        self.shadow = {n: p.data.clone() for n, p in model.named_parameters() if p.requires_grad}
    def update(self):
        for n, p in self.model.named_parameters():
            if p.requires_grad:
                self.shadow[n] = (1.0 - self.decay) * p.data + self.decay * self.shadow[n]
    def apply_to_model(self):
        for n, p in self.model.named_parameters():
            if p.requires_grad: p.data.copy_(self.shadow[n])

# ---------------------------------------------------------
# 3. 데이터
# ---------------------------------------------------------
def natural_sort_key(s): return [int(t) if t.isdigit() else t.lower() for t in re.split('([0-9]+)', s)]

def collect_samples(dataset_root, folders, is_pcam=False):
    """기존 코드(get_optimized_samples)와 동일 필터링. PCAM 폴더는 필터 없이 전량 사용."""
    samples = []
    for folder in folders:
        img_dir = os.path.join(dataset_root, folder, "images")
        lbl_dir = os.path.join(dataset_root, folder, "labels")
        if not os.path.exists(img_dir): continue
        img_files = sorted([f for f in os.listdir(img_dir) if f.lower().endswith('.png')], key=natural_sort_key)
        for i, f in enumerate(img_files):
            lbl_path = os.path.join(lbl_dir, os.path.splitext(f)[0] + ".npy")
            if not os.path.exists(lbl_path): continue
            is_p = 1 if np.max(np.load(lbl_path)) > 0.5 else 0
            # 기존 코드의 1~4번 폴더 사람 이미지 1/5 샘플링 유지
            if (not is_pcam) and folder in ['1', '2', '3', '4'] and is_p == 1 and i % 5 != 0: continue
            samples.append({'img': os.path.join(img_dir, f), 'lbl': lbl_path, 'cls': is_p, 'pcam': is_pcam})
    return samples

def split_8020(samples, seed=42):
    random.seed(seed); random.shuffle(samples)
    k = int(len(samples) * 0.8)
    return samples[:k], samples[k:]

class MixedDataset(Dataset):
    """photometric augmentation 포함. 정규화는 기존과 동일: (x/255 - 0.5)/0.5"""
    def __init__(self, samples, train=False):
        self.samples, self.train = samples, train
    def __len__(self): return len(self.samples)

    def _augment(self, img):  # img: uint8 (256,256) → (img, flipped)
        # 좌우 반전 (주의: 기존 v2 코드는 라벨을 안 뒤집는 버그가 있었음 — 여기서 교정)
        flipped = random.random() < 0.5
        if flipped:
            img = img[:, ::-1].copy()
        x = img.astype(np.float32)
        # 밝기/대비 jitter
        alpha = random.uniform(0.7, 1.3)            # 대비
        beta  = random.uniform(-30, 30)             # 밝기
        x = x * alpha + beta
        # 감마 jitter — sRGB(기존)↔linear(PCAM) gap을 메우는 핵심
        g = random.uniform(0.55, 1.8)
        x = np.clip(x, 0, 255) / 255.0
        x = np.power(x, g) * 255.0
        # 약한 가우시안 노이즈 (RAW 센서 노이즈 모사)
        if random.random() < 0.3:
            x = x + np.random.normal(0, random.uniform(1, 5), x.shape)
        return np.clip(x, 0, 255).astype(np.uint8), flipped

    def __getitem__(self, idx):
        s = self.samples[idx]
        img = cv2.imread(s['img'], 0)
        if img.shape != (256, 256): img = cv2.resize(img, (256, 256))
        flipped = False
        if self.train: img, flipped = self._augment(img)
        lbl = np.load(s['lbl']).reshape(16, 16).astype(np.float32)
        if flipped: lbl = lbl[:, ::-1].copy()
        t = torch.from_numpy(img.astype(np.float32) / 255.0).unsqueeze(0)
        t = (t - 0.5) / 0.5
        return t, torch.from_numpy(lbl).unsqueeze(0), s['cls'], int(s['pcam'])

# ---------------------------------------------------------
# 4. 검증 (기존 프로토콜: max>0.8 + 3×3 tolerance)
# ---------------------------------------------------------
@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    res = {0: [0, 0], 1: [0, 0]}  # pcam플래그 → [match, total]
    for iv, lv, cv, pv in loader:
        out = torch.sigmoid(model(iv.to(device))).squeeze().cpu().numpy()
        gt = lv.squeeze().numpy()
        ok = False
        if np.max(out) > 0.8 and cv.item() == 1:
            y, x = np.unravel_index(np.argmax(out), out.shape)
            ok = bool(np.any(gt[max(0, y-1):min(16, y+2), max(0, x-1):min(16, x+2)] > 0.5))
        elif np.max(out) <= 0.8 and cv.item() == 0:
            ok = True
        key = pv.item()
        res[key][1] += 1
        if ok: res[key][0] += 1
    acc = {}
    for k in (0, 1):
        acc[k] = res[k][0] / res[k][1] * 100 if res[k][1] else float('nan')
    return acc  # {0: 기존 acc, 1: PCAM acc}

# ---------------------------------------------------------
# 5. 학습
# ---------------------------------------------------------
def main():
    BASE = "E:/final"
    ap = argparse.ArgumentParser()
    # 기본 데이터셋 = 해상도 matching된 열화본(휴대폰 PCAM화 + 폴더7 실 PCAM)
    ap.add_argument("--dataset", default=f"{BASE}/bnn_dataset")
    ap.add_argument("--pcam_folder", default="7")
    ap.add_argument("--init", default=f"{BASE}/training code/final_res_bnn_ema.pth")
    ap.add_argument("--out", default=f"{BASE}/training code/final_res_bnn_pcam.pth")
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--lr", type=float, default=2e-5)
    # 실 PCAM이 적으므로 과적합 방지 위해 비율 낮춤(0.2). 데이터 늘면 0.3까지 상향 가능
    ap.add_argument("--pcam_ratio", type=float, default=0.2, help="배치 내 실 PCAM(폴더7) 비율")
    args = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    old_s  = collect_samples(args.dataset, ['1','2','3','4','5','6'], is_pcam=False)
    pcam_s = collect_samples(args.dataset, [args.pcam_folder], is_pcam=True)
    if not pcam_s:
        print(f"[ERROR] PCAM 폴더({args.dataset}/{args.pcam_folder})에 샘플 없음. 2_label 먼저 실행."); return
    old_tr, old_va   = split_8020(old_s)
    pcam_tr, pcam_va = split_8020(pcam_s)
    print(f"기존: train {len(old_tr)} / val {len(old_va)}")
    print(f"PCAM: train {len(pcam_tr)} / val {len(pcam_va)}")

    train_ds = MixedDataset(old_tr + pcam_tr, train=True)
    val_ds   = MixedDataset(old_va + pcam_va, train=False)

    # 샘플링 가중치: (a) 클래스 균형 × (b) PCAM 비율 30% 맞춤
    tr = old_tr + pcam_tr
    n_old, n_pcam = len(old_tr), len(pcam_tr)
    w_pcam = args.pcam_ratio / max(n_pcam, 1)
    w_old  = (1 - args.pcam_ratio) / max(n_old, 1)
    cls_cnt = {0: sum(1 for s in tr if s['cls'] == 0), 1: sum(1 for s in tr if s['cls'] == 1)}
    weights = [(w_pcam if s['pcam'] else w_old) / cls_cnt[s['cls']] for s in tr]
    loader = DataLoader(train_ds, batch_size=32,
                        sampler=WeightedRandomSampler(weights, len(weights)), num_workers=2)
    v_loader = DataLoader(val_ds, batch_size=1, shuffle=False)

    model = HardwareResBNN_v6().to(device)
    if os.path.exists(args.init):
        model.load_state_dict(torch.load(args.init, map_location=device))
        print(f">>> {args.init} 로드 — fine-tune 시작")
    else:
        print(f"[WARN] {args.init} 없음 — 처음부터 학습 (비권장)")

    ema = ExponentialMovingAverage(model, decay=0.99)
    optimizer = optim.Adam(model.parameters(), lr=args.lr)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    criterion = nn.BCEWithLogitsLoss()

    # 시작점 성능 기록
    acc0 = evaluate(model, v_loader, device)
    print(f"[시작점] 기존 val: {acc0[0]:.2f}%  PCAM val: {acc0[1]:.2f}%")
    best_score = -1.0

    for epoch in range(args.epochs):
        model.train(); total_loss = 0
        for imgs, labels, _, _ in loader:
            imgs, labels = imgs.to(device), labels.to(device)
            optimizer.zero_grad()
            loss = criterion(model(imgs), labels)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 0.1)
            optimizer.step()
            ema.update()
            total_loss += loss.item()
        scheduler.step()

        # EMA 가중치로 검증
        orig = {n: p.data.clone() for n, p in model.named_parameters()}
        ema.apply_to_model()
        acc = evaluate(model, v_loader, device)
        # score: 기존 정확도 사수 + PCAM 개선 (기존에 더 큰 가중치)
        score = 0.6 * acc[0] + 0.4 * acc[1]
        print(f"Epoch [{epoch+1}/{args.epochs}] Loss: {total_loss/len(loader):.4f} | "
              f"기존: {acc[0]:.2f}%  PCAM: {acc[1]:.2f}%  score: {score:.2f}")
        if score > best_score:
            best_score = score
            torch.save(model.state_dict(), args.out)
            print(f"  --> [Best] 저장: {args.out}")
        for n, p in model.named_parameters(): p.data.copy_(orig[n])

    print(f"\n>>> 완료. best score {best_score:.2f} → {args.out}")
    print(">>> 다음: 4_export/export_weights_hls.py 로 weights_hls.h 생성")

if __name__ == "__main__":
    main()
