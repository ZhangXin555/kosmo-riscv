`timescale 1ns / 1ps
//==========================================================================
//  uart.sv — 通用异步收发器（8N1，115200 bps，本工程用来回传毫秒数）
//--------------------------------------------------------------------------
//  帧格式（8N1）：
//      空闲 = 高电平
//      起始位 1 个 = 0
//      数据位 8 个（**低位先发** LSB first）
//      停止位 1 个 = 1
//  一帧 10 个"位时间"，每位 = BAUD_DIV = CLK_FREQ / BAUD_RATE 个时钟
//  50 MHz / 115200 = 434（本工程取整，误差约 0.0064%，可接受）
//
//  本文件里有两套互相独立的状态机：
//      rx_* ：接收（这里主要用来做"能收到东西"的验证，主流程用不到）
//      tx_* ：发送（关键路径 —— 把 32 位毫秒数按字节发出去）
//  两份都用了"两次同步 + 边沿检测"处理异步输入（rx 来自外部引脚）。
//==========================================================================
module uart #(
    parameter CLK_FREQ = 50000000,      // 系统时钟频率
    parameter BAUD_RATE = 115200        // 波特率
)(
    input wire clk,
    input wire rst_n,                   // 低有效复位

    // 接收侧
    input  wire rx,                     // 串行输入
    output reg [7:0] rx_data,           // 收到的 1 字节
    output reg rx_ready,                // 收到数据后保持约半个位时间

    // 发送侧
    output reg tx,                      // 串行输出
    input wire [7:0] tx_data,           // 要发的字节
    input wire tx_start,                // 启动一拍
    output reg tx_busy                  // 发送中（用于反压）
);
    // 一个位时间需要多少个时钟
    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;

    //======================================================================
    // 接收部分
    //======================================================================
    reg [1:0] rx_state;
    reg [12:0] rx_cnt;                  // 位内计时
    reg [7:0] rx_shift;                 // 移位寄存器
    reg rx_d0, rx_d1, rx_d2;            // 两级同步 + 一级延迟（做边沿检测）

    //----------------------------------------------------------------------
    // 异步输入同步（防止亚稳态）：rx → d0 → d1 → d2
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_d0 <= 1'b1;              // 空闲是高电平
            rx_d1 <= 1'b1;
            rx_d2 <= 1'b1;
        end else begin
            rx_d0 <= rx;
            rx_d1 <= rx_d0;
            rx_d2 <= rx_d1;
        end
    end

    // 下降沿检测：rx_d2=1 而 rx_d1=0 → 说明刚刚出现了起始位
    wire rx_negedge = rx_d2 & ~rx_d1;

    reg [3:0] rx_bit_cnt;               // 已收几位
    reg rx_ready_pulse;                 // 收完一字节的脉冲
    reg [15:0] rx_ready_cnt;

    //----------------------------------------------------------------------
    // 接收状态机
    //   0 空闲：等下降沿 → 置成 1，并把计时器预置半个位（对齐到位的中心）
    //   1 等半个位：对齐到起始位中心
    //   2 逐位采样：每满一个 BAUD_DIV 采一次 dr_rx，右移进 rx_shift
    //   3 等停止位：收完第 8 位后再等一个位时间，输出 rx_data
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= 0;
            rx_cnt <= 0;
            rx_bit_cnt <= 0;
            rx_shift <= 0;
            rx_data <= 0;
            rx_ready_pulse <= 0;
        end else begin
            rx_ready_pulse <= 0;
            case(rx_state)
                0: begin
                    if(rx_negedge) begin
                        rx_state <= 1;
                        rx_cnt <= BAUD_DIV >> 1;   // 半个位 → 采到起始位中心
                        rx_bit_cnt <= 0;
                    end
                end
                1: begin
                    if(rx_cnt == BAUD_DIV-1) begin
                        rx_cnt <= 0;
                        rx_state <= 2;
                    end else
                        rx_cnt <= rx_cnt + 1;
                end
                2: begin
                    if(rx_cnt == BAUD_DIV-1) begin
                        rx_cnt <= 0;
                        rx_shift <= {rx_d2, rx_shift[7:1]};  // LSB first
                        if(rx_bit_cnt == 7)
                            rx_state <= 3;
                        else
                            rx_bit_cnt <= rx_bit_cnt + 1;
                    end else
                        rx_cnt <= rx_cnt + 1;
                end
                3: begin
                    if(rx_cnt == BAUD_DIV-1) begin
                        rx_cnt <= 0;
                        rx_state <= 0;
                        rx_data <= rx_shift;
                        rx_ready_pulse <= 1'b1;
                    end else begin
                        rx_cnt <= rx_cnt + 1;
                    end
                end
                default: rx_state <= 0;
            endcase
        end
    end

    //----------------------------------------------------------------------
    // rx_ready 展宽：收到一字节后保持约一个位时间的高电平
    //   （原注释写"半个 BAUD_DIV"，实际计数到 BAUD_DIV-1）
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_ready <= 1'b0;
            rx_ready_cnt <= 0;
        end else begin
            if (rx_ready_pulse) begin
                rx_ready <= 1'b1;
                rx_ready_cnt <= 0;
            end else if (rx_ready) begin
                if (rx_ready_cnt < BAUD_DIV - 1) begin
                    rx_ready_cnt <= rx_ready_cnt + 1;
                end else begin
                    rx_ready <= 1'b0;
                end
            end
        end
    end

    //======================================================================
    // 发送部分
    //======================================================================
    reg [3:0] tx_state;
    reg [12:0] tx_cnt;
    reg [3:0] tx_bit_cnt;
    reg [9:0] tx_shift;                 // {停止位, 8 位数据, 起始位}

    //----------------------------------------------------------------------
    // 发送状态机
    //   0 空闲：tx 保持高；检测到 tx_start → 装入 {1'b1, tx_data, 1'b0}
    //   1 移位：每满一个位时间，把 tx_shift[0] 打到 tx 上，然后右移
    //            总共发 10 位（起始位 + 8 数据 + 停止位）
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= 0;
            tx_busy <= 0;
            tx_cnt <= 0;
            tx_bit_cnt <= 0;
            tx_shift <= 10'b1111111111;
            tx <= 1'b1;                 // 空闲高
        end else begin
            case(tx_state)
                0: begin
                    tx_busy <= 0;
                    if(tx_start) begin
                        tx_shift <= {1'b1, tx_data, 1'b0};  // 停止位 | 数据 | 起始位
                        tx_state <= 1;
                        tx_cnt <= 0;
                        tx_bit_cnt <= 0;
                        tx_busy <= 1;
                    end
                end
                1: begin
                    if(tx_cnt == BAUD_DIV-1) begin
                        tx_cnt <= 0;
                        tx <= tx_shift[0];                  // 从起始位开始往外打
                        tx_shift <= {1'b1, tx_shift[9:1]};  // 右移，低位先发
                        if(tx_bit_cnt == 9)
                            tx_state <= 0;                  // 10 位发完
                        else
                            tx_bit_cnt <= tx_bit_cnt + 1;
                    end else
                        tx_cnt <= tx_cnt + 1;
                end
            endcase
        end
    end

endmodule
