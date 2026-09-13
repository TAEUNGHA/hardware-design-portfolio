# FPGA 기반 BNN 객체인식 하드웨어 가속기 (졸업 종합설계, 2026)

Zynq-7020 단일 SoC에 이진 신경망(BNN) 기반 **사람 검출 가속기**를 RTL로 설계·검증한 프로젝트입니다.
곱셈을 XNOR·비트카운트로 대체해 연산을 경량화했고, 검증은 SW→PS→PS+PL→PL 단계로 나눠 PL이 PS 결과를 **bit-exact**로 재현함을 확인했습니다.

**핵심 성과** — 사람 검출 정확도 94.5% · 추론 30초 → 1.394초(약 21배) · 자원 LUT 79% / BRAM 74% / DSP 33%

## 폴더 구조

### `training/` — 학습·데이터·weight 추출 (PyTorch)
- `v2_final_bnn_256_gray.py` — 베이스 학습 (`HardwareResBNN_v6` → `final_res_bnn_v6.pth`)
- `v2_final_bnn_256_gray_@.py` — EMA 안정화 학습 (→ `final_res_bnn_ema.pth`, 89.67%)
- `v2_final_bnn_256_gray_3.py` — 검증·시각화 (16×16 그리드 활성 표시)
- `datamake.py`, `YOLO_12.py` — 학습 데이터 생성 / YOLO 자동 라벨링
- **`domain_adaptation/` — PCAM 도메인 적응 파이프라인**
  1. `1_capture_bin2png.py` — PCAM 캡처 → png 변환
  2. `2_label_pcam.py` — PCAM 이미지 YOLO 자동 라벨링
  3. `3_retrain_pcam.py` — 기존 모델(ema)에서 시작해 **기존+PCAM 혼합 fine-tune** (sRGB↔linear 도메인 갭을 낮은 LR·감마 jitter로 보정) → `final_res_bnn_pcam.pth`
  4. `4_export_weights_hls.py` — `.pth` → `weights_hls.h` (Q15.16) HLS weight 추출

### `vivado/` — 가속기 하드웨어 (RTL + 프로젝트)
- `A3/` — 가속기 IP RTL: `Accelerator_Top` · `BNN_Core_Unit` · `Stage1/2_Engine` · `Global_Weight_Dispatcher` · `AXI_Lite_Slave`
- `A4_1/` — 블록디자인 시스템 프로젝트(`.xpr`) + 하드웨어 핸드오프(`.xsa`)

### `vitis/` — PS 제어 애플리케이션
- `hello_world/src/main.c` — PS 제어 프로그램 · `weights_hls.h` — 배포 가중치 헤더

---
> Vivado `.runs`/`.cache`, Vitis `platform`(BSP), 대용량 데이터셋(`.bin`)·가중치(`.pth`)·사전학습 YOLO(`.pt`)는
> 빌드 시 재생성되거나 용량이 커 제외했습니다. `.xpr`를 열면 프로젝트가 정상 복원됩니다.
