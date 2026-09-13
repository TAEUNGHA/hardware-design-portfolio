import os, cv2, re, numpy as np, torch

def natural_sort_key(s): return [int(t) if t.isdigit() else t.lower() for t in re.split('([0-9]+)', s)]

def export_v22_1_force_background():
    out_dir = "./BNN_DATA"
    if not os.path.exists(out_dir): os.makedirs(out_dir)
    
    global_idx = 0
    print(">>> Starting v22.1 Force Background Search (Scanning all frames)")

    for fld in ['1','2','3','4','5','6']:
        i_p = f"./bnn_dataset/{fld}/images"
        l_p = f"./bnn_dataset/{fld}/labels"
        if not os.path.exists(i_p): continue
        
        # 파일 목록 정렬 및 매칭
        common = sorted(list(set([f.replace('.png','') for f in os.listdir(i_p)]) & set([f.replace('.npy','') for f in os.listdir(l_p)])), key=natural_sort_key)
        
        bg_list = []
        person_list = []
        
        # [수정] 분할 구간에 상관없이 폴더 전체를 스캔하여 배경/사람 분류
        for name in common:
            lbl = np.load(os.path.join(l_p, name + '.npy'))
            # 아주 미세한 값도 배경으로 인정하기 위해 임계값 조정 (0.1)
            if np.max(lbl) < 0.1:
                bg_list.append(name)
            else:
                person_list.append(name)
        
        # 폴더당 100장 구성 전략
        # 5, 6번 폴더는 배경을 최대한 많이(최대 50장) 넣음
        # 1~4번 폴더는 배경이 있으면 넣고 없으면 사람으로 채움
        if fld in ['5', '6']:
            num_bg = min(len(bg_list), 50)
        else:
            num_bg = min(len(bg_list), 20) # 1~4번은 배경이 적으므로 최대 20장만 시도
            
        num_person = 100 - num_bg
        
        # 최종 리스트 확정
        target_names = bg_list[:num_bg] + person_list[:num_person]
        
        print(f"Folder {fld}: Found Total BG:{len(bg_list)}, Person:{len(person_list)}")
        print(f"   -> Selected for Test: BG:{num_bg}, Person:{num_person}")

        for name in target_names:
            img = cv2.resize(cv2.imread(os.path.join(i_p, name+'.png'), 0), (256, 256))
            lbl = np.load(os.path.join(l_p, name+'.npy')).reshape(16, 16)
            
            # i{idx}.bin, l{idx}.bin 형태로 저장
            img.tofile(os.path.join(out_dir, f"i{global_idx}.bin"))
            (lbl > 0.5).astype(np.uint8).tofile(os.path.join(out_dir, f"l{global_idx}.bin"))
            global_idx += 1

    print(f"\n>>> Total {global_idx} pairs synced and created in {out_dir}")

if __name__ == "__main__":
    export_v22_1_force_background()