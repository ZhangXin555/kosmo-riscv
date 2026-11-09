`timescale 1ns/1ps

//=============================================================================
// 模块名 ：sext（符号扩展器）
// 位置   ：ID 级（cpu_IDU.sv）里把 12 位立即数扩成 32 位
// 干什么 ：把 DATA_WIDTH 位有符号数扩展到 OUT_WIDTH 位：
//          最高位（符号位）复制 (OUT_WIDTH-DATA_WIDTH) 份拼到前面。
//          例：12'hFFF → 32'hFFFF_FFFF（-1）；12'h7FF → 32'h0000_07FF（+2047）
// 为什么 ：RISC-V 的 I/S/B 型立即数都是 12 位有符号，参与 32 位运算前必须先符号扩展。
//=============================================================================
module sext#
(
    parameter DATA_WIDTH=1,               // 输入位宽（例：12）
    parameter OUT_WIDTH=2                 // 输出位宽（例：32）
)
(
    input [DATA_WIDTH-1:0]data,           // 原始窄立即数
    output [OUT_WIDTH-1:0]sext_data       // 扩展后的 32 位结果
);

// {重复次数{被重复的位}, 原数据} —— 把符号位 data[DATA_WIDTH-1] 复制到高位
assign sext_data = {{(OUT_WIDTH-DATA_WIDTH){data[DATA_WIDTH-1]}},data};

endmodule
