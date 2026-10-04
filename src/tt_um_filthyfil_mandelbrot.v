/*
 * Copyright (c) 2026 Filip Jasionek
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Mandelbrot with colour-cycling bands, 1 Tiny Tapeout tile.
 *
 * Beam racing (no frame buffer): the screen is 80x60 blocks of 8x8 pixels.
 * One iteration stage computes each block in the 16 core clocks (8 pixels at
 * 2 clocks/pixel) before it is displayed: 16 iterations of z <- z^2 + c.
 *
 *   clk = 50.35 MHz (2x the 25.175 MHz VGA pixel clock)
 *   arithmetic: Q3.6 signed (9 bits, range [-4, 4)); an update that overflows
 *   counts as an escape (|z'| >= 4 implies |z| > 2)
 *   colour = palette[(n_escape + phase) mod 16], inside the set black;
 *   phase steps once every 1/2/4/8 frames
 *
 * ui_in[1:0] cycle speed (step every 2^s frames)
 * ui_in[2]   direction
 * ui_in[3]   pause
 * uo_out     TinyVGA PMOD {hsync, B0, G0, R0, vsync, B1, G1, R1}
 *
 * See docs/info.md.
 */

`default_nettype none

module tt_um_filthyfil_mandelbrot (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------------------------------------------------
    // VGA 640x480@60 timing, pixel enable every 2nd clock
    // ---------------------------------------------------------
    localparam H_VISIBLE = 640, H_SYNC_START = 656, H_SYNC_END = 752, H_TOTAL = 800;
    localparam V_VISIBLE = 480, V_SYNC_START = 490, V_SYNC_END = 492, V_TOTAL = 525;

    reg pix; // second clock of the pixel
    reg [9:0] h;
    reg [9:0] v;

    always @(posedge clk) begin
        if (!rst_n) begin
            pix <= 1'b0;
            h <= 10'd0;
            v <= 10'd0;
        end
        else begin
            pix <= ~pix;
            if (pix) begin
                if (h == H_TOTAL - 1) begin
                    h <= 10'd0;
                    v <= (v == V_TOTAL - 1) ? 10'd0 : v + 10'd1;
                end
                else begin
                    h <= h + 10'd1;
                end
            end
        end
    end

    wire frame_tick = pix && (h == H_TOTAL - 1) && (v == V_TOTAL - 1);

    // ---------------------------------------------------------
    // block schedule: 16 clocks per 8-pixel block
    // the stage computes the block *after* the one on screen
    // ---------------------------------------------------------
    wire [3:0] iter = {h[2:0], pix}; // iteration index within the block
    wire block_end = (iter == 4'd15);

    wire [6:0] h_block = h[9:3]; // 0..99
    wire line_last_block = (h_block == 7'd99);
    wire [9:0] v_next = (v == V_TOTAL - 1) ? 10'd0 : v + 10'd1;

    wire [6:0] col = line_last_block ? 7'd0 : h_block + 7'd1;
    wire [6:0] row = line_last_block ? v_next[9:3] : v[9:3];

    // c = (-3.25 + col/16) + i(1.875 - row/16) in Q3.6 (1.0 = 64, step = 4 LSB)
    wire signed [10:0] cr = $signed({2'b00, col, 2'b00}) - 11'sd208;
    wire signed [10:0] ci = 11'sd120 - $signed({2'b00, row, 2'b00});

    // ---------------------------------------------------------
    // iteration stage
    // ---------------------------------------------------------
    reg signed [8:0] x, y;
    reg esc; // escaped (sticky within the block)
    reg [3:0] n; // iteration of escape

    // squares are only needed while |x|, |y| < 2, so square magnitudes:
    // |x| < 128 -> 7-bit squarer, |x + y| < 256 -> 8-bit squarer
    wire [8:0] ax = x[8] ? -x : x;
    wire [8:0] ay = y[8] ? -y : y;
    wire signed [9:0] sum = x + y;
    wire [9:0] as = sum[9] ? -sum : sum;

    wire x_big = ax[8] | ax[7]; // |x| >= 2
    wire y_big = ay[8] | ay[7];

    wire [13:0] x2_p = ax[6:0] * ax[6:0];
    wire [13:0] y2_p = ay[6:0] * ay[6:0];
    wire [15:0] s_p = as[7:0] * as[7:0];
    wire [7:0] x2 = x2_p[13:6]; // x^2       < 4.0
    wire [7:0] y2 = y2_p[13:6]; // y^2       < 4.0
    wire [9:0] s = s_p[15:6]; // (x+y)^2   < 16.0

    wire [8:0] mag2 = x2 + y2;
    wire escape_now = x_big | y_big | (mag2 > 9'd256); // |z|^2 > 4

    // z' = (x^2 - y^2 + cr) + i(2xy + ci), 2xy = (x+y)^2 - x^2 - y^2
    wire signed [11:0] xw = $signed({4'b0, x2}) - $signed({4'b0, y2}) + cr;
    wire signed [11:0] yw = $signed({2'b0, s}) - $signed({3'b0, mag2}) + ci;

    // outside [-4, 4): |z'| >= 4, escaped
    wire overflow = (xw[11:8] != {4{xw[8]}}) | (yw[11:8] != {4{yw[8]}});

    wire esc_next = esc | escape_now | overflow;
    wire [3:0] n_next = esc ? n : escape_now ? iter : iter + 4'd1;

    reg disp_esc;
    reg [3:0] disp_n;

    always @(posedge clk) begin
        if (block_end) begin
            // result of the block just computed goes on screen next
            disp_esc <= esc_next;
            disp_n <= n_next;
            // start the next block from z = 0
            x <= 9'sd0;
            y <= 9'sd0;
            esc <= 1'b0;
            n <= 4'd0;
        end
        else begin
            x <= xw[8:0];
            y <= yw[8:0];
            esc <= esc_next;
            n <= n_next;
        end
    end

    // ---------------------------------------------------------
    // colour cycling
    // ---------------------------------------------------------
    reg [3:0] ui_meta, ui_sync;
    reg [2:0] frame_div;
    reg [3:0] phase;

    wire [1:0] speed = ui_sync[1:0];
    wire reverse = ui_sync[2];
    wire pause = ui_sync[3];
    wire [2:0] speed_mask = (3'b1 << speed) - 3'b1; // 000, 001, 011, 111

    always @(posedge clk) begin
        if (!rst_n) begin
            ui_meta <= 4'd0;
            ui_sync <= 4'd0;
            frame_div <= 3'd0;
            phase <= 4'd0;
        end
        else begin
            ui_meta <= ui_in[3:0];
            ui_sync <= ui_meta;
            if (frame_tick) begin
                frame_div <= frame_div + 3'd1;
                if (!pause && (frame_div & speed_mask) == 3'd0)
                    phase <= reverse ? phase - 4'd1 : phase + 4'd1;
            end
        end
    end

    // closed loop, no black: navy - blue - white - yellow - orange - maroon - purple
    wire [3:0] pal_idx = disp_n + phase; // wraps mod 16
    reg [5:0] rgb; // {R[1:0], G[1:0], B[1:0]}
    always @* begin
        case (pal_idx)
            4'd0 : rgb = 6'b00_00_01;
            4'd1 : rgb = 6'b00_00_10;
            4'd2 : rgb = 6'b00_01_10;
            4'd3 : rgb = 6'b00_01_11;
            4'd4 : rgb = 6'b01_10_11;
            4'd5 : rgb = 6'b10_10_11;
            4'd6 : rgb = 6'b10_11_11;
            4'd7 : rgb = 6'b11_11_11;
            4'd8 : rgb = 6'b11_11_10;
            4'd9 : rgb = 6'b11_11_01;
            4'd10: rgb = 6'b11_10_00;
            4'd11: rgb = 6'b11_01_00;
            4'd12: rgb = 6'b10_01_00;
            4'd13: rgb = 6'b01_00_00;
            4'd14: rgb = 6'b01_00_01;
            default: rgb = 6'b01_00_10;
        endcase
    end

    // ---------------------------------------------------------
    // registered outputs (syncs active low)
    // ---------------------------------------------------------
    wire visible = (h < H_VISIBLE) && (v < V_VISIBLE);
    wire hsync = ~((h >= H_SYNC_START) && (h < H_SYNC_END));
    wire vsync = ~((v >= V_SYNC_START) && (v < V_SYNC_END));
    wire [5:0] colour = (visible && disp_esc) ? rgb : 6'd0;

    reg [7:0] out_reg;
    always @(posedge clk) begin
        if (!rst_n)
            out_reg <= 8'b1000_1000; // syncs inactive (high), black
        else
            out_reg <= {hsync, colour[0], colour[2], colour[4],
                        vsync, colour[1], colour[3], colour[5]};
    end

    assign uo_out = out_reg;
    assign uio_out = 8'd0;
    assign uio_oe = 8'd0;

    wire _unused = &{ena, uio_in, ui_in[7:4], 1'b0};

endmodule
