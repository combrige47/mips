module d_cache (
    input wire clk, rst,
    //mips core
    input         cpu_data_req     ,
    input         cpu_data_wr      ,
    input  [1 :0] cpu_data_size    ,
    input  [31:0] cpu_data_addr    ,
    input  [31:0] cpu_data_wdata   ,
    output [31:0] cpu_data_rdata   ,
    output        cpu_data_addr_ok ,
    output        cpu_data_data_ok ,

    //axi interface
    output         cache_data_req     ,
    output         cache_data_wr      ,
    output  [1 :0] cache_data_size    ,
    output  [31:0] cache_data_addr    ,
    output  [31:0] cache_data_wdata   ,
    input   [31:0] cache_data_rdata   ,
    input          cache_data_addr_ok ,
    input          cache_data_data_ok 
);

    // Cache配置
    parameter  WAY_NUM      = 2;                // 路数
    parameter  INDEX_WIDTH  = 9, OFFSET_WIDTH = 2;  // 索引宽度减少1位（组数减半）
    localparam TAG_WIDTH    = 32 - INDEX_WIDTH - OFFSET_WIDTH;
    localparam SET_NUM      = 1 << INDEX_WIDTH; // 组数

    // Cache存储单元
    reg                 cache_valid [SET_NUM-1:0][WAY_NUM-1:0];  // 每个组的两路有效位
    reg [TAG_WIDTH-1:0] cache_tag   [SET_NUM-1:0][WAY_NUM-1:0];  // 每个组的两路标签
    reg [31:0]          cache_block [SET_NUM-1:0][WAY_NUM-1:0];  // 每个组的两路数据
    reg                 lru_bit     [SET_NUM-1:0];  // LRU位（用于替换策略）
    reg                 cache_dirty [SET_NUM-1:0][WAY_NUM-1:0];//脏位，用于存储cache是否为脏

    // 访问地址分解
    wire [OFFSET_WIDTH-1:0] offset = cpu_data_addr[OFFSET_WIDTH-1:0];
    wire [INDEX_WIDTH-1:0] set_idx = cpu_data_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];  // 组索引
    wire [TAG_WIDTH-1:0] tag = cpu_data_addr[31:INDEX_WIDTH+OFFSET_WIDTH];

    // 访问Cache line
    wire way0_valid = cache_valid[set_idx][0];
    wire way1_valid = cache_valid[set_idx][1];
    wire way0_tag_match = (cache_tag[set_idx][0] == tag);
    wire way1_tag_match = (cache_tag[set_idx][1] == tag);

    // 判断是否命中
    wire hit = (way0_valid && way0_tag_match) || (way1_valid && way1_tag_match);
    wire hit_way0 = way0_valid && way0_tag_match;  // 命中第0路
    wire hit_way1 = way1_valid && way1_tag_match;  // 命中第1路

    // 读或写
    wire read, write;
    assign write = cpu_data_wr;
    assign read = ~write;

    // FSM
    parameter IDLE = 2'b00, RM = 2'b01, WM = 2'b11;
    reg [1:0] state;
    always @(posedge clk) begin
        if(rst) begin
            state <= IDLE;
        end
        else begin
            case(state)
                IDLE:   state <= cpu_data_req & read & ~hit ? RM :
                                 cpu_data_req & read & hit  ? IDLE :
                                 cpu_data_req & write       ? WM : IDLE;
                RM:     state <= read & cache_data_data_ok ? IDLE : RM;
                WM:     state <= write & cache_data_data_ok ? IDLE : WM;
            endcase
        end
    end
    
    // 读内存
    // 变量read_req, addr_rcv, read_finish用于构造类sram信号。
    wire read_req;      // 一次完整的读事务，从发出读请求到结束
    reg addr_rcv;       // 地址接收成功(addr_ok)后到结束
    wire read_finish;   // 数据接收成功(data_ok)，即读请求结束
    always @(posedge clk) begin
        addr_rcv <= rst ? 1'b0 :
                    read & cache_data_req & cache_data_addr_ok ? 1'b1 :
                    read_finish ? 1'b0 : addr_rcv;
    end
    assign read_req = state==RM;
    assign read_finish = read & cache_data_data_ok;

    // 写内存
    wire write_req;     
    reg waddr_rcv;      
    wire write_finish;   
    always @(posedge clk) begin
        waddr_rcv <= rst ? 1'b0 :
                     write & cache_data_req & cache_data_addr_ok ? 1'b1 :
                     write_finish ? 1'b0 : waddr_rcv;
    end
    assign write_req = state==WM;
    assign write_finish = write & cache_data_data_ok;

    // output to mips core
    assign cpu_data_rdata   = hit_way0 ? cache_block[set_idx][0] : 
                                       hit_way1 ? cache_block[set_idx][1] : 
                                       cache_data_rdata;
    assign cpu_data_addr_ok = (read & cpu_data_req & hit | cache_data_req & cache_data_addr_ok);
    assign cpu_data_data_ok = (read & cpu_data_req & hit | cache_data_data_ok);

    // output to axi interface
    assign cache_data_req   = read_req & ~addr_rcv | write_req & ~waddr_rcv;
    assign cache_data_wr    = cpu_data_wr;
    assign cache_data_size  = cpu_data_size;
    assign cache_data_addr  = cpu_data_addr;
    assign cache_data_wr    = cpu_data_wr;
    assign cache_data_wdata = cpu_data_wdata;

    // 写入Cache
    // 保存地址中的tag, index，防止addr发生改变
    reg [TAG_WIDTH-1:0] tag_save;
    reg [INDEX_WIDTH-1:0] index_save;
    always @(posedge clk) begin
        tag_save   <= rst ? 0 :
                      cpu_data_req ? tag : tag_save;
        index_save <= rst ? 0 :
                      cpu_data_req ? set_idx : index_save;
    end

    wire [31:0] write_cache_data;
    wire [3:0] write_mask;

    // 根据地址低两位和size，生成写掩码（针对sb，sh等不是写完整一个字的指令），4位对应1个字（4字节）中每个字的写使能
    assign write_mask = cpu_data_size==2'b00 ?
                            (cpu_data_addr[1] ? (cpu_data_addr[0] ? 4'b1000 : 4'b0100):
                                                (cpu_data_addr[0] ? 4'b0010 : 4'b0001)) :
                            (cpu_data_size==2'b01 ? (cpu_data_addr[1] ? 4'b1100 : 4'b0011) : 4'b1111);

    // 掩码的使用：位为1的代表需要更新的。
    // 位拓展：{8{1'b1}} -> 8'b11111111
    // new_data = old_data & ~mask | write_data & mask
    assign write_cache_data = cache_block[set_idx][hit_way0 ? 0 : 1] & ~{{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}} | 
                              cpu_data_wdata & {{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}};

    // LRU位更新
    always @(posedge clk) begin
        if (rst) begin
            for (integer i = 0; i < SET_NUM; i = i + 1) begin
                lru_bit[i] <= 1'b0;  // 初始化为0
            end
        end else if (hit) begin
            // 命中时更新LRU位（将命中的路标记为最近使用）
            if (hit_way0) lru_bit[set_idx] <= 1'b1;  // 命中路0，标记路1为LRU
            if (hit_way1) lru_bit[set_idx] <= 1'b0;  // 命中路1，标记路0为LRU
        end else if (read_finish || write_finish) begin
            // 缺失时更新LRU位（将新填充的路标记为最近使用）
            lru_bit[set_idx] <= ~lru_bit[set_idx];  // 简单的LRU，每次替换时翻转LRU位
        end
    end

    // 写入缓存（根据替换策略选择路）
    always @(posedge clk) begin
        if (rst) begin
            for (integer i = 0; i < SET_NUM; i = i + 1) begin
                for (integer j = 0; j < WAY_NUM; j = j + 1) begin
                    cache_valid[i][j] <= 1'b0;
                    cache_dirty[i][j] <= 1'b0;
                end
            end
        end else begin
            if (read_finish) begin  // 读缺失，填充缓存
            if (~cache_dirty[set_idx][lru_bit[set_idx]])begin //dirty位为干净
                cache_valid[set_idx][lru_bit[set_idx]] <= 1'b1;
                cache_tag[set_idx][lru_bit[set_idx]] <= tag;
                cache_block[set_idx][lru_bit[set_idx]] <= cache_data_rdata;
            end
            else begin  //dirty位为脏
                /*code*/
                //将脏数据写入内存后读取
                cache_valid[set_idx][lru_bit[set_idx]] <= 1'b1;
                cache_tag[set_idx][lru_bit[set_idx]] <= tag;
                cache_block[set_idx][lru_bit[set_idx]] <= cache_data_rdata;
            end
            end else if (~read_finish)begin //读命中
                //do nothing
            end
            else if (write && cpu_data_req && hit) begin  // 写命中
                if (hit_way0)
                begin cache_block[set_idx][0] <= write_cache_data;
                 cache_dirty[set_idx][0] <= 1;
                    end
                if (hit_way1)begin cache_block[set_idx][1] <= write_cache_data;
                cache_dirty[set_idx][1] <= 1; 
                end
            end else begin  //写缺失
                if (~cache_dirty[set_idx][lru_bit[set_idx]]) begin //dirty位为干净的
                    // to do
                end else begin  //dirty位为脏的

                end
            end
        end
    end

endmodule