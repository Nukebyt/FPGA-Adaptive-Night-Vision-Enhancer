`timescale 1ns/1ps
// seq_div.v -- sequential restoring divider: q = floor(num / den), NW cycles after start.
// The controller runs in vertical blanking where time is free, so dividers are sequential and share one instance.
// start: one-clock pulse with num/den valid. done: one-clock pulse when q is valid (q holds until the next start).
// den = 0 gives q = all ones (never used: callers guarantee den > 0).
module seq_div #(
    parameter NW = 64,
    parameter DW = 48
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [NW-1:0] num,
    input  wire [DW-1:0] den,
    output reg           busy,
    output reg           done,
    output reg  [NW-1:0] q
);
    reg [NW-1:0] n;
    reg [DW:0]   rem;
    reg [DW-1:0] d;
    reg [7:0]    cnt;
    wire [DW:0]  rem_sh = {rem[DW-1:0], n[NW-1]};
    wire         ge     = (rem_sh >= {1'b0, d});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; q <= {NW{1'b0}}; n <= {NW{1'b0}}; rem <= {(DW+1){1'b0}}; d <= {DW{1'b0}}; cnt <= 8'd0;
        end else begin
            done <= 1'b0;
            if (start) begin
                n <= num; d <= den; rem <= {(DW+1){1'b0}}; q <= {NW{1'b0}}; cnt <= NW[7:0]; busy <= 1'b1;
            end else if (busy) begin
                rem <= ge ? (rem_sh - {1'b0, d}) : rem_sh;
                q   <= {q[NW-2:0], ge};
                n   <= {n[NW-2:0], 1'b0};
                cnt <= cnt - 1'b1;
                if (cnt == 8'd1) begin busy <= 1'b0; done <= 1'b1; end
            end
        end
    end
endmodule
