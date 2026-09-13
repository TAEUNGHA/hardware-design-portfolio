module IMEM (
  input  [31:0] A,
  output [31:0] RD,

  // 디버그/외부 관찰용 포트 (read-only)
  input         DBG_EN,
  input  [31:0] DBG_A,
  output [31:0] DBG_RD
);

  reg [31:0] RAM [0:127];

  initial begin
   
    $readmemh("/home/dice22/P4/rtl/gemm8x8.txt", RAM);
  end

  // CPU/RISC 포트 (word aligned)
  assign RD = RAM[A[31:2]];

  // 디버그 포트 (word aligned 읽기, DBG_EN이 1일 때만 유효로 사용)
  assign DBG_RD = RAM[DBG_A[31:2]];

endmodule
