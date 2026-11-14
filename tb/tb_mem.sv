// tb_mem.sv - small self-checking test for main_mem on its own.
// Checks: line read returns the right 4 words, latency is LATENCY cycles,
// a write is stored and read back, and the other words in the line are unchanged.
module tb_mem;

  localparam int LATENCY = 4;

  logic         clk = 0;
  logic         rst_n;
  logic         req_valid = 0, req_we = 0;
  logic         req_ready;
  logic [31:0]  req_addr = '0, req_wdata = '0;
  logic         resp_valid;
  logic [127:0] resp_rdata;

  int errors = 0;

  main_mem #(.LATENCY(LATENCY)) dut (
    .clk(clk), .rst_n(rst_n),
    .mem_req_valid(req_valid), .mem_req_ready(req_ready),
    .mem_req_we(req_we), .mem_req_addr(req_addr), .mem_req_wdata(req_wdata),
    .mem_resp_valid(resp_valid), .mem_resp_rdata(resp_rdata));

  always #5 clk = ~clk;   // 100 MHz

  // Send one request, wait for the response, report how many cycles it took
  task automatic do_request(input logic we, input logic [31:0] addr,
                            input logic [31:0] wdata, output int cycles);
    @(negedge clk);
    req_valid = 1; req_we = we; req_addr = addr; req_wdata = wdata;
    @(posedge clk);                    // accepted here (memory is idle)
    @(negedge clk);
    req_valid = 0;
    cycles = 0;
    while (!resp_valid) begin
      @(posedge clk); cycles++;
      #1;
    end
  endtask

  task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      errors++;
      $error("FAIL %s: expected %h, got %h", name, exp, got);
    end else
      $display("ok   %s = %h", name, got);
  endtask

  int cyc;

  initial begin
    rst_n = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;

    // 1. Read the line containing 0x58 -> words 0x14..0x17 (addresses 0x50..0x5C)
    do_request(0, 32'h58, '0, cyc);
    check("read 0x50 word0", resp_rdata[ 31: 0], 32'hA500_0014);
    check("read 0x50 word1", resp_rdata[ 63:32], 32'hA500_0015);
    check("read 0x50 word2", resp_rdata[ 95:64], 32'hA500_0016);
    check("read 0x50 word3", resp_rdata[127:96], 32'hA500_0017);
    check("read latency (cycles)", cyc, LATENCY);

    // 2. Write 0xDEADBEEF to 0x54, then read the line back
    do_request(1, 32'h54, 32'hDEAD_BEEF, cyc);
    check("write latency (cycles)", cyc, LATENCY);
    do_request(0, 32'h50, '0, cyc);
    check("after write word1", resp_rdata[ 63:32], 32'hDEAD_BEEF);
    check("after write word0", resp_rdata[ 31: 0], 32'hA500_0014);   // neighbours unchanged
    check("after write word2", resp_rdata[ 95:64], 32'hA500_0016);

    if (errors == 0) $display("==== MAIN_MEM: ALL TESTS PASSED ====");
    else             $display("==== MAIN_MEM: %0d FAILURE(S) ====", errors);
    $finish;
  end

endmodule
