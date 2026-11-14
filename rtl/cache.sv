// cache.sv - N-way set-associative cache, write-through, no-write-allocate, LRU.
//
// WAYS = 1 gives a direct-mapped cache; 2, 4 or 8 give set-associative caches.
// The total size stays NUM_LINES lines; more ways means fewer sets:
//   SETS = NUM_LINES / WAYS
//
// Address split (defaults, WAYS = 4):  tag [31:8] | set index [7:4] | word [3:2] | byte [1:0]
//
// Replacement: on a read miss, fill an empty (invalid) way if there is one,
// otherwise the least recently used (LRU) way. Every read hit, write hit and
// line fill makes that way the most recently used.
//
// Controller states:
//   IDLE          ready for a CPU request; register it when accepted
//   COMPARE       compare the tag in every way of the set: hit = any way valid && tag match
//   ALLOCATE      read miss: fetch the whole line from memory into the victim way
//   WRITE_THROUGH write: send the word to memory (and update the hit way, if any)
//   RESPOND       one-cycle cpu_resp_valid pulse, then back to IDLE
module cache #(
  parameter int ADDR_W         = 32,
  parameter int DATA_W         = 32,
  parameter int WORDS_PER_LINE = 4,
  parameter int NUM_LINES      = 64,
  parameter int WAYS           = 4      // 1 = direct-mapped; 2, 4 or 8 = set-associative
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
  // Sizes, worked out from the parameters
  // ---------------------------------------------------------------------------
  localparam int SETS        = NUM_LINES / WAYS;
  localparam int BYTE_BITS   = $clog2(DATA_W / 8);                        // 2
  localparam int WORD_BITS   = $clog2(WORDS_PER_LINE);                    // 2
  localparam int INDEX_BITS  = $clog2(SETS);                              // 4 for 4-way
  localparam int OFFSET_BITS = WORD_BITS + BYTE_BITS;                     // 4
  localparam int TAG_BITS    = ADDR_W - INDEX_BITS - OFFSET_BITS;         // 24 for 4-way
  localparam int WAY_BITS    = (WAYS > 1) ? $clog2(WAYS) : 1;             // way number width

  initial begin
    if (WAYS != 1 && WAYS != 2 && WAYS != 4 && WAYS != 8)
      $fatal(1, "WAYS must be 1, 2, 4 or 8");
  end

  // ---------------------------------------------------------------------------
  // The request being worked on (copied in when it is accepted)
  // ---------------------------------------------------------------------------
  logic              we_q;
  logic [ADDR_W-1:0] addr_q;
  logic [DATA_W-1:0] wdata_q;
  logic [DATA_W-1:0] rdata_q;

  logic [TAG_BITS-1:0]   tag;
  logic [INDEX_BITS-1:0] index;      // which set
  logic [WORD_BITS-1:0]  word;

  assign word  = addr_q[BYTE_BITS +: WORD_BITS];
  assign index = addr_q[OFFSET_BITS +: INDEX_BITS];
  assign tag   = addr_q[ADDR_W-1 -: TAG_BITS];

  // ---------------------------------------------------------------------------
  // Storage per way: valid bits (registers), tag RAM, and one data RAM per word
  // position. tag_rd[w] / data_rd[w][k] are the values for the current set.
  // ---------------------------------------------------------------------------
  logic                valid_arr [WAYS][SETS];
  logic [TAG_BITS-1:0] tag_rd    [WAYS];
  logic [DATA_W-1:0]   data_rd   [WAYS][WORDS_PER_LINE];

  // LRU ages: 0 = most recently used, WAYS-1 = least recently used.
  // The ages in a set are always a permutation of 0..WAYS-1.
  logic [WAY_BITS-1:0] age [SETS][WAYS];

  // ---------------------------------------------------------------------------
  // Hit detection: compare the tag in every way of the set at the same time
  // ---------------------------------------------------------------------------
  logic [WAYS-1:0]     way_hit;
  logic                hit;
  logic [WAY_BITS-1:0] hit_way;

  always_comb begin
    hit     = 1'b0;
    hit_way = '0;
    for (int w = 0; w < WAYS; w++) begin
      way_hit[w] = valid_arr[w][index] && (tag_rd[w] == tag);
      if (way_hit[w]) begin
        hit     = 1'b1;
        hit_way = WAY_BITS'(w);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Victim choice for a read miss: first empty way, otherwise the LRU way
  // ---------------------------------------------------------------------------
  logic [WAY_BITS-1:0] victim_way;
  logic                found_empty;

  always_comb begin
    found_empty = 1'b0;
    victim_way  = '0;
    for (int w = WAYS - 1; w >= 0; w--) begin      // lowest-numbered empty way wins
      if (!valid_arr[w][index]) begin
        found_empty = 1'b1;
        victim_way  = WAY_BITS'(w);
      end
    end
    if (!found_empty) begin
      for (int w = 0; w < WAYS; w++)
        if (age[index][w] == WAY_BITS'(WAYS - 1))
          victim_way = WAY_BITS'(w);
    end
  end

  // ---------------------------------------------------------------------------
  // Controller state machine
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {IDLE, COMPARE, ALLOCATE, WRITE_THROUGH, RESPOND} state_t;
  state_t state;
  logic   mem_sent;   // memory has accepted our request; waiting for its reply

  assign cpu_req_ready  = (state == IDLE);
  assign cpu_resp_valid = (state == RESPOND);
  assign cpu_resp_rdata = rdata_q;

  assign mem_req_valid = ((state == ALLOCATE) || (state == WRITE_THROUGH)) && !mem_sent;
  assign mem_req_we    = (state == WRITE_THROUGH);
  assign mem_req_wdata = wdata_q;
  assign mem_req_addr  = (state == ALLOCATE)
                         ? {addr_q[ADDR_W-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}}
                         : addr_q;

  // Events that write storage or update LRU
  logic fill_line, update_word, touch;
  logic [WAY_BITS-1:0] touch_way;
  assign fill_line   = (state == ALLOCATE)      && mem_resp_valid;
  assign update_word = (state == WRITE_THROUGH) && mem_resp_valid && hit;   // write hit only
  // A way becomes most recently used on a read hit, a write hit or a line fill
  assign touch       = ((state == COMPARE) && !we_q && hit) || update_word || fill_line;
  assign touch_way   = fill_line ? victim_way : hit_way;

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
      for (int w = 0; w < WAYS; w++)
        for (int s = 0; s < SETS; s++)
          valid_arr[w][s] <= 1'b0;              // every line starts empty
    end else begin
      case (state)

        IDLE: begin
          if (cpu_req_valid) begin              // handshake: valid && ready
            we_q    <= cpu_req_we;
            addr_q  <= cpu_req_addr;
            wdata_q <= cpu_req_wdata;
            state   <= COMPARE;
          end
        end

        COMPARE: begin
          if (we_q) begin                       // all writes go through to memory
            writes <= writes + 1;
            state  <= WRITE_THROUGH;
          end else if (hit) begin               // read hit: answer from the hit way
            read_hits <= read_hits + 1;
            rdata_q   <= data_rd[hit_way][word];
            state     <= RESPOND;
          end else begin                        // read miss: fetch the line
            read_misses <= read_misses + 1;
            state       <= ALLOCATE;
          end
        end

        ALLOCATE: begin
          if (mem_req_valid && mem_req_ready)
            mem_sent <= 1'b1;
          if (mem_resp_valid) begin             // line has arrived
            valid_arr[victim_way][index] <= 1'b1;
            rdata_q  <= mem_resp_rdata[word*DATA_W +: DATA_W];
            mem_sent <= 1'b0;
            state    <= RESPOND;
          end
        end

        WRITE_THROUGH: begin
          if (mem_req_valid && mem_req_ready)
            mem_sent <= 1'b1;
          if (mem_resp_valid) begin             // memory has stored the word
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
  // LRU ages. On a touch: every way younger than the touched way gets one step
  // older; the touched way becomes 0 (most recent). At reset, way w has age w.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < SETS; s++)
        for (int w = 0; w < WAYS; w++)
          age[s][w] <= WAY_BITS'(w);
    end else if (touch && WAYS > 1) begin
      for (int w = 0; w < WAYS; w++) begin
        if (WAY_BITS'(w) == touch_way)
          age[index][w] <= '0;
        else if (age[index][w] < age[index][touch_way])
          age[index][w] <= age[index][w] + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Tag and data RAMs, one set per way. Each RAM has one write port and an
  // asynchronous read, so Vivado maps it to distributed (LUT) RAM.
  //   line fill -> the victim way's tag and all its data lanes are written
  //   write hit -> only the hit way's lane selected by the word offset is written
  // ---------------------------------------------------------------------------
  for (genvar w = 0; w < WAYS; w++) begin : g_way

    logic [TAG_BITS-1:0] tag_ram [SETS];
    logic                fill_this_way;
    assign fill_this_way = fill_line && (victim_way == WAY_BITS'(w));

    always_ff @(posedge clk) begin
      if (fill_this_way)
        tag_ram[index] <= tag;
    end
    assign tag_rd[w] = tag_ram[index];

    for (genvar k = 0; k < WORDS_PER_LINE; k++) begin : g_lane
      logic [DATA_W-1:0] ram [SETS];
      logic              we;
      logic [DATA_W-1:0] din;

      assign we  = fill_this_way ||
                   (update_word && (hit_way == WAY_BITS'(w)) && (word == WORD_BITS'(k)));
      assign din = fill_line ? mem_resp_rdata[k*DATA_W +: DATA_W] : wdata_q;

      always_ff @(posedge clk) begin
        if (we)
          ram[index] <= din;
      end
      assign data_rd[w][k] = ram[index];
    end
  end

endmodule
