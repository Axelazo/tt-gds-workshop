
`default_nettype none
module tt_um_vga_example (
    input wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input wire ena, clk, rst_n
);
    assign uio_out=8'd0;
    assign uio_oe=8'd0;
    wire _unused_ok=&{1'b0,uio_in};

    // 800 clocks/line is divisible by 16. Low horizontal bits also tag
    // the logical row currently at the circulating board's output.
    reg [9:0] hpos,vpos;
    wire [3:0] phase=hpos[3:0];
    wire frame_tick=hpos==10'd0 && vpos==10'd480;
    wire video_on=hpos<10'd640 && vpos<10'd480;
    reg hs,vs,red,green,blue;
    wire lit,white,game_over;
    assign uo_out={hs,blue,green,red,vs,blue,green,red};
    always @(posedge clk) begin
        if (!rst_n) begin
            hpos<=0; vpos<=0; hs<=1; vs<=1;
            red<=0; green<=0; blue<=0;
        end else begin
            if (hpos==10'd799) begin
                hpos<=0;
                vpos<=vpos==10'd524 ? 10'd0 : vpos+10'd1;
            end else hpos<=hpos+10'd1;
            hs<=!(hpos>=10'd656 && hpos<10'd752);
            vs<=!(vpos>=10'd490 && vpos<10'd492);
            red<=video_on && (white || (game_over && lit));
            green<=video_on && lit && !game_over;
            blue<=video_on && white && !game_over;
        end
    end

    // Keep only the packet bits needed for Start, arrows and A.
    reg [7:0] meta,sync_in;
    reg clk_prev,latch_prev;
    reg [8:0] pad_shift;
    reg [5:0] pad_buttons;
    always @(posedge clk) begin
        if (!rst_n) begin
            meta<=0; sync_in<=0; clk_prev<=0; latch_prev<=0;
            pad_shift<=9'h1ff; pad_buttons<=0;
        end else begin
            meta<=ui_in; sync_in<=meta;
            clk_prev<=sync_in[5]; latch_prev<=sync_in[4];
            if (sync_in[5] && !clk_prev)
                pad_shift<={pad_shift[7:0],sync_in[6]};
            if (sync_in[4] && !latch_prev)
                pad_buttons<=pad_shift==9'h1ff ? 6'd0 : pad_shift[8:3];
        end
    end
    // keys = {Start,hard-drop,rotate,down,left,right}.
    wire [5:0] keys={pad_buttons[5],sync_in[7]|pad_buttons[0],
        sync_in[0]|pad_buttons[4],sync_in[1]|pad_buttons[3],
        sync_in[2]|pad_buttons[2],sync_in[3]|pad_buttons[1]};
    reg [5:0] old_keys;
    wire [5:0] pressed=keys & ~old_keys;
    always @(posedge clk) begin
        if (!rst_n) old_keys<=0;
        else old_keys<=keys;
    end

    // A seven-entry spawn decoder. Rotation is wiring, not another ROM.
    function [15:0] initial_shape;
        input [2:0] kind;
        begin
            case (kind)
                0:initial_shape=16'h00f0; // I
                1:initial_shape=16'h0066; // O
                2:initial_shape=16'h0072; // T
                3:initial_shape=16'h0036; // S
                4:initial_shape=16'h0063; // Z
                5:initial_shape=16'h0071; // J
                default:initial_shape=16'h0074; // L
            endcase
        end
    endfunction
    reg [15:0] piece;
    reg is_i,is_o;
    wire [15:0] rotate_i={piece[3],piece[7],piece[11],piece[15],
        piece[2],piece[6],piece[10],piece[14],
        piece[1],piece[5],piece[9],piece[13],
        piece[0],piece[4],piece[8],piece[12]};
    wire [15:0] rotate_3={4'd0,1'b0,piece[2],piece[6],piece[10],
        1'b0,piece[1],piece[5],piece[9],1'b0,piece[0],piece[4],piece[8]};
    wire [15:0] rotated=is_o ? piece : is_i ? rotate_i : rotate_3;

    localparam [3:0] SYNC=0,WAIT=1,CHECK=2,LOCK=3,SCAN=4,
        COPY=5,FILL=6,AWARD=7,SPAWN=8,OVER=9,INIT=10;
    localparam [2:0] LEFT=0,RIGHT=1,TURN=2,DOWN=3,HARD=4,NEW=5;
    (* fsm_encoding="none" *) reg [3:0] state;
    reg [2:0] action;
    reg [1:0] r;
    reg signed [3:0] piece_x;
    reg [3:0] piece_y;
    reg [3:0] read_row,write_row;
    reg [2:0] cleared;
    reg [7:0] row_buffer;
    reg [7:0] score; // BCD hundreds, displayed with two trailing zeros.
    reg [7:0] rng;
    wire [7:0] rng_next={rng[6:0],rng[7]^rng[5]^rng[4]^rng[3]};
    reg [4:0] pending,frame_count;
    wire [4:0] events=pending | pressed[4:0];
    assign game_over=state==OVER;

    wire checking=state==CHECK;
    wire turn_trial=checking && action==TURN;
    wire signed [3:0] trial_x=piece_x +
        ((checking && action==LEFT) ? -4'sd1 :
         (checking && action==RIGHT) ? 4'sd1 : 4'sd0);
    wire [4:0] trial_y={1'b0,piece_y}+
        ((checking && (action==DOWN || action==HARD)) ? 5'd1 : 5'd0);
    wire [15:0] trial_piece=turn_trial ? rotated : piece;
    wire [3:0] nibble=trial_piece[{r,2'b00} +: 4];
    wire signed [3:0] shift_x=trial_x+4'sd4;
    wire [15:0] shifted={12'd0,nibble} << shift_x[3:0];
    wire [4:0] check_y=trial_y+{3'd0,r};

    // Unconditional shift: 120 bits need just a DFF, without an enable,
    // address decoder, data selector, or reset gate on each storage bit.
    reg [127:0] board;
    wire [7:0] row_out=board[7:0];
    reg [7:0] row_in;
    always @* begin
        row_in=row_out;
        case (state)
            SYNC,INIT:row_in=0;
            LOCK:if (phase==check_y[3:0]) row_in=row_out | shifted[11:4];
            COPY:if (phase==write_row) row_in=row_buffer;
            FILL:if ({1'b0,phase}<{2'd0,cleared}) row_in=0;
            default:begin end
        endcase
    end
    always @(posedge clk) board<={row_in,board[127:8]};
    wire collision=(|nibble) && (check_y[4] ||
        (|shifted[15:12]) || (|shifted[3:0]) ||
        (|(row_out & shifted[11:4])));

    // One small BCD adder, used only when awarding cleared lines.
    reg [3:0] award;
    always @* begin
        case (cleared)
            1:award=1; 2:award=3; 3:award=5; 4:award=8;
            default:award=0;
        endcase
    end
    wire [4:0] score_sum={1'b0,score[3:0]}+{1'b0,award};
    wire [4:0] score_minus_ten=score_sum-5'd10;
    always @(posedge clk) begin
        if (!rst_n || pressed[5] || (game_over && pressed[4])) begin
            state<=SYNC; frame_count<=0; pending<=0;
            score<=0; rng<=8'h5a;
        end else begin
            // The store always circulates; ena gates new game operations.
            pending<=pending | pressed[4:0];
            if (frame_tick) begin
                frame_count<=frame_count+5'd1; rng<=rng_next;
            end
            case (state)
                SYNC:if (phase==15) state<=INIT;
                INIT:if (phase==15) state<=SPAWN;
                WAIT:if (frame_tick && ena) begin
                    pending<=0; r<=0;
                    if (events[4]) begin
                        action<=HARD; state<=CHECK;
                    end else if (events[3]) begin
                        action<=TURN; state<=CHECK;
                    end else if (events[1] ||
                        (keys[1] && frame_count[2:0]==0)) begin
                        action<=LEFT; state<=CHECK;
                    end else if (events[0] ||
                        (keys[0] && frame_count[2:0]==0)) begin
                        action<=RIGHT; state<=CHECK;
                    end else if (events[2] ||
                        (keys[2] && frame_count[1:0]==0) || frame_count==0) begin
                        action<=DOWN; state<=CHECK;
                    end
                end
                CHECK:if (phase==check_y[3:0]) begin
                    if (collision) begin
                        if (action==NEW) state<=OVER;
                        else if (action==DOWN || action==HARD) begin
                            r<=0; state<=LOCK;
                        end else state<=WAIT;
                    end else if (r==3) begin
                        piece_x<=trial_x; piece_y<=trial_y[3:0];
                        if (turn_trial) piece<=rotated;
                        r<=0;
                        if (action!=HARD) state<=WAIT;
                    end else r<=r+2'd1;
                end
                LOCK:if (phase==check_y[3:0]) begin
                    if (r==3) begin
                        read_row<=15; write_row<=15; cleared<=0;
                        pending<=0; state<=SCAN;
                    end else r<=r+2'd1;
                end
                SCAN:if (phase==read_row) begin
                    if (&row_out) begin
                        cleared<=cleared+3'd1;
                        if (read_row==0) state<=FILL;
                        else read_row<=read_row-4'd1;
                    end else begin
                        row_buffer<=row_out; state<=COPY;
                    end
                end
                COPY:if (phase==write_row) begin
                    write_row<=write_row-4'd1;
                    if (read_row==0) state<=FILL;
                    else begin read_row<=read_row-4'd1; state<=SCAN; end
                end
                FILL:if (cleared==0 || {1'b0,phase}=={2'd0,cleared}-5'd1)
                    state<=AWARD;
                AWARD:begin
                    if (score_sum>=10) begin
                        if (score[7:4]==9) score<=8'h99;
                        else score<={score[7:4]+4'd1,score_minus_ten[3:0]};
                    end else score[3:0]<=score_sum[3:0];
                    state<=SPAWN;
                end
                SPAWN:if (rng[2:0]!=7) begin
                    piece<=initial_shape(rng[2:0]);
                    is_i<=rng[2:0]==0; is_o<=rng[2:0]==1;
                    piece_x<=2; piece_y<=0;
                    action<=NEW; r<=0; state<=CHECK;
                end else rng<=rng_next;
                OVER:pending<=0;
                default:state<=SYNC;
            endcase
        end
    end

    // 8x16 board at (256,112), 14x14 squares and two-pixel gaps.
    // Cache one circulating row: no 128:1 read mux in the pixel path.
    wire [3:0] screen_row=vpos[7:4]-4'd7;
    reg [7:0] scan_bits;
    always @(posedge clk) begin
        if (phase==screen_row) scan_bits<=row_out;
    end
    wire board_area=hpos[9:7]==3'd2 && vpos>=10'd112 && vpos<10'd368;
    wire gap_ok=hpos[3:0]!=0 && hpos[3:0]!=15 &&
                vpos[3:0]!=0 && vpos[3:0]!=15;
    wire signed [4:0] dx=$signed({2'd0,hpos[6:4]})-
                            $signed({piece_x[3],piece_x});
    wire [4:0] dy={1'b0,screen_row}-{1'b0,piece_y};
    wire piece_pixel=(state==WAIT || state==CHECK) &&
        dx>=0 && dx<5'sd4 && dy<5'd4 && piece[{dy[1:0],dx[1:0]}];
    wire settled=board_area && gap_ok && scan_bits[hpos[6:4]];
    wire falling=board_area && gap_ok && piece_pixel;

    // Compact seven-segment score, four digits, no text/font ROM.
    reg [3:0] digit;
    always @* begin
        case (hpos[5:4])
            0:digit=score[7:4]; 1:digit=score[3:0];
            default:digit=0;
        endcase
    end
    reg [6:0] segments;
    always @* begin
        case (digit) // a,b,c,d,e,f,g
            0:segments=7'b1111110; 1:segments=7'b0110000;
            2:segments=7'b1101101; 3:segments=7'b1111001;
            4:segments=7'b0110011; 5:segments=7'b1011011;
            6:segments=7'b1011111; 7:segments=7'b1110000;
            8:segments=7'b1111111; default:segments=7'b1111011;
        endcase
    end
    wire [3:0] sx=hpos[3:0];
    wire [4:0] sy=vpos[4:0];
    wire hstroke=sx>=2 && sx<10;
    wire upper=sy>=2 && sy<14;
    wire lower=sy>=16 && sy<28;
    wire left_bar=sx<2, right_bar=sx>=10 && sx<12;
    wire score_pixel=hpos[9:6]==4'd7 && vpos[9:5]==5'd3 &&
        ((segments[6] && hstroke && sy<2) ||
         (segments[5] && right_bar && upper) ||
         (segments[4] && right_bar && lower) ||
         (segments[3] && hstroke && sy>=28 && sy<30) ||
         (segments[2] && left_bar && lower) ||
         (segments[1] && left_bar && upper) ||
         (segments[0] && hstroke && sy>=14 && sy<16));
    assign white=settled || score_pixel;
    assign lit=white || falling;
endmodule
`default_nettype wire
