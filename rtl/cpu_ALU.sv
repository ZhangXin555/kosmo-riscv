`timescale 1ns/1ps

//=============================================================================
// 模块名 ：ALU（Arithmetic & Logic Unit，算术逻辑单元）
// 流水级 ：属于 EX 级内部（纯组合逻辑，没有寄存器、不额外占拍）
// 干什么 ：根据 4 位操作码 choice，对 d1、d2 做 11 种运算之一，结果放 result。
// 三个设计要点（也是这个 CPU 能跑到 100 MHz 以上的关键，复刻时照这个思路写）：
//   1) 所有运算**并行预计算**（与/或/异或/左移/右移/算术右移/两种比较/不相等），
//      最后只做一层 case 选择。关键路径 = “比较器或移位器 → 一级选择”，
//      而不是“先花几级译码、再算”；
//   2) 加减法只做**一个加法器**：把 d2 取反（d2_inv = ~d2）交给 add 模块，
//      由 choose_add_sub 决定用 d2 还是 d2_inv+1（补码减法），省一个加法器；
//   3) 比较结果统一放在 bit0：
//        signed_lt    ：有符号 d1 <  d2
//        unsigned_lt  ：无符号 d1 <  d2
//        equal        ：d1 != d2（注意！这里存的是“不相等”）
//      分支要用的“相等 / 大于等于”由 EXU 里的 inv_flag 翻转 bit0 得到，
//      所以这里不要改 equal 的定义，否则会和 EXU 的取反重复、分支全反。
// 常见坑 ：移位量只能取 d2 的低 5 位（RISC-V 规定 shamt 是 5 位），写 d2[4:0]。
//=============================================================================
/*interface define*/

`define alu_add                   4'b0000   // 加
`define alu_sub                   4'b0001   // 减
`define alu_or                    4'b0010   // 或
`define alu_and                   4'b0011   // 与
`define alu_xor                   4'b0100   // 异或
`define alu_signed_comparator     4'b0101   // 有符号比较（小于）
`define alu_unsigned_comparator   4'b0110   // 无符号比较（小于）
`define alu_equal                 4'b0111   // 相等判断（实际存“不相等”）
`define alu_sll                   4'b1000   // 逻辑左移
`define alu_srl                   4'b1001   // 逻辑右移
`define alu_sra                   4'b1010   // 算术右移

`define Performance_Count

module ALU #(
    parameter BW = 32                        // 数据位宽（本 CPU 用 32）
)(
    input [BW-1:0] d1,                       // 操作数 A
    input [BW-1:0] d2,                       // 操作数 B
    input [3:0] choice,                      // 操作码
    output logic [BW-1:0] result              // 运算结果（logic 才能在下面对它做过程赋值）
);
    //-------------------------------------------------------------------------
    // ① 并行预计算：所有结果同时算，最后选（组合逻辑，无时钟）
    //-------------------------------------------------------------------------
    logic [BW-1:0] d2_inv;                   // d2 的按位取反（减法用）
    logic [BW-1:0] and_result;               // d1 & d2
    logic [BW-1:0] or_result;                // d1 | d2
    logic [BW-1:0] xor_result;               // d1 ^ d2
    logic [BW-1:0] sll_result;               // d1 << d2[4:0]
    logic [BW-1:0] srl_result;               // d1 >> d2[4:0]（高位补 0）
    logic [BW-1:0] sra_result;               // d1 >>> d2[4:0]（高位补符号位）
    logic [BW-1:0] add_result;               // 加法器输出（减法也走它）
    logic [BW-1:0] sub_result;               // 减法结果（= 加法器输出）

    logic signed_lt;                         // 有符号小于（1 位）
    logic unsigned_lt;                       // 无符号小于（1 位）
    logic equal;                             // 不相等（1 位）

    assign d2_inv = ~d2;                     // 先取反，减法要用

    assign and_result = d1 & d2;                          // 与
    assign or_result  = d1 | d2;                          // 或
    assign xor_result = d1 ^ d2;                          // 异或
    assign sll_result = d1 << d2[4:0];                    // 左移
    assign srl_result = d1 >> d2[4:0];                    // 逻辑右移
    assign sra_result = $signed(d1) >>> d2[4:0];          // 算术右移

    // 比较器：$signed 让综合器走有符号比较；结果只有 1 位
    assign signed_lt   = $signed(d1) < $signed(d2);       // 有符号小于
    assign unsigned_lt = d1 < d2;                         // 无符号小于
    assign equal       = (d1 != d2);                      // 不相等（注意定义）

    //-------------------------------------------------------------------------
    // ② 加减共用一个加法器
    //    choose_add_sub = 0 → d1 + d2
    //    choose_add_sub = 1 → d1 + (~d2 + 1) = d1 - d2（补码）
    //-------------------------------------------------------------------------
    add #(
        .BW(BW)
    ) add_inst0 (
        .choose_add_sub(choice == `alu_sub),  // 1=减法，0=加法
        .add_1(d1),                           // 被加数
        .add_2(d2),                           // 加数
        .add_2_inv(d2_inv),                   // d2 的取反值（减法时用）
        .result(add_result)                   // 和
    );
    assign sub_result = add_result;           // 减法也走同一个加法器

    //-------------------------------------------------------------------------
    // ③ 一层 case 选最终结果（这个 always 是纯组合，always@(*) 不会生成寄存器）
    //-------------------------------------------------------------------------
    always @(*) begin
        case(choice)
            `alu_signed_comparator   : result = {{(BW-1){1'b0}}, signed_lt};    // < 有符号
            `alu_unsigned_comparator : result = {{(BW-1){1'b0}}, unsigned_lt};  // < 无符号
            `alu_add                 : result = add_result;                     // 加
            `alu_sub                 : result = sub_result;                     // 减
            `alu_and                 : result = and_result;                     // 与
            `alu_or                  : result = or_result;                      // 或
            `alu_xor                 : result = xor_result;                     // 异或
            `alu_equal               : result = {{(BW-1){1'b0}}, equal};        // 不相等
            `alu_sll                 : result = sll_result;                     // <<
            `alu_srl                 : result = srl_result;                     // >>
            `alu_sra                 : result = sra_result;                     // >>>
            default                  : result = {BW{1'b0}};                     // 未定义 → 0
        endcase
    end

endmodule
