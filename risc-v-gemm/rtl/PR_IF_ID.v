module PR_IF_ID (
    input clk, reset, en, flush,
    input [31:0] instr_f, pc_f, pcplus4_f,
    output reg [31:0] instr_d, pc_d, pcplus4_d
);
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            instr_d <= 32'b0; 
            pc_d <= 32'b0; 
            pcplus4_d <= 32'b0;
        end 
       else begin
         if(flush)begin
            instr_d <= 32'b0; 
            pc_d <= 32'b0; 
            pcplus4_d <= 32'b0;
         end 
          else if (en) begin
            instr_d <= instr_f;
            pc_d <= pc_f;
            pcplus4_d <= pcplus4_f;
        end
      end
    end
endmodule
