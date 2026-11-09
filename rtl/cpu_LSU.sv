//=============================================================================
// 模块名 ：LSU（Load/Store Unit，访存单元）
// 流水级 ：MEM（第 4 级）
// 干什么 ：三件事
//   1) 把 EX 级递过来的地址/数据送出去给数据存储器（`addr/wen/wdata/mask/rdata`）；
//   2) 把读回来的原始 32 位数据按 funct3 切/扩成正确的 32 位
//      （lb/lbu/lh/lhu/lw 五种宽度，注意有符号要符号扩展、无符号要补零）；
//   3) 把控制信号再往下透传给 WB 级（R_wen/csr_wen/rd/…）。
// 它是纯组合模块：LSU 内部**没有任何寄存器**，所以 MEM 这一级本身不额外吃拍，
// 真正的边界在 EX_LSWB_Reg（进）和后面 WB 级（出）。
//
// ★ funct3 编码（RISC-V 规范，读代码时对照看）
//     000 = lb   取字节，**符号扩展**
//     001 = lh   取半字，符号扩展
//     010 = lw   取整字
//     100 = lbu  取字节，**零扩展**
//     101 = lhu  取半字，零扩展
//   写内存那一侧：`mask = funct3_reg[1:0]`，由存储器按 mask 决定写几个字节
//     （00=1 字节、01=2 字节、10=4 字节）
//
// ★ 数据对齐的坑（复刻时最容易漏）
//   RISC-V 允许非对齐地址，硬件要按地址低位选字节。
//   这个 CPU 简化处理：读数据直接从 rdata[0+:8]/[0+:16] 取（默认访问是对齐的），
//   真正的字节选择放在了选通侧（mask / 存储器的行内偏移）。
//   如果自己实现时把地址低位丢了，lb 读 0x1001 会读到 0x1000 那一字节 —— 结果全错。
//
// ★ 为什么 `assign LSU_Rdata = rdata_ex;` 这一行当年出过 bug（已修，留作教训）
//   原来 DRAM.v 的读口是"1 拍寄存"（`spo <= mem[a]`），而 WBU 在**同一个沿**就采样
//   LSU_Rdata，导致 load 拿到的是**上一个地址**的数据。
//   现在的修法：读地址改由 EX 级组合产生（见 dram_driver.sv 的 rd_addr），
//   让 BRAM 在 EX→MEM 这个沿就锁到真正的 load 地址，这一行就不用再改。
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */

`timescale 1ns / 1ps

module LSU(
    // ---- 从 EX_LSWB_Reg 来的（已打一拍）----
    input mem_ren_reg,          // load 标志
    input mem_wen_reg,          // store 标志
    input R_wen_reg,            // 写回寄存器堆标志
    input [3:0] csr_wen_reg,    // CSR 写使能
    input [31:0] Ex_result_reg, // load/store 地址（也兼作 ALU 结果）
    input [4:0] rd_reg,         // 目的寄存器号
    input [2:0] funct3_reg,     // 访存宽度/符号类型
    input [31:0] rs2_value_reg, // store 写入数据
    input jump_flag_reg,        // 跳转标志
    input [31:0] rd_value_reg,  // 跳转写回值（pc+4）
    input [31:0] pc_reg,        // 指令地址

    // ---- 透传给 WB 级 ----
    output [31:0] rd_value_next,    // 写回值（跳转时是 pc+4）
    output R_wen_next,              // 写回使能
    output [31:0] LSU_Rdata,        // 已按 funct3 对齐/扩展的读数据
    output [3:0] csr_wen_next,      // CSR 写使能
    output [31:0] Ex_result_next,   // ALU 结果（非 load 指令的写回值）
    output [4:0] rd_next,           // 目的寄存器号
    output mem_ren_next,            // load 标志（继续往下传）
    output jump_flag_next,          // 跳转标志
    output [31:0] pc_next,          // 指令地址

    // ---- 直接连数据存储器（DRAM）的接口 ----
    output [31:0] addr,             // 访问地址（字节地址）
    output wen,                     // 写使能
    output [31:0] wdata,            // 写数据
    output [1:0] mask,              // 写字节掩码：00=1B、01=2B、10=4B
    input [31:0] rdata              // 存储器读回的原始 32 位
);
    logic [31:0] rdata_8i;          // lb  结果（符号扩展）
    logic [31:0] rdata_16i;         // lh  结果（符号扩展）
    logic [31:0] rdata_8u;          // lbu 结果（零扩展）
    logic [31:0] rdata_16u;         // lhu 结果（零扩展）
    logic [31:0] rdata_ex;          // 最终选中的数据

    //-------------------------------------------------------------------------
    // ① 纯连线：控制/数据往下透传（MEM 级不改这些值）
    //-------------------------------------------------------------------------
    assign rd_value_next  = rd_value_reg;   // pc+4 直接过
    assign R_wen_next     = R_wen_reg;      // 写回使能直接过
    assign csr_wen_next   = csr_wen_reg;    // CSR 写使能直接过
    assign Ex_result_next = Ex_result_reg;  // ALU 结果直接过（WB 用它写回）
    assign rd_next        = rd_reg;         // 目的寄存器直接过
    assign mem_ren_next   = mem_ren_reg;    // load 标志直接过
    assign jump_flag_next = jump_flag_reg;  // 跳转标志直接过
    assign pc_next        = pc_reg;         // PC 直接过

    //-------------------------------------------------------------------------
    // ② 送存储器的信号
    //-------------------------------------------------------------------------
    assign addr  = Ex_result_reg;           // 地址 = ALU 算出的有效地址
    assign wdata = rs2_value_reg;           // 写数据 = 源寄存器 2
    assign wen   = mem_wen_reg;             // 只有 store 才写
    assign mask  = funct3_reg[1:0];         // 00:1B 01:2B 10:4B

    //-------------------------------------------------------------------------
    // ③ 读数据按宽度/符号整理
    //-------------------------------------------------------------------------
    assign LSU_Rdata = rdata_ex;

    always @(*) begin
        case (funct3_reg)
            3'b000: rdata_ex = rdata_8i;    // lb
            3'b001: rdata_ex = rdata_16i;   // lh
            3'b010: rdata_ex = rdata;       // lw（整字，不用处理）
            3'b100: rdata_ex = rdata_8u;    // lbu
            3'b101: rdata_ex = rdata_16u;   // lhu
            default: rdata_ex = 0;          // 其他（sb/sh/sw 不需要读）→ 0
        endcase
    end

    // 零扩展：高位直接补 0
    assign rdata_8u  = {24'd0, rdata[7:0]};
    assign rdata_16u = {16'd0, rdata[15:0]};

    // 符号扩展：复用 cpu_sext 模块（把最高位复制到高位）
    /* verilator lint_off PINMISSING */
    sext #(
        .DATA_WIDTH(8),
        .OUT_WIDTH(32)
    ) sext_i8 (
        .data(rdata[0+:8]),         // 取低 8 位
        .sext_data(rdata_8i)        // 符号扩展到 32 位
    );

    sext #(
        .DATA_WIDTH(16),
        .OUT_WIDTH(32)
    ) sext_i16 (
        .data(rdata[0+:16]),        // 取低 16 位
        .sext_data(rdata_16i)       // 符号扩展到 32 位
    );

endmodule //LSU
