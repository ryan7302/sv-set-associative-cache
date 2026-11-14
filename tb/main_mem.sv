// main_mem.sv - simulation model of slow main memory (the "warehouse").
//
// Talks to the cache with a valid/ready handshake:
//   - A request is accepted on a clock edge where mem_req_valid && mem_req_ready.
//   - LATENCY cycles later, mem_resp_valid pulses high for one cycle.
//   - Read  (mem_req_we = 0): returns the whole 4-word line containing the address.
//   - Write (mem_req_we = 1): stores one word; the pulse is the acknowledgement.
//
// Initial contents are predictable so the testbench can check reads of
// addresses that were never written: word number i holds 0xA500_0000 + i.
//
// This is a testbench model, not hardware for the FPGA, so it uses a plain
// "always" block and an "initial" block to fill the memory.
module main_mem #(
  parameter int ADDR_W         = 32,
  parameter int DATA_W         = 32,
  parameter int WORDS_PER_LINE = 4,
  parameter int MEM_WORDS      = 1024,   // 4 KiB of memory
  parameter int LATENCY        = 4       // clock cycles from request to response
)(
  input  logic                             clk,
  input  logic                             rst_n,          // active-low reset

  input  logic                             mem_req_valid,
  output logic                             mem_req_ready,
  input  logic                             mem_req_we,
  input  logic [ADDR_W-1:0]                mem_req_addr,
  input  logic [DATA_W-1:0]                mem_req_wdata,

  output logic                             mem_resp_valid,
  output logic [DATA_W*WORDS_PER_LINE-1:0] mem_resp_rdata
);

  // The storage: MEM_WORDS words of DATA_W bits each
  logic [DATA_W-1:0] mem [MEM_WORDS];

  initial begin
    for (int i = 0; i < MEM_WORDS; i++)
      mem[i] = 32'hA500_0000 + i;
  end

  // Byte address -> word number (drop the 2 byte-offset bits, wrap at the memory size)
  function automatic int word_index(logic [ADDR_W-1:0] a);
    return int'(a >> 2) % MEM_WORDS;
  endfunction

  // Request held while we "take our time"
  logic              busy;
  int                count;
  logic              we_q;
  logic [ADDR_W-1:0] addr_q;
  logic [DATA_W-1:0] wdata_q;

  assign mem_req_ready = !busy;   // can only take a new request when idle

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy           <= 1'b0;
      count          <= 0;
      mem_resp_valid <= 1'b0;
      mem_resp_rdata <= '0;
    end else begin
      mem_resp_valid <= 1'b0;                 // default: no response this cycle

      if (!busy) begin
        if (mem_req_valid) begin              // handshake: valid && ready
          busy    <= 1'b1;
          count   <= LATENCY - 1;
          we_q    <= mem_req_we;
          addr_q  <= mem_req_addr;
          wdata_q <= mem_req_wdata;
        end
      end else if (count != 0) begin
        count <= count - 1;                   // still "walking to the warehouse"
      end else begin
        busy           <= 1'b0;               // done: respond for one cycle
        mem_resp_valid <= 1'b1;
        if (we_q) begin
          mem[word_index(addr_q)] <= wdata_q;
        end else begin
          // first word of the line = word index with the bottom bits cleared
          for (int w = 0; w < WORDS_PER_LINE; w++)
            mem_resp_rdata[w*DATA_W +: DATA_W] <=
              mem[(word_index(addr_q) & ~(WORDS_PER_LINE - 1)) + w];
        end
      end
    end
  end

endmodule
