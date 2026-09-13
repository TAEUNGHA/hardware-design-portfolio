`timescale 1ns / 1ps
// =============================================================================
// Accelerator_Top.v  - BNN 가속기 최상위 모듈 (Stage1 PL 통합 완벽판)
// =============================================================================
module Accelerator_Top # (
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 5
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI4-Lite 슬레이브 ----
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- AXI4-Stream 슬레이브 입력 (DMA MM2S) ----
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // ---- AXI4-Stream 마스터 출력 (DMA S2MM) ----
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire [3:0]  m_axis_tkeep,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // =========================================================
    // 내부 제어 신호
    // =========================================================
    wire        w_run;          // AXI-Lite → 엔진 실행 트리거
    wire        w_idle;         // 통합 idle (Stage1 & Stage2)
    wire        w_done;         // Stage2 완료 → AXI-Lite
    wire        w_load_done;    // Dispatcher: 가중치 전송 완료
    wire        w_mode;         // DMA 모드: 0=가중치, 1=이미지
    wire        w_frame;        // 레거시 신호
    wire        w_clear;        // Stage2 → clear frame_ready

    wire [31:0] check_addr;
    wire [2:0]  bram_sel;
    reg  [31:0] selected_dout;

    // Dispatcher 파이프라인 레지스터
    wire [31:0] b_wdata, b_addr;
    wire        en_bin,  en_sc,  en_para,  en_head,  en_feat;
    wire [3:0]  we_bin,  we_sc,  we_para,  we_head,  we_feat;

    reg [31:0] b_wdata_r, b_addr_r;
    reg        en_bin_r,  en_sc_r,  en_para_r,  en_head_r,  en_feat_r;
    reg [3:0]  we_bin_r,  we_sc_r,  we_para_r,  we_head_r,  we_feat_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_wdata_r<=0; b_addr_r<=0;
            en_bin_r<=0; en_sc_r<=0; en_para_r<=0; en_head_r<=0; en_feat_r<=0;
            we_bin_r<=0; we_sc_r<=0; we_para_r<=0; we_head_r<=0; we_feat_r<=0;
        end else begin
            b_wdata_r<=b_wdata; b_addr_r<=b_addr;
            en_bin_r<=en_bin; en_sc_r<=en_sc; en_para_r<=en_para; en_head_r<=en_head; en_feat_r<=en_feat;
            we_bin_r<=we_bin; we_sc_r<=we_sc; we_para_r<=we_para; we_head_r<=we_head; we_feat_r<=we_feat;
        end
    end

    wire [63:0] dout_bin, dout_para;
    wire [31:0] dout_sc, dout_head, dout_feat;

    // Stage 1 통신 와이어
    wire [10:0] s1_l1_w_rd_addr;
    wire [15:0] s1_l1_w_rd_data;
    wire        s1_o_done, s1_o_idle;
    wire [11:0] s1_b1_rd_addr,   s1_b1_rd_addr_b;
    wire [31:0] s1_b1_rd_data,  s1_b1_rd_data_b;
    wire [12:0] s1_feat_wr_addr;
    wire [31:0] s1_feat_wr_data;
    wire [3:0]  s1_feat_wr_we;
    wire        s1_s_axis_tready;

    // Stage 2 통신 와이어
    wire [31:0] eng_rd_addr_bin, eng_rd_addr_sc;
    wire [31:0] eng_rd_addr_feat, eng_rd_addr_para, eng_rd_addr_head;
    wire [31:0] eng_wr_addr_feat, eng_wr_data_feat;
    wire [3:0]  eng_wr_we_feat;
    wire        s2_o_done, s2_o_idle;

    // =========================================================
    // AXI-Stream 안전 상호 배제 라우팅 (MUX)
    // =========================================================
    wire disp_tready;
    wire disp_tvalid = (w_mode == 1'b0) ? s_axis_tvalid : 1'b0;
    wire s1_tvalid   = (w_mode == 1'b1) ? s_axis_tvalid : 1'b0;
    assign s_axis_tready = (w_mode == 1'b0) ? disp_tready : s1_s_axis_tready;

    reg w_mode_d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) w_mode_d <= 0;
        else        w_mode_d <= w_mode;

    // Stage1 구동 트리거 래치
    reg s1_start_latch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s1_start_latch <= 0;
        else begin
            if (w_mode && !w_mode_d && w_load_done) s1_start_latch <= 1;
            if (s1_o_done)                          s1_start_latch <= 0;
        end
    end

    // Stage1 연산 완료 플래그 래치 (Stage2의 연료 역할)
    reg s1_frame_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s1_frame_ready <= 0;
        else begin
            if (s1_o_done)  s1_frame_ready <= 1;
            if (w_clear)    s1_frame_ready <= 0;
        end
    end

    assign w_idle = s1_o_idle & s2_o_idle;
    assign w_done = s2_o_done;

    // Port B 주소 멀티플렉서
    wire [12:0] addrb_bin  = w_run ? eng_rd_addr_bin[12:0]  : check_addr[12:0];
    wire [14:0] addrb_sc   = w_run ? eng_rd_addr_sc[14:0]   : check_addr[14:0];
    wire [10:0] addrb_para = w_run ? eng_rd_addr_para[10:0] : check_addr[10:0];
    wire [10:0] addrb_head = w_run ? eng_rd_addr_head[10:0] : check_addr[10:0];
    wire [12:0] addrb_feat = w_run ? eng_rd_addr_feat[12:0] : check_addr[12:0];

    // BRAM_FEAT Port A 멀티플렉서 (3-way 완벽 검증 분기)
    wire s1_wr_active = |s1_feat_wr_we;
    wire        ena_feat_a   = s1_wr_active ? 1'b1                    : (w_run ? (|eng_wr_we_feat) : en_feat_r);
    wire [3:0]  wea_feat_a   = s1_wr_active ? s1_feat_wr_we           : (w_run ? eng_wr_we_feat    : we_feat_r);
    wire [12:0] addra_feat_a = s1_wr_active ? s1_feat_wr_addr         : (w_run ? eng_wr_addr_feat[12:0] : b_addr_r[12:0]);
    wire [31:0] dina_feat_a  = s1_wr_active ? s1_feat_wr_data         : (w_run ? eng_wr_data_feat  : b_wdata_r);

    // =========================================================
    // 하위 IP 모듈 구조 결합
    // =========================================================
    AXI_Lite_Slave u_axi (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n), .S_AXI_AWADDR(s_axi_awaddr), .S_AXI_AWVALID(s_axi_awvalid), .S_AXI_AWREADY(s_axi_awready),
        .S_AXI_WDATA(s_axi_wdata), .S_AXI_WSTRB(s_axi_wstrb), .S_AXI_WVALID(s_axi_wvalid), .S_AXI_WREADY(s_axi_wready), .S_AXI_BRESP(s_axi_bresp),
        .S_AXI_BVALID(s_axi_bvalid), .S_AXI_BREADY(s_axi_bready), .S_AXI_ARADDR(s_axi_araddr), .S_AXI_ARVALID(s_axi_arvalid), .S_AXI_ARREADY(s_axi_arready),
        .S_AXI_RDATA(s_axi_rdata), .S_AXI_RRESP(s_axi_rresp), .S_AXI_RVALID(s_axi_rvalid), .S_AXI_RREADY(s_axi_rready),
        .o_run(w_run), .i_idle(w_idle), .i_done(w_done), .i_load_done(w_load_done),
        .bram_check_addr(check_addr), .bram_sel(bram_sel), .bram_check_dout(selected_dout), .dma_mode(w_mode)
    );

    Global_Weight_Dispatcher u_disp (
        .clk(clk), .rst_n(rst_n), .dma_mode(w_mode), .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(disp_tvalid), .s_axis_tready(disp_tready), .s_axis_tlast(s_axis_tlast),
        .bram_wdata(b_wdata), .bram_addr(b_addr), .en_bin(en_bin), .we_bin(we_bin), .en_sc(en_sc), .we_sc(we_sc), .en_para(en_para), .we_para(we_para), .en_head(en_head), .we_head(we_head), .en_feat(en_feat), .we_feat(we_feat),
        .l1_w_rd_addr(s1_l1_w_rd_addr), .l1_w_rd_data(s1_l1_w_rd_data), .b1_rd_addr(s1_b1_rd_addr), .b1_rd_data(s1_b1_rd_data), .b1_rd_addr_b(s1_b1_rd_addr_b), .b1_rd_data_b(s1_b1_rd_data_b),
        .load_done(w_load_done), .frame_ready(w_frame), .clear_frame_ready(w_clear)
    );

    Stage1_Engine u_s1 (
        .clk(clk), .rst_n(rst_n), .i_start(s1_start_latch), .o_done(s1_o_done), .o_idle(s1_o_idle),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s1_tvalid), .s_axis_tready(s1_s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .l1_w_rd_addr(s1_l1_w_rd_addr), .l1_w_rd_data(s1_l1_w_rd_data), .b1_rd_addr(s1_b1_rd_addr), .b1_rd_data(s1_b1_rd_data), .b1_rd_addr_b(s1_b1_rd_addr_b), .b1_rd_data_b(s1_b1_rd_data_b),
        .feat_wr_addr(s1_feat_wr_addr), .feat_wr_data(s1_feat_wr_data), .feat_wr_we(s1_feat_wr_we)
    );

    Stage2_Engine u_eng (
        .clk(clk), .rst_n(rst_n), .i_run(w_run), .frame_ready(s1_frame_ready), .o_done(s2_o_done), .o_idle(s2_o_idle), .clear_frame_ready(w_clear),
        .rd_addr_bin(eng_rd_addr_bin), .rd_data_bin(dout_bin), .rd_addr_sc(eng_rd_addr_sc), .rd_data_sc(dout_sc), .rd_addr_feat(eng_rd_addr_feat), .rd_data_feat(dout_feat), .rd_addr_para(eng_rd_addr_para), .rd_data_para(dout_para), .rd_addr_head(eng_rd_addr_head), .rd_data_head(dout_head),
        .wr_addr_feat(eng_wr_addr_feat), .wr_data_feat(eng_wr_data_feat), .wr_we_feat(eng_wr_we_feat),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast)
    );

    // =========================================================
    // 메모리 자원 할당 프리미티브 리스트
    // =========================================================
    BRAM_BIN u_bin   (.clka(clk), .ena(en_bin_r), .wea(we_bin_r), .addra(b_addr_r[13:0]), .dina(b_wdata_r), .douta(), .clkb(clk), .enb(1'b1), .web(8'h0), .addrb(addrb_bin), .dinb(64'h0), .doutb(dout_bin));
    BRAM_SC u_sc     (.clka(clk), .ena(en_sc_r), .wea(we_sc_r), .addra(b_addr_r[14:0]), .dina(b_wdata_r), .douta(), .clkb(clk), .enb(1'b1), .web(4'h0), .addrb(addrb_sc[14:0]), .dinb(32'h0), .doutb(dout_sc));
    BRAM_PARA u_para (.clka(clk), .ena(en_para_r), .wea(we_para_r), .addra(b_addr_r[11:0]), .dina(b_wdata_r), .douta(), .clkb(clk), .enb(1'b1), .web(8'h0), .addrb(addrb_para), .dinb(64'h0), .doutb(dout_para));
    BRAM_HEAD u_head (.clka(clk), .ena(en_head_r), .wea(we_head_r), .addra(b_addr_r[10:0]), .dina(b_wdata_r), .douta(), .clkb(clk), .enb(1'b1), .web(4'h0), .addrb(addrb_head), .dinb(32'h0), .doutb(dout_head));
    BRAM_FEAT u_feat (.clka(clk), .ena(ena_feat_a), .wea(wea_feat_a), .addra(addra_feat_a), .dina(dina_feat_a), .douta(), .clkb(clk), .enb(1'b1), .web(4'h0), .addrb(addrb_feat), .dinb(32'h0), .doutb(dout_feat));

    always @(*) begin
        case (bram_sel)
            3'd0:    selected_dout = dout_bin[31:0];
            3'd1:    selected_dout = dout_sc[31:0];
            3'd2:    selected_dout = dout_para[31:0];
            3'd3:    selected_dout = dout_head;
            3'd4:    selected_dout = dout_feat;
            3'd5:    selected_dout = dout_bin[63:32];
            3'd6:    selected_dout = dout_para[63:32];
            default: selected_dout = 32'h0;
        endcase
    end

    assign m_axis_tkeep = 4'hF;
endmodule