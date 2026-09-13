

# --- 1. Base Clock Constraint ---
create_clock -name "sys_clk" -period 20.000 -waveform {0.0 10.0} [get_ports CLOCK_50]


# --- 2. Input Delay Constraints ---
set_input_delay -clock "sys_clk" -max 5.0 [get_ports {KEY[*] SW[*] UART_RXD}]
set_input_delay -clock "sys_clk" -min 1.0 [get_ports {KEY[*] SW[*]}]

# For UART, a more precise hold constraint is often better if known, but 1.0 is a safe start.
set_input_delay -clock "sys_clk" -min 0.5 [get_ports {UART_RXD}]


# --- 3. Output Delay Constraints ---
set_output_delay -clock "sys_clk" -max 5.0 [get_ports {LEDR[*] UART_TXD}]
set_output_delay -clock "sys_clk" -min 1.0 [get_ports {LEDR[*] UART_TXD}]


# --- 4. Asynchronous Paths and False Paths ---


# --- 5. Report Unconstrained Paths (Optional) ---

