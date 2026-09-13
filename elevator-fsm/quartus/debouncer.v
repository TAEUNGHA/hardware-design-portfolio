module debouncer(
    input               CLK, 
    input               RSTN,

    input               btn_open,
    input               btn_close,  

    output  reg         btn_open_out,
    output  reg         btn_close_out
);

    localparam COUNT_MAX = 500;
   
    reg [$clog2(COUNT_MAX):0] counter1;
    reg [$clog2(COUNT_MAX):0] counter2;

    reg btn_int1;
    reg btn_int2;

    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
           btn_int1 <= 0;
            counter1 <= 0;
            btn_open_out <= 0;
        end else begin
            if (btn_open != btn_int1) begin
                btn_int1 <= btn_open;
                counter1 <= 0;
            end 
            else if (counter1 < COUNT_MAX) begin
                counter1 <= counter1 + 1;
            end 
            else begin
                btn_open_out <= btn_int1;
            end	   
        end
    end // always @ (posedge CLK or negedge RSTN)

       always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
	   btn_int2 <= 0;
	   counter2 <= 0;
	   btn_close_out <= 0;
        end else begin
	    if (btn_close != btn_int2) begin
                btn_int2 <= btn_close;
                counter2 <= 0;
            end 
            else if (counter2 < COUNT_MAX) begin
                counter2 <= counter2 + 1;
            end 
            else begin
                btn_close_out <= btn_int2;
            end
	   
        end
    end

endmodule
