module core_ram(input logic clk, reset_n,
                      input logic [1:0] exe_data_f,
                      input logic [1:0] save_f,
                      input logic [1:0] out_f, // transfer filter,conv, and sum_out to other core
                      input logic [1:0] write_en, // write alu_result in ram
                      input logic            stack_f,
                      input logic [1:0] stack_mode,
                      input logic [4:0] pc_in,
                      input logic [15:0] data_in, sum_in,
                      input logic [15:0] multi1, multi2, multi3, sum_result,
                      output logic [15:0] pixel1, pixel2, pixel3, weight1, weight2, weight3, conv1, conv2, conv3,
                      output logic [7:0] inst_out,
                      output logic [15:0] sum_out,
                      output logic [15:0] transfer_out);
  logic [15:0]                               ram_data_array [0:10];
  logic [7:0]                                inst_memory [0:25];
  always_ff@(posedge clk or negedge reset_n)begin
    if(!reset_n)begin
            for(int i=0; i<11; i++)begin
              ram_data_array[i] <= 0;
            end

            /* set inst_memory */

          //{count_reg2_f,count_reg1_f,sub,opcode}

          inst_memory[0] <= {1'b0, 1'b0, 1'b0, 2'b00, 3'b000}; //Nope
          inst_memory[1] <= {1'b0, 1'b0, 1'b0, 2'b00, 3'b011}; //stack1 weight
          inst_memory[2] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b011}; //stack2 weight
          inst_memory[3] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b001}; //load weight
          inst_memory[4] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b010}; //tranfer
          inst_memory[5] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b001}; //load weight
          inst_memory[6] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b010}; //tranfer
          inst_memory[7] <= {1'b0, 1'b0, 1'b1, 2'b01, 3'b001}; //load weight, count_reg1 +1
          inst_memory[8] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b110}; //jump to 1
          inst_memory[9] <= {1'b0, 1'b0, 1'b0, 2'b10, 3'b011}; //stack1 pixel
          inst_memory[10] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b011}; //stack2 pixel
          inst_memory[11] <= {1'b0, 1'b0, 1'b0, 2'b10, 3'b010}; //transfer pixel
          inst_memory[12] <= {1'b0, 1'b0, 1'b1, 2'b10, 3'b001}; //load pixel, count_reg1 +1
          inst_memory[13] <= {1'b0, 1'b0, 1'b0, 2'b10, 3'b110}; //jump to 9
          inst_memory[14] <= {1'b0, 1'b0, 1'b0, 2'b00, 3'b100}; //mult
          inst_memory[15] <= {1'b0, 1'b0, 1'b0, 2'b01, 3'b101}; //add conv
          inst_memory[16] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b001}; //load sum
          inst_memory[17] <= {1'b0, 1'b0, 1'b0, 2'b10, 3'b101}; //add sum
          inst_memory[18] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b010}; //transfer sum
          inst_memory[19] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b001}; //load sum
          inst_memory[20] <= {1'b0, 1'b0, 1'b0, 2'b10, 3'b101}; //add sum
          inst_memory[21] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b010}; //transfer sum
          inst_memory[22] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b001}; //load sum
          inst_memory[23] <= {1'b0, 1'b0, 1'b0, 2'b10, 3'b101}; //add sum
          inst_memory[24] <= {1'b0, 1'b1, 1'b0, 2'b11, 3'b010}; //transfer sum, count_reg2+1
          inst_memory[25] <= {1'b0, 1'b0, 1'b0, 2'b11, 3'b110}; //jump to 9 or 0
          pixel1 <= 0;
          pixel2 <= 0;
          pixel3 <= 0;
          weight1 <= 0;
          weight2 <= 0;
          weight3 <= 0;



104
             inst_out <= 0;
             sum_out <= 0;
             transfer_out <=0;
      end // if (!reset_n)
      /* ram_data_array[0] ~[2] : pixel
       ram_data_array[3] ~ [5] : weight
       ram_data_array[6] ~ [8] : conv data
       ram_data_array[9] : sum
       ram_data_array[10] : sum in and out */
      else begin

           inst_out <= inst_memory[pc_in];

           case(save_f)
            2'b01 : begin // save weight
              ram_data_array[3] <= data_in;
            end
            2'b10 : begin // save pixel
              ram_data_array[0] <= data_in;
            end
            2'b11 : begin // save sum
              ram_data_array[10] <= sum_in;
            end
            default: ; // if have some problem, change this case to if
           endcase // case (save_f)

           case(out_f)
            2'b01 : begin // transfer weight
              transfer_out <= ram_data_array[3];
            end
            2'b10 : begin // transfer pixel
              transfer_out <= ram_data_array[0];
            end
            2'b11 : begin // transfer sum
              sum_out <= ram_data_array[10];
            end
           endcase // case (out_f)

            if(stack_f == 1) begin //do stack
               case(stack_mode)
                2'b00 : begin //weight stack 1
                       ram_data_array[5] <= ram_data_array[4]; // second input to first
                end
                2'b01 : begin //weight stack 2
                       ram_data_array[4] <= ram_data_array[3]; //third input to second
                end
                2'b10 : begin //pixel stack 1
                       ram_data_array[2] <= ram_data_array[1]; //second input to first
                end
                2'b11 : begin //pixel stack 2
                       ram_data_array[1] <= ram_data_array[0]; //third input to second
                end
                default : ;
               endcase // case (stack_mode)
            end // if (stack_f == 1)


           case(exe_data_f)
            2'b01 : begin // convolution
              pixel1 <= ram_data_array[0];
              pixel2 <= ram_data_array[1];
              pixel3 <= ram_data_array[2];
              weight1 <= ram_data_array[3];
              weight2 <= ram_data_array[4];
              weight3 <= ram_data_array[5];



105
          end
          2'b10 : begin // sum
            conv1 <= ram_data_array[6];
            conv2 <= ram_data_array[7];
            conv3 <= ram_data_array[8];
          end
          2'b11 : begin
            conv1 <= ram_data_array[9];
            conv2 <= ram_data_array[10];
            conv3 <= 0;
          end
          2'b00 : begin // Nope
            pixel1 <= 0;
            pixel2 <= 0;
            pixel3 <= 0;
            weight1 <= 0;
            weight2 <= 0;
            weight3 <= 0;
            conv1 <= 0;
            conv2 <= 0;
            conv3 <= 0;
          end
          default : begin
            pixel1 <= 0;
            pixel2 <= 0;
            pixel3 <= 0;
            weight1 <= 0;
            weight2 <= 0;
            weight3 <= 0;
            conv1 <= 0;
            conv2 <= 0;
            conv3 <= 0;
          end // case: default
         endcase // case (aludata_f)

         case(write_en) //
          2'b01 : begin //save mult result
            ram_data_array[6] <= multi1;
            ram_data_array[7] <= multi2;
            ram_data_array[8] <= multi3;
          end
          2'b10 : begin //save sum result
            ram_data_array[9] <= sum_result;
          end
          2'b11 : begin
            ram_data_array[10] <= sum_result;
          end
          default : ;
         endcase // case (write_en)
   end // else: !if(!reset_n)
 end // always_ff@ (posedge clk or negedge reset_n)
endmodule // core_ram
