`timescale 1ns / 1ps
// =============================================================================
// Stage1_Engine.v
// [최종 타이밍 최적화] DSP 파이프라이닝 및 비트 폭 매핑 완결판
// =============================================================================

module Stage1_Engine (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_start,
    output reg         o_done,
    output reg         o_idle,

    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire        s_axis_tlast,

    output wire [10:0] l1_w_rd_addr,       
    input  wire [15:0] l1_w_rd_data,       

    output reg  [11:0] b1_rd_addr,
    input  wire [31:0] b1_rd_data,
    output reg  [11:0] b1_rd_addr_b,
    input  wire [31:0] b1_rd_data_b,

    output reg  [12:0] feat_wr_addr,
    output reg  [31:0] feat_wr_data,
    output reg  [3:0]  feat_wr_we
);

    localparam B1_BN1_W = 12'd0, B1_BN1_B = 12'd32, B1_BN1_M = 12'd64, B1_BN1_VINV = 12'd96;
    localparam B1_BCONV = 12'd128, B1_ALPHA = 12'd704;
    localparam B1_BN2_W = 12'd768, B1_BN2_B = 12'd832, B1_BN2_M = 12'd896, B1_BN2_VINV = 12'd960;
    localparam B1_SC1   = 12'd1024;

    integer ii;

    // ⭐️ 파이프라인 딜레이(WAIT) 수용을 위한 FSM 상태 추가
    localparam [5:0]
        IDLE        = 0,  IMG_FILL    = 1,  IMG_REFILL  = 2,  PHASE_SEL   = 3,
        L1_W_LOAD   = 4,  L1_BN_LOAD  = 5,  L1_PX_LOAD  = 6,  L1_CONV_REG = 7,
        L1_BN_S1    = 8,  L1_BN_S2    = 9,  L1_NEXT_PX  = 10, L1_NEXT_CH  = 11,
        L1_ROW_DONE = 12,
        B1_PX_START = 13, B1_WIN_LOAD = 14, B1_OC_START = 15, B1_BCV_LOAD_P1 = 16,
        B1_BCV_CALC = 17, B1_SC_CALC  = 18, B1_BN_CALC  = 19, B1_STORE    = 20,
        B1_NEXT_PX  = 21, B1_ROW_DONE = 22, MP_ROW      = 23, WR_FEAT     = 24,
        DONE_ST     = 25, L1_CONV_PIPE1 = 26,
        L1_BN_S3    = 27, B1_SC_MUL   = 28, L1_BN_S1B   = 29,
        L1_BN_S1C   = 30, L1_CONV_PIPE2 = 31, L1_CONV_PIPE3 = 32,
        B1_BCV_LOAD_P2 = 33,
        // 신규 파이프라인 대기 상태들
        L1_BN_S1D   = 34, L1_BN_S1E   = 35, L1_BN_S2B   = 36, L1_BN_S2C   = 37,
        B1_SC_MUL_WAIT = 38, B1_SC_MUL_RD = 39;

    reg [5:0] state;
    reg [4:0] sub;

    (* ram_style = "distributed" *) reg [2:0] mod7 [0:255];
    // ⭐️ 픽셀 정규화 LUT: PS와 동일한 (pixel<<16)/127 - 65536 → [-1.0, +1.008] Q15.16
    // 최대값 66052 → 18-bit signed 필요 (17-bit는 pixel 254-255에서 오버플로우!)
    (* ram_style = "distributed" *) reg signed [17:0] px_norm_lut [0:255];
    integer _p;
    initial for (_p = 0; _p < 256; _p = _p + 1) begin
        mod7[_p] = _p % 7;
        px_norm_lut[_p] = (_p * 65536) / 127 - 65536;
    end

    function [1:0] fn_mod3;
        input [3:0] v;
        begin
            if (v >= 6) fn_mod3 = v - 4'd6;
            else if (v >= 3) fn_mod3 = v - 4'd3;
            else fn_mod3 = v[1:0];
        end
    endfunction

    reg [7:0]  l1_r, l1_c; 
    reg [7:0]  l1_rows_done;
    reg [7:0]  b1_r, b1_c; 
    reg [7:0]  b1_rows_done;
    reg [4:0]  l1_ch; 

    wire [8:0] ir [0:6]; genvar gk; generate for (gk = 0; gk < 7; gk = gk + 1) begin : IR_COORD assign ir[gk] = (l1_r * 2) + gk - 9'd3; end endgenerate
    wire [8:0] ic [0:6]; generate for (gk = 0; gk < 7; gk = gk + 1) begin : IC_COORD assign ic[gk] = (l1_c * 2) + gk - 9'd3; end endgenerate
    wire ir_in_bounds [0:6]; generate for (gk = 0; gk < 7; gk = gk + 1) begin : IR_BND assign ir_in_bounds[gk] = (ir[gk] < 9'd256); end endgenerate
    wire [2:0] row_map [0:6]; generate for (gk = 0; gk < 7; gk = gk + 1) begin : RMAP assign row_map[gk] = mod7[ir[gk][7:0]]; end endgenerate

    reg [2:0]  lb_wr_slot; reg [7:0]  lb_wr_col; reg [8:0]  lb_rows_loaded; wire [7:0] lb_dout [0:6];
    wire [7:0] lb_rd_col = (state == L1_PX_LOAD && sub < 7) ? ic[sub][7:0] : 8'd0;
    wire lb_write_cond = (state == IMG_FILL || state == IMG_REFILL) && s_axis_tvalid && s_axis_tready;
    wire lb_wr_valid = (lb_wr_col < 64);
    
    wire [6:0] lb_we;
    assign lb_we[0] = lb_write_cond && (lb_wr_slot == 3'd0) && lb_wr_valid;
    assign lb_we[1] = lb_write_cond && (lb_wr_slot == 3'd1) && lb_wr_valid;
    assign lb_we[2] = lb_write_cond && (lb_wr_slot == 3'd2) && lb_wr_valid;
    assign lb_we[3] = lb_write_cond && (lb_wr_slot == 3'd3) && lb_wr_valid;
    assign lb_we[4] = lb_write_cond && (lb_wr_slot == 3'd4) && lb_wr_valid;
    assign lb_we[5] = lb_write_cond && (lb_wr_slot == 3'd5) && lb_wr_valid;
    assign lb_we[6] = lb_write_cond && (lb_wr_slot == 3'd6) && lb_wr_valid;

    bram_lb u_lb_0 ( .clka(clk), .ena(1'b1), .wea(lb_we[0]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[0]) );
    bram_lb u_lb_1 ( .clka(clk), .ena(1'b1), .wea(lb_we[1]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[1]) );
    bram_lb u_lb_2 ( .clka(clk), .ena(1'b1), .wea(lb_we[2]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[2]) );
    bram_lb u_lb_3 ( .clka(clk), .ena(1'b1), .wea(lb_we[3]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[3]) );
    bram_lb u_lb_4 ( .clka(clk), .ena(1'b1), .wea(lb_we[4]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[4]) );
    bram_lb u_lb_5 ( .clka(clk), .ena(1'b1), .wea(lb_we[5]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[5]) );
    bram_lb u_lb_6 ( .clka(clk), .ena(1'b1), .wea(lb_we[6]), .addra(lb_wr_col[5:0]), .dina(s_axis_tdata), .clkb(clk), .enb(1'b1), .addrb(lb_rd_col), .doutb(lb_dout[6]) );

    reg [7:0] px_from_bram [0:6];
    wire signed [17:0] px_norm [0:6]; // 정규화된 픽셀 (Q15.16, 18-bit signed)
    always @(*) begin
        for (ii = 0; ii < 7; ii = ii + 1) begin
            case (row_map[ii])
                3'd0: px_from_bram[ii] = lb_dout[0]; 3'd1: px_from_bram[ii] = lb_dout[1]; 3'd2: px_from_bram[ii] = lb_dout[2];
                3'd3: px_from_bram[ii] = lb_dout[3]; 3'd4: px_from_bram[ii] = lb_dout[4]; 3'd5: px_from_bram[ii] = lb_dout[5];
                3'd6: px_from_bram[ii] = lb_dout[6]; default: px_from_bram[ii] = 8'd0;
            endcase
        end
    end
    generate for (gk = 0; gk < 7; gk = gk + 1) begin : PX_NORM
        assign px_norm[gk] = px_norm_lut[px_from_bram[gk]];
    end endgenerate

    // ─────────────────────────────────────────────────────────────────────────
    // ⭐️ [신규] 명시적 DSP 파이프라인 (Input Reg -> Mult -> Output Reg)
    // ─────────────────────────────────────────────────────────────────────────
    
    // 1. SC Multiplier: 32x16 -> 48-bit 전용 레지스터 (fb_dout는 Q15.16 전체 필요)
    reg signed [31:0] sc_in_a1, sc_in_b1;
    reg signed [15:0] sc_in_a2, sc_in_b2;
    reg signed [47:0] sc_out_a, sc_out_b;

    always @(posedge clk) begin
        sc_out_a <= sc_in_a1 * sc_in_a2;
        sc_out_b <= sc_in_b1 * sc_in_b2;
    end

    // 2. L1 & B1 공유 BN Multiplier: 32x32 -> 64-bit 전용 레지스터
    reg signed [31:0] bn_in_a1, bn_in_a2;
    reg signed [31:0] bn_in_b1, bn_in_b2;
    reg signed [63:0] bn_out_a, bn_out_b;

    always @(posedge clk) begin
        bn_out_a <= bn_in_a1 * bn_in_a2;
        bn_out_b <= bn_in_b1 * bn_in_b2;
    end

    // ─────────────────────────────────────────────────────────────────────────

    reg signed [31:0] l1_acc; reg signed [31:0] bn1_w_r, bn1_b_r, bn1_m_r, bn1_vi_r;
    reg signed [31:0] l1_nv_r; reg signed [63:0] l1_raw; reg signed [15:0] w_reg [0:48]; reg [5:0] w_tap;
    reg signed [17:0] px_r [0:48]; // ⭐️ 18-bit signed (정규화된 Q15.16 픽셀, max 66052)
    reg px_ic_valid_d;

    assign l1_w_rd_addr = (state == L1_W_LOAD) ? ((sub == 0) ? {l1_ch, 6'd0} : {l1_ch, w_tap + 6'd1}) : 11'd0;

    // ⭐️ 18-bit pixel × 16-bit weight = 34-bit product (Q30.32)
    // 49개 합산: 최대 40-bit 필요 → 전체 40-bit로 통일
    reg signed [39:0] prod_r [0:48]; wire signed [39:0] s1 [0:24]; wire signed [39:0] s2 [0:12]; reg signed [39:0] s2_r [0:12];
    wire signed [39:0] s3 [0:6]; reg signed [39:0] s4_r [0:3];
    always @(posedge clk) begin
        for (ii = 0; ii < 49; ii = ii + 1) prod_r[ii] <= px_r[ii] * $signed(w_reg[ii]);
        for (ii = 0; ii < 13; ii = ii + 1) s2_r[ii]   <= s2[ii];
        s4_r[0] <= s3[0]+s3[1]; s4_r[1] <= s3[2]+s3[3]; s4_r[2] <= s3[4]+s3[5]; s4_r[3] <= s3[6];
    end
    generate for (gk = 0; gk < 24; gk = gk + 1) begin : S1 assign s1[gk] = prod_r[gk*2] + prod_r[gk*2+1]; end endgenerate assign s1[24] = prod_r[48];
    generate for (gk = 0; gk < 12; gk = gk + 1) begin : S2 assign s2[gk] = s1[gk*2] + s1[gk*2+1]; end endgenerate assign s2[12] = s1[24];
    generate for (gk = 0; gk < 6; gk = gk + 1) begin : S3 assign s3[gk] = s2_r[gk*2] + s2_r[gk*2+1]; end endgenerate assign s3[6] = s2_r[12];
    wire signed [39:0] l1_tree = (s4_r[0] + s4_r[1]) + (s4_r[2] + s4_r[3]);

    reg fb_we; reg [13:0] fb_wr_addr_r; reg signed [31:0] fb_din; wire signed [31:0] fb_dout;
    reg [1:0] fb_wr_slot; reg [6:0] fb_count; reg fb_oob_r; reg [1:0] sc_cslot_r; reg [13:0] fb_rd_addr_w;
    wire fb_wr_valid = (fb_wr_addr_r < 12288);

    bram_fb u_fb_mem (.clka(clk), .ena(1'b1), .wea(fb_we && fb_wr_valid), .addra(fb_wr_addr_r), .dina(fb_din), .clkb(clk), .enb(1'b1), .addrb(fb_rd_addr_w), .doutb(fb_dout));

    reg [4:0] b1_oc; reg [3:0] b1_kp; reg [4:0] b1_ic;
    (* ram_style = "distributed" *) reg signed [31:0] b1_win [0:8][0:31];
    reg signed [31:0] b1_conv_acc, b1_conv_acc_b; reg signed [63:0] b1_sc_acc, b1_sc_acc_b;
    reg signed [31:0] b1_alpha_r, b1_bw2_r, b1_bb2_r, b1_bm2_r, b1_bv2_r; reg signed [31:0] b1_alpha_b, b1_bw2_b, b1_bb2_b, b1_bm2_b, b1_bv2_b;
    reg signed [31:0] b1_out_val, b1_out_val_b; 
    reg signed [31:0] bn_sc_a, bn_sc_b; reg signed [31:0] bn_nv_a, bn_nv_b; reg signed [63:0] bn_raw_a, bn_raw_b;
    reg signed [31:0] bwin_mux_0 [0:31], bwin_mux_1 [0:31], bwin_mux_2 [0:31]; reg [31:0] bconv_bits_a_pre, bconv_bits_b_pre;
    reg signed [31:0] bwin_sel [0:31]; reg [31:0] bconv_bits_a, bconv_bits_b;


    reg signed [31:0] bcv_stage0_a [0:31], bcv_stage0_b [0:31]; reg signed [31:0] bcv_stage1_a [0:15], bcv_stage1_b [0:15]; 
    reg signed [31:0] bcv_stage2_a [0:7],  bcv_stage2_b [0:7];  reg signed [31:0] bcv_stage3_a [0:3],  bcv_stage3_b [0:3];  
    reg signed [31:0] bcv_stage4_a [0:1],  bcv_stage4_b [0:1];  reg signed [31:0] bcv_tree_out_a,       bcv_tree_out_b;     

    always @(posedge clk) begin
        for (ii=0; ii<32; ii=ii+1) begin bcv_stage0_a[ii] <= bconv_bits_a[ii]?bwin_sel[ii]:-bwin_sel[ii]; bcv_stage0_b[ii] <= bconv_bits_b[ii]?bwin_sel[ii]:-bwin_sel[ii]; end
        for (ii=0; ii<16; ii=ii+1) begin bcv_stage1_a[ii] <= bcv_stage0_a[ii*2]+bcv_stage0_a[ii*2+1]; bcv_stage1_b[ii] <= bcv_stage0_b[ii*2]+bcv_stage0_b[ii*2+1]; end
        for (ii=0; ii<8; ii=ii+1)  begin bcv_stage2_a[ii] <= bcv_stage1_a[ii*2]+bcv_stage1_a[ii*2+1]; bcv_stage2_b[ii] <= bcv_stage1_b[ii*2]+bcv_stage1_b[ii*2+1]; end
        for (ii=0; ii<4; ii=ii+1)  begin bcv_stage3_a[ii] <= bcv_stage2_a[ii*2]+bcv_stage2_a[ii*2+1]; bcv_stage3_b[ii] <= bcv_stage2_b[ii*2]+bcv_stage2_b[ii*2+1]; end
        bcv_stage4_a[0] <= bcv_stage3_a[0]+bcv_stage3_a[1]; bcv_stage4_a[1] <= bcv_stage3_a[2]+bcv_stage3_a[3];
        bcv_stage4_b[0] <= bcv_stage3_b[0]+bcv_stage3_b[1]; bcv_stage4_b[1] <= bcv_stage3_b[2]+bcv_stage3_b[3];
        bcv_tree_out_a <= bcv_stage4_a[0]+bcv_stage4_a[1]; bcv_tree_out_b <= bcv_stage4_b[0]+bcv_stage4_b[1];
    end

    wire signed [31:0] mp_dout_a, mp_dout_b; reg mp_we_a, mp_we_b;
    reg [12:0] mp_wr_addr_a, mp_wr_addr_b; reg signed [31:0] mp_din_a, mp_din_b;
    wire [12:0] mp_addr_a = mp_we_a ? mp_wr_addr_a : mp_rd_addr_a_w; wire [12:0] mp_addr_b = mp_we_b ? mp_wr_addr_b : mp_rd_addr_b_w;
    wire mp_wr_valid_a = (mp_wr_addr_a < 8192); wire mp_wr_valid_b = (mp_wr_addr_b < 8192);

    bram_mp u_mp_mem (.clka(clk), .ena(1'b1), .wea(mp_we_a && mp_wr_valid_a), .addra(mp_addr_a), .dina(mp_din_a), .douta(mp_dout_a), .clkb(clk), .enb(1'b1), .web(mp_we_b && mp_wr_valid_b), .addrb(mp_addr_b), .dinb(mp_din_b), .doutb(mp_dout_b));

    reg [5:0] mp_c, mp_oc; reg [31:0] bp_w0, bp_w1; reg [12:0] bp_addr;
    wire [5:0] oc_e = {b1_oc, 1'b0}; wire [5:0] oc_o = {b1_oc, 1'b1};

    reg signed [31:0] l1_bo; reg fb_oob_comb; reg [3:0] fb_nkp; reg [4:0] fb_nic; reg [1:0] fb_nd3, fb_nm3;
    reg signed [8:0] fb_nwr, fb_nwc; reg [6:0] fb_noff;
    
    wire [8:0] l1_need_raw = (l1_r * 2) + 9'd4;
    wire [8:0] l1_need = (l1_need_raw > 9'd256) ? 9'd256 : l1_need_raw;
    wire b1_can_start = (b1_r > 0 && b1_r < 127) ? (fb_count >= 3) : (fb_count >= 2);

    always @(*) begin
        b1_rd_addr = 12'd0; b1_rd_addr_b = 12'd0;
        case (state)
            L1_BN_LOAD: begin case(sub) 5'd0:b1_rd_addr=B1_BN1_W+{7'd0,l1_ch}; 5'd1:b1_rd_addr=B1_BN1_B+{7'd0,l1_ch}; 5'd2:b1_rd_addr=B1_BN1_M+{7'd0,l1_ch}; 5'd3:b1_rd_addr=B1_BN1_VINV+{7'd0,l1_ch}; endcase end
            B1_OC_START: begin b1_rd_addr = B1_BCONV+{3'd0,oc_e,3'd0}+{6'd0,oc_e}; b1_rd_addr_b = B1_BCONV+{3'd0,oc_o,3'd0}+{6'd0,oc_o}; end
            B1_BCV_CALC: begin if (b1_kp == 8) begin b1_rd_addr = B1_SC1+{oc_e,5'd0}; b1_rd_addr_b = B1_SC1+{oc_o,5'd0}; end else begin b1_rd_addr = B1_BCONV+{3'd0,oc_e,3'd0}+{6'd0,oc_e}+{8'd0,b1_kp}+12'd1; b1_rd_addr_b = B1_BCONV+{3'd0,oc_o,3'd0}+{6'd0,oc_o}+{8'd0,b1_kp}+12'd1; end end
            B1_SC_CALC: begin if (b1_ic == 31) begin b1_rd_addr = B1_ALPHA+{6'd0,oc_e}; b1_rd_addr_b = B1_ALPHA+{6'd0,oc_o}; end else begin b1_rd_addr = B1_SC1+{oc_e,5'd0}+{7'd0,b1_ic}+12'd1; b1_rd_addr_b = B1_SC1+{oc_o,5'd0}+{7'd0,b1_ic}+12'd1; end end
            B1_BN_CALC: begin case(sub) 5'd0:begin b1_rd_addr=B1_BN2_W+{6'd0,oc_e}; b1_rd_addr_b=B1_BN2_W+{6'd0,oc_o}; end 5'd1:begin b1_rd_addr=B1_BN2_B+{6'd0,oc_e}; b1_rd_addr_b=B1_BN2_B+{6'd0,oc_o}; end 5'd2:begin b1_rd_addr=B1_BN2_M+{6'd0,oc_e}; b1_rd_addr_b=B1_BN2_M+{6'd0,oc_o}; end 5'd3:begin b1_rd_addr=B1_BN2_VINV+{6'd0,oc_e}; b1_rd_addr_b=B1_BN2_VINV+{6'd0,oc_o}; end endcase end
        endcase
    end

    always @(*) begin
        fb_rd_addr_w = 14'd0; fb_oob_comb = 1'b1; fb_nkp = 4'd0; fb_nic = 5'd0; fb_nd3 = 2'd0; fb_nm3 = 2'd0; fb_nwr = 9'sd0; fb_nwc = 9'sd0; fb_noff = 7'd0;
        case (state)
            B1_PX_START: begin if (b1_r == 0 || b1_c == 0) fb_oob_comb = 1'b1; else begin fb_oob_comb = 1'b0; fb_rd_addr_w = {fn_mod3({2'd0, fb_wr_slot} + 4'd3 - {1'b0, fb_count[2:0]}), b1_c[6:0] - 7'd1, 5'd0}; end end
            B1_WIN_LOAD: begin
                if (b1_ic == 31 && b1_kp == 8) fb_oob_comb = 1'b1;
                else begin
                    fb_nkp = (b1_ic == 31) ? b1_kp + 4'd1 : b1_kp; fb_nic = (b1_ic == 31) ? 5'd0 : b1_ic + 5'd1;
                    fb_nd3 = (fb_nkp >= 6) ? 2'd2 : (fb_nkp >= 3) ? 2'd1 : 2'd0; fb_nm3 = (fb_nkp >= 6) ? fb_nkp[1:0] - 2'd2 : (fb_nkp >= 3) ? fb_nkp[1:0] - 2'd3 : fb_nkp[1:0];
                    fb_nwr = $signed({1'b0, b1_r}) + $signed({7'd0, fb_nd3}) - 9'sd1; fb_nwc = $signed({1'b0, b1_c}) + $signed({7'd0, fb_nm3}) - 9'sd1;
                    if (fb_nwr < 0 || fb_nwr >= 128 || fb_nwc < 0 || fb_nwc >= 128) fb_oob_comb = 1'b1;
                    else begin fb_oob_comb = 1'b0; fb_noff = (b1_r == 0) ? fb_nwr[6:0] : fb_nd3[1:0]; fb_rd_addr_w = {fn_mod3({2'd0, fb_wr_slot} + 4'd3 - {1'b0, fb_count[2:0]} + {2'd0, fb_noff[1:0]}), fb_nwc[6:0], fb_nic}; end
                end
            end
            // SC는 b1_win[4][ic] 레지스터를 사용하므로 fb BRAM 읽기 불필요
        endcase
    end

    reg [12:0] mp_rd_addr_a_w, mp_rd_addr_b_w;
    always @(*) begin
        mp_rd_addr_a_w = 13'd0; mp_rd_addr_b_w = 13'd0;
        case (state)
            B1_BN_CALC: if (sub == 15 || sub == 16) begin mp_rd_addr_a_w = {b1_c[6:0], oc_e}; mp_rd_addr_b_w = {b1_c[6:0], oc_o}; end
            B1_ROW_DONE: if (b1_r[0] == 1) begin mp_rd_addr_a_w = {6'd0, 1'b0, 6'd0}; mp_rd_addr_b_w = {6'd0, 1'b1, 6'd0}; end
            MP_ROW: if (mp_oc < 63) begin mp_rd_addr_a_w = {mp_c, 1'b0, mp_oc + 6'd1}; mp_rd_addr_b_w = {mp_c, 1'b1, mp_oc + 6'd1}; end
            WR_FEAT: if (sub == 1 && mp_c < 63) begin mp_rd_addr_a_w = {mp_c + 6'd1, 1'b0, 6'd0}; mp_rd_addr_b_w = {mp_c + 6'd1, 1'b1, 6'd0}; end
        endcase
    end

    wire signed [31:0] w_mp_v0 = $signed(mp_dout_a);
    wire signed [31:0] w_mp_v1 = $signed(mp_dout_b);
    wire signed [31:0] w_mp_mx = (w_mp_v0 > w_mp_v1) ? w_mp_v0 : w_mp_v1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; sub<=0; o_done<=0; o_idle<=1; s_axis_tready<=0;
            lb_wr_slot<=0; lb_wr_col<=0; lb_rows_loaded<=0; px_ic_valid_d<=0;
            l1_r<=0; l1_c<=0; l1_ch<=0; l1_acc<=0; l1_rows_done<=0; l1_nv_r<=0; w_tap<=0;
            fb_wr_slot<=0; fb_count<=0; fb_we<=0; fb_wr_addr_r<=0; fb_din<=0; fb_oob_r<=1; sc_cslot_r<=0;
            b1_r<=0; b1_c<=0; b1_oc<=0; b1_kp<=0; b1_ic<=0; b1_conv_acc<=0; b1_conv_acc_b<=0;
            b1_sc_acc<=0; b1_sc_acc_b<=0; b1_out_val<=0; b1_out_val_b<=0; b1_rows_done<=0;
            bn_sc_a<=0; bn_sc_b<=0; bn_nv_a<=0; bn_nv_b<=0; mp_we_a<=0; mp_we_b<=0;
            mp_wr_addr_a<=0; mp_wr_addr_b<=0; mp_din_a<=0; mp_din_b<=0;
            feat_wr_addr<=0; feat_wr_data<=0; feat_wr_we<=0; bp_addr<=0; bp_w0<=0; bp_w1<=0; mp_c<=0; mp_oc<=0;
            bn_in_a1<=0; bn_in_a2<=0; bn_in_b1<=0; bn_in_b2<=0;
            sc_in_a1<=0; sc_in_a2<=0; sc_in_b1<=0; sc_in_b2<=0;
            for (ii = 0; ii < 49; ii = ii + 1) begin w_reg[ii] <= 16'sd0; px_r[ii]  <= 18'sd0; end
            for (ii = 0; ii < 32; ii = ii + 1) begin bwin_sel[ii] <= 0; bwin_mux_0[ii] <= 0; bwin_mux_1[ii] <= 0; bwin_mux_2[ii] <= 0; end
            bconv_bits_a <= 0; bconv_bits_b <= 0; bconv_bits_a_pre <= 0; bconv_bits_b_pre <= 0;
        end else begin
            feat_wr_we <= 4'h0; fb_we <= 1'b0; mp_we_a <= 1'b0; mp_we_b <= 1'b0;

            case (state)
            IDLE: begin
                o_idle <= 1; o_done <= 0;
                if (i_start) begin
                    o_idle<=0; s_axis_tready<=1; lb_wr_slot<=0; lb_wr_col<=0; lb_rows_loaded<=0;
                    l1_r<=0; l1_c<=0; l1_rows_done<=0; fb_wr_slot<=0; fb_count<=0; b1_r<=0; b1_rows_done<=0; bp_addr<=0;
                    state <= IMG_FILL;
                end
            end
            IMG_FILL, IMG_REFILL: begin
                if (state == IMG_REFILL && s_axis_tready == 0) s_axis_tready <= 1;
                if (s_axis_tvalid && s_axis_tready) begin
                    if (lb_wr_col == 63) begin
                        lb_wr_slot <= (lb_wr_slot == 6) ? 3'd0 : lb_wr_slot + 3'd1;
                        lb_rows_loaded <= lb_rows_loaded + 1;
                        lb_wr_col <= 0;
                        if (lb_rows_loaded + 9'd1 >= l1_need) begin s_axis_tready <= 0; state <= PHASE_SEL; end
                    end else lb_wr_col <= lb_wr_col + 1;
                end
            end
            PHASE_SEL: begin
                if (l1_rows_done >= 128 && b1_rows_done >= 128) state <= DONE_ST;
                else if (b1_rows_done < l1_rows_done && b1_can_start) begin b1_c <= 0; state <= B1_PX_START; end
                else if (l1_rows_done < 128 && lb_rows_loaded >= l1_need && fb_count < 3) begin l1_c <= 0; l1_ch <= 0; sub <= 0; w_tap <= 0; state <= L1_W_LOAD; end
                else if (l1_rows_done < 128 && lb_rows_loaded < l1_need) state <= IMG_REFILL;
            end
            L1_W_LOAD: case(sub) 0:begin w_tap<=0; sub<=1; end 1:begin w_reg[w_tap]<=$signed(l1_w_rd_data); if(w_tap==48)begin sub<=0; state<=L1_BN_LOAD; end else w_tap<=w_tap+1; end endcase
            L1_BN_LOAD: case(sub) 0:sub<=1; 1:begin bn1_w_r<=b1_rd_data; sub<=2; end 2:begin bn1_b_r<=b1_rd_data; sub<=3; end 3:begin bn1_m_r<=b1_rd_data; sub<=4; end 4:begin bn1_vi_r<=b1_rd_data; sub<=0; state<=L1_PX_LOAD; end endcase
            L1_PX_LOAD: begin
                case(sub)
                    0: begin px_ic_valid_d<=(ic[0]<9'd256); sub<=1; end
                    1,2,3,4,5,6: begin for(ii=0;ii<7;ii=ii+1) if(ir_in_bounds[ii]&&px_ic_valid_d) px_r[ii*7+sub-1]<=px_norm[ii]; else px_r[ii*7+sub-1]<=18'sd0; px_ic_valid_d<=(ic[sub]<9'd256); sub<=sub+1; end
                    7: begin for(ii=0;ii<7;ii=ii+1) if(ir_in_bounds[ii]&&px_ic_valid_d) px_r[ii*7+6]<=px_norm[ii]; else px_r[ii*7+6]<=18'sd0; sub<=0; state<=L1_CONV_PIPE1; end
                endcase
            end
            L1_CONV_PIPE1: state <= L1_CONV_PIPE2; L1_CONV_PIPE2: state <= L1_CONV_PIPE3; L1_CONV_PIPE3: state <= L1_CONV_REG;
            L1_CONV_REG: begin l1_acc <= l1_tree >>> 16; state<=L1_BN_S1; end // Q30.32 → Q15.16 (산술 시프트, 부호 보존)
            
            // ⭐️ [신규] L1_BN 명시적 파이프라이닝 적용 (공유 32x32 곱셈기 사용)
            L1_BN_S1: begin l1_nv_r<=l1_acc-bn1_m_r; state<=L1_BN_S1B; end
            L1_BN_S1B: begin bn_in_a1 <= l1_nv_r; bn_in_a2 <= bn1_vi_r; state<=L1_BN_S1C; end // Input Feed
            L1_BN_S1C: begin state<=L1_BN_S1D; end // Wait state for DSP Pipeline
            L1_BN_S1D: begin l1_raw <= bn_out_a; state<=L1_BN_S1E; end // Output Read
            L1_BN_S1E: begin l1_nv_r <= l1_raw[47:16]+{31'd0,l1_raw[15]}; state<=L1_BN_S2; end
            L1_BN_S2: begin bn_in_a1 <= l1_nv_r; bn_in_a2 <= bn1_w_r; state<=L1_BN_S2B; end // Input Feed
            L1_BN_S2B: begin state<=L1_BN_S2C; end // Wait state for DSP Pipeline
            L1_BN_S2C: begin l1_raw <= bn_out_a; state<=L1_BN_S3; end // Output Read
            L1_BN_S3: begin l1_bo=l1_raw[47:16]+{31'd0,l1_raw[15]}+bn1_b_r; fb_we<=1'b1; fb_wr_addr_r<={fb_wr_slot,l1_c[6:0],l1_ch}; fb_din<=(l1_bo>0)?l1_bo:32'sd0; state<=L1_NEXT_PX; end
            
            L1_NEXT_PX: begin if (l1_c == 127) state <= L1_NEXT_CH; else begin l1_c <= l1_c + 1; sub <= 0; state <= L1_PX_LOAD; end end
            L1_NEXT_CH: begin if (l1_ch == 31) state <= L1_ROW_DONE; else begin l1_ch <= l1_ch + 1; l1_c <= 0; sub <= 0; w_tap <= 0; state <= L1_W_LOAD; end end
            L1_ROW_DONE: begin fb_wr_slot <= (fb_wr_slot == 2) ? 2'd0 : fb_wr_slot + 2'd1; fb_count <= fb_count + 1; l1_rows_done <= l1_rows_done + 1; l1_r <= l1_r + 1; state <= PHASE_SEL; end
            B1_PX_START: begin b1_oc <= 0; b1_kp <= 0; b1_ic <= 0; sc_cslot_r <= fn_mod3({2'd0, fb_wr_slot} + 4'd3 - {1'b0, fb_count[2:0]} + ((b1_r == 0) ? 4'd0 : 4'd1)); fb_oob_r <= fb_oob_comb; state <= B1_WIN_LOAD; end
            B1_WIN_LOAD: begin
                b1_win[b1_kp][b1_ic] <= fb_oob_r ? 32'sd0 : fb_dout;
                fb_oob_r <= fb_oob_comb;
                if (b1_ic == 31) begin b1_ic <= 0; if (b1_kp == 8) begin b1_kp <= 0; state <= B1_OC_START; end else b1_kp <= b1_kp + 1; end else b1_ic <= b1_ic + 1;
            end
            B1_OC_START: begin b1_kp <= 0; b1_conv_acc <= 0; b1_conv_acc_b <= 0; sub <= 0; state <= B1_BCV_LOAD_P1; end
            B1_BCV_LOAD_P1: begin for(ii=0;ii<32;ii=ii+1) begin bwin_mux_0[ii]<=(b1_kp==0)?b1_win[0][ii]:(b1_kp==1)?b1_win[1][ii]:b1_win[2][ii]; bwin_mux_1[ii]<=(b1_kp==3)?b1_win[3][ii]:(b1_kp==4)?b1_win[4][ii]:b1_win[5][ii]; bwin_mux_2[ii]<=(b1_kp==6)?b1_win[6][ii]:(b1_kp==7)?b1_win[7][ii]:b1_win[8][ii]; end bconv_bits_a_pre<=b1_rd_data; bconv_bits_b_pre<=b1_rd_data_b; state<=B1_BCV_LOAD_P2; end
            B1_BCV_LOAD_P2: begin for(ii=0;ii<32;ii=ii+1) bwin_sel[ii]<=(b1_kp<3)?bwin_mux_0[ii]:(b1_kp<6)?bwin_mux_1[ii]:bwin_mux_2[ii]; bconv_bits_a<=bconv_bits_a_pre; bconv_bits_b<=bconv_bits_b_pre; state<=B1_BCV_CALC; end
            B1_BCV_CALC: begin if(sub==6) begin b1_conv_acc<=b1_conv_acc+bcv_tree_out_a; b1_conv_acc_b<=b1_conv_acc_b+bcv_tree_out_b; sub<=0; if(b1_kp==8)begin b1_ic<=0; b1_sc_acc<=0; b1_sc_acc_b<=0; state<=B1_SC_MUL; end else begin b1_kp<=b1_kp+1; state<=B1_BCV_LOAD_P1; end end else sub<=sub+1; end
            
            // ⭐️ [최적화] SC 3-cycle 파이프라인: b1_win 레지스터 직접 읽기, SC_MUL_RD 제거
            B1_SC_MUL: begin
                sc_in_a1 <= b1_win[4][b1_ic]; sc_in_a2 <= $signed(b1_rd_data[15:0]);
                sc_in_b1 <= b1_win[4][b1_ic]; sc_in_b2 <= $signed(b1_rd_data_b[15:0]);
                state <= B1_SC_MUL_WAIT;
            end
            B1_SC_MUL_WAIT: begin state <= B1_SC_CALC; end // DSP 1-cycle → 바로 CALC
            B1_SC_CALC: begin b1_sc_acc<=b1_sc_acc+sc_out_a; b1_sc_acc_b<=b1_sc_acc_b+sc_out_b; if(b1_ic==31)begin sub<=0; state<=B1_BN_CALC; end else begin b1_ic<=b1_ic+1; state<=B1_SC_MUL; end end
            
            // ⭐️ [신규] B1_BN 명시적 파이프라이닝 적용 (32x32 곱셈기 딜레이 분산)
            B1_BN_CALC: begin
                case(sub)
                    0:begin b1_alpha_r<=b1_rd_data; b1_alpha_b<=b1_rd_data_b; sub<=1; end 
                    1:begin b1_bw2_r<=b1_rd_data; b1_bw2_b<=b1_rd_data_b; sub<=2; end
                    2:begin b1_bb2_r<=b1_rd_data; b1_bb2_b<=b1_rd_data_b; sub<=3; end 
                    3:begin b1_bm2_r<=b1_rd_data; b1_bm2_b<=b1_rd_data_b; sub<=4; end
                    4:begin b1_bv2_r<=b1_rd_data; b1_bv2_b<=b1_rd_data_b; sub<=5; end
                    
                    // Mul 1: conv_acc * alpha
                    5:begin bn_in_a1 <= b1_conv_acc; bn_in_a2 <= b1_alpha_r; bn_in_b1 <= b1_conv_acc_b; bn_in_b2 <= b1_alpha_b; sub<=6; end // Input Feed
                    6:begin sub<=7; end // Wait state
                    7:begin bn_raw_a <= bn_out_a; bn_raw_b <= bn_out_b; sub<=8; end // Output Read
                    
                    8:begin bn_sc_a<=bn_raw_a[47:16]+{31'd0,bn_raw_a[15]}-b1_bm2_r; bn_sc_b<=bn_raw_b[47:16]+{31'd0,bn_raw_b[15]}-b1_bm2_b; sub<=9; end
                    
                    // Mul 2: sc * bv2
                    9:begin bn_in_a1 <= bn_sc_a; bn_in_a2 <= b1_bv2_r; bn_in_b1 <= bn_sc_b; bn_in_b2 <= b1_bv2_b; sub<=10; end
                    10:begin sub<=11; end // Wait state
                    11:begin bn_raw_a <= bn_out_a; bn_raw_b <= bn_out_b; sub<=12; end
                    
                    12:begin bn_nv_a<=bn_raw_a[47:16]+{31'd0,bn_raw_a[15]}; bn_nv_b<=bn_raw_b[47:16]+{31'd0,bn_raw_b[15]}; sub<=13; end
                    
                    // Mul 3: nv * bw2
                    13:begin bn_in_a1 <= bn_nv_a; bn_in_a2 <= b1_bw2_r; bn_in_b1 <= bn_nv_b; bn_in_b2 <= b1_bw2_b; sub<=14; end
                    14:begin sub<=15; end // Wait state
                    15:begin bn_raw_a <= bn_out_a; bn_raw_b <= bn_out_b; sub<=16; end
                    
                    16:begin b1_out_val<=bn_raw_a[47:16]+{31'd0,bn_raw_a[15]}+b1_bb2_r+b1_sc_acc[47:16]; b1_out_val_b<=bn_raw_b[47:16]+{31'd0,bn_raw_b[15]}+b1_bb2_b+b1_sc_acc_b[47:16]; sub<=0; state<=B1_STORE; end
                endcase
            end
            B1_STORE: begin
                if (b1_r[0] == 0) begin mp_we_a<=1'b1; mp_wr_addr_a<={b1_c[6:0],oc_e}; mp_din_a<=b1_out_val; mp_we_b<=1'b1; mp_wr_addr_b<={b1_c[6:0],oc_o}; mp_din_b<=b1_out_val_b; end
                else begin if (b1_out_val>$signed(mp_dout_a)) begin mp_we_a<=1'b1; mp_wr_addr_a<={b1_c[6:0],oc_e}; mp_din_a<=b1_out_val; end if (b1_out_val_b>$signed(mp_dout_b)) begin mp_we_b<=1'b1; mp_wr_addr_b<={b1_c[6:0],oc_o}; mp_din_b<=b1_out_val_b; end end
                if (b1_oc == 31) begin b1_oc <= 0; state <= B1_NEXT_PX; end else begin b1_oc <= b1_oc + 1; state <= B1_OC_START; end
            end
            B1_NEXT_PX: begin if (b1_c == 127) state <= B1_ROW_DONE; else begin b1_c <= b1_c + 1; state <= B1_PX_START; end end
            B1_ROW_DONE: begin b1_rows_done <= b1_rows_done + 1; if (b1_r >= 1) fb_count <= fb_count - 1; if (b1_r[0] == 1) begin mp_c <= 0; mp_oc <= 0; bp_w0 <= 0; bp_w1 <= 0; state <= MP_ROW; end else begin b1_r <= b1_r + 1; state <= PHASE_SEL; end end
            MP_ROW: begin
                if (!w_mp_mx[31]) begin if (mp_oc < 32) bp_w0[mp_oc] <= 1'b1; else bp_w1[mp_oc-32] <= 1'b1; end
                if (mp_oc == 63) begin mp_oc <= 0; state <= WR_FEAT; sub <= 0; end else mp_oc <= mp_oc + 1;
            end
            WR_FEAT: begin
                case (sub)
                    0: begin feat_wr_addr <= bp_addr; feat_wr_data <= bp_w0; feat_wr_we <= 4'hF; sub <= 1; end
                    1: begin feat_wr_addr <= bp_addr + 13'd1; feat_wr_data <= bp_w1; feat_wr_we <= 4'hF; bp_addr <= bp_addr + 13'd2; bp_w0 <= 0; bp_w1 <= 0; sub <= 0; 
                             if (mp_c == 63) begin mp_c <= 0; b1_r <= b1_r + 1; if (b1_r >= 127) state <= DONE_ST; else state <= PHASE_SEL; end 
                             else begin mp_c <= mp_c + 1; state <= MP_ROW; end 
                       end
                endcase
            end
            DONE_ST: begin o_done <= 1; if (!i_start) begin o_done <= 0; state <= IDLE; end end
            endcase
        end
    end
endmodule