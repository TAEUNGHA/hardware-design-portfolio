module core_topmodule (
   input logic clk,
   input logic reset_n,
   input logic [15:0] data_in_from_ext,
   input logic [15:0] sum_in_from_prev_core, // after change total bit because it can be 17 bit

     output logic [15:0] data_out_to_ext,
     output logic [15:0] sum_out_to_next_core       // 17 bit
);

      logic [1:0] exe_data_f_ctrl;
      logic     stack_f_ctrl;
      logic [1:0] stack_mode_ctrl;
      logic [1:0] save_f_ctrl;
      logic [1:0] out_f_ctrl;
      logic [1:0] write_en_ctrl;
      logic [1:0] pc_f_ctrl;
      logic     mult_f_ctrl;
      logic     adder_f_ctrl;
      logic     count_reg1_f_from_decoder;
      logic     count_reg2_f_from_decoder;
     logic other_f_from_decoder;
     logic [7:0]        inst_in_from_ram_output;

     logic [4:0] pc_out_val;




109
  logic [15:0] pixel1_val, pixel2_val, pixel3_val;
  logic [15:0] weight1_val, weight2_val, weight3_val;
  logic [15:0] conv1_val, conv2_val, conv3_val;

  logic [15:0] multi1_res, multi2_res, multi3_res;

  logic [15:0] sum_result_res;

  core_pc u_core_pc (
     .clk     (clk),
     .reset_n    (reset_n),
     .count_reg1_f (count_reg1_f_from_decoder),
     .count_reg2_f (count_reg2_f_from_decoder),
                        .other_f (other_f_from_decoder),
     .pc_f     (pc_f_ctrl),
     .pc_out     (pc_out_val)
  );

  core_decoder u_core_decoder (
     .inst_in  (inst_in_from_ram_output),
     .exe_data_f (exe_data_f_ctrl),
     .stack_f   (stack_f_ctrl),
     .stack_mode (stack_mode_ctrl),
     .save_f    (save_f_ctrl),
     .out_f    (out_f_ctrl),
     .write_en (write_en_ctrl),
     .pc_f    (pc_f_ctrl),
     .mult_f    (mult_f_ctrl),
     .adder_f    (adder_f_ctrl),
     .count_reg1_f (count_reg1_f_from_decoder),
     .count_reg2_f (count_reg2_f_from_decoder),
                                   .other_f (other_f_from_decoder)
  );

  core_ram u_core_ram (
     .clk     (clk),
     .reset_n      (reset_n),
     .exe_data_f (exe_data_f_ctrl),
     .save_f     (save_f_ctrl),
     .out_f     (out_f_ctrl),
     .write_en (write_en_ctrl),
     .stack_f    (stack_f_ctrl),
     .stack_mode (stack_mode_ctrl),
     .pc_in     (pc_out_val),
     .data_in      (data_in_from_ext),
     .sum_in        (sum_in_from_prev_core),
     .multi1      (multi1_res),
     .multi2      (multi2_res),
     .multi3      (multi3_res),
     .sum_result (sum_result_res),
     .pixel1     (pixel1_val),
     .pixel2     (pixel2_val),
     .pixel3     (pixel3_val),
     .weight1       (weight1_val),
     .weight2       (weight2_val),
     .weight3       (weight3_val),
     .conv1       (conv1_val),
     .conv2       (conv2_val),
     .conv3       (conv3_val),
     .inst_out (inst_in_from_ram_output),
     .sum_out        (sum_out_to_next_core),
     .transfer_out (data_out_to_ext)
  );

  core_mult u_core_mult (



110
          .pixel1  (pixel1_val),
          .pixel2  (pixel2_val),
          .pixel3  (pixel3_val),
          .weight1   (weight1_val),
          .weight2   (weight2_val),
          .weight3   (weight3_val),
          .mult_f   (mult_f_ctrl),
          .multi1   (multi1_res),
          .multi2   (multi2_res),
          .multi3   (multi3_res)
     );

     core_adder u_core_adder (
        .conv1    (conv1_val),
        .conv2    (conv2_val),
        .conv3    (conv3_val),
        .adder_f   (adder_f_ctrl),
        .sum_result (sum_result_res)
     );

endmodule // core_topmodule
