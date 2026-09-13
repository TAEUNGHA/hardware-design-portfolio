module uart_tx #(
    parameter CLKS_PER_BIT = 434 // For 50MHz clock and 115200 baud
) (
    input               CLK,
    input               RST_N,
    input               i_Tx_DV,      // Data Valid
    input       [7:0]   i_Tx_Byte,
    output  reg         o_Tx_Serial,
    output              o_Tx_Active   // High while transmitting
);
    
    localparam  IDLE        = 2'b00;
    localparam  START_BIT   = 2'b01;
    localparam  DATA_BITS   = 2'b10;
    localparam  STOP_BIT    = 2'b11;
    
    reg [1:0]   r_SM_Main;
    reg [9:0]   r_Clk_Count;
    reg [2:0]   r_Bit_Index;
    reg [7:0]   r_Tx_Byte;

    assign o_Tx_Active = (r_SM_Main != IDLE);

    always @(posedge CLK or negedge RST_N) begin
        if (!RST_N) begin
            r_SM_Main   <= IDLE;
            r_Clk_Count <= 0;
            r_Bit_Index <= 0;
            r_Tx_Byte   <= 0;
            o_Tx_Serial <= 1;
        end
        else begin
            case(r_SM_Main)
                IDLE: begin
                    o_Tx_Serial <= 1; // Drive line high
                    if (i_Tx_DV) begin
                        r_Tx_Byte   <= i_Tx_Byte;
                        r_Clk_Count <= 0;
                        r_Bit_Index <= 0;
                        o_Tx_Serial <= 0; // Start bit
                        r_SM_Main   <= START_BIT;
                    end
                end
                START_BIT: begin
                    if (r_Clk_Count == CLKS_PER_BIT - 1) begin
                        r_Clk_Count <= 0;
                        r_SM_Main   <= DATA_BITS;
                    end else begin
                        r_Clk_Count <= r_Clk_Count + 1;
                    end
                end
                DATA_BITS: begin
                    o_Tx_Serial <= r_Tx_Byte[r_Bit_Index];
                    if (r_Clk_Count == CLKS_PER_BIT - 1) begin
                        r_Clk_Count <= 0;
                        if (r_Bit_Index == 7) begin
                            r_SM_Main   <= STOP_BIT;
                        end else begin
                            r_Bit_Index <= r_Bit_Index + 1;
                        end
                    end else begin
                        r_Clk_Count <= r_Clk_Count + 1;
                    end
                end
                STOP_BIT: begin
                    o_Tx_Serial <= 1; // Stop bit
                    if (r_Clk_Count == CLKS_PER_BIT - 1) begin
                        r_SM_Main   <= IDLE;
                    end else begin
                        r_Clk_Count <= r_Clk_Count + 1;
                    end
                end
                default:
                    r_SM_Main <= IDLE;
            endcase
        end
    end
endmodule
