`timescale 1ns / 1ps


module testbench();
	reg clk;
	reg rst;

	wire[31:0] writedata,dataadr,instr;
	wire memwrite,flushE,stallD,jumpD;

	top dut(clk,rst,writedata,dataadr,memwrite);

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
		if(memwrite) begin
			/* code */
			if(dataadr === 84 & writedata === 7) begin
				/* code */
				$display("Simulation succeeded");
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
