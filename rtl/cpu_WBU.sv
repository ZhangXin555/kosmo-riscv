`timescale 1ns/1ps

//=============================================================================
// 模块名 ：WBU（Write Back Unit，写回单元）
// 流水级 ：WB（第 5 级，最后一级）
// 干什么 ：决定"这条指令最后写回寄存器堆的值是哪一个"，并把写回使能交出去。
//          它是纯组合逻辑，本身没有寄存器；写回动作发生在 RegisterFile 里。
//
// ★ 写回值三选一（本模块唯一真正的逻辑，务必记牢）
//     rd_value_next = (jump_flag | |csr_wen) ? rd_value    // ① 跳转 or 写 CSR → pc+4 / csr 旧值
//                   : (mem_ren)             ? MEM_Rdata   // ② load → 存储器读回的数据
//                   :                         Ex_result;  // ③ 其它 → ALU 结果
//   记忆口诀：跳转/CSR 优先，其次 load，最后才是 ALU。
//   为什么 CSR 要写回 rd_value（pc+4）？因为 CSR 指令（csrrw 等）要顺带
//   把 CSR 旧值写进 rd —— 旧值由 Reg_Stack 从 csrs 端口旁路给 rd_value，
//   这里只是选通路。
//
// ★ `R_wen_next = R_wen & valid`
//   valid=0 表示这一拍流水线里是"被冲刷掉的假指令"，
//   即使它携带 R_wen=1，也绝不能真的写寄存器堆 —— 这一句就是防幽灵写回的闸门。
//
// ★ `ready = 1'b1`
//   WB 是最后一级，永远能"接收"（写回在当拍就完成，不需要等），
//   所以 ready 恒 1。也正因为如此，WB 不会成为整条流水线的瓶颈。
//
// 复刻要点 ：三个输出
//   1) `pc_out`         → 给 IFU 判断"现在该不该跳"（和 dnpc 比较）
//   2) `rd_value_next`  → 写回数据
//   3) `R_wen_next`     → 写回使能（已和 valid 与过）
//=============================================================================
/*interface define*/

// __opcode__（头部宏与其它模块保持一致，实际本文件未用到）
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

module WBU (
    input clock,                    // 时钟（本模块不用，保留统一接口）
    input reset,                    // 复位（本模块不用，保留统一接口）

    input [31:0] MEM_Rdata,         // 存储器读回的数据（load 结果）
    input [31:0] Ex_result,         // ALU 结果
    input [31:0] rd_value,          // 跳转时的 pc+4 / CSR 旧值
    input [4:0] rd,                 // 目的寄存器号
    input [3:0] csr_wen,            // CSR 写使能（4 位分别对应 4 个 CSR）
    input R_wen,                    // 要写回寄存器堆
    input mem_ren,                  // 是 load
    input jump_flag,                // 是跳转
    input [31:0] pc,                // 指令地址

    input valid,                    // 这一拍指令是否有效
    output ready,                   // 本模块永远 ready

    output valid_next,              // 有效标志往下传
    output R_wen_next,              // 真正的写回使能（与 valid 相与）
    output [3:0] csr_wen_next,      // CSR 写使能
    output [31:0] csrd,             // 送给 CSR 的写数据（= ALU 结果）

    output logic [31:0] pc_out,     // 指令 PC（给 IFU 做跳转判断）
    output [31:0] rd_value_next,    // 最终写回数据
    output [4:0] rd_next            // 最终写回寄存器号
);

    //-------------------------------------------------------------------------
    // ① PC 直通（IFU 用它和 dnpc 比较，判断是否要 flush 前两级）
    //-------------------------------------------------------------------------
    assign pc_out = pc;

    //-------------------------------------------------------------------------
    // ② 有效位直通
    //-------------------------------------------------------------------------
    assign valid_next = valid;

    //-------------------------------------------------------------------------
    // ③ ★写回值三选一★
    //    跳转 / 写 CSR  → rd_value（pc+4 或 csr 旧值）
    //    load          → MEM_Rdata（存储器读回的）
    //    其它          → Ex_result（ALU 结果）
    //-------------------------------------------------------------------------
    assign rd_value_next = (jump_flag | (|csr_wen)) ? rd_value
                         : (mem_ren)                ? MEM_Rdata
                         :                            Ex_result;

    //-------------------------------------------------------------------------
    // ④ CSR 写数据 & 写使能
    //-------------------------------------------------------------------------
    assign csrd         = Ex_result;        // CSR 新值来自 ALU 结果（csrrw 的 rs1）
    assign csr_wen_next = csr_wen;          // CSR 写使能透传

    //-------------------------------------------------------------------------
    // ⑤ ★写回使能必须与 valid 相与★
    //    被冲刷的假指令即使带着 R_wen=1 也不能写寄存器堆
    //-------------------------------------------------------------------------
    assign R_wen_next = R_wen & valid;

    //-------------------------------------------------------------------------
    // ⑥ 目的寄存器号 & ready
    //-------------------------------------------------------------------------
    assign rd_next = rd;
    assign ready   = 1'b1;                  // 最后一级，永远能收

endmodule  //WBU
