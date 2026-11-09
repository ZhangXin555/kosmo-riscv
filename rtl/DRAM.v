`timescale 1ns/1ps

// DRAM: 65536 x 32 simple-dual-port RAM
// NOTE: BRAM 上电为 0（PDS 综合时不要写 65536 次循环，会触发 "Loop limit 2000 exceeded"）
module DRAM(
    input  wire        clk,
    input  wire [15:0] a,
    output reg  [31:0] spo,
    input  wire        we,
    input  wire [31:0] d
);
    reg [31:0] mem [0:65535];

    initial begin
        mem[16'h0003] = 32'h1234abcd;
        mem[16'h0004] = 32'h55667788;
        mem[16'h0007] = 32'hff0000ff;
    end

    always @(posedge clk) begin
        if (we) mem[a] <= d;
        spo <= mem[a];
    end
endmodule