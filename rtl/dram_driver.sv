`timescale 1ns / 1ps
//==========================================================================
//  dram_driver.sv — DRAM 控制器（字节/半字/字 访存 + 读晚一拍问题的修复）
//--------------------------------------------------------------------------
//  DRAM.v 本身是一个同步读的 BRAM：
//      always @(posedge clk) begin
//          if (we) mem[a] <= d;
//          spo <= mem[a];      // ← 读数据是"打过一拍"才出来
//      end
//  也就是说：这一拍给地址，**下一拍**才拿到数据。
//  而 CPU 的 load 是在 MEM 级当拍就要用数据的 → 直接接会拿到"上一个地址"的数据。
//
//  修复办法（方案 C，零性能代价）：
//     写地址用 MEM 级的 perip_addr
//     读地址用 EX 级的 rd_addr  ← 提前一拍给！
//  这样当指令走到 MEM 级时，BRAM 里正好锁存着这条 load 的数据。
//
//  另一个职责：非对齐 / 窄宽度访问
//     RV32I 支持 lb/lbu/lh/lhu/sb/sh，需要按地址低 2 位挑字节、
//     写的时候还要"读-改-写"（先读回整字，再替换其中一部分，再写回）。
//==========================================================================
module dram_driver(
    input  logic         clk,

    input  logic [17:0]  perip_addr,      // MEM 级地址（写用）
    input  logic [17:0]  rd_addr,         // EX  级地址（读用，提前一拍）
    input  logic [31:0]  perip_wdata,     // 写数据
    input  logic [1:0]   perip_mask,      // 00=字节 01=半字 10=整字
    input  logic         dram_wen,        // 写使能
    output logic [31:0]  perip_rdata      // 读回（已按掩码整理好）
);
    logic [15:0] dram_addr;        // 送给 BRAM 的字地址（字 = 4 字节）
    logic [ 1:0] offset;           // 写地址的低 2 位（选哪个字节/半字）
    logic [ 1:0] rd_offset;        // 读地址的低 2 位
    logic [31:0] dram_data, dram_rdata_raw, dout;

    //------------------------------------------------------------------
    // 地址选择：这是整个修复的关键一行
    //   写：perip_addr（MEM 级地址，正常时序）
    //   读：rd_addr（EX 级地址，比 MEM 早一拍）→ 抵消 BRAM 的 1 拍延迟
    //------------------------------------------------------------------
    assign dram_addr = dram_wen ? perip_addr[17:2] : rd_addr[17:2];

    assign offset    = perip_addr[1:0];   // 写偏移
    assign rd_offset = rd_addr[1:0];      // 读偏移
    assign perip_rdata = dout;

    //------------------------------------------------------------------
    // BRAM 本体
    //------------------------------------------------------------------
    DRAM Mem_DRAM (
        .clk (clk),
        .a   (dram_addr),
        .spo (dram_rdata_raw),
        .we  (dram_wen),
        .d   (dram_data)
    );

    //------------------------------------------------------------------
    // 读数据整理（组合）
    //   lb/lbu：按 rd_offset 从 32 位里挑 1 个字节，高位补 0
    //   lh/lhu：按 rd_offset[1] 挑低半字或高半字，高位补 0
    //   lw    ：整字原样输出
    //   符号扩展不在这里做 —— 由 cpu_LSU 的 sext 模块负责
    //------------------------------------------------------------------
    always_comb begin
        dout = 0;
        case (perip_mask)
            2'b00: // lb / lbu
                case (rd_offset)
                    2'b00: dout = {24'b0, dram_rdata_raw[7:0]};
                    2'b01: dout = {24'b0, dram_rdata_raw[15:8]};
                    2'b10: dout = {24'b0, dram_rdata_raw[23:16]};
                    2'b11: dout = {24'b0, dram_rdata_raw[31:24]};
                endcase
            2'b01: // lh / lhu
                case (rd_offset[1])
                    1'b0: dout = {24'b0, dram_rdata_raw[15:0]};
                    1'b1: dout = {24'b0, dram_rdata_raw[31:16]};
                endcase
            2'b10: dout = dram_rdata_raw;   // lw：整字
            default: dout = 0;
        endcase
    end

    //------------------------------------------------------------------
    // 写数据整理（组合，读-改-写）
    //   sw：整个 32 位直接覆盖
    //   sh：保留另一半，替换对应 16 位
    //   sb：保留其余 3 个字节，替换其中 1 个
    //   注意：dram_rdata_raw 是**当前读出**的旧值，所以能"只改一部分"
    //------------------------------------------------------------------
    always_comb begin
        case (perip_mask)
            2'b10: dram_data = perip_wdata;                     // sw
            2'b01: begin                                        // sh
                case (offset[1])
                    1'b0: dram_data = {dram_rdata_raw[31:16], perip_wdata[15:0]};
                    1'b1: dram_data = {perip_wdata[15:0], dram_rdata_raw[15:0]};
                endcase
            end
            2'b00: begin                                        // sb
                case (offset)
                    2'b00: dram_data = {dram_rdata_raw[31:8],  perip_wdata[7:0]};
                    2'b01: dram_data = {dram_rdata_raw[31:16], perip_wdata[7:0], dram_rdata_raw[7:0]};
                    2'b10: dram_data = {dram_rdata_raw[31:24], perip_wdata[7:0], dram_rdata_raw[15:0]};
                    2'b11: dram_data = {perip_wdata[7:0], dram_rdata_raw[23:0]};
                endcase
            end
            default: dram_data = perip_wdata;
        endcase
    end
endmodule
