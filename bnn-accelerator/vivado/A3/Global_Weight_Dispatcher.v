`timescale 1ns / 1ps
// =============================================================================
// Global_Weight_Dispatcher.v
// [수정 사항] Stage 1 통합에 따라, dma_mode == 1 일 때 BRAM_FEAT를 덮어쓰는
//            충돌 로직을 제거하고, Stage 1이 온전히 제어하도록 변경했습니다.
// =============================================================================
module Global_Weight_Dispatcher (
    input wire clk, input wire rst_n, input wire dma_mode,
    input wire [31:0] s_axis_tdata, input wire s_axis_tvalid, output wire s_axis_tready, input wire s_axis_tlast,
    output reg [31:0] bram_wdata, output reg [31:0] bram_addr,
    output reg en_bin, output reg [3:0] we_bin, output reg en_sc, output reg [3:0] we_sc,
    output reg en_para, output reg [3:0] we_para, output reg en_head, output reg [3:0] we_head,
    output reg en_feat, output reg [3:0] we_feat,
    input  wire [10:0] l1_w_rd_addr, output wire [15:0] l1_w_rd_data,
    input  wire [11:0] b1_rd_addr, output wire [31:0] b1_rd_data,
    input  wire [11:0] b1_rd_addr_b, output wire [31:0] b1_rd_data_b,
    input wire clear_frame_ready, output reg load_done, output reg frame_ready
);

    localparam SZ_L1_W=1568, SZ_S1=4640, SZ_BIN=12096, SZ_SC=20480, SZ_PARA=2240, SZ_HEAD=257;
    reg [31:0] w_cnt; reg [5:0] l1_k; reg [4:0] l1_c; reg [11:0] b1_w_idx;
    assign s_axis_tready = 1'b1;

    (* ram_style = "distributed" *) reg [15:0] l1_w_mem [0:2047];
    reg l1_w_wr_en; reg [10:0] l1_w_wr_addr; reg [15:0] l1_w_wr_data;
    always @(posedge clk) if (l1_w_wr_en) l1_w_mem[l1_w_wr_addr] <= l1_w_wr_data;
    reg [15:0] l1_w_dout; always @(posedge clk) l1_w_dout <= l1_w_mem[l1_w_rd_addr];
    assign l1_w_rd_data = l1_w_dout;

    reg b1_wr_en; reg [11:0] b1_wr_addr; wire [11:0] b1_addr_a = b1_wr_en ? b1_wr_addr : b1_rd_addr;
    bram_b1 u_b1_mem (.clka(clk), .ena(1'b1), .wea(b1_wr_en), .addra(b1_addr_a), .dina(bram_wdata), .douta(b1_rd_data),
                      .clkb(clk), .enb(1'b1), .web(1'b0), .addrb(b1_rd_addr_b), .dinb(32'd0), .doutb(b1_rd_data_b));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_cnt<=0; bram_addr<=0; bram_wdata<=0; load_done<=0; frame_ready<=0;
            l1_k<=0; l1_c<=0; b1_w_idx<=0; b1_wr_en<=0; b1_wr_addr<=0; l1_w_wr_en<=0;
            en_bin<=0; we_bin<=0; en_sc<=0; we_sc<=0; en_para<=0; we_para<=0; en_head<=0; we_head<=0; en_feat<=0; we_feat<=0;
        end else begin
            if (clear_frame_ready) frame_ready <= 0;
            en_bin<=0; we_bin<=0; en_sc<=0; we_sc<=0; en_para<=0; we_para<=0; en_head<=0; we_head<=0; en_feat<=0; we_feat<=0;
            b1_wr_en <= 0; l1_w_wr_en <= 0;

            // ⭐️ 주의: s_axis_tready가 1일 때만 데이터가 유효하므로 AND 연산 추가
            if (s_axis_tvalid && s_axis_tready) begin
                bram_wdata <= s_axis_tdata;
                if (dma_mode == 0) begin
                    if (w_cnt < SZ_L1_W) begin l1_w_wr_en<=1; l1_w_wr_addr<={l1_c,6'd0}|{5'd0,l1_k}; l1_w_wr_data<=s_axis_tdata[15:0]; if (l1_k==48) begin l1_k<=0; l1_c<=l1_c+1; end else l1_k<=l1_k+1; end
                    else if (w_cnt < SZ_S1) begin b1_wr_en<=1; b1_wr_addr<=b1_w_idx; b1_w_idx<=b1_w_idx+1; l1_k<=0; l1_c<=0; end
                    else if (w_cnt < SZ_S1+SZ_BIN) begin en_bin<=1; we_bin<=4'hF; bram_addr<=(w_cnt-SZ_S1); end
                    else if (w_cnt < SZ_S1+SZ_BIN+SZ_SC) begin en_sc<=1; we_sc<=4'hF; bram_addr<=(w_cnt-(SZ_S1+SZ_BIN)); end
                    else if (w_cnt < SZ_S1+SZ_BIN+SZ_SC+SZ_PARA) begin en_para<=1; we_para<=4'hF; bram_addr<=(w_cnt-(SZ_S1+SZ_BIN+SZ_SC)); end
                    else if (w_cnt < SZ_S1+SZ_BIN+SZ_SC+SZ_PARA+SZ_HEAD) begin en_head<=1; we_head<=4'hF; bram_addr<=(w_cnt-(SZ_S1+SZ_BIN+SZ_SC+SZ_PARA)); end
                    if (s_axis_tlast) begin load_done <= 1; w_cnt <= 0; b1_w_idx <= 0; end else w_cnt <= w_cnt + 1;
                end else begin
                    // [해결됨] 이미지는 Stage1_Engine이 처리하므로 여기서 BRAM_FEAT를 덮어쓰거나 무단으로 frame_ready를 켜지 않습니다!
                end
            end
        end
    end
endmodule