`timescale 1ns / 1ps


module testbench();
	reg clk;
	reg rst;

	wire[31:0] writedata,dataadr;
	wire memwrite,sw;
	wire [6:0] debug_addr;
	wire [31:0] debug_data;
	assign sw = 0;
	assign debug_addr = 7'd84;
	top dut(clk,rst,sw,writedata,dataadr,memwrite,debug_addr,debug_data);

	initial begin 
		rst <= 1;
		#200;
		rst <= 0;
	end

	always begin
		clk <= 1;
		#10;
		clk <= 0;
		#10;
	
	end

	always @(posedge clk) begin
	$display("debug_addr:%h,debug_data:%d",debug_addr,debug_data);
		if(memwrite) begin
			/* code */
			if(dataadr === 84 & writedata === 7) begin
				/* code */
				$display("Simulation succeeded");
				#100;
				$display("debug_addr:%h,debug_data:%d",debug_addr,debug_data);
				$stop;
			end else if(dataadr !== 80) begin
				/* code */
				#100;
				$display("Simulation Failed");
				$stop;
			end
		end
	end
endmodule
