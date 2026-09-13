module RISCVSINGLE (
    input  CLK, RSTN,
    output [31:0] PC,          // To IMEM (PC_F)
    input  [31:0] INSTR,       // From IMEM (INSTR_F)
    output        MEMWRITE,    // To DMEM (MEMWRITE_M)
    output [31:0] ALURESULT,   // To DMEM Addr
    output [31:0] WRITEDATA,   // To DMEM Data
    input  [31:0] READDATA     // From DMEM
);

    // Internal Wires
    wire [31:0] INSTR_D; // Controller가 해석할 명령어
    wire [1:0] RESULTSRC_D, IMMSRC_D;
    wire MEMWRITE_D, ALUSRC_D, REGWRITE_D, JUMP_D, BRANCH_D;
    wire [2:0] ALUCONTROL_D;
    wire ZERO_E; // Not actually used by controller in this logic, but wired out
    wire MEMWRITE_RAW;

    // CONTROLLER: Decode 단계의 INSTR_D를 보고 제어 신호 생성
    CONTROLLER CTRL (
        .OP(INSTR_D[6:0]), 
        .FUNCT3(INSTR_D[14:12]), 
        .FUNCT7B5(INSTR_D[30]), 
        .FUNCT7B0(INSTR_D[25]), 
        .ZERO(ZERO_E), // Branch logic is inside Datapath now, but pass it anyway
        .RESULTSRC(RESULTSRC_D), 
        .MEMWRITE(MEMWRITE_D), 
        .PCSRC(), // PCSRC logic is moved to Datapath (Execute Stage)
        .ALUSRC(ALUSRC_D), 
        .REGWRITE(REGWRITE_D), 
        .JUMP(JUMP_D), 
        .IMMSRC(IMMSRC_D), 
        .ALUCONTROL(ALUCONTROL_D),
        .BRANCH(BRANCH_D)
    );

    DATAPATH DP (
        .CLK(CLK), .RSTN(RSTN),
        // Controller Inputs
        .RESULTSRC_D(RESULTSRC_D), .MEMWRITE_D(MEMWRITE_D), 
        .ALUSRC_D(ALUSRC_D), .REGWRITE_D(REGWRITE_D), 
        .JUMP_D(JUMP_D), .BRANCH_D(BRANCH_D), 
        .IMMSRC_D(IMMSRC_D), .ALUCONTROL_D(ALUCONTROL_D),
        
        // Memory Interface
        .PC(PC), .INSTR(INSTR),
        .ALURESULT(ALURESULT), .WRITEDATA(WRITEDATA), 
        .READDATA(READDATA), .MEMWRITE_M_OUT(MEMWRITE_RAW), // Pipeline output to Memory
        
        // Feedback
        .INSTR_D(INSTR_D),
        .ZERO_E(ZERO_E)
    );
   assign MEMWRITE = (MEMWRITE_RAW === 1'b1) ? 1'b1 : 1'b0;

endmodule

