module PR_MEM_WB (
    input clk, reset,
    input regwrite_m, input [1:0] resultsrc_m,
    input [31:0] aluresult_m, readdata_m, pcplus4_m,
    input [4:0] rd_m,
    
    output reg regwrite_w, output reg [1:0] resultsrc_w,
    output reg [31:0] aluresult_w, readdata_w, pcplus4_w,
    output reg [4:0] rd_w
);
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            regwrite_w <= 0; resultsrc_w <= 0;
            aluresult_w <= 0; readdata_w <= 0; pcplus4_w <= 0; rd_w <= 0;
        end else begin
            regwrite_w <= regwrite_m; resultsrc_w <= resultsrc_m;
            aluresult_w <= aluresult_m; readdata_w <= readdata_m; 
            pcplus4_w <= pcplus4_m; rd_w <= rd_m;
        end
    end
endmodule
