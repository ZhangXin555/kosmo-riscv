`timescale 1ns/1ps

//=============================================================================
// 模块名 ：IDU（Instruction Decode Unit，译码单元）
// 流水级 ：第 2 级 —— ID（译码 + 读寄存器 + 算分支目标）
// 干什么 ：拿到 IF 送来的 32 位指令，做四件事：
//   1) 拆字段：opcode[6:0] / rs1[19:15] / rs2[24:20] / funct3[14:12] / rd[11:7]
//   2) 拼立即数：I/U/S/B/J 五种格式，按 opcode 选一个
//   3) 生成控制信号：写回使能 R_wen、访存 mem_wen/mem_ren、分支 branch_flag、
//      跳转 jump_flag、ALU 操作码 alu_opcode、CSR 写使能 csr_wen_next
//   4) 读通用寄存器（例化 Reg_Stack），顺便算出分支目标 pc+imm、跳转返回地址 snpc
// 关键点 ：
//   * 本模块全是组合逻辑（assign），只有末尾的 Reg_Stack 里有触发器；
//   * ALU 的两个操作数 add1_value/add2_value 在这里就选好，EX 级只管算；
//   * `imm` 与 `csr_wen_next` 互相引用（csr_wen_next 用 imm，imm 又由 opcode 选），
//     Verilog 的 assign 是并行求值，先后顺序无所谓；
//   * 例外：csr_wen_next 判断时 imm 还没“定义完”，但组合逻辑会自动收敛。
//=============================================================================
/*interface define*/

// ---- RISC-V opcode（inst[6:0]）----
`define R_opcode  7'b0110011                 // R 型：add/sub/sll/slt/sltu/xor/srl/sra/or/and
`define lw 7'b0000011                        // I 型 load：lw
`define addi 7'b0010011                      // I 型算术：addi 及各变体
`define jarl 7'b1100111                      // I 型 jalr（原文拼写 jarl）
`define S_opcode  7'b0100011                 // S 型 store
`define B_opcode  7'b1100011                 // B 型 条件分支
`define lui 7'b0110111                       // U 型 lui
`define auipc 7'b0010111                     // U 型 auipc
`define jal  7'b1101111                      // J 型 jal
`define M_opcode  7'b1110011                 // 系统指令：ecall/mret/csr 读写

// ---- ALU 操作码（与 cpu_ALU.sv 的 case 一一对应）----
`define alu_add                   4'b0000    // 加（也用于地址计算/访存地址）
`define alu_sub                   4'b0001    // 减
`define alu_or                    4'b0010    // 或
`define alu_and                   4'b0011    // 与
`define alu_xor                   4'b0100    // 异或
`define alu_signed_comparator     4'b0101    // 有符号小于（slt / blt / bge）
`define alu_unsigned_comparator   4'b0110    // 无符号小于（sltu / bltu / bgeu）
`define alu_equal                 4'b0111    // 相等（beq / bne）
`define alu_sll                   4'b1000    // 逻辑左移
`define alu_srl                   4'b1001    // 逻辑右移
`define alu_sra                   4'b1010    // 算术右移

