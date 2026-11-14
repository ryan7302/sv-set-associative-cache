# Timing constraints for synthesising cache.sv on its own (out-of-context).

# 100 MHz clock: one clock period = 10 ns.
create_clock -period 10.000 -name clk [get_ports clk]

# Out-of-context: tell Vivado the clock would come from a global clock buffer
# in the full chip (removes Timing 38-242 / Route 35-197).
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# I/O timing budget (removes TIMING-18 and makes the I/O paths timed).
# Assumption: in a full system the cache connects to registers in the CPU and
# the memory controller on the same chip, and each side may use up to 2 ns of
# the 10 ns clock period for its own logic and routing (max, for setup), and
# at least 0.5 ns (min, for hold). Separate min/max values avoid XDCH-2.
set_input_delay  -clock clk -max 2.000 [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set_input_delay  -clock clk -min 0.500 [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]

# rst_n is an asynchronous reset: not timed as a normal data input.
set_false_path -from [get_ports rst_n]
