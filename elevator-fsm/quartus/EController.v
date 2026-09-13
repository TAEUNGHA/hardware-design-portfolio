//`include "tickgen.v"
module EController(/*AUTOARG*/
   // Outputs
   current_dir, real_floor, MOTOR_UP, MOTOR_DN, DOOR_OPEN_DRV,
   DOOR_CLOSE_DRV, current_state, dir_prediction,
   // Inputs
   CLK, RSTN, CALL_FLOOR, CAR_CALL_FLOOR, CAR_CALL_VALID, CALL_DIR, CALL_VALID, BTN_OPEN, BTN_CLOSE,
   EMG_STOP, T_TICK
   );
   input CLK, RSTN;
   input [5:0] CALL_FLOOR, CAR_CALL_FLOOR;
   input       CALL_DIR, CALL_VALID, CAR_CALL_VALID;
   input	BTN_OPEN, BTN_CLOSE, EMG_STOP;
   input	T_TICK;
   //output reg	MOTOR_UP, MOTOR_DN, DOOR_OPEN_DRV, DOOR_CLOSE_DRV;
   output [1:0] current_dir;
	output [1:0] dir_prediction;
	output reg [2:0] current_state;
   output [5:0]	    real_floor;
   output	    MOTOR_UP, MOTOR_DN, DOOR_OPEN_DRV, DOOR_CLOSE_DRV;
   reg [5:0] current_floor; //parameter control

   localparam	    MAX_FLOOR = 32; // change to parameter

   reg [MAX_FLOOR+1:0] hall_up, hall_down, car_call; //min 1 floar, max 30 floar
   reg [MAX_FLOOR+1:0] next_hall_up, next_hall_down, next_car_call;
   // parameter control
   reg [1:0]	       current_move_count, next_move_count;
   reg	[1:0]	       current_open_count, next_open_count;
   reg		       current_door_count, next_door_count;
   //reg		       next_MOTOR_UP, next_MOTOR_DN, next_DOOR_OPEN_DRV, next_DOOR_CLOSE_DRV;
   reg [2:0]	       next_state;
   reg [5:0]	       next_floor;
   reg		       m_eb, d_eb, o_eb;

   reg [2:0]	       backup_state; //back up for EMG
   reg [1:0]	       backup_move_count, backup_open_count; //back up for EMG

   reg		       current_emg_flag, next_emg_flag;	// information to write back backup data

	reg [1:0] current_dir_save, next_dir_save; //expect for future dir
	
   wire		       m_tick, d_tick, o_tick;
	
	 wire utu_hit;
    wire utd_hit;
    wire dtd_hit;
    wire dtu_hit;

   tickgen t0(
	      // Outputs
	      .tick			(m_tick),
	      // Inputs
	      .CLK			(CLK),
	      .RSTN			(RSTN),
	      .enable			(m_eb));
   tickgen t1(
	      // Outputs
	      .tick			(d_tick),
	      // Inputs
	      .CLK			(CLK),
	      .RSTN			(RSTN),
	      .enable			(d_eb));
   tickgen t2(
	      // Outputs
	      .tick			(o_tick),
	      // Inputs
	      .CLK			(CLK),
	      .RSTN			(RSTN),
	      .enable			(o_eb));
  
   localparam	S_IDLE_STOP = 3'b000;
   localparam	S_DOOR_OPENING = 3'b001;
   localparam	S_DOOR_CLOSING = 3'b010;
   localparam	S_MOVING_UP = 3'b011;
   localparam	S_MOVING_DOWN = 3'b100;
   localparam	S_DWELL = 3'b101;
   localparam	S_EMG = 3'b110;
	
	localparam s_stop = 2'b00;
	localparam s_up = 2'b01;
	localparam s_down = 2'b10;

   always@(posedge CLK or negedge RSTN)begin
      if(!RSTN)begin
	 current_state <= S_IDLE_STOP;
	 current_floor <= 6'd1;
	 
	 current_dir_save <= s_stop;
	 
	 current_emg_flag <= 0;
	 
	 current_move_count <= 0;
	 current_open_count <= 0;
	 current_door_count <= 0;
	 
	 hall_up <= 0;
	 hall_down <= 0;
	 car_call <= 0;
      end
      else begin
	 if(EMG_STOP && current_state != S_EMG)begin
	    backup_state <= current_state;
	    backup_move_count <= current_move_count;
	    backup_open_count <= current_open_count;
	 end
	 if(current_state == S_IDLE_STOP && current_emg_flag)begin
	    backup_state <= 0;
	    current_move_count <= backup_move_count;
	    current_open_count <= backup_open_count;
		 backup_move_count <= 0;
		 backup_open_count <= 0;
	 end
	 
	 current_state <= next_state;
	 current_floor <= next_floor;
	 
	 current_dir_save <= next_dir_save;
	 
	 current_emg_flag <= next_emg_flag;
	 
	 current_move_count <= next_move_count;
	 current_open_count <= next_open_count;
	 current_door_count <= next_door_count;

	 hall_up <= next_hall_up;
	 hall_down <= next_hall_down;
	 car_call <= next_car_call;
  
      end
   end // always@ (posedge CLK or negedge RSTN)
   
   assign utu_hit = |(hall_up>>(current_floor+1) | car_call>>(current_floor+1));
   assign utd_hit = |(hall_down >> (current_floor + 2));
   assign dtd_hit = |(hall_down << (MAX_FLOOR - (current_floor -2)) | car_call << (MAX_FLOOR - (current_floor-2)));
   assign dtu_hit = |(hall_up << (MAX_FLOOR - (current_floor - 3)));
   
   always@(*)begin
      next_state = current_state;
      next_floor = current_floor;
		next_dir_save = current_dir_save;
      
      m_eb = 0;
      d_eb = 0;
      o_eb = 0;
      
      next_emg_flag = current_emg_flag;
      
      next_move_count = current_move_count;
      next_open_count = current_open_count;
      next_door_count = current_door_count;

      next_hall_up = hall_up;
      next_hall_down = hall_down;
      next_car_call = car_call;

      if(CALL_VALID)begin
	 if(CALL_DIR) begin
	    if (CALL_FLOOR>=1 && CALL_FLOOR<=32) next_hall_up[CALL_FLOOR] = 1;
	    else next_hall_up[CALL_FLOOR] = 0;
	 end
	 else begin
	    if (CALL_FLOOR>=1 && CALL_FLOOR<= 32) next_hall_down[CALL_FLOOR] = 1;
	    else next_hall_down[CALL_FLOOR] = 0;
	 end
      end
      
		if(CAR_CALL_VALID) begin
		  if(CAR_CALL_FLOOR>=1 && CAR_CALL_FLOOR<=32) next_car_call[CAR_CALL_FLOOR] = 1;
		end
      
      if(EMG_STOP)begin
	 next_state = S_EMG;
      end
      else begin
	 case(current_state)
	   S_IDLE_STOP : begin
	      if(current_emg_flag) begin
		 next_emg_flag = 0;
		 next_state = backup_state;
	      end // if (current_emg_flag)
	      else begin
		 if(BTN_OPEN)begin // BTN_OPEN, BTN_CLOSE not the same with hall
		    next_state = S_DOOR_OPENING;
		 end
		 
		 else if(hall_up[current_floor] || hall_down[current_floor]||car_call[current_floor])begin
		    next_state = S_DOOR_OPENING;
		    next_hall_up[current_floor] = 0;
		    next_hall_down[current_floor] = 0;
			 next_car_call[current_floor] = 0;
		 end
		 
		 else if(utu_hit) begin
		    next_state = S_MOVING_UP;
			 next_dir_save = s_up;
		 end
		 else if(utd_hit||hall_down[current_floor+1]) begin
		    next_state = S_MOVING_UP;
			 next_dir_save = s_up;
		 end
		 else if(dtd_hit) begin
		    next_state = S_MOVING_DOWN;
			 next_dir_save = s_down;
		 end
		 else if(dtu_hit||hall_up[current_floor - 1]) begin
		    next_state = S_MOVING_DOWN;
			 next_dir_save = s_down;
		 end
		 
		 else begin
		    next_state = S_IDLE_STOP;
			 next_dir_save = s_stop;
		 end			   
	      end // else: !if(current_emg_flag)
	   end // case: S_IDLE_STOP
		
	   S_DOOR_OPENING : begin
	      d_eb = 1;
			if(d_eb && d_tick) next_door_count = current_door_count + 1;
	      if(current_door_count ==1 ) begin
		 next_state = S_DWELL;
		 next_door_count = 0;
	      end // if (d_tick)
	   end // case: S_DOOR_OPENING
		
	   S_DOOR_CLOSING : begin
	      d_eb = 1;
			if(d_eb && d_tick) next_door_count = current_door_count + 1;
	      if(current_door_count==1) begin
			  if(current_dir_save == s_up) begin
		      if(utu_hit||utd_hit||hall_down[current_floor+1])begin
		         next_state = S_MOVING_UP;
		         next_door_count = 0;
					next_dir_save = s_up;
		       end // if (utu_hit(current_floor, hall_up, car_call)||utd_hit(current_floor,hall_down))
		       else if(dtd_hit||dtu_hit||hall_up[current_floor-1])begin
		         next_state = S_MOVING_DOWN;
		         next_door_count = 0;
					next_dir_save = s_down;
		       end // if (dtd_hit(current_floor, hall_up, car_call)||dtu_hit(current_floor, hall_down, car_call))
		       else begin
		         next_state = S_IDLE_STOP;
		         next_door_count = 0;
		         next_hall_up[current_floor] = 0;
		         next_hall_down[current_floor] = 0;
		         next_car_call[current_floor] = 0;
					next_dir_save = s_stop;
		       end
	        end
			 else if(current_dir_save == s_down) begin
			    if(dtd_hit||dtu_hit||hall_up[current_floor-1])begin
		         next_state = S_MOVING_DOWN;
		         next_door_count = 0;
		       end // if (utu_hit(current_floor, hall_up, car_call)||utd_hit(current_floor,hall_down))
		       else if(utu_hit||utd_hit||hall_down[current_floor+1])begin
		         next_state = S_MOVING_UP;
		         next_door_count = 0;
		       end // if (dtd_hit(current_floor, hall_up, car_call)||dtu_hit(current_floor, hall_down, car_call))
		       else begin
		         next_state = S_IDLE_STOP;
		         next_door_count = 0;
		         next_hall_up[current_floor] = 0;
		         next_hall_down[current_floor] = 0;
		         next_car_call[current_floor] = 0;
		       end
	        end
			  else begin
			    	next_state = S_IDLE_STOP;
		         next_door_count = 0;
		         next_hall_up[current_floor] = 0;
		         next_hall_down[current_floor] = 0;
		         next_car_call[current_floor] = 0;
					next_dir_save = s_stop;
		       end
          end // This 'end' was missing
	   end // case: S_DOOR_CLOSING
		
	   S_MOVING_UP : begin
	      m_eb = 1;
			next_dir_save = s_up;
			
		   if(m_eb && m_tick) next_move_count = current_move_count + 1;
	      if(current_move_count == 2)begin
		 if(utu_hit)begin
		    if(hall_up[current_floor+1] || car_call[current_floor+1])begin
		       next_state = S_DOOR_OPENING;
		       next_floor = current_floor+1;
		       next_move_count = 0;
		       next_hall_up[current_floor+1] = 0;
		       next_car_call[current_floor+1] = 0;
		    end
		    else begin
		       next_state = S_MOVING_UP;
		       next_floor = current_floor+1;
		       next_move_count = 0;
		    end // else: !if(hall_up[current_floor+1] || car_call[current_floor+1])
		 end // if (utu_hit(current_floor, hall_up, car_call))
		 
		 else if(utd_hit) begin
		       next_state = S_MOVING_UP;
		       next_floor = current_floor + 1;
		       next_move_count = 0;
		     end // else: !if(hall_down[current_floor+1])
			  
		 else if(hall_down[current_floor+1]) begin
		       next_state = S_DOOR_OPENING;
		       next_floor = current_floor + 1;
		       next_move_count = 0;
		       next_hall_down[current_floor+1] = 0;
				 next_dir_save = s_down;
		     end
		    else if(dtd_hit|| dtu_hit||hall_up[current_floor - 1])begin
		       next_state = S_MOVING_DOWN;
		       next_floor = current_floor + 1;
		       next_move_count = 0;
				 next_dir_save = s_down;
		    end
		    else begin
		       next_state = S_IDLE_STOP;
		       next_floor = current_floor + 1;
		       next_move_count = 0;
				 next_dir_save = s_stop;
		    end
		 end // if (move_count == 2)
	   end // case: S_MOVING_UP
		
	   S_MOVING_DOWN : begin
	      m_eb = 1;
			next_dir_save = s_down;
			
	    if(m_eb && m_tick) next_move_count = current_move_count + 1;
		 if(current_move_count == 2)begin
		    if(dtd_hit)begin
		       if(car_call[current_floor-1]||hall_down[current_floor-1])begin
			  next_state = S_DOOR_OPENING;
			  next_floor = current_floor-1;
			  next_move_count = 0;
			  next_hall_down[current_floor - 1] = 0;
			  next_car_call[current_floor - 1] = 0;
		       end
		       else begin
			  next_state = S_MOVING_DOWN; //maybe go to stop
			  next_floor = current_floor-1;
			  next_move_count = 0;
		       end // else: !if(hall_up[current_floor+1]||car_call[current_floor+1]||hall_down[current_floor+1])
		    end // if (utu_hit(current_floor, hall_up, car_call)||utd_hit(current_floor,hall_down))

		    else if(dtu_hit)begin
			  next_state = S_MOVING_DOWN;
			  next_floor = current_floor-1;
			  next_move_count = 0;
		     end // else: !if(hall_up[current_floor-1])
			  
			  else if(hall_up[current_floor-1])begin
			  next_state = S_DOOR_OPENING;
			  next_floor = current_floor-1;
			  next_move_count = 0;
			  next_hall_up[current_floor - 1] = 0;
			  next_dir_save = s_up;
		     end

		    else if(utu_hit||utd_hit||hall_down[current_floor + 1])begin
		       next_state = S_MOVING_UP;
		       next_floor = current_floor - 1;
		       next_move_count = 0;
				 next_dir_save = s_up;
		    end
		    else begin
		       next_state = S_IDLE_STOP;
		       next_floor = current_floor - 1;
		       next_move_count = 0;
				 next_dir_save = s_stop;
		    end
		 end // if (current_move_count == 1)
	   end // case: S_MOVING_DOWN
		
	   S_DWELL : begin
	      o_eb = 1;
			next_car_call[current_floor] = 0;
			if(o_eb && o_tick) next_open_count = current_open_count + 1;
	      if(BTN_OPEN)begin
			   o_eb = 0;
		      next_state = S_DWELL;
		      next_open_count = 0;
	      end
			else if((current_dir_save == s_up) && hall_up[current_floor]) begin
			     o_eb = 0;
				  next_state = S_DWELL;
				  next_open_count = 0;
				  next_hall_up[current_floor] = 0;
		     end
					
			else if((current_dir_save == s_down) && hall_down[current_floor]) begin
			     o_eb = 0;
				  next_state = S_DWELL;
				  next_open_count = 0;
				  next_hall_up[current_floor] = 0;
		     end
			
			else if((current_dir_save == s_stop) && (hall_down[current_floor]||hall_up[current_floor])) begin
			     o_eb = 0;
				  next_state = S_DWELL;
				  next_open_count = 0;
				  next_hall_up[current_floor] = 0;
				  next_hall_down[current_floor] = 0;
		     end
			  
	      else if(BTN_CLOSE)begin
		     next_state = S_DOOR_CLOSING;
		     next_open_count = 0;
	      end
		   else if(current_open_count==3)begin
		    next_state = S_DOOR_CLOSING;
		    next_open_count = 0;
		   end
	   end // case: S_DWELL
		
	   S_EMG : begin
	      if(EMG_STOP!=1)begin
		 next_state = S_IDLE_STOP;
		 next_emg_flag = 1;
	      end	   
	   end
	 endcase // case (current_state) - Changed from 'endcase'
    end // else: !if(EMG_STOP)
   end // always@ (*)

   assign real_floor = next_floor;
	assign dir_prediction = next_dir_save;

   assign MOTOR_UP = (next_state==S_MOVING_UP)? 1 : 0;
   assign MOTOR_DN = (next_state==S_MOVING_DOWN)? 1 : 0;
   assign DOOR_OPEN_DRV = (next_state==S_DOOR_OPENING)? 1 : 0;
   assign DOOR_CLOSE_DRV = (next_state==S_DOOR_CLOSING)? 1 : 0;

   localparam DIR_STOP = 2'b00;
   localparam DIR_UP = 2'b01;
   localparam DIR_DOWN = 2'b10;
   
   assign current_dir = (next_state == S_MOVING_UP)? DIR_UP : (next_state == S_MOVING_DOWN) ? DIR_DOWN : DIR_STOP;
   
endmodule // EController
	
