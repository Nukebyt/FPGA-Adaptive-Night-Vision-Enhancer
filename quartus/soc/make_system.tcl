# make_system.tcl -- edit the proven CFAR/GHRD Platform Designer system into the night-vision system.
# Run:  qsys-script --script=make_system.tcl      (in quartus/soc, after copying soc_system.qsys from the reference)
# Changes: clk_0 = 25 MHz (one clock for the whole fabric: no CDC in the video path); cfar_bridge_0 removed;
# nv_engine_0 added: CSR slave on the lightweight bridge path at 0x10000 (and on the JTAG master for System Console),
# both DMA masters on the HPS F2H SDRAM port 0; the engine's status conduit is exported for LEDs/HEX.
package require -exact qsys 12.0

load_system soc_system.qsys

remove_instance cfar_bridge_0
foreach i [get_interfaces] { if {[string match cfar_bridge_0* $i]} { remove_interface $i } }

add_instance nv_engine_0 nv_engine
add_connection clk_0.clk nv_engine_0.clock clock
add_connection clk_0.clk_reset nv_engine_0.reset reset

add_connection mm_bridge_0.m0 nv_engine_0.csr avalon
set_connection_parameter_value mm_bridge_0.m0/nv_engine_0.csr baseAddress {0x10000}
add_connection fpga_only_master.master nv_engine_0.csr avalon
set_connection_parameter_value fpga_only_master.master/nv_engine_0.csr baseAddress {0x10000}

add_connection nv_engine_0.rd hps_0.f2h_sdram0_data avalon
set_connection_parameter_value nv_engine_0.rd/hps_0.f2h_sdram0_data baseAddress {0x0000}
add_connection nv_engine_0.wr hps_0.f2h_sdram0_data avalon
set_connection_parameter_value nv_engine_0.wr/hps_0.f2h_sdram0_data baseAddress {0x0000}

add_interface nv_status conduit end
set_interface_property nv_status EXPORT_OF nv_engine_0.status

set_instance_parameter_value clk_0 clockFrequency {25000000}
set_instance_parameter_value clk_0 clockFrequencyKnown {true}

save_system soc_system.qsys
