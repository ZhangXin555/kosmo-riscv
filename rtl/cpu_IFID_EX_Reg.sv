`timescale 1ns/1ps

//=============================================================================
// 模块名 ：IFID_EX_Reg（ID → EX 流水寄存器）
// 流水级 ：介于第 2 级 ID 和第 3 级 EX 之间的"隔板"
// 干什么 ：把 ID 级算好的所有信号，在时钟上升沿**同时**打一拍，送给 EX 级。
//           处理器能"流水"的根本原因就在这里：每一级只干自己那段活，
//           干完把结果推进寄存器，下一拍下一级接着干，上一级同时开始处理下一条。
// 三条规则（复刻时照抄这三条就不会错）：
//   1) reset=1        → 全部清 0（valid=0，相当于流水线里没有指令）
//   2) 有效且下一级接收 → 正常把本拍输入打进寄存器
//   3) 被冲刷(EXU_inst_clr) → 控制信号清零、valid 清零（这条指令被"擦掉"，
//      变成气泡 bubble；数据寄存器不清也无所谓，因为 valid=0 没人会用它）
// 为什么要"冲刷"：分支预测失败 / jal / jalr / 异常时，后面已经取进来的
//   错误指令必须作废，否则会写错寄存器、写错内存。
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

module IFID_EX_Reg(
    input clock,                             // 时钟
    input reset,                             // 复位（同步，高有效）
    input EXU_inst_clr,                      // 冲刷：把本拍要写入的指令变成气泡

    // ---- 握手信号（本设计 ready 恒 1，但结构上保留）----
    input valid_last,                        // 上一级（ID）给的 valid
    input ready_last,                        // 给上一级的 ready
    input ready_next,                        // 下一级（EX）给的 ready
    output logic valid_next,                 // 送给下一级的 valid

    // ---- 来自 IDU 的数据/控制 ----
    input [2:0] funct3,                      // 功能码
    input [3:0] csr_wen,                     // CSR 写使能
    input R_wen,                             // 通用寄存器写使能
    input mem_wen,                           // 写存储器
    input mem_ren,                           // 读存储器
    input [4:0] rd,                          // 目的寄存器号
    input [31:0] pc,                         // 本条指令的 PC
    input [3:0] alu_opcode,                  // ALU 操作码
    input inv_flag,                          // 比较结果是否取反（分支用）
    input jump_flag,                         // 跳转标志
    input branch_flag,                       // 分支标志
    input fetch_i_flag,                      // fence.i 标志
    input [31:0] branch_pc,                  // 分支目标地址
    input [31:0] rs2_value,                  // rs2 原值（store 数据用）
    input [31:0] add1,                       // ALU 操作数 A
    input [31:0] add2,                       // ALU 操作数 B
    input [31:0] rd_value,                   // 预先算好的写回值

    // ---- 送给 EXU 的同类信号（全部加 _reg 后缀）----
    output logic [2:0] funct3_reg,
    output logic [3:0] csr_wen_reg,
    output logic R_wen_reg,
    output logic mem_wen_reg,
    output logic mem_ren_reg,
    output logic [4:0] rd_reg,
    output logic [31:0] pc_reg,
    output logic [3:0] alu_opcode_reg,
    output logic inv_flag_reg,
    output logic jump_flag_reg,
    output logic branch_flag_reg,
    output logic fetch_i_reg,
    output logic [31:0] branch_pc_reg,
    output logic [31:0] rs2_value_reg,
    output logic [31:0] add1_reg,
    output logic [31:0] add2_reg,
    output logic [31:0] rd_value_reg
);

    //-------------------------------------------------------------------------
    // ① valid 寄存器：决定"这一格流水里到底有没有一条真指令"
    //    冲刷时置 0 → 后面各级看到 valid=0 就知道这是个气泡，什么都不能写。
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if(reset)                                     // 复位：流水线清空
            valid_next <= 1'b0;
        else if(valid_last & ready_next & EXU_inst_clr)   // 有指令但被冲刷
            valid_next <= 1'b0;
        else if(valid_last & ready_next)              // 正常接收
            valid_next <= 1'b1;
        else                                          // 上一级没给指令（气泡）
            valid_next <= 1'b0;
    end

    //-------------------------------------------------------------------------
    // ② 数据寄存器（PC、操作数、rd、funct3、ALU 码……）
    //    只在"有效且下一级能收"时更新；复位清 0；冲刷时不清（valid=0 就够）
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if(reset)begin
            funct3_reg      <= 0;
            rd_reg          <= 0;
            alu_opcode_reg  <= 0;
            inv_flag_reg    <= 0;
            rs2_value_reg   <= 0;
            add1_reg        <= 0;
            add2_reg        <= 0;
            rd_value_reg    <= 0;
            branch_pc_reg   <= 0;
            pc_reg          <= 0;
        end
        else if(valid_last & ready_next)
        begin
            funct3_reg      <= funct3;      // 功能码
            rd_reg          <= rd;          // 目的寄存器
            alu_opcode_reg  <= alu_opcode;  // ALU 操作码
            inv_flag_reg    <= inv_flag;    // 比较取反
            rs2_value_reg   <= rs2_value;   // store 数据
            add1_reg        <= add1;        // ALU A
            add2_reg        <= add2;        // ALU B
            rd_value_reg    <= rd_value;    // 写回值（jal 的 pc+4 等）
            branch_pc_reg   <= branch_pc;   // 分支目标
            pc_reg          <= pc;          // 本条 PC
        end
    end

    //-------------------------------------------------------------------------
    // ③ 控制寄存器：写使能一类信号。冲刷时必须清 0，
    //    否则一条被作废的指令仍可能写寄存器/写内存，把结果搞坏。
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if(reset)begin
            mem_ren_reg     <= 0;
            csr_wen_reg     <= 0;
            R_wen_reg       <= 0;
            mem_wen_reg     <= 0;
            jump_flag_reg   <= 0;
            branch_flag_reg <= 0;
            fetch_i_reg     <= 0;
        end
        else if(valid_last & ready_next & EXU_inst_clr)begin
            mem_ren_reg     <= 0;            // 冲刷：禁止读内存
            csr_wen_reg     <= 0;            // 禁止写 CSR
            R_wen_reg       <= 0;            // 禁止写通用寄存器
            mem_wen_reg     <= 0;            // 禁止写内存
            jump_flag_reg   <= 0;            // 取消跳转
            branch_flag_reg <= 0;            // 取消分支
            fetch_i_reg     <= 0;            // 取消 fence.i
        end
        else if(valid_last & ready_next) begin
            mem_ren_reg     <= mem_ren;
            csr_wen_reg     <= csr_wen;
            R_wen_reg       <= R_wen;
            mem_wen_reg     <= mem_wen;
            jump_flag_reg   <= jump_flag;
            branch_flag_reg <= branch_flag;
            fetch_i_reg     <= fetch_i_flag;
        end
    end

endmodule
