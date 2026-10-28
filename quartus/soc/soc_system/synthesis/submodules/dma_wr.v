`timescale 1ns/1ps
// dma_wr.v -- frame writer: packs the output pixel stream into 64-bit words and writes them through an Avalon-MM master
// (roadmap 3b.6). Single-beat writes, a 16-word FIFO absorbs waitrequest stalls (one word is produced every 8 pixels).
//
// base is sampled at the first pixel (in_sof) of every frame; words go to base, base+8, ... in raster order, so the frame
// image in memory is exactly the pixel order (W*H a multiple of 8). frame_done: one-clock pulse once the last word of
// the frame has been ACCEPTED by the memory (not merely queued). overflow is sticky if the FIFO was full when a word
// had to be pushed (the memory stalled for more than 16 words).
module dma_wr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire        in_eof,
    input  wire [7:0]  in_data,
    input  wire [31:0] base,
    output reg         frame_done,
    output reg         overflow,
    input  wire        clr_overflow,
    // Avalon-MM master
    output wire [31:0] m_address,
    output wire        m_write,
    output wire [63:0] m_writedata,
    output wire [7:0]  m_byteenable,
    input  wire        m_waitrequest
);
    reg [63:0] pk;
    reg [2:0]  pk_cnt;
    reg [31:0] waddr;
    reg        eof_seen;

    // 16-word FIFO (register array)
    reg [63:0] q [0:15];
    reg [4:0]  wp, rp;
    wire [4:0] fill  = wp - rp;
    wire       q_empty = (fill == 0);
    wire       q_full  = (fill == 5'd16);

    wire [63:0] word_now = pk | ({56'd0, in_data} << {pk_cnt, 3'b000});
    wire        push     = in_valid & (pk_cnt == 3'd7);

    assign m_write      = ~q_empty;
    assign m_address    = waddr;
    assign m_writedata  = q[rp[3:0]];
    assign m_byteenable = 8'hFF;
    wire accepted = m_write & ~m_waitrequest;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pk <= 64'd0; pk_cnt <= 3'd0; waddr <= 32'd0; eof_seen <= 1'b0; wp <= 5'd0; rp <= 5'd0;
            frame_done <= 1'b0; overflow <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (clr_overflow) overflow <= 1'b0;
            if (in_valid) begin
                if (in_sof) waddr <= base;
                if (pk_cnt == 3'd7) begin
                    pk <= 64'd0; pk_cnt <= 3'd0;
                    if (q_full) overflow <= 1'b1;
                    else begin q[wp[3:0]] <= word_now; wp <= wp + 1'b1; end
                end else begin
                    pk <= word_now; pk_cnt <= pk_cnt + 1'b1;
                end
                if (in_eof) eof_seen <= 1'b1;
            end
            if (accepted) begin rp <= rp + 1'b1; waddr <= waddr + 32'd8; end
            if (eof_seen && q_empty && !in_valid) begin eof_seen <= 1'b0; frame_done <= 1'b1; end
        end
    end
endmodule
