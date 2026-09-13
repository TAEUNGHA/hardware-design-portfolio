import os, cv2, re, numpy as np, torch, torch.nn as nn, torch.optim as optim
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
import torchvision.transforms as T
from PIL import Image
import random

# 1. BNN 커스텀 레이어 (STE)
class BinarizeSTE(torch.autograd.Function):
    @staticmethod
    def forward(ctx, input):
        ctx.save_for_backward(input)
        return torch.where(input >= 0, torch.tensor(1.0).to(input.device), torch.tensor(-1.0).to(input.device))
    @staticmethod
    def backward(ctx, grad_output):
        input, = ctx.saved_tensors
        grad_input = grad_output.clone()
        grad_input[input.abs() > 1.2] = 0 # 범위를 살짝 넓혀 유연성 부여
        return grad_input

def binarize(x): return BinarizeSTE.apply(x)

class BinaryConv2d(nn.Conv2d):
    def forward(self, input):
        w = self.weight
        # 가중치 스케일링 (학습 안정화 핵심)
        scaling_factor = torch.mean(torch.abs(w), dim=[1, 2, 3], keepdim=True)
        bw = binarize(w) * scaling_factor
        return nn.functional.conv2d(input, bw, self.bias, self.stride, self.padding)

# 2. 잔차 연결(Shortcut)이 포함된 하드웨어 규격 모델
class HardwareResBNN_v6(nn.Module):
    def __init__(self):
        super(HardwareResBNN_v6, self).__init__()
        # L1: Real-valued CNN (입력층)
        self.conv1 = nn.Conv2d(1, 32, kernel_size=7, stride=2, padding=3, bias=False)
        self.bn1 = nn.BatchNorm2d(32)
        
        # BNN Layers with Shortcuts
        # L2: 32 -> 64
        self.bconv1 = BinaryConv2d(32, 64, 3, padding=1, bias=False)
        self.bn2 = nn.BatchNorm2d(64)
        self.shortcut1 = nn.Conv2d(32, 64, 1, stride=1, bias=False) # 채널 맞춤용
        
        # L3: 64 -> 128
        self.bconv2 = BinaryConv2d(64, 128, 3, padding=1, bias=False)
        self.bn3 = nn.BatchNorm2d(128)
        self.shortcut2 = nn.Conv2d(64, 128, 1, stride=1, bias=False)
        
        # L4: 128 -> 256
        self.bconv3 = BinaryConv2d(128, 256, 3, padding=1, bias=False)
        self.bn4 = nn.BatchNorm2d(256)
        self.shortcut3 = nn.Conv2d(128, 256, 1, stride=1, bias=False)

        self.pool = nn.MaxPool2d(2)
        self.relu = nn.ReLU(inplace=True)
        self.head = nn.Conv2d(256, 1, kernel_size=1)

    def forward(self, x):
        # Layer 1
        x = self.relu(self.bn1(self.conv1(x)))
        
        # BNN Block 1
        res = self.shortcut1(x)
        x = binarize(self.bn2(self.bconv1(x)) + res)
        x = self.pool(x)
        
        # BNN Block 2
        res = self.shortcut2(x)
        x = binarize(self.bn3(self.bconv2(x)) + res)
        x = self.pool(x)
        
        # BNN Block 3
        res = self.shortcut3(x)
        x = binarize(self.bn4(self.bconv3(x)) + res)
        x = self.pool(x)
        
        x = self.head(x)
        return x # Logit 출력

# --- [데이터 로더 부분은 동일 - 생략 없이 포함] ---
def natural_sort_key(s): return [int(t) if t.isdigit() else t.lower() for t in re.split('([0-9]+)', s)]

def get_optimized_samples(dataset_root="./bnn_dataset"):
    all_samples = []
    for folder in ['1','2','3','4','5','6']:
        img_dir, lbl_dir = os.path.join(dataset_root, folder, "images"), os.path.join(dataset_root, folder, "labels")
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

# 4. 학습 루프
def train():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    train_s, val_s = get_optimized_samples()
    t_trans = T.Compose([T.RandomHorizontalFlip(), T.ToTensor(), T.Normalize((0.5,),(0.5,))])
    v_trans = T.Compose([T.ToTensor(), T.Normalize((0.5,),(0.5,))])
    train_ds, val_ds = ToleranceDataset(train_s, t_trans), ToleranceDataset(val_s, v_trans)
    
    cls_list = [s['cls'] for s in train_s]
    weights = [1.0/cls_list.count(c) for c in cls_list]
    sampler = WeightedRandomSampler(weights, len(weights))
    loader = DataLoader(train_ds, batch_size=32, sampler=sampler)
    v_loader = DataLoader(val_ds, batch_size=1, shuffle=False)

    model = HardwareResBNN_v6().to(device)
    optimizer = optim.Adam(model.parameters(), lr=0.0002) # 안정성을 위해 더 낮은 LR 사용
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=50)
    criterion = nn.BCEWithLogitsLoss()

    best_acc = 0.0
    print(f"\n>>> Res-BNN v6.0 학습 시작 (붕괴 방지용 Shortcut 적용)")

    for epoch in range(50):
        model.train(); total_loss = 0
        for imgs, labels, _ in loader:
            imgs, labels = imgs.to(device), labels.to(device)
            optimizer.zero_grad()
            loss = criterion(model(imgs), labels)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 0.1)
            optimizer.step()
            total_loss += loss.item()
        
        scheduler.step()
        
        model.eval(); match = 0
        with torch.no_grad():
            for iv, lv, cv in v_loader:
                out = torch.sigmoid(model(iv.to(device))).squeeze().cpu().numpy()
                gt = lv.squeeze().numpy()
                if np.max(out) > 0.8 and cv.item() == 1:
                    y, x = np.unravel_index(np.argmax(out), out.shape)
                    if np.any(gt[max(0,y-1):min(16,y+2), max(0,x-1):min(16,x+2)] > 0.5): match += 1
                elif np.max(out) <= 0.8 and cv.item() == 0: match += 1
        
        current_acc = (match / len(val_ds)) * 100
        print(f"Epoch [{epoch+1}/50] Loss: {total_loss/len(loader):.4f} | Acc: {current_acc:.2f}%")

        if current_acc > best_acc:
            best_acc = current_acc
            torch.save(model.state_dict(), "final_res_bnn_v6.pth")

    print(f"\n>>> 최상의 정확도: {best_acc:.2f}%")

if __name__ == "__main__":
    train()