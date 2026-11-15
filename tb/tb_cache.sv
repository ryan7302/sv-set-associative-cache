// tb_cache.sv - self-checking testbench for cache.sv (any WAYS: 1, 2, 4 or 8)
//
//   DUT:        cache (the design)  <->  main_mem (simulation model of memory)
//   Reference:  ref_mem  - every value ever written, so read data can be checked
//               ref_valid/ref_tag/ref_age - a software copy of the cache's sets,
//               ways and LRU order, so we know whether each access SHOULD hit
//   Tests:      directed tests (each cache behaviour on purpose), then
//               N_RANDOM constrained-random reads and writes, then a
//               conflict-heavy workload that shows the benefit of more ways
//   Checks:     read data, hit/miss, "a read hit never uses memory",
//               performance counters, plus SVA assertions on the handshakes
//
// Run in Vivado: set tb_cache as simulation top, Run Behavioral Simulation, then Run All.
// To test another associativity, change WAYS below (or override the parameter).
module tb_cache #(parameter int WAYS = 4);

  // ---------------------------------------------------------------------------
  // Settings (must match the design and memory defaults)
  // ---------------------------------------------------------------------------
  localparam int NUM_LINES      = 64;
  localparam int WORDS_PER_LINE = 4;
  localparam int MEM_WORDS      = 1024;   // main_mem size: 4 KiB
  localparam int LATENCY        = 4;
  localparam int N_RANDOM       = 1000;
  localparam int N_CONFLICT     = 400;
  localparam int SETS           = NUM_LINES / WAYS;

  // ---------------------------------------------------------------------------
  // Clock, reset and wires
  // ---------------------------------------------------------------------------
  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;                   // 100 MHz

  logic         cpu_req_valid = 0, cpu_req_we = 0;
  logic [31:0]  cpu_req_addr = '0, cpu_req_wdata = '0;
  logic         cpu_req_ready, cpu_resp_valid;
  logic [31:0]  cpu_resp_rdata;

  logic         mem_req_valid, mem_req_ready, mem_req_we, mem_resp_valid;
  logic [31:0]  mem_req_addr, mem_req_wdata;
  logic [127:0] mem_resp_rdata;

  logic [31:0]  read_hits, read_misses, writes;

  cache #(.NUM_LINES(NUM_LINES), .WORDS_PER_LINE(WORDS_PER_LINE), .WAYS(WAYS)) dut (.*);

  main_mem #(.MEM_WORDS(MEM_WORDS), .LATENCY(LATENCY)) mem (.*);

  // ---------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------
  logic [31:0] ref_mem [int];             // address -> last value written
  logic        ref_valid [SETS][WAYS];
  int          ref_tag   [SETS][WAYS];
  int          ref_age   [SETS][WAYS];   // 0 = most recently used

  // What memory should hold at an address: last write, or the initial pattern
  function automatic logic [31:0] expected_value(logic [31:0] addr);
    if (ref_mem.exists(addr)) return ref_mem[addr];
    return 32'hA500_0000 + ((addr >> 2) % MEM_WORDS);
  endfunction

  function automatic int index_of(logic [31:0] addr); return (addr >> 4) % SETS; endfunction
  function automatic int tag_of  (logic [31:0] addr); return (addr >> 4) / SETS; endfunction

  // Which way of the set holds this tag (-1 if none)
  function automatic int find_way(int set, int tag);
    for (int w = 0; w < WAYS; w++)
      if (ref_valid[set][w] && ref_tag[set][w] == tag) return w;
    return -1;
  endfunction

  // Make way w the most recently used in its set (same rule as the design)
  function automatic void touch(int set, int w);
    int old = ref_age[set][w];
    for (int i = 0; i < WAYS; i++)
      if (ref_age[set][i] < old) ref_age[set][i]++;
    ref_age[set][w] = 0;
  endfunction

  // Way a read miss will fill: first empty way, otherwise the least recently used
  function automatic int victim(int set);
    for (int w = 0; w < WAYS; w++) if (!ref_valid[set][w]) return w;
    for (int w = 0; w < WAYS; w++) if (ref_age[set][w] == WAYS - 1) return w;
    return 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Scoreboard counters
  // ---------------------------------------------------------------------------
  int checks = 0, errors = 0;
  int exp_hits = 0, exp_misses = 0, exp_writes = 0;
  int rand_hits, rand_misses;            // totals at the end of the random phase
  int hit_lat_min = 1000, hit_lat_max = 0, miss_lat_min = 1000, miss_lat_max = 0;

  // Count memory handshakes, so we can prove a read hit never touches memory
  int mem_requests = 0;
  always @(posedge clk) if (mem_req_valid && mem_req_ready) mem_requests++;

  task automatic fail(input string msg);
    errors++;
    $error("FAIL: %s", msg);
  endtask

  // ---------------------------------------------------------------------------
  // One CPU access: send it, wait for the response, check everything
  // ---------------------------------------------------------------------------
  task automatic access(input logic we, input logic [31:0] addr, input logic [31:0] wdata,
                        input string name = "");
    int          cycles, mem_before, idx, way;
    bit          should_hit;
    logic [31:0] expect_data;

    idx         = index_of(addr);
    way         = find_way(idx, tag_of(addr));
    should_hit  = (way >= 0);
    expect_data = expected_value(addr);
    mem_before  = mem_requests;

    // Drive the request and wait until the cache accepts it (valid && ready)
    @(negedge clk);
    cpu_req_valid = 1; cpu_req_we = we; cpu_req_addr = addr; cpu_req_wdata = wdata;
    do @(posedge clk); while (!cpu_req_ready);
    #1 cpu_req_valid = 0;

    // Wait for the one-cycle response
    cycles = 0;
    while (!cpu_resp_valid) begin
      @(posedge clk); #1;
      cycles++;
      if (cycles > 100) begin fail($sformatf("%s: no response (timeout)", name)); return; end
    end

    checks++;
    if (we) begin
      // Write-through: memory must be written exactly once; no line is loaded
      exp_writes++;
      if (mem_requests - mem_before != 1)
        fail($sformatf("%s: write used %0d memory requests, expected 1", name, mem_requests - mem_before));
      ref_mem[addr] = wdata;               // a write miss does NOT allocate: ref cache unchanged
      if (should_hit) touch(idx, way);     // a write hit makes the way most recently used
    end else begin
      if (cpu_resp_rdata !== expect_data)
        fail($sformatf("%s: read %h returned %h, expected %h", name, addr, cpu_resp_rdata, expect_data));
      if (should_hit) begin
        exp_hits++;
        if (mem_requests != mem_before)
          fail($sformatf("%s: read hit at %h used memory", name, addr));
        hit_lat_min = (cycles < hit_lat_min) ? cycles : hit_lat_min;
        hit_lat_max = (cycles > hit_lat_max) ? cycles : hit_lat_max;
        touch(idx, way);
      end else begin
        exp_misses++;
        if (mem_requests - mem_before != 1)
          fail($sformatf("%s: read miss at %h used %0d memory requests, expected 1", name, addr, mem_requests - mem_before));
        miss_lat_min = (cycles < miss_lat_min) ? cycles : miss_lat_min;
        miss_lat_max = (cycles > miss_lat_max) ? cycles : miss_lat_max;
        way = victim(idx);                 // a read miss fills the victim way
        ref_valid[idx][way] = 1;
        ref_tag[idx][way]   = tag_of(addr);
        touch(idx, way);
      end
    end

    // The design's counters must agree with the reference after every access
    if (read_hits != exp_hits || read_misses != exp_misses || writes != exp_writes)
      fail($sformatf("%s: counters hits/misses/writes = %0d/%0d/%0d, expected %0d/%0d/%0d",
                     name, read_hits, read_misses, writes, exp_hits, exp_misses, exp_writes));
  endtask

  // ---------------------------------------------------------------------------
  // Random transaction: word-aligned address inside the 4 KiB memory,
  // 70% reads / 30% writes. 4 KiB = 4 tags per line, so hits, misses and
  // conflict evictions all happen.
  // ---------------------------------------------------------------------------
  class Txn;
    rand bit          we;
    rand bit   [31:0] addr;
    rand bit   [31:0] wdata;
    constraint in_memory { addr < MEM_WORDS * 4; addr[1:0] == 2'b00; }
    constraint mostly_reads { we dist {0 := 70, 1 := 30}; }
  endclass

  // ---------------------------------------------------------------------------
  // Assertions: rules that must hold on every clock edge
  // ---------------------------------------------------------------------------
  // Once a request is accepted, the cache must stop accepting until it is done
  a_busy_after_accept: assert property (@(posedge clk) disable iff (!rst_n)
      (cpu_req_valid && cpu_req_ready) |=> !cpu_req_ready)
    else fail("cpu_req_ready stayed high after a request was accepted");

  // The response is a single-cycle pulse
  a_resp_one_cycle: assert property (@(posedge clk) disable iff (!rst_n)
      cpu_resp_valid |=> !cpu_resp_valid)
    else fail("cpu_resp_valid was high for more than one cycle");

  // The cache never asks the CPU for a new request while it is responding
  a_no_ready_while_resp: assert property (@(posedge clk) disable iff (!rst_n)
      cpu_resp_valid |-> !cpu_req_ready)
    else fail("cpu_req_ready and cpu_resp_valid high together");

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
    Txn t;
    t = new();
    for (int s = 0; s < SETS; s++)
      for (int w = 0; w < WAYS; w++) begin
        ref_valid[s][w] = 0;
        ref_age[s][w]   = w;
      end

    $display("==== Cache configuration: %0d-way, %0d sets ====", WAYS, SETS);

    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    $display("---- Directed tests ----");
    access(0, 32'h058, '0,            "D1 cold miss");
    access(0, 32'h05C, '0,            "D2 hit, same line");
    access(0, 32'h050, '0,            "D3 hit, word 0");
    access(1, 32'h058, 32'h1234_5678, "D4 write hit");
    access(0, 32'h058, '0,            "D5 read after write hit");
    access(0, 32'h458, '0,            "D6 conflict miss (evicts line 5)");
    access(0, 32'h058, '0,            "D7 miss again, data from memory");
    access(1, 32'h858, 32'hCAFE_F00D, "D8 write miss, no allocate");
    access(0, 32'h058, '0,            "D9 line 5 untouched by write miss");
    access(0, 32'h858, '0,            "D10 read the written miss");
    access(0, 32'hFFC, '0,            "D11 last word of memory");
    access(0, 32'h3F0, '0,            "D12 last line (index 63)");
    $display("directed: %0d checks, %0d errors", checks, errors);

    $display("---- %0d random transactions ----", N_RANDOM);
    repeat (N_RANDOM) begin
      if (!t.randomize()) fail("randomize failed");
`ifdef VERILATOR
      // The open-source simulator used for a second opinion ignores constraints,
      // so apply them by hand there. Vivado XSim does not see this code.
      t.addr = (t.addr % (MEM_WORDS * 4)) & ~32'h3;
`endif
      access(t.we, t.addr, t.wdata, "random");
    end

    // -------------------------------------------------------------------------
    // Conflict-heavy workload: reads from 4 lines that all map to the same set
    // in a direct-mapped cache (addresses 1 KiB apart). A direct-mapped cache
    // keeps evicting them; with 4 or more ways they all fit.
    // -------------------------------------------------------------------------
    rand_hits   = exp_hits;
    rand_misses = exp_misses;
    $display("---- %0d conflict-heavy reads ----", N_CONFLICT);
    repeat (N_CONFLICT) begin
      logic [31:0] a;
      a = 32'h050 + ($urandom_range(0, 3) * 32'h400) + ($urandom_range(0, 3) * 4);
      access(0, a, '0, "conflict");
    end

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    $display("");
    $display("Accesses checked : %0d", checks);
    $display("Configuration    : %0d-way, %0d sets", WAYS, SETS);
    $display("Reads (all)      : %0d hits, %0d misses (hit rate %0.1f%%)",
             exp_hits, exp_misses, 100.0 * exp_hits / (exp_hits + exp_misses));
    $display("Random phase     : hit rate %0.1f%%",
             100.0 * rand_hits / (rand_hits + rand_misses));
    $display("Conflict phase   : hit rate %0.1f%%",
             100.0 * (exp_hits - rand_hits) / ((exp_hits - rand_hits) + (exp_misses - rand_misses)));
    $display("Writes           : %0d", exp_writes);
    $display("Read hit latency : %0d-%0d cycles, read miss latency: %0d-%0d cycles",
             hit_lat_min, hit_lat_max, miss_lat_min, miss_lat_max);
    if (errors == 0) $display("==== CACHE: ALL TESTS PASSED ====");
    else             $display("==== CACHE: %0d FAILURE(S) ====", errors);
    $finish;
  end

endmodule
