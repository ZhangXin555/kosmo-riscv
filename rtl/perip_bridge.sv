`timescale 1ns / 1ps
//==========================================================================
//  perip_bridge.sv — 外设总线桥（地址译码器 / MMIO）
//--------------------------------------------------------------------------
//  这个模块是 CPU 与外部世界之间的"前台"。CPU 只有一套 store/load 接口，
//  所有外设（DRAM、拨码、按键、数码管、LED、计时器）都挂在同一组地址上，
//  靠地址的高位来区分去哪个设备 —— 这就是所谓 MMIO（内存映射 I/O）。
//
//  地址分配（CPU 看到的 32 位地址）：
//    0x8010_0000 ~ 0x8013_FFFF  → DRAM（256 KB，用低 18 位）
//    0x8020_0000 (+0x00)        → 拨码开关 SW0（读）
//    0x8020_0004 (+0x04)        → 拨码开关 SW1（读）
//    0x8020_0010 (+0x10)        → 按键 KEY（读）
//    0x8020_0020 (+0x20)        → 数码管 SEG（写）
//    0x8020_0040 (+0x40)        → LED（写）
//    0x8020_0050 (+0x50)        → 毫秒计时器（写魔数控制 / 读当前值）
//
//  两个关键概念：
//    1) 写通道：只有"落在某个地址上"的写才会生效（见两个 case）
//    2) 读通道：用"地址 == 常量"的掩码做**线与**，把多路数据 mux 起来，
//       未命中任何设备时返回 0xDEAD_BEEF（方便发现"读到了不存在的地址"）
//==========================================================================
module perip_bridge(
    input  logic         clk,
    input  logic         cnt_clk,            // 计时器专用时钟（本设计=clk）
    input  logic         rst,

    // ---- CPU 访存接口（来自 MEM 级）----
    input  logic [31:0]  perip_addr,         // 访存地址
    input  logic [31:0]  rd_addr,            // **读**地址（EX 级提前给，见 dram_driver）
    input  logic [31:0]  perip_wdata,        // 写数据
    input  logic         perip_wen,          // 写使能
    input  logic [1:0]   perip_mask,         // 访问宽度：00=字节 01=半字 10=字
    output logic [31:0]  perip_rdata,        // 读数据

    // ---- 虚拟外设输入（板上没接，顶层给常数）----
    input  logic [63:0]  virtual_sw_input,   // 拨码开关值
    input  logic [7:0]   virtual_key_input,  // 按键值

    // ---- 虚拟外设输出（板上没接，悬空）----
    output logic [39:0]  virtual_seg_output, // 数码管段码
    output logic [31:0]  virtual_led_output, // LED 寄存器

    // ---- 给板级用 ----
    output logic [31:0]  ms_value,           // 毫秒值（送 LED / 串口）
    output logic         ms_running          // 计时中
);

    //------------------------------------------------------------------
    // 地址常量（写成 localparam 而不是宏，便于综合时被常量折叠）
    //------------------------------------------------------------------
    localparam logic [31:0] DRAM_ADDR_START = 32'h8010_0000;   // DRAM 起点
    localparam logic [31:0] DRAM_ADDR_END   = 32'h8013_FFFF;   // DRAM 终点（256KB）

    localparam logic [31:0] SW0_ADDR        = 32'h8020_0000;   // 拨码 SW0
    localparam logic [31:0] SW1_ADDR        = 32'h8020_0004;   // 拨码 SW1
    localparam logic [31:0] KEY_ADDR        = 32'h8020_0010;   // 按键
    localparam logic [31:0] SEG_ADDR        = 32'h8020_0020;   // 数码管
    localparam logic [31:0] LED_ADDR        = 32'h8020_0040;   // LED
    localparam logic [31:0] CNT_ADDR        = 32'h8020_0050;   // 毫秒计时器

    //------------------------------------------------------------------
    // 内部寄存器（可写的两个外设）
    //------------------------------------------------------------------
    logic [31:0] LED;        // LED 寄存器
    logic [39:0] seg_wdata;  // 数码管寄存器

    // 计时器回读值（由 counter 模块组合输出）
    logic [31:0] cnt_rdata;

    //------------------------------------------------------------------
    // 写通道
    //   只有 perip_wen 有效 且 地址精确匹配时才写入。
    //   注意：这里用 perip_addr（MEM 级的地址），写是"正常时序"。
    //------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            LED       <= 32'd0;
            seg_wdata <= 40'd0;
        end else if (perip_wen) begin
            case (perip_addr)
                LED_ADDR: LED       <= perip_wdata;   // 写 LED 寄存器
                SEG_ADDR: seg_wdata <= {8'd0, perip_wdata};   // 写数码管寄存器
                default : ;                            // 其它地址：忽略
            endcase
        end
    end

    // 把寄存器值送到输出端口
    assign virtual_led_output = LED;
    assign virtual_seg_output = seg_wdata;

    //------------------------------------------------------------------
    // 读通道（组合逻辑）
    //   mmio_rdata 只负责"非计时器"的那几个设备；
    //   DRAM 和计时器的读数据在下面用掩码并到 perip_rdata 里。
    //   default 给 0xDEAD_BEEF：读到没实现的地址时，一眼就能看出来。
    //------------------------------------------------------------------
    logic [31:0] mmio_rdata;

    always_comb begin
        case (perip_addr)
            SW0_ADDR: mmio_rdata = virtual_sw_input[31:0];    // 拨码低 32 位
            SW1_ADDR: mmio_rdata = virtual_sw_input[63:32];   // 拨码高 32 位
            KEY_ADDR: mmio_rdata = {24'd0, virtual_key_input};// 按键（8 位零扩展）
            SEG_ADDR: mmio_rdata = seg_wdata[31:0];                 // 读回数码管寄存器
            LED_ADDR: mmio_rdata = LED;                       // 读回 LED 寄存器
            default : mmio_rdata = 32'hDEAD_BEEF;             // 未实现地址
        endcase
    end

    //------------------------------------------------------------------
    // DRAM：地址落在 0x8010_0000~0x8013_FFFF 时使能
    //   送进去的是"低 18 位"，即 256KB 空间
    //------------------------------------------------------------------
    logic        dram_sel;
    logic [31:0] dram_rdata;

    assign dram_sel = (perip_addr >= DRAM_ADDR_START) && (perip_addr < DRAM_ADDR_END);

    dram_driver dram_driver_inst (
        .clk        (clk),
        .perip_addr (perip_addr[17:0]),              // 写/读地址（低 18 位）
        .rd_addr    (rd_addr),                       // **读**地址（EX 级，提前）
        .perip_wdata(perip_wdata),
        .perip_mask (perip_mask[1:0]),               // 掩码：字节/半字/字
        .dram_wen   (perip_wen & (perip_addr >= DRAM_ADDR_START) && (perip_addr < DRAM_ADDR_END)),
        .perip_rdata(dram_rdata)                     // 读回数据
    );

    //------------------------------------------------------------------
    // 毫秒计时器：写 0x8020_0050 时使能；读时直接把 cnt_ms 送出去
    //------------------------------------------------------------------
    logic        cnt_sel;

    assign cnt_sel = (perip_addr == CNT_ADDR);

    counter counter_inst (
        .clk        (cnt_clk),
        .perip_wdata(perip_wdata),
        .cnt_wen    (perip_wen & cnt_sel),           // 只有写这个地址才算数
        .perip_rdata(cnt_rdata),                     // 读回毫秒数
        .ms_value   (ms_value),                      // 送给板级
        .ms_running (ms_running)
    );

    //------------------------------------------------------------------
    // 读数据汇总
    //   每个设备配一个"地址是否命中"的 32 位掩码（全 0 或全 1），
    //   用 & 选通、用 | 合并 —— 等价于一个多路选择器，
    //   但这种写法综合出来的是一条很浅的或门树，时序更好。
    //------------------------------------------------------------------
    assign perip_rdata =
          ({32{dram_sel}} & dram_rdata)              // DRAM
        | ({32{cnt_sel}}  & cnt_rdata)               // 计时器
        | ({32{~dram_sel & ~cnt_sel}} & mmio_rdata); // 其余 MMIO

endmodule
