`timescale 1ns/1ps
// hex7seg.v -- hex digit to DE10-Standard 7-segment, ACTIVE LOW (0 = lit).
// Bit order [0]=a(top) [1]=b [2]=c [3]=d(bottom) [4]=e [5]=f [6]=g(middle).
// Polarity and bit order were confirmed on this board by the CFAR project's board_check design.
module hex7seg (
    input  wire [3:0] d,
    output reg  [6:0] seg_n
);
    always @(*) begin
        case (d)
            4'h0: seg_n = 7'b1000000;
            4'h1: seg_n = 7'b1111001;
            4'h2: seg_n = 7'b0100100;
            4'h3: seg_n = 7'b0110000;
            4'h4: seg_n = 7'b0011001;
            4'h5: seg_n = 7'b0010010;
            4'h6: seg_n = 7'b0000010;
            4'h7: seg_n = 7'b1111000;
            4'h8: seg_n = 7'b0000000;
            4'h9: seg_n = 7'b0010000;
            4'hA: seg_n = 7'b0001000;
            4'hB: seg_n = 7'b0000011;
            4'hC: seg_n = 7'b1000110;
            4'hD: seg_n = 7'b0100001;
            4'hE: seg_n = 7'b0000110;
            4'hF: seg_n = 7'b0001110;
        endcase
    end
endmodule
