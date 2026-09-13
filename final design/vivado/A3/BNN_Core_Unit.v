`timescale 1ns / 1ps
// =============================================================================
// BNN_Core_Unit.v  -  XNOR-Popcount + Linear Fold 파이프라인
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │  Pipeline (5-stage, 5-cycle latency)                                     │
// │                                                                          │
// │  T+0  in_vld=1, win_bits / weight_bits / total_bits / params 안정        │
// │  T+1  [Stage1] xnor_res → p_sum[32]  (32그룹 × 18bit 부분 팝카운트)     │
// │  T+2  [Stage2] p_sum[32] → pop_cnt   (5레벨 이진트리, 10비트)           │
// │  T+3  [Stage3] b_res × param_A → mul_q16  (b_res 조합, 곱셈 등록)      │
// │  T+4  [Stage4] mul_q16[31:0] + param_B → out_val_pre (sc_val 분리)      │
// │  T+5  [Stage5] out_val_pre + sc_val → out_val (등록)                    │
// │                                                                          │
// │  [타이밍 개선] sc_val 덧셈을 Stage5로 분리:                               │
// │    기존: sc_b3트리(7레벨)+Stage4덧셈(10레벨) = 22레벨 한 클럭 → 위반    │
// │    변경: 트리→core_sc_val.D(11레벨) / sc_val.Q→out_val.D(5레벨) 분리    │
// │                                                                          │
// │  out_vld = vld_pipe[4] → T+5 에 1이 됨 (out_val 과 동일 클럭 등록)      │
// └──────────────────────────────────────────────────────────────────────────┘
//
// 주의:
//   · param_A, param_B, sc_val 은 in_vld 이후 최소 5클럭 동안 안정 유지 필요
//   · Block3 (1152-bit) 은 Stage2_Engine에서 2패스 호출 후 결과를 합산
//   · mul_q16[31:0] 사용: b_res(-576~+1152) × weff(Q15.16, 실용 범위 ±30)
//     최대 1152 × 30×65536 ≈ 2.27×10⁹ → 32비트 부호 정수 상한에 근접.
//     weff 절댓값이 30 이상인 경우 상위 비트 [47:16] 슬라이싱으로 교체 필요.
// =============================================================================

module BNN_Core_Unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vld,

    // ── 이진 입력 벡터 (3×3×in_ch, 최대 576비트) ──────────────────────────
    input  wire [575:0]       win_bits,     // 3×3 입력 창 이진 벡터
    input  wire [575:0]       weight_bits,  // 3×3 가중치 이진 벡터
    input  wire  [9:0]        total_bits,   // 유효 비트 수 (≤576)

    // ── 선형 폴딩 파라미터 (Q15.16 고정소수점) ─────────────────────────────
    input  wire signed [31:0] param_A,      // weff
    input  wire signed [31:0] param_B,      // beff  (Block3 패스0은 32'h0 전달)
    input  wire signed [31:0] sc_val,       // shortcut 합산값

    // ── 출력 ──────────────────────────────────────────────────────────────
    output reg  signed [31:0] out_val,      // 최종 합산 결과 (Q15.16)
    output wire               out_bit,      // 이진화: out_val ≥ 0 → 1'b1
    output wire               out_vld       // out_val 유효 신호 (4클럭 지연)
);

    integer i, j;

    // =========================================================================
    // [조합] XNOR 연산
    // =========================================================================
    wire [575:0] xnor_res;
    assign xnor_res = ~(win_bits ^ weight_bits);

    // =========================================================================
    // Stage 1 : 32그룹 부분 팝카운트
    //   · 576비트를 32그룹 × 18비트로 분할
    //   · 각 그룹 최대값 = 18  →  5비트 [4:0]
    //   · for-loop 내부에서 블로킹 acc 로 누산 후 non-blocking 등록
    //     (non-blocking 누산이면 마지막 반복값만 반영되는 RTL 버그 방지)
    // =========================================================================
    reg [4:0] p_sum [0:31];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1)
                p_sum[i] <= 5'd0;
        end else begin
            for (i = 0; i < 32; i = i + 1) begin : GEN_PSUM
                reg [4:0] acc;
                acc = 5'd0;
                for (j = 0; j < 18; j = j + 1)
                    acc = acc + {4'b0, xnor_res[i * 18 + j]};
                p_sum[i] <= acc;
            end
        end
    end

    // =========================================================================
    // Stage 2 : 전체 팝카운트 합산 - 5레벨 병렬 이진 트리
    //   · 32그룹(5-bit) → 16(6-bit) → 8(7-bit) → 4(8-bit) → 2(9-bit) → 1(10-bit)
    //   · 기존 32단 직렬 루프(~10ns) → 5레벨 트리(~2.5ns)로 타이밍 개선
    // =========================================================================
    genvar gp;

    wire [5:0] pt1 [0:15];
    wire [6:0] pt2 [0:7];
    wire [7:0] pt3 [0:3];
    wire [8:0] pt4 [0:1];
    wire [9:0] pt5;

    generate
        for (gp = 0; gp < 16; gp = gp + 1) begin : PT1
            assign pt1[gp] = {1'b0, p_sum[2*gp]} + {1'b0, p_sum[2*gp+1]};
        end
        for (gp = 0; gp < 8; gp = gp + 1) begin : PT2
            assign pt2[gp] = {1'b0, pt1[2*gp]} + {1'b0, pt1[2*gp+1]};
        end
        for (gp = 0; gp < 4; gp = gp + 1) begin : PT3
            assign pt3[gp] = {1'b0, pt2[2*gp]} + {1'b0, pt2[2*gp+1]};
        end
        for (gp = 0; gp < 2; gp = gp + 1) begin : PT4
            assign pt4[gp] = {1'b0, pt3[2*gp]} + {1'b0, pt3[2*gp+1]};
        end
    endgenerate
    assign pt5 = {1'b0, pt4[0]} + {1'b0, pt4[1]};

    reg [9:0] pop_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pop_cnt <= 10'd0;
        else        pop_cnt <= pt5;
    end

    // =========================================================================
    // [조합] b_res = 2×pop_cnt - total_bits
    //   · 범위: -576 ~ +1152  →  12비트 부호 정수 [11:0]
    //   · {1'b0, pop_cnt, 1'b0} = 12비트 (MSB 0 패딩 + pop_cnt × 2)
    //   · {2'b00, total_bits}   = 12비트 (MSB 2비트 0 패딩)
    //   · total_bits 는 연산 기간 내 안정 → 지연 불필요
    // =========================================================================
    wire signed [11:0] b_res;
    assign b_res = $signed({1'b0, pop_cnt, 1'b0}) - $signed({2'b00, total_bits});

    // =========================================================================
    // Stage 3 : 곱셈  mul_q16 = b_res × param_A
    //   · 12비트 × 32비트 → 44비트 결과를 64비트 레지스터에 부호 확장 저장
    //   · [31:0] 슬라이스를 Q15.16 결과로 사용
    //     (b_res 는 정수, param_A 는 Q15.16 → 곱은 그대로 Q15.16)
    // =========================================================================
    reg signed [63:0] mul_q16;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_q16 <= 64'd0;
        end else begin
            mul_q16 <= $signed(b_res) * $signed(param_A);
        end
    end

    // =========================================================================
    // Stage 4 : 부분 합산  out_val_pre = mul_q16[31:0] + param_B
    //   · sc_val 덧셈을 Stage5로 분리하여 타이밍 위반 해소
    //   · 기존 22레벨 단일 경로 → Stage4(≤11레벨) + Stage5(≤5레벨) 분리
    // =========================================================================
    reg signed [31:0] out_val_pre;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_val_pre <= 32'd0;
        end else begin
            out_val_pre <= mul_q16[31:0] + param_B;
        end
    end

    // =========================================================================
    // Stage 5 : sc_val 합산
    //   out_val = out_val_pre + sc_val   (Q15.16)
    //   · sc_val 은 in_vld 이후 최소 5클럭 동안 안정 유지 필요
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_val <= 32'd0;
        end else begin
            out_val <= out_val_pre + sc_val;
        end
    end

    // =========================================================================
    // 유효 신호 파이프라인 (5클럭 지연)
    //   vld_pipe : [0]=T+1, [1]=T+2, [2]=T+3, [3]=T+4, [4]=T+5
    //   out_vld  = vld_pipe[4] → out_val 등록과 동일 클럭에 1이 됨
    // =========================================================================
    reg [4:0] vld_pipe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vld_pipe <= 5'd0;
        else
            vld_pipe <= {vld_pipe[3:0], in_vld};
    end

    assign out_vld = vld_pipe[4];

    // =========================================================================
    // 이진화 출력
    //   out_val[31] = 1 → 음수 → out_bit = 0
    //   out_val[31] = 0 → 0 이상 → out_bit = 1
    // =========================================================================
    assign out_bit = ~out_val[31];

endmodule
