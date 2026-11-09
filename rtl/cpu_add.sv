`timescale 1ns/1ps

//=============================================================================
// 模块名 ：add（可切换加/减的加法器）
// 位置   ：被 cpu_ALU.sv 调用的组合运算单元（EX 级内部）
// 干什么 ：choose_add_sub=0 时做 add_1 + add_2（加法）；
//          choose_add_sub=1 时做 add_1 + (~add_2 + 1) = add_1 - add_2（减法）。
//          "加 1"来自 add_2_inv，它是 add_2 的按位取反（在 ALU 里生成），
//          所以这里不再自己取反，省一级逻辑。
// 关键点 ：减法用"补码 = 取反加一"实现；BW 是位宽参数（ALU 里例化成 32）。
//=============================================================================
module add
#(
    parameter BW=4                        // 位宽参数，默认 4（ALU 里用 32）
)
(
   input choose_add_sub,                  // 0=加法，1=减法
   input [BW-1:0]add_1,                   // 被加数（操作数 A）
   input [BW-1:0]add_2,                   // 加数（操作数 B）
   input [BW-1:0]add_2_inv,               // ~add_2，减法时用来做补码
   output [BW-1:0]result                  // 运算结果
);

logic [BW-1:0]add_3;                      // 真正参与相加的第二项

// 选第二操作数：加法直接用 B；减法用 ~B（1 的补数）
assign add_3 = (choose_add_sub == 1'b0)? add_2:(add_2_inv + 1'b1);   // 减法时 +1 补齐成 2 的补码

// 核心：A + B 或 A + (~B+1)
assign result = add_1 + add_3;

endmodule
