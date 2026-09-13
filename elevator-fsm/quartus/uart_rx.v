module uart_rx #(
    parameter CLKS_PER_BIT = 434 // For 50MHz clock and 115200 baud
) (
    input               CLK,
    input               RST_N,
    input               i_Rx_Serial,
    output  reg         o_Rx_DV,   
    output  reg [7:0]   o_Rx_Byte
);

    localparam  IDLE        = 3'b000;
    localparam  START_BIT   = 3'b001;
    localparam  DATA_BITS   = 3'b010;
    localparam  STOP_BIT    = 3'b011;
    localparam  CLEANUP     = 3'b100;

    reg [2:0]   r_SM_Main;
    reg [9:0]   r_Clk_Count;
    reg [2:0]   r_Bit_Index;
    reg [7:0]   r_Rx_Byte;

    always @(posedge CLK or negedge RST_N) begin
        if (!RST_N) begin
            r_SM_Main   <= IDLE;
            r_Clk_Count <= 0;
            r_Bit_Index <= 0;
            r_Rx_Byte   <= 0;
            o_Rx_DV     <= 0;
            o_Rx_Byte   <= 0;
        end
        else begin
            o_Rx_DV <= 0; // Default value
            case (r_SM_Main)
                IDLE: begin
                    if (i_Rx_Serial == 0) begin // Start bit detected
                        r_Clk_Count <= 0;
                        r_SM_Main   <= START_BIT;
                    end
                end
                START_BIT: begin
                    if (r_Clk_Count == (CLKS_PER_BIT / 2) - 1) begin
                        if (i_Rx_Serial == 0) begin
                            r_Clk_Count <= 0;
                            r_Bit_Index <= 0;
                            r_SM_Main   <= DATA_BITS;
                        end else begin
                            r_SM_Main   <= IDLE; // False start bit
                        end
                    end else begin
                        r_Clk_Count <= r_Clk_Count + 1;
                    end
                end
                DATA_BITS: begin
                    if (r_Clk_Count == CLKS_PER_BIT - 1) begin
                        r_Clk_Count <= 0;
                        r_Rx_Byte[r_Bit_Index] <= i_Rx_Serial;
                        
                        if (r_Bit_Index == 7) begin
                            r_Bit_Index <= 0;
                            r_SM_Main   <= STOP_BIT;
                        end else begin
                            r_Bit_Index <= r_Bit_Index + 1;
                        end
                    end else begin
                        r_Clk_Count <= r_Clk_Count + 1;
                    end
                end
                STOP_BIT: begin
                    if (r_Clk_Count == CLKS_PER_BIT - 1) begin
                        r_Clk_Count <= 0;
                        r_SM_Main   <= CLEANUP;
                    end else begin
                        r_Clk_Count <= r_Clk_Count + 1;
                    end
                end
                CLEANUP: begin
                    o_Rx_DV   <= 1;
                    o_Rx_Byte <= r_Rx_Byte;
                    r_SM_Main <= IDLE;
                end
                default:
                    r_SM_Main <= IDLE;
            endcase
        end
    end
endmodule
