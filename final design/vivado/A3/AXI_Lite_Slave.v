`timescale 1 ns / 1 ps

module AXI_Lite_Slave # (
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
) (
    output reg o_run,
    input wire i_idle,
    input wire i_done,
    input wire i_load_done,
    output reg [31:0] bram_check_addr,
    output reg [2:0]  bram_sel,
    input wire [31:0]  bram_check_dout,
    output reg dma_mode,

    input wire  S_AXI_ACLK,
    input wire  S_AXI_ARESETN,
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
    input wire [2 : 0] S_AXI_AWPROT,
    input wire  S_AXI_AWVALID,
    output reg  S_AXI_AWREADY,
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input wire  S_AXI_WVALID,
    output reg  S_AXI_WREADY,
    output reg [1 : 0] S_AXI_BRESP,
    output reg  S_AXI_BVALID,
    input wire  S_AXI_BREADY,
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
    input wire [2 : 0] S_AXI_ARPROT,
    input wire  S_AXI_ARVALID,
    output reg  S_AXI_ARREADY,
    output reg [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
    output reg [1 : 0] S_AXI_RRESP,
    output reg  S_AXI_RVALID,
    input wire  S_AXI_RREADY
);
    reg [31:0] slv_reg0, slv_reg2, slv_reg4;
    reg [1:0] rwait_cnt;
    reg aw_en;

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            S_AXI_AWREADY <= 0; S_AXI_WREADY <= 0; S_AXI_BVALID <= 0; S_AXI_BRESP <= 0;
            slv_reg0 <= 0; slv_reg2 <= 0; slv_reg4 <= 0; aw_en <= 1;
            o_run <= 0; dma_mode <= 0; bram_check_addr <= 0; bram_sel <= 0;
        end else begin
            if (~S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                S_AXI_AWREADY <= 1; aw_en <= 0;
            end else if (S_AXI_BREADY && S_AXI_BVALID) begin
                aw_en <= 1; S_AXI_AWREADY <= 0;
            end else S_AXI_AWREADY <= 0;

            if (~S_AXI_WREADY && S_AXI_WVALID && S_AXI_AWVALID && aw_en) S_AXI_WREADY <= 1;
            else S_AXI_WREADY <= 0;

            if (S_AXI_WVALID && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_AWREADY) begin
                case (S_AXI_AWADDR[4:2])
                    3'h0: begin slv_reg0 <= S_AXI_WDATA; o_run <= S_AXI_WDATA[31]; dma_mode <= S_AXI_WDATA[0]; end
                    3'h2: begin slv_reg2 <= S_AXI_WDATA; bram_check_addr <= S_AXI_WDATA; end
                    3'h4: begin slv_reg4 <= S_AXI_WDATA; bram_sel <= S_AXI_WDATA[2:0]; end
                endcase
            end
            if (i_done) o_run <= 1'b0;
            if (S_AXI_AWREADY && S_AXI_AWVALID && ~S_AXI_BVALID && S_AXI_WREADY && S_AXI_WVALID) S_AXI_BVALID <= 1;
            else if (S_AXI_BREADY && S_AXI_BVALID) S_AXI_BVALID <= 0;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            S_AXI_ARREADY <= 0; S_AXI_RVALID <= 0; S_AXI_RDATA <= 0; rwait_cnt <= 0;
        end else begin
            if (~S_AXI_ARREADY && S_AXI_ARVALID) begin
                S_AXI_ARREADY <= 1; rwait_cnt <= 2'd1;
            end else begin
                S_AXI_ARREADY <= 0;
            end
            if (rwait_cnt == 2'd1) rwait_cnt <= 2'd2;
            else if (rwait_cnt == 2'd2) begin
                S_AXI_RVALID <= 1; S_AXI_RRESP <= 0; rwait_cnt <= 0;
                case (S_AXI_ARADDR[4:2])
                    3'h0: S_AXI_RDATA <= slv_reg0;
                    3'h1: S_AXI_RDATA <= {29'd0, i_load_done, i_idle, i_done};
                    3'h2: S_AXI_RDATA <= slv_reg2;
                    3'h3: S_AXI_RDATA <= bram_check_dout;
                    3'h4: S_AXI_RDATA <= slv_reg4;
                    default: S_AXI_RDATA <= 0;
                endcase
            end else if (S_AXI_RVALID && S_AXI_RREADY) S_AXI_RVALID <= 0;
        end
    end
endmodule