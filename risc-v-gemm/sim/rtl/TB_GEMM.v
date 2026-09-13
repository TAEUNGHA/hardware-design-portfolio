`timescale 1ns/1ps

// 8x8 8-bit 양의 정수 행렬 곱 C = A x B 를 검증하는 self-checking testbench
// - DMEM 내 메모리 맵 (바이트 주소 기준):
//   A: 0x0000_0000 ~ 8*8 words (행렬 A, row-major)
//   B: 0x0000_0100 ~ 8*8 words (행렬 B, row-major)
//   C: 0x0000_0200 ~ 8*8 words (행렬 C, row-major 결과)
//   STATUS(DONE flag용): 0x0000_0300
//
// 결과 비교 시, TCK 주기와 합성 후 나올 수 있는 절대 딜레이를
// 고려할 수 있도록 다음과 같은 매크로를 사용한다.
//
//   `TCK_NS                : 클럭 주기(ns)
//   `MAX_LATENCY_NS        : 허용 가능한 최대 연산 지연(ns)
//   `RESULT_CHECK_DELAY_NS : DONE 플래그 이후 결과를 읽기 전 대기 시간(ns)

`define TCK_NS                10         // 100MHz (10ns)
`define MAX_LATENCY_NS        20000000   // 20 ms (소프트웨어 mul32에 충분히 큼)
`define RESULT_CHECK_DELAY_NS 0          // DONE 이후 결과 읽기 전 추가 대기 시간

`define MAX_CYCLES (`MAX_LATENCY_NS / `TCK_NS)  // 2,000,000 cycles
`define MAX_TEST_ID 3 // 랜덤 테스트 횟수

module TB_GEMM;

  // 행렬 크기
  localparam N = 8;

  // 바이트 주소 기준 메모리 맵
  localparam [31:0] ADDR_BASE_A = 32'h0000_0000;
  localparam [31:0] ADDR_BASE_B = 32'h0000_0100;
  localparam [31:0] ADDR_BASE_C = 32'h0000_0200;
  localparam [31:0] ADDR_STATUS = 32'h0000_0300;

  // DUT와 연결되는 기본 신호들
  reg  CLK;
  reg  RESET;

  wire [31:0] PC;
  wire [31:0] DATAADR;
  wire [31:0] WRITEDATA;
  wire        MEMWRITE;

  // IMEM 디버그 포트
  reg         IMEM_DBG_EN;
  reg  [31:0] IMEM_DBG_A;
  wire [31:0] IMEM_DBG_RD;

  // DMEM 디버그 포트
  reg         DMEM_DBG_EN;
  reg         DMEM_DBG_WE;
  reg  [31:0] DMEM_DBG_A;
  reg  [31:0] DMEM_DBG_WD;
  wire [31:0] DMEM_DBG_RD;

  // DUT 인스턴스
  TOP_GEMM DUT (
    .CLK         (CLK),
    .RESET       (RESET),
    .PC          (PC),
    .DATAADR     (DATAADR),
    .WRITEDATA   (WRITEDATA),
    .MEMWRITE    (MEMWRITE),
    .IMEM_DBG_EN (IMEM_DBG_EN),
    .IMEM_DBG_A  (IMEM_DBG_A),
    .IMEM_DBG_RD (IMEM_DBG_RD),
    .DMEM_DBG_EN (DMEM_DBG_EN),
    .DMEM_DBG_WE (DMEM_DBG_WE),
    .DMEM_DBG_A  (DMEM_DBG_A),
    .DMEM_DBG_WD (DMEM_DBG_WD),
    .DMEM_DBG_RD (DMEM_DBG_RD)
  );

  // 골든 모델용 행렬 (software model)
  integer goldA [0:N*N-1];
  integer goldB [0:N*N-1];
  integer goldC [0:N*N-1];

  integer test_id;
  integer i, j, k;
  integer idx, idxA, idxB, idxC;

  integer pass_count, fail_count;

  // 리포트/트레이스 파일 관련 변수
  integer report_fd;
  integer trace_fd;
  integer last_done_cycle;
  reg     last_timed_out;
  integer last_mismatches;
  integer first_mismatch_i, first_mismatch_j;
  integer first_mismatch_mem, first_mismatch_gold;

  // trace용 글로벌 cycle 카운터
  integer cycle_cnt;

  //--------------------------------------------------------------------------
  // 클럭 생성
  //--------------------------------------------------------------------------
  initial begin
    CLK = 1'b0;
    forever #(`TCK_NS/2) CLK = ~CLK;
  end

  //--------------------------------------------------------------------------
  // DMEM 디버그 쓰기
  //--------------------------------------------------------------------------
  task dmem_dbg_write(input [31:0] addr, input [31:0] data);
  begin
    @(negedge CLK);
    DMEM_DBG_EN = 1'b1;
    DMEM_DBG_WE = 1'b1;
    DMEM_DBG_A  = addr;
    DMEM_DBG_WD = data;
    @(negedge CLK);
    DMEM_DBG_EN = 1'b0;
    DMEM_DBG_WE = 1'b0;
    DMEM_DBG_A  = 32'b0;
    DMEM_DBG_WD = 32'b0;
  end
  endtask

  //--------------------------------------------------------------------------
  // DMEM 디버그 읽기
  //--------------------------------------------------------------------------
  task dmem_dbg_read(input [31:0] addr, output [31:0] data);
  begin
    @(negedge CLK);
    DMEM_DBG_EN = 1'b1;
    DMEM_DBG_WE = 1'b0;
    DMEM_DBG_A  = addr;
    @(negedge CLK);
    data        = DMEM_DBG_RD;
    DMEM_DBG_EN = 1'b0;
    DMEM_DBG_A  = 32'b0;
  end
  endtask

  //--------------------------------------------------------------------------
  // DMEM에 랜덤 행렬 A,B를 넣고 C, STATUS 초기화
  //--------------------------------------------------------------------------
  task init_matrices_random;
    integer seed;
    integer tmp_addr;
  begin
    seed = test_id + 32'h1234_5678;

    for (i = 0; i < N; i = i + 1) begin
      for (j = 0; j < N; j = j + 1) begin
        idx = i*N + j;

        // 0~255 랜덤 값
        goldA[idx] = ($random(seed) & 8'hFF);
        goldB[idx] = ($random(seed) & 8'hFF);
        goldC[idx] = 0;

        // DMEM에 A,B,C 초기화
        tmp_addr = ADDR_BASE_A + (idx << 2);
        dmem_dbg_write(tmp_addr, goldA[idx]);

        tmp_addr = ADDR_BASE_B + (idx << 2);
        dmem_dbg_write(tmp_addr, goldB[idx]);

        tmp_addr = ADDR_BASE_C + (idx << 2);
        dmem_dbg_write(tmp_addr, 32'h0);  // C는 0으로
      end
    end

    // STATUS = 0
    dmem_dbg_write(ADDR_STATUS, 32'h0);
  end
  endtask

  //--------------------------------------------------------------------------
  // 골든 C = A x B 계산 (software model)
  //--------------------------------------------------------------------------
  task compute_golden;
  begin
    for (i = 0; i < N; i = i + 1) begin
      for (j = 0; j < N; j = j + 1) begin
        idxC = i*N + j;
        goldC[idxC] = 0;
        for (k = 0; k < N; k = k + 1) begin
          idxA = i*N + k;
          idxB = k*N + j;
          goldC[idxC] = goldC[idxC] + goldA[idxA] * goldB[idxB];
        end
      end
    end
  end
  endtask

  //--------------------------------------------------------------------------
  // 결과 비교 (C 전체 비교, 첫 mismatch 기록)
  //--------------------------------------------------------------------------
  task check_result;
    integer mismatches;
    reg [31:0] c_hw;
    integer addr;
  begin
    mismatches          = 0;
    last_mismatches     = 0;
    first_mismatch_i    = -1;
    first_mismatch_j    = -1;
    first_mismatch_mem  = 0;
    first_mismatch_gold = 0;

    for (i = 0; i < N; i = i + 1) begin
      for (j = 0; j < N; j = j + 1) begin
        idx  = i*N + j;
        addr = ADDR_BASE_C + (idx << 2);

        dmem_dbg_read(addr, c_hw);

        if (c_hw !== goldC[idx]) begin
          if (mismatches == 0) begin
            first_mismatch_i    = i;
            first_mismatch_j    = j;
            first_mismatch_mem  = c_hw;
            first_mismatch_gold = goldC[idx];
          end
          mismatches = mismatches + 1;
          if (mismatches <= 10) begin
            $display("  MISMATCH test %0d: C[%0d,%0d] = %0d (mem) != %0d (gold)",
                     test_id, i, j, c_hw, goldC[idx]);
          end
        end
      end
    end

    last_mismatches = mismatches;

    if (mismatches == 0) begin
      pass_count = pass_count + 1;
      $display("TEST %0d PASS", test_id);
    end else begin
      fail_count = fail_count + 1;
      $display("TEST %0d FAIL: mismatches=%0d", test_id, mismatches);
    end
  end
  endtask

  //--------------------------------------------------------------------------
  // DONE 플래그 또는 타임아웃까지 대기 (STATUS 읽어 확인)
  //--------------------------------------------------------------------------
  task wait_done_or_timeout;
    integer cycle;
    reg [31:0] status_val;
    reg done;
  begin
    done            = 0;
    cycle           = 0;
    last_done_cycle = 0;
    last_timed_out  = 0;

    while (!done && cycle < `MAX_CYCLES) begin
      @(posedge CLK);
      cycle = cycle + 1;

      dmem_dbg_read(ADDR_STATUS, status_val);
      if (status_val == 32'h1) begin
        done            = 1;
        last_done_cycle = cycle;
        $display("  DONE detected at time %0t (cycle %0d)", $time, cycle);
      end

      // 간헐적 디버그 출력
      if (cycle % 100000 == 0) begin
        $display("  [DEBUG] cycle=%0d, PC=%h", cycle, PC);
      end
    end

    if (!done) begin
      last_timed_out = 1;
      $display("  TIMEOUT waiting for DONE flag (cycle >= %0d)", `MAX_CYCLES);
    end
  end
  endtask

  //--------------------------------------------------------------------------
  // trace용: 모든 클럭에서 PC/MEMWRITE를 로그 파일로 남김
  //--------------------------------------------------------------------------
  always @(posedge CLK) begin
    if (RESET) begin
      cycle_cnt <= 0;
    end else begin
      cycle_cnt <= cycle_cnt + 1;

      if (trace_fd != 0) begin
        // 100주기마다 스냅샷
        if (cycle_cnt % 100 == 0) begin
          $fdisplay(trace_fd,
            "C%0d SNAP PC=%08h MEMWRITE=%0d DATAADR=%08h WRITEDATA=%08h",
            cycle_cnt, PC, MEMWRITE, DATAADR, WRITEDATA);
        end

        // 메모리 write가 있을 때 이벤트 로깅
        if (MEMWRITE) begin
          $fdisplay(trace_fd,
            "C%0d WRITE A=%08h WD=%08h",
            cycle_cnt, DATAADR, WRITEDATA);

          // STATUS 쓰기
          if (DATAADR == ADDR_STATUS) begin
            $fdisplay(trace_fd,
              "C%0d STATUS_WRITE value=%08h",
              cycle_cnt, WRITEDATA);
          end

          // C 영역 쓰기
          if (DATAADR >= ADDR_BASE_C &&
              DATAADR <  ADDR_BASE_C + N*N*4) begin
            integer c_idx;
            c_idx = (DATAADR - ADDR_BASE_C) >> 2;
            $fdisplay(trace_fd,
              "C%0d C_WRITE idx=%0d value=%08h",
              cycle_cnt, c_idx, WRITEDATA);
          end
        end
      end
    end
  end

  //--------------------------------------------------------------------------
  // 메인 시나리오: 10번 랜덤 8x8 GEMM 테스트 + 리포트/트레이스 출력
  //--------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    // 디버그 포트 초기값
    IMEM_DBG_EN = 1'b0;
    IMEM_DBG_A  = 32'b0;
    DMEM_DBG_EN = 1'b0;
    DMEM_DBG_WE = 1'b0;
    DMEM_DBG_A  = 32'b0;
    DMEM_DBG_WD = 32'b0;

    // 리포트 파일 오픈
    report_fd = $fopen("gemm_report.txt", "w");
    if (report_fd == 0) begin
      $display("ERROR: Cannot open gemm_report.txt for writing");
    end else begin
      $fdisplay(report_fd, "8x8 GEMM Simulation Report");
      $fdisplay(report_fd,
        "TCK_NS=%0d ns, MAX_LATENCY_NS=%0d ns, RESULT_CHECK_DELAY_NS=%0d ns",
        `TCK_NS, `MAX_LATENCY_NS, `RESULT_CHECK_DELAY_NS);
      $fdisplay(report_fd,
        "-------------------------------------------------------------------------------");
    end

    // trace 파일 오픈
    trace_fd = $fopen("gemm_trace.txt", "w");
    if (trace_fd == 0) begin
      $display("ERROR: Cannot open gemm_trace.txt for writing");
    end else begin
      $fdisplay(trace_fd, "cycle, PC, MEMWRITE, DATAADR, WRITEDATA");
    end

    // 초기 리셋
    RESET = 1'b1;
    #(`TCK_NS*50);
    @(negedge CLK);
    RESET = 1'b0;

    // 여러 번 랜덤 테스트 수행
    for (test_id = 0; test_id < (`MAX_TEST_ID); test_id = test_id + 1) begin
      integer latency_ns;
      integer total_time_ns;

      $display("\n==== GEMM TEST %0d START ====", test_id);

      // 각 테스트마다: RESET=1 상태에서 DMEM 초기화 후 리셋 해제
      RESET = 1'b1;
      init_matrices_random();
      compute_golden();
      // 입력 행렬 A, B와 기대 결과 C(golden)를 리포트 파일에 출력
      if (report_fd != 0) begin
        integer ridx;
        $fdisplay(report_fd, "TEST %0d : Random Matrices and Expected Result", test_id);

        // Matrix A
        $fdisplay(report_fd, "Matrix A (8x8):");
        for (i = 0; i < N; i = i + 1) begin
          for (j = 0; j < N; j = j + 1) begin
            ridx = i*N + j;
            $fwrite(report_fd, "%0d ", goldA[ridx]);
          end
          $fdisplay(report_fd, "");
        end

        // Matrix B
        $fdisplay(report_fd, "Matrix B (8x8):");
        for (i = 0; i < N; i = i + 1) begin
          for (j = 0; j < N; j = j + 1) begin
            ridx = i*N + j;
            $fwrite(report_fd, "%0d ", goldB[ridx]);
          end
          $fdisplay(report_fd, "");
        end

        // Expected Matrix C (golden)
        $fdisplay(report_fd, "Expected Matrix C = A x B (8x8):");
        for (i = 0; i < N; i = i + 1) begin
          for (j = 0; j < N; j = j + 1) begin
            ridx = i*N + j;
            $fwrite(report_fd, "%0d ", goldC[ridx]);
          end
          $fdisplay(report_fd, "");
        end

        $fdisplay(report_fd,
          "-------------------------------------------------------------------------------");
      end

      #20;
      RESET = 1'b0;

      // DONE 플래그까지 대기
      wait_done_or_timeout();

      // DONE 이후 여유 시간
      #(`RESULT_CHECK_DELAY_NS);

      // 결과 비교
      check_result();

      latency_ns    = last_done_cycle * `TCK_NS;
      total_time_ns = latency_ns + `RESULT_CHECK_DELAY_NS;

      if (report_fd != 0) begin
        if (last_timed_out) begin
          $fdisplay(report_fd,
            "TEST %0d : TIMEOUT (no DONE). TCK_NS=%0d ns, MAX_LATENCY_NS=%0d ns",
            test_id, `TCK_NS, `MAX_LATENCY_NS);
        end else if (last_mismatches == 0) begin
          $fdisplay(report_fd,
            "TEST %0d : PASS | TCK_NS=%0d ns | DONE_cycle=%0d | latency_ns=%0d | extra_delay_ns=%0d | total_time_ns=%0d",
            test_id, `TCK_NS, last_done_cycle, latency_ns,
            `RESULT_CHECK_DELAY_NS, total_time_ns);
        end else begin
          $fdisplay(report_fd,
            "TEST %0d : FAIL | TCK_NS=%0d ns | DONE_cycle=%0d | latency_ns=%0d | extra_delay_ns=%0d | total_time_ns=%0d",
            test_id, `TCK_NS, last_done_cycle, latency_ns,
            `RESULT_CHECK_DELAY_NS, total_time_ns);
          $fdisplay(report_fd,
            "  first mismatch at C[%0d,%0d] : expected=%0d, measured=%0d (total mismatches=%0d)",
            first_mismatch_i, first_mismatch_j,
            first_mismatch_gold, first_mismatch_mem, last_mismatches);
        end
        $fdisplay(report_fd,
          "-------------------------------------------------------------------------------");
      end
    end

    $display("\n==== ALL TESTS DONE: PASS=%0d, FAIL=%0d ====",
             pass_count, fail_count);

    if (report_fd != 0) begin
      $fdisplay(report_fd,
        "SUMMARY: PASS=%0d, FAIL=%0d", pass_count, fail_count);
      $fclose(report_fd);
    end
    if (trace_fd != 0) begin
      $fclose(trace_fd);
    end

    $finish;
  end

endmodule
