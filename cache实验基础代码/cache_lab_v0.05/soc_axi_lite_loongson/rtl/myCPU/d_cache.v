module d_cache_4way #( 
    parameter WAY_NUM = 4,
    parameter INDEX_WIDTH = 8,
    parameter OFFSET_WIDTH = 2
)(
    input wire clk, rst,
    // mips core
    input         cpu_data_req,
    input         cpu_data_wr,
    input  [1 :0] cpu_data_size,
    input  [31:0] cpu_data_addr,
    input  [31:0] cpu_data_wdata,
    output [31:0] cpu_data_rdata,
    output        cpu_data_addr_ok,
    output        cpu_data_data_ok,

    // axi interface
    output         cache_data_req,
    output         cache_data_wr,
    output  [1 :0] cache_data_size,
    output  [31:0] cache_data_addr,
    output  [31:0] cache_data_wdata,
    input   [31:0] cache_data_rdata,
    input          cache_data_addr_ok,
    input          cache_data_data_ok
);

localparam TAG_WIDTH = 32 - INDEX_WIDTH - OFFSET_WIDTH;
localparam SET_NUM = 1 << INDEX_WIDTH;
localparam LRU_BITS = WAY_NUM - 1;

// Cache storage
reg                 cache_valid [SET_NUM-1:0][WAY_NUM-1:0];
reg [TAG_WIDTH-1:0] cache_tag   [SET_NUM-1:0][WAY_NUM-1:0];
reg [31:0]          cache_block [SET_NUM-1:0][WAY_NUM-1:0];
reg [LRU_BITS-1:0]  lru_tree    [SET_NUM-1:0];

// Address decode
wire [OFFSET_WIDTH-1:0] offset   = cpu_data_addr[OFFSET_WIDTH-1:0];
wire [INDEX_WIDTH-1:0] set_idx   = cpu_data_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];
wire [TAG_WIDTH-1:0]   tag       = cpu_data_addr[31:INDEX_WIDTH+OFFSET_WIDTH];

// Hit detection
wire [WAY_NUM-1:0] way_valid;
wire [WAY_NUM-1:0] way_hit;

generate
    genvar i;
    for (i = 0; i < WAY_NUM; i = i + 1) begin : way_check
        assign way_valid[i] = cache_valid[set_idx][i];
        assign way_hit[i]   = way_valid[i] && (cache_tag[set_idx][i] == tag);
    end
endgenerate

wire hit = |way_hit;

// Hit way index
reg [1:0] hit_index;
always @(*) begin
    hit_index = 2'd0;
    for (integer j = 0; j < WAY_NUM; j=j+1) begin
        if (way_hit[j]) hit_index = j[1:0];
    end
end

// FSM
localparam IDLE = 2'b00, RM = 2'b01, WM = 2'b11;
reg [1:0] state;
always @(posedge clk) begin
    if (rst) state <= IDLE;
    else begin
        case(state)
            IDLE:   state <= cpu_data_req & ~cpu_data_wr & ~hit ? RM :
                             cpu_data_req & cpu_data_wr         ? WM : IDLE;
            RM:     state <= cache_data_data_ok ? IDLE : RM;
            WM:     state <= cache_data_data_ok ? IDLE : WM;
        endcase
    end
end

// AXI handshake
reg addr_rcv, waddr_rcv;
always @(posedge clk) begin
    addr_rcv <= rst ? 1'b0 : (cache_data_req & cache_data_addr_ok ? 1'b1 : cache_data_data_ok ? 1'b0 : addr_rcv);
    waddr_rcv <= rst ? 1'b0 : (cache_data_req & cache_data_addr_ok ? 1'b1 : cache_data_data_ok ? 1'b0 : waddr_rcv);
end

wire read_req = state == RM;
wire write_req = state == WM;
wire read_finish = read_req & cache_data_data_ok;
wire write_finish = write_req & cache_data_data_ok;

assign cpu_data_rdata = hit ? cache_block[set_idx][hit_index] : cache_data_rdata;
assign cpu_data_addr_ok = hit || (cache_data_req && cache_data_addr_ok);
assign cpu_data_data_ok = hit || cache_data_data_ok;

assign cache_data_req   = (read_req & ~addr_rcv) | (write_req & ~waddr_rcv);
assign cache_data_wr    = cpu_data_wr;
assign cache_data_size  = cpu_data_size;
assign cache_data_addr  = cpu_data_addr;
assign cache_data_wdata = cpu_data_wdata;

// Victim selection via pseudo LRU
function [1:0] select_victim;
    input [2:0] tree;
    casez(tree)
        3'b0??: select_victim = (tree[1] == 0) ? 2'd0 : 2'd1;
        3'b1??: select_victim = (tree[2] == 0) ? 2'd2 : 2'd3;
    endcase
endfunction
wire [1:0] victim_way = select_victim(lru_tree[set_idx]);

// Update LRU state
function [2:0] update_lru;
    input [1:0] used_way;
    case (used_way)
        2'd0: update_lru = 3'b000;
        2'd1: update_lru = 3'b001;
        2'd2: update_lru = 3'b100;
        2'd3: update_lru = 3'b101;
    endcase
endfunction

// Tag & index save
reg [TAG_WIDTH-1:0] tag_save;
reg [INDEX_WIDTH-1:0] index_save;
always @(posedge clk) begin
    if (cpu_data_req) begin
        tag_save <= tag;
        index_save <= set_idx;
    end
end

// Fill cache on miss
always @(posedge clk) begin
    if (rst) begin
        for (integer i = 0; i < SET_NUM; i=i+1) begin
            for (integer j = 0; j < WAY_NUM; j=j+1) begin
                cache_valid[i][j] <= 0;
            end
            lru_tree[i] <= 0;
        end
    end else begin
        if (read_finish) begin
            cache_valid[index_save][victim_way] <= 1'b1;
            cache_tag[index_save][victim_way] <= tag_save;
            cache_block[index_save][victim_way] <= cache_data_rdata;
            lru_tree[index_save] <= update_lru(victim_way);
        end else if (hit && cpu_data_wr) begin
            cache_block[set_idx][hit_index] <= cpu_data_wdata; // assume full word write
            lru_tree[set_idx] <= update_lru(hit_index);
        end
    end
end

endmodule
