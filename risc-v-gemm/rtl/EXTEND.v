module EXTEND (INSTR, IMMSRC, IMMEXT);
  input  [31:7] INSTR;
  input  [1:0]  IMMSRC;
  output [31:0] IMMEXT;

  reg [31:0] IMMEXT;

  always @(*) begin
    case (IMMSRC)
      // I-type 
      2'b00: IMMEXT = {{20{INSTR[31]}}, INSTR[31:20]};
      // S-type (stores)
      2'b01: IMMEXT = {{20{INSTR[31]}}, INSTR[31:25], INSTR[11:7]};
      // B-type (branches)
      2'b10: IMMEXT = {{20{INSTR[31]}}, INSTR[7], INSTR[30:25], INSTR[11:8], 1'b0};
      // J-type (jal)
      2'b11: IMMEXT = {{12{INSTR[31]}}, INSTR[19:12], INSTR[20], INSTR[30:21], 1'b0};
      default: IMMEXT = 32'bx;
    endcase
  end
endmodule
