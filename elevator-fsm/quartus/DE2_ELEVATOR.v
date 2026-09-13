
//`include "ELEVATOR_TOP.v"
//`include "binary_to_7seg.v"
module DE2_ELEVATOR(
    input           CLOCK_50, 
    input   KEY1, KEY0, KEY3,  

    input           UART_RXD,   
    output          UART_TXD,   

    input    SW0, SW17,     

    output  [3:0]  LEDR,       
    output  [2:0]   LEDG,       

    output  [6:0]   HEX0,  
    output  [6:0]   HEX1,
	 output  [6:0]   HEX4,
	 output [6:0] HEX6 
);

    wire        motor_up_wire;
    wire        motor_dn_wire;
    wire        door_open_wire;
    wire        door_close_wire;
    wire [5:0]  current_floor_wire;
    wire [1:0]  current_dir_wire;
	 wire [2:0] current_state_wire;
	 wire [1:0] dir_prediction_wire;

    ELEVATOR_TOP u_elevator_core (
        .CLK            (CLOCK_50),
        .RST_N          (SW0),           
        .FPGA_RX        (UART_RXD),
        .KEY_OPEN       (!KEY0), //LOW          
        .KEY_CLOSE      (!KEY1),          
        .SW_EMG         (SW17),          
        .S_HELP        (!KEY3),
		  
        .FPGA_TX        (UART_TXD),
        .MOTOR_UP       (motor_up_wire),
        .MOTOR_DN       (motor_dn_wire),
        .DOOR_OPEN_DRV  (door_open_wire),
        .DOOR_CLOSE_DRV (door_close_wire),
        .CURRENT_FLOOR_OUT (current_floor_wire),
        .CURRENT_DIR_OUT   (current_dir_wire),
		  .CURRENT_STATE (current_state_wire),
		  .DIR_PREDICTION (dir_prediction_wire)
    );


    assign LEDR[0] = motor_up_wire;
    assign LEDR[1] = motor_dn_wire;
    assign LEDR[2] = door_open_wire;
    assign LEDR[3] = door_close_wire;

   localparam DIR_STOP =2'b00; 
    localparam DIR_UP   = 2'b01;
    localparam DIR_DOWN = 2'b10;
   assign LEDG[0] = (current_dir_wire == 2'b00);
    assign LEDG[1] = (current_dir_wire == 2'b01);   
    assign LEDG[2] = (current_dir_wire == 2'b10);  

    wire [3:0] ones_digit;
    wire [3:0] tens_digit;
	 
	 wire [3:0] state_digit;


    assign ones_digit = current_floor_wire % 10;
    assign tens_digit = current_floor_wire / 10;
	 
	 assign state_digit = current_state_wire % 10;
	 
	 assign HEX4 = (dir_prediction_wire==2'b00)? 7'b0010010 : (dir_prediction_wire == 2'b01)? 7'b1000001 : (dir_prediction_wire == 2'b10)? 7'b0100001 : 7'b1111111;

    binary_to_7seg decoder_ones (
        .binary_in (ones_digit),
        .seg_out   (HEX0)
    );

    binary_to_7seg decoder_tens (
        .binary_in (tens_digit),
        .seg_out   (HEX1)
    );
	 
	 binary_to_7seg decoder_state (
        .binary_in (state_digit),
        .seg_out   (HEX6)
    );

endmodule
