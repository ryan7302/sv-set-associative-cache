# Timing constraints for synthesising cache.sv on its own (out-of-context).

# 100 MHz clock: one clock period = 10 ns.
create_clock -period 10.000 -name clk [get_ports clk]

# Out-of-context: tell Vivado the clock would come from a global clock buffer
# in the full chip (removes Timing 38-242 / Route 35-197).
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# I/O timing budget (removes TIMING-18 and makes the I/O paths timed).
# Inputs come from registers in the CPU and memory controller on the same chip,
# clocked through the same global clock tree as this block:
#   min 2.0 ns = clock-tree delay to the source register (~1.5 ns, the same as
#                this block sees) + clock-to-output (~0.5 ns)     -> hold check
#   max 3.0 ns = the above + up to 1 ns of logic and routing     -> setup check
# (With a min of 0.5 ns the hold check wrongly assumed the source register's
#  clock arrives 1.5 ns earlier than ours, giving false hold violations.)
set_input_delay  -clock clk -max 3.000 [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set_input_delay  -clock clk -min 2.000 [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]

# Outputs: the receiving logic may use up to 2 ns before its register (max),
# and needs at least 0.5 ns of hold margin (min). Separate values avoid XDCH-2.
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]

# rst_n is an asynchronous reset: not timed as a normal data input.
set_false_path -from [get_ports rst_n]
