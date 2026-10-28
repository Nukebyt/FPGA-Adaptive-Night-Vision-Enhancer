# 25 MHz datapath clock (VGA pixel clock). Tighten PERIOD_NS to find the real limit; keep the check_sta rule that the clock
# name appears in every slack table.
create_clock -name clk -period 40.000 [get_ports clk]
derive_clock_uncertainty
