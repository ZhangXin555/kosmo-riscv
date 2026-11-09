//=============================================================================
// 模块名 ：IFU（Instruction Fetch Unit，取指单元）
// 流水级 ：第 1 级 —— IF（取指）
// 干什么 ：维护"下一条要取的指令地址" PC，并把 IROM 的数据当成指令送出去。
//           它只管"地址怎么变"，不管"指令是什么意思"（那是 ID 级的事）。
// 关键点 ：
//   1) PC 复位值 0x8000_0000，是 IROM 的起始地址；
//   2) 正常情况 PC <= PC + 4（RISC-V 指令定长 4 字节）；
//   3) 一旦 dnpc_flag 有效（来自 ID 级的分支/跳转/陷入），PC <= dnpc，
//      这就叫"重定向/redirect"，是流水线清空(flush)的触发源；
//   4) stall 有效时 PC 保持不变（load-use 冒险时冻结取指）；
//   5) ready 是外部（多周期存储器）给的"可以继续"信号，本设计恒为 1。
// 说明   ：本模块没有寄存器堆、没有运算，全部逻辑就是"三选一的 PC 更新"。
//=============================================================================
`timescale 1ns / 1ps
/*interface define*/

// ---- 下面是 RISC-V 指令 opcode 的宏定义（CPU 各文件都复制一份，方便单独编译）----
`define R_opcode  7'b0110011          // R 型：add/sub/and/or/xor/sll/srl/sra/slt
`define lw 7'b0000011                 // I 型 load：lw
`define addi 7'b0010011               // I 型算术：addi
`define jarl 7'b1100111               // I 型 jalr（原文拼写为 jarl，沿用不改）
`define S_opcode  7'b0100011          // S 型 store
`define B_opcode  7'b1100011          // B 型 条件分支 beq/bne/blt/bge...
`define lui 7'b0110111                // U 型 lui
`define auipc 7'b0010111              // U 型 auipc
`define jal  7'b1101111               // J 型 jal
`define M_opcode  7'b1110011          // 系统指令（ecall/mret/csr 类）

// ---- ALU 操作码宏定义（EX 级 cpu_ALU.sv 用，这里只为了各文件能独立编译）----
`define alu_add                   4'b0000
`define alu_sub                   4'b0001
`define alu_or                    4'b0010
`define alu_and                   4'b0011
`define alu_xor                   4'b0100
`define alu_signed_comparator     4'b0101
`define alu_unsigned_comparator   4'b0110
`define alu_equal                 4'b0111
`define alu_sll                   4'b1000
`define alu_srl                   4'b1001
`define alu_sra                   4'b1010

`define Performance_Count             // 打开性能计数器（统计拍数/CPI 用）

//=============================================================================
// 端口说明
//   输入 clock      ：时钟，所有时序逻辑都在它的上升沿动作
//   输入 reset      ：复位（高有效），把 PC 拉回 0x8000_0000
//   输入 dnpc[31:0] ：新的 PC 值（分支/跳转/陷入的目标地址）
//   输入 dnpc_flag  ：新 PC 使能；=1 表示"这一拍就要跳"
//   输入 irom_data  ：IROM 组合读出的指令字（地址已经由 pc 给出）
//   输入 stall      ：取指冻结（load-use 冒险时由 Data_hazard 给）
//   输出 snpc[31:0] ：顺序 PC = pc + 4（送去 ID 级算 jal/jalr 的返回地址）
//   输出 pc[31:0]   ：当前指令地址（同时直接接到 IROM 的地址口）
//   输出 inst[31:0] ：当前指令内容（就是 irom_data 直通）
//   输入 ready      ：存储器就绪；本设计恒 1，保留是为了将来接慢速存储器
//   输出 ifault     ：取指越界异常（PC 跑到 IROM 之外）
//   输出 valid      ：取到的指令有效；本设计恒 1
//=============================================================================
module IFU(
    input clock,                       // 时钟
    input reset,                       // 复位，高有效
    input [31:0] dnpc,                 // 重定向目标地址
    input dnpc_flag,                   // 重定向使能
    input [31:0] irom_data,            // IROM 输出的指令
    input stall,                       // 取指暂停

    output [31:0] snpc,                // pc + 4
    output logic [31:0] pc,            // 当前 PC
    output [31:0] inst,                // 当前指令

    input ready,                       // 存储器就绪

    output ifault,                     // 取指越界异常
    output logic valid                 // 指令有效
);

    localparam ResetValue = 32'h8000_0000;   // 复位后第一条指令地址（IROM 基址）

    assign valid = 1'b1;                     // 本设计取指永远有效（IROM 单拍返回）

    // IROM 只有 16 KB（0x8000_0000 ~ 0x8000_3FFF）：
    // pc[31:14] 必须等于 18'h2_0000（即高 18 位是 0x8000 >> … 精确说 0x8000_0000>>14 = 0x20000）
    // 一旦不等，说明 PC 跑到 ROM 外面去了 —— 这就是"取指地址越界"异常。
    assign ifault = (pc[31:14] != 18'h2_0000);   // 1 = 越界

    assign snpc = pc + 4;                    // 顺序下一条（指令 4 字节对齐）
    assign inst = irom_data;                 // IROM 是组合读，当拍就能拿到指令

    //-------------------------------------------------------------------------
    // PC 更新：四种情况，优先级从高到低
    //   1) reset            → 回到 0x8000_0000
    //   2) stall            → 冻结（PC 不动，等前面那条 load 写完）
    //   3) dnpc_flag        → 跳转/分支/陷入，PC 取目标地址
    //   4) 其他             → PC + 4，顺序执行
    // 注意每个分支都带 valid & ready 条件：存储器没准备好就不动 PC。
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if (reset)                                   // 复位优先
            pc <= ResetValue;                        // 回到 ROM 起始
        else if (stall & valid & ready)              // 冒险暂停
            pc <= pc;                                // 保持
        else if (dnpc_flag & valid & ready)          // 重定向
            pc <= dnpc;                              // 跳到目标
        else if (valid & ready)                      // 正常顺序执行
            pc <= snpc;                              // PC += 4
    end

endmodule
