`timescale 1ns/1ps

// TOP_GEMM : RISCVSINGLE + IMEM + DMEM 래핑
// - IMEM/DMEM 자체에 디버그 포트가 있으므로, 이를 그대로 밖으로 노출
module TOP_GEMM (
  input         CLK,
  input         RESET,

  // CPU 관찰용
  output [31:0] PC,
  output [31:0] DATAADR,
  output [31:0] WRITEDATA,
  output        MEMWRITE,

  // IMEM 디버그 포트
  input         IMEM_DBG_EN,
  input  [31:0] IMEM_DBG_A,
  output [31:0] IMEM_DBG_RD,

  // DMEM 디버그 포트
  input         DMEM_DBG_EN,
  input         DMEM_DBG_WE,
  input  [31:0] DMEM_DBG_A,
  input  [31:0] DMEM_DBG_WD,
  output [31:0] DMEM_DBG_RD
);
  wire [31:0] instr;
  wire [31:0] readdata;

  // CPU
  RISCVSINGLE CPU (
    .CLK       (CLK),
    .RSTN     (RESET),
    .PC        (PC),
    .INSTR     (instr),
    .MEMWRITE  (MEMWRITE),
    .ALURESULT (DATAADR),
    .WRITEDATA (WRITEDATA),
    .READDATA  (readdata)
  );

  // Instruction memory
  IMEM imem (
    .A      (PC),
    .RD     (instr),
    .DBG_EN (IMEM_DBG_EN),
    .DBG_A  (IMEM_DBG_A),
    .DBG_RD (IMEM_DBG_RD)
  );

  // Data memory
  DMEM #(.DEPTH(256)) dmem (
    .CLK     (CLK),
    .WE      (MEMWRITE),
    .A       (DATAADR),
    .WD      (WRITEDATA),
    .RD      (readdata),
    .DBG_EN  (DMEM_DBG_EN),
    .DBG_WE  (DMEM_DBG_WE),
    .DBG_A   (DMEM_DBG_A),
    .DBG_WD  (DMEM_DBG_WD),
    .DBG_RD  (DMEM_DBG_RD)
  );
endmodule
