module core_mult(input logic [15:0] pixel1, pixel2, pixel3, weight1, weight2, weight3,
                    input logic mult_f,
                    output logic [15:0] multi1, multi2,multi3);
  always_comb begin
    multi1 = 0;
    multi2 = 0;
    multi3 = 0;
    if(mult_f) begin
           multi1 = pixel1 * weight1;
           multi2 = pixel2 * weight2;
           multi3 = pixel3 * weight3;
    end
  end
endmodule // core_mult
