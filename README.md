# Direct-Mapped Cache in SystemVerilog

A parameterised direct-mapped cache with a self-checking, constrained-random SystemVerilog testbench. Simulated in Vivado XSim and synthesised for an Artix-7 FPGA.

![Tests](https://img.shields.io/badge/tests-1012%20accesses%20passing-brightgreen) ![Timing](https://img.shields.io/badge/timing-met%20at%20100%20MHz-brightgreen) ![Tool](https://img.shields.io/badge/Vivado-2026.1-blue)

---

## 1. Specification

### Parameters (defaults)

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_W` | 32 | Byte address width |
| `DATA_W` | 32 | Word width (bits) |
| `WORDS_PER_LINE` | 4 | Words per cache line (16-byte lines) |
| `NUM_LINES` | 64 | Number of lines (1 KiB of data) |
| `MEM_LATENCY` | 4 | Memory model delay in clock cycles |

### Address breakdown (defaults)

| Bits | Field | Width | Purpose |
|---|---|---|---|
| [31:10] | Tag | 22 | Identifies which memory block is stored in the line |
| [9:4] | Index | 6 | Selects one of the 64 lines |
| [3:2] | Word offset | 2 | Selects one of the 4 words in the line |
| [1:0] | Byte offset | 2 | Always `00`: word-aligned accesses only |

Each line stores: a valid bit, a 22-bit tag, and 4 × 32-bit words.

### Policies

| Policy | Choice | Reason |
|---|---|---|
| Mapping | Direct-mapped | Simplest; one possible line per address |
| Write hit | Write-through | Cache and memory always agree; no dirty bits |
| Write miss | No-write-allocate | Write goes to memory only; the line is not loaded |
| Read miss | Allocate | Fetch the whole 16-byte line, then return the word |
| Replacement | None needed | Direct-mapped: the indexed line is overwritten |


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
| COMPARE | Read the indexed line; hit = valid && tag match | Read hit → RESPOND; read miss → ALLOCATE; write → WRITE_THROUGH |
| ALLOCATE | Request the line from memory; on response, fill the line, set valid and tag | RESPOND |
| WRITE_THROUGH | Update the cached word if hit; write the word to memory; wait for ack | RESPOND |
| RESPOND | Pulse `cpu_resp_valid` with read data | IDLE |

Measured latency (see Results): a read hit responds 1 cycle after acceptance is seen by the testbench; read misses take 7 cycles with a memory latency of 4.

### Performance counters

`read_hits`, `read_misses`, `writes`.

---

## 2. Verification plan

Self-checking testbench `tb_cache.sv`:

- **Reference model:** an associative array holds the expected value of every address written. Every read response is compared with it.
- **Directed tests:** cold miss, read hit, conflict eviction (two addresses with the same index, different tags), write hit, write miss (line not allocated), write then read back.
- **Random test:** 1,000 constrained-random reads and writes over a small address range, so hits, misses and evictions all occur.
- **Memory traffic checks:** a read hit makes no memory request; a read miss and every write make exactly one.
- **Assertions (SVA):** `cpu_req_ready` drops after a request is accepted; `cpu_resp_valid` is a one-cycle pulse; ready and response are never high together.
- **Report:** checks passed/failed, hit rate.

---

## 3. Results

### Verification (Vivado XSim)

| Item | Result |
|---|---|
| Directed tests | 12 / 12 passing |
| Random transactions | 1,000 (about 70% reads, 30% writes), all passing |
| Every read checked against the reference memory | yes |
| Every read checked for expected hit/miss | yes, plus the design's own counters |
| Read hit latency | 1 cycle after acceptance |
| Read miss latency | 7 cycles (memory latency 4) |
| Random-test hit rate | 23.8% (random addresses over 4 KiB with a 1 KiB cache: about 25% expected) |

The testbench was checked by deliberately breaking the design: ignoring the valid bit is caught by the first directed test (a false hit on an empty cache), and not updating the cache on a write hit is caught by the read-after-write test.

The same testbench also runs in Verilator as a second opinion.

### Synthesis and implementation (Artix-7 xc7a35t, 100 MHz, out-of-context)

| Metric | First version | Final version |
|---|---|---|
| Slice LUTs | 10,986 (53%) | **400 (1.9%)** |
| LUT as memory (distributed RAM) | 0 | 150 |
| Registers | 8,546 | **263** |
| Worst negative slack (setup) | not measured | **+2.652 ns** (about 136 MHz maximum) |
| Worst hold slack | not measured | +0.085 ns |

**What changed between the two versions.** In the first version the data array was written in two different ways (a whole line on a fill, one word on a write hit) and read in the same cycle. FPGA RAM cannot do that, so Vivado built all 8,192 data bits from flip-flops plus large multiplexers. The data array is now four separate 64 × 32-bit RAMs, one per word position. Each has a single write port: on a line fill all four write their own word; on a write hit only the lane selected by the word offset writes. Vivado maps each lane, and the 64 × 22-bit tag array, to distributed RAM: 4 × 32 + 22 = 150 LUT RAMs.

The critical path runs from the request address register through the tag comparison to the RAM write enable (5 logic levels, 6.7 ns).

The cache is synthesised out-of-context because, as a standalone block, it has far more I/O signals than the device has pins; in a real system it would sit between a processor and a memory controller on the same chip.

---

## 4. Repository structure

```
sv-direct-mapped-cache/
├── rtl/cache.sv              The cache (synthesisable design)
├── tb/main_mem.sv            Main memory model (simulation only)
├── tb/tb_cache.sv            Self-checking testbench for the cache
├── tb/tb_mem.sv              Small test for the memory model
├── tb/tb_hello.sv            SystemVerilog feature check for the simulator
├── constr/cache_timing.xdc   100 MHz clock constraint
└── README.md
```

## 5. How to run

1. Create a Vivado project (part xc7a35tcpg236-1). Add `rtl/cache.sv` as a design source, the `tb/` files as simulation sources and `constr/cache_timing.xdc` as a constraint. Do not copy the files into the project.
2. Set `tb_cache` as the simulation top, run behavioural simulation, then **Run All**. The console ends with `==== CACHE: ALL TESTS PASSED ====` and the hit-rate summary.
3. For resource and timing numbers: set synthesis option `-mode out_of_context` (Settings → Synthesis → More Options), run synthesis and implementation, then open the timing summary.

## 6. Possible extensions

- Write-back with write-allocate (dirty bit per line, WRITE_BACK state).
- 2-way set-associative with LRU replacement, to reduce conflict misses.
- Block RAM version with a registered read (one extra cycle on a hit).
- Hardware demo on a Basys 3: block-RAM memory, a request generator and pass/fail on the LEDs.
