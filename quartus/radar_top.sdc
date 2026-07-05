# radar_top.sdc — timing constraints for analysis (periods in ns)

# 50 MHz board crystal
create_clock -name {CLOCK_50} -period 20.000 [get_ports {CLOCK_50}]

# audio bit clock - set to 64 overbuffer setting
# 64 × 96,000 Hz = 6.144 MHz → period = 162.76 ns
# This clock comes from the WM8731 (asynchronous to CLOCK_50).
# setup for automatic analysis of i2s_rx's synchronisers.
create_clock -name {AUD_BCLK} -period 162.760 [get_ports {AUD_BCLK}]

# create clock constraints from ALTPLL
derive_pll_clocks

# I2C pins change at 100 kHz driven by a state machine — not a clock, not
# timing-critical in the same sense. Tell TimeQuest not to analyse these paths.
set_false_path -from [get_clocks {CLOCK_50}] -to [get_ports {I2C_SCLK I2C_SDAT}]

# tell timing performance analyzer to not bother synchronising the clocks (handled in i2s_rx)
set_clock_groups -asynchronous \
    -group [get_clocks {CLOCK_50}] \
    -group [get_clocks {AUD_BCLK}]

