
module cmd_parser(
    input           CLK,
    input           RST_N,
    input           i_Rx_DV,
    input   [7:0]   i_Rx_Byte,
    
    output  reg [5:0] o_CALL_FLOOR,
    output  reg     o_CALL_DIR,
    output  reg     o_CALL_VALID,
    output  reg     o_CAR_CALL_VALID, 
    output  reg     o_Send_Error_Req
);

    reg [7:0] buffer [0:9]; 
    reg [3:0] buf_idx;

    reg [5:0] next_call_floor;
    reg       next_call_dir;
    reg       next_call_valid;
    reg       next_car_call_valid; 
    reg       next_send_error_req;
    reg [7:0] next_buffer [0:9];
    reg [3:0] next_buf_idx;

    always @(posedge CLK or negedge RST_N) begin
        integer i;
        if (!RST_N) begin
            o_CALL_FLOOR <= 0;
            o_CALL_DIR   <= 0;
            o_CALL_VALID <= 0;
            o_CAR_CALL_VALID <= 0;
            o_Send_Error_Req <= 0;
            buf_idx      <= 0;
            for (i = 0; i < 10; i = i + 1) begin
                buffer[i] <= 0;
            end
        end else begin
            o_CALL_FLOOR <= next_call_floor;
            o_CALL_DIR   <= next_call_dir;
            o_CALL_VALID <= next_call_valid;
            o_CAR_CALL_VALID <= next_car_call_valid;
            o_Send_Error_Req <= next_send_error_req;
            buf_idx      <= next_buf_idx;
            for (i = 0; i < 10; i = i + 1) begin
                buffer[i] <= next_buffer[i];
            end
        end
    end


    always @(*) begin
        integer i;
        
        next_call_floor = o_CALL_FLOOR;
        next_call_dir   = o_CALL_DIR;
        next_call_valid = 1'b0; 
        next_car_call_valid = 1'b0; 
        next_send_error_req = 1'b0; 
        next_buf_idx    = buf_idx;
        for (i = 0; i < 10; i = i + 1) begin
            next_buffer[i] = buffer[i];
        end

        if (i_Rx_DV) begin
            if (i_Rx_Byte == 8'h0D) begin 
                reg is_hall_call, is_car_call;
                is_hall_call = 1'b0;
                is_car_call = 1'b0;

                case (buf_idx) 
                    2: if (buffer[0] == "C" && buffer[1] >= "0" && buffer[1] <= "9") begin
                           next_call_floor = buffer[1] - "0";
                           is_car_call = 1'b1;
                       end
                    3: if (buffer[0] == "C" && buffer[1] >= "0" && buffer[1] <= "9" && buffer[2] >= "0" && buffer[2] <= "9") begin
                           next_call_floor = (buffer[1]-"0")*10 + (buffer[2]-"0");
                           is_car_call = 1'b1;
                       end
							  
                       else if (buffer[0] >= "0" && buffer[0] <= "9" && buffer[1] == "U" && buffer[2] == "P") begin
                           next_call_floor = buffer[0] - "0";
                           next_call_dir   = 1'b1;
                           is_hall_call    = 1'b1;
                       end
                    4: if (buffer[0]>="0"&&buffer[0]<="9"&&buffer[1]>="0"&&buffer[1]<="9"&&buffer[2]=="U"&&buffer[3]=="P") begin
                           next_call_floor = (buffer[0]-"0")*10 + (buffer[1]-"0");
                           next_call_dir   = 1'b1;
                           is_hall_call    = 1'b1;
                       end
                    5: if (buffer[0]>="0"&&buffer[0]<="9"&&buffer[1]=="D"&&buffer[2]=="O"&&buffer[3]=="W"&&buffer[4]=="N") begin
                           next_call_floor = buffer[0] - "0";
                           next_call_dir   = 1'b0;
                           is_hall_call    = 1'b1;
                       end
                    6: if (buffer[0]>="0"&&buffer[0]<="9"&&buffer[1]>="0"&&buffer[1]<="9"&&buffer[2]=="D"&&buffer[3]=="O"&&buffer[4]=="W"&&buffer[5]=="N") begin
                           next_call_floor = (buffer[0]-"0")*10 + (buffer[1]-"0");
                           next_call_dir   = 1'b0;
                           is_hall_call    = 1'b1;
                       end
                endcase

                if (is_hall_call)       next_call_valid = 1'b1;
                else if (is_car_call)   next_car_call_valid = 1'b1;
                else                    next_send_error_req = 1'b1;
                
                next_buf_idx = 0;
            end 
            else if (i_Rx_Byte != 8'h0A) begin 
                if (buf_idx < 10) begin
                    next_buffer[buf_idx] = i_Rx_Byte;
                    next_buf_idx         = buf_idx + 1;
                end
            end
        end
    end

endmodule
