import os, cv2, re, numpy as np, torch, torch.nn as nn
from torch.utils.data import DataLoader, Dataset
import torchvision.transforms as T
from PIL import Image

# [모델 정의 부분은 이전 v6.2와 동일하므로 구조 유지]
class BinarizeSTE(torch.autograd.Function):
    @staticmethod
    def forward(ctx, input):
        return torch.where(input >= 0, torch.tensor(1.0).to(input.device), torch.tensor(-1.0).to(input.device))
    @staticmethod
    def backward(ctx, grad_output):
        return grad_output

def binarize(x): return BinarizeSTE.apply(x)

class BinaryConv2d(nn.Conv2d):
    def forward(self, input):
        w = self.weight
        scaling_factor = torch.mean(torch.abs(w), dim=[1, 2, 3], keepdim=True)
        bw = binarize(w) * scaling_factor
        return nn.functional.conv2d(input, bw, self.bias, self.stride, self.padding)

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
        res1 = self.shortcut1(x); x = binarize(self.bn2(self.bconv1(x)) + res1); x = self.pool(x)
        res2 = self.shortcut2(x); x = binarize(self.bn3(self.bconv2(x)) + res2); x = self.pool(x)
        res3 = self.shortcut3(x); x = binarize(self.bn4(self.bconv3(x)) + res3); x = self.pool(x)
        return self.head(x)

def natural_sort_key(s): return [int(t) if t.isdigit() else t.lower() for t in re.split('([0-9]+)', s)]

def get_val_samples(dataset_root="./bnn_dataset"):
    val_samples = []
    for folder in ['1','2','3','4','5','6']:
        img_dir = os.path.join(dataset_root, folder, "images")
        lbl_dir = os.path.join(dataset_root, folder, "labels")
        if not os.path.exists(img_dir): continue
        img_files = sorted([f for f in os.listdir(img_dir) if f.lower().endswith('.png')], key=natural_sort_key)
        split_idx = int(len(img_files) * 0.8)
        for f in img_files[split_idx : split_idx + 100]:
            lbl_path = os.path.join(lbl_dir, os.path.splitext(f)[0] + ".npy")
            if os.path.exists(lbl_path):
                val_samples.append({'img': os.path.join(img_dir, f), 'lbl': lbl_path, 'cls': 1 if np.max(np.load(lbl_path)) > 0.5 else 0})
    return val_samples

# ---------------------------------------------------------
# 메인 시각화 프로세스 (다중 그리드 활성화 표시)
# ---------------------------------------------------------
def visualize_multi_grid():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    output_dir = "visual_multi_grid_v6_2"
    os.makedirs(output_dir, exist_ok=True)

    model = HardwareResBNN_v6().to(device)
    model.load_state_dict(torch.load("final_res_bnn_ema.pth", map_location=device))
    model.eval()

    val_samples = get_val_samples()
    transform = T.Compose([T.ToTensor(), T.Normalize((0.5,), (0.5,))])

    print(f">>> {len(val_samples)}장 다중 그리드 시각화 시작...")

    with torch.no_grad():
        for i, sample in enumerate(val_samples):
            raw_img = cv2.imread(sample['img'])
            img_256 = cv2.resize(cv2.cvtColor(raw_img, cv2.COLOR_BGR2GRAY), (256, 256))
            img_tensor = transform(Image.fromarray(img_256)).unsqueeze(0).to(device)

            prob_map = torch.sigmoid(model(img_tensor)).squeeze().cpu().numpy()
            gt_grid = np.load(sample['lbl']).reshape(16, 16)
            
            vis_img = cv2.resize(raw_img, (512, 512)) # 가독성을 위해 512로 확대

            # 1. 정답 영역 (파란색 투명 박스)
            y_gt, x_gt = np.where(gt_grid > 0.5)
            for gy, gx in zip(y_gt, x_gt):
                cv2.rectangle(vis_img, (gx*32, gy*32), (gx*32+32, gy*32+32), (255, 0, 0), 1)

            # 2. 모든 활성화 영역 (노란색 박스: 확률 0.8 이상)
            y_pred, x_pred = np.where(prob_map > 0.8)
            for py, px in zip(y_pred, x_pred):
                # 살짝 작게 그려서 GT와 겹침 확인 용이하게 함
                cv2.rectangle(vis_img, (px*32+4, py*32+4), (px*32+28, py*32+28), (0, 255, 255), 2)

            # 3. 최고점 표시 (녹색 또는 빨간색 원)
            max_val = np.max(prob_map)
            is_match = False
            if max_val > 0.8:
                my, mx = np.unravel_index(np.argmax(prob_map), prob_map.shape)
                # 3x3 Tolerance 판정
                neighbor = gt_grid[max(0, my-1):min(16, my+2), max(0, mx-1):min(16, mx+2)]
                is_match = True if (sample['cls'] == 1 and np.any(neighbor > 0.5)) else False
                if sample['cls'] == 0: is_match = False # 배경인데 검출하면 FAIL

                color = (0, 255, 0) if is_match else (0, 0, 255)
                cv2.circle(vis_img, (mx*32+16, my*32+16), 10, color, -1) # 채워진 원
            else:
                if sample['cls'] == 0: is_match = True

            # 결과 저장
            res_str = "MATCH" if is_match else "FAIL"
            cv2.imwrite(os.path.join(output_dir, f"{i:03d}_{res_str}_{os.path.basename(sample['img'])}"), vis_img)

    print(f">>> 완료! {output_dir}/ 폴더를 확인하세요.")

if __name__ == "__main__":
    visualize_multi_grid()