`timescale 1ns/1ps
// rom_tb.v -- every generated ROM module must return exactly the words in its .hex file, one clock after addr.
// Run from the repository root (hex paths are relative to it). Verdict: "RESULT: PASS" / "RESULT: FAIL".
module rom_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    integer errors = 0, i;
    reg [9:0] a_gamma = 0; wire [7:0]  d_gamma;
    reg [7:0] a_log2 = 0;  wire [12:0] d_log2;
    reg [7:0] a_exp2 = 0;  wire [16:0] d_exp2;
    reg [3:0] a_recip = 0; wire [16:0] d_recip;
    reg [5:0] a_motion = 0; wire [8:0] d_motion;
    rom_gamma  u0 (.clk(clk), .addr(a_gamma),  .data(d_gamma));
    rom_log2   u1 (.clk(clk), .addr(a_log2),   .data(d_log2));
    rom_exp2   u2 (.clk(clk), .addr(a_exp2),   .data(d_exp2));
    rom_recip  u3 (.clk(clk), .addr(a_recip),  .data(d_recip));
    rom_motion u4 (.clk(clk), .addr(a_motion), .data(d_motion));
    reg [7:0]  m_gamma  [0:1023];
    reg [15:0] m_log2   [0:255];
    reg [19:0] m_exp2   [0:255];
    reg [19:0] m_recip  [0:9];
    reg [11:0] m_motion [0:63];
    initial begin
        $readmemh("rtl/rom/gamma_rom.hex", m_gamma);
        $readmemh("rtl/rom/log2_rom.hex", m_log2);
        $readmemh("rtl/rom/exp2_rom.hex", m_exp2);
        $readmemh("rtl/rom/recip_rom.hex", m_recip);
        $readmemh("rtl/rom/motion_rom.hex", m_motion);
        for (i = 0; i < 1024; i = i + 1) begin
            a_gamma = i; a_log2 = i; a_exp2 = i; a_recip = i; a_motion = i;
            @(posedge clk); @(posedge clk); #1;
            if (d_gamma !== m_gamma[i]) begin errors = errors + 1; if (errors < 6) $display("gamma %0d: %0d vs %0d", i, d_gamma, m_gamma[i]); end
            if (i < 256 && d_log2 !== m_log2[i]) begin errors = errors + 1; if (errors < 6) $display("log2 %0d", i); end
            if (i < 256 && d_exp2 !== m_exp2[i]) begin errors = errors + 1; if (errors < 6) $display("exp2 %0d", i); end
            if (i < 10 && d_recip !== m_recip[i]) begin errors = errors + 1; if (errors < 6) $display("recip %0d", i); end
            if (i < 64 && d_motion !== m_motion[i]) begin errors = errors + 1; if (errors < 6) $display("motion %0d", i); end
        end
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errors=%0d)", errors);
        $finish;
    end
endmodule
