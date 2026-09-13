//`include "EController.v"
//`include "debouncer.v"
module ELEVATOR_FSM(

    input           CLK,
    input           RST_N,
	 input           T_TICK,         
	 input   [5:0]   CALL_FLOOR,
	 input           CALL_DIR,
	 input           CALL_VALID,
	 input   [5:0]   CAR_CALL_FLOOR,
	 input           CAR_CALL_VALID,
	 input           BTN_OPEN,
	 input           BTN_CLOSE,
	 input           EMG_STOP,

	 output          MOTOR_UP,
    output          MOTOR_DN,
    output          DOOR_OPEN_DRV,
    output          DOOR_CLOSE_DRV,
    output  [5:0]   CURRENT_FLOOR,
    output  [1:0]   CURRENT_DIR,
	 output [2:0]current_state_reg,
	 output [1:0] dir_prediction
);


   wire  btn_open_wire, btn_close_wire;

    EController u_ec (
        .CLK            (CLK),
        .RSTN           (RST_N),
        .CALL_FLOOR     (CALL_FLOOR),
        .CALL_DIR       (CALL_DIR),
        .CALL_VALID     (CALL_VALID),
		  .CAR_CALL_FLOOR (CAR_CALL_FLOOR),
		  .CAR_CALL_VALID (CAR_CALL_VALID), 
        .BTN_OPEN       (btn_open_wire),
        .BTN_CLOSE      (btn_close_wire),
        .EMG_STOP       (EMG_STOP),
        .T_TICK         (T_TICK), 
        
        .MOTOR_UP       (MOTOR_UP),
        .MOTOR_DN       (MOTOR_DN),
        .DOOR_OPEN_DRV  (DOOR_OPEN_DRV),
        .DOOR_CLOSE_DRV (DOOR_CLOSE_DRV),
        .current_dir  (CURRENT_DIR),
		  .dir_prediction (dir_prediction), 
        .real_floor  (CURRENT_FLOOR),
		  .current_state (current_state_reg)
    );

   debouncer d0(
		// Outputs
		.btn_open_out		(btn_open_wire),
		.btn_close_out		(btn_close_wire),
		// Inputs
		.CLK			(CLK),
		.RSTN			(RST_N),
		.btn_open		(BTN_OPEN),
		.btn_close		(BTN_CLOSE));



endmodule
