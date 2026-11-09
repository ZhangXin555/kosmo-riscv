`timescale 1ns / 1ps
//==========================================================================
//  top.v — 板级顶层（Kosmo2-MES2K100 / 紫光 PG2K100-6MBG400）
//--------------------------------------------------------------------------
//  这个文件只做三件事：
//    1) 把复位整理干净（按键 + 上电延时）
//    2) 把 CPU、指令 ROM、外设总线桥这三块连起来
//    3) 把"跑了多少毫秒"送到 LED 和串口
//
//  板级资源（已核对）：
//    clk   = T9   50 MHz 有源晶振
//    rst_n = W13  BTN0 按键，低有效
//    led   = LED0..LED4 + LED4_R/G/B，共 8 位，**低电平点亮**
//    uart_tx = J8-23 = W6（J8 是 40Pin 扩展口的第 23 脚）
//
//  串口帧格式（每 0.5 秒发一次，115200 8N1）：
//    AA  m3 m2 m1 m0  XOR      —— 6 字节，m 是 32 位毫秒值的字节
//    最后那个 XOR 是 b0^b1^b2^b3^b4，用来在 PC 端校验
//==========================================================================
module top (
    input  wire       clk,        // 50 MHz 时钟（T9）
    input  wire       rst_n,      // 复位按键（W13），低有效
    output wire [7:0] led,        // 8 个 LED，低电平点亮
    output wire       uart_tx     // 软 UART 发送脚（W6）
);

    //------------------------------------------------------------------
    // 复位同步器
    //   异步按键 rst_n 直接当复位会引入亚稳态，所以先打 4 拍同步。
    //   rst_sync 的每一位都是 rst_n 延迟后的版本，这里只保留结构，
    //   实际逻辑见下面的 DIAG 说明。
    //------------------------------------------------------------------
    reg [3:0] rst_sync;                                   // 4 级同步移位寄存器
    always @(posedge clk) rst_sync <= {rst_sync[2:0], rst_n};  // 每拍把 rst_n 往高位挤

    // 【调试期绕过】上板验证时发现 BTN0 按下去会让 CPU 一直复位，
    //   为了让程序上电就跑，直接把复位钉成 0（不复位）。
    //   正式版应该改成：wire rst = ~rst_sync[3];  // 按键松开后才解除复位
    wire rst = 1'b0;   // DIAG: 忽略 BTN0，上电直接跑

    //------------------------------------------------------------------
    // 总线信号声明（CPU 与外部世界之间的所有线）
    //------------------------------------------------------------------
    wire [31:0] pc, instruction;                 // 取指地址 / 取回的指令
    wire [31:0] perip_addr, perip_wdata, perip_rdata;  // 外设：地址 / 写数据 / 读数据
    wire [31:0] perip_rd_addr;                   // 外设：**读**地址（比写地址早一拍，见下）
    wire        perip_wen;                       // 外设写使能
    wire [1:0]  perip_mask;                      // 访问宽度：00=字节 01=半字 10=字
    wire [39:0] seg40;                           // 数码管段码（本板没接，留空）
    wire [31:0] led32;                           // 外设 LED 寄存器的值（本板没接，留空）
    wire [31:0] ms_value;                        // 计时器的毫秒值
    wire        ms_running;                      // 计时器是否在跑

    //------------------------------------------------------------------
    // CPU 核（真正的流水线都在 myCPU 里）
    //------------------------------------------------------------------
    myCPU Core_cpu (
        .cpu_rst       (rst),                    // 复位
        .cpu_clk       (clk),                    // 时钟
        .irom_addr     (pc),                     // 输出：下一条指令地址
        .irom_data     (instruction),            // 输入：取回的指令
        .perip_addr    (perip_addr),             // 输出：访存地址（MEM 级）
        .perip_rd_addr (perip_rd_addr),          // 输出：读地址（EX 级，提前给）
        .perip_wen     (perip_wen),              // 输出：写使能
        .perip_mask    (perip_mask),             // 输出：访问宽度
        .perip_wdata   (perip_wdata),            // 输出：写数据
        .perip_rdata   (perip_rdata)             // 输入：读回的数据
    );

    //------------------------------------------------------------------
    // 指令 ROM
    //   地址取 pc[13:2]：因为一字 4 字节，所以去掉低 2 位；
    //   只取 14 位 => 16 KB 指令空间，足够放测试固件（2035 条）
    //------------------------------------------------------------------
    IROM Mem_IROM (
        .a   (pc[13:2]),
        .spo (instruction)
    );

    //------------------------------------------------------------------
    // 外设总线桥：地址译码 + 各外设
    //   0x8010_0000 ~ 0x8013_FFFF → DRAM
    //   0x8020_0040 → LED 寄存器
    //   0x8020_0050 → 毫秒计时器
    //------------------------------------------------------------------
    perip_bridge bridge_inst (
        .clk               (clk),
        .cnt_clk           (clk),                // 计时器用同一个时钟
        .rst               (rst),
        .perip_addr        (perip_addr),
        .rd_addr           (perip_rd_addr[17:0]),// **读地址**单独给（见 dram_driver 的注释）
        .perip_wdata       (perip_wdata),
        .perip_wen         (perip_wen),
        .perip_mask        (perip_mask),
        .perip_rdata       (perip_rdata),
        .virtual_sw_input  (64'd0),              // 本板拨码没接，固定 0
        .virtual_key_input (8'hFF),              // 本板按键没接，固定全 1（不按下）
        .virtual_seg_output(seg40),              // 数码管输出（悬空）
        .virtual_led_output(led32),              // 外设 LED 输出（悬空）
        .ms_value          (ms_value),           // 毫秒值 → 送 LED / 串口
        .ms_running        (ms_running)          // 计时状态
    );

    //------------------------------------------------------------------
    // LED 显示
    //   设计意图：led = ~ms_value[7:0]（低 8 位毫秒，取反后输出，
    //   因为 LED 是低电平点亮），程序停表后这个数就"冻住"，
    //   人眼看到的二进制就是最终毫秒数的低 8 位。
    //   正式版改成：assign led = ~ms_value[7:0];
    //------------------------------------------------------------------
    // 【调试期】全 0 = 8 个灯全亮（低有效），用来确认位流真的下载进去了
    assign led = 8'h00;   // DIAG: 全灯亮（低有效）

    //------------------------------------------------------------------
    // 串口发送：把 ms_value 打包成 6 字节帧，每 0.5 秒发一次
    //------------------------------------------------------------------
    ms_uart_tx #(
        .CLK_HZ  (50_000_000),      // 时钟频率
        .BAUD    (115200),          // 波特率
        .GAP_CLK (25_000_000)       // 帧间隔 = 25M 拍 = 0.5 秒
    ) u_ms_tx (
        .clk (clk),
        .rst (rst),
        .ms  (ms_value),            // 要发的毫秒值
        .tx  (uart_tx)              // 输出脚
    );

endmodule


//==========================================================================
//  ms_uart_tx — 软 UART 发送器 + 帧打包器
//--------------------------------------------------------------------------
//  为什么自己写而不用现成的 uart.sv？
//    因为这里要的不只是"发一个字节"，而是"每 0.5 秒自动发一整帧 6 字节"，
//    把打包、间隔、字节序都放在一个模块里更省事。
//
//  结构分两块：
//    (A) 字节串行器：把 1 个字节变成 起始位+8数据位+停止位 的波形
//    (B) 帧打包器：决定"现在该发第几个字节"，并在发完 6 个后等 0.5 秒
//==========================================================================
module ms_uart_tx #(
    parameter integer CLK_HZ  = 50_000_000,   // 时钟频率
    parameter integer BAUD    = 115200,       // 波特率
    parameter integer GAP_CLK = 25_000_000    // 帧间隔（拍数）
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] ms,      // 当前毫秒值
    output wire        tx       // 串口输出
);
    // 1 个 bit 需要多少个时钟周期：50MHz / 115200 = 434.03 → 四舍五入 434
    // 加 BAUD/2 再除，是为了做四舍五入而不是截断
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;   // 50MHz 下 = 434

    //==================================================================
    // (A) 字节串行器
    //==================================================================
    reg  [15:0] cnt;        // 位内计时：0..DIV-1
    reg  [3:0]  bitn;       // 当前发到第几位（0=起始位, 1..8=数据, 9=停止位）
    reg  [9:0]  sh;         // 移位寄存器：{停止位, 8位数据, 起始位}
    reg         busy;       // 正在发送
    reg         tx_r;       // 输出电平

    assign tx = tx_r;       // 输出到端口

    // 下面这组变量属于帧打包器 (B)，因为串行器要用，所以提前声明
    reg [2:0]  bidx;        // 当前发第几个字节 0..5
    reg [7:0]  cur_byte;    // 当前要发的字节
    reg [31:0] ms_lat;      // 帧开始时锁存的毫秒值（防止发送途中数值变化）
    reg [31:0] gap;         // 帧间隔倒计时
    reg        start_pulse; // 通知串行器"可以发下一个字节了"
    reg        sent_hi;     // 本字节是否已经被串行器接收
    reg        was_busy;    // 上一拍的 busy，用来检测边沿

    always @(posedge clk) begin
        if (rst) begin
            // 复位：线路保持空闲高电平
            tx_r <= 1'b1; busy <= 1'b0; cnt <= 16'd0; bitn <= 4'd0; sh <= 10'h3FF;
        end else if (!busy) begin
            // 空闲态：线路为高，等 start_pulse 来
            tx_r <= 1'b1;
            if (start_pulse) begin
                // 装载：bit9=停止位(1) bit8..1=数据 bit0=起始位(0)
                sh   <= {1'b1, cur_byte, 1'b0};
                tx_r <= 1'b0;                 // 立刻拉低 = 起始位
                cnt  <= 16'd0;
                bitn <= 4'd0;
                busy <= 1'b1;                 // 进入发送态
            end
        end else begin
            // 发送态：每 DIV 拍推进一位
            if (cnt == DIV-1) begin
                cnt <= 16'd0;
                if (bitn == 4'd9) begin
                    // 停止位发完 → 回到空闲
                    busy <= 1'b0;
                    tx_r <= 1'b1;
                end else begin
                    bitn <= bitn + 4'd1;      // 下一位
                    tx_r <= sh[bitn + 4'd1];  // 数据是 LSB 先发
                end
            end else begin
                cnt <= cnt + 16'd1;           // 一位内继续计数
            end
        end
    end

    //==================================================================
    // (B) 帧打包器
    //   帧内容：AA m3 m2 m1 m0 XOR
    //     m3 = ms[31:24] ... m0 = ms[7:0]（大端）
    //     XOR = 前 5 字节异或，PC 端用它校验
    //==================================================================


    // 帧里 6 个字节的内容
    wire [7:0] b0 = 8'hAA;                    // 帧头
    wire [7:0] b1 = ms_lat[31:24];            // 毫秒 bit31..24
    wire [7:0] b2 = ms_lat[23:16];            // 毫秒 bit23..16
    wire [7:0] b3 = ms_lat[15:8];             // 毫秒 bit15..8
    wire [7:0] b4 = ms_lat[7:0];              // 毫秒 bit7..0
    wire [7:0] b5 = b0 ^ b1 ^ b2 ^ b3 ^ b4;   // 校验字节

    reg [7:0] byte_sel;     // 按 bidx 选出当前字节

    always @(*) begin
        case (bidx)
            3'd0: byte_sel = b0;
            3'd1: byte_sel = b1;
            3'd2: byte_sel = b2;
            3'd3: byte_sel = b3;
            3'd4: byte_sel = b4;
            default: byte_sel = b5;   // 3'd5
        endcase
    end

    always @(*) cur_byte = byte_sel;   // 组合赋值给串行器用

    always @(posedge clk) begin
        if (rst) begin
            bidx <= 3'd0; ms_lat <= 32'd0; gap <= 32'd0;
            start_pulse <= 1'b0; sent_hi <= 1'b0; was_busy <= 1'b0;
        end else begin
            start_pulse <= 1'b0;      // 默认不启动（只保持 1 拍）
            was_busy    <= busy;      // 记录上一拍的 busy，用来找边沿

            // busy 上升沿：串行器已接收本字节 → 标记"这一字节已发出"
            if (busy && !was_busy) sent_hi <= 1'b1;

            // busy 下降沿：本字节发完了
            if (!busy && was_busy) begin
                sent_hi <= 1'b0;
                if (bidx == 3'd5) begin
                    bidx <= 3'd0;         // 一帧结束，回到帧头
                    gap  <= GAP_CLK;      // 开始 0.5 秒间隔
                end else begin
                    bidx <= bidx + 3'd1;  // 下一个字节
                end
            end

            // 空闲且本字节还没被接收：要么等间隔，要么发起
            if (!busy && !sent_hi) begin
                if (gap != 32'd0) begin
                    gap <= gap - 32'd1;   // 间隔倒计时
                end else begin
                    // 帧头开始前锁存 ms，保证一帧 6 字节是同一个值
                    if (bidx == 3'd0) ms_lat <= ms;
                    start_pulse <= 1'b1;  // 通知串行器发这一字节
                end
            end
        end
    end

endmodule
