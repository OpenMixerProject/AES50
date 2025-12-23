# PLL Constraints
#################
create_clock -period 10.00 CLK_100M
create_clock -period 12.50 CLK_80M
create_clock -period 20.00 CLK_50M


#create_clock -period <USER_PERIOD> [get_ports {pll_core_clkin0}]
create_clock -period 20.00 [get_ports {APLL_MCLK}]
create_clock -period 40.00 [get_ports {CLK_25M}]

set_max_delay -from CLK_100M -to CLK_50M 10.00
set_max_delay -from CLK_50M -to CLK_100M 10.00
