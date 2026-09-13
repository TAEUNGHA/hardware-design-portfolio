import os
import cv2
import numpy as np
from ultralytics import YOLO
from tqdm import tqdm

def generate_folder_wise_dataset(root_folders=['3', '4', '5', '6'], output_base="./bnn_dataset"): #1,2,3,4,5,6
    # 1. YOLOv8 모델 로드
    model = YOLO('yolov8n.pt') 
    
    print(f"폴더별 데이터셋 생성을 시작합니다. 대상: {root_folders}")

    for folder_name in root_folders:
        if not os.path.exists(folder_name):
            print(f"경고: {folder_name} 폴더를 찾을 수 없어 건너뜁니다.")
            continue

        # 2. 각 원본 폴더별 저장 경로 설정
        current_folder_dir = os.path.join(output_base, folder_name)
        img_dir = os.path.join(current_folder_dir, "images")
        label_dir = os.path.join(current_folder_dir, "labels")
        visual_dir = os.path.join(current_folder_dir, "visuals")
        
        for d in [img_dir, label_dir, visual_dir]:
            os.makedirs(d, exist_ok=True)

        print(f"\n--- [폴더 {folder_name}] 처리 시작 ---")

        for label_type in ['0', '1']: # 0: 배경, 1: 사람
            input_dir = os.path.join(folder_name, label_type)
            if not os.path.exists(input_dir):
                continue

            files = [f for f in os.listdir(input_dir) if f.lower().endswith(('.png', '.jpg', '.jpeg'))]
            print(f" > 하위 폴더 '{label_type}' 라벨링 중... ({len(files)}장)")

            for f in tqdm(files):
                img_path = os.path.join(input_dir, f)
                img = cv2.imread(img_path)
                if img is None: continue

                # 512x512 리사이징 (AI 모델 입력 규격)
                img_512 = cv2.resize(img, (512, 512))
                img_vis = img_512.copy()
                
                base_name = os.path.splitext(f)[0]
                # 파일명에 라벨 타입(0/1)을 붙여 저장
                save_name = f"L{label_type}_{base_name}"
                
                # 16x16 그리드 정답지 생성
                grid_label = np.zeros((16, 16), dtype=np.float32)

                # 사람이 있는 폴더(1)인 경우에만 YOLO 가동
                if label_type == '1':
                    results = model(img_512, verbose=False, conf=0.4)
                    
                    for r in results:
                        for box in r.boxes:
                            if int(box.cls) == 0: # Person
                                x1, y1, x2, y2 = box.xyxy[0].cpu().numpy().astype(int)
                                
                                # 시각화용 박스 그리기
                                cv2.rectangle(img_vis, (x1, y1), (x2, y2), (0, 0, 255), 2)
                                
                                # 16x16 그리드 매핑
                                gx1, gy1 = int(x1 / 32), int(y1 / 32)
                                gx2, gy2 = int(x2 / 32), int(y2 / 32)
                                
                                grid_label[max(0, gy1):min(16, gy2+1), max(0, gx1):min(16, gx2+1)] = 1.0
                                
                                # 시각화용 그리드 색칠
                                for gy in range(max(0, gy1), min(16, gy2+1)):
                                    for gx in range(max(0, gx1), min(16, gx2+1)):
                                        overlay = img_vis.copy()
                                        cv2.rectangle(overlay, (gx*32, gy*32), (gx*32+32, gy*32+32), (0, 255, 0), -1)
                                        cv2.addWeighted(overlay, 0.3, img_vis, 0.7, 0, img_vis)

                # 시각화 가독성을 위한 그리드 선 추가
                for i in range(1, 16):
                    cv2.line(img_vis, (i*32, 0), (i*32, 512), (100, 100, 100), 1)
                    cv2.line(img_vis, (0, i*32), (512, i*32), (100, 100, 100), 1)

                # 데이터 저장 (해당 폴더 내부의 경로로)
                cv2.imwrite(os.path.join(img_dir, f"{save_name}.png"), img_512)
                np.save(os.path.join(label_dir, f"{save_name}.npy"), grid_label)
                cv2.imwrite(os.path.join(visual_dir, f"vis_{save_name}.jpg"), img_vis)

    print(f"\n[전체 완료] '{output_base}' 폴더 내부에 폴더별로 정리되었습니다.")

if __name__ == "__main__":
    # pip install ultralytics tqdm
    generate_folder_wise_dataset()