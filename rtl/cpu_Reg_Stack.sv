`timescale 1ns/1ps

//=============================================================================
// Reg_Stack：把"寄存器堆"和"CSR 组"打包在一起的壳子
//=============================================================================
// 【为什么要这个模块】
//   ID 级既要读通用寄存器（x0~x31），又要读 CSR（mepc/mcause/mstatus/mtvec）。
//   把两者合成一个模块，ID 级只例化它一个，接口简单。
//
// 【写了什么】
//   1) 地址译码：给一个 CSR 地址（csr_addr），选回对应的 CSR 值（csrs）。
//      本 CPU 只支持 6 个：0x341 mepc / 0x342 mcause / 0x300 mstatus /
//      0x305 mtvec / 0xf11 mvendorid / 0xf12 marchid。
//      注：RISC-V 规定这三个是只读：mvendorid、marchid、mimpid，
//          所以这里只做"读"，写使能被 csr_wen 只放行 mepc/mcause/mstatus/mtvec。
//   2) 例化 CSR：里面是真寄存器（时序），负责 mepc/mcause/mstatus/mtvec 的更新
//      （异常时自动写 mcause/mepc，mret 时按 mstatus 回退）。
//   3) 例化 RegisterFile：通用寄存器堆（两个组合读口 + 一个同步写口）。
//   4) `wdata` 这一行：当 rd==x0 时强制写 0 —— 与寄存器堆内部的 x0 保护形成双保险。
//=============================================================================

module Reg_Stack(
    input reset,                          // 复位
    input clock,                          // 时钟
    input [31:0] pc,                      // 当前指令 PC（异常时写进 mepc）
    input ecall_flag,                     // 本条指令是 ecall（要触发异常）
    input [1:0] exc_cause,                // 异常原因（写进 mcause）
    input [4:0] rs1,                      // 读寄存器号 1
    input [4:0] rs2,                      // 读寄存器号 2
    input [4:0] rd,                       // 写寄存器号
    input [31:0] rd_value,                // 写回数据
    input [31:0] csr_addr,                // CSR 地址（从指令 imm 字段来）
    input R_wen,                          // 通用寄存器写使能
    input [3:0] csr_wen,                  // CSR 写使能（4 位分别对应 4 个 CSR）
    input [31:0] csrd,                    // 要写进 CSR 的数据
    output [31:0] rs1_value,              // 读出的 rs1
    output [31:0] rs2_value,              // 读出的 rs2
    output [31:0] a0_value,               // x10 的值（测试判定用）
    output [31:0] csrs,                   // 按 csr_addr 选出的 CSR 值
    output [31:0] mepc_out,               // 给 Control 用来做 mret 返回
    output [31:0] mtvec_out               // 给 Control 用来做异常跳转
);
    logic [31:0] wdata;                   // 真正写进寄存器堆的数据（x0 会被强制 0）
    logic [31:0] mcause_out;              // 以下 6 个是 CSR 的输出
    logic [31:0] mstatus_out;
    logic [31:0] mvendorid_out;
    logic [31:0] marchid_out;

    // rd 是 x0 时写 0（其实寄存器堆内部也拦了，这里再拦一次）
    assign wdata = (rd == 4'd0) ? 32'd0 : rd_value;

    //-------------------------------------------------------------------------
    // CSR 读多路选择：按地址挑一个送出去；地址不认识就返回 0
    //  0x341=mepc   0x342=mcause   0x300=mstatus   0x305=mtvec
    //  0xf11=mvendorid  0xf12=marchid
    //-------------------------------------------------------------------------
    assign csrs = (csr_addr == 32'h341) ? mepc_out :
                  (csr_addr == 32'h342) ? mcause_out :
                  (csr_addr == 32'h300) ? mstatus_out :
                  (csr_addr == 32'h305) ? mtvec_out :
                  (csr_addr == 32'hf11) ? mvendorid_out :
                  (csr_addr == 32'hf12) ? marchid_out : 32'd0;

    //-------------------------------------------------------------------------
    // CSR 组（时序）
    //-------------------------------------------------------------------------
    CSR #(32,0) CSR_inst(
        .clock(clock),
        .reset(reset),
        .pc(pc),                          // PC 会在异常时进 mepc
        .ecall_flag(ecall_flag),
        .exc_cause(exc_cause),            // 进 mcause
        .csrd(csrd),
        .csr_wen(csr_wen),
        .mvendorid_out(mvendorid_out),
        .marchid_out(marchid_out),
        .mepc_out(mepc_out),
        .mcause_out(mcause_out),
        .mstatus_out(mstatus_out),
        .mtvec_out(mtvec_out)
    );

    //-------------------------------------------------------------------------
    // 通用寄存器堆（组合读、同步写）
    //-------------------------------------------------------------------------
    RegisterFile #(5, 32) Reg_inst(
        .clock(clock),
        .wdata(wdata),
        .waddr(rd),
        .wen(R_wen),
        .reset(reset),
        .rs1_addr(rs1),
        .rs2_addr(rs2),
        .rs1_value(rs1_value),
        .rs2_value(rs2_value),
        .a0_value(a0_value)
    );

endmodule
