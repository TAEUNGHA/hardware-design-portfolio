
module status_transmitter (
    input           CLK,
    input           RST_N,
    input           i_Tick_1s,
    input           i_Send_Error_Req,
    input           i_Help_Req,
    input   [5:0]   i_Current_Floor,
    input   [1:0]   i_Current_Dir,
    input           i_Tx_Active,
    output  reg     o_Tx_DV,
    output  reg [7:0] o_Tx_Byte
);
    localparam DIR_STOP = 2'd0, DIR_UP = 2'd1, DIR_DOWN = 2'd2;
    
    localparam S_IDLE        = 3'd0;
    localparam S_PREPARE     = 3'd1;
    localparam S_SEND_BYTE   = 3'd2;
    localparam S_WAIT_ACCEPT = 3'd3;
    localparam S_WAIT_FINISH = 3'd4;

    reg [2:0]   state; 
    reg [4:0]   send_idx; 
    reg [7:0]   message_buf [0:39];
    reg [5:0]   message_len;
    reg [1:0]   msg_type; 
    reg [7:0]   ft, fo;

    always @(posedge CLK or negedge RST_N) begin
        if (!RST_N) begin
            state <= S_IDLE; 
            send_idx <= 0; 
            o_Tx_DV <= 1'b0; 
            o_Tx_Byte <= 8'h00; 
            msg_type <= 0;
        end else begin
            o_Tx_DV <= 1'b0; 

            case (state)
                S_IDLE: begin
                    if (!i_Tx_Active) begin
                        if (i_Help_Req) begin 
								msg_type <= 2; state <= S_PREPARE;
								end
                        else if (i_Send_Error_Req) begin 
								msg_type <= 1; state <= S_PREPARE;
								end
                        else if (i_Tick_1s) begin
								msg_type <= 0; state <= S_PREPARE;
								end
                    end
                end

                S_PREPARE: begin
                   
                    case (msg_type)
                        0: begin // Status
                           ft = (i_Current_Floor/10) + "0"; 
                           fo = (i_Current_Floor % 10) + "0";
                           message_buf[0] <= "F"; message_buf[1] <= ":"; message_buf[2] <= ft; message_buf[3] <= fo;
                           message_buf[4] <= ","; message_buf[5] <= "D"; message_buf[6] <= "I"; message_buf[7] <= "R"; message_buf[8] <= ":";
                           case(i_Current_Dir)
                               DIR_UP:   begin message_buf[9]<="U"; message_buf[10]<="P"; message_buf[11]<=8'h0D; message_buf[12]<=8'h0A; message_len<=13; end
                               DIR_DOWN: begin message_buf[9]<="D"; message_buf[10]<="O"; message_buf[11]<="W"; message_buf[12]<="N"; message_buf[13]<=8'h0D; message_buf[14]<=8'h0A; message_len<=15; end
                               default:  begin message_buf[9]<="S"; message_buf[10]<="T"; message_buf[11]<="O"; message_buf[12]<="P"; message_buf[13]<=8'h0D; message_buf[14]<=8'h0A; message_len<=15; end
                           endcase
                        end
                        1: begin // Error
                           message_buf[0] <= "E"; message_buf[1] <= "R"; message_buf[2] <= "R"; 
                           message_buf[3] <= ":"; message_buf[4] <= "C"; message_buf[5] <= "M"; 
                           message_buf[6] <= "D"; message_buf[7] <= 8'h0D; message_buf[8] <= 8'h0A;
                           message_len <= 9;
                        end
                        2: begin // Help
                           message_buf[0] <= "H"; message_buf[1] <= "E"; message_buf[2] <= "L"; 
                           message_buf[3] <= "P"; message_buf[4] <= 8'h0D; message_buf[5] <= 8'h0A;
                           message_len <= 6;
                        end
                    endcase
                    send_idx <= 0;
                    state    <= S_SEND_BYTE;
                end

                S_SEND_BYTE: begin
                    o_Tx_DV   <= 1'b1;
                    o_Tx_Byte <= message_buf[send_idx];
                    state     <= S_WAIT_ACCEPT;
                end
                
                S_WAIT_ACCEPT: begin
                    if (i_Tx_Active) begin
                        state <= S_WAIT_FINISH;
                    end
                end

                S_WAIT_FINISH: begin
                    if (!i_Tx_Active) begin
                        if (send_idx + 1 < message_len) begin
                            send_idx <= send_idx + 1;
                            state    <= S_SEND_BYTE;
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule