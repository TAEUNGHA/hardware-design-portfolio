# FPGA 기반 실시간 엘리베이터 제어 시스템 (FSM)

7-상태 FSM 엘리베이터 제어기를 Verilog로 설계해 **Altera DE2 FPGA**에 구현한 실시간 제어 시스템입니다.
SCAN 방식 스케줄러, UART 기반 원격 명령·모니터링, 비상정지 인터록을 포함합니다.

## 핵심 성과
- 제공된 테스트벤치의 **7개 시나리오 31/31 STEP 전부 PASS** (다층 상·하행 순서 제어, SCAN 스케줄링, 문 개폐, 비상정지)
- 기본 요구사항(FSM 제어) 외에 **다음 이동방향 예측**, **원격 UART 제어**, **HALL 버튼 겸용** 등 부가기능 구현

## FSM 설계 (7-state)
`S_IDLE_STOP(0)` · `S_DOOR_OPENING(1)` · `S_DOOR_CLOSING(2)` · `S_MOVING_UP(3)` · `S_MOVING_DOWN(4)` · `S_DWELL(5)` · `S_EMG(6)`
- **2-process 방식** — posedge clk에서 상태 갱신, `always@(*)` 조합회로에서 next_state 계산
- 출력(현재 층·방향, 모터·도어 구동)은 `assign` 조합논리로 즉시 반영
- 시간이 필요한 상태(OPENING/CLOSING, DWELL, MOVING)에는 **`tickgen`(1초 tick 생성기)을 3개 개별 인스턴스**로 배치

## SCAN 스케줄러
- 현재 진행 방향과 같은 Hall 호출에 우선순위를 주고, 그중 **가장 가까운 층을 최우선**으로 선택
- 정지 순간의 다음 이동방향을 `dir_save` 레지스터에 저장 → 스케줄링과 **방향 예측**에 활용
- 문은 OPEN을 CLOSE보다 우선, 현재 층과 HALL 층이 같고 정차 중이면 HALL 호출을 버튼처럼 처리

## 서브모듈
- **`uart_rx` / `uart_tx`** — 115200bps 비동기 직렬 송수신 (start/8-data/stop 비트 타이밍 샘플링)
- **`cmd_parser`** — 수신 바이트를 `\r` 기준으로 파싱해 Hall Call / Car Call 명령으로 디코드, 오류 시 에러 신호
- **`status_transmitter`** — 주기 보고·에러·도움 요청을 받아 `"F:05,DIR:STOP\r\n"` 등 상태 메시지를 UART로 순차 송신
- **`debouncer`** — 100clk 안정 신호만 통과시키는 버튼 디바운서
- **`EController`** — 상태 전이·스케줄러·출력 제어 핵심 로직 / **`ELEVATOR_FSM`** — UART 제외 코어 통합
- **`ELEVATOR_TOP`** — 전체 서브모듈 배선(중앙 배선반) / **`DE2_ELEVATOR`** — DE2 보드 물리 핀 매핑 최상위

## DE2 입출력 매핑
- `HEX1/HEX0` 현재 층 · `HEX4` 방향 예측(S/U/d) · `HEX6` FSM 상태 번호
- `SW0` RST_N · `SW17` EMG_STOP · `KEY0` OPEN · `KEY1` CLOSE · `KEY3` HELP(비상 호출)
- `LEDR0~3` MOTOR_UP/DOWN·DOOR_OPEN/CLOSE · `LEDG0~2` 현재 이동상태(STOP/UP/DOWN)

## 폴더 구조
- `quartus/` — **열리는 Quartus 프로젝트**: 소스 `.v` 전체 + 프로젝트/설정/제약 (`test1.qpf`, `test1.qsf`, `test1.sdc`)
- `tb/` — 테스트벤치(`TB_ELEVATOR_TOP_V31.v`)와 테스트 결과(`report.txt`, 31/31 PASS)
- `gui/` — PC측 UART 모니터링 GUI (`elevator_GUI2.py`, PuTTY 대체)

> 컴파일 시 재생성되는 Quartus 산출물(`db/`, `incremental_db/`, `output_files/`, `.bak`)은 제외했습니다.
> `test1.qpf`를 Quartus에서 열면 프로젝트가 복원됩니다.

**Tools:** Verilog · UART(115200bps) · Altera DE2 FPGA (Quartus)
