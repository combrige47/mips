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
    reg                 cache_dirty [SET_NUM-1:0][WAY_NUM-1:0];  // 每个组的两路脏位
    reg [TAG_WIDTH-1:0] cache_tag   [SET_NUM-1:0][WAY_NUM-1:0];  // 每个组的两路标签
    reg [31:0]          cache_block [SET_NUM-1:0][WAY_NUM-1:0];  // 每个组的两路数据
    reg                 lru_bit     [SET_NUM-1:0];  // LRU位（用于替换策略）

    // 访问地址分解
    wire [OFFSET_WIDTH-1:0] offset = cpu_data_addr[OFFSET_WIDTH-1:0];
    wire [INDEX_WIDTH-1:0] set_idx = cpu_data_addr[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];  // 组索引
    wire [TAG_WIDTH-1:0] tag = cpu_data_addr[31:INDEX_WIDTH+OFFSET_WIDTH];

    // 访问Cache line
    wire way0_valid = cache_valid[set_idx][0];
    wire way1_valid = cache_valid[set_idx][1];
    wire way0_dirty = cache_dirty[set_idx][0];
    wire way1_dirty = cache_dirty[set_idx][1];
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

    // 选择要替换的路
    wire replace_way = lru_bit[set_idx];  // LRU位为0选择路0，为1选择路1
    wire replace_way_dirty = replace_way ? way1_dirty : way0_dirty;
    wire replace_way_valid = replace_way ? way1_valid : way0_valid;

    // 保存地址中的tag, index，防止addr发生改变
    reg [TAG_WIDTH-1:0] tag_save;
    reg [INDEX_WIDTH-1:0] index_save;
    reg [1:0] way_save; // 保存命中的路
    always @(posedge clk) begin
        tag_save   <= rst ? 0 :
                      cpu_data_req ? tag : tag_save;
        index_save <= rst ? 0 :
                      cpu_data_req ? set_idx : index_save;
        way_save   <= rst ? 0 :
                      hit ? (hit_way0 ? 2'b00 : 2'b01) : way_save;
    end

    // FSM状态定义
    parameter IDLE      = 3'b000,  // 空闲状态
              WRITEBACK = 3'b001,  // 写回脏数据
              READ_MEM  = 3'b010,  // 从内存读取数据
              WRITE_HIT = 3'b011,  // 写命中
              WRITE_MISS = 3'b100; // 写缺失

    reg [2:0] state;
    reg [2:0] next_state;
    
    // 状态转移逻辑
    always @(posedge clk) begin
        if(rst) begin
            state <= IDLE;
        end
        else begin
            state <= next_state;
        end
    end
    
    // 组合逻辑：确定下一状态
    always @(*) begin
        case(state)
            IDLE: begin
                if(cpu_data_req) begin
                    if(read) begin
                        if(hit)
                            next_state = IDLE; // 读命中，直接返回数据
                        else begin
                            if(replace_way_valid && replace_way_dirty)
                                next_state = WRITEBACK; // 读缺失且替换的行是脏的，先写回
                            else
                                next_state = READ_MEM; // 读缺失但替换的行是干净的，直接读取
                        end
                    end
                    else begin // write
                        if(hit)
                            next_state = WRITE_HIT; // 写命中
                        else begin
                            if(replace_way_valid && replace_way_dirty)
                                next_state = WRITEBACK; // 写缺失且替换的行是脏的，先写回
                            else
                                next_state = WRITE_MISS; // 写缺失但替换的行是干净的，直接写分配
                        end
                    end
                end
                else
                    next_state = IDLE;
            end
            
            WRITEBACK: begin
                if(cache_data_data_ok) begin // 写回完成
                    if(read)
                        next_state = READ_MEM; // 写回后读内存
                    else
                        next_state = WRITE_MISS; // 写回后写分配
                end
                else
                    next_state = WRITEBACK;
            end
            
            READ_MEM: begin
                if(cache_data_data_ok) // 读内存完成
                    next_state = IDLE;
                else
                    next_state = READ_MEM;
            end
            
            WRITE_HIT: begin
                next_state = IDLE; // 写命中直接完成
            end
            
            WRITE_MISS: begin
                next_state = IDLE; // 写分配完成
            end
            
            default: next_state = IDLE;
        endcase
    end

    // 控制信号
    wire do_writeback = (state == WRITEBACK);
    wire do_read_mem = (state == READ_MEM);
    wire do_write_hit = (state == WRITE_HIT);
    wire do_write_miss = (state == WRITE_MISS);

    // 读内存控制
    wire read_req;
    reg addr_rcv;
    wire read_finish;
    always @(posedge clk) begin
        addr_rcv <= rst ? 1'b0 :
                    do_read_mem & cache_data_req & cache_data_addr_ok ? 1'b1 :
                    read_finish ? 1'b0 : addr_rcv;
    end
    assign read_req = do_read_mem;
    assign read_finish = do_read_mem & cache_data_data_ok;

    // 写内存控制（写回操作）
    wire writeback_req;
    reg wb_addr_rcv;
    wire writeback_finish;
    always @(posedge clk) begin
        wb_addr_rcv <= rst ? 1'b0 :
                     do_writeback & cache_data_req & cache_data_addr_ok ? 1'b1 :
                     writeback_finish ? 1'b0 : wb_addr_rcv;
    end
    assign writeback_req = do_writeback;
    assign writeback_finish = do_writeback & cache_data_data_ok;

    // 写掩码生成
    wire [3:0] write_mask;
    assign write_mask = cpu_data_size==2'b00 ?
                            (cpu_data_addr[1] ? (cpu_data_addr[0] ? 4'b1000 : 4'b0100):
                                                (cpu_data_addr[0] ? 4'b0010 : 4'b0001)) :
                            (cpu_data_size==2'b01 ? (cpu_data_addr[1] ? 4'b1100 : 4'b0011) : 4'b1111);

    // 生成写入Cache的数据
    wire [31:0] write_cache_data;
    assign write_cache_data = hit ? 
                             (hit_way0 ? 
                              (cache_block[set_idx][0] & ~{{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}}) | 
                              (cpu_data_wdata & {{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}}) :
                              (cache_block[set_idx][1] & ~{{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}}) | 
                              (cpu_data_wdata & {{8{write_mask[3]}}, {8{write_mask[2]}}, {8{write_mask[1]}}, {8{write_mask[0]}}})) :
                             cpu_data_wdata; // 写缺失时直接写入完整数据

    // LRU位更新
    always @(posedge clk) begin
        if (rst) begin
            for (integer i = 0; i < SET_NUM; i = i + 1) begin
                lru_bit[i] <= 1'b0;  // 初始化为0
            end
        end else if (hit && (read || do_write_hit)) begin
            // 命中时更新LRU位（将命中的路标记为最近使用）
            if (hit_way0) lru_bit[set_idx] <= 1'b1;  // 命中路0，标记路1为LRU
            if (hit_way1) lru_bit[set_idx] <= 1'b0;  // 命中路1，标记路0为LRU
        end else if (read_finish || do_write_miss) begin
            // 缺失时更新LRU位（将新填充的路标记为最近使用）
            lru_bit[set_idx] <= replace_way;  // 替换了哪一路，就将另一路标记为最近使用
        end
    end

    // 写入缓存
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
                cache_valid[set_idx][replace_way] <= 1'b1;
                cache_dirty[set_idx][replace_way] <= 1'b0;
                cache_tag[set_idx][replace_way] <= tag;
                cache_block[set_idx][replace_way] <= cache_data_rdata;
            end else if (do_write_hit) begin  // 写命中
                if (hit_way0) begin
                    cache_block[set_idx][0] <= write_cache_data;
                    cache_dirty[set_idx][0] <= 1'b1;
                end
                if (hit_way1) begin
                    cache_block[set_idx][1] <= write_cache_data;
                    cache_dirty[set_idx][1] <= 1'b1;
                end
            end else if (do_write_miss) begin  // 写缺失（写分配）
                cache_valid[set_idx][replace_way] <= 1'b1;
                cache_dirty[set_idx][replace_way] <= 1'b1;
                cache_tag[set_idx][replace_way] <= tag;
                cache_block[set_idx][replace_way] <= write_cache_data;
            end else if (writeback_finish) begin  // 写回完成后，将脏位清零
                cache_dirty[index_save][replace_way] <= 1'b0;
            end
        end
    end

    // 输出到MIPS核心
    assign cpu_data_rdata   = hit ? 
                             (hit_way0 ? cache_block[set_idx][0] : cache_block[set_idx][1]) : 
                             cache_data_rdata;
    assign cpu_data_addr_ok = (read && hit && cpu_data_req) || 
                             (cache_data_req && cache_data_addr_ok);
    assign cpu_data_data_ok = (read && hit && cpu_data_req) || 
                             ((read && read_finish) || (write && (do_write_hit || do_write_miss)));

    // 输出到AXI接口
    assign cache_data_req   = writeback_req & ~wb_addr_rcv | read_req & ~addr_rcv;
    assign cache_data_wr    = writeback_req;  // 只有写回操作才需要向内存写数据
    assign cache_data_size  = 2'b10;  // 总是以字为单位进行内存访问
    assign cache_data_addr  = do_writeback ? 
                             {cache_tag[index_save][replace_way], index_save, 2'b00} :  // 写回时使用保存的地址
                             cpu_data_addr & 32'hFFFFFFFC;  // 读取时使用当前地址（按字对齐）
    assign cache_data_wdata = do_writeback ? 
                             (replace_way ? cache_block[index_save][1] : cache_block[index_save][0]) : 
                             32'h0;  // 写回时使用缓存中的数据

endmodule    