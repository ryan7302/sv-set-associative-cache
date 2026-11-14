// cache.sv - direct-mapped cache, write-through, no-write-allocate.
//
// Default size: 64 lines x 4 words x 32 bits = 1 KiB.
// Address split (defaults):  tag [31:10] | index [9:4] | word [3:2] | byte [1:0]
//
// Controller states:
//   IDLE          ready for a CPU request; register it when accepted
//   COMPARE       look up the indexed line: hit = valid && tag match
//   ALLOCATE      read miss: fetch the whole line from memory, fill it
//   WRITE_THROUGH write: send the word to memory (and update the line if it is a hit)
//   RESPOND       one-cycle cpu_resp_valid pulse, then back to IDLE
module cache #(
  parameter int ADDR_W         = 32,
  parameter int DATA_W         = 32,
  parameter int WORDS_PER_LINE = 4,
  parameter int NUM_LINES      = 64
)(
  input  logic                             clk,
  input  logic                             rst_n,          // active-low reset

  // CPU side
  input  logic                             cpu_req_valid,
  output logic                             cpu_req_ready,
  input  logic                             cpu_req_we,
  input  logic [ADDR_W-1:0]                cpu_req_addr,
  input  logic [DATA_W-1:0]                cpu_req_wdata,
  output logic                             cpu_resp_valid,
  output logic [DATA_W-1:0]                cpu_resp_rdata,

  // Memory side
  output logic                             mem_req_valid,
  input  logic                             mem_req_ready,
  output logic                             mem_req_we,
  output logic [ADDR_W-1:0]                mem_req_addr,
  output logic [DATA_W-1:0]                mem_req_wdata,
  input  logic                             mem_resp_valid,
  input  logic [DATA_W*WORDS_PER_LINE-1:0] mem_resp_rdata,

  // Performance counters
  output logic [31:0]                      read_hits,
  output logic [31:0]                      read_misses,
  output logic [31:0]                      writes
);

  // ---------------------------------------------------------------------------
  // Field widths, worked out from the parameters (the "2 to the power of what"
  // rule: $clog2(64) = 6, $clog2(4) = 2)
  // ---------------------------------------------------------------------------
  localparam int BYTE_BITS  = $clog2(DATA_W / 8);                       // 2
  localparam int WORD_BITS  = $clog2(WORDS_PER_LINE);                   // 2
  localparam int INDEX_BITS = $clog2(NUM_LINES);                        // 6
  localparam int TAG_BITS   = ADDR_W - INDEX_BITS - WORD_BITS - BYTE_BITS; // 22
  localparam int OFFSET_BITS = WORD_BITS + BYTE_BITS;                   // 4

  // ---------------------------------------------------------------------------
  // Storage: one valid bit, one tag and one line of data per index
  // ---------------------------------------------------------------------------
  logic                valid_arr [NUM_LINES];
  logic [TAG_BITS-1:0] tag_arr   [NUM_LINES];
  // Data is stored as WORDS_PER_LINE separate RAMs ("lanes"), one per word
  // position - see the storage section at the bottom. lane_rdata[w] is word w
  // of the currently indexed line.
  logic [DATA_W-1:0]   lane_rdata [WORDS_PER_LINE];

  // ---------------------------------------------------------------------------
  // The request being worked on (copied in when it is accepted)
  // ---------------------------------------------------------------------------
  logic              we_q;
  logic [ADDR_W-1:0] addr_q;
  logic [DATA_W-1:0] wdata_q;
  logic [DATA_W-1:0] rdata_q;

  // Split the address into its fields
  logic [TAG_BITS-1:0]   tag;
  logic [INDEX_BITS-1:0] index;
  logic [WORD_BITS-1:0]  word;

  assign word  = addr_q[BYTE_BITS +: WORD_BITS];       // bits [3:2]
  assign index = addr_q[OFFSET_BITS +: INDEX_BITS];    // bits [9:4]
  assign tag   = addr_q[ADDR_W-1 -: TAG_BITS];         // bits [31:10]

  // Hit = the line holds real data AND it is the block we want
  logic hit;
  assign hit = valid_arr[index] && (tag_arr[index] == tag);

  // ---------------------------------------------------------------------------
  // Controller state machine
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {IDLE, COMPARE, ALLOCATE, WRITE_THROUGH, RESPOND} state_t;
  state_t state;
  logic   mem_sent;   // memory has accepted our request; waiting for its reply

  // CPU-side outputs
  assign cpu_req_ready  = (state == IDLE);
  assign cpu_resp_valid = (state == RESPOND);
  assign cpu_resp_rdata = rdata_q;

  // Memory-side outputs: ask once, then wait for the reply
  assign mem_req_valid = ((state == ALLOCATE) || (state == WRITE_THROUGH)) && !mem_sent;
  assign mem_req_we    = (state == WRITE_THROUGH);
  assign mem_req_wdata = wdata_q;
  // Reads ask for the start of the line (offset bits cleared); writes give the word address
  assign mem_req_addr  = (state == ALLOCATE)
                         ? {addr_q[ADDR_W-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}}
                         : addr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= IDLE;
      mem_sent    <= 1'b0;
      we_q        <= 1'b0;
      addr_q      <= '0;
      wdata_q     <= '0;
      rdata_q     <= '0;
      read_hits   <= '0;
      read_misses <= '0;
      writes      <= '0;
      for (int i = 0; i < NUM_LINES; i++)
        valid_arr[i] <= 1'b0;                  // every line starts empty
    end else begin
      case (state)

        IDLE: begin
          if (cpu_req_valid) begin             // handshake: valid && ready
            we_q    <= cpu_req_we;
            addr_q  <= cpu_req_addr;
            wdata_q <= cpu_req_wdata;
            state   <= COMPARE;
          end
        end

        COMPARE: begin
          if (we_q) begin                      // all writes go through to memory
            writes <= writes + 1;
            state  <= WRITE_THROUGH;
          end else if (hit) begin              // read hit: answer from the cache
            read_hits <= read_hits + 1;
            rdata_q   <= lane_rdata[word];
            state     <= RESPOND;
          end else begin                       // read miss: fetch the line
            read_misses <= read_misses + 1;
            state       <= ALLOCATE;
          end
        end

        ALLOCATE: begin
          if (mem_req_valid && mem_req_ready)
            mem_sent <= 1'b1;
          if (mem_resp_valid) begin            // line has arrived
            valid_arr[index] <= 1'b1;
            rdata_q  <= mem_resp_rdata[word*DATA_W +: DATA_W];
            mem_sent <= 1'b0;
            state    <= RESPOND;
          end
        end

        WRITE_THROUGH: begin
          if (mem_req_valid && mem_req_ready)
            mem_sent <= 1'b1;
          if (mem_resp_valid) begin            // memory has stored the word
            mem_sent <= 1'b0;
            state    <= RESPOND;
          end
        end

        RESPOND: state <= IDLE;

        default: state <= IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Tag and data storage (no reset needed: the valid bit says whether they count)
  //
  // Written so the FPGA tools map it to RAM instead of flip-flops:
  // each RAM has ONE write port (one address, one data input, one write enable)
  // and an asynchronous read, which is the shape of Xilinx distributed (LUT) RAM.
  // ---------------------------------------------------------------------------
  logic fill_line, update_word;
  assign fill_line   = (state == ALLOCATE)      && mem_resp_valid;
  assign update_word = (state == WRITE_THROUGH) && mem_resp_valid && hit;  // write hit only

  // Tag RAM: 64 x 22 bits
  always_ff @(posedge clk) begin
    if (fill_line)
      tag_arr[index] <= tag;
  end

  // Data RAMs: one 64 x 32-bit RAM per word position.
  //   line fill -> all lanes write their own word of the incoming line
  //   write hit -> only the lane selected by the word offset writes
  for (genvar w = 0; w < WORDS_PER_LINE; w++) begin : g_lane
    logic [DATA_W-1:0] ram [NUM_LINES];
    logic              we;
    logic [DATA_W-1:0] din;

    assign we  = fill_line || (update_word && (word == w));
    assign din = fill_line ? mem_resp_rdata[w*DATA_W +: DATA_W] : wdata_q;

    always_ff @(posedge clk) begin
      if (we)
        ram[index] <= din;
    end

    assign lane_rdata[w] = ram[index];   // asynchronous read
  end

endmodule
