`timescale 1ns/1ps

//=============================================================================
// Data_hazard：数据冒险（旁路）选择器 —— 纯组合，只吐 2 位控制码
//=============================================================================
// 【一句话职责】
//   判断"我在 ID 级要用的 rs1/rs2"能不能从流水线更靠后的级直接抄过来，
//   并给出四选一控制码，交给 Control 去做真正的多路选择。
//
// 【控制码含义】（和 cpu_Control.sv 里的 case 一一对应）
//   2'b00 → 用寄存器堆读出的原值
//   2'b01 → 用 EX 级 ALU 结果（上一条指令刚算出来的）
//   2'b10 → 用 MEM 级结果（上上条指令的结果）
//   2'b11 → 用 MEM 级 load 读回的数据
//
// 【为什么要 `!= 5'b0`】
//   x0 恒为 0，任何写 x0 的指令都是空操作；如果不排除，会出现
//   "把某条指令的 rd=0 当成真依赖"而错误旁路，甚至覆盖 x0 的 0 值。
//
// 【为什么 EXU 优先于 MEM】
//   EX 级是"最近"的指令，它的结果最新；
//   如果 EX 和 MEM 同时命中同一个寄存器，必须用 EX 的（MEM 那条更旧）。
//
// 【为什么 load 要特殊处理】
//   load 的数据不在 Ex_result 里，而在存储器读口出来的 MEM_Rdata 里，
//   所以 MEM 级命中且这条是 load（MEM_mem_ren=1）时，选择码要给 2'b11。
//   注意：load 后面紧跟使用它的指令这种情况（load-use）光靠旁路救不了，
//   必须由 Control 的 stall_condition 停一拍（见 cpu_Control.sv）。
//=============================================================================

module Data_hazard(
    input [4:0] IDU_rs1,                  // 本条指令的 rs1 号
    input [4:0] IDU_rs2,                  // 本条指令的 rs2 号
    input [4:0] EXU_rd,                   // EX 级指令的目的寄存器
    input [4:0] MEM_rd,                   // MEM 级指令的目的寄存器
    input IDU_valid,                      // 以下三个 valid 本实现里没用到，
    input EXU_valid,                      // 保留是为了以后加"作废指令不参与旁路"用
    input MEM_valid,
    input MEM_mem_ren,                    // MEM 级这条是 load（要取读数据而不是 ALU 结果）
    input EXU_R_Wen,                      // EX 级真的会写寄存器堆
    input MEM_R_Wen,                      // MEM 级真的会写寄存器堆
    output [1:0] IDU_rs1_choice,          // rs1 的四选一控制码
    output [1:0] IDU_rs2_choice           // rs2 的四选一控制码
);
    // 第一步：只比"寄存器号是否相同"（还没管这一级是不是真的要写）
    logic exu_rs1_match, exu_rs2_match;
    logic mem_rs1_match, mem_rs2_match;
    // 第二步：再与上"这一级确实要写寄存器堆 (R_Wen)"
    logic exu_rs1_valid, exu_rs2_valid;
    logic mem_rs1_valid, mem_rs2_valid;

    // 寄存器号相同，且不是 x0
    assign exu_rs1_match = (EXU_rd == IDU_rs1) && (EXU_rd != 5'b0);
    assign exu_rs2_match = (EXU_rd == IDU_rs2) && (EXU_rd != 5'b0);
    assign mem_rs1_match = (MEM_rd == IDU_rs1) && (MEM_rd != 5'b0);
    assign mem_rs2_match = (MEM_rd == IDU_rs2) && (MEM_rd != 5'b0);

    // 命中 + 该级真的要写 → 才允许旁路
    assign exu_rs1_valid = EXU_R_Wen && exu_rs1_match;
    assign exu_rs2_valid = EXU_R_Wen && exu_rs2_match;
    assign mem_rs1_valid = MEM_R_Wen && mem_rs1_match;
    assign mem_rs2_valid = MEM_R_Wen && mem_rs2_match;

    // 最终优先级：EX 级 > MEM 级(load 用 11 / 普通结果用 10) > 寄存器堆原值(00)
    assign IDU_rs1_choice = exu_rs1_valid ? 2'b01 : (mem_rs1_valid ? (MEM_mem_ren ? 2'b11 : 2'b10) : 2'b00);
    assign IDU_rs2_choice = exu_rs2_valid ? 2'b01 : (mem_rs2_valid ? (MEM_mem_ren ? 2'b11 : 2'b10) : 2'b00);
endmodule
