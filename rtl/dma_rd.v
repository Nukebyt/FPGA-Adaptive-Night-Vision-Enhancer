`timescale 1ns/1ps
// dma_rd.v -- linear frame reader: NWORDS 64-bit words from an Avalon-MM master into the byte FIFO (roadmap 3b.3).
//
// start (one clock pulse) with base address: reads base, base+8, ... NWORDS words. Single-beat pipelined reads: a new read is
// presented whenever the FIFO credit allows (outstanding + lvl <= LIMIT), regardless of data still in flight (Avalon
// readdatavalid pipelining). m_read/m_address depend only on registers and the FIFO level, never on waitrequest/readdata.
// done: one-clock pulse when the last word has been written into the FIFO. busy while a frame is being fetched.
// The master clock equals the datapath clock (25 MHz): no CDC anywhere in the video path.
module dma_rd #(
    parameter NWORDS = 38400,           // W*H/8
    parameter AW     = 8,               // FIFO depth 2**AW words
    parameter LIMIT  = 252              // 2**AW - 4
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [31:0]   base,
    input  wire [AW+1:0] lvl,
    output reg           busy,
    output reg           done,
    output wire          fifo_wr_en,
    output wire [63:0]   fifo_wr_data,
    // Avalon-MM master (64-bit, byte addresses)
    output wire [31:0]   m_address,
    output wire          m_read,
    input  wire          m_waitrequest,
    input  wire [63:0]   m_readdata,
    input  wire          m_readdatavalid
);
    reg [31:0] addr;
    reg [16:0] issued, received;
    reg [8:0]  outstanding;

    wire can_issue = busy && (issued < NWORDS) && ((outstanding + lvl) <= LIMIT);
    assign m_read     = can_issue;
    assign m_address  = addr;
    wire   accepted   = m_read & ~m_waitrequest;
    assign fifo_wr_en   = m_readdatavalid & busy;
    assign fifo_wr_data = m_readdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr <= 32'd0; issued <= 0; received <= 0; outstanding <= 0; busy <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                addr <= base; issued <= 0; received <= 0; outstanding <= 0; busy <= 1'b1;
            end else if (busy) begin
                if (accepted) begin addr <= addr + 32'd8; issued <= issued + 1'b1; end
                outstanding <= outstanding + {8'd0, accepted} - {8'd0, m_readdatavalid};
                if (m_readdatavalid) begin
                    received <= received + 1'b1;
                    if (received == NWORDS - 1) begin busy <= 1'b0; done <= 1'b1; end
                end
            end
        end
    end
endmodule
