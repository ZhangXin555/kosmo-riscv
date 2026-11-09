`timescale 1ns/1ps

/*interface define*/


//=============================================================================
// myCPU：5 级流水 RISC-V（RV32I 子集）处理器顶层 —— 只做"连线"，不写逻辑
//=============================================================================
// 【整体结构】五级流水，级与级之间用"流水寄存器"隔开：
//
//   IF(IFU 取指) → [IFID_EX_Reg] → ID(IDU 译码+读寄存器)
//        → [IFID_EX_Reg 的另一半: EX 入口] → EX(EXU 执行+ALU)
//        → [EX_LSWB_Reg] → MEM(LSU 访存) → WB(WBU 写回)
//
//   严格说本 CPU 的流水寄存器是两级：
//     · IFID_EX_Reg：ID 级的输入数据(inst 译码结果/寄存器值) 和 EX 级的输入 是同一个模块，
//       它同时承担"IF/ID → ID/EX"这道墙（工程实现上算一级）
//     · EX_LSWB_Reg：EX → MEM 这道墙
//   WB 级(WBU) 是纯组合，所以物理上是 4 个触发器级 + 1 个组合级 = 5 级流水。
//
// 【握手协议】每一级都有 valid / ready：
//   valid=1 表示"我这一级里有真指令"，ready=1 表示"我这一级能接收上一级的指令"。
//   上一级只有在 valid_last & ready_last 同时为 1 时才往前推（见各流水寄存器）。
//   本 CPU 里 ready 全部恒为 1（除了 IFU 的 stall 分支），也就是**没有反压**，
//   真正的停顿只来自"load-use 冒险"（Control 里把 IFU_stall 拉高）。
//
// 【三条关键路径（读代码时按这三条走）】
//   1) 取指/跳转：IFU_pc → irom_addr → irom_data → inst → IDU → Control → dnpc/dnpc_flag → IFU
//   2) 数据旁路：EXU 用到的操作数不一定来自寄存器堆，可能是上一条指令刚算出的结果
//      → Control 输出 EXU_rs1_in / EXU_rs2_in（在 IDU 原值 / EXU 结果 / MEM 结果 / WB 写回 之间选）
//   3) 写回：WBU_rd_value → IDU.rd_value → Reg_Stack 写入寄存器堆
//=============================================================================


// __opcode__（RV32I 操作码，7 位；各模块头部都重复定义一遍，方便单文件搬走）
`define R_opcode  7'b0110011                    // R 型：add/sub/and/or/...
`define lw 7'b0000011                          // lw
`define addi 7'b0010011                        // addi（I 型算术）
`define jarl 7'b1100111                        // jalr
`define S_opcode  7'b0100011                   // store
`define B_opcode  7'b1100011                   // 分支
`define lui 7'b0110111                         // lui
`define auipc 7'b0010111                       // auipc
`define jal  7'b1101111                        // jal
`define M_opcode  7'b1110011                   // CSR / ecall / mret

// alu 操作码（4 位，Control/IDU 译出来，ALU 执行）
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


`define Performance_Count                      // 打开性能计数器（统计周期/停顿）


