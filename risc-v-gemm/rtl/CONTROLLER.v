//`include "MAINDEC.v"
//`include "ALUDEC.v"
module CONTROLLER(
  input [6:0]  OP,	  // Instruction opcode
  input [2:0]  FUNCT3,	  // Instruction funct3
  input	       FUNCT7B5,  // Bit 5 of funct7 (used for SUB detection)
  input FUNCT7B0, //for mul
  input	       ZERO,	  // ALU result == 0 flag
  output [1:0] RESULTSRC, // Select result source: ALU / MEM / PC+4
  output       MEMWRITE,  // Enable writing to data memory
  output       PCSRC,	  // Select next PC (branch/jump)
  output       ALUSRC,	  // Select ALU input (register or immediate)
  output       REGWRITE,  // Enable writing to register file
  output       JUMP,	  // Jump instruction flag
  output [1:0] IMMSRC,	  // Select immediate type (I, S, B, J)
  output [2:0] ALUCONTROL, // Select ALU operation (add, sub, and, or, slt …)
  output BRANCH
 );
  wire [1:0] ALUOP;  // ALU operation category
// Branch instruction flag
  // Main decoder: generates high-level control signals from opcode
  MAINDEC MD(
    .OP(OP),
    .RESULTSRC(RESULTSRC),
    .MEMWRITE(MEMWRITE),
    .BRANCH(BRANCH),
    .ALUSRC(ALUSRC),
    .REGWRITE(REGWRITE),
    .JUMP(JUMP),
    .IMMSRC(IMMSRC),
    .ALUOP(ALUOP)
  );

     // ALU decoder: generates exact ALU operation from funct3/funct7 and ALUOP
  ALUDEC AD(
    .OPB5(OP[5]),
    .FUNCT3(FUNCT3),
    .FUNCT7B5(FUNCT7B5),
    .FUNCT7B0(FUNCT7B0),
    .ALUOP(ALUOP),
    .ALUCONTROL(ALUCONTROL)
  );
  // PC source logic: branch taken (BRANCH & ZERO) or unconditional JUMP
  assign PCSRC = (BRANCH&ZERO)|JUMP;
 endmodule
