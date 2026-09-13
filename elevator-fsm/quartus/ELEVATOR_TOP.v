
module ELEVATOR_TOP (
    input           CLK,
    input           RST_N,
    input           FPGA_RX,
    input           KEY_OPEN,
    input           KEY_CLOSE,
    input           SW_EMG,
	 input           S_HELP,
    

    output          FPGA_TX,
    output          MOTOR_UP,
    output          MOTOR_DN,
    output          DOOR_OPEN_DRV,
    output          DOOR_CLOSE_DRV,
    output  [5:0]   CURRENT_FLOOR_OUT,
    output  [1:0]   CURRENT_DIR_OUT,
	 output [2:0] CURRENT_STATE,
	 output [1:0] DIR_PREDICTION
);
    
    wire [7:0]  rx_byte;
    wire        rx_dv;
    wire [7:0]  tx_byte;
    wire        tx_dv;
    wire        tx_active;
    wire [5:0]  call_floor;
    wire        call_dir;
    wire        call_valid;       
    wire        car_call_valid;   
    wire        send_error_req;
    wire        tick_1s;


    wire [5:0]  fsm_current_floor;
    wire [1:0]  fsm_current_dir;
    

    reg [25:0] tick_counter;
    always @(posedge CLK or negedge RST_N) begin
        if (!RST_N) tick_counter <= 0;
        else if (tick_counter == 50_000_000 - 1) tick_counter <= 0;
        else tick_counter <= tick_counter + 1;
    end
    assign tick_1s = (tick_counter == 50_000_000 - 1);


    uart_rx u_rx (
	 .CLK(CLK), 
	 .RST_N(RST_N), 
	 .i_Rx_Serial(FPGA_RX), 
	 .o_Rx_DV(rx_dv), 
	 .o_Rx_Byte(rx_byte));
	 
    uart_tx u_tx (
	 .CLK(CLK), 
	 .RST_N(RST_N), 
	 .i_Tx_DV(tx_dv), 
	 .i_Tx_Byte(tx_byte), 
	 .o_Tx_Serial(FPGA_TX), 
	 .o_Tx_Active(tx_active));
    

    cmd_parser u_parser (
        .CLK(CLK), 
        .RST_N(RST_N), 
        .i_Rx_DV(rx_dv), 
        .i_Rx_Byte(rx_byte), 
        .o_CALL_FLOOR(call_floor), 
        .o_CALL_DIR(call_dir), 
        .o_CALL_VALID(call_valid),
        .o_CAR_CALL_VALID(car_call_valid), 
        .o_Send_Error_Req(send_error_req)
    );
    status_transmitter u_transmitter (
	 .CLK(CLK), 
	 .RST_N(RST_N), 
	 .i_Tick_1s(tick_1s), 
	 .i_Send_Error_Req(send_error_req), 
	 .i_Help_Req(S_HELP), 
	 .i_Current_Floor(fsm_current_floor), 
	 .i_Current_Dir(fsm_current_dir), 
	 .i_Tx_Active(tx_active), 
	 .o_Tx_DV(tx_dv), 
	 .o_Tx_Byte(tx_byte));

    ELEVATOR_FSM u_elevator (
        .CLK(CLK), 
        .RST_N(RST_N), 
        .T_TICK(1'b0),
        .CALL_FLOOR(call_floor), 
        .CALL_DIR(call_dir), 
        .CALL_VALID(call_valid), 
        .CAR_CALL_FLOOR(call_floor),       
        .CAR_CALL_VALID(car_call_valid),                    
        .BTN_OPEN(KEY_OPEN), 
        .BTN_CLOSE(KEY_CLOSE), 
        .EMG_STOP(SW_EMG), 
        .MOTOR_UP(MOTOR_UP),
        .MOTOR_DN(MOTOR_DN),
        .DOOR_OPEN_DRV(DOOR_OPEN_DRV),
        .DOOR_CLOSE_DRV(DOOR_CLOSE_DRV),
        .CURRENT_FLOOR(fsm_current_floor), 
        .CURRENT_DIR(fsm_current_dir),
		  .current_state_reg(CURRENT_STATE),
		  .dir_prediction(DIR_PREDICTION)
    );

    assign CURRENT_FLOOR_OUT = fsm_current_floor;
    assign CURRENT_DIR_OUT   = fsm_current_dir;

endmodule
