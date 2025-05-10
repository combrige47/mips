module regfile(
	input wire clk,
	input wire we3,
	input wire [4:0] ra1, ra2, wa3,
	input wire [31:0] wd3,
	output wire [31:0] rd1, rd2,

	// 调试接口
	input wire [4:0] debug_addr,           // 输入要读取的寄存器号
	output wire [31:0] debug_data          // 输出该寄存器的值
);

	reg [31:0] rf[31:0];

	always @(negedge clk) begin
		if (we3) begin
			rf[wa3] <= wd3;
		end
	end

	assign rd1 = (ra1 != 0) ? rf[ra1] : 0;
	assign rd2 = (ra2 != 0) ? rf[ra2] : 0;

	// 调试读取端口
	assign debug_data = (debug_addr != 0) ? rf[debug_addr] : 32'b0;

endmodule
