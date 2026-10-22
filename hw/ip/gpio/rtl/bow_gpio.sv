// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 GPIO port (IOPAD controller): Width pins with direction, push-pull or
// open-drain output, alternate function select and edge interrupts.
//
// Register map (32 bit registers, bits [Width-1:0] used, see docs/ip/gpio.md):
//   0x00 IN         R  : pin levels (after a 2 flip-flop synchroniser)
//   0x04 OUT        RW : output data
//   0x08 OUT_SET    W  : OUT |=  wdata   (reads 0)
//   0x0C OUT_CLR    W  : OUT &= ~wdata   (reads 0)
//   0x10 OUT_TGL    W  : OUT ^=  wdata   (reads 0)
//   0x14 DIR        RW : 1 = output, 0 = input (reset: all inputs)
//   0x18 OD         RW : 1 = open-drain: driven low for OUT = 0, released
//                        (high impedance) for OUT = 1
//   0x1C AF         RW : 1 = pin driven by its alternate function; only the
//                        pins in AfMask have one (other bits read 0)
//   0x20 IRQ_EN     RW : interrupt enable
//   0x24 IRQ_RISE   RW : detect rising edges
//   0x28 IRQ_FALL   RW : detect falling edges
//   0x2C IRQ_STATUS R/W1C: selected edge seen (set even when IRQ_EN = 0)
//
// irq_o = |(IRQ_STATUS & IRQ_EN)
//
// The pads (IO buffers) are outside this module, in the board top or the
// testbench: pad = gpio_oe_o ? gpio_o : Z, gpio_i = pad level.

module bow_gpio import bow_bus_pkg::*; #(
  parameter int unsigned      Width   = 8,
  parameter logic [Width-1:0] AfMask  = '0,  // pins that have an alternate function
  parameter logic [Width-1:0] AfReset = '0,  // AF after reset (within AfMask)
  parameter logic [Width-1:0] AfIdle  = '1   // af_in_o while the AF is not selected
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  bus_req_t         bus_req_i,
  output bus_rsp_t         bus_rsp_o,

  // Pads
  input  logic [Width-1:0] gpio_i,     // asynchronous pad levels
  output logic [Width-1:0] gpio_o,
  output logic [Width-1:0] gpio_oe_o,

  // Alternate functions (peripheral side)
  input  logic [Width-1:0] af_out_i,   // value driven by the peripheral
  input  logic [Width-1:0] af_oe_i,    // drive enable from the peripheral
  output logic [Width-1:0] af_in_o,    // pad level for the peripheral

  output logic             irq_o
);

  localparam logic [11:0] RegIn        = 12'h000;
  localparam logic [11:0] RegOut       = 12'h004;
  localparam logic [11:0] RegOutSet    = 12'h008;
  localparam logic [11:0] RegOutClr    = 12'h00C;
  localparam logic [11:0] RegOutTgl    = 12'h010;
  localparam logic [11:0] RegDir       = 12'h014;
  localparam logic [11:0] RegOd        = 12'h018;
  localparam logic [11:0] RegAf        = 12'h01C;
  localparam logic [11:0] RegIrqEn     = 12'h020;
  localparam logic [11:0] RegIrqRise   = 12'h024;
  localparam logic [11:0] RegIrqFall   = 12'h028;
  localparam logic [11:0] RegIrqStatus = 12'h02C;

  // ---------------------------------------------------------------------------
  // Register interface
  // ---------------------------------------------------------------------------
  logic [11:0]      reg_addr;
  logic             reg_we, reg_re;
  logic [Width-1:0] wdata;

  assign reg_addr = {bus_req_i.addr[11:2], 2'b00};
  assign reg_we   = bus_req_i.req &  bus_req_i.we;
  assign reg_re   = bus_req_i.req & ~bus_req_i.we;
  assign wdata    = bus_req_i.wdata[Width-1:0];

  logic [Width-1:0] out_q, dir_q, od_q, af_q;
  logic [Width-1:0] irq_en_q, irq_rise_q, irq_fall_q, irq_status_q;
  logic [Width-1:0] in_sync, in_q, edges, status_clr;

  // Edge events win over a clear in the same cycle, so none is lost.
  assign edges      = (in_sync & ~in_q & irq_rise_q) | (~in_sync & in_q & irq_fall_q);
  assign status_clr = (reg_we && reg_addr == RegIrqStatus) ? wdata : '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_q        <= '0;
      dir_q        <= '0;
      od_q         <= '0;
      af_q         <= AfReset & AfMask;
      irq_en_q     <= '0;
      irq_rise_q   <= '0;
      irq_fall_q   <= '0;
      irq_status_q <= '0;
      in_q         <= '0;
    end else begin
      if (reg_we) begin
        unique case (reg_addr)
          RegOut:     out_q      <= wdata;
          RegOutSet:  out_q      <= out_q | wdata;
          RegOutClr:  out_q      <= out_q & ~wdata;
          RegOutTgl:  out_q      <= out_q ^ wdata;
          RegDir:     dir_q      <= wdata;
          RegOd:      od_q       <= wdata;
          RegAf:      af_q       <= wdata & AfMask;
          RegIrqEn:   irq_en_q   <= wdata;
          RegIrqRise: irq_rise_q <= wdata;
          RegIrqFall: irq_fall_q <= wdata;
          default: ;
        endcase
      end
      in_q         <= in_sync;
      irq_status_q <= (irq_status_q & ~status_clr) | edges;
    end
  end

  // Read data multiplexer (registered: response comes one cycle after gnt).
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    rdata_d = '0;
    unique case (reg_addr)
      RegIn:        rdata_d[Width-1:0] = in_sync;
      RegOut:       rdata_d[Width-1:0] = out_q;
      RegDir:       rdata_d[Width-1:0] = dir_q;
      RegOd:        rdata_d[Width-1:0] = od_q;
      RegAf:        rdata_d[Width-1:0] = af_q;
      RegIrqEn:     rdata_d[Width-1:0] = irq_en_q;
      RegIrqRise:   rdata_d[Width-1:0] = irq_rise_q;
      RegIrqFall:   rdata_d[Width-1:0] = irq_fall_q;
      RegIrqStatus: rdata_d[Width-1:0] = irq_status_q;
      default:      rdata_d = '0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= bus_req_i.req;
      if (reg_re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata_q;

  // ---------------------------------------------------------------------------
  // Pads
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < Width; i++) begin : g_sync
    bow_sync u_sync (
      .clk_i,
      .rst_ni,
      .d_i (gpio_i[i]),
      .q_o (in_sync[i])
    );
  end

  // GPIO: push-pull drives OUT, open-drain drives only the zeros.
  logic [Width-1:0] gpio_oe;
  assign gpio_oe = dir_q & ~(od_q & out_q);

  assign gpio_o    = (af_q & af_out_i) | (~af_q & out_q);
  assign gpio_oe_o = (af_q & af_oe_i)  | (~af_q & gpio_oe);
  // The peripheral synchronises af_in_o itself (e.g. UART RX).
  assign af_in_o   = (af_q & gpio_i)   | (~af_q & AfIdle);

  assign irq_o = |(irq_status_q & irq_en_q);

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be,
                        bus_req_i.wdata};

endmodule
