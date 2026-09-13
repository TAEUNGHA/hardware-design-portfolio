module ALUDEC(
	      input	       OPB5,
	      input [2:0]      FUNCT3,
	      input	       FUNCT7B5,//for add, sub
	      input	       FUNCT7B0,//for mul	      
	      input [1:0]      ALUOP,
	      output reg [2:0] ALUCONTROL
	      );

   wire RTYPESUB;
   assign RTYPESUB = FUNCT7B5 & OPB5;

   always @(*) begin
      case(ALUOP)
	2'b00: ALUCONTROL = 3'b000;
	2'b01: ALUCONTROL = 3'b001;
	default:begin
	   case(FUNCT3)
	     3'b000: begin
if(OPB5) begin
		if(FUNCT7B0) ALUCONTROL = 3'b100; //mul 
                else if(RTYPESUB) ALUCONTROL = 3'b001; //sub
		else ALUCONTROL = 3'b000; //add
end
else begin
ALUCONTROL = 3'b000;
end

	     end
	     3'b010: ALUCONTROL = 3'b101;
	     3'b110: ALUCONTROL = 3'b011;
	     3'b111: ALUCONTROL = 3'b010;
	     default: ALUCONTROL = 3'b000;
	   endcase // case (FUNCT3)
	end // case: default
      endcase // case (ALUOP)
   end // always @ (*)
endmodule // ALUDEC
