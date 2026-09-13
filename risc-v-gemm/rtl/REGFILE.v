module REGFILE(/*AUTOARG*/
   // Outputs
   RD1, RD2,
   // Inputs
   CLK, WE3, A1, A2, A3, WD3
   );
   input CLK;
   input WE3; //write enable
   input [4:0] A1, A2, A3;
   input [31:0]	WD3;
   output [31:0] RD1, RD2;


   reg [31:0]	 RF [0:31];

   assign RD1 = (A1 == 5'd0) ? 32'd0 : RF[A1];
   assign RD2 = (A2 == 5'd0) ? 32'd0 : RF[A2];

   always@(posedge CLK) begin
      if(WE3&&(A3!=5'd0)) begin
	 RF[A3] <= WD3;
      end
      else begin
      end
   end
endmodule // REGFILE
