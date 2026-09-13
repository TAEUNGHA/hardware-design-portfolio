//`include "ELEVATOR_FSM.v"
`timescale 1ns/1ps

module TB_ELEVATOR_TOP;

    reg         CLK;
    reg         RST_N;
    reg         T_TICK;
    reg  [5:0]  CALL_FLOOR;
    reg         CALL_DIR;
    reg         CALL_VALID;
    reg         BTN_OPEN;
    reg         BTN_CLOSE;
    reg         EMG_STOP;

    wire        MOTOR_UP;
    wire        MOTOR_DN;
    wire        DOOR_OPEN_DRV;
    wire        DOOR_CLOSE_DRV;
    wire [5:0]  CURRENT_FLOOR;
    wire [1:0]  CURRENT_DIR;

    reg  [5:0]  expected_floor;

    ELEVATOR_FSM
       dut (
        .CLK            (CLK),
        .RST_N          (RST_N),
        .T_TICK         (T_TICK),
        .CALL_FLOOR     (CALL_FLOOR),
        .CALL_DIR       (CALL_DIR),
        .CALL_VALID     (CALL_VALID),
        .BTN_OPEN       (BTN_OPEN),
        .BTN_CLOSE      (BTN_CLOSE),
        .EMG_STOP       (EMG_STOP),
        .MOTOR_UP       (MOTOR_UP),
        .MOTOR_DN       (MOTOR_DN),
        .DOOR_OPEN_DRV  (DOOR_OPEN_DRV),
        .DOOR_CLOSE_DRV (DOOR_CLOSE_DRV),
        .CURRENT_FLOOR  (CURRENT_FLOOR),
        .CURRENT_DIR    (CURRENT_DIR)
    );

    initial CLK = 0;
    always #10 CLK = ~CLK;

    initial T_TICK = 0;
    always begin
        #100_000 T_TICK = 1;
        #20      T_TICK = 0;
    end

    integer fd;
    integer pass_cnt, fail_cnt;

    task send_call(input [5:0] floor, input dir);
    begin
        @(posedge CLK);
        CALL_FLOOR <= floor;
        CALL_DIR   <= dir;
        CALL_VALID <= 1;
        @(posedge CLK);
        CALL_VALID <= 0;
        CALL_FLOOR <= 0;
    end
    endtask

    task wait_ticks(input integer n);
        integer i;
    begin
        for (i=0; i<n; i=i+1)
            @(posedge T_TICK);
    end
    endtask

    task press_open(input integer ticks);
        integer i;
    begin
        BTN_OPEN <= 1;
        for (i=0; i<ticks; i=i+1)
            @(posedge T_TICK);
        BTN_OPEN <= 0;
    end
    endtask

    task press_close;
    begin
        @(posedge T_TICK);
        BTN_CLOSE <= 1;
        @(posedge T_TICK);
        BTN_CLOSE <= 0;
    end
    endtask

    task press_emg(input integer ticks);
        integer i;
    begin
        EMG_STOP <= 1;
        for (i=0; i<ticks; i=i+1)
            @(posedge T_TICK);
        EMG_STOP <= 0;
    end
    endtask

    task check_floor(
        input integer case_id,
        input integer step_id,
        input [5:0]  exp_floor
    );
    begin
        
        @(negedge CLK);
        expected_floor = exp_floor;
        if (CURRENT_FLOOR == exp_floor) begin
            pass_cnt++;
            $fdisplay(fd, "CASE %0d STEP %0d : PASS (floor=%0d)", case_id, step_id, CURRENT_FLOOR);
        end else begin
            fail_cnt++;
            $fdisplay(fd, "CASE %0d STEP %0d : FAIL (got=%0d expect=%0d)", case_id, step_id, CURRENT_FLOOR, exp_floor);
        end
    end
    endtask

    initial begin

      // $dumpfile("TB_ELEVATOR_TOP_V31.vcd");
      // $dumpvars(0, TB_ELEVATOR_TOP);
        RST_N          = 0;
        CALL_FLOOR     = 0;
        CALL_DIR       = 1;
        CALL_VALID     = 0;
        BTN_OPEN       = 0;
        BTN_CLOSE      = 0;
        EMG_STOP       = 0;
        expected_floor = 0;

        fd = $fopen("report.txt", "w");
        pass_cnt = 0;
        fail_cnt = 0;
        $fdisplay(fd, "==== ELEVATOR FSM TEST REPORT ====");

        wait_ticks(1);
        RST_N = 1;
        wait_ticks(1);

        // ====================================================
        // 1-1) 5UP 15UP 31UP *5->12->31*
        // ====================================================
        $fdisplay(fd, "===== 1-1) 5UP 15UP 31UP =====");
        send_call(6'd5, 1);
        wait_ticks(1);
        send_call(6'd15, 1);
        wait_ticks(1);
        send_call(6'd31, 1);
        wait_ticks(6);
        check_floor(1, 1, 6'd5);
        wait_ticks(5);
        wait_ticks(20);
        check_floor(1, 2, 6'd15);
        wait_ticks(5);
        wait_ticks(32);
        check_floor(1, 3, 6'd31);
        // ====================================================
        // 1-2) 32DN 17DN 1DN  *32->17->1*
        // ====================================================
        $fdisplay(fd, "===== 1-2) 32DN 17DN 1DN =====");
        send_call(6'd32, 0);
        wait_ticks(1);
        send_call(6'd17, 0);
        wait_ticks(1);
        send_call(6'd1, 0);
        wait_ticks(5);
        check_floor(1, 4, 6'd32);
        wait_ticks(5);
        wait_ticks(30);
        check_floor(1, 5, 6'd17);
        wait_ticks(5);
        wait_ticks(32);
        check_floor(1, 6, 6'd1);

        // ====================================================
        // 2-1) 4UP 10UP 8UP *4->8->10*
        // ====================================================
        $fdisplay(fd, "===== 2-1) 4UP 10UP 8UP =====");
        wait_ticks(5);
        send_call(6'd4, 1);
        wait_ticks(1);
        send_call(6'd10, 1);
        wait_ticks(1);
        send_call(6'd8, 1);
        wait_ticks(4);
        check_floor(2, 1, 6'd4);
        wait_ticks(5);
        wait_ticks(8);
        check_floor(2, 2, 6'd8);
        wait_ticks(5);
        wait_ticks(4);
        check_floor(2, 3, 6'd10);

        // ====================================================
        // 2-2) 9DN 1DN 4DN  *9->4->1*
        // ====================================================
        $fdisplay(fd, "===== 2-2) 9DN 1DN 4DN =====");
        wait_ticks(5);
        send_call(6'd9, 0);
        wait_ticks(1);
        send_call(6'd1, 0);
        wait_ticks(1);
        send_call(6'd4, 0);
        check_floor(2, 4, 6'd9);
        wait_ticks(5);
        wait_ticks(10);
        check_floor(2, 5, 6'd4);
        wait_ticks(5);
        wait_ticks(6);
        check_floor(2, 6, 6'd1);

        // ====================================================
        // 3-1) 3UP 8UP 2DN *3->8->2*
        // ====================================================
        $fdisplay(fd, "===== 3-1) 3UP 8UP 2DN =====");
        wait_ticks(5);
        send_call(6'd3, 1);
        wait_ticks(1);
        send_call(6'd8, 1);
        wait_ticks(1);
        send_call(6'd2, 0);
        wait_ticks(2);
        check_floor(3, 1, 6'd3);
        wait_ticks(5);
        wait_ticks(10);
        check_floor(3, 2, 6'd8);
        wait_ticks(5);
        wait_ticks(12);
        check_floor(3, 3, 6'd2);

        // ====================================================
        // 3-2) 4DN 8DN 2UP *4->8->2*
        // ====================================================
        $fdisplay(fd, "===== 3-2) 4DN 8DN 2UP =====");
        wait_ticks(5);
        send_call(6'd4, 0);
        wait_ticks(1);
        send_call(6'd8, 0);
        wait_ticks(1);
        send_call(6'd2, 1);
        wait_ticks(2);
        check_floor(3, 4, 6'd4);
        wait_ticks(5);
        wait_ticks(8);
        check_floor(3, 5, 6'd8);
        wait_ticks(5);
        wait_ticks(12);
        check_floor(3, 6, 6'd2);

        // ====================================================
        // 4-1) 9UP 3DN 12UP *9->12->3*
        // ====================================================
        $fdisplay(fd, "===== 4-1) 9UP 3DN 12UP =====");
        wait_ticks(5);
        send_call(6'd9, 1);
        wait_ticks(1);
        send_call(6'd3, 0);
        wait_ticks(1);
        send_call(6'd12, 1);
        wait_ticks(12);
        check_floor(4, 1, 6'd9);
        wait_ticks(5);
        wait_ticks(6);
        check_floor(4, 2, 6'd12);
        wait_ticks(5);
        wait_ticks(18);
        check_floor(4, 3, 6'd3);

        // ====================================================
        // 4-2) 10DN 2UP 3DN *10->3->2*
        // ====================================================
        $fdisplay(fd, "===== 4-2) 10DN 2UP 3DN =====");
        wait_ticks(5);
        send_call(6'd10, 0);
        wait_ticks(1);
        send_call(6'd2, 1);
        wait_ticks(1);
        send_call(6'd3, 0);
        wait_ticks(12);
        check_floor(4, 4, 6'd10);
        wait_ticks(5);
        wait_ticks(14);
        check_floor(4, 5, 6'd3);
        wait_ticks(5);
        wait_ticks(2);
        check_floor(4, 6, 6'd2);

        // ====================================================
        // 5) 3UP 10DN 10UP 15UP *3->10->15->10*
        // ====================================================
        $fdisplay(fd, "===== 5) 3UP 10DN 10UP 15UP =====");
        wait_ticks(1);
        send_call(6'd3, 1);
        wait_ticks(1);
        send_call(6'd10, 0);
        wait_ticks(1);
        send_call(6'd10, 1);
        wait_ticks(1);
        send_call(6'd15, 1);
        wait_ticks(3);
        check_floor(5, 1, 6'd3);
        wait_ticks(5);
        wait_ticks(14);
        check_floor(5, 2, 6'd10);
        wait_ticks(5);
        wait_ticks(10);
        check_floor(5, 3, 6'd15);
        wait_ticks(5);
        wait_ticks(10);
        check_floor(5, 4, 6'd10);

        // ====================================================
        // 6) BTN OPEN/CLOSE
        // ====================================================
        $fdisplay(fd, "===== 6) BTN OPEN/CLOSE =====");
        send_call(6'd5, 1);
        wait_ticks(5);
        wait_ticks(10);
        send_call(6'd7, 1);
        press_open(5);
        wait_ticks(5);
        send_call(6'd4, 0);
        check_floor(6, 1, 6'd5);
        $fdisplay(fd, "CASE 6 : PASS (OPEN)");
        wait_ticks(5);
        press_close();
        wait_ticks(7);
        check_floor(6, 1, 6'd4);
        $fdisplay(fd, "CASE 6 : PASS (CLOSE)");

        // ====================================================
        // 7) EMG TEST
        // ====================================================
       wait_ticks(5); 
       $fdisplay(fd, "===== 7) EMG TEST =====");
        send_call(6'd20, 1);
        wait_ticks(3);
        press_emg(5);
        wait_ticks(30);
        check_floor(7, 1, 6'd20);
        $fdisplay(fd, "CASE 7 : PASS (EMG)");

        $fdisplay(fd, "===================================");
        $fdisplay(fd, "TOTAL PASS = %0d", pass_cnt);
        $fdisplay(fd, "TOTAL FAIL = %0d", fail_cnt);
        $fdisplay(fd, "===================================");
        $fclose(fd);
        $finish;
    end

endmodule
