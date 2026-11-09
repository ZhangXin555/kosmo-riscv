`timescale 1ns/1ps

//=============================================================================
// 模块名 ：EX_LSWB_Reg（EX → MEM 流水寄存器，名字里的 LSWB 是"load/store/wb"）
// 流水级 ：这是 5 级流水里的**第 3 到第 4 级之间的那道墙**
//          IF → ID → EX → [EX_LSWB_Reg] → MEM(LSU) → WB(WBU)
// 干什么 ：把 EX 级算好的东西在时钟上升沿"锁"一份，下一拍交给 MEM 级用。
//          数据寄存器 + 控制寄存器都要锁：数据是 Ex_result/rs2/rd，控制是
//          mem_ren/mem_wen/R_wen/csr_wen/jump_flag，漏一个就会出"写错寄存器"的幽灵 bug。
// 为什么需要它 ：每一级只做一件事、只占一拍；没有这道墙，EX 的组合结果会
//          直接冲进 MEM，级与级之间无法各自推进（也无法做 flush/stall）。
//
// ★ 读懂本文件的关键：`valid_next`（这一级现在有没有"真指令"）
//   reset                     → 0（复位后流水线是空的）
//   valid_last & ready_last    → 1（上一级给了有效指令，且上一级也握手成功）
//   否则                       → 0（上一级被冲刷/被暂停，这一级就作废）
//   注意这里只用了 ready_last，**没有**看 ready_next：
//   因为本级的 valid 表示"交给下一级的这一拍我有没有货"，
//   而下一级能不能收，由下一级自己的 valid/ready 逻辑去判断。
//
// ★ 数据寄存器的更新条件 `valid_last & ready_last`
//   两个条件同时成立才更新：上一级有货（valid）且双方握手成功（ready）。
//   被 flush 的那一拍不更新 → 里面的旧值保持，但 valid_next=0，
//   于是 LSU/WBU 看到 valid=0 就不会真的写内存/写寄存器。
//
// 复刻要点 ：
//   1) 所有 output 都必须是 `output logic`（过程赋值）；
//   2) reset 时**控制位全部清 0**（尤其 R_wen/mem_wen）——
//      否则复位那一刻流水线里的垃圾会写进寄存器堆或内存；
//   3) 冲刷（flush）时只依赖 valid 变 0 来屏蔽副作用，不必把数据也清零，
//      省掉一组复位优先级选择器。
//=============================================================================
/*interface define*/

// __opcode__（本文件其实没用到这些宏，但保留和其它模块一致的头部，方便整体移植）
`define R_opcode  7'b0110011
`define lw 7'b0000011                          // lw
`define addi 7'b0010011                        // addi
`define jarl 7'b1100111                        // jalr
`define S_opcode  7'b0100011
`define B_opcode  7'b1100011
`define lui 7'b0110111                         // lui
`define auipc 7'b0010111                       // auipc
`define jal  7'b1101111                        // jal
`define M_opcode  7'b1110011

// alu
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


`define Performance_Count


module EX_LSWB_Reg (
    input clock,                            // 时钟
    input reset,                            // 同步复位（高有效）

    // ---- 握手信号（valid/ready 协议，和 IFID_EX_Reg 完全一致）----
    input valid_last,                       // 上一级（EX）这一拍有没有有效指令
    input ready_last,                       // 上一级是否握手成功（EX 侧 ready）
    input ready_next,                       // 下一级（MEM）是否准备好接收（本模块只透传，不参与判断）
    output logic valid_next,                // 本模块交给下一级的有效位

    // ---- 从 EXU 来的数据/控制 ----
    input mem_ren,                          // 是 load（读内存）
    input mem_wen,                          // 是 store（写内存）
    input R_wen,                            // 要写回寄存器堆
    input [3:0] csr_wen,                    // 写哪个 CSR（mepc/mcause/mstatus/mtvec 各一位）
    input [31:0] Ex_result,                 // EX 算出的结果（load/store 的地址 或 写回值）
    input [4:0] rd,                         // 目的寄存器号
    input [2:0] funct3,                     // 功能位（区分 lb/lh/lw、sb/sh/sw）
    input [31:0] rs2_value,                 // store 要写的数据
    input jump_flag,                        // 是跳转指令（jal/jalr）
    input [31:0] rd_value,                  // 跳转时写回 pc+4
    input [31:0] pc,                        // 当前指令地址（调试/CSR 用）

    // ---- 交给 LSU/WBU 的数据/控制 ----
    output logic mem_ren_reg,               // 打一拍后的 mem_ren
    output logic mem_wen_reg,               // 打一拍后的 mem_wen
    output logic R_wen_reg,                 // 打一拍后的 R_wen
    output logic [3:0] csr_wen_reg,         // 打一拍后的 csr_wen
    output logic [31:0] Ex_result_reg,      // 打一拍后的地址/结果
    output logic [4:0] rd_reg,              // 打一拍后的 rd
    output logic [2:0] funct3_reg,          // 打一拍后的 funct3
    output logic [31:0] rs2_value_reg,      // 打一拍后的 store 数据
    output logic jump_flag_reg,             // 打一拍后的 jump_flag
    output logic [31:0] rd_value_reg,       // 打一拍后的 pc+4
    output logic [31:0] pc_reg              // 打一拍后的 pc
);

    //-------------------------------------------------------------------------
    // ① 有效位：决定这一级"有没有真指令"
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if (reset)                      // 复位：流水线清空
            valid_next <= 1'b0;
        else if (valid_last & ready_last)   // 上一级有货且握手成功 → 本级有货
            valid_next <= 1'b1;
        else                            // 上一级被冲刷 / 被暂停 → 本级作废
            valid_next <= 1'b0;
    end

    //-------------------------------------------------------------------------
    // ② 数据 + 控制：只在"上一级有货且握手成功"的那一拍更新
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if (reset) begin
            // 复位时**控制位必须清零**，特别是 R_wen / mem_wen，
            // 否则复位瞬间流水线里的旧值会把寄存器堆或内存写坏
            mem_ren_reg   <= 0;
            mem_wen_reg   <= 0;
            R_wen_reg     <= 0;
            csr_wen_reg   <= 0;
            Ex_result_reg <= 0;
            rd_value_reg  <= 0;
            rd_reg        <= 0;
            funct3_reg    <= 0;
            rs2_value_reg <= 0;
            jump_flag_reg <= 0;
            pc_reg        <= 0;
        end else if (valid_last & ready_last) begin
            mem_ren_reg   <= mem_ren;       // load 标志
            mem_wen_reg   <= mem_wen;       // store 标志
            R_wen_reg     <= R_wen;         // 写回标志
            csr_wen_reg   <= csr_wen;       // CSR 写使能
            Ex_result_reg <= Ex_result;     // 地址 / 结果
            rd_value_reg  <= rd_value;      // 跳转写回的 pc+4
            rd_reg        <= rd;            // 目的寄存器
            funct3_reg    <= funct3;        // 访存宽度
            rs2_value_reg <= rs2_value;     // store 数据
            jump_flag_reg <= jump_flag;     // 跳转标志
            pc_reg        <= pc;            // 指令地址
        end
        // 注意：else 分支什么都不做 = 保持原值（被暂停时流水寄存器不变）
    end

endmodule
