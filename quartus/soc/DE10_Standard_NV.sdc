# DE10_Standard_NV.sdc -- constraints for the night-vision SoC design.
# Clocks: CLOCK_50 (board), the 25 MHz PLL output (derive_pll_clocks, checklist 2.2/2.6: without it the whole fabric is silently
# unconstrained), JTAG TCK. HPS DDR3 timing comes from the Qsys-generated hps_sdram SDC through soc_system.qip.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
create_clock -name {altera_reserved_tck} -period 40 {altera_reserved_tck}
set_input_delay  -clock altera_reserved_tck -clock_fall 3 [get_ports altera_reserved_tdi]
set_input_delay  -clock altera_reserved_tck -clock_fall 3 [get_ports altera_reserved_tms]
set_output_delay -clock altera_reserved_tck 3 [get_ports altera_reserved_tdo]

derive_pll_clocks
derive_clock_uncertainty

# human-speed IO
set_false_path -from [get_ports {KEY*}] -to *
set_false_path -from [get_ports {SW*}]  -to *
set_false_path -from * -to [get_ports {LEDR* HEX*}]
