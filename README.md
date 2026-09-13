# hardware-design-portfolio

##📂 대표 프로젝트

###1. FPGA 기반 BNN 객체인식 하드웨어 가속기 (졸업 종합설계, 2026)

###GPU 없이 저전력 엣지 환경에서 실시간 객체 인식을 구현한 프로젝트. 사람 검출·안면 인식 담당.

###곱셈을 XNOR·비트카운트로 대체하는 BNN 가속기를 RTL로 설계, Zynq-7020 단일 SoC에 구현
###검증을 SW → PS → PS+PL → PL 단계로 나눠 PL이 PS 결과를 bit-exact 재현함을 확인
###성과: 사람 검출 정확도 94.5% / 추론 30초 → 1.394초(약 21배) / 자원 LUT 79%·BRAM 74%·DSP 33%
###학습 데이터가 없어 촬영 영상에서 프레임을 추출·YOLO 자동 라벨링해 확보, PCAM 도메인 적응 재학습으로 실환경 정확도 개선
###기술: SystemVerilog/Verilog, Vivado·Vitis, Zynq-7020, Python(학습 파이프라인)

###2. RISC-V 8×8 GEMM 프로세서 & ASIC 합성 (2025)

파이프라인 프로세서 설계부터 ASIC 합성·타이밍 검증까지 완결.

5-stage 파이프라인 RISC-V에 MUL 명령어와 8×8 행렬곱 연산 구현
데이터·제어 해저드를 명령어 재정렬 / predict-not-taken + flush로 해결
Synopsys DC 32nm 합성, 250MHz(4ns)에서 타이밍 슬랙 MET, 게이트레벨 넷리스트를 RTL과 대조 검증
기술: Verilog, Synopsys Design Compiler, STA
3. 멀티코어 CNN Convolution 가속기 (2025)
CNN convolution을 병렬 가속하는 3×3 멀티코어 프로세서를 SystemVerilog로 설계
각 코어에 stack 구조를 두어 systolic 데이터플로우로 weight·input 재사용 극대화
성과: 단일 CPU 대비 CNN 1회 연산 명령어 196 → 135개(약 31%↓)
Verilator 기반 검증환경에서 Scoreboard·Coverage·Assertion으로 엣지 케이스까지 검증
기술: SystemVerilog, Verilator
4. Zynq 기반 CNN(LeNet) 가속 SoC (2025)
Zynq-7000에 LeNet(MNIST) 추론 SoC를 PL 가속기 + PS 제어앱 + AXI 구조로 설계
BRAM 버퍼링·타일링, Vivado·Vitis 기반 HW–SW 통합
기술: Verilog, Vivado·Vitis, AXI, C/C++
5. Baugh-Wooley 4×4 곱셈기 풀커스텀 레이아웃 (VLSI, 2026)
signed 곱셈기를 트랜지스터 레벨 스키매틱부터 50nm 풀커스텀 레이아웃까지 설계
성과: 면적 294.6µm² · 최악 지연 약 0.62ns, DRC·LVS 무결 통과, post-layout 시뮬레이션 검증
6. FPGA 실시간 제어 시스템 — 엘리베이터 FSM (2025)
7-상태 FSM 엘리베이터 제어기를 Verilog로 설계, DE2 FPGA 구현
UART 원격 모니터링·명령 파서, 비상정지 인터록 포함, 제공 테스트 31/31 통과
기술: Verilog, UART, Altera DE2
7. STM32 스마트 가스밸브 안전 개선 (임베디드 경진대회, 2026)
가스·불꽃·온도·인체감지 센서와 서보모터를 연동한 임베디드 안전 제어 시스템
기존 제품의 안전 취약점을 센서 기반 자동 제어로 개선
기술: STM32, C, 다중 센서·모터 제어
