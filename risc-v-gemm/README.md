# RISC-V 8×8 GEMM 프로세서 & ASIC 합성

5-stage 파이프라인 RISC-V 프로세서에 곱셈(MUL) 명령어와 8×8 행렬곱(GEMM) 연산을 구현하고,
Synopsys Design Compiler로 32nm 논리합성·타이밍 검증까지 **설계→합성→검증 전 과정**을 완결한 프로젝트입니다.

## 핵심 성과
- **32nm 표준셀(SAED 32nm) 합성 후 250MHz(4ns)에서 타이밍 슬랙 MET (0.00ns)**
- 합성된 게이트레벨 넷리스트를 RTL과 대조 검증하여 공정 특성이 반영된 동작 정확성까지 확인

## 설계 내용
- **5-stage 파이프라인** RISC-V 코어 (IF/ID/EX/MEM/WB)에 MUL 명령어와 행렬곱 연산 구현
- **데이터 해저드**: 의존 명령 간 간격을 확보하도록 명령어 순서 재정렬(reordering)로 해소
- **제어 해저드**: predict-not-taken으로 순차 명령을 선인출하고, 분기 성립 시 오인출 명령을 flush
- Synopsys DC 논리합성 → STA(정적 타이밍 분석) → 게이트레벨 시뮬레이션 검증

## 폴더 구조
- `rtl/` — RTL 소스 (`RISCVSINGLE`, `DATAPATH`, `CONTROLLER`, `ALU`/`ALUDEC`, 파이프라인 레지스터 `PR_*`, `TOP_GEMM` 등)
- `tb/` — 테스트벤치 (`TB_GEMM.v`)
- `syn/` — 합성 스크립트·제약 (`run.tcl`, `RISC.sdc`)
- `netlist/` — 합성 결과 게이트레벨 넷리스트 (`RISCVSINGLE_gate.v`)
- `report.txt` — 합성 타이밍 리포트 (slack MET)

**Tools:** Verilog · Synopsys Design Compiler · SAED 32nm 표준셀 라이브러리
