module core_3by3_tb;

  localparam CLK_PERIOD = 10;
  localparam CMD_CYCLE = CLK_PERIOD * 2;

  logic clk;
  logic reset_n;

  logic [15:0] tb_ext_data_in_row0;
  logic [15:0] tb_ext_data_in_row1;
  logic [15:0] tb_ext_data_in_row2;

  logic [15:0] tb_ext_sum_in_col0;
  logic [15:0] tb_ext_sum_in_col1;
  logic [15:0] tb_ext_sum_in_col2;

  logic [15:0] tb_final_sum_out_col0;
  logic [15:0] tb_final_sum_out_col1;
  logic [15:0] tb_final_sum_out_col2;

  logic [15:0] tb_ext_data_out_row0;
  logic [15:0] tb_ext_data_out_row1;
  logic [15:0] tb_ext_data_out_row2;

  core_3by3 dut (
     .clk(clk),
     .reset_n(reset_n),
     .ext_data_in_row0(tb_ext_data_in_row0),
     .ext_data_in_row1(tb_ext_data_in_row1),
     .ext_data_in_row2(tb_ext_data_in_row2),
     .ext_sum_in_col0(tb_ext_sum_in_col0),
     .ext_sum_in_col1(tb_ext_sum_in_col1),
     .ext_sum_in_col2(tb_ext_sum_in_col2),
     .final_sum_out_col0(tb_final_sum_out_col0),
     .final_sum_out_col1(tb_final_sum_out_col1),
     .final_sum_out_col2(tb_final_sum_out_col2),
     .ext_data_out_row0(tb_ext_data_out_row0),
     .ext_data_out_row1(tb_ext_data_out_row1),
     .ext_data_out_row2(tb_ext_data_out_row2)
  );

  always #(CLK_PERIOD/2) clk = ~clk;

  // Test data
  byte image[5][5] = '{
     '{1, 2, 3, 4, 5},
     '{6, 7, 8, 9, 1},
     '{2, 3, 4, 5, 6},
     '{7, 8, 9, 1, 2},
     '{3, 4, 5, 6, 7}
  };

  byte filter_kernel[3][3] = '{
     '{1, 0, 1},
     '{0, 1, 0},
     '{1, 0, 1}
  };

  initial begin
     clk = 0;
     reset_n = 0;



113
      tb_ext_data_in_row0 = 0;
      tb_ext_data_in_row1 = 0;
      tb_ext_data_in_row2 = 0;
      tb_ext_sum_in_col0 = 0;
      tb_ext_sum_in_col1 = 0;
      tb_ext_sum_in_col2 = 0;

      #(CLK_PERIOD * 2);
      reset_n = 1;

      //#15;

      #(CMD_CYCLE); // inst[0] (Nope)

      #(CMD_CYCLE); // inst[1] (stack1 weight)
      #(CMD_CYCLE); // inst[2] (stack2 weight)
      tb_ext_data_in_row0 = filter_kernel[0][0]; // F00
      tb_ext_data_in_row1 = filter_kernel[1][0]; // F10
      tb_ext_data_in_row2 = filter_kernel[2][0]; // F20
      #(CMD_CYCLE); // inst[3]
      #(CMD_CYCLE); // inst[4]
      tb_ext_data_in_row0 = filter_kernel[0][0]; // F01
      tb_ext_data_in_row1 = filter_kernel[1][0]; // F11
      tb_ext_data_in_row2 = filter_kernel[2][0]; // F21
      #(CMD_CYCLE); // inst[5]
      #(CMD_CYCLE); // inst[6]
      tb_ext_data_in_row0 = filter_kernel[0][0]; // F02
      tb_ext_data_in_row1 = filter_kernel[1][0]; // F12
      tb_ext_data_in_row2 = filter_kernel[2][0]; // F22
      #(CMD_CYCLE); // inst[7]
      #(CMD_CYCLE); // inst[8]

      #(CMD_CYCLE); // inst[1]
      #(CMD_CYCLE); // inst[2]
      tb_ext_data_in_row0 = filter_kernel[0][1];
      tb_ext_data_in_row1 = filter_kernel[1][1];
      tb_ext_data_in_row2 = filter_kernel[2][1];
      #(CMD_CYCLE); //inst[3]
      #(CMD_CYCLE); // inst[4]
      tb_ext_data_in_row0 = filter_kernel[0][1];
      tb_ext_data_in_row1 = filter_kernel[1][1];
      tb_ext_data_in_row2 = filter_kernel[2][1];
      #(CMD_CYCLE);//inst[5]
      #(CMD_CYCLE); // inst[6]
      tb_ext_data_in_row0 = filter_kernel[0][1];
      tb_ext_data_in_row1 = filter_kernel[1][1];
      tb_ext_data_in_row2 = filter_kernel[2][1];
      #(CMD_CYCLE); //inst[7]
      #(CMD_CYCLE); // inst[8] (Jump to 1). PC=1, count_reg1=2.

      #(CMD_CYCLE*2); // inst[1], inst[2]
      tb_ext_data_in_row0 = filter_kernel[0][2];
      tb_ext_data_in_row1 = filter_kernel[1][2];
      tb_ext_data_in_row2 = filter_kernel[2][2];
      #(CMD_CYCLE); //inst[3]
      #(CMD_CYCLE); // inst[4]
      tb_ext_data_in_row0 = filter_kernel[0][2];
      tb_ext_data_in_row1 = filter_kernel[1][2];
      tb_ext_data_in_row2 = filter_kernel[2][2];
      #(CMD_CYCLE); //inst[5]
      #(CMD_CYCLE); // inst[6]
      tb_ext_data_in_row0 = filter_kernel[0][2];
      tb_ext_data_in_row1 = filter_kernel[1][2];
      tb_ext_data_in_row2 = filter_kernel[2][2];
      #(CMD_CYCLE); //inst[7]



