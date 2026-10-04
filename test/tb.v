`default_nettype none
`timescale 1ns / 1ps

/* Instantiates the design and captures VGA frames from the output pins.

   test.py drives the inputs and requests captures: set `capture` high, wait
   for `capture_done`, set `capture` low. Each capture waits for the next
   frame and writes output/frame<N>.ppm (P3, 640x480, maxval 3). It decodes
   only the TinyVGA pins (active-low syncs): visible line 0 follows the 33rd
   hsync pulse after vsync, and visible pixel 0 starts 48 pixels after an
   hsync pulse ends. The pixel clock is clk/2.

   The capture loop runs in Verilog because cocotb is too slow to await
   ~840k clock edges per frame from Python.
*/
module tb ();

  // Dump the first 20 us only (reset and a few lines); full frames would
  // produce a multi-GB trace.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #20000;
    $dumpoff;
  end

  // Wire up the inputs and outputs:
  // The clock is generated here rather than with cocotb's Clock: driving
  // millions of edges from cocotb makes frame capture ~5x slower.
  reg clk = 1'b0;
  always #9.93 clk = ~clk;  // 50.35 MHz = 2x the 25.175 MHz pixel clock
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  tt_um_filthyfil_mandelbrot user_project (

      // Include power ports for the Gate Level test:
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif

      .ui_in  (ui_in),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

  // ---------------------------------------------------------
  // VGA frame capture (TinyVGA PMOD pinout)
  // ---------------------------------------------------------
  wire hsync_n = uo_out[7];
  wire vsync_n = uo_out[3];
  wire [1:0] r = {uo_out[0], uo_out[4]};
  wire [1:0] g = {uo_out[1], uo_out[5]};
  wire [1:0] b = {uo_out[2], uo_out[6]};

  reg capture = 1'b0;
  reg capture_done = 1'b0;
  integer frame_no = 0;

  initial begin : capture_loop
    integer f, line, px, k;
    reg [8*32-1:0] name;
    forever begin
      wait (capture === 1'b1);
      $sformat(name, "output/frame%0d.ppm", frame_no);
      f = $fopen(name, "w");
      $fwrite(f, "P3\n640 480\n3\n");
      @(posedge vsync_n);  // end of vsync pulse (start of line 492)
      for (k = 0; k < 32; k = k + 1) @(posedge hsync_n);
      for (line = 0; line < 480; line = line + 1) begin
        @(posedge hsync_n);  // 33rd hsync for line 0
        repeat (48 * 2 + 1) @(negedge clk);  // into pixel 0 (2 clocks/pixel)
        for (px = 0; px < 640; px = px + 1) begin
          $fwrite(f, "%0d %0d %0d\n", r, g, b);
          repeat (2) @(negedge clk);
        end
      end
      $fclose(f);
      frame_no = frame_no + 1;
      capture_done = 1'b1;
      wait (capture === 1'b0);
      capture_done = 1'b0;
    end
  end

endmodule
