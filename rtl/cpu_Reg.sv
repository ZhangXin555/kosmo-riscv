`timescale 1ns/1ps

//=============================================================================
// 模块名 ：Reg（带复位、带写使能的通用寄存器）
// 位置   ：被流水线寄存器模块（cpu_IFID_EX_Reg / cpu_EX_LSWB_Reg）反复例化
// 干什么 ：每个时钟上升沿，如果 wen=1 就把 din 存进 dout；reset 时清成 RESET_VAL。
//          wen=0 时保持原值 —— 这就是流水线"暂停/气泡"的实现方式。
// 参数   ：WIDTH 位宽；RESET_VAL 复位值。
//=============================================================================
module Reg #(WIDTH = 1, RESET_VAL = 0) (
    input clock,                          // 时钟
    input reset,                          // 复位，高有效
    input [WIDTH-1: 0]din,                // 输入端
    output logic [WIDTH-1: 0]dout,        // 输出端（寄存后的值）
    input wen                             // 写使能：1=更新，0=保持
);
always @(posedge clock) begin
    if (reset)                            // 复位优先
        dout <= RESET_VAL;                // 清成指定初值
    else if (wen)                         // 有写使能才更新
        dout <= din;                      // 打一拍
    end
endmodule
