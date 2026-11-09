`timescale 1ns/1ps

//=============================================================================
// Control：流水线控制单元（旁路/停顿/跳转/异常 的总决策器）
//=============================================================================
// 【它在流水线里的位置】
//   它是**纯组合逻辑**（没有时序），随时看"当前各级里是什么指令"，
//   然后当拍决定三件事：
//     1) 下一条 PC 去哪     → dnpc / dnpc_flag
//     2) 这一拍谁要作废     → EXU_inst_clear（冲刷 EX 级）、icache_clr
//     3) 操作数从哪来       → EXU_rs1_in / EXU_rs2_in（数据旁路）
//   另外还负责 load-use 冒险的一拍停顿 → IFU_stall
//
// 【为什么要有旁路（forwarding）】
//   `addi x1, x0, 5` 刚在 EX 级算出 x1=5，下一条 `add x2, x1, x1` 在 ID 级读寄存器堆时，
//   前一条还没写回（要等 WB 级），读出来的是旧值。
//   做法：不真等，而是从"正在飞的指令"里把结果抄过来 —— 这就是旁路。
//   优先级：EX 级结果（最近）> MEM 级结果 > MEM 级 load 数据 > 寄存器堆原值（最旧）。
//
// 【load-use 冒险为什么必须停一拍】
//   load 的数据要到 MEM 级末尾才从存储器出来，EX 级拿不到。
//   所以当"上一条是 load 且目标是本条要用的寄存器"时，只能让 IF 停一拍、
//   把 EX 级作废，等 load 的数据在 MEM 级出现后再旁路。
//=============================================================================

module Control(

    input clock,                          // 时钟（本模块没用到，保留端口便于替换成时序版本）
    input reset,                          // 复位（同上，没用到）

    input [31:0] mtvec_out,               // 异常入口地址（CSR mtvec）
    input [31:0] mepc_out,                // 异常返回地址（CSR mepc）

    input [31:0] branch_pc,               // EX 级算好的分支目标（pc+imm）
    input [31:0] Ex_result,               // EX 级 ALU 结果

    input [31:0] MEM_Ex_result,           // MEM 级的结果（= WB 写回值，旁路源）
    input [31:0] MEM_Rdata,               // MEM 级 load 读回的数据（旁路源）

    input [31:0] IDU_rs1_value,           // ID 级从寄存器堆读出的 rs1 原值
    input [31:0] IDU_rs2_value,           // ID 级从寄存器堆读出的 rs2 原值
    input branch_flag,                    // EX 级：这是一条分支指令
    input jump_flag,                      // EX 级：这是一条跳转指令（jal/jalr）
    input mret_flag,                      // ID 级：mret
    input ecall_flag,                     // ID 级：ecall

    input MEM_mem_ren,                    // MEM 级：这是一条 load
    input fence_i_flag,                   // EX 级：fence.i（清指令缓存）

    input [4:0] IDU_rs1,                  // ID 级：本条指令的 rs1 号
    input [4:0] IDU_rs2,                  // ID 级：本条指令的 rs2 号

    input IDU_valid,                      // ID 级有真指令
    input EXU_valid,                      // EX 级有真指令
    input MEM_valid,                      // MEM 级有真指令
    input ifault,                         // IF 级：取指地址越界（异常）

    input [4:0] EXU_rd,                   // EX 级：目的寄存器号
    input [4:0] MEM_rd,                   // MEM 级：目的寄存器号

    input EXU_mem_ren,                    // EX 级：这是一条 load（下一拍就要用它的数据）
    input EXU_R_Wen,                      // EX 级：要写寄存器堆
    input MEM_R_Wen,                      // MEM 级：要写寄存器堆
    output IFU_stall,                     // ★让 IF 级停一拍

    output [31:0] EXU_rs1_in,             // ★旁路后真正送进 ALU 的 rs1
    output [31:0] EXU_rs2_in,             // ★旁路后真正送进 ALU 的 rs2

    output icache_clr,                    // 清取指缓存
    output EXU_inst_clear,                // ★冲刷 EX 级（把这条指令作废）
    output [31:0] dnpc,                   // ★下一条 PC
    output dnpc_flag,                     // ★要不要改 PC
    output [1:0] exc_cause                // 异常原因（给 CSR 用）
);
    logic [1:0] IDU_rs1_choice;           // rs1 的四选一控制码（由 Data_hazard 给出）
    logic [1:0] IDU_rs2_choice;           // rs2 的四选一控制码

    // 预计算控制信号以减少关键路径
    logic branch_taken;                   // 分支真的成立（要跳）
    logic exception_or_jump;              // 无条件改变 PC 的事件
    logic stall_condition;                // 需要停一拍
    logic exc_misalign;                   // 目标地址不对齐
    logic exc_trap;                        // 发生异常（要跳异常入口）
    logic rs1_hazard, rs2_hazard;         // rs1/rs2 撞上了上一条 load 的目标

    //-------------------------------------------------------------------------
    // 第一级：基本条件计算（都是组合，当拍出结果）
    //-------------------------------------------------------------------------
    // 分支是否成立：ALU 把"比较结果"塞在 bit0 上（beq 时 inv_flag 取反后 1=相等）
    assign branch_taken = branch_flag & Ex_result[0];

    // 这些指令一定会改 PC：jal/jalr、fence.i、mret、ecall
    assign exception_or_jump = jump_flag | fence_i_flag | mret_flag | ecall_flag;

    // 取指地址不对齐（IALIGN=32）：跳转/分支目标 bit[1] 非 0 即触发 mcause=0
    //   注：mret/ecall 不走这条判断（它们的目标是 CSR 里的地址）
    assign exc_misalign = ~mret_flag & ~ecall_flag &
                          ((jump_flag & Ex_result[1]) | (branch_taken & branch_pc[1]));

    // 只要"地址不对齐"或"取指越界"就进异常
    assign exc_trap = exc_misalign | ifault;

    // 异常原因编码：2'b10=取指越界，2'b01=地址不对齐，2'b00=正常
    assign exc_cause = ifault ? 2'b10 : (exc_misalign ? 2'b01 : 2'b00);

    // ---- load-use 冒险检测 ----
    // x0 永远是 0，写 x0 不算数，所以 `EXU_rd != 5'b0` 必须判
    assign rs1_hazard = (EXU_rd == IDU_rs1) && (EXU_rd != 5'b0);
    assign rs2_hazard = (EXU_rd == IDU_rs2) && (EXU_rd != 5'b0);

    // 上一条(EX 级)是 load，且它要写的寄存器正是本条要读的 → 停一拍
    assign stall_condition = EXU_mem_ren && (rs1_hazard || rs2_hazard);

    //-------------------------------------------------------------------------
    // 第二级：输出信号
    //-------------------------------------------------------------------------
    // 要改 PC：分支成立 / 无条件跳转 / 异常
    assign dnpc_flag = branch_taken | exception_or_jump | exc_trap;

    // 要冲刷 EX 级：上面那些"改 PC"的情况都会让紧跟其后的指令作废；
    // load-use 停顿也要作废（停的这一拍 EX 级里是条假指令）
    assign EXU_inst_clear = branch_taken | exception_or_jump | stall_condition | exc_trap;

    // 让 IF 级停一拍（PC 保持、不发新指令）
    assign IFU_stall = stall_condition;

    // fence.i：清指令缓存（本工程的 IROM 是组合读，实际只用来同步流水线）
    assign icache_clr = fence_i_flag & EXU_valid;

    //-------------------------------------------------------------------------
    // 第三级：dnpc 选择（跳到哪里）—— 优先级从上到下
    //-------------------------------------------------------------------------
    logic [31:0] dnpc_reg;
    always @(*) begin
        if (exc_trap)                     // ① 异常最优先 → 去 mtvec
            dnpc_reg = mtvec_out;
        else if (jump_flag)               // ② jal/jalr → 用 ALU 算出的目标
            dnpc_reg = Ex_result;
        else if (branch_flag)             // ③ 分支 → 用 ID 级算好的 pc+imm
            dnpc_reg = branch_pc;
        else if (mret_flag)               // ④ mret → 回 mepc
            dnpc_reg = mepc_out;
        else                              // ⑤ 其它（理论上不会走到，因为 dnpc_flag=0）
            dnpc_reg = mtvec_out;
    end
    assign dnpc = dnpc_reg;

    //-------------------------------------------------------------------------
    // 第三级（并行）：数据旁路四选一
    //   choice 由 Data_hazard 模块根据"寄存器号是否相同 + 该级是否真的写"算出：
    //     2'b00 → 用寄存器堆读出来的原值（最新鲜的旧值）
    //     2'b01 → 用 EX 级 ALU 结果（上一条刚算出来）
    //     2'b10 → 用 MEM 级结果（上上条的结果，已经在流水寄存器里）
    //     2'b11 → 用 MEM 级 load 读回的数据
    //-------------------------------------------------------------------------
    logic [31:0] rs1_mux_reg, rs2_mux_reg;
    always @(*) begin
        case (IDU_rs1_choice)
            2'b01: rs1_mux_reg = Ex_result;        // 来自 EX 级
            2'b10: rs1_mux_reg = MEM_Ex_result;    // 来自 MEM 级
            2'b11: rs1_mux_reg = MEM_Rdata;        // 来自 load
            default: rs1_mux_reg = IDU_rs1_value;  // 寄存器堆原值
        endcase
    end
    always @(*) begin
        case (IDU_rs2_choice)
            2'b01: rs2_mux_reg = Ex_result;
            2'b10: rs2_mux_reg = MEM_Ex_result;
            2'b11: rs2_mux_reg = MEM_Rdata;
            default: rs2_mux_reg = IDU_rs2_value;
        endcase
    end
    assign EXU_rs1_in = rs1_mux_reg;
    assign EXU_rs2_in = rs2_mux_reg;

    //-------------------------------------------------------------------------
    // 旁路控制码生成：单独放在 Data_hazard 模块里（见 cpu_Data_hazard.sv）
    //-------------------------------------------------------------------------
    Data_hazard Data_hazard_inst(
        .IDU_rs1(IDU_rs1),
        .IDU_rs2(IDU_rs2),
        .EXU_rd(EXU_rd),
        .MEM_rd(MEM_rd),
        .MEM_valid(MEM_valid),
        .EXU_valid(EXU_valid),
        .IDU_valid(IDU_valid),
        .MEM_mem_ren(MEM_mem_ren),
        .EXU_R_Wen(EXU_R_Wen),
        .MEM_R_Wen(MEM_R_Wen),
        .IDU_rs1_choice(IDU_rs1_choice),
        .IDU_rs2_choice(IDU_rs2_choice)
    );
endmodule