`define Performance_Count                   // 性能统计开关

//=============================================================================
// 端口分组说明（读代码时先看这一块，再看下面的 assign）
//   【指令入口】inst[31:0] 当前指令；snpc = pc+4；pc 当前地址
//   【寄存器堆】rd_value = 上一条写回的值；rd/R_wen 写回端口；csrd/csr_wen CSR 读口
//   【EXU 前递】EXU_rs1_in / EXU_rs2_in —— 经过冒险单元选择后的真实操作数
//                （可能是寄存器值，也可能是 EX/MEM 前递过来的新值）
//   【给 ID→EX 流水寄存器】rd_next/funct3/alu_opcode/add1_value/add2_value/
//                branch_pc/mem_wen/mem_ren/inv_flag/branch_flag/jump_flag/
//                R_wen_next/csr_wen_next/rd_value_next/pc_out
//   【给控制/异常】ecall_flag/mret_flag/fence_i_flag/exc_cause
//   【给冒险单元】rs1/rs2（源寄存器号）、A0 值 a0_value（调试用）
//   【握手】valid_last/ready_last、valid_next/ready_next（本设计恒通）
//=============================================================================
module IDU(
    input clock,                             // 时钟
    input reset,                             // 复位

    input [31:0] inst,                       // 当前指令
    input [31:0] snpc,                       // pc + 4（jal/jalr 的返回地址）
    input [31:0] pc,                         // 当前指令地址

    input [31:0] rd_value,                   // 写回值（来自 WB 级）
    input [31:0] csrd,                       // CSR 读出的值
    input [4:0] rd,                          // 写回目标寄存器号
    input R_wen,                             // 写回使能（来自后续级）
    input [3:0] csr_wen,                     // CSR 写使能（来自后续级）

    input [31:0] EXU_rs1_in,                 // 实际 rs1 操作数（含前递）
    input [31:0] EXU_rs2_in,                 // 实际 rs2 操作数（含前递）

    output [4:0] rd_next,                    // 本指令的 rd（送下一级）
    output [2:0] funct3,                     // funct3 字段（ALU 细分用）
    output mret_flag,                        // 是 mret 指令
    output ecall_flag,                       // 是 ecall 指令
    input  [1:0] exc_cause,                  // 异常原因（来自 Control）
    output fence_i_flag,                     // 是 fence.i 指令（清流水，本设计只做气泡）

    output [31:0] branch_pc,                 // 分支目标地址 = pc + imm
    output [31:0] rs1_value,                 // rs1 寄存器值（Reg_Stack 输出）
    output [31:0] rs2_value,                 // rs2 寄存器值

    output [31:0] add1_value,                // ALU 操作数 A（已选好）
    output [31:0] add2_value,                // ALU 操作数 B（已选好）
    output [3:0] csr_wen_next,               // CSR 写使能（4bit：mepc/mcause/mstatus/mtvec）
    output R_wen_next,                       // 本指令是否写通用寄存器
    output [31:0] rd_value_next,             // 预先算好的写回值（jal/jalr 的返回地址等）

    output mem_wen,                          // 写存储器（store）
    output mem_ren,                          // 读存储器（load）
    output inv_flag,                         // 分支需要取反（beq/bge/bgeu → 用 bne/blt/bltu 判）
    output branch_flag,                      // 是条件分支
    output jump_flag,                        // 是跳转（jal/jalr）

    output [3:0] alu_opcode,                 // ALU 操作码

    output [4:0] rs1,                        // 源寄存器 1 号
    output [4:0] rs2,                        // 源寄存器 2 号
    output [31:0] a0_value,                  // a0(x10) 的值（调试/打印用）
    output [31:0] mepc_out,                  // mepc 寄存器值（异常返回地址）
    output [31:0] mtvec_out,                 // mtvec 寄存器值（异常入口）
    output [31:0] pc_out,                    // 本级 PC（保存进流水寄存器）

    input valid_last,                        // 上一级有效
    output ready_last,                       // 告诉上一级我准备好了
    input ready_next,                        // 下一级准备好了
    output valid_next                        // 告诉下一级数据有效
);

    logic [31:0] csr_addr;                   // CSR 地址（= imm）
    logic [6:0] oprand;                      // inst[31:25]：R 型用来区分 sra/srl、add/sub
    logic [6:0] opcode;                      // inst[6:0]：主操作码

    // 五种立即数格式 + CSR 读值 + 选中后的 imm
    logic [31:0] imm_I;                      // I 型：12 位符号扩展
    logic [31:0] imm_U;                      // U 型：20 位左移 12
    logic [31:0] imm_R;                      // R 型：无立即数（只为对称保留）
    logic [31:0] imm_S;                      // S 型：store 的偏移
    logic [31:0] imm_B;                      // B 型：分支偏移（已左移 1）
    logic [31:0] imm_J;                      // J 型：jal 偏移（已左移 1）
    logic [31:0] csrs;                       // CSR 读出的数据
    logic [31:0] imm;                        // 最终选中的立即数

    assign ready_last = ready_next;          // 握手直通（本设计无背压）
    assign valid_next = valid_last;          // 握手直通

    //-------------------------------------------------------------------------
    // 字段切分：RISC-V 的字段位置是固定的，直接从 inst 里取
    //-------------------------------------------------------------------------
    assign oprand = inst[31:25];             // funct7
    assign opcode = inst[6:0];               // 主操作码
    assign rs1 = inst[19:15];                // 源寄存器 1
    assign rs2 = inst[24:20];                // 源寄存器 2
    assign funct3 = inst[14:12];             // 功能码 3 位
    assign rd_next = inst[11:7];             // 目的寄存器

    //-------------------------------------------------------------------------
    // 三条"整条指令编码固定"的特殊指令：直接和 32 位常数比较
    //-------------------------------------------------------------------------
    assign ecall_flag = (inst == 32'b00000000000000000000000001110011);              // ecall
    assign mret_flag = (inst == 32'b00110000001000000000000001110011);               // mret
    assign fence_i_flag = (inst == 32'b00000000000000000001000000001111);            // fence.i

    //-------------------------------------------------------------------------
    // CSR 写使能：4 位分别对应 4 个 CSR
    //   [0]=mepc(0x341) [1]=mcause(0x342) [2]=mstatus(0x300) [3]=mtvec(0x305)
    //   只有 opcode 是系统指令、且立即数等于这个 CSR 地址时，才允许写
    //-------------------------------------------------------------------------
    assign csr_wen_next[0] = (opcode == `M_opcode && imm == 32'h341);   // mepc
    assign csr_wen_next[1] = (opcode == `M_opcode && imm == 32'h342);   // mcause
    assign csr_wen_next[2] = (opcode == `M_opcode && imm == 32'h300);   // mstatus
    assign csr_wen_next[3] = (opcode == `M_opcode && imm == 32'h305);   // mtvec

    //-------------------------------------------------------------------------
    // 写回 / 访存 / 跳转 / 分支 控制
    //-------------------------------------------------------------------------
    // store、branch 不写寄存器；opcode==0 是空指令（NOP 被当成 0），也不写
    assign R_wen_next = (opcode == `S_opcode || opcode == `B_opcode || opcode == 0)? 1'b0:1'b1;
    assign mem_wen = (opcode == `S_opcode);            // store 才写存储器
    assign mem_ren = (opcode == `lw);                  // lw 才读存储器

    assign jump_flag = (opcode == `jarl || opcode == `jal)? 1'b1:1'b0;   // jalr / jal

    // 分支取反：beq(000)/bge(101)/bgeu(111) 用"反向比较"来实现，省一条减法
    assign inv_flag = (opcode == `B_opcode && (funct3 == 3'b101 || funct3 == 3'b111 || funct3 == 3'b000 ))? 1'b1:1'b0;
    assign branch_flag = (opcode == `B_opcode)? 1'b1:1'b0;               // 条件分支整体标志

    //-------------------------------------------------------------------------
    // 写回值预计算：跳转指令写 PC+4；CSR 指令写 CSR 旧值；其它指令写 0（真正结果由 EX 给）
    //-------------------------------------------------------------------------
    assign csr_addr = imm;                     // CSR 地址就藏在 imm 里（I 型编码）
    assign rd_value_next = jump_flag? snpc:    // jal/jalr：返回地址 = pc+4
        (|csr_wen_next)? csrs:                 // csr 指令：写回 CSR 读值（| 表示非零）
        0;                                     // 其它：占位 0
    assign branch_pc = pc + imm;               // 分支目标 = 当前 PC + 偏移（ID 级就算好）
    assign pc_out = pc;                        // 本级 PC 存进流水寄存器，后面算 auipc/jalr

    //-------------------------------------------------------------------------
    // ALU 两个操作数：在 ID 级就选好，EX 级直接送加法器
    //-------------------------------------------------------------------------
    // 操作数 A：lui 用 0；jal/auipc 用 PC；其余用 rs1
    assign add1_value = (opcode == `lui)? 0 :
        (opcode == `jal || opcode == `auipc )? pc :
        EXU_rs1_in;
    // 操作数 B：R/B 型用 rs2；csrrs/csrrc 用 rd_value_next；csrrwi 用 0；其余用立即数
    assign add2_value = (opcode == `R_opcode || opcode == `B_opcode)? EXU_rs2_in :
        (opcode == `M_opcode && funct3 == 3'b010)? rd_value_next :
        (opcode == `M_opcode && funct3 == 3'b001)? 0 : imm;

    //-------------------------------------------------------------------------
    // ALU 操作码译码：一串三目运算（等价于优先级 case）
    // 读法：A ? 结果 : B ? 结果 : ... : 最后默认值
    // 1) 地址类/加法类 → alu_add
    // 2) slt/blt/bge   → alu_signed_comparator
    // 3) sltu/bltu/bgeu→ alu_unsigned_comparator
    // 4) xor / or / and / sll / srl / sra / sub
    //-------------------------------------------------------------------------
    assign alu_opcode = (opcode == `S_opcode || opcode == `lw
        || opcode == `lui || opcode == `auipc
        || opcode == `jal || opcode == `jarl
        || (opcode ==`addi && funct3 == 3'b000) || (opcode == `R_opcode &&
        funct3 == 3'b000 && oprand[5] == 1'b0) || (opcode == `B_opcode &&
        funct3[2:1] == 2'b01))?
        `alu_add : (opcode == `addi && funct3 == 3'b010) ||                   // slti
        (opcode == `R_opcode && funct3 == 3'b010) ||                          // slt
        (opcode == `B_opcode && (funct3 == 3'b101 || funct3 == 3'b100))?      // bge/blt
        `alu_signed_comparator:
        (opcode == `B_opcode && (funct3 == 3'b110 || funct3 == 3'b111)) ||    // bltu/bgeu
        (opcode == `addi && (funct3 == 3'b011)) ||                            // sltiu
        (opcode == `R_opcode && (funct3 == 3'b011))?                          // sltu
        `alu_unsigned_comparator:
        (opcode == `addi && funct3 == 3'b100 ) ||                             // xori
        (opcode == `R_opcode && funct3 == 3'b100 )?                           // xor
        `alu_xor : (opcode == `addi && funct3 == 3'b110 ) ||                  // ori
        (opcode == `R_opcode && funct3 == 3'b110 ) ||                         // or
        (opcode == `M_opcode && funct3 == 3'b010 )?                           // csrrs
        `alu_or : (opcode == `addi && funct3 == 3'b111 ) ||                   // andi
        (opcode == `R_opcode && funct3 == 3'b111 )?                           // and
        `alu_and : (opcode == `addi && funct3 == 3'b001 ) ||                  // slli
        (opcode == `R_opcode && funct3 == 3'b001 )?                           // sll
        `alu_sll : (opcode == `addi && funct3 == 3'b101 && oprand[5] == 1'b0) ||   // srli
        (opcode == `R_opcode && funct3 == 3'b101 && oprand[5] == 1'b0)?            // srl
        `alu_srl : (opcode == `addi && funct3 == 3'b101 && oprand[5] == 1'b1) ||   // srai
        (opcode == `R_opcode && funct3 == 3'b101 && oprand[5] == 1'b1)?            // sra
        `alu_sra : (opcode == `R_opcode && funct3 == 3'b000 && oprand[5] == 1'b1)? // sub
        `alu_sub : (opcode == `B_opcode && funct3[2:1] == 2'b00)?                  // beq/bne
        `alu_equal:`alu_add;                                                       // 默认加法
    // 注意：beq/bne 用 alu_equal 算出"相等"，再配合 inv_flag 决定是否取反

    //-------------------------------------------------------------------------
    // 立即数拼接（逐位对照 RISC-V 手册的编码图）
    //-------------------------------------------------------------------------
    assign imm_I = {{20{inst[31]}},inst[31:20]};                       // I：signExt(inst[31:20])
    assign imm_U = {inst[31:12],12'd0};                                // U：inst[31:12]<<12
    assign imm_R = {25'd0,inst[31:25]};                                // R：无立即数，仅占位
    assign imm_S = {{20{inst[31]}},inst[31:25],inst[11:7]};            // S：signExt(imm[11:5],imm[4:0])
    assign imm_B = {imm_S[31:11],imm_S[0],imm_S[10:1]}<<1;             // B：位重排后左移 1（偶数偏移）
    assign imm_J = {{11{inst[31]}},inst[31],inst[19:12],inst[20],inst[30:21]}<<1;  // J：位重排后左移 1
/* verilator lint_off IMPLICIT */

    // 按 opcode 选立即数
    assign imm = (opcode == `lw || opcode == `addi || opcode == `jarl || opcode == `M_opcode)? imm_I:
        (opcode == `lui || opcode == `auipc)? imm_U:
        (opcode == `jal)? imm_J:
        (opcode == `B_opcode)? imm_B:
        (opcode == `S_opcode)? imm_S:
        (opcode == `S_opcode)? imm_R :        // ← 原文笔误：这里再写 S_opcode，imm_R 永远选不中
        0;                                    //   R 型本来不用立即数，所以无害，保留原样
    // 读法提醒：立即数靠"opcode 决定格式"，不改 opcode、改 funct3 都还在同一格式里。

    //-------------------------------------------------------------------------
    // 例化寄存器栈：读 rs1/rs2 的值，并维护 mepc/mtvec/mcause 等 CSR
    // （真正的寄存器堆在 cpu_RegisterFile.sv 里，这里是把"读口 + CSR + 调试口"打包）
    //-------------------------------------------------------------------------
Reg_Stack Reg_Stack_inst0(
    .reset(reset),                            // 复位
    .clock(clock),                            // 时钟
    .pc(pc),                                  // 当前 PC（ecall 时存进 mepc）
    .ecall_flag(ecall_flag),                  // ecall 触发
    .exc_cause(exc_cause),                    // 异常原因（写 mcause）
    .rs1(rs1),                                // 读口 1 地址
    .rs2(rs2),                                // 读口 2 地址
    .rd(rd),                                  // 写口地址
    .rd_value(rd_value),                      // 写口数据

    .csr_addr(csr_addr),                      // CSR 地址
    .R_wen(R_wen),                            // 通用寄存器写使能
    .csr_wen(csr_wen),                        // CSR 写使能
    .csrd(csrd),                              // CSR 读数据

    .rs1_value(rs1_value),                    // 输出 rs1 值
    .rs2_value(rs2_value),                    // 输出 rs2 值
    .a0_value(a0_value),                      // 输出 a0（x10）值，调试用
    .csrs(csrs),                              // 输出 CSR 值
    .mepc_out(mepc_out),                      // 输出 mepc
    .mtvec_out(mtvec_out)                     // 输出 mtvec
);

endmodule
