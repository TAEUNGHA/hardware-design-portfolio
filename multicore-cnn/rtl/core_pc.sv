module core_pc(
            input logic      clk,
            input logic      reset_n,
            input logic      count_reg1_f,
            input logic      count_reg2_f,
            input logic      other_f,
            input logic [1:0] pc_f,
            output logic [4:0] pc_out
            );




106
    typedef enum                            logic {S0, S1} state_e;

    logic [4:0]                             internal_pc_reg;
    state_e internal_state_reg;

    logic [4:0]                             next_pc_comb;
    state_e next_state_comb;

    logic [2:0]                             count_reg1;
    logic [1:0]                             count_reg2;

    assign pc_out = internal_pc_reg;

    always_comb begin
      next_state_comb = internal_state_reg;
      next_pc_comb = internal_pc_reg;

      case (internal_state_reg)
       S0 : begin
         next_state_comb = S1;
       end

       S1 : begin
               if(!other_f)begin
           if (pc_f == 2'b01) begin       // inst[8] is jump to inst[1]
                          if (count_reg1 < 3) begin
                next_pc_comb = 1;
                          end
                          else begin
                next_pc_comb = internal_pc_reg + 1;
                          end
           end
                  else if (pc_f == 2'b10) begin // inst[10] is jump to inst[6]
                          if (count_reg1 < 5) begin
                next_pc_comb = 9;
                          end
                          else begin
                next_pc_comb = internal_pc_reg + 1;
                          end
           end
                  else if (pc_f == 2'b11) begin // inst[18] is jump to inst[6]
                          if (count_reg2 < 3) begin
                next_pc_comb = 9;
                          end
                          else begin
                next_pc_comb = 0;
                          end
           end
                  else begin // pc_f == 2'b00 (No jump)
                          next_pc_comb = internal_pc_reg + 1;
           end // else: !if(pc_f == 2'b11)
               end // if (other_f)
               else begin
           if (pc_f == 2'b01) begin       // inst[8] is jump to inst[1]
                          if (count_reg1 < 3) begin
                next_pc_comb = 1;
                          end
                          else begin
                next_pc_comb = internal_pc_reg + 1;
                          end
           end
                  else if (pc_f == 2'b10) begin // inst[10] is jump to inst[6]
                          if (count_reg1 < 3) begin
                next_pc_comb = 9;



107
                     end
                     else begin
            next_pc_comb = internal_pc_reg + 1;
                     end
         end
             else if (pc_f == 2'b11) begin // inst[18] is jump to inst[6]
          next_pc_comb = 0;
         end
             else begin // pc_f == 2'b00 (No jump)
                     next_pc_comb = internal_pc_reg + 1;
         end // else: !if(pc_f == 2'b11)
           end
       next_state_comb = S0;
      end

      default: begin
        next_pc_comb = 0;
        next_state_comb = S0;
      end
     endcase
    end

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
       internal_pc_reg <= 0;
       internal_state_reg <= S0;
       count_reg1 <= 0;
       count_reg2 <= 0;
    end
    else begin
       internal_state_reg <= next_state_comb;
       internal_pc_reg <= next_pc_comb;
              if(!other_f)begin
         if (internal_state_reg == S1) begin
            if ((pc_f == 2'b01) && count_reg1 >= 3 ||(pc_f == 2'b10) && count_reg1 >= 5 ) begin
                           count_reg1 <= 0;
                   end
            else if (count_reg1_f) begin
                           count_reg1 <= count_reg1 + 1;
            end

            if (pc_f == 2'b11 && count_reg2 >= 3) begin
                           count_reg2 <= 0;
            end
                   else if (count_reg2_f) begin
                           count_reg2 <= count_reg2 + 1;
            end
         end
              end // if (!other_f)
              else begin
         if (internal_state_reg == S1) begin
            if ((pc_f == 2'b01) && count_reg1 >= 3 ||(pc_f == 2'b10) && count_reg1 >= 3 ) begin
                           count_reg1 <= 0;
                   end
            else if (count_reg1_f) begin
                           count_reg1 <= count_reg1 + 1;
            end

         end
       end
    end // else: !if(!reset_n)
  end
endmodule
