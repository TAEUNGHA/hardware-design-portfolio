module DATAPATH(
    input CLK, RSTN, // RSTN: Active High Reset
    
    // From Controller (ID Stage Inputs)
    input [1:0] RESULTSRC_D, 
    input       MEMWRITE_D, ALUSRC_D, REGWRITE_D, JUMP_D, BRANCH_D,
    input [1:0] IMMSRC_D, 
    input [2:0] ALUCONTROL_D,
    
    // External Memory Interface
    output [31:0] PC,          // To IMEM
    input  [31:0] INSTR,       // From IMEM
    output [31:0] ALURESULT,   // To DMEM Address
    output [31:0] WRITEDATA,   // To DMEM Data
    input  [31:0] READDATA,    // From DMEM
    output        MEMWRITE_M_OUT, // To DMEM WE
    
    // To Controller (Feedback)
    output [31:0] INSTR_D,     // Decode Stage Instruction
    output        ZERO_E       // Execute Stage Zero Flag
);

    // =========================================================
    // WIRE DECLARATIONS
    // =========================================================
    
    // Fetch Stage
    wire [31:0] PCNext_F, PCPlus4_F, PC_F;
    
    // Decode Stage
    wire [31:0] PC_D, PCPlus4_D; 
    wire [31:0] RD1_D, RD2_D, ImmExt_D;
    wire PCSrc_Raw;
    // Execute Stage
    wire RegWrite_E, MemWrite_E, Jump_E, Branch_E, ALUSrc_E;
    wire [1:0] ResultSrc_E;
    wire [2:0] ALUControl_E;
    wire [31:0] RD1_E, RD2_E, PC_E, ImmExt_E, PCPlus4_E;
    wire [4:0]  Rs1_E, Rs2_E, Rd_E;
    wire [31:0] SrcA_E, SrcB_E, ALUResult_E, PCTarget_E;
    wire Zero_E, PCSrc_E;
    
    // Memory Stage
    wire RegWrite_M, MemWrite_M;
    wire [1:0] ResultSrc_M;
    wire [31:0] ALUResult_M, WriteData_M, PCPlus4_M;
    wire [4:0]  Rd_M;
    
    // Writeback Stage
    wire RegWrite_W;
    wire [1:0] ResultSrc_W;
    wire [31:0] ALUResult_W, ReadData_W, PCPlus4_W, Result_W;
    wire [4:0]  Rd_W;


    // =========================================================
    // STAGE 1: FETCH
    // =========================================================
    
    // 1-1. PC Register (Internal implementation)
    reg [31:0] r_PC;
    always @(posedge CLK or posedge RSTN) begin
        if (RSTN) r_PC <= 32'b0;
        else      r_PC <= PCNext_F;
    end
    
    assign PC_F = r_PC;
    assign PC = PC_F;          
    assign PCPlus4_F = PC_F + 4;
    
    // 1-2. Next PC Mux
    // [현재 상태] PCSrc_E가 0으로 고정되므로 무조건 PC+4가 선택됨 (x 방지)
    assign PCNext_F = (PCSrc_E) ? PCTarget_E : PCPlus4_F;

    // 1-3. IF/ID Pipeline Register
    PR_IF_ID pr1 (
        .clk(CLK), .reset(RSTN), .en(1'b1), 
        .flush(PCSrc_E), // 현재는 0
        .instr_f(INSTR), .pc_f(PC_F), .pcplus4_f(PCPlus4_F),
        .instr_d(INSTR_D), .pc_d(PC_D), .pcplus4_d(PCPlus4_D)
    );


    // =========================================================
    // STAGE 2: DECODE
    // =========================================================
    
    // 2-1. Register File
    REGFILE rf (
        .CLK(CLK), 
        .WE3(RegWrite_W),     // WB 단계에서 오는 신호
        .A1(INSTR_D[19:15]), 
        .A2(INSTR_D[24:20]), 
        .A3(Rd_W),            // WB 단계에서 오는 주소
        .WD3(Result_W),       // WB 단계에서 오는 데이터
        .RD1(RD1_D), 
        .RD2(RD2_D)
    );
    
    // 2-2. Sign Extend
    EXTEND ext (
        .INSTR(INSTR_D[31:7]), .IMMSRC(IMMSRC_D), .IMMEXT(ImmExt_D)
    );

    // 2-3. ID/EX Pipeline Register
    PR_ID_EX pr2 (
        .clk(CLK), .reset(RSTN), 
        .flush(PCSrc_E), // 현재는 0
        
        // Inputs
        .regwrite_d(REGWRITE_D), .memwrite_d(MEMWRITE_D), 
        .jump_d(JUMP_D), .branch_d(BRANCH_D), .alusrc_d(ALUSRC_D),
        .resultsrc_d(RESULTSRC_D), .alucontrol_d(ALUCONTROL_D),
        .rd1_d(RD1_D), .rd2_d(RD2_D), .pc_d(PC_D), .immext_d(ImmExt_D), .pcplus4_d(PCPlus4_D),
        .rs1_d(INSTR_D[19:15]), .rs2_d(INSTR_D[24:20]), .rd_d(INSTR_D[11:7]),
        
        // Outputs
        .regwrite_e(RegWrite_E), .memwrite_e(MemWrite_E), 
        .jump_e(Jump_E), .branch_e(Branch_E), .alusrc_e(ALUSrc_E),
        .resultsrc_e(ResultSrc_E), .alucontrol_e(ALUControl_E),
        .rd1_e(RD1_E), .rd2_e(RD2_E), .pc_e(PC_E), .immext_e(ImmExt_E), .pcplus4_e(PCPlus4_E),
        .rs1_e(Rs1_E), .rs2_e(Rs2_E), .rd_e(Rd_E)
    );


    // =========================================================
    // STAGE 3: EXECUTE
    // =========================================================
    
    // 3-1. SrcB Mux
    assign SrcA_E = RD1_E;
    assign SrcB_E = (ALUSrc_E) ? ImmExt_E : RD2_E;
    
    // 3-2. ALU
    alu alu0 (
        .a(SrcA_E), .b(SrcB_E), .alucontrol(ALUControl_E),
        .result(ALUResult_E), .zero(Zero_E)
    );
    
    // 3-3. Branch Target Adder
    assign PCTarget_E = PC_E + ImmExt_E;
    
    assign PCSrc_Raw = (Branch_E & Zero_E) | Jump_E;

    assign PCSrc_E = (PCSrc_Raw === 1'b1) ? 1'b1 : 1'b0;



    assign ZERO_E = Zero_E;

    // 3-5. EX/MEM Pipeline Register
    PR_EX_MEM pr3 (
        .clk(CLK), .reset(RSTN),
        // Inputs
        .regwrite_e(RegWrite_E), .memwrite_e(MemWrite_E), .resultsrc_e(ResultSrc_E),
        .aluresult_e(ALUResult_E), .writedata_e(RD2_E), .pcplus4_e(PCPlus4_E), .rd_e(Rd_E),
        // Outputs
        .regwrite_m(RegWrite_M), .memwrite_m(MemWrite_M), .resultsrc_m(ResultSrc_M),
        .aluresult_m(ALUResult_M), .writedata_m(WriteData_M), .pcplus4_m(PCPlus4_M), .rd_m(Rd_M)
    );


    // =========================================================
    // STAGE 4: MEMORY
    // =========================================================
    
    // 1. 외부 메모리 인터페이스 연결
    assign ALURESULT = ALUResult_M;     // 주소 (Ex: 0x00, 0x04...)
    assign WRITEDATA = WriteData_M;     // 데이터 (sw용)
    assign MEMWRITE_M_OUT = MemWrite_M; // 쓰기 신호
    
    // [중요] lw 명령어는 여기서 READDATA를 받습니다.
    // 하지만 파이프라인이므로, 이 데이터는 다음 클럭(WB 단계)에 레지스터에 쓰여야 합니다.

    // 2. MEM/WB Pipeline Register
    PR_MEM_WB pr4 (
        .clk(CLK), 
        .reset(RSTN),
        
        // Control Signals
        .regwrite_m(RegWrite_M), 
        .resultsrc_m(ResultSrc_M),
        
        // Data Signals
        .aluresult_m(ALUResult_M), 
        .readdata_m(READDATA),      // ★ 외부에서 들어온 데이터
        .pcplus4_m(PCPlus4_M), 
        .rd_m(Rd_M),
        
        // Outputs (To Writeback Stage)
        .regwrite_w(RegWrite_W), 
        .resultsrc_w(ResultSrc_W),
        .aluresult_w(ALUResult_W), 
        .readdata_w(ReadData_W),    // ★ WB 단계로 전달된 데이터
        .pcplus4_w(PCPlus4_W), 
        .rd_w(Rd_W)
    );


    // =========================================================
    // STAGE 5: WRITEBACK
    // =========================================================
    
    // 1. Result Mux (가장 중요한 부분!)
    // ResultSrc_W가 00이면 ALU결과(addi 등), 01이면 메모리값(lw)
    assign Result_W = (ResultSrc_W == 2'b00) ? ALUResult_W :
                      (ResultSrc_W == 2'b01) ? ReadData_W :
                      (ResultSrc_W == 2'b10) ? PCPlus4_W : 32'b0;

    // 2. Feedback to Register File (이미 STAGE 2에 연결되어 있음)
    // rf (.WD3(Result_W), .WE3(RegWrite_W), ...);

endmodule
