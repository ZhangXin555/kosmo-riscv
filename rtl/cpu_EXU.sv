`timescale 1ns/1ps

//=============================================================================
// 模块名 ：EXU（Execute Unit，执行单元）
// 流水级 ：第 3 级 —— EX（真正算数的那一级）
// 干什么 ：1) 把 ID 送来的操作数 A/B 丢进 ALU 算（加减/逻辑/移位/比较）
//           2) 把控制信号原样"透传"给 EX→MEM 流水寄存器
//           3) 用 inv_flag 对"比较结果"做一次取反，实现 beq/bge/bgeu
// 关键点 ：
//   * EXU 本身没有状态（纯组合逻辑），流水寄存器在 EX_LSWB_Reg 里；
//   * `Ex_result = alu_result ^ {31'd0, inv_flag_reg}` 这行是"取反技巧"：
//       ALU 只会算"小于"和"不相等"，分支指令需要"大于等于""相等"，
//       beq/bge/bgeu 在 ID 级把 inv_flag 置 1，这里只翻转最低位就完成等价判断，
//       省掉一条"再比较一次"的路径，关键路径更短、频率更高；
//   * 访存地址、寄存器写回值都从 Ex_result 走：lw/sw 的地址 = rs1+imm，
//     alu 结果 = 写回值。
//=============================================================================
/*interface define*/

// __opcode__
`define R_opcode  7'b0110011                 // R 型
`define lw 7'b0000011                        // load
`define addi 7'b0010011                      // 立即数算术
`define jarl 7'b1100111                      // jalr
`define S_opcode  7'b0100011                 // store
`define B_opcode  7'b1100011                 // 条件分支
`define lui 7'b0110111                       // lui
`define auipc 7'b0010111                     // auipc
`define jal  7'b1101111                      // jal
`define M_opcode  7'b1110011                 // 系统指令

// ---- ALU 操作码 ----
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

module EXU (
    // ---- 来自 IFID_EX_Reg（ID 打过来的）----
    input [2:0] funct3_reg,                  // 功能码
    input [3:0] csr_wen_reg,                 // CSR 写使能
    input R_wen_reg,                         // 写通用寄存器
    input mem_wen_reg,                       // 写内存
    input mem_ren_reg,                       // 读内存
    input [4:0] rd_reg,                      // 目的寄存器
    input [31:0] pc_reg,                     // 本条 PC
    input [3:0] alu_opcode_reg,              // ALU 操作码
    input inv_flag_reg,                      // 比较结果取反
    input jump_flag_reg,                     // 跳转
    input branch_flag_reg,                   // 分支
    input fetch_i_reg,                       // fence.i
    input [31:0] branch_pc_reg,              // 分支目标
    input [31:0] rs2_value_reg,              // rs2 原值（store 数据）
    input [31:0] add1_reg,                   // ALU A
    input [31:0] add2_reg,                   // ALU B
    input [31:0] rd_value_reg,               // 预计算写回值

    // ---- 送给 EX_LSWB_Reg（往下打一拍）----
    output [2:0] funct3_next,
    output [3:0] csr_wen_next,
    output R_wen_next,
    output mem_wen_next,
    output mem_ren_next,
    output [4:0] rd_next,
    output [31:0] pc_next,
    output jump_flag_next,
    output [31:0] rs2_value_next,
    output [31:0] rd_value_next,
    output [31:0] Ex_result,                 // ALU 结果（下面两级都要用）
    output fetch_i_flag_next,
    output branch_flag_next,
    output [31:0] branch_pc_next
);
    logic [31:0] alu_result;                 // ALU 原始输出

    //-------------------------------------------------------------------------
    // 控制信号透传：EX 级不改这些信号，只是原样交给下一级寄存器
    //-------------------------------------------------------------------------
    assign funct3_next = funct3_reg;                 // 功能码
    assign csr_wen_next = csr_wen_reg;               // CSR 写使能
    assign R_wen_next = R_wen_reg;                   // 写寄存器
    assign mem_wen_next = mem_wen_reg;               // 写内存
    assign mem_ren_next = mem_ren_reg;               // 读内存
    assign rd_next = rd_reg;                         // 目的寄存器
    assign pc_next = pc_reg;                         // PC
    assign jump_flag_next = jump_flag_reg;           // 跳转标志
    assign rs2_value_next = rs2_value_reg;           // store 数据（原样带下去）
    assign rd_value_next = rd_value_reg;             // 写回值（原样带下去）
    assign fetch_i_flag_next = fetch_i_reg;          // fence.i
    assign branch_flag_next = branch_flag_reg;       // 分支标志
    assign branch_pc_next = branch_pc_reg;           // 分支目标

    //-------------------------------------------------------------------------
    // ALU 结果 + 取反技巧
    //   inv_flag_reg = 1 时，只翻转 bit0：
    //     ALU 算 "不相等"(1) → 翻转成 0 → bne 不成立；beq 成立…
    //   注意 ALU 里 equal 的定义是 (d1 != d2)，配合 inv_flag 正好实现两类分支。
    //-------------------------------------------------------------------------
    assign Ex_result = alu_result ^ {31'd0, inv_flag_reg};

    //-------------------------------------------------------------------------
    // 例化 ALU（组合逻辑，参数化位宽 BW）
    //   输入：d1=A, d2=B, choice=操作码；输出：result
    //-------------------------------------------------------------------------
    /* verilator lint_off PINMISSING */
    ALU #(
        .BW(32)                              // 32 位数据通路
    ) ALU_i0 (
        .d1(add1_reg),                       // 操作数 A
        .d2(add2_reg),                       // 操作数 B
        .choice(alu_opcode_reg),             // 操作码
        .result(alu_result)                  // 结果
    );
endmodule
