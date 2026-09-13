module core_3by3 (
   input logic clk,
   input logic reset_n,

     input logic [15:0] ext_data_in_row0, // For C00
     input logic [15:0] ext_data_in_row1, // For C10
     input logic [15:0] ext_data_in_row2, // For C20

     input logic [15:0] ext_sum_in_col0, // For C00
     input logic [15:0] ext_sum_in_col1, // For C01
     input logic [15:0] ext_sum_in_col2, // For C02

     output logic [15:0] final_sum_out_col0, // From C20
     output logic [15:0] final_sum_out_col1, // From C21
     output logic [15:0] final_sum_out_col2, // From C22

     output logic [15:0] ext_data_out_row0, // From C02
     output logic [15:0] ext_data_out_row1, // From C12
     output logic [15:0] ext_data_out_row2 // From C22
);


     // Horizontal data pass-through (left to right)
     logic [15:0] data_c00_c01, data_c01_c02;
     logic [15:0] data_c10_c11, data_c11_c12;
     logic [15:0] data_c20_c21, data_c21_c22;

     // Vertical sum pass-through (top to bottom)
     logic [15:0] sum_c00_c10, sum_c10_c20;
     logic [15:0] sum_c01_c11, sum_c11_c21;
     logic [15:0] sum_c02_c12, sum_c12_c22;

     // Row 0
     core_topmodule C00 (
        .clk(clk), .reset_n(reset_n),
        .data_in_from_ext(ext_data_in_row0),    // Left input from external
        .sum_in_from_prev_core(ext_sum_in_col0), // Top input from external
        .data_out_to_ext(data_c00_c01),      // Right output to C01
        .sum_out_to_next_core(sum_c00_c10)        // Bottom output to C10



111
  );
  core_topmodule C01 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(data_c00_c01),      // Left input from C00
     .sum_in_from_prev_core(ext_sum_in_col1), // Top input from external
     .data_out_to_ext(data_c01_c02),      // Right output to C02
     .sum_out_to_next_core(sum_c01_c11)         // Bottom output to C11
  );
  core_topmodule C02 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(data_c01_c02),      // Left input from C01
     .sum_in_from_prev_core(ext_sum_in_col2), // Top input from external
     .data_out_to_ext(ext_data_out_row0),     // Right output to external
     .sum_out_to_next_core(sum_c02_c12)         // Bottom output to C12
  );

  // Row 1
  core_topmodule C10 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(ext_data_in_row1),    // Left input from external
     .sum_in_from_prev_core(sum_c00_c10),        // Top input from C00
     .data_out_to_ext(data_c10_c11),      // Right output to C11
     .sum_out_to_next_core(sum_c10_c20)         // Bottom output to C20
  );
  core_topmodule C11 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(data_c10_c11),      // Left input from C10
     .sum_in_from_prev_core(sum_c01_c11),        // Top input from C01
     .data_out_to_ext(data_c11_c12),      // Right output to C12
     .sum_out_to_next_core(sum_c11_c21)         // Bottom output to C21
  );
  core_topmodule C12 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(data_c11_c12),      // Left input from C11
     .sum_in_from_prev_core(sum_c02_c12),        // Top input from C02
     .data_out_to_ext(ext_data_out_row1),     // Right output to external
     .sum_out_to_next_core(sum_c12_c22)         // Bottom output to C22
  );

  // Row 2
  core_topmodule C20 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(ext_data_in_row2),    // Left input from external
     .sum_in_from_prev_core(sum_c10_c20),        // Top input from C10
     .data_out_to_ext(data_c20_c21),      // Right output to C21
     .sum_out_to_next_core(final_sum_out_col0) // Bottom output to external
  );
  core_topmodule C21 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(data_c20_c21),      // Left input from C20
     .sum_in_from_prev_core(sum_c11_c21),        // Top input from C11
     .data_out_to_ext(data_c21_c22),      // Right output to C22
     .sum_out_to_next_core(final_sum_out_col1) // Bottom output to external
  );
  core_topmodule C22 (
     .clk(clk), .reset_n(reset_n),
     .data_in_from_ext(data_c21_c22),      // Left input from C21
     .sum_in_from_prev_core(sum_c12_c22),        // Top input from C12
     .data_out_to_ext(ext_data_out_row2),     // Right output to external
     .sum_out_to_next_core(final_sum_out_col2) // Bottom output to external
  );

endmodule
