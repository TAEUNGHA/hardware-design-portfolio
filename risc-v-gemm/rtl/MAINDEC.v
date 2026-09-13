module MAINDEC(
	       input [6:0] OP,
	       output [1:0] RESULTSRC,
	       output MEMWRITE,
	       output BRANCH,
	       output ALUSRC,
	       output REGWRITE,
	       output JUMP,
	       output [1:0] IMMSRC,
	       output [1:0] ALUOP
	       );
   reg [10:0] CONTROLS;

   //CONTROLS = {REGWRITE, IMMSRC[1:0], ALUSRC, MEMWRITE, RESULTSRC[1:0], BRANCH, ALUOP[1:0], JUMP}

   assign{REGWRITE, IMMSRC, ALUSRC, MEMWRITE, RESULTSRC, BRANCH, ALUOP, JUMP} = CONTROLS;

   always @(*) begin
      case(OP)
	7'b0000011: CONTROLS = 11'b1_00_1_0_01_0_00_0; //LW
	7'b0100011: CONTROLS = 11'b0_01_1_1_00_0_00_0; //SW
	7'b0110011: CONTROLS = 11'b1_00_0_0_00_0_10_0; //R (ADD, SUB, AND, OR, SLT)
	7'b1100011: CONTROLS = 11'b0_10_0_0_00_1_01_0; //BEQ
	7'b0010011: CONTROLS = 11'b1_00_1_0_00_0_10_0; //I (ADDI, ANDI, ORI, SLTI)
	7'b1101111: CONTROLS = 11'b1_11_0_0_10_0_00_1; //JAL
	default: CONTROLS = 11'b0_00_0_0_00_0_00_0; //UNdefined
      endcase // case (OP)
   end // always @ (*)
endmodule // MAINDEC
