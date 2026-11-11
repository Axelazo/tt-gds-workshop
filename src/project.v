`default_nettype none

module tt_um_axelazo_tetris (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    assign uio_out = 8'd0;
    assign uio_oe = 8'd0;
    wire _unused_ok = &{1'b0, uio_in};

    // Standard 640x480 timing. RGB and sync share the same one-clock delay.
    reg [9:0] hpos, vpos;
    reg hs, vs;
    reg [5:0] rgb;
    reg [5:0] pixel_rgb;
    wire active = hpos < 10'd640 && vpos < 10'd480;
    wire frame_tick = hpos == 10'd0 && vpos == 10'd480;
    assign uo_out = {hs, rgb[0], rgb[2], rgb[4],
                    vs, rgb[1], rgb[3], rgb[5]};

    always @(posedge clk) begin
        if (!rst_n) begin
            hpos <= 0;
            vpos <= 0;
            hs <= 1;
            vs <= 1;
            rgb <= 0;
        end else begin
            if (hpos == 10'd799) begin
                hpos <= 0;
                vpos <= vpos == 10'd524 ? 10'd0 : vpos + 10'd1;
            end else hpos <= hpos + 10'd1;
            hs <= !(hpos >= 10'd656 && hpos < 10'd752);
            vs <= !(vpos >= 10'd490 && vpos < 10'd492);
            rgb <= active ? pixel_rgb : 6'd0;
        end
    end

    // Synchronize buttons and receive the Playground's 12-bit Pmod packets.
    // Packet bits: B,Y,Select,Start,Up,Down,Left,Right,A,X,L,R (MSB first).
    reg [7:0] input_meta, input_sync, input_prev;
    reg [11:0] pad_shift, pad_data;
    always @(posedge clk) begin
        if (!rst_n) begin
            input_meta <= 0;
            input_sync <= 0;
            input_prev <= 0;
            pad_shift <= 12'hfff;
            pad_data <= 12'hfff;
        end else begin
            input_meta <= ui_in;
            input_sync <= input_meta;
            input_prev <= input_sync;
            if (input_sync[5] && !input_prev[5])
                pad_shift <= {pad_shift[10:0], input_sync[6]};
            if (input_sync[4] && !input_prev[4]) pad_data <= pad_shift;
        end
    end
    wire [11:0] pad = pad_data == 12'hfff ? 12'd0 : pad_data;
    wire [5:0] keys = {
        pad[8], input_sync[7] | pad[3], input_sync[0] | pad[7],
        input_sync[1] | pad[6], input_sync[2] | pad[5],
        input_sync[3] | pad[4]
    };
    reg [5:0] keys_prev;
    wire [5:0] pressed = keys & ~keys_prev;
    always @(posedge clk) begin
        if (!rst_n) keys_prev <= 0;
        else keys_prev <= keys;
    end

    // Four 4-bit rows, low nibble first; bit 0 is the leftmost block.
    // These are tiny piece masks, not a rotating image or a texture ROM.
    function [15:0] shape;
        input [2:0] kind;
        input [1:0] turn;
        begin
            case (kind)
                3'd0: case (turn) // I
                    0: shape=16'h00f0; 1: shape=16'h4444;
                    2: shape=16'h0f00; default: shape=16'h2222;
                endcase
                3'd1: shape=16'h0066; // O
                3'd2: case (turn) // T
                    0: shape=16'h0072; 1: shape=16'h0262;
                    2: shape=16'h0270; default: shape=16'h0232;
                endcase
                3'd3: case (turn) // S
                    0: shape=16'h0036; 1: shape=16'h0462;
                    2: shape=16'h0360; default: shape=16'h0231;
                endcase
                3'd4: case (turn) // Z
                    0: shape=16'h0063; 1: shape=16'h0264;
                    2: shape=16'h0630; default: shape=16'h0132;
                endcase
                3'd5: case (turn) // J
                    0: shape=16'h0071; 1: shape=16'h0226;
                    2: shape=16'h0470; default: shape=16'h0322;
                endcase
                3'd6: case (turn) // L
                    0: shape=16'h0074; 1: shape=16'h0622;
                    2: shape=16'h0170; default: shape=16'h0223;
                endcase
                default: shape=16'h0000;
            endcase
        end
    endfunction

    // Decimal score stays in BCD: no division or decimal conversion per pixel.
    function [23:0] add_score;
        input [23:0] value, amount;
        integer n;
        reg carry;
        reg [4:0] sum;
        begin
            carry=0;
            for (n=0; n<6; n=n+1) begin
                sum={1'b0,value[n*4 +: 4]} +
                    {1'b0,amount[n*4 +: 4]} + {4'd0,carry};
                carry=sum >= 5'd10;
                if (carry) sum=sum-5'd10;
                add_score[n*4 +: 4]=sum[3:0];
            end
            if (carry) add_score=24'h999999;
        end
    endfunction

    localparam [2:0] IDLE=0, CHECK=1, LOCK=2, SCAN=3,
                     FILL=4, AWARD=5, SPAWN=6, OVER=7;
    localparam [2:0] SIDE=0, ROTATE=1, FALL=2, SOFT=3, HARD=4, NEW=5;
    reg [2:0] state, action;
    reg [9:0] board [0:19];
    reg [2:0] piece_kind;
    reg [1:0] piece_turn, trial_turn, check_row, lock_row;
    reg signed [5:0] piece_x, piece_y, trial_x, trial_y;
    reg [2:0] kick, cleared;
    reg blocked;
    reg signed [5:0] scan_row, write_row;
    reg [23:0] score;
    reg [15:0] rng;
    wire [15:0] rng_next={rng[14:0],rng[15]^rng[13]^rng[12]^rng[10]};
    reg [5:0] requests;
    reg [5:0] gravity_count;
    reg [3:0] repeat_count;
    reg soft_count;
    wire [15:0] trial_shape=shape(piece_kind,trial_turn);
    wire [15:0] current_shape=shape(piece_kind,piece_turn);
    wire [3:0] test_bits=trial_shape[{check_row,2'b00} +: 4];
    wire [3:0] lock_bits=current_shape[{lock_row,2'b00} +: 4];

    // Check four cells on one row per clock, only during a game operation.
    // Never scan all 200 board cells for every VGA pixel.
    reg row_hit;
    reg signed [6:0] test_x, test_y;
    integer c;
    always @* begin
        c=0;
        row_hit=0;
        test_x=0;
        test_y=$signed({trial_y[5],trial_y})+$signed({5'd0,check_row});
        if (state == CHECK) begin
            for (c=0; c<4; c=c+1) begin
                test_x=$signed({trial_x[5],trial_x})+$signed(c[6:0]);
                if (test_bits[c]) begin
                    if (test_x<0 || test_x>=10 || test_y<0 || test_y>=20)
                        row_hit=1;
                    else if (board[test_y>=0 && test_y<20 ?
                                   test_y[4:0] : 5'd0][test_x[3:0]]) row_hit=1;
                end
            end
        end
    end
    wire signed [6:0] lock_y=
        $signed({piece_y[5],piece_y})+$signed({5'd0,lock_row});
    wire [4:0] lock_index=lock_y>=0 && lock_y<20 ? lock_y[4:0] : 5'd0;
    wire [4:0] scan_index=scan_row>=0 && scan_row<20 ? scan_row[4:0] : 5'd0;
    wire [4:0] write_index=write_row>=0 && write_row<20 ? write_row[4:0] : 5'd0;
    wire [9:0] lock_mask=piece_x<0 ?
        ({6'd0,lock_bits} >> (-piece_x)) :
        ({6'd0,lock_bits} << piece_x);
    integer row;

    always @(posedge clk) begin
        if (!rst_n || pressed[5] || (state==OVER && pressed[4])) begin
            for (row=0; row<20; row=row+1) board[row]<=0;
            state<=CHECK; action<=NEW;
            piece_kind<=2; piece_turn<=0; piece_x<=3; piece_y<=0;
            trial_turn<=0; trial_x<=3; trial_y<=0;
            check_row<=0; lock_row<=0; kick<=0; blocked<=0;
            scan_row<=19; write_row<=19; cleared<=0;
            score<=0; rng<=16'hace1; requests<=0;
            gravity_count<=0; repeat_count<=0; soft_count<=0;
        end else if (ena) begin
            requests<=requests | {1'b0,pressed[4:0]};
            if (pressed[0] || pressed[1]) repeat_count<=4'd12;
            if (!(keys[0] || keys[1])) repeat_count<=0;
            if (!keys[2]) soft_count<=0;

            if (frame_tick && state!=OVER) begin
                rng<=rng_next;
                if (gravity_count==6'd29) begin
                    gravity_count<=0;
                    requests[5]<=1;
                end else gravity_count<=gravity_count+6'd1;
                if ((keys[0] || keys[1]) && !(pressed[0] || pressed[1])) begin
                    if (repeat_count==0) begin
                        requests[0]<=keys[0] && !keys[1];
                        requests[1]<=keys[1] && !keys[0];
                        repeat_count<=4'd3;
                    end else repeat_count<=repeat_count-4'd1;
                end
                if (keys[2]) begin
                    soft_count<=~soft_count;
                    if (soft_count) requests[2]<=1;
                end
            end

            case (state)
                IDLE: if (frame_tick && |requests) begin
                    trial_x<=piece_x; trial_y<=piece_y; trial_turn<=piece_turn;
                    check_row<=0; blocked<=0; kick<=0; state<=CHECK;
                    if (requests[4]) begin
                        action<=HARD; trial_y<=piece_y+6'sd1;
                        requests[4]<=0; requests[5]<=0;
                    end else if (requests[3]) begin
                        action<=ROTATE; trial_turn<=piece_turn+2'd1;
                        requests[3]<=0;
                    end else if (requests[1]) begin
                        action<=SIDE; trial_x<=piece_x-6'sd1; requests[1]<=0;
                    end else if (requests[0]) begin
                        action<=SIDE; trial_x<=piece_x+6'sd1; requests[0]<=0;
                    end else begin
                        action<=requests[2] ? SOFT : FALL;
                        trial_y<=piece_y+6'sd1;
                        requests[2]<=0; requests[5]<=0; gravity_count<=0;
                    end
                end
                CHECK: begin
                    if (row_hit) blocked<=1;
                    if (check_row!=3) check_row<=check_row+2'd1;
                    else if (blocked || row_hit) begin
                        if (action==ROTATE && kick<4) begin
                            // Small horizontal wall kicks, including the I piece.
                            case (kick)
                                0: trial_x<=piece_x-6'sd1;
                                1: trial_x<=piece_x+6'sd1;
                                2: trial_x<=piece_x-6'sd2;
                                3: trial_x<=piece_x+6'sd2;
                                default: trial_x<=piece_x;
                            endcase
                            kick<=kick+3'd1; check_row<=0; blocked<=0;
                        end else if (action==NEW) state<=OVER;
                        else if (action==FALL || action==SOFT || action==HARD) begin
                            lock_row<=0; state<=LOCK;
                        end else state<=IDLE;
                    end else begin
                        piece_x<=trial_x; piece_y<=trial_y; piece_turn<=trial_turn;
                        if (action==HARD) begin
                            score<=add_score(score,24'h000002);
                            trial_y<=trial_y+6'sd1; check_row<=0; blocked<=0;
                        end else begin
                            if (action==SOFT) score<=add_score(score,24'h000001);
                            state<=IDLE;
                        end
                    end
                end
                LOCK: begin
                    if (lock_bits!=0 && lock_y>=0 && lock_y<20)
                        board[lock_index]<=board[lock_index] | lock_mask;
                    if (lock_row==3) begin
                        scan_row<=19; write_row<=19; cleared<=0;
                        requests[5:2]<=0; gravity_count<=0; state<=SCAN;
                    end else lock_row<=lock_row+2'd1;
                end
                SCAN: begin
                    // Compact every surviving row downward; adjacent full rows
                    // are all counted before the empty rows are filled above.
                    if (scan_row<0) state<=FILL;
                    else begin
                        if (board[scan_index]==10'h3ff) cleared<=cleared+3'd1;
                        else begin
                            board[write_index]<=board[scan_index];
                            write_row<=write_row-6'sd1;
                        end
                        scan_row<=scan_row-6'sd1;
                    end
                end
                FILL: if (write_row>=0) begin
                    board[write_index]<=0; write_row<=write_row-6'sd1;
                end else state<=AWARD;
                AWARD: begin
                    case (cleared)
                        1: score<=add_score(score,24'h000100);
                        2: score<=add_score(score,24'h000300);
                        3: score<=add_score(score,24'h000500);
                        4: score<=add_score(score,24'h000800);
                        default: begin end
                    endcase
                    state<=SPAWN;
                end
                SPAWN: begin
                    if (rng[2:0]<7) begin
                        piece_kind<=rng[2:0]; piece_turn<=0;
                        piece_x<=3; piece_y<=0;
                        trial_turn<=0; trial_x<=3; trial_y<=0;
                        check_row<=0; blocked<=0; action<=NEW; state<=CHECK;
                    end else rng<=rng_next;
                end
                OVER: requests<=0;
                default: state<=OVER;
            endcase
        end
    end

    // 10x20 board at (240,80). 16-pixel cells use bit slices instead of
    // division. Each block is 14x14, leaving a clean two-pixel gap.
    wire [9:0] bx=hpos-10'd240, by=vpos-10'd80;
    wire [3:0] gx=bx[7:4];
    wire [4:0] gy=by[8:4];
    wire [4:0] render_row=gy<20 ? gy : 5'd0;
    wire board_area=hpos>=240 && hpos<400 && vpos>=80 && vpos<400;
    wire block_area=bx[3:0]!=0 && bx[3:0]!=15 &&
                    by[3:0]!=0 && by[3:0]!=15;
    wire signed [6:0] dx=$signed({3'd0,gx})-$signed({piece_x[5],piece_x});
    wire signed [6:0] dy=$signed({2'd0,gy})-$signed({piece_y[5],piece_y});
    wire drawing_piece=(state==IDLE || state==CHECK) &&
                       dx>=0 && dx<4 && dy>=0 && dy<4;
    wire live_block=drawing_piece && current_shape[{dy[1:0],dx[1:0]}];

    function [14:0] glyph;
        input [4:0] ch;
        begin
            case (ch)
                 0:glyph=15'b111_101_101_101_111;
                 1:glyph=15'b010_110_010_010_111;
                 2:glyph=15'b111_001_111_100_111;
                 3:glyph=15'b111_001_111_001_111;
                 4:glyph=15'b101_101_111_001_001;
                 5:glyph=15'b111_100_111_001_111;
                 6:glyph=15'b111_100_111_101_111;
                 7:glyph=15'b111_001_010_010_010;
                 8:glyph=15'b111_101_111_101_111;
                 9:glyph=15'b111_101_111_001_111;
                10:glyph=15'b111_100_111_001_111; // S
                11:glyph=15'b111_100_100_100_111; // C
                12:glyph=15'b111_101_101_101_111; // O
                13:glyph=15'b110_101_110_101_101; // R
                14:glyph=15'b111_100_110_100_111; // E
                16:glyph=15'b111_100_101_101_111; // G
                17:glyph=15'b010_101_111_101_101; // A
                18:glyph=15'b101_111_111_101_101; // M
                19:glyph=15'b101_101_101_101_010; // V
                default:glyph=0;
            endcase
        end
    endfunction
    wire [9:0] tx=hpos-10'd432;
    wire [3:0] letter=tx[7:4];
    wire title_area=hpos>=432 && hpos<512 && vpos>=96 && vpos<116;
    wire number_area=hpos>=432 && hpos<528 && vpos>=128 && vpos<148;
    wire over_area=state==OVER && hpos>=432 && hpos<576 && vpos>=192 && vpos<212;
    reg [4:0] ch;
    reg [14:0] bits;
    reg [2:0] font_row;
    always @* begin
        ch=15;
        if (title_area) begin
            case (letter)
                0:ch=10; 1:ch=11; 2:ch=12; 3:ch=13; 4:ch=14;
                default:ch=15;
            endcase
        end else if (number_area) begin
            case (letter)
                0:ch={1'b0,score[23:20]}; 1:ch={1'b0,score[19:16]};
                2:ch={1'b0,score[15:12]}; 3:ch={1'b0,score[11:8]};
                4:ch={1'b0,score[7:4]}; 5:ch={1'b0,score[3:0]};
                default:ch=15;
            endcase
        end else if (over_area) begin
            case (letter)
                0:ch=16; 1:ch=17; 2:ch=18; 3:ch=14; 4:ch=15;
                5:ch=12; 6:ch=19; 7:ch=14; 8:ch=13;
                default:ch=15;
            endcase
        end
        bits=glyph(ch);
        case (vpos[4:2])
            0:font_row=bits[14:12]; 1:font_row=bits[11:9];
            2:font_row=bits[8:6]; 3:font_row=bits[5:3];
            4:font_row=bits[2:0]; default:font_row=0;
        endcase
        pixel_rgb=0;
        if (board_area && block_area) begin
            if (board[render_row][gx]) pixel_rgb=state==OVER ? 6'b110000 : 6'b111111;
            else if (live_block) pixel_rgb=6'b001100;
        end
        if ((title_area || number_area || over_area) &&
            tx[3:2]<3 && font_row[2-tx[3:2]])
            pixel_rgb=state==OVER ? 6'b110000 : 6'b111111;
    end
endmodule

`default_nettype wire