module myCPU (
    input cpu_clk,                             // CPU 时钟（板子上 50 MHz）
    input cpu_rst,                             // 复位（高有效）

    // ---- 指令存储器（IROM）接口 ----
    output [31:0] irom_addr,                   // 取指地址 = IFU 的 PC
    input  [31:0] irom_data,                   // 取回的指令

    // ---- 外设/数据存储器（DRAM + UART + 计数器）接口 ----
    output [31:0] perip_addr,                  // 访存地址（字节地址）
    output [31:0] perip_rd_addr,               // ★读地址（EX 级组合给出，见文件末尾说明）
    output perip_wen,                          // 写使能
    output [ 1:0] perip_mask,                  // 写字节掩码
    output [31:0] perip_wdata,                 // 写数据
    input  [31:0] perip_rdata                  // 读回数据
);

    //=========================================================================
    // 一、IFU（取指单元）相关信号
    //=========================================================================
    logic [31:0] IFU_inst;                     // 取到的指令
    logic IFU_valid;                           // IF 级有效
    logic [31:0] IFU_pc;                       // 当前 PC
    logic [31:0] IFU_snpc;                     // PC+4（顺序下一条）

    //=========================================================================
    // 二、IDU（译码单元）相关信号
    //=========================================================================
    logic [31:0] IDU_pc;                       // 指令 PC
    logic [ 4:0] IDU_rd;                       // 目的寄存器号
    logic [ 2:0] IDU_funct3;                   // funct3
    logic IDU_mret_flag;                       // mret 指令
    logic IDU_ecall_flag;                      // ecall 指令
    logic [31:0] IDU_rs2_value;                // rs2 读出值
    logic [31:0] IDU_rs1_value;                // rs1 读出值
    logic [ 3:0] IDU_csr_wen;                  // CSR 写使能（4 个 CSR 各一位）
    logic IDU_R_wen;                           // 要写寄存器堆
    logic [31:0] IDU_rd_value;                 // 写回值（跳转时 pc+4）
    logic IDU_mem_wen;                         // store
    logic IDU_mem_ren;                         // load
    logic IDU_inv_flag;                        // ALU 结果取反标志（分支用）
    logic IDU_branch_flag;                     // 分支指令
    logic IDU_jump_flag;                       // 跳转指令
    logic [31:0] IDU_add1_value;               // ALU 操作数 1
    logic [31:0] IDU_add2_value;               // ALU 操作数 2
    logic [3:0] IDU_alu_opcode;                // ALU 操作码
    logic [4:0] IDU_rs1;                       // rs1 号
    logic [4:0] IDU_rs2;                       // rs2 号
    logic [31:0] IDU_a0_value;                 // a0 的值（测试程序结果打印用）
    logic [31:0] IDU_mepc_out;                 // CSR mepc 值
    logic [31:0] IDU_mtvec_out;                // CSR mtvec 值
    logic [1:0] exc_cause;                     // 异常原因
    logic       ifault;                        // 取指异常（PC 跑出 IROM 范围）
    logic [31:0] IDU_branch_pc;                // 分支目标地址 = pc+imm
    logic IDU_valid;                           // ID 级有效
    logic IDU_ready;                           // ID 级 ready（= 寄存器堆能收）
    logic IDU_fence_i_flag;                    // fence.i 指令

    //=========================================================================
    // 三、IFID_EX_Reg（ID→EX 流水寄存器）输出
    //=========================================================================
    logic [ 2:0] IFID_EX_funct3_reg;
    logic [ 3:0] IFID_EX_csr_wen_reg;
    logic IFID_EX_R_wen_reg;
    logic IFID_EX_mem_wen_reg;
    logic IFID_EX_mem_ren_reg;
    logic [4:0] IFID_EX_rd_reg;
    logic [31:0] IFID_EX_pc_reg;
    logic [3:0] IFID_EX_alu_opcode_reg;
    logic IFID_EX_inv_flag_reg;
    logic IFID_EX_jump_flag_reg;
    logic IFID_EX_branch_flag_reg;
    logic IFID_EX_fetch_i_reg;
    logic [31:0] IFID_EX_branch_pc_reg;
    logic [31:0] IFID_EX_rs2_value_reg;
    logic [31:0] IFID_EX_add1_reg;
    logic [31:0] IFID_EX_add2_reg;
    logic [31:0] IFID_EX_rd_value_reg;
    logic IFID_EX_valid;                       // EX 级有效

    //=========================================================================
    // 四、EXU（执行单元）输出
    //=========================================================================
    logic [2:0] EXU_funct3;
    logic [3:0] EXU_csr_wen;
    logic EXU_R_wen;
    logic EXU_mem_wen;
    logic EXU_mem_ren;
    logic [ 4:0] EXU_rd;
    logic [31:0] EXU_pc;
    logic EXU_jump_flag;
    logic [31:0] EXU_rs2_value;
    logic [31:0] EXU_rd_value;
    logic [31:0] EXU_Ex_result;                // ★ALU 结果（也是访存地址）
    logic EXU_fence_i_flag;
    logic EXU_branch_flag;
    logic [31:0] EXU_branch_pc;

    //=========================================================================
    // 五、EX_LSWB_Reg（EX→MEM 流水寄存器）输出
    //=========================================================================
    logic EX_LSWB_mem_ren_reg;
    logic EX_LSWB_mem_wen_reg;
    logic EX_LSWB_R_wen_reg;
    logic [3:0] EX_LSWB_csr_wen_reg;
    logic [31:0] EX_LSWB_Ex_result_reg;
    logic [4:0] EX_LSWB_rd_reg;
    logic [2:0] EX_LSWB_funct3_reg;
    logic [31:0] EX_LSWB_rs2_value_reg;
    logic EX_LSWB_jump_flag_reg;
    logic [31:0] EX_LSWB_rd_value_reg;
    logic [31:0] EX_LSWB_pc_reg;
    logic EX_LSWB_valid;                       // MEM 级有效

    //=========================================================================
    // 六、LSU（访存）输出
    //=========================================================================
    logic LSU_jump_flag;
    logic LSU_R_wen;
    logic [31:0] LSU_Rdata;                    // 已按宽度/符号整理好的读数据
    logic [3:0] LSU_csr_wen;
    logic [31:0] LSU_Ex_result;
    logic [31:0] LSU_rd_value;
    logic [31:0] LSU_pc;
    logic [4:0] LSU_rd;
    logic LSU_mem_ren;
    logic LSU_ready;
    logic LSU_valid;

    //=========================================================================
    // 七、WBU（写回）输出
    //=========================================================================
    logic [31:0] WBU_pc;
    logic [31:0] WBU_rd_value;                 // ★最终写回值
    logic [31:0] WBU_csrd;                     // CSR 写数据
    logic [ 4:0] WBU_rd;
    logic WBU_R_wen;                           // ★最终写回使能
    logic [ 3:0] WBU_csr_wen;
    logic WBU_ready;
    logic WBU_valid;

    //=========================================================================
    // 八、Control（控制单元）输出 —— 整条流水线的"交通警察"
    //=========================================================================
    logic dnpc_flag;                           // 是否要跳转（改 PC）
    logic EXU_inst_clear;                      // 冲刷 EX 级（ID 级那条作废）
    logic [31:0] dnpc;                         // 跳转目标地址
    logic IFU_stall;                           // ★取指停顿（load-use 冒险时拉高）
    logic icache_clr;                          // 清指令缓存/取指有效位
    logic [31:0] EXU_rs1_in;                   // ★旁路后的 rs1 实际值
    logic [31:0] EXU_rs2_in;                   // ★旁路后的 rs2 实际值

    //=========================================================================
    // 九、连线主体
    //=========================================================================
    // IROM 的地址就是 IFU 的 PC
    assign irom_addr = IFU_pc;

    //-------------------------------------------------------------------------
    // 9.1 IFU：取指。PC 由 Control 的 dnpc_flag/dnpc 控制跳转，由 stall 控制停顿
    //     .ready 接 IDU_ready：ID 级能收，IF 才能往下推
    //-------------------------------------------------------------------------
    IFU IFU_Inst0 (
        .clock (cpu_clk),
        .reset (cpu_rst),
        .dnpc (dnpc),                          // 跳转目标
        .dnpc_flag(dnpc_flag),                 // 跳转使能
        .stall (IFU_stall),                    // 停顿（保持 PC）
        .pc (IFU_pc),                          // 当前 PC
        .snpc (IFU_snpc),                      // PC+4
        .inst (IFU_inst),                      // 输出的指令
        .irom_data(irom_data),                 // 从 IROM 读回的指令
        .ready (IDU_ready),                    // 下一级(ID)是否准备好
        .valid (IFU_valid),                    // 本级有效
        .ifault (ifault)                       // 取指地址越界 → 异常
    );

    //-------------------------------------------------------------------------
    // 9.2 Control：**整个 CPU 的大脑**，只在本文件里看到它连线，逻辑在 cpu_Control.sv
    //     它看的输入：
    //       · 指令信息（mret/ecall/fence.i、branch/jump 标志、rs1/rs2 号）
    //       · 各流水级是否有效（IDU_valid / EXU_valid / MEM_valid）
    //       · EXU 的运算结果、MEM 的读数据、WB 的写回值（做旁路选择）
    //     它出的输出：
    //       · dnpc / dnpc_flag  （跳不跳、跳到哪）
    //       · IFU_stall         （取指停顿）
    //       · EXU_inst_clear    （冲刷 EX 级）
    //       · EXU_rs1_in/rs2_in （旁路后的操作数）
    //-------------------------------------------------------------------------
    Control Control_inst0 (
        .clock (cpu_clk),
        .reset (cpu_rst),
        .mtvec_out (IDU_mtvec_out),            // 异常入口地址
        .mepc_out (IDU_mepc_out),              // 异常返回地址
        .branch_pc (EXU_branch_pc),            // EX 级算好的分支目标
        .Ex_result (EXU_Ex_result),            // EX 级结果（旁路源之一）
        .MEM_Ex_result(WBU_rd_value),          // MEM/WB 的写回值（旁路源之一）
        .IDU_rs1_value(IDU_rs1_value),         // ID 级读出的 rs1
        .IDU_rs2_value(IDU_rs2_value),         // ID 级读出的 rs2
        .MEM_Rdata (LSU_Rdata),                // load 读回值（旁路源之一）
        .branch_flag (EXU_branch_flag),
        .jump_flag (EXU_jump_flag),
        .mret_flag (IDU_mret_flag),
        .ecall_flag (IDU_ecall_flag),
        .fence_i_flag (EXU_fence_i_flag),
        .MEM_mem_ren (LSU_mem_ren),
        .IDU_rs1 (IDU_rs1),
        .IDU_rs2 (IDU_rs2),
        .IDU_valid (IDU_valid),
        .EXU_valid (IFID_EX_valid),
        .MEM_valid (LSU_valid),
        .EXU_rd (EXU_rd),
        .MEM_rd (LSU_rd),
        .EXU_mem_ren (EXU_mem_ren),
        .EXU_R_Wen (EXU_R_wen),
        .MEM_R_Wen (LSU_R_wen),
        .IFU_stall (IFU_stall),
        .EXU_rs1_in (EXU_rs1_in),
        .EXU_rs2_in (EXU_rs2_in),
        .dnpc (dnpc),
        .icache_clr (icache_clr),
        .EXU_inst_clear (EXU_inst_clear),
        .dnpc_flag (dnpc_flag),
        .exc_cause (exc_cause),
        .ifault (ifault)
    );

    //-------------------------------------------------------------------------
    // 9.3 IDU：译码 + 读寄存器堆 + 生成全部控制信号
    //     · 输入 inst / pc / snpc
    //     · 写回口接 WBU（rd_value / rd / R_wen），所以寄存器写在 WB 级完成
    //     · EXU_rs1_in / EXU_rs2_in 从 Control 回来 → 喂给 ALU 的操作数
    //     · branch_pc = pc + imm（分支目标），在 ID 级就算好
    //-------------------------------------------------------------------------
    IDU IDU_Inst0 (
        .clock (cpu_clk),
        .reset (cpu_rst),
        .snpc (IFU_snpc),
        .inst (IFU_inst),
        .pc (IFU_pc),
        .rd_value (WBU_rd_value),              // ★WB 级写回值
        .csrd (WBU_csrd),
        .rd (WBU_rd),
        .R_wen (WBU_R_wen),                    // ★WB 级写回使能
        .csr_wen (WBU_csr_wen),
        .EXU_rs1_in (EXU_rs1_in),              // 旁路后的 rs1
        .EXU_rs2_in (EXU_rs2_in),              // 旁路后的 rs2
        .branch_pc (IDU_branch_pc),
        .rd_next (IDU_rd),
        .funct3 (IDU_funct3),
        .mret_flag (IDU_mret_flag),
        .ecall_flag (IDU_ecall_flag),
        .fence_i_flag (IDU_fence_i_flag),
        .add2_value (IDU_add2_value),
        .add1_value (IDU_add1_value),
        .rs1_value (IDU_rs1_value),
        .rs2_value (IDU_rs2_value),
        .csr_wen_next (IDU_csr_wen),
        .R_wen_next (IDU_R_wen),
        .rd_value_next(IDU_rd_value),
        .mem_wen (IDU_mem_wen),
        .mem_ren (IDU_mem_ren),
        .inv_flag (IDU_inv_flag),
        .exc_cause (exc_cause),
        .branch_flag (IDU_branch_flag),
        .jump_flag (IDU_jump_flag),
        .alu_opcode (IDU_alu_opcode),
        .pc_out (IDU_pc),
        .rs1 (IDU_rs1),
        .rs2 (IDU_rs2),
        .a0_value (IDU_a0_value),
        .mepc_out (IDU_mepc_out),
        .mtvec_out (IDU_mtvec_out),
        .valid_last (IFU_valid),               // 上一级(IF)有效
        .ready_last (IDU_ready),               // 本级 ready
        .ready_next (1'b1),                    // IFID_EX_Reg 永远能收
        .valid_next (IDU_valid)
    );

    //-------------------------------------------------------------------------
    // 9.4 IFID_EX_Reg：ID → EX 的流水寄存器
    //     · EXU_inst_clr 来自 Control：被冲刷时把 valid 清零（作废这条指令）
    //     · 数据段：funct3/rd/alu_opcode/rs2/add1/add2/rd_value/branch_pc/pc
    //     · 控制段：mem_ren/mem_wen/R_wen/csr_wen/jump/branch/fetch_i
    //-------------------------------------------------------------------------
    IFID_EX_Reg IFID_EX_Reg_inst0 (
        .clock (cpu_clk),
        .reset (cpu_rst),
        .EXU_inst_clr (EXU_inst_clear),
        .valid_last (IDU_valid),
        .ready_last (1'b1),
        .ready_next (1'b1),
        .valid_next (IFID_EX_valid),
        .funct3 (IDU_funct3),
        .csr_wen (IDU_csr_wen),
        .R_wen (IDU_R_wen),
        .mem_wen (IDU_mem_wen),
        .mem_ren (IDU_mem_ren),
        .rd (IDU_rd),
        .pc (IDU_pc),
        .alu_opcode (IDU_alu_opcode),
        .inv_flag (IDU_inv_flag),
        .jump_flag (IDU_jump_flag),
        .branch_flag (IDU_branch_flag),
        .fetch_i_flag (IDU_fence_i_flag),
        .branch_pc (IDU_branch_pc),
        .rs2_value (EXU_rs2_in),               // ★注意：存的是**旁路后**的 rs2
        .add1 (IDU_add1_value),
        .add2 (IDU_add2_value),
        .rd_value (IDU_rd_value),
        .funct3_reg (IFID_EX_funct3_reg),
        .csr_wen_reg (IFID_EX_csr_wen_reg),
        .R_wen_reg (IFID_EX_R_wen_reg),
        .mem_wen_reg (IFID_EX_mem_wen_reg),
        .mem_ren_reg (IFID_EX_mem_ren_reg),
        .rd_reg (IFID_EX_rd_reg),
        .pc_reg (IFID_EX_pc_reg),
        .alu_opcode_reg(IFID_EX_alu_opcode_reg),
        .inv_flag_reg (IFID_EX_inv_flag_reg),
        .jump_flag_reg(IFID_EX_jump_flag_reg),
        .branch_flag_reg(IFID_EX_branch_flag_reg),
        .fetch_i_reg (IFID_EX_fetch_i_reg),
        .branch_pc_reg(IFID_EX_branch_pc_reg),
        .rs2_value_reg(IFID_EX_rs2_value_reg),
        .add1_reg (IFID_EX_add1_reg),
        .add2_reg (IFID_EX_add2_reg),
        .rd_value_reg (IFID_EX_rd_value_reg)
    );

    //-------------------------------------------------------------------------
    // 9.5 EXU：执行。核心是一个 ALU（加/减/逻辑/比较/移位）+ inv_flag 取反技巧
    //     Ex_result = ALU 结果；分支指令用它和 inv_flag 一起判断跳不跳
    //-------------------------------------------------------------------------
    EXU EXU_Inst0 (
        .funct3_reg (IFID_EX_funct3_reg),
        .csr_wen_reg (IFID_EX_csr_wen_reg),
        .R_wen_reg (IFID_EX_R_wen_reg),
        .mem_wen_reg (IFID_EX_mem_wen_reg),
        .mem_ren_reg (IFID_EX_mem_ren_reg),
        .rd_reg (IFID_EX_rd_reg),
        .pc_reg (IFID_EX_pc_reg),
        .alu_opcode_reg (IFID_EX_alu_opcode_reg),
        .inv_flag_reg (IFID_EX_inv_flag_reg),
        .jump_flag_reg (IFID_EX_jump_flag_reg),
        .branch_flag_reg (IFID_EX_branch_flag_reg),
        .fetch_i_reg (IFID_EX_fetch_i_reg),
        .branch_pc_reg (IFID_EX_branch_pc_reg),
        .rs2_value_reg (IFID_EX_rs2_value_reg),
        .add1_reg (IFID_EX_add1_reg),
        .add2_reg (IFID_EX_add2_reg),
        .rd_value_reg (IFID_EX_rd_value_reg),
        .funct3_next (EXU_funct3),
        .csr_wen_next (EXU_csr_wen),
        .R_wen_next (EXU_R_wen),
        .mem_wen_next (EXU_mem_wen),
        .mem_ren_next (EXU_mem_ren),
        .rd_next (EXU_rd),
        .pc_next (EXU_pc),
        .jump_flag_next (EXU_jump_flag),
        .rs2_value_next (EXU_rs2_value),
        .rd_value_next (EXU_rd_value),
        .Ex_result (EXU_Ex_result),
        .fetch_i_flag_next(EXU_fence_i_flag),
        .branch_flag_next (EXU_branch_flag),
        .branch_pc_next (EXU_branch_pc)
    );

    //-------------------------------------------------------------------------
    // 9.6 EX_LSWB_Reg：EX → MEM 流水寄存器
    //-------------------------------------------------------------------------
    EX_LSWB_Reg EX_LSWB_Reg_inst0 (
        .clock (cpu_clk),
        .reset (cpu_rst),
        .valid_last (IFID_EX_valid),
        .ready_last (1'b1),
        .ready_next (WBU_ready),
        .valid_next (EX_LSWB_valid),
        .mem_ren (EXU_mem_ren),
        .mem_wen (EXU_mem_wen),
        .R_wen (EXU_R_wen),
        .csr_wen (EXU_csr_wen),
        .Ex_result (EXU_Ex_result),
        .rd (EXU_rd),
        .funct3 (EXU_funct3),
        .rs2_value (EXU_rs2_value),
        .jump_flag (EXU_jump_flag),
        .rd_value (EXU_rd_value),
        .pc (EXU_pc),
        .mem_ren_reg (EX_LSWB_mem_ren_reg),
        .mem_wen_reg (EX_LSWB_mem_wen_reg),
        .R_wen_reg (EX_LSWB_R_wen_reg),
        .csr_wen_reg (EX_LSWB_csr_wen_reg),
        .Ex_result_reg(EX_LSWB_Ex_result_reg),
        .rd_reg (EX_LSWB_rd_reg),
        .funct3_reg (EX_LSWB_funct3_reg),
        .rs2_value_reg(EX_LSWB_rs2_value_reg),
        .jump_flag_reg(EX_LSWB_jump_flag_reg),
        .rd_value_reg (EX_LSWB_rd_value_reg),
        .pc_reg (EX_LSWB_pc_reg)
    );

    //-------------------------------------------------------------------------
    // 9.7 LSU：访存。addr/wen/wdata/mask/rdata 直接接到外设端口（perip_*）
    //     load 的读回数据按 funct3 做符号/零扩展后给 WBU 用
    //-------------------------------------------------------------------------
    LSU LSU_Inst0 (
        .mem_ren_reg (EX_LSWB_mem_ren_reg),
        .mem_wen_reg (EX_LSWB_mem_wen_reg),
        .R_wen_reg (EX_LSWB_R_wen_reg),
        .csr_wen_reg (EX_LSWB_csr_wen_reg),
        .Ex_result_reg (EX_LSWB_Ex_result_reg),
        .rd_reg (EX_LSWB_rd_reg),
        .funct3_reg (EX_LSWB_funct3_reg),
        .rs2_value_reg (EX_LSWB_rs2_value_reg),
        .jump_flag_reg (EX_LSWB_jump_flag_reg),
        .rd_value_reg (EX_LSWB_rd_value_reg),
        .pc_reg (EX_LSWB_pc_reg),
        .rd_value_next (LSU_rd_value),
        .R_wen_next (LSU_R_wen),
        .LSU_Rdata (LSU_Rdata),
        .csr_wen_next (LSU_csr_wen),
        .Ex_result_next (LSU_Ex_result),
        .rd_next (LSU_rd),
        .mem_ren_next (LSU_mem_ren),
        .jump_flag_next (LSU_jump_flag),
        .pc_next (LSU_pc),
        .addr (perip_addr),                    // 地址 → 外设
        .wen (perip_wen),                      // 写使能 → 外设
        .wdata (perip_wdata),                  // 写数据 → 外设
        .mask (perip_mask),                    // 字节掩码 → 外设
        .rdata (perip_rdata)                   // 读回数据 ← 外设
    );

    //-------------------------------------------------------------------------
    // 9.8 WBU：写回。三选一（跳转/CSR → pc+4，load → 读数据，其它 → ALU 结果）
    //     R_wen_next 还要和 valid 与一下，防止被冲刷的假指令写寄存器
    //-------------------------------------------------------------------------
    WBU WBU_inst0 (
        .clock (cpu_clk),
        .reset (cpu_rst),
        .MEM_Rdata (LSU_Rdata),
        .Ex_result (LSU_Ex_result),
        .rd_value (LSU_rd_value),
        .rd (LSU_rd),
        .csr_wen (LSU_csr_wen),
        .R_wen (LSU_R_wen),
        .mem_ren (LSU_mem_ren),
        .jump_flag (LSU_jump_flag),
        .pc (LSU_pc),
        .R_wen_next (WBU_R_wen),
        .csr_wen_next (WBU_csr_wen),
        .csrd (WBU_csrd),
        .rd_value_next(WBU_rd_value),
        .pc_out (WBU_pc),
        .valid (EX_LSWB_valid),
        .ready (WBU_ready),
        .rd_next (WBU_rd),
        .valid_next (WBU_valid)
    );

    //-------------------------------------------------------------------------
    // 9.9 ★读地址旁路：这是修 bug 的关键一行
    //
    //   问题：DRAM 读口是"1 拍寄存"（`spo <= mem[a]`），而 WBU 在同一个沿采样，
    //        导致 load 拿到的是**上一个地址**的数据 → 地址一跳变就读回垃圾。
    //   修法：让 BRAM 的**读地址**由 EX 级组合结果（EXU_Ex_result）直接驱动，
    //        这样在 EX→MEM 这个时钟沿，BRAM 锁进来的就是真正的 load 地址。
    //        写地址仍然用 MEM 级的 perip_addr（写不受影响）。
    //   注意 `===` 和默认安全地址：非访存周期 EXU_Ex_result 可能是 X，
    //        用 `===` 判断 + 给一个固定安全地址，避免 X 传进 BRAM 地址导致整条流水线变 X。
    //-------------------------------------------------------------------------
    assign perip_rd_addr = (EXU_mem_ren === 1'b1) ? EXU_Ex_result : 32'h8010_0000;

endmodule
