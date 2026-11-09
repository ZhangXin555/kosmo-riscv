module tb;
  reg clk=0, rst=1;
  wire [31:0] irom_addr, perip_addr, perip_wdata;
  wire perip_wen;
  wire [1:0] perip_mask;
  wire [31:0] perip_rdata;
  reg [31:0] rom [0:4095];
  reg [31:0] dram [0:65535];
  reg [31:0] dram_q;
  integer cycles=0;
  integer i;
  reg done=0;
  always #10 clk = ~clk;
  wire [31:0] irom_data = rom[irom_addr[15:2]];
  always @(posedge clk) if (!rst) cycles <= cycles + 1;
  always @(posedge clk) begin
    if (!rst && perip_wen) begin
      if (perip_addr[15:0] == 16'h00F0) begin
        if (!done) begin done <= 1; $display("RESULT_CYCLES=%0d DONEVAL=%h", cycles, perip_wdata); end
      end else begin
        dram[perip_addr[15:2]] <= perip_wdata;
      end
    end
    dram_q <= dram[perip_addr[15:2]];
  end
  assign perip_rdata = dram_q;
  myCPU uut(.cpu_clk(clk), .cpu_rst(rst), .irom_addr(irom_addr), .irom_data(irom_data),
            .perip_addr(perip_addr), .perip_wen(perip_wen), .perip_mask(perip_mask),
            .perip_wdata(perip_wdata), .perip_rdata(perip_rdata));
  initial begin
    for (i=0;i<65536;i=i+1) dram[i]=32'd0;   // init dram
    $readmemh("prog.hex", rom);
    rst = 1; repeat(5) @(posedge clk); rst = 0;
    wait(done); $display("TOTAL_CYCLES=%0d DRAM0=%h", cycles, dram[0]); $finish;
  end
  always @(posedge clk) if (!rst && cycles<40) $display("t=%0t pc=%h inst=%h wen=%b pa=%h", $time, irom_addr, irom_data, perip_wen, perip_addr);
  initial begin
    #2000000; $display("TIMEOUT_CYCLES=%0d", cycles); $finish;
  end
endmodule
