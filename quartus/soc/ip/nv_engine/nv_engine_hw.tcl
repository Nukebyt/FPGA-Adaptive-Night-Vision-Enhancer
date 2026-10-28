# nv_engine_hw.tcl -- Platform Designer component for rtl/nv_engine.v (the night-vision video engine).
# Hand-written, fixed HDL (no generation callback), same static-fileset pattern as the CFAR project's cfar_avalon_bridge_hw.tcl.
# Checklist 2.3: `package require -exact qsys <version>` must match, otherwise the component is silently invisible;
# add_fileset takes an EMPTY callback for a static file list.
package require -exact qsys 12.0

set_module_property NAME nv_engine
set_module_property DISPLAY_NAME "Night-Vision Engine"
set_module_property VERSION 1.0
set_module_property GROUP "Night-Vision"
set_module_property DESCRIPTION "Adaptive night-vision video engine: CSR slave, input DMA reader, enhancement core, output DMA writer."
set_module_property AUTHOR "FPGA-Adaptive-Night-Vision"
set_module_property INTERNAL false
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false

# ---- sources (relative to this file: quartus/soc/ip/nv_engine -> repo root is four levels up) ----
set RTL ../../../../rtl
set files [list \
    nv_engine.v nv_core.v nv_temporal.v nv_spatial.v nv_tone.v nv_sharpen.v nv_ctrl.v nv_hist.v nv_noise.v \
    win3x3.v ram_sdp.v seq_div.v vga_timing.v fifo_64to8.v dma_rd.v dma_wr.v nv_csr.v \
    rom/rom_gamma.v rom/rom_log2.v rom/rom_exp2.v rom/rom_recip.v rom/rom_motion.v]

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL nv_engine
foreach f $files { add_fileset_file [file tail $f] VERILOG PATH $RTL/$f }

add_fileset SIM_VERILOG SIM_VERILOG "" ""
set_fileset_property SIM_VERILOG TOP_LEVEL nv_engine
foreach f $files { add_fileset_file [file tail $f] VERILOG PATH $RTL/$f }

# ---- clock and reset ----
add_interface clock clock end
set_interface_property clock ENABLED true
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges NONE
add_interface_port reset rst_n reset_n Input 1

# ---- CSR slave (word addressed, fixed read latency 1, no wait states) ----
add_interface csr avalon end
set_interface_property csr addressUnits WORDS
set_interface_property csr associatedClock clock
set_interface_property csr associatedReset reset
set_interface_property csr bitsPerSymbol 8
set_interface_property csr readLatency 1
set_interface_property csr readWaitTime 0
set_interface_property csr writeWaitTime 0
set_interface_property csr holdTime 0
set_interface_property csr setupTime 0
set_interface_property csr timingUnits Cycles
add_interface_port csr csr_address address Input 8
add_interface_port csr csr_read read Input 1
add_interface_port csr csr_write write Input 1
add_interface_port csr csr_writedata writedata Input 32
add_interface_port csr csr_readdata readdata Output 32

# ---- input DMA master (64-bit, byte addresses, pipelined reads) ----
add_interface rd avalon start
set_interface_property rd addressUnits SYMBOLS
set_interface_property rd associatedClock clock
set_interface_property rd associatedReset reset
set_interface_property rd bitsPerSymbol 8
set_interface_property rd doStreamReads false
set_interface_property rd doStreamWrites false
add_interface_port rd rd_address address Output 32
add_interface_port rd rd_read read Output 1
add_interface_port rd rd_waitrequest waitrequest Input 1
add_interface_port rd rd_readdata readdata Input 64
add_interface_port rd rd_readdatavalid readdatavalid Input 1

# ---- output DMA master ----
add_interface wr avalon start
set_interface_property wr addressUnits SYMBOLS
set_interface_property wr associatedClock clock
set_interface_property wr associatedReset reset
set_interface_property wr bitsPerSymbol 8
set_interface_property wr doStreamReads false
set_interface_property wr doStreamWrites false
add_interface_port wr wr_address address Output 32
add_interface_port wr wr_write write Output 1
add_interface_port wr wr_writedata writedata Output 64
add_interface_port wr wr_byteenable byteenable Output 8
add_interface_port wr wr_waitrequest waitrequest Input 1

# ---- status conduit (LEDs / HEX at the top level) ----
add_interface status conduit end
set_interface_property status associatedClock clock
add_interface_port status st_lg lg Output 16
add_interface_port status st_ready ready Output 1
add_interface_port status st_enabled enabled Output 1
add_interface_port status st_error error Output 1
add_interface_port status st_frames frames Output 32
