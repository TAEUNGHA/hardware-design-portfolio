/*
 module PC(
   // Outputs
   PC,PCPlus4,
   // Inputs
   clk, reset, PCSrc, ImmExt
   );
   input clk, reset, PCSrc;

   input [31:0] ImmExt;
   output reg [31:0] PC, PCPlus4;

   reg  [31:0] 	     PCTarget;
   reg [31:0] 	     PCNext;

   always@(posedge clk or posedge reset) begin
      if(reset) begin
	 PC <= 32'b0;
      end
      else begin
	 PC <= PCNext;
      end
   end
always@(*) begin
PCPlus4 = PC+4;
PCTarget = PC + ImmExt;
if(PCSrc) PCNext = PCTarget;
else PCNext = PCPlus4;
end

  // assign PCPlus4 = PC + 4;
   //assign PCTarget = PC + ImmExt;
   //assign PCNext = (PCSrc == 1)? PCTarget : PCPlus4;
endmodule // PC
*/

module PC(
    input clk, reset,
    input [31:0] PCNext,
    output reg [31:0] PC
);
    always @(posedge clk or posedge reset) begin
        if (reset) PC <= 32'b0;
        else       PC <= PCNext;
    end
endmodule
