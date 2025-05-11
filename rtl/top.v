module top(
	input wire clk,rst,
	input wire sw,						   //选择输出寄存器还是地�?对应的数�?
	output wire[31:0] writedata,dataadr,
	output wire memwrite,
	input wire [6:0] debug_addr,           // 输入要读取的寄存器号/地址
	output wire [31:0] debug_data          // 输出该寄存器/对应地址的�??
    );

	wire[31:0] pc,instr,readdata,reg_data,addr_data;
	wire [6:0] reg_num,addr;

	assign reg_num = debug_addr;
	assign addr = debug_addr;

	mips mips(clk,rst,pc,instr,memwrite,dataadr,writedata,readdata,reg_num[4:0],reg_data);
	inst_mem imem(.clka(~clk),.addra(pc[31:2]),.douta(instr));
	data_mem dmem(.clka(~clk),.wea(memwrite),.addra(dataadr),.dina(writedata),.douta(readdata),.ena(1'b1),
	.clkb(~clk),.web(1'b0),.addrb({debug_addr}),.doutb(addr_data),.enb(1'b1));

	
	mux2 #(32) mod(addr_data,reg_data,sw,debug_data);
endmodule
