`timescale 1ns / 1ps
// =============================================================================
// [MODULE] Stage2_Engine.v
// [VERSION] 64-bit 2-Core SIMD + B3 Swap (MUX-free)
// -----------------------------------------------------------------------------
// - ARCHITECTURE: 2-Core SIMD 64-bit Asymmetric BRAM (32-bit Write / 64-bit Read)
// - B3 Pass1: Register swap approach (0 MUX LUTs, +36 cycles/pixel)
// - Adder tree with pipeline registers (sc_b2_r, sc_b3_r)
// - 2-Channel Data Interleaving: [Ch0_w0, Ch1_w0, Ch0_w1, Ch1_w1, ...]
// =============================================================================

module Stage2_Engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_run,
    input  wire        frame_ready,
    output reg         o_done,
    output reg         o_idle,
    output reg         clear_frame_ready,

    // 64-bit 비대칭 BRAM 읽기 버스 (BIN, PARA) + 32-bit SC (INT16 packed)
    output reg  [31:0] rd_addr_bin,   input  wire [63:0]  rd_data_bin,
    output reg  [31:0] rd_addr_sc,    input  wire [31:0]  rd_data_sc,    // INT16×2 packed
    output reg  [31:0] rd_addr_feat,  input  wire [31:0]  rd_data_feat, // 특징맵 32-bit
    output reg  [31:0] rd_addr_para,  input  wire [63:0]  rd_data_para,
    output reg  [31:0] rd_addr_head,  input  wire [31:0]  rd_data_head, // HEAD 32-bit

    output reg  [31:0] wr_addr_feat,  output wire [31:0]  wr_data_feat,
    output reg  [3:0]  wr_we_feat,

    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast
);

    // 64-bit 주소 체계 (2-word 단위)
    localparam [31:0] B2_BIN_BASE = 32'd0;
    localparam [31:0] B3_BIN_BASE = 32'd1152;  // 2304 / 2
    localparam [31:0] B2_SC_BASE  = 32'd0;
    localparam [31:0] B3_SC_BASE  = 32'd4096;  // 8192 / 2
    localparam [31:0] WEFF2_BASE  = 32'd0;
    localparam [31:0] BEFF2_BASE  = 32'd64;    // 128 / 2
    localparam [31:0] WEFF3_BASE  = 32'd128;   // 256 / 2
    localparam [31:0] BEFF3_BASE  = 32'd256;   // 512 / 2

    // 6-bit 상태 인코딩 (B3_SWAP_FWD=31, B3_SWAP_BACK=32 추가)
    localparam [5:0]
        IDLE=0, WAIT_F=1, B2_PARA_RD=2, B2_WT_LOAD=3, B2_SC_LOAD=4,
        B2_WIN_LOAD=5, B2_BNN_ISSUE=6, B2_BNN_WAIT=7, B2_RD_MEM=8, B2_WR_MEM=9, B2_MAXPOOL=10,
        B3_OC_INIT=11, B3_PARA_RD=12, B3_WT0_LOAD=13, B3_WT1_LOAD=14, B3_SC_LOAD=15,
        B3_WIN0_LOAD=16, B3_P0_ISSUE=17, B3_P0_WAIT=18, B3_WIN1_LOAD=19, B3_P1_ISSUE=20,
        B3_P1_WAIT=21, B3_RD_MEM=22, B3_WR_MEM=23, B3_MAXPOOL=24,
        HEAD_INIT=25, HEAD_FEAT_LOAD=26, HEAD_WT_LOAD=27, HEAD_SEND=28, DONE_ST=29, B2_OC_INIT=30,
        B3_SWAP_FWD=31, B3_SWAP_BACK=32;

    assign wr_data_feat = 32'd0;
    genvar c_idx, g_idx;

    // --- 내부 메모리 (변경 없음) ---
    reg         b2_wea;      reg  [13:0] b2_addra;      reg  [31:0] b2_dina;
    reg  [13:0] b2_rd_addr;  wire [31:0] b2_rd_data;
    bram_b2 u_b2_mem (.clka(clk), .ena(1'b1), .wea(b2_wea), .addra(b2_addra), .dina(b2_dina), .clkb(clk), .enb(1'b1), .addrb(b2_rd_addr), .doutb(b2_rd_data));

    reg         b2pool_wea;  reg  [11:0] b2pool_addra;  reg  [31:0] b2pool_dina;
    reg  [11:0] b2p_rd_addr; wire [31:0] b2p_rd_data;
    bram_b2pool u_b2pool_mem (.clka(clk), .ena(1'b1), .wea(b2pool_wea), .addra(b2pool_addra), .dina(b2pool_dina), .clkb(clk), .enb(1'b1), .addrb(b2p_rd_addr), .doutb(b2p_rd_data));

    // --- 2-CORE SIMD 레지스터 (c2/c3 제거) ---
    reg signed [31:0] weff_cur0, weff_cur1;
    reg signed [31:0] beff_cur0, beff_cur1;

    reg [31:0] wt_regs_c0 [0:17]; reg [31:0] wt_regs_c1 [0:17];
    reg [31:0] wt_p1_c0   [0:17]; reg [31:0] wt_p1_c1   [0:17];

    reg signed [31:0] sc_regs_c0 [0:63];  reg signed [31:0] sc_regs_c1 [0:63];
    reg signed [31:0] sc_b3_c0   [0:127]; reg signed [31:0] sc_b3_c1   [0:127];

    reg [31:0] win_buf    [0:17];
    reg [31:0] win_buf_p1 [0:17];

    // --- B3 Swap용 SC 저장 레지스터 ---
    reg signed [31:0] saved_sc_b3 [0:1];

    // =========================================================================
    // [핵심] 가산기 트리 파이프라이닝 (2-Core)
    // =========================================================================
    wire signed [31:0] b2_s0 [0:1][0:63]; wire signed [31:0] b2_s1 [0:1][0:31]; reg signed  [31:0] b2_r1 [0:1][0:31]; // 파이프라인 1
    wire signed [31:0] b2_s2 [0:1][0:15]; wire signed [31:0] b2_s3 [0:1][0:7];  reg signed  [31:0] b2_r3 [0:1][0:7];  // 파이프라인 2
    wire signed [31:0] b2_s4 [0:1][0:3];  wire signed [31:0] b2_s5 [0:1][0:1];  reg  signed [31:0] b2_r5 [0:1][0:1];   // 파이프라인 3
    wire signed [31:0] sc_b2 [0:1]; reg signed [31:0] sc_b2_r [0:1];                                            // 파이프라인 4

    wire signed [31:0] b3_s0 [0:1][0:127]; wire signed [31:0] b3_s1 [0:1][0:63]; reg signed  [31:0] b3_r1 [0:1][0:63]; // 파이프라인 1
    wire signed [31:0] b3_s2 [0:1][0:31];  wire signed [31:0] b3_s3 [0:1][0:15]; reg signed  [31:0] b3_r3 [0:1][0:15]; // 파이프라인 2
    wire signed [31:0] b3_s4 [0:1][0:7];   wire signed [31:0] b3_s5 [0:1][0:3];  reg signed  [31:0] b3_r5 [0:1][0:3];  // 파이프라인 3
    wire signed [31:0] b3_s6 [0:1][0:1];   wire signed [31:0] sc_b3 [0:1]; reg signed [31:0] sc_b3_r [0:1]; // 파이프라인 4

    generate
        for (c_idx = 0; c_idx < 2; c_idx = c_idx + 1) begin : CORE_TREES
            // --- Block 2 Tree (64-element) ---
            for (g_idx = 0; g_idx < 32; g_idx = g_idx + 1) begin : B2S0_GEN
                assign b2_s0[c_idx][g_idx]    = win_buf[8][g_idx]    ? (c_idx==0 ? sc_regs_c0[g_idx]    : sc_regs_c1[g_idx])    : -(c_idx==0 ? sc_regs_c0[g_idx]    : sc_regs_c1[g_idx]);
                assign b2_s0[c_idx][32+g_idx] = win_buf[9][g_idx]    ? (c_idx==0 ? sc_regs_c0[32+g_idx] : sc_regs_c1[32+g_idx]) : -(c_idx==0 ? sc_regs_c0[32+g_idx] : sc_regs_c1[32+g_idx]);
            end
            for (g_idx = 0; g_idx < 32; g_idx = g_idx + 1) begin : B2S1_GEN assign b2_s1[c_idx][g_idx] = b2_s0[c_idx][2*g_idx] + b2_s0[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 32; g_idx = g_idx + 1) begin : B2R1_GEN always @(posedge clk) b2_r1[c_idx][g_idx] <= b2_s1[c_idx][g_idx]; end
            for (g_idx = 0; g_idx < 16; g_idx = g_idx + 1) begin : B2S2_GEN assign b2_s2[c_idx][g_idx] = b2_r1[c_idx][2*g_idx] + b2_r1[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 8;  g_idx = g_idx + 1) begin : B2S3_GEN assign b2_s3[c_idx][g_idx] = b2_s2[c_idx][2*g_idx] + b2_s2[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 8;  g_idx = g_idx + 1) begin : B2R3_GEN always @(posedge clk) b2_r3[c_idx][g_idx] <= b2_s3[c_idx][g_idx]; end
            for (g_idx = 0; g_idx < 4;  g_idx = g_idx + 1) begin : B2S4_GEN assign b2_s4[c_idx][g_idx] = b2_r3[c_idx][2*g_idx] + b2_r3[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 2;  g_idx = g_idx + 1) begin : B2S5_GEN assign b2_s5[c_idx][g_idx] = b2_s4[c_idx][2*g_idx] + b2_s4[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 2;  g_idx = g_idx + 1) begin : B2R5_GEN always @(posedge clk) b2_r5[c_idx][g_idx] <= b2_s5[c_idx][g_idx]; end // 파이프라인 3
            assign sc_b2[c_idx] = b2_r5[c_idx][0] + b2_r5[c_idx][1];
            always @(posedge clk) sc_b2_r[c_idx] <= sc_b2[c_idx]; // 파이프라인 4

            // --- Block 3 Tree (128-element) ---
            for (g_idx = 0; g_idx < 32; g_idx = g_idx + 1) begin : B3S0_GEN
                assign b3_s0[c_idx][g_idx]    = win_buf[8][g_idx]    ? (c_idx==0 ? sc_b3_c0[g_idx]    : sc_b3_c1[g_idx])    : -(c_idx==0 ? sc_b3_c0[g_idx]    : sc_b3_c1[g_idx]);
                assign b3_s0[c_idx][32+g_idx] = win_buf[9][g_idx]    ? (c_idx==0 ? sc_b3_c0[32+g_idx] : sc_b3_c1[32+g_idx]) : -(c_idx==0 ? sc_b3_c0[32+g_idx] : sc_b3_c1[32+g_idx]);
                assign b3_s0[c_idx][64+g_idx] = win_buf_p1[8][g_idx] ? (c_idx==0 ? sc_b3_c0[64+g_idx] : sc_b3_c1[64+g_idx]) : -(c_idx==0 ? sc_b3_c0[64+g_idx] : sc_b3_c1[64+g_idx]);
                assign b3_s0[c_idx][96+g_idx] = win_buf_p1[9][g_idx] ? (c_idx==0 ? sc_b3_c0[96+g_idx] : sc_b3_c1[96+g_idx]) : -(c_idx==0 ? sc_b3_c0[96+g_idx] : sc_b3_c1[96+g_idx]);
            end
            for (g_idx = 0; g_idx < 64; g_idx = g_idx + 1) begin : B3S1_GEN assign b3_s1[c_idx][g_idx] = b3_s0[c_idx][2*g_idx] + b3_s0[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 64; g_idx = g_idx + 1) begin : B3R1_GEN always @(posedge clk) b3_r1[c_idx][g_idx] <= b3_s1[c_idx][g_idx]; end
            for (g_idx = 0; g_idx < 32; g_idx = g_idx + 1) begin : B3S2_GEN assign b3_s2[c_idx][g_idx] = b3_r1[c_idx][2*g_idx] + b3_r1[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 16; g_idx = g_idx + 1) begin : B3S3_GEN assign b3_s3[c_idx][g_idx] = b3_s2[c_idx][2*g_idx] + b3_s2[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 16; g_idx = g_idx + 1) begin : B3R3_GEN always @(posedge clk) b3_r3[c_idx][g_idx] <= b3_s3[c_idx][g_idx]; end
            for (g_idx = 0; g_idx < 8;  g_idx = g_idx + 1) begin : B3S4_GEN assign b3_s4[c_idx][g_idx] = b3_r3[c_idx][2*g_idx] + b3_r3[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 4;  g_idx = g_idx + 1) begin : B3S5_GEN assign b3_s5[c_idx][g_idx] = b3_s4[c_idx][2*g_idx] + b3_s4[c_idx][2*g_idx+1]; end
            for (g_idx = 0; g_idx < 4;  g_idx = g_idx + 1) begin : B3R5_GEN always @(posedge clk) b3_r5[c_idx][g_idx] <= b3_s5[c_idx][g_idx]; end
            for (g_idx = 0; g_idx < 2;  g_idx = g_idx + 1) begin : B3S6_GEN assign b3_s6[c_idx][g_idx] = b3_r5[c_idx][2*g_idx] + b3_r5[c_idx][2*g_idx+1]; end
            assign sc_b3[c_idx] = b3_s6[c_idx][0] + b3_s6[c_idx][1];
            always @(posedge clk) sc_b3_r[c_idx] <= sc_b3[c_idx]; // 파이프라인 4
        end
    endgenerate

    // =========================================================================
    // [SECTION 5] 2-CORE INSTANCES (MUX-free 직결)
    // =========================================================================
    reg  core_vld;
    reg  [9:0] core_total_bits;
    reg  signed [31:0] c_paramA [0:1]; reg  signed [31:0] c_paramB [0:1]; reg  signed [31:0] c_sc_val [0:1];
    wire signed [31:0] c_val [0:1]; wire [0:1] c_bit; wire [0:1] c_done;
    wire [575:0] wb_buf    = {win_buf[17], win_buf[16], win_buf[15], win_buf[14], win_buf[13], win_buf[12], win_buf[11], win_buf[10], win_buf[9], win_buf[8], win_buf[7], win_buf[6], win_buf[5], win_buf[4], win_buf[3], win_buf[2], win_buf[1], win_buf[0]};
    wire [575:0] wt_flat_c0 = {wt_regs_c0[17], wt_regs_c0[16], wt_regs_c0[15], wt_regs_c0[14], wt_regs_c0[13], wt_regs_c0[12], wt_regs_c0[11], wt_regs_c0[10], wt_regs_c0[9], wt_regs_c0[8], wt_regs_c0[7], wt_regs_c0[6], wt_regs_c0[5], wt_regs_c0[4], wt_regs_c0[3], wt_regs_c0[2], wt_regs_c0[1], wt_regs_c0[0]};
    wire [575:0] wt_flat_c1 = {wt_regs_c1[17], wt_regs_c1[16], wt_regs_c1[15], wt_regs_c1[14], wt_regs_c1[13], wt_regs_c1[12], wt_regs_c1[11], wt_regs_c1[10], wt_regs_c1[9], wt_regs_c1[8], wt_regs_c1[7], wt_regs_c1[6], wt_regs_c1[5], wt_regs_c1[4], wt_regs_c1[3], wt_regs_c1[2], wt_regs_c1[1], wt_regs_c1[0]};

    BNN_Core_Unit u_core0 (.clk(clk), .rst_n(rst_n), .in_vld(core_vld), .win_bits(wb_buf), .weight_bits(wt_flat_c0), .total_bits(core_total_bits), .param_A(c_paramA[0]), .param_B(c_paramB[0]), .sc_val(c_sc_val[0]), .out_val(c_val[0]), .out_bit(c_bit[0]), .out_vld(c_done[0]));
    BNN_Core_Unit u_core1 (.clk(clk), .rst_n(rst_n), .in_vld(core_vld), .win_bits(wb_buf), .weight_bits(wt_flat_c1), .total_bits(core_total_bits), .param_A(c_paramA[1]), .param_B(c_paramB[1]), .sc_val(c_sc_val[1]), .out_val(c_val[1]), .out_bit(c_bit[1]), .out_vld(c_done[1]));

    // =========================================================================
    // [SECTION 6] FSM CONTROL
    // =========================================================================
    (* max_fanout = 64 *) reg [5:0]  state;
    (* max_fanout = 64 *) reg [9:0]  sub_cnt;
    (* max_fanout = 64 *) reg [7:0]  oc_cnt;

    reg [9:0] tot_bits_acc;
    reg [5:0] b2_row, b2_col; reg [4:0] b3_row, b3_col;
    reg valid_r, valid_rp, valid_r_d1, valid_rp_d1, valid_r_d2, valid_rp_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin valid_r_d1 <= 0; valid_rp_d1 <= 0; valid_r_d2 <= 0; valid_rp_d2 <= 0; end
        else begin valid_r_d1 <= valid_r; valid_rp_d1 <= valid_rp; valid_r_d2 <= valid_r_d1; valid_rp_d2 <= valid_rp_d1; end
    end

    wire [9:0]  hacc_ich   = sub_cnt - 10'd2;
    wire [31:0] hacc_word  = head_feat[hacc_ich[7:5]];
    wire        hacc_bit_v = hacc_word[hacc_ich[4:0]];

    reg [5:0] pos6; reg signed [6:0] kr7, kc7; reg signed [7:0] ir8, ic8; reg [6:0] irclamp, icclamp; reg bnd;
    reg [4:0] pos5; reg signed [6:0] kr7w, kc7w; reg signed [7:0] ir8w, ic8w; reg [4:0] irw, icw; reg bndw;
    reg [4:0] r_out, c_out; reg [5:0] r0, c0, r1, c1;

    reg signed [31:0] p0_val0, p0_val1;
    reg signed [31:0] final_val0, final_val1;
    reg [1:0]  out_bits_2b;
    reg [9:0]  mp_opix; reg [2:0] mp_wrd, mp_sub; reg [31:0] mp_or;
    reg [7:0]  head_pix, out_cnt;
    reg signed [31:0] head_acc0;
    reg [31:0] rmw_addr, rmw_mask_val;

    // ⭐️ [LUTRAM 최적화] async reset 제거 → 분산 RAM 추론 가능
    // 별도 always 블록 (reset 없음)으로 분리하여 Vivado가 LUTRAM으로 합성
    reg [31:0] head_feat [0:7];
    reg [31:0] head_feat_wdata; reg [2:0] head_feat_waddr; reg head_feat_we;
    always @(posedge clk) if (head_feat_we) head_feat[head_feat_waddr] <= head_feat_wdata;

    (* ram_style = "distributed" *) reg [31:0] logit_buf [0:255];
    reg [31:0] logit_buf_wdata; reg [7:0] logit_buf_waddr; reg logit_buf_we;
    always @(posedge clk) if (logit_buf_we) logit_buf[logit_buf_waddr] <= logit_buf_wdata;

    // wt_p1도 별도 블록으로 분리
    reg [31:0] wt_p1_wdata_c0, wt_p1_wdata_c1; reg [4:0] wt_p1_waddr; reg wt_p1_we;
    always @(posedge clk) if (wt_p1_we) begin wt_p1_c0[wt_p1_waddr] <= wt_p1_wdata_c0; wt_p1_c1[wt_p1_waddr] <= wt_p1_wdata_c1; end

    always @(posedge clk or negedge rst_n) begin : MAIN_FSM
        if (!rst_n) begin
            state <= IDLE; o_done <= 0; o_idle <= 1; clear_frame_ready <= 0; core_vld <= 0; core_total_bits <= 0;
            m_axis_tvalid <= 0; m_axis_tlast <= 0; wr_we_feat <= 0; wr_addr_feat <= 0; rd_addr_bin <= 0; rd_addr_sc <= 0;
            rd_addr_feat <= 0; rd_addr_para <= 0; rd_addr_head <= 0; b2_rd_addr <= 0; b2p_rd_addr <= 0; b2_wea <= 0;
            b2_addra <= 0; b2_dina <= 0; b2pool_wea <= 0; b2pool_addra <= 0; b2pool_dina <= 0; sub_cnt <= 0;
            tot_bits_acc <= 0; oc_cnt <= 0; b2_row <= 0; b2_col <= 0; b3_row <= 0; b3_col <= 0; valid_r <= 0; valid_rp <= 0;
            mp_opix <= 0; mp_wrd <= 0; mp_sub <= 0; mp_or <= 0; head_pix <= 0; out_cnt <= 0; rmw_addr <= 0; rmw_mask_val <= 0;
            m_axis_tdata <= 0; out_bits_2b <= 0; head_acc0 <= 0;

            weff_cur0 <= 0; weff_cur1 <= 0; beff_cur0 <= 0; beff_cur1 <= 0;
            p0_val0 <= 0; p0_val1 <= 0; final_val0 <= 0; final_val1 <= 0;
            c_paramA[0]<=0; c_paramA[1]<=0; c_paramB[0]<=0; c_paramB[1]<=0;
            c_sc_val[0]<=0; c_sc_val[1]<=0;
            saved_sc_b3[0] <= 0; saved_sc_b3[1] <= 0;
            head_feat_we <= 0; logit_buf_we <= 0; wt_p1_we <= 0;
        end else begin
            core_vld <= 1'b0; wr_we_feat <= 4'h0; m_axis_tvalid <= 1'b0; m_axis_tlast <= 1'b0; b2_wea <= 1'b0; b2pool_wea <= 1'b0;
            head_feat_we <= 1'b0; logit_buf_we <= 1'b0; wt_p1_we <= 1'b0;

            case (state)
            IDLE: begin o_done <= 1'b0; tot_bits_acc <= 10'd0; if (i_run) begin state <= WAIT_F; o_idle <= 1'b0; end else o_idle <= 1'b1; end
            WAIT_F: begin tot_bits_acc <= 10'd0; if (frame_ready) begin clear_frame_ready <= 1'b1; oc_cnt <= 8'd0; sub_cnt <= 10'd0; state <= B2_OC_INIT; end end
            B2_OC_INIT: begin clear_frame_ready <= 1'b0; sub_cnt <= 10'd0; b2_row <= 6'd0; b2_col <= 6'd0; state <= B2_PARA_RD; end

            // [64-bit] 파라미터 2번 읽기로 2채널 동시 로드
            B2_PARA_RD: begin
                if (sub_cnt == 0) rd_addr_para <= WEFF2_BASE + {24'd0, oc_cnt[7:1]};
                if (sub_cnt == 1) rd_addr_para <= BEFF2_BASE + {24'd0, oc_cnt[7:1]};
                if (sub_cnt == 2) {weff_cur1, weff_cur0} <= rd_data_para;
                if (sub_cnt == 3) begin {beff_cur1, beff_cur0} <= rd_data_para; sub_cnt <= 10'd0; state <= B2_WT_LOAD; end
                else sub_cnt <= sub_cnt + 10'd1;
            end

            // [64-bit] 가중치 18번 읽기로 2채널 동시 로드
            B2_WT_LOAD: begin
                if (sub_cnt < 18) rd_addr_bin <= B2_BIN_BASE + ({24'd0, oc_cnt[7:1]} * 18) + sub_cnt;
                if (sub_cnt >= 2 && sub_cnt <= 19) begin
                    wt_regs_c0[sub_cnt-2] <= rd_data_bin[31:0];
                    wt_regs_c1[sub_cnt-2] <= rd_data_bin[63:32];
                end
                if (sub_cnt == 19) begin sub_cnt <= 10'd0; state <= B2_SC_LOAD; end else sub_cnt <= sub_cnt + 10'd1;
            end

            // [INT16 packed] 숏컷 스케일 64번 읽기로 2채널 동시 로드
            B2_SC_LOAD: begin
                if (sub_cnt < 64) rd_addr_sc <= B2_SC_BASE + ({24'd0, oc_cnt[7:1]} * 64) + sub_cnt;
                if (sub_cnt >= 2 && sub_cnt <= 65) begin
                    sc_regs_c0[sub_cnt-2] <= {{16{rd_data_sc[15]}},  rd_data_sc[15:0]};   // INT16 sign-extend
                    sc_regs_c1[sub_cnt-2] <= {{16{rd_data_sc[31]}},  rd_data_sc[31:16]};   // INT16 sign-extend
                end
                if (sub_cnt == 65) begin sub_cnt <= 10'd0; state <= B2_WIN_LOAD; end else sub_cnt <= sub_cnt + 10'd1;
            end

            B2_WIN_LOAD: begin
                if (sub_cnt == 0) tot_bits_acc <= 10'd0; pos6 = sub_cnt[5:1];
                case (pos6)
                    6'd0: begin kr7=-1; kc7=-1; end 6'd1: begin kr7=-1; kc7= 0; end 6'd2: begin kr7=-1; kc7= 1; end
                    6'd3: begin kr7= 0; kc7=-1; end 6'd4: begin kr7= 0; kc7= 0; end 6'd5: begin kr7= 0; kc7= 1; end
                    6'd6: begin kr7= 1; kc7=-1; end 6'd7: begin kr7= 1; kc7= 0; end 6'd8: begin kr7= 1; kc7= 1; end
                    default: begin kr7=0; kc7=0; end
                endcase
                ir8 = $signed({2'b00, b2_row}) + kr7; ic8 = $signed({2'b00, b2_col}) + kc7;
                bnd = (ir8 >= 0) && (ir8 < 64) && (ic8 >= 0) && (ic8 < 64);
                irclamp = bnd ? ir8[6:0] : 7'd0; icclamp = bnd ? ic8[6:0] : 7'd0;

                if (sub_cnt < 18) begin rd_addr_feat <= {25'd0, irclamp} * 128 + {25'd0, icclamp} * 2 + {31'd0, sub_cnt[0]}; valid_r <= bnd; end
                if (sub_cnt >= 2 && sub_cnt <= 19) begin win_buf[sub_cnt-2] <= valid_r_d1 ? rd_data_feat : 32'd0; if (valid_r_d1) tot_bits_acc <= tot_bits_acc + 10'd32; end
                if (sub_cnt == 19) begin sub_cnt <= 10'd0; state <= B2_BNN_ISSUE; end else sub_cnt <= sub_cnt + 10'd1;
            end

            B2_BNN_ISSUE: begin
                c_paramA[0] <= weff_cur0; c_paramB[0] <= beff_cur0; c_sc_val[0] <= sc_b2_r[0];
                c_paramA[1] <= weff_cur1; c_paramB[1] <= beff_cur1; c_sc_val[1] <= sc_b2_r[1];
                core_total_bits <= 10'd576; core_vld <= 1'b1; state <= B2_BNN_WAIT;
            end

            B2_BNN_WAIT: begin
                if (c_done[0]) begin
                    out_bits_2b <= {c_bit[1], c_bit[0]};
                    rmw_addr <= {18'd0, b2_row, b2_col, 2'b00} + {26'd0, oc_cnt[7:5]}; b2_rd_addr <= {b2_row, b2_col, 2'b00} + {11'd0, oc_cnt[7:5]}; rmw_mask_val <= (32'h3 << oc_cnt[4:0]);
                    state <= B2_RD_MEM;
                end
            end

            B2_RD_MEM: state <= B2_WR_MEM;
            B2_WR_MEM: begin
                b2_addra <= rmw_addr[13:0]; b2_dina <= (b2_rd_data & ~rmw_mask_val) | ({30'd0, out_bits_2b} << oc_cnt[4:0]); b2_wea <= 1'b1;
                if (b2_col < 63) begin b2_col <= b2_col + 6'd1; sub_cnt <= 10'd0; state <= B2_WIN_LOAD; end
                else if (b2_row < 63) begin b2_col <= 6'd0; b2_row <= b2_row + 6'd1; sub_cnt <= 10'd0; state <= B2_WIN_LOAD; end
                else begin b2_row <= 6'd0; b2_col <= 6'd0; if (oc_cnt < 126) begin oc_cnt <= oc_cnt + 8'd2; sub_cnt <= 10'd0; state <= B2_OC_INIT; end else begin mp_opix <= 10'd0; mp_wrd <= 3'd0; mp_sub <= 3'd0; mp_or <= 32'd0; state <= B2_MAXPOOL; end end
            end

            B2_MAXPOOL: begin
                r_out = mp_opix[9:5]; c_out = mp_opix[4:0]; r0 = {r_out, 1'b0}; c0 = {c_out, 1'b0}; r1 = {r_out, 1'b1}; c1 = {c_out, 1'b1};
                case (mp_sub)
                    3'd0: begin b2_rd_addr <= {r0, c0, 2'b00} + {11'd0, mp_wrd}; mp_sub <= 3'd1; end 3'd1: begin b2_rd_addr <= {r0, c1, 2'b00} + {11'd0, mp_wrd}; mp_sub <= 3'd2; end
                    3'd2: begin mp_or <= b2_rd_data; b2_rd_addr <= {r1, c0, 2'b00} + {11'd0, mp_wrd}; mp_sub <= 3'd3; end 3'd3: begin mp_or <= mp_or | b2_rd_data; b2_rd_addr <= {r1, c1, 2'b00} + {11'd0, mp_wrd}; mp_sub <= 3'd4; end
                    3'd4: begin mp_or <= mp_or | b2_rd_data; mp_sub <= 3'd5; end
                    3'd5: begin b2pool_addra <= {mp_opix[9:0], mp_wrd[1:0]}; b2pool_dina <= mp_or | b2_rd_data; b2pool_wea <= 1'b1; mp_or <= 32'd0; mp_sub <= 3'd0;
                        if (mp_wrd < 3) begin mp_wrd <= mp_wrd + 3'd1; end else begin mp_wrd <= 3'd0; if (mp_opix < 1023) begin mp_opix <= mp_opix + 10'd1; end else begin oc_cnt <= 8'd0; sub_cnt <= 10'd0; state <= B3_OC_INIT; end end
                    end
                endcase
            end

            B3_OC_INIT: begin sub_cnt <= 10'd0; b3_row <= 5'd0; b3_col <= 5'd0; state <= B3_PARA_RD; end

            B3_PARA_RD: begin
                if (sub_cnt == 0) rd_addr_para <= WEFF3_BASE + {24'd0, oc_cnt[7:1]};
                if (sub_cnt == 1) rd_addr_para <= BEFF3_BASE + {24'd0, oc_cnt[7:1]};
                if (sub_cnt == 2) {weff_cur1, weff_cur0} <= rd_data_para;
                if (sub_cnt == 3) begin {beff_cur1, beff_cur0} <= rd_data_para; sub_cnt <= 10'd0; state <= B3_WT0_LOAD; end
                else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_WT0_LOAD: begin
                if (sub_cnt < 18) rd_addr_bin <= B3_BIN_BASE + ({24'd0, oc_cnt[7:1]} * 36) + sub_cnt;
                if (sub_cnt >= 2 && sub_cnt <= 19) begin
                    wt_regs_c0[sub_cnt-2] <= rd_data_bin[31:0];
                    wt_regs_c1[sub_cnt-2] <= rd_data_bin[63:32];
                end
                if (sub_cnt == 19) begin sub_cnt <= 10'd0; state <= B3_WT1_LOAD; end else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_WT1_LOAD: begin
                if (sub_cnt < 18) rd_addr_bin <= B3_BIN_BASE + ({24'd0, oc_cnt[7:1]} * 36) + 18 + sub_cnt;
                if (sub_cnt >= 2 && sub_cnt <= 19) begin
                    wt_p1_we<=1'b1; wt_p1_waddr<=sub_cnt[4:0]-5'd2; wt_p1_wdata_c0<=rd_data_bin[31:0]; wt_p1_wdata_c1<=rd_data_bin[63:32];
                end
                if (sub_cnt == 19) begin sub_cnt <= 10'd0; state <= B3_SC_LOAD; end else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_SC_LOAD: begin
                if (sub_cnt < 128) rd_addr_sc <= B3_SC_BASE + ({24'd0, oc_cnt[7:1]} * 128) + sub_cnt;
                if (sub_cnt >= 2 && sub_cnt <= 129) begin
                    sc_b3_c0[sub_cnt-2] <= {{16{rd_data_sc[15]}},  rd_data_sc[15:0]};   // INT16 sign-extend
                    sc_b3_c1[sub_cnt-2] <= {{16{rd_data_sc[31]}},  rd_data_sc[31:16]};   // INT16 sign-extend
                end
                if (sub_cnt == 129) begin sub_cnt <= 10'd0; state <= B3_WIN0_LOAD; end else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_WIN0_LOAD: begin
                if (sub_cnt == 0) tot_bits_acc <= 10'd0; pos5 = sub_cnt[5:1];
                case (pos5)
                    5'd0: begin kr7w=-1; kc7w=-1; end  5'd1: begin kr7w=-1; kc7w= 0; end  5'd2: begin kr7w=-1; kc7w= 1; end
                    5'd3: begin kr7w= 0; kc7w=-1; end  5'd4: begin kr7w= 0; kc7w= 0; end  5'd5: begin kr7w= 0; kc7w= 1; end
                    5'd6: begin kr7w= 1; kc7w=-1; end  5'd7: begin kr7w= 1; kc7w= 0; end  5'd8: begin kr7w= 1; kc7w= 1; end default: begin kr7w=0; kc7w=0; end
                endcase
                ir8w = $signed({3'b000, b3_row}) + kr7w; ic8w = $signed({3'b000, b3_col}) + kc7w;
                bndw = (ir8w >= 0) && (ir8w < 32) && (ic8w >= 0) && (ic8w < 32);
                irw  = bndw ? ir8w[4:0] : 5'd0; icw  = bndw ? ic8w[4:0] : 5'd0;

                if (sub_cnt < 18) begin b2p_rd_addr <= {irw, icw, 2'b00} + {11'd0, sub_cnt[0]}; valid_rp <= bndw; end
                if (sub_cnt >= 2 && sub_cnt <= 19) begin win_buf[sub_cnt-2] <= valid_rp_d1 ? b2p_rd_data : 32'd0; if (valid_rp_d1) tot_bits_acc <= tot_bits_acc + 10'd32; end
                if (sub_cnt == 19) begin sub_cnt <= 10'd0; state <= B3_P0_ISSUE; end else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_P0_ISSUE: begin
                c_paramA[0]<=weff_cur0; c_paramB[0]<=32'sd0; c_sc_val[0]<=32'sd0;
                c_paramA[1]<=weff_cur1; c_paramB[1]<=32'sd0; c_sc_val[1]<=32'sd0;
                core_total_bits <= 10'd576; core_vld <= 1'b1; state <= B3_P0_WAIT;
            end

            B3_P0_WAIT: begin if (c_done[0]) begin p0_val0 <= c_val[0]; p0_val1 <= c_val[1]; sub_cnt <= 10'd0; state <= B3_WIN1_LOAD; end end

            B3_WIN1_LOAD: begin
                if (sub_cnt == 0) tot_bits_acc <= 10'd0; pos5 = sub_cnt[5:1];
                case (pos5)
                    5'd0: begin kr7w=-1; kc7w=-1; end  5'd1: begin kr7w=-1; kc7w= 0; end  5'd2: begin kr7w=-1; kc7w= 1; end
                    5'd3: begin kr7w= 0; kc7w=-1; end  5'd4: begin kr7w= 0; kc7w= 0; end  5'd5: begin kr7w= 0; kc7w= 1; end
                    5'd6: begin kr7w= 1; kc7w=-1; end  5'd7: begin kr7w= 1; kc7w= 0; end  5'd8: begin kr7w= 1; kc7w= 1; end default: begin kr7w=0; kc7w=0; end
                endcase
                ir8w = $signed({3'b000, b3_row}) + kr7w; ic8w = $signed({3'b000, b3_col}) + kc7w;
                bndw = (ir8w >= 0) && (ir8w < 32) && (ic8w >= 0) && (ic8w < 32);
                irw  = bndw ? ir8w[4:0] : 5'd0; icw  = bndw ? ic8w[4:0] : 5'd0;

                if (sub_cnt < 18) begin b2p_rd_addr <= {irw, icw, 2'b00} + 2 + {11'd0, sub_cnt[0]}; valid_rp <= bndw; end
                if (sub_cnt >= 2 && sub_cnt <= 19) begin win_buf_p1[sub_cnt-2] <= valid_rp_d1 ? b2p_rd_data : 32'd0; if (valid_rp_d1) tot_bits_acc <= tot_bits_acc + 10'd32; end
                if (sub_cnt == 19) begin
                    // sc_b3_r 저장 (swap 전에 안정된 값 캡처)
                    saved_sc_b3[0] <= sc_b3_r[0];
                    saved_sc_b3[1] <= sc_b3_r[1];
                    sub_cnt <= 10'd0;
                    state <= B3_SWAP_FWD;
                end else sub_cnt <= sub_cnt + 10'd1;
            end

            // ── B3 Swap Forward: wt_regs↔wt_p1 교환, win_buf_p1→win_buf 복사 (18 cycles) ──
            B3_SWAP_FWD: begin
                wt_regs_c0[sub_cnt[4:0]] <= wt_p1_c0[sub_cnt[4:0]];
                wt_regs_c1[sub_cnt[4:0]] <= wt_p1_c1[sub_cnt[4:0]];
                wt_p1_we<=1'b1; wt_p1_waddr<=sub_cnt[4:0]; wt_p1_wdata_c0<=wt_regs_c0[sub_cnt[4:0]]; wt_p1_wdata_c1<=wt_regs_c1[sub_cnt[4:0]];
                win_buf[sub_cnt[4:0]]    <= win_buf_p1[sub_cnt[4:0]];
                if (sub_cnt == 17) begin sub_cnt <= 10'd0; state <= B3_P1_ISSUE; end
                else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_P1_ISSUE: begin
                c_paramA[0]<=weff_cur0; c_paramB[0]<=beff_cur0; c_sc_val[0]<=saved_sc_b3[0];
                c_paramA[1]<=weff_cur1; c_paramB[1]<=beff_cur1; c_sc_val[1]<=saved_sc_b3[1];
                core_total_bits <= 10'd576; core_vld <= 1'b1; state <= B3_P1_WAIT;
            end

            B3_P1_WAIT: begin
                if (c_done[0]) begin
                    final_val0 <= p0_val0 + c_val[0]; final_val1 <= p0_val1 + c_val[1];
                    rmw_addr <= {22'd0, b3_row, b3_col, 3'b000} + {25'd0, oc_cnt[7:5]}; b2_rd_addr <= {1'b0, b3_row[4:0], b3_col[4:0], 3'b000} + {11'd0, oc_cnt[7:5]}; rmw_mask_val <= (32'h3 << oc_cnt[4:0]);
                    sub_cnt <= 10'd0;
                    state <= B3_SWAP_BACK;
                end
            end

            // ── B3 Swap Back: wt_regs↔wt_p1 복원 (18 cycles) ──
            B3_SWAP_BACK: begin
                wt_regs_c0[sub_cnt[4:0]] <= wt_p1_c0[sub_cnt[4:0]];
                wt_regs_c1[sub_cnt[4:0]] <= wt_p1_c1[sub_cnt[4:0]];
                wt_p1_we<=1'b1; wt_p1_waddr<=sub_cnt[4:0]; wt_p1_wdata_c0<=wt_regs_c0[sub_cnt[4:0]]; wt_p1_wdata_c1<=wt_regs_c1[sub_cnt[4:0]];
                if (sub_cnt == 17) begin state <= B3_RD_MEM; end
                else sub_cnt <= sub_cnt + 10'd1;
            end

            B3_RD_MEM: begin out_bits_2b <= {~final_val1[31], ~final_val0[31]}; state <= B3_WR_MEM; end
            B3_WR_MEM: begin
                b2_addra <= {1'b0, rmw_addr[12:0]}; b2_dina <= (b2_rd_data & ~rmw_mask_val) | ({30'd0, out_bits_2b} << oc_cnt[4:0]); b2_wea <= 1'b1;
                if (b3_col < 31) begin b3_col <= b3_col + 5'd1; sub_cnt <= 10'd0; state <= B3_WIN0_LOAD; end
                else if (b3_row < 31) begin b3_col <= 5'd0; b3_row <= b3_row + 5'd1; sub_cnt <= 10'd0; state <= B3_WIN0_LOAD; end
                else begin b3_row <= 5'd0; b3_col <= 5'd0; if (oc_cnt < 254) begin oc_cnt <= oc_cnt + 8'd2; sub_cnt <= 10'd0; state <= B3_OC_INIT; end else begin mp_opix <= 10'd0; mp_wrd <= 3'd0; mp_sub <= 3'd0; mp_or <= 32'd0; state <= B3_MAXPOOL; end end
            end

            B3_MAXPOOL: begin
                r_out = mp_opix[7:4]; c_out = mp_opix[3:0]; r0 = {r_out, 1'b0}; c0 = {c_out, 1'b0}; r1 = {r_out, 1'b1}; c1 = {c_out, 1'b1};
                case (mp_sub)
                    3'd0: begin b2_rd_addr <= {1'b0, r0[4:0], c0[4:0], 3'b000} + {11'd0, mp_wrd}; mp_sub <= 3'd1; end 3'd1: begin b2_rd_addr <= {1'b0, r0[4:0], c1[4:0], 3'b000} + {11'd0, mp_wrd}; mp_sub <= 3'd2; end
                    3'd2: begin mp_or <= b2_rd_data; b2_rd_addr <= {1'b0, r1[4:0], c0[4:0], 3'b000} + {11'd0, mp_wrd}; mp_sub <= 3'd3; end 3'd3: begin mp_or <= mp_or | b2_rd_data; b2_rd_addr <= {1'b0, r1[4:0], c1[4:0], 3'b000} + {11'd0, mp_wrd}; mp_sub <= 3'd4; end
                    3'd4: begin mp_or <= mp_or | b2_rd_data; mp_sub <= 3'd5; end
                    3'd5: begin b2pool_addra <= {1'b0, mp_opix[7:0], mp_wrd}; b2pool_dina <= mp_or | b2_rd_data; b2pool_wea <= 1'b1; mp_or <= 32'd0; mp_sub <= 3'd0;
                        if (mp_wrd < 7) begin mp_wrd <= mp_wrd + 3'd1; end else begin mp_wrd <= 3'd0; if (mp_opix < 255) begin mp_opix <= mp_opix + 10'd1; end else begin head_pix <= 8'd0; sub_cnt <= 10'd0; state <= HEAD_INIT; end end
                    end
                endcase
            end

            // ── HEAD 1-pixel 순차 처리 (변경 없음) ──────────────────────────────
            HEAD_INIT: begin head_pix <= 8'd0; sub_cnt <= 10'd0; state <= HEAD_FEAT_LOAD; end

            HEAD_FEAT_LOAD: begin
                if (sub_cnt < 8) b2p_rd_addr <= {1'b0, head_pix[7:0], 3'b000} + {9'd0, sub_cnt[2:0]};
                if (sub_cnt >= 2 && sub_cnt <= 9) begin head_feat_we<=1'b1; head_feat_waddr<=sub_cnt[2:0]-3'd2; head_feat_wdata<=b2p_rd_data; end
                if (sub_cnt == 9) begin sub_cnt <= 10'd0; head_acc0 <= 32'sd0; state <= HEAD_WT_LOAD; end
                else sub_cnt <= sub_cnt + 10'd1;
            end

            HEAD_WT_LOAD: begin
                if (sub_cnt <= 256) rd_addr_head <= {23'd0, sub_cnt[8:0]};
                if (sub_cnt >= 2 && sub_cnt <= 257)
                    head_acc0 <= head_acc0 + (hacc_bit_v ? $signed(rd_data_head) : -$signed(rd_data_head));
                if (sub_cnt == 258) begin
                    logit_buf_we<=1'b1; logit_buf_waddr<=head_pix; logit_buf_wdata<=head_acc0+$signed(rd_data_head);
                    sub_cnt <= 10'd0;
                    if (head_pix < 255) begin head_pix <= head_pix + 8'd1; state <= HEAD_FEAT_LOAD; end
                    else begin out_cnt <= 8'd0; state <= HEAD_SEND; end
                end else sub_cnt <= sub_cnt + 10'd1;
            end

            HEAD_SEND: begin
                if (m_axis_tready || !m_axis_tvalid) begin
                    m_axis_tdata <= logit_buf[out_cnt]; m_axis_tvalid <= 1'b1; m_axis_tlast <= (out_cnt == 255);
                    if (out_cnt == 255) state <= DONE_ST; else out_cnt <= out_cnt + 8'd1;
                end
            end
            DONE_ST: begin o_done <= 1'b1; o_idle <= 1'b1; if (!i_run) state <= IDLE; end
            default: state <= IDLE;
            endcase
        end
    end
endmodule