// tickgen.v

module tickgen(/*AUTOARG*/
   // Outputs
   tick,
   // Inputs
   CLK, RSTN, enable
   );
	
   input CLK;
   input RSTN;
   input enable;
   output tick;

	localparam COUNT_MAX = 49_999_999;

   reg [$clog2(COUNT_MAX):0] counter_reg;

    assign tick = (counter_reg == COUNT_MAX);

    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
           counter_reg <= 0;
        end
	else if (!enable)begin
	   counter_reg <= 0;
	end
        else begin
            if (tick) begin
                counter_reg <= 0;
            end 
            else counter_reg <= counter_reg + 1;
        end
    end
endmodule


