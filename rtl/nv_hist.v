`timescale 1ns/1ps
// nv_hist.v -- 256-bin luma histogram of the raw input frame (roadmap 4.1).
// Read-modify-write on one RAM. Hazard: two pixels of the same bin in consecutive clocks. The second read happens on the
// same edge as the first write and returns the OLD count, so the previous stage-1 result is forwarded
// (checklist 1.2 / roadmap 4.1). Pixels further apart than one clock need no forwarding.
//
// The controller owns the RAM while it scans (scan = 1): it reads bin by bin and clears each bin as it goes, so the
// next frame starts from zeros without a second bank. After reset and after clear_all the module zeroes all 256 bins
// itself (RAM contents are not guaranteed zero on power-up), taking 256 clocks, during which pixels must not arrive.
//
// Latency: a pixel is counted 2 clocks after in_valid; the count of a frame is final 2 clocks after its last pixel.
module nv_hist (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear_all,
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        scan,
    input  wire [7:0]  h_raddr,
    output wire [18:0] h_rdata,
    input  wire        h_clr_en,
    input  wire [7:0]  h_clr_addr,
    output reg         clearing
);
    reg        v1;
    reg [7:0]  a1;
    reg        v_prev;
    reg [7:0]  a_prev;
    reg [18:0] n_prev;
    reg [8:0]  clr_i;

    wire [18:0] rdata;
    wire [18:0] base = (v_prev && (a_prev == a1)) ? n_prev : rdata;
    wire [18:0] newc = base + 19'd1;

    wire        we    = clearing ? 1'b1 : scan ? h_clr_en : v1;
    wire [7:0]  waddr = clearing ? clr_i[7:0] : scan ? h_clr_addr : a1;
    wire [18:0] wdata = (clearing || scan) ? 19'd0 : newc;
    wire [7:0]  raddr = scan ? h_raddr : in_data;

    ram_sdp #(.DW(19), .AW(8), .DEPTH(256)) ram (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .raddr(raddr), .rdata(rdata));
    assign h_rdata = rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; a1 <= 8'd0; v_prev <= 1'b0; a_prev <= 8'd0; n_prev <= 19'd0; clearing <= 1'b1; clr_i <= 9'd0;
        end else begin
            v1 <= in_valid & ~scan & ~clearing;
            a1 <= in_data;
            v_prev <= v1 & ~scan & ~clearing;
            a_prev <= a1;
            n_prev <= newc;
            if (clear_all) begin clearing <= 1'b1; clr_i <= 9'd0; end
            else if (clearing) begin
                clr_i <= clr_i + 1'b1;
                if (clr_i == 9'd255) clearing <= 1'b0;
            end
        end
    end
endmodule
