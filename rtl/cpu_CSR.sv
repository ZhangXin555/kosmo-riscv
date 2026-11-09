`timescale 1ns/1ps

//=============================================================================
// CSR：控制状态寄存器组（mepc / mcause / mstatus / mtvec + 两个只读 ID）
//=============================================================================
// 【本 CPU 用到的 4 个真寄存器】
//   mepc    (0x341) 发生异常时，自动把"出错指令的 PC"存进来，mret 时跳回它
//   mcause  (0x342) 异常原因编码（见下）
//   mstatus (0x300) 全局中断开关等状态位；复位值 32'h1800（MPP=11，机器模式）
//   mtvec   (0x305) 异常入口地址。本设计**没有实现 trap 处理程序**，
//                   所以复位值 0 —— 真出异常会跳到 0（这是原竞赛程序的现状）
//
// 【mcause 编码（本实现自定义的简化版）】
//   exc_cause==2'b10 → 1   （取指地址越界 ifault）
//   exc_cause==2'b01 → 0   （跳转/分支目标地址不对齐）
//   ecall            → 11  （环境调用）
//   其它             → 直接用写进来的 csrd
//
// 【写入优先级】异常/ecall 是"硬件自动写"，与软件写 csr_wen 或在一起：
//   mepc/mcause 的 wen = csr_wen[x] | ecall_flag | (|exc_cause)
//   —— 注意这里没有做优先级仲裁，同一拍既有异常又有 csr 写时会互相覆盖，
//      本设计的使用场景（固件不写 CSR）不会冲突。
//
// 【两个只读 ID】
//   mvendorid = 0x79737978（"xy sy" ASCII，工程遗留的彩蛋）
//   marchid   = 0x016FBCBD
//=============================================================================

module CSR #(
    parameter CSR_WIDTH = 32,             // 位宽
    parameter RESET_VAL = 0               // 复位值
)(
    input clock,                          // 时钟
    input reset,                          // 复位
    input [31:0] pc,                      // 当前指令 PC（异常时写进 mepc）
    input ecall_flag,                     // ecall 指令
    input [1:0] exc_cause,                // 异常原因（00=无, 01=不对齐, 10=越界）
    input [31:0] csrd,                    // 软件要写的值（csrrw 的源）
    input [3:0] csr_wen,                  // 4 位写使能：[0]mepc [1]mcause [2]mstatus [3]mtvec
    output [31:0] mvendorid_out,          // 只读：厂商 ID
    output [31:0] marchid_out,            // 只读：架构 ID
    output [31:0] mepc_out,               // 异常返回地址
    output [31:0] mcause_out,             // 异常原因
    output [31:0] mstatus_out,            // 状态寄存器
    output [31:0] mtvec_out               // 异常入口
);
    logic [31:0] mepc_in;                 // 下面 4 个是"下一拍要写进去的值"
    logic [31:0] mcause_in;
    logic [31:0] mstatus_in;
    logic [31:0] mtvec_in;

    //-------------------------------------------------------------------------
    // 组合：算出每个 CSR 的输入
    //-------------------------------------------------------------------------
    // 有异常（ecall 或 exc_cause!=0）时，mepc 存"当前 PC"；否则存软件写的值
    assign mepc_in = (ecall_flag | (|exc_cause)) ? pc : csrd;

    // 异常原因：越界→1，不对齐→0，ecall→11，其它→软件写
    assign mcause_in = (exc_cause == 2'b10) ? 32'd1 :
                        (exc_cause == 2'b01) ? 32'd0 :
                        ((ecall_flag) ? 11 : csrd);

    assign mstatus_in = csrd;             // mstatus 只能软件写
    assign mtvec_in = csrd;               // mtvec 只能软件写

    // 只读 ID（写不进，也不该写）
    assign mvendorid_out = 32'h79737978;
    assign marchid_out = 32'h16FBCBD;

    //-------------------------------------------------------------------------
    // 4 个时序寄存器（统一用 cpu_Reg.sv 这个通用寄存器元件）
    //   wen = 软件写使能 | 硬件自动写条件
    //-------------------------------------------------------------------------
    Reg #(
        .WIDTH(CSR_WIDTH),
        .RESET_VAL(RESET_VAL)
    ) CSR_MEPC(
        .clock(clock),
        .reset(reset),
        .din(mepc_in),
        .dout(mepc_out),
        .wen(csr_wen[0] | ecall_flag | (|exc_cause))
    );
    Reg #(
        .WIDTH(CSR_WIDTH),
        .RESET_VAL(RESET_VAL)
    ) CSR_MCAUSE(
        .clock(clock),
        .reset(reset),
        .din(mcause_in),
        .dout(mcause_out),
        .wen(csr_wen[1] | ecall_flag | (|exc_cause))
    );
    Reg #(
        .WIDTH(CSR_WIDTH),
        .RESET_VAL(32'h1800)              // 复位后 mstatus.MPP = 11（机器模式）
    ) CSR_MSTATUS(
        .clock(clock),
        .reset(reset),
        .din(mstatus_in),
        .dout(mstatus_out),
        .wen(csr_wen[2])
    );
    Reg #(
        .WIDTH(CSR_WIDTH),
        .RESET_VAL(RESET_VAL)
    ) CSR_MTVEC(
        .clock(clock),
        .reset(reset),
        .din(mtvec_in),
        .dout(mtvec_out),
        .wen(csr_wen[3])
    );
endmodule
