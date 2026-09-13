module alu(
   // Outputs
   result, zero,
   // Inputs
   a, b, alucontrol
   );
   input [31:0] a, b;
   input [2:0]	alucontrol;
   output reg [31:0] result;
   output reg	     zero;

   always@(*) begin
      case(alucontrol)
	3'b000 : result = a + b;
	3'b001 : result = a - b;
	3'b010 : result = a&b;
	3'b011 : result = a | b;
	3'b100 : result = a * b; //change 8 bit multiplier after
	3'b101 : result = ($signed(a)<$signed(b)) ? 1 : 0;
	//3'b110 : result = a << b[4:0];
	//3'b111 : result = a >> b[4:0];
	default : result = 0;
      endcase // case (alucontrol)

      if(result == 0) zero = 1;
      else zero  = 0;
   end // always@ (*)
endmodule // alu

/*
 module alu(
   // Outputs
   result, zero, overflow,
   // Inputs
   a, b, alucontrol
   );
   
   input [31:0] a, b;
   input [2:0]  alucontrol;
   output reg [31:0] result;
   output reg        zero;
   output reg        overflow;

   always@(*) begin
      case(alucontrol)
         3'b000: begin
            result = a + b;
            if (a[31] == b[31] && result[31] != a[31])
               overflow = 1'b1;
         end
         3'b001: begin
            result = a - b;
            if (a[31] != b[31] && result[31] != a[31])
               overflow = 1'b1;
         end
         3'b010 : result = a & b;
         3'b011 : result = a | b;
         3'b100 : result = a ^ b;
         3'b101 : result = ($signed(a) < $signed(b)) ? 1 : 0;
         3'b110 : result = a << b[4:0];
         3'b111 : result = a >> b[4:0];
         default : result = 0;
      endcase
      zero = (result == 32'd0);
   end
endmodule
*/	   
  
