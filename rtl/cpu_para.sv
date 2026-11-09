`timescale 1ns/1ps

//=============================================================================
// 模块名 ：para（全局参数宏定义文件，没有逻辑）
// 位置   ：工程里当"公共头文件"用；只放 `define，不产生任何电路
// 干什么 ：集中定义 RISC-V opcode 和 ALU 操作码，供各模块 `include/复制 使用。
// 注意   ：本工程各 .sv 是各自复制一份宏（不靠 `include），
//          所以这个文件即使在工程里被综合，也只会生成一个空模块。
//=============================================================================
/*interface define*/

// ---- RISC-V 指令 opcode（inst[6:0]）----
`define R_opcode  7'b0110011          // R 型：寄存器-寄存器运算
`define lw 7'b0000011                 // I 型 load
`define addi 7'b0010011               // I 型 addi
`define jarl 7'b1100111               // I 型 jalr（原文拼写 jarl）
`define S_opcode  7'b0100011          // S 型 store
`define B_opcode  7'b1100011          // B 型 条件分支
`define lui 7'b0110111                // U 型 lui
`define auipc 7'b0010111              // U 型 auipc
`define jal  7'b1101111               // J 型 jal
`define M_opcode  7'b1110011          // 系统指令

// ---- ALU 操作码（4 位）----
`define alu_add                   4'b0000   // 加
`define alu_sub                   4'b0001   // 减
`define alu_or                    4'b0010   // 或
`define alu_and                   4'b0011   // 与
`define alu_xor                   4'b0100   // 异或
`define alu_signed_comparator     4'b0101   // 有符号比较（slt）
`define alu_unsigned_comparator   4'b0110   // 无符号比较（sltu）
`define alu_equal                 4'b0111   // 相等比较（beq）
`define alu_sll                   4'b1000   // 逻辑左移
`define alu_srl                   4'b1001   // 逻辑右移
`define alu_sra                   4'b1010   // 算术右移

`define Performance_Count                // 性能统计开关（拍数/CPI）
