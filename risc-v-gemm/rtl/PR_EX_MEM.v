module PR_EX_MEM (
    input clk, reset,
    input regwrite_e, memwrite_e, input [1:0] resultsrc_e,
    input [31:0] aluresult_e, writedata_e, pcplus4_e,
    input [4:0] rd_e,
    
    output reg regwrite_m, memwrite_m, output reg [1:0] resultsrc_m,
    output reg [31:0] aluresult_m, writedata_m, pcplus4_m,
    output reg [4:0] rd_m
);
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            regwrite_m <= 0; memwrite_m <= 0; resultsrc_m <= 0;
            aluresult_m <= 0; writedata_m <= 0; pcplus4_m <= 0; rd_m <= 0;
        end else begin
            regwrite_m <= regwrite_e; memwrite_m <= memwrite_e; resultsrc_m <= resultsrc_e;
            aluresult_m <= aluresult_e; writedata_m <= writedata_e; 
            pcplus4_m <= pcplus4_e; rd_m <= rd_e;
        end
    end
endmodule
