module DMEM #(parameter DEPTH = 1024) (
  input         CLK,

  // CPU/RISC 포트
  input         WE,
  input  [31:0] A,
  input  [31:0] WD,
  output [31:0] RD,

  // 디버그/외부 제어 포트
  input         DBG_EN,
  input         DBG_WE,
  input  [31:0] DBG_A,
  input  [31:0] DBG_WD,
  output [31:0] DBG_RD
);
  // 32-bit wide, DEPTH-deep memory
  reg [31:0] RAM [0:DEPTH-1];

  // CPU 읽기 포트 (word aligned)
  assign RD = RAM[A[31:2]];

  // 디버그 읽기 포트 (word aligned, 비동기 읽기)
  assign DBG_RD = RAM[DBG_A[31:2]];

  // 쓰기는 클럭 동기
  // 디버그 쓰기가 활성화된 경우 우선권을 갖는다.
  always @(posedge CLK) begin
    if (DBG_EN && DBG_WE)
      RAM[DBG_A[31:2]] <= DBG_WD;
    else if (WE)
      RAM[A[31:2]] <= WD;
  end
endmodule
