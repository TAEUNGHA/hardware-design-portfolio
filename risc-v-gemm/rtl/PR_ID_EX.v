module PR_ID_EX (
    input clk, reset, flush,
    
    // Control Signals (From Controller)
    input regwrite_d, memwrite_d, jump_d, branch_d, alusrc_d,
    input [1:0] resultsrc_d, input [2:0] alucontrol_d,
    
    // Data Signals (From Datapath)
    input [31:0] rd1_d, rd2_d, pc_d, immext_d, pcplus4_d,
    input [4:0] rs1_d, rs2_d, rd_d,
    
    // Outputs (To Execute Stage)
    output reg regwrite_e, memwrite_e, jump_e, branch_e, alusrc_e,
    output reg [1:0] resultsrc_e, output reg [2:0] alucontrol_e,
    output reg [31:0] rd1_e, rd2_e, pc_e, immext_e, pcplus4_e,
    output reg [4:0] rs1_e, rs2_e, rd_e
);
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            regwrite_e <= 0; memwrite_e <= 0; jump_e <= 0; branch_e <= 0; alusrc_e <= 0;
            resultsrc_e <= 0; alucontrol_e <= 0;
            rd1_e <= 0; rd2_e <= 0; pc_e <= 0; immext_e <= 0; pcplus4_e <= 0;
            rs1_e <= 0; rs2_e <= 0; rd_e <= 0;
        end
  else begin
       if (flush) begin
            regwrite_e <= 0; memwrite_e <= 0; jump_e <= 0; branch_e <= 0; alusrc_e <= 0;
            resultsrc_e <= 0; alucontrol_e <= 0;
            rd1_e <= 0; rd2_e <= 0; pc_e <= 0; immext_e <= 0; pcplus4_e <= 0;
            rs1_e <= 0; rs2_e <= 0; rd_e <= 0;
        end
  else begin 
            regwrite_e <= regwrite_d; memwrite_e <= memwrite_d; 
            jump_e <= jump_d; branch_e <= branch_d; alusrc_e <= alusrc_d;
            resultsrc_e <= resultsrc_d; alucontrol_e <= alucontrol_d;
            rd1_e <= rd1_d; rd2_e <= rd2_d; pc_e <= pc_d; immext_e <= immext_d; 
            pcplus4_e <= pcplus4_d;
            rs1_e <= rs1_d; rs2_e <= rs2_d; rd_e <= rd_d;
         end
       end
    end
endmodule
