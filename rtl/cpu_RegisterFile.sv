`timescale 1ns/1ps

//=============================================================================
// RegisterFile：32×32 位寄存器堆（RV32I 的 x0~x31）
//=============================================================================
// 【要点】
//   1) 两个**组合**读口（rs1/rs2）：只要给地址，当拍就出数据，不需要时钟。
//      这是 RISC-V 的便利之处：读不消耗周期。
//   2) 一个**同步**写口（wen + waddr + wdata）：时钟上升沿写入。
//      写口接的是 WB 级（写回），所以"读"永远看到的是已经提交的值。
//   3) x0 必须恒为 0：
//        · 写口：`waddr != 0` 才写（防止被写坏）
//        · 读口：`rs1_addr == 0 ? 0 : ...`（防止有人绕过写口）
//   4) a0（x10）单独引出一根线：测试程序把结果放在 a0 里，
//      仿真/板上的判定模块直接读它就知道程序跑出什么值。
//   5) reset 时把 32 个寄存器全清 0（for 循环，综合会展开成并行复位）。
//=============================================================================

// __opcode__（和其他文件重复定义，方便单文件搬走）
`define R_opcode  7'b0110011
`define lw 7'b0000011                          // lw
`define addi 7'b0010011                        // addi
`define jarl 7'b1100111                        // jalr
`define S_opcode  7'b0100011                   // store
`define B_opcode  7'b1100011                   // 分支
`define lui 7'b0110111                         // lui
`define auipc 7'b0010111                       // auipc
`define jal  7'b1101111                        // jal
`define M_opcode  7'b1110011                   // CSR/ecall/mret

// alu 操作码（本模块用不到，保持与其他文件一致的宏集合，便于整体拷贝）
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

module RegisterFile #(ADDR_WIDTH = 5, DATA_WIDTH = 32) (
    input clock,                               // 时钟
    input [DATA_WIDTH-1:0] wdata,              // 写数据（来自 WB 级）
    input [ADDR_WIDTH-1:0] waddr,              // 写地址（rd）
    input wen,                                 // 写使能（WB 级的 R_wen）
    input reset,                               // 复位（清空全部寄存器）
    input [ADDR_WIDTH-1:0] rs1_addr,           // 读地址 1
    input [ADDR_WIDTH-1:0] rs2_addr,           // 读地址 2
    output [DATA_WIDTH-1:0] rs1_value,         // 读数据 1（组合输出）
    output [DATA_WIDTH-1:0] rs2_value,         // 读数据 2（组合输出）
    output [DATA_WIDTH-1:0] a0_value           // x10 (a0) 的值，测试判定用
);
    // 32 个 32 位寄存器
    logic [DATA_WIDTH-1:0] rf [2**ADDR_WIDTH-1:0];

    //-------------------------------------------------------------------------
    // 同步写口 + 复位
    //   · reset 为高：下一个沿把 32 个寄存器全部清 0
    //   · 否则 wen 且 waddr != 0：写入 wdata
    //   · x0 永远不写（waddr != 0 这个条件就是干这个的）
    //-------------------------------------------------------------------------
    always @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < 2**ADDR_WIDTH; i++) begin
                rf[i] <= 0;
            end
        end else if (wen && waddr != 0) begin  // x0 寄存器始终为 0
            rf[waddr] <= wdata;
        end
    end

    //-------------------------------------------------------------------------
    // 组合读口
    //   读 x0 时直接返回常数 0，不查表 —— 双保险，防止 x0 被写脏
    //-------------------------------------------------------------------------
    assign rs1_value = (rs1_addr == 0) ? 0 : rf[rs1_addr];
    assign rs2_value = (rs2_addr == 0) ? 0 : rf[rs2_addr];

    // a0 = x10：测试程序约定把结果放这里
    assign a0_value = rf[10];
endmodule
