`timescale 1ns/1ps
// fifo_64to8.v -- single-clock FIFO, 64-bit write side, 8-bit (byte) read side, little-endian byte order
// (byte 0 = bits [7:0] of the first word, so a memory image read as 64-bit words streams out in address order).
//
// Write: wr_en with wr_data when !full. Read: rd_en pops one byte when !empty; rd_data is valid in the same cycle as !empty
// (registered state, no combinational path from rd_en). 1 byte per clock sustained: the next word is prefetched into nxt while
// cur is being shifted out (a refill needs 3 clocks, a word lasts 8).
// lvl counts words written minus words fully consumed (a partly consumed word still counts), so the DMA credit check
// (outstanding + lvl <= 2**AW - 4) can never overflow the RAM. flush resets everything.
module fifo_64to8 #(
    parameter AW = 8                       // 2**AW words of storage
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          flush,
    input  wire          wr_en,
    input  wire [63:0]   wr_data,
    output wire [AW+1:0] lvl,
    input  wire          rd_en,
    output wire [7:0]    rd_data,
    output wire          empty
);
    reg  [AW:0]   wr_ptr, rd_ptr;
    reg  [AW+1:0] count;                   // lvl
    reg  [63:0]   cur, nxt;
    reg           cur_valid, nxt_valid, rd_pend;
    reg  [2:0]    bcnt;
    wire [63:0]   rdata;
    wire [AW:0]   ram_cnt = wr_ptr - rd_ptr;

    ram_sdp #(.DW(64), .AW(AW), .DEPTH(1 << AW)) ram (
        .clk(clk), .we(wr_en), .waddr(wr_ptr[AW-1:0]), .wdata(wr_data), .raddr(rd_ptr[AW-1:0]), .rdata(rdata));

    assign rd_data = cur[7:0];
    assign empty   = ~cur_valid;
    assign lvl     = count;

    wire word_done = cur_valid & rd_en & (bcnt == 3'd7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; rd_ptr <= 0; count <= 0; cur <= 64'd0; nxt <= 64'd0; cur_valid <= 1'b0; nxt_valid <= 1'b0;
            rd_pend <= 1'b0; bcnt <= 3'd0;
        end else if (flush) begin
            wr_ptr <= 0; rd_ptr <= 0; count <= 0; cur_valid <= 1'b0; nxt_valid <= 1'b0; rd_pend <= 1'b0; bcnt <= 3'd0;
        end else begin
            if (wr_en) wr_ptr <= wr_ptr + 1'b1;
            count <= count + {{(AW+1){1'b0}}, wr_en} - {{(AW+1){1'b0}}, word_done};

            // prefetch the next word into nxt (RAM read latency 1)
            rd_pend <= 1'b0;
            if (!nxt_valid && !rd_pend && ram_cnt != 0) begin
                rd_pend <= 1'b1;
                rd_ptr  <= rd_ptr + 1'b1;
            end
            if (rd_pend) begin nxt <= rdata; nxt_valid <= 1'b1; end

            // byte shifter
            if (cur_valid) begin
                if (rd_en) begin
                    cur <= {8'd0, cur[63:8]};
                    bcnt <= bcnt + 1'b1;
                    if (bcnt == 3'd7) begin
                        bcnt <= 3'd0;
                        if (nxt_valid) begin cur <= nxt; nxt_valid <= 1'b0; end
                        else cur_valid <= 1'b0;
                    end
                end
            end else if (nxt_valid) begin
                cur <= nxt; cur_valid <= 1'b1; nxt_valid <= 1'b0; bcnt <= 3'd0;
            end
        end
    end
endmodule
