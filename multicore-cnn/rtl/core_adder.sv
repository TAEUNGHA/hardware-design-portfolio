module core_adder(input logic [15:0] conv1, conv2, conv3,
                   input logic          adder_f,
                   output logic [15:0] sum_result);
  always_comb begin
    sum_result = 0;
    if(adder_f)begin
           sum_result = conv1+conv2+conv3;
    end
  end
endmodule // core_adder
