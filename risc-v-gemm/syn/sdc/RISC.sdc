####################################
## CLOCK
####################################
create_clock -name CLOCK -period 4  [get_ports CLK]
set_clock_latency 1 [get_clocks CLOCK]
set_clock_uncertainty -setup 0.5 [get_clocks CLOCK]
set_clock_uncertainty -hold  0.1 [get_clocks CLOCK]
set_clock_transition 0.5 [get_clocks CLOCK]

####################################
## RESET
####################################
set_false_path -from [get_ports RSTN] -to [all_registers]

####################################
## INPUTS (CLOCK PERIOD 40%)
####################################
set_input_delay 1.6 -clock CLOCK [remove_from_collection [all_inputs] [get_ports {CLK RSTN}]]
set_input_transition 0.1 [remove_from_collection [all_inputs] [get_ports {CLK RSTN}]]

####################################
## OUTPUTS (CLOCK PERIOD 40%)
####################################
set_output_delay 1.6 -clock CLOCK [all_outputs]
set_load 100 [all_outputs]
