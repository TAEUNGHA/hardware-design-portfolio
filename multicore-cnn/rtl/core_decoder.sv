 module core_decoder(input logic [7:0] inst_in,
                  output logic [1:0] exe_data_f,
                  output logic     stack_f,
                  output logic [1:0] stack_mode,
                  output logic [1:0] save_f,
                  output logic [1:0] out_f,
                  output logic [1:0] write_en,
                  output logic [1:0] pc_f,
                  output logic     mult_f,
                  output logic     adder_f,
                  output logic     count_reg1_f,
                  output logic     count_reg2_f,
                  output logic     other_f);

  logic [2:0]                         opcode;
  logic [1:0]                         sub;


  always_comb begin
    exe_data_f =2'b00;
    stack_f = 1'b0;
    stack_mode = 2'b00;
    save_f = 2'b00;
    out_f = 2'b00;
    write_en = 2'b00;
    pc_f = 1'b0;




101
      mult_f = 1'b0;
      adder_f = 1'b0;

      other_f = inst_in[7];
      count_reg2_f = inst_in[6];
      count_reg1_f = inst_in[5];
      sub = inst_in[4:3];
      opcode = inst_in[2:0];

      /* opcode 000(Nope) 001(load) 010(transfer) 011(stack) 100(mult) 101(add) 110(jump) */

      case(opcode)
           3'b000 : begin //Nope
              exe_data_f = 2'b00;
              stack_f = 1'b0;
              stack_mode = 2'b00;
              save_f = 2'b00;
              out_f = 2'b00;
              write_en = 2'b00;
              pc_f = 2'b00;
              mult_f = 1'b0;
              adder_f = 1'b0;
           end
           3'b001 : begin //load
             exe_data_f = 2'b00;
             stack_f = 1'b0;
             stack_mode = 2'b00;
             if(sub==2'b01) save_f = 2'b01; //save weight
             else if(sub==2'b10) save_f = 2'b10; //save pixel
             else if(sub ==2'b11) save_f = 2'b11; //save sum
             else save_f = 2'b00;
             out_f = 2'b00;
             write_en = 2'b00;
             pc_f = 2'b00;
             mult_f = 1'b0;
             adder_f = 1'b0;
           end
           3'b010 : begin //transfer
             exe_data_f = 2'b00;
             stack_f = 1'b0;
             stack_mode = 2'b00;
             save_f = 2'b00;
             if(sub == 2'b01) out_f = 2'b01; //weight
             else if(sub == 2'b10) out_f = 2'b10; // pixel
             else if(sub == 2'b11) out_f = 2'b11; // sum
             else out_f = 2'b00;
             write_en = 2'b00;
             pc_f = 2'b00;
             mult_f = 1'b0;
             adder_f = 1'b0;
           end
           3'b011 : begin //stack
             exe_data_f = 2'b00;
             stack_f=1'b1;
             if(sub == 2'b00) stack_mode = 2'b00; // weight stack 1
             else if(sub == 2'b01) stack_mode = 2'b01;//weight stack 2
             else if(sub == 2'b10) stack_mode = 2'b10;//pixel stack 1
             else stack_mode = 2'b11;// pixel stack 2
             save_f = 2'b00;
             out_f = 2'b00;
             write_en = 2'b00;
             pc_f = 2'b00;
             mult_f = 1'b0;
             adder_f = 1'b0;
           end



102
     3'b100 : begin //mult
       exe_data_f = 2'b01;
       stack_f = 1'b0;
       stack_mode = 2'b00;
       save_f = 2'b00;
       out_f = 2'b00;
       write_en = 2'b01;
       pc_f = 2'b00;
       mult_f = 1'b1;
       adder_f = 1'b0;
     end
     3'b101 : begin //add
       if(sub == 2'b01) begin
          exe_data_f = 2'b10;
          write_en = 2'b10;
          adder_f = 1'b1;
       end
       else if(sub == 2'b10) begin
          exe_data_f = 2'b11;
          write_en = 2'b11;
          adder_f = 1'b1;
       end
       else if(sub == 2'b11)begin
          exe_data_f = 2'b10;
          write_en = 2'b11;
          adder_f = 1'b1;
       end
       else begin
          exe_data_f = 2'b00;
          write_en = 2'b00;
          adder_f = 1'b0;
       end
       stack_f = 1'b0;
       stack_mode = 2'b00;
       save_f = 2'b00;
       out_f = 2'b00;

      pc_f = 2'b00;
      mult_f = 1'b0;

     end // case: 3'b101
     3'b110 : begin //jump
        exe_data_f = 2'b00;
        stack_f = 1'b0;
        stack_mode = 2'b00;
        save_f = 2'b00;
        out_f = 2'b00;
        write_en = 2'b00;
       if(sub == 2'b01) pc_f = 2'b01;
       else if(sub == 2'b10) pc_f =2'b10;
       else if(sub==2'b11) pc_f = 2'b11;
       else pc_f = 2'b00;
        mult_f = 1'b0;
        adder_f = 1'b0;
     end // case: 3'b110
     default: begin
       exe_data_f = 2'b00;
        stack_f = 1'b0;
        stack_mode = 2'b00;
        save_f = 2'b00;
        out_f = 2'b00;
        write_en = 2'b00;
        pc_f = 2'b00;
        mult_f = 1'b0;
        adder_f = 1'b0;



103
         end // case: default
   endcase // case (opcode)
 end // always_comb
endmodule // core_decoder
