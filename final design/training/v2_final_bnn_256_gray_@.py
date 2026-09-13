import os, cv2, re, numpy as np, torch, torch.nn as nn, torch.optim as optim
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
import torchvision.transforms as T
from PIL import Image
import random

# ---------------------------------------------------------
# 1. BNN 커스텀 레이어 (하드웨어 논리 일치)
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

# ---------------------------------------------------------
# 2. 하드웨어 규격 모델 (v6 Res-BNN 구조)
# ---------------------------------------------------------
class HardwareResBNN_v6(nn.Module):
    def __init__(self):
        super(HardwareResBNN_v6, self).__init__()
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
        # Block 1
        res = self.shortcut1(x)
        x = binarize(self.bn2(self.bconv1(x)) + res)
        x = self.pool(x)
        # Block 2
        res = self.shortcut2(x)
        x = binarize(self.bn3(self.bconv2(x)) + res)
        x = self.pool(x)
        # Block 3
        res = self.shortcut3(x)
        x = binarize(self.bn4(self.bconv3(x)) + res)
        x = self.pool(x)
        return self.head(x)

# ---------------------------------------------------------
# 3. EMA 관리 클래스 (가중치 진동 억제기)
# ---------------------------------------------------------
class ExponentialMovingAverage:
    def __init__(self, model, decay=0.999):
        self.model = model
        self.decay = decay
        self.shadow = {}
        for name, param in model.named_parameters():
            if param.requires_grad:
                self.shadow[name] = param.data.clone()

    def update(self):
        for name, param in self.model.named_parameters():
            if param.requires_grad:
                new_average = (1.0 - self.decay) * param.data + self.decay * self.shadow[name]
                self.shadow[name] = new_average.clone()

    def apply_to_model(self):
        for name, param in self.model.named_parameters():
            if param.requires_grad:
                param.data.copy_(self.shadow[name])

# ---------------------------------------------------------
# 4. 데이터셋 및 학습 설정 (기존 로직 유지)
# ---------------------------------------------------------
def natural_sort_key(s): return [int(t) if t.isdigit() else t.lower() for t in re.split('([0-9]+)', s)]

def get_optimized_samples(dataset_root="./bnn_dataset"):
    all_samples = []
    for folder in ['1','2','3','4','5','6']:
        img_dir = os.path.join(dataset_root, folder, "images")
        lbl_dir = os.path.join(dataset_root, folder, "labels")
        if not os.path.exists(img_dir): continue
        img_files = sorted([f for f in os.listdir(img_dir) if f.lower().endswith('.png')], key=natural_sort_key)
        for i, f in enumerate(img_files):
            lbl_path = os.path.join(lbl_dir, os.path.splitext(f)[0] + ".npy")
            if os.path.exists(lbl_path):
                label_data = np.load(lbl_path)
                is_p = 1 if np.max(label_data) > 0.5 else 0
                if folder in ['1','2','3','4'] and is_p == 1 and i % 5 != 0: continue
                all_samples.append({'img': os.path.join(img_dir, f), 'lbl': lbl_path, 'cls': is_p})
    random.seed(42); random.shuffle(all_samples)
    split = int(len(all_samples) * 0.8)
    return all_samples[:split], all_samples[split:]

class ToleranceDataset(Dataset):
    def __init__(self, s, t=None): self.samples=s; self.transform=t
    def __len__(self): return len(self.samples)
    def __getitem__(self, idx):
        s = self.samples[idx]; img = cv2.imread(s['img'], 0)
        img_tensor = self.transform(Image.fromarray(cv2.resize(img, (256,256))))
        lbl = torch.from_numpy(np.load(s['lbl'])).unsqueeze(0).float()
        return img_tensor, lbl, s['cls']

# ---------------------------------------------------------
# 5. EMA 기반 파이널 학습 루프
# ---------------------------------------------------------
def run_ema_stabilization():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    train_s, val_s = get_optimized_samples()
    t_trans = T.Compose([T.RandomHorizontalFlip(), T.ToTensor(), T.Normalize((0.5,),(0.5,))])
    v_trans = T.Compose([T.ToTensor(), T.Normalize((0.5,),(0.5,))])
    train_ds, val_ds = ToleranceDataset(train_s, t_trans), ToleranceDataset(val_s, v_trans)
    
    loader = DataLoader(train_ds, batch_size=32, sampler=WeightedRandomSampler([1.0/2 for _ in range(len(train_ds))], len(train_ds)))
    v_loader = DataLoader(val_ds, batch_size=1, shuffle=False)

    model = HardwareResBNN_v6().to(device)
    if os.path.exists("final_res_bnn_v6.pth"):
        model.load_state_dict(torch.load("final_res_bnn_v6.pth"))
        print(">>> Model loaded. Starting EMA stabilization...")

    # EMA 초기화 (학습 중인 가중치를 아주 부드럽게 추적)
    ema = ExponentialMovingAverage(model, decay=0.99)
    optimizer = optim.Adam(model.parameters(), lr=5e-6) # 극도로 낮은 LR
    criterion = nn.BCEWithLogitsLoss()

    best_ema_acc = 0.0

    for epoch in range(20):
        model.train(); total_loss = 0
        for imgs, labels, _ in loader:
            imgs, labels = imgs.to(device), labels.to(device)
            optimizer.zero_grad()
            loss = criterion(model(imgs), labels)
            loss.backward()
            optimizer.step()
            ema.update() # 매 배치마다 평균 가중치 업데이트
            total_loss += loss.item()
        
        # [중요] 검증은 EMA 가중치로 수행
        model.eval()
        orig_weights = {n: p.data.clone() for n, p in model.named_parameters()}
        ema.apply_to_model() # 가중치를 평균값으로 일시 교체
        
        match = 0
        with torch.no_grad():
            for iv, lv, cv in v_loader:
                out = torch.sigmoid(model(iv.to(device))).squeeze().cpu().numpy()
                gt = lv.squeeze().numpy()
                if np.max(out) > 0.8 and cv.item() == 1:
                    y, x = np.unravel_index(np.argmax(out), out.shape)
                    if np.any(gt[max(0,y-1):min(16,y+2), max(0,x-1):min(16,x+2)] > 0.5): match += 1
                elif np.max(out) <= 0.8 and cv.item() == 0: match += 1
        
        ema_acc = (match / len(val_ds)) * 100
        print(f"EMA Epoch [{epoch+1}/20] Acc: {ema_acc:.2f}%")

        if ema_acc > best_ema_acc:
            best_ema_acc = ema_acc
            torch.save(model.state_dict(), "final_res_bnn_ema.pth")
            print(f"--> [EMA Best] Saved model with Acc: {best_ema_acc:.2f}%")

        # 원본 가중치로 복구하여 다음 에폭 학습 계속
        for n, p in model.named_parameters(): p.data.copy_(orig_weights[n])

    print(f"\n>>> 완료. EMA 기반 최종 정확도: {best_ema_acc:.2f}%")

if __name__ == "__main__":
    run_ema_stabilization()