114
      #(CMD_CYCLE); // inst[8] (Jump). PC is 9


      #(CMD_CYCLE*3); // PC=9,10,11 (stack, stack, transfer)
      tb_ext_data_in_row0 = image[0][0]; // P00
      tb_ext_data_in_row1 = image[1][0]; // P10
      tb_ext_data_in_row2 = image[2][0]; // P20
      #(CMD_CYCLE); //inst[12]
      #(CMD_CYCLE); // PC=13 (Jump to 9). PC=9, count_reg1=1.

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[0][1]; // P01
      tb_ext_data_in_row1 = image[1][1]; // P11
      tb_ext_data_in_row2 = image[2][1]; // P21
      #(CMD_CYCLE); //PC=12
      #(CMD_CYCLE); // PC=13 (Jump to 9). PC=9, count_reg1=2.

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[0][2]; // P02
      tb_ext_data_in_row1 = image[1][2]; // P12
      tb_ext_data_in_row2 = image[2][2]; // P22
      #(CMD_CYCLE*2); //PC 12,13

       #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[0][3]; // P02
      tb_ext_data_in_row1 = image[1][3]; // P12
      tb_ext_data_in_row2 = image[2][3]; // P22
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[0][4]; // P02
      tb_ext_data_in_row1 = image[1][4]; // P12
      tb_ext_data_in_row2 = image[2][4]; // P22
      #(CMD_CYCLE); //PC=12
      #(CMD_CYCLE); // PC=13 (Jump). PC=14
      #(CMD_CYCLE); //PC=14, mult
      #(CMD_CYCLE); //PC=15, add conv
      #(CMD_CYCLE); //PC=16, load sum(reset first temp_sum)
      #(CMD_CYCLE); //PC=17, add sum
      #(CMD_CYCLE); //PC=18, Transfer sum
      #(CMD_CYCLE); //PC=19, load sum
      #(CMD_CYCLE); //PC=20, add sum
      #(CMD_CYCLE); //PC=21, transfer sum
      #(CMD_CYCLE); //PC=22, load sum
      #(CMD_CYCLE); //PC=23, add sum
      #(CMD_CYCLE); //PC=24, tranfer sum
      #(CMD_CYCLE); //PC=25, Jump to 9 or 0


      #(CMD_CYCLE*3); // PC=9,10,11 (stack, stack, transfer)
      tb_ext_data_in_row0 = image[1][0]; // P10
      tb_ext_data_in_row1 = image[2][0]; // P20
      tb_ext_data_in_row2 = image[3][0]; // P30
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[1][1]; // P11
      tb_ext_data_in_row1 = image[2][1]; // P21
      tb_ext_data_in_row2 = image[3][1]; // P31
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[1][2]; // P12
      tb_ext_data_in_row1 = image[2][2]; // P22
      tb_ext_data_in_row2 = image[3][2]; // P32



115
      #(CMD_CYCLE*2);

       #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[1][3]; // P12
      tb_ext_data_in_row1 = image[2][3]; // P22
      tb_ext_data_in_row2 = image[3][3]; // P32
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[1][4]; // P12
      tb_ext_data_in_row1 = image[2][4]; // P22
      tb_ext_data_in_row2 = image[3][4]; // P32
      #(CMD_CYCLE*2);
      #(CMD_CYCLE*12);

      #(CMD_CYCLE*3); // PC=9,10,11 (stack, stack, transfer)
      tb_ext_data_in_row0 = image[2][0]; // P20
      tb_ext_data_in_row1 = image[3][0]; // P30
      tb_ext_data_in_row2 = image[4][0]; // P40
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[2][1]; // P21
      tb_ext_data_in_row1 = image[3][1]; // P31
      tb_ext_data_in_row2 = image[4][1]; // P41
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[2][2]; // P22
      tb_ext_data_in_row1 = image[3][2]; // P32
      tb_ext_data_in_row2 = image[4][2]; // P42
      #(CMD_CYCLE*2);

       #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[2][3]; // P22
      tb_ext_data_in_row1 = image[3][3]; // P32
      tb_ext_data_in_row2 = image[4][3]; // P42
      #(CMD_CYCLE*2);

      #(CMD_CYCLE*3); // PC=9,10,11
      tb_ext_data_in_row0 = image[2][4]; // P22
      tb_ext_data_in_row1 = image[3][4]; // P32
      tb_ext_data_in_row2 = image[4][4]; // P42
      #(CMD_CYCLE*2);
      #(CMD_CYCLE*12);

      #(CLK_PERIOD * 50);

    $finish;
  end
endmodule
