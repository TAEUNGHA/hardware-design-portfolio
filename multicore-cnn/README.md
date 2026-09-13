# 멀티코어 CNN Convolution 가속 프로세서 (3×3 Systolic)

3×3, 총 9개 코어로 구성된 멀티코어 연산 시스템을 **SystemVerilog**로 설계하고,
CNN convolution을 대상 연산으로 구현한 프로젝트입니다. convolution이 같은 weight·input을
여러 연산에 반복 사용한다는 점에 착안해, 한 번 불러온 데이터를 인접 코어로 흘려보내며
재사용하는 **systolic 데이터플로우**로 설계했습니다.

## 핵심
- 각 코어에 **stack 구조 레지스터**를 두어 곱셈 순서와 데이터 재사용을 직접 제어하고, 코어 입출력 방향을 설계해 인접 코어 간 systolic 데이터 전달을 구현
- 데이터 재사용으로 동일 convolution 연산을 **단일 CPU 대비 명령어 196 → 135개(약 31%↓)**
- **Verilator** 검증 환경에서 랜덤 입력에 **Scoreboard·Coverage·Assertion**을 적용해 엣지 케이스까지 검증

## 구조
- `rtl/`
  - `core_3by3.sv` — 9개 코어를 3×3으로 연결한 최상위
  - `core_topmodule.sv` — 단일 코어 통합(PC·RAM·Decoder·Mult·Adder)
  - `core_pc.sv` · `core_ram.sv` · `core_decoder.sv` · `core_mult.sv` · `core_adder.sv` — 코어 구성 모듈
- `tb/core_3by3_tb.sv` — 시스템 검증 테스트벤치

> 소스는 프로젝트 최종 보고서에 포함된 코드를 모듈별로 추출·정리한 것입니다(PDF 특수문자 제거).
> 시뮬레이터에서 한 번 컴파일 확인 후 사용을 권장합니다.

**Tools:** SystemVerilog · Verilator
