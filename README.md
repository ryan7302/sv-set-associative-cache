# Set-Associative Cache in SystemVerilog

A parameterised cache in SystemVerilog: direct-mapped (`WAYS = 1`) or set-associative with LRU replacement (`WAYS = 2, 4, 8`; default 4). Verified with a self-checking, constrained-random testbench in Vivado XSim and implemented on an Artix-7 FPGA.

> Branch `set-associative`. The original direct-mapped version is on `main`.

![Tests](https://img.shields.io/badge/tests-1412%20accesses%20passing-brightgreen) ![Timing](https://img.shields.io/badge/timing-met%20at%20100%20MHz-brightgreen) ![Tool](https://img.shields.io/badge/Vivado-2026.1-blue)

---

## 1. Specification

### Parameters (defaults)

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_W` | 32 | Byte address width |
| `DATA_W` | 32 | Word width (bits) |
| `WORDS_PER_LINE` | 4 | Words per cache line (16-byte lines) |
| `NUM_LINES` | 64 | Total number of lines (1 KiB of data) |
| `WAYS` | 4 | Lines per set: 1 = direct-mapped, 2/4/8 = set-associative. Sets = `NUM_LINES / WAYS` |
| `MEM_LATENCY` | 4 | Memory model delay in clock cycles |

### Address breakdown

| Field | Direct-mapped (`WAYS = 1`, 64 sets) | 4-way (`WAYS = 4`, 16 sets) | Purpose |
|---|---|---|---|
| Tag | [31:10], 22 bits | [31:8], 24 bits | Identifies which memory block is stored in a line |
| Set index | [9:4], 6 bits | [7:4], 4 bits | Selects the set |
| Word offset | [3:2] | [3:2] | Selects one of the 4 words in the line |
| Byte offset | [1:0] = `00` | [1:0] = `00` | Word-aligned accesses only |

Each line stores a valid bit, a tag and 4 × 32-bit words. Fewer sets means fewer index bits, so the tag grows.

### Policies

| Policy | Choice | Reason |
|---|---|---|
| Mapping | `WAYS`-way set-associative | An address can go in any of the `WAYS` lines of its set |
| Write hit | Write-through | Cache and memory always agree; no dirty bits |
| Write miss | No-write-allocate | Write goes to memory only; the line is not loaded |
| Read miss | Allocate | Fetch the whole 16-byte line, then return the word |
| Replacement | Empty way first, then LRU | Least recently used way is evicted; read hits, write hits and fills update the LRU order |


### CPU-side interface

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `cpu_req_valid` | in | 1 | CPU presents a request |
| `cpu_req_ready` | out | 1 | Cache can accept a request (FSM in IDLE) |
| `cpu_req_we` | in | 1 | 1 = write, 0 = read |
| `cpu_req_addr` | in | 32 | Byte address (word-aligned) |
| `cpu_req_wdata` | in | 32 | Write data |
| `cpu_resp_valid` | out | 1 | One-cycle pulse: request complete |
| `cpu_resp_rdata` | out | 32 | Read data (valid with `cpu_resp_valid` on reads) |

A request is accepted on a clock edge where `cpu_req_valid && cpu_req_ready`. One request is handled at a time.

### Memory-side interface

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `mem_req_valid` | out | 1 | Cache presents a memory request |
| `mem_req_ready` | in | 1 | Memory can accept a request |
| `mem_req_we` | out | 1 | 1 = word write, 0 = line read |
| `mem_req_addr` | out | 32 | Line address for reads, word address for writes |
| `mem_req_wdata` | out | 32 | Write data |
| `mem_resp_valid` | in | 1 | One-cycle pulse: read data ready or write acknowledged |
| `mem_resp_rdata` | in | 128 | Full line for reads |

### Controller state machine

| State | Action | Next |
|---|---|---|
| IDLE | `cpu_req_ready = 1`; register the request when accepted | COMPARE |
| COMPARE | Compare the tag with every way of the set in parallel; hit = any way valid && tag match | Read hit → RESPOND; read miss → ALLOCATE; write → WRITE_THROUGH |
| ALLOCATE | Request the line from memory; on response, fill the victim way (empty, else LRU), set valid and tag | RESPOND |
| WRITE_THROUGH | Update the cached word in the hit way, if any; write the word to memory; wait for ack | RESPOND |
| RESPOND | Pulse `cpu_resp_valid` with read data | IDLE |

Measured latency (see Results): a read hit responds 1 cycle after acceptance is seen by the testbench; read misses take 7 cycles with a memory latency of 4.

### Performance counters

`read_hits`, `read_misses`, `writes`.

---

## 2. Verification plan

Self-checking testbench `tb_cache.sv`:

- **Reference model:** an associative array holds the expected value of every address written, and a software copy of the sets, ways and LRU order predicts whether each access should hit. Every read response and every hit/miss is compared with it.
- **Directed tests:** cold miss, read hit, conflict eviction (two addresses with the same index, different tags), write hit, write miss (line not allocated), write then read back.
- **Random test:** 1,000 constrained-random reads and writes over 4 KiB, so hits, misses and evictions all occur.
- **Conflict test:** 400 reads from four lines that map to the same set in a direct-mapped cache (addresses 1 KiB apart). This separates conflict misses from capacity misses.
- **Memory traffic checks:** a read hit makes no memory request; a read miss and every write make exactly one.
- **Assertions (SVA):** `cpu_req_ready` drops after a request is accepted; `cpu_resp_valid` is a one-cycle pulse; ready and response are never high together.
- **Report:** checks passed/failed, hit rate.

---

## 3. Results

### Direct-mapped vs 4-way

| | 1-way (direct-mapped) | 4-way set-associative |
|---|---|---|
| Sets × ways | 64 × 1 | 16 × 4 |
| **Verification** (12 directed + 1,000 random + 400 conflict accesses) | all passing | all passing |
| Hit rate, random reads over 4 KiB | about 23% | about 24% |
| **Hit rate, conflict-heavy reads** | **about 22%** | **99%** |
| Read hit / miss latency | 1 / 7 cycles | 1 / 7 cycles |
| Slice LUTs | **400** (1.9%) | **1,217** (5.9%) |
| — of which distributed RAM | 150 | 608 |
| Registers | 263 | 409 |
| Setup slack at 100 MHz (WNS) | **+2.270 ns** | **+0.303 ns** |
| Hold slack (WHS) | +0.051 ns | +0.071 ns |
| Logic levels on worst path | 5 | 7 |
| Methodology warnings | 0 | 0 |

Implementation: Artix-7 xc7a35t, out-of-context, 100 MHz, constraints in `constr/cache_timing.xdc`. Verification: 1-way fully in Vivado XSim; 4-way directed tests in XSim and the full run (with the hit rates above) in Verilator using the same testbench.

### What the comparison shows

- **Conflict misses vs capacity misses.** In the conflict test, four lines fight over one line of the direct-mapped cache and keep evicting each other (about 22% hits, roughly the chance of reading the same line twice in a row). With 4 ways all four fit, and after the first four misses every read hits. With random addresses over 4 KiB, associativity makes almost no difference: a 1 KiB cache can only hold a quarter of the data, so those misses come from capacity, not conflicts.
- **Cost in logic.** 4-way compares four tags in parallel, chooses the hit way, and keeps LRU state per set, so it uses about 3× the LUTs.
- **Cost in timing.** The critical path becomes request address → four tag comparisons → hit-way select → RAM write enable: 7 logic levels and 9.1 ns, leaving 0.3 ns of slack at 100 MHz (direct-mapped: 5 levels, 2.3 ns of slack). An 8-way version would probably need pipelining to meet 100 MHz on this device.
- **RAM efficiency.** The same 1 KiB of data uses 608 LUT RAMs in 4-way against 150 in direct-mapped. Each LUT RAM holds 64 entries, but a 4-way set array has only 16, so most of each LUT RAM is unused. A block-RAM implementation would avoid this.

### How the direct-mapped version was made small

The first version wrote the data array in two different ways (a whole line on a fill, one word on a write hit) and read it in the same cycle. FPGA RAM cannot do that, so Vivado built all 8,192 data bits from flip-flops: 10,986 LUTs (53% of the device) and 8,546 registers. The data is now stored as separate 32-bit RAMs, one per word position (and, in the set-associative version, one set per way). Each has a single write port: a line fill writes all four lanes of the victim way; a write hit writes only the lane selected by the word offset. Vivado maps each to distributed RAM, bringing the direct-mapped cache down to 400 LUTs.

### Testbench quality

The testbench was checked by deliberately breaking the design. It catches: a hit that ignores the valid bit (false hit on an empty cache), a write hit that does not update the cache (stale read), and a replacement policy that always evicts way 0 instead of the LRU way (a predicted miss turns into a hit).

### Constraints and remaining warnings

`constr/cache_timing.xdc` sets a 100 MHz clock from a global clock buffer, and input/output delays that model the cache sitting between registers in a CPU and a memory controller on the same chip. Inputs: max 3.0 ns (setup), min 2.0 ns (hold: about 1.5 ns of shared clock tree plus 0.5 ns clock-to-output at the sending register). Outputs: max 2.0 ns, min 0.5 ns. A first attempt used a 0.5 ns input minimum; that ignored the sending register's own clock-tree delay and produced false hold violations, which is why the reasoning is written into the constraint file.

Synthesis and methodology reports have no warnings. The remaining implementation warnings are inherent to out-of-context implementation of a block without its surrounding design: no partition pin locations (Route 35-198) and connectivity DRCs that need the full chip (DRC 23-814, Constraints 18-8777).

The cache is synthesised out-of-context because, as a standalone block, it has far more I/O signals than the device has pins; in a real system it would sit between a processor and a memory controller on the same chip.

---

## 4. Repository structure

```
sv-direct-mapped-cache/
├── rtl/cache.sv              The cache (synthesisable design)
├── tb/main_mem.sv            Main memory model (simulation only)
├── tb/tb_cache.sv            Self-checking testbench for the cache
├── tb/tb_mem.sv              Small test for the memory model
├── constr/cache_timing.xdc   100 MHz clock constraint
└── README.md
```

## 5. How to run

1. Create a Vivado project (part xc7a35tcpg236-1). Add `rtl/cache.sv` as a design source, `tb/tb_cache.sv`, `tb/main_mem.sv` and `tb/tb_mem.sv` as simulation sources, and `constr/cache_timing.xdc` as a constraint. Do not copy the files into the project.
2. Set `tb_cache` as the simulation top, run behavioural simulation, then **Run All**. The console ends with the configuration, hit rates per phase and `==== CACHE: ALL TESTS PASSED ====`.
3. To test another associativity, add `-generic_top WAYS=1` (or 2, 4, 8) under Simulation settings → Elaboration → More Options.
4. For resource and timing numbers: add `-mode out_of_context` (and optionally `-generic WAYS=1`) under Synthesis settings → More Options, run synthesis and implementation, then open the timing summary.

## 6. Possible extensions

- Write-back with write-allocate (dirty bit per line, WRITE_BACK state).
- Pipelined lookup (tag compare in one stage, data select in the next) for higher associativity at 100 MHz and above.
- Block RAM version with a registered read, to store the data efficiently at high associativity.
- Pseudo-LRU (tree) replacement, which needs fewer state bits than true LRU at 8 ways.
- Hardware demo on a Basys 3: block-RAM memory, a request generator and pass/fail on the LEDs.
