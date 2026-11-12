// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY receive I/O on AMD Versal XPIO banks: the Versal twin of
// bow_dphy_io_xusp, the board level half of the Bow32 CSI-2 receiver
// (bow_mipi_rx with DlyVid = 1). No vendor D-PHY or Advanced I/O Wizard IP:
// the IBUFDS_DPHY, XPHY (native mode), XPLL and BUFGCE primitives are
// instantiated here. Used by the Huins MFP-VP1902 camera build (IMX274,
// 4 lanes x 1440 Mbit/s, hw/fpga/huins_vp1902, docs/camera_huins.md).
//
//   clock lane IBUFDS_DPHY -HSRX_O-> XPHY[strobe] DATAIN[0]   (DQS_SRC LOCAL)
//                                      | PCLK/NCLK_NIBBLE_OUT -> pair nibble   (inter-nibble)
//                                      | CLK_TO_LOWER/UPPER   -> nibble +-2    (inter-byte)
//                                      +- FIFO_WR_CLK (strobe / 4) -> BUFGCE (CE = byte_ce_i)
//                                                                   -> byte_clk_o
//   data lane  IBUFDS_DPHY -HSRX_O-> XPHY[n] DATAIN[s] -> input delay -> 1:8 -> 8 deep FIFO
//              -> Q<s> (FIFO_RD_CLK = byte_clk_o) -> capture flop (BLI) -> rx_data_o
//   all lanes  LPRX_O_P/N ---------------------------------------------------> lp_o (async)
//   XPLL       pll_clkin_i x 15 / 1 = VCO 3000 MHz, CLKOUTPHY / 2 = 1500 MHz = PLL_CLK of
//              every nibble of the bank (BISC, delay calibration, VT tracking; the capture
//              itself runs on the strobe)
//   ctrl_clk_i free running: CTRL_CLK of every nibble, init sequencer, input delay control
//
// Why the XPHY: Versal XPIO has no ISERDES component; XP IOL component mode only reaches
// ~250 Mbit/s, so 1.44 Gbit/s needs the XPHY in native strobe mode. The clock lane is the
// strobe: it enters NIBBLESLICE 0 of its nibble and is forwarded to the other nibbles by
// dedicated wires, which never leave the XPIO bank. All five pairs must therefore be in
// one bank, the clock lane on an XCC pin "N<k>P0" (in practice a GC/XCC pin).
//
// Ports, compared with bow_dphy_io_xusp (same pads, LP, HS enable and byte clock ports):
//   * byte_clk_o: FIFO_WR_CLK of the strobe nibble through a BUFGCE in the bank's clock
//     region, 180 MHz at 1440 Mbit/s. Like the UltraScale+ byte clock it stops with the
//     clock lane; byte_ce_i is its gate (CE_TYPE SYNC, bow_dphy_lp opens it in the static
//     HS-0 of the clock lane and closes it after the clock stopped).
//   * byte_rst_i is not used (no ISERDES to align): see burst_rst_en_i.
//   * rx_data_o[l]: byte_clk_o domain, bit 0 = first bit on the wire (D-PHY sends the
//     LSB first: an aligned word is the byte); rx_valid_o[l] = 1: a new FIFO word this
//     cycle (bow_mipi_rx advances the lane aligner only on valid words). FIFO latency 2-3
//     byte clocks; when the strobe stops the FIFOs keep their last words, which come out
//     first in the next burst, long before the SoT (harmless for the aligner).
//   * clk_q_o: deserialised clock lane samples (diagnostics: 55 / aa while it toggles).
//   * phy_rdy_o (ctrl_clk_i domain flop, asynchronous for the receiver): XPLL locked, BISC
//     done, PHY_RDY of every nibble. phy_status_o = {PHY_RDY all, DLY_RDY all, XPLL
//     LOCKED_FB, XPLL LOCKED}, synchronised to ctrl_clk_i.
//   * dly_tap_i / dly_load_i / dly_tap_o are in the ctrl_clk_i domain (the XPHY loads and
//     reads its delays on CTRL_CLK) and work without a byte clock. In the Huins camera top
//     ctrl_clk_i = the SoC video clock, so bow_mipi_rx runs its tap logic with DlyVid = 1.
//   * reinit_i / burst_rst_en_i: run-time knobs, see "Run-time knobs" below.
//
// Input delays (bow_mipi_rx DlyVid = 1 contract):
//   * The tap is the TOTAL input delay of the data P slice, including the alignment delay
//     BISC added at init. After phy_rdy_o, dly_tap_o shows the BISC result (kept over
//     voltage and temperature by VT tracking): software starts its eye sweep there and never
//     loads a blind 0.
//   * Nothing is loaded without a request. A request is dly_load_i[l] high for one cycle
//     with the tap on dly_tap_i[l]; the tap is taken in that cycle. The first request of a
//     lane after init puts the lane's slice into user mode (RX_EN_VTC = 0, "PL updates" in
//     AM010) and loads VtcWait cycles later; then LD = 1 (CE = INC = RXTX_SEL = 0) for one
//     cycle with CNTVALUEIN = tap. Loads of one lane are >= LdGap cycles apart (AM010: >= 3);
//     a request that arrives while one is still pending replaces its tap (the newest value
//     is loaded). Requests before phy_rdy_o are ignored. A fall of phy_rdy_o ends user mode
//     (VT tracking again; a re-init, reinit_i or a loss of XPLL lock, restarts from the new
//     BISC delay: the loaded taps are lost).
//   * Tap size: AM010 only guarantees >= 625 ps for 512 taps (UI 694 ps at 1440 Mbit/s);
//     the simulation model steps ~2 ps per tap. UNVERIFIED on silicon.
//
// Nibble plan (parameters, checked at elaboration). Instance n = 0..NumNib-1 is one XPHY;
// Vivado places it by the pins on its DATAIN, so NibPhys / NibBank must say where that is
// (the forwarding wires and the BISC chain connect physical neighbours only).
//   NibRole 0 STROBE  the clock lane on NIBBLESLICE 0
//           1 NIBBLE  strobe from the pair partner (nibble pairs 0-1, 2-3, 4-5, 6-7)
//           2 BYTE    strobe from the nibble 2 above (CLK_TO_LOWER: nibbles 0-3; 6 -> 8) or
//                     2 below (CLK_TO_UPPER: nibbles 4-7), AM010 XP clocking. A NIBBLE
//                     receiver cannot forward inter-byte.
//   NibSrc  instance the strobe comes from (NIBBLE / BYTE); LaneNib / LaneSlice: instance
//   and P slice (0 / 2 / 4) of each data lane.
//   The defaults are a synthetic plan for simulation and lint, no board's: one bank, the
//   clock lane on nibble 4 slice 0 (n0 STROBE), D0 strobe local (n0 slice 2), D1 inter-nibble
//   (n2 = nibble 5, slice 4), D2 inter-byte CLK_TO_UPPER (n1 = nibble 6, slice 0), D3
//   inter-byte CLK_TO_LOWER (n3 = nibble 2, slice 2). A board build passes the plan of its
//   pins. The Huins camera build derives it at build time from the generated pin XDC and
//   the package pin functions (hw/fpga/huins_vp1902/tcl/cam_plan.tcl: the board pin map is
//   confidential, so the repo holds no plan of it) and passes it as generics of
//   bow32_huins_vp1902_cam_top; tcl/cam_xphy.tcl checks the netlist against the pins again.
//   CheckPlan = 0 skips the physical rules (same bank, pair partner, +-2 neighbour) and
//   allows several banks (NumPll XPLLs, NibBank): only to watch Vivado reject a plan. No
//   DRC checks the forwarding: an unreachable nibble passes opt_design and place_design and
//   fails in route_design ([Route 35-7], "Site pin does not reach interconnect fabric").
//
// Options (defaults = what AMD's MIPI_RX PHY does on the same device; simulated both ways):
//   EnVtcEarly 1: EN_VTC = 1 from reset on (AMD); 0: EN_VTC after DLY_RDY (AM010 sequence).
//   RdenReg    1: FIFO_RDEN = ~FIFO_EMPTY registered once (AMD); 0: ~FIFO_EMPTY directly
//              (AM010 text). Both decode every burst.
//   BitRev     1 reverses rx_data_o, if the wire order ever turns out different.
//   FwdDqsLocal 1: DQS_SRC LOCAL on inter-nibble receivers (AMD and the default: EXTERN).
//
// Run-time knobs (asynchronous levels, two flop synchronisers to ctrl_clk_i here; 0 = the
// AMD-like behaviour above): the questions only the silicon answers can be tried without a
// rebuild. The Huins camera top drives them from the registers of the receiver's D-PHY
// (step 4 of docs/ip/mipi_rx_arch.md; GPIO PA4 / PA5 before): reinit_i from CMD.REINIT, a
// pulse of 32 bus clock cycles (640 ns at 50 MHz), burst_rst_en_i = ~CTRL.DES_RST_DIS, 1
// from reset.
//   reinit_i       1 holds the PHY in its init reset, the state after a loss of XPLL lock:
//                  XPLL RST, XPHY RST / RX_RST / TX_RST, CLKOUTPHYEN 0, phy_rdy_o = 0, user
//                  mode and pending loads cleared (the loaded taps are lost). Its release
//                  runs the init sequence again: XPLL lock, BISC, VT tracking, e.g. to retry
//                  BISC with the clock lane toggling (sensor streaming) if it did not
//                  complete with the clock lane in LP-11.
//   burst_rst_en_i 1: RX_RST of the used slices while byte_ce_i = 0, which drains the FIFOs
//                  every burst: keeps the FIFO latency constant when glitches at HS entry
//                  clock the strobe before the gate opens (simulation); 0: no per burst
//                  reset (AMD). It only acts while the gate is closed, so it may change at
//                  any time (RX_RST "does not reset the input delay", AM010).
//
// Implementation notes (Vivado 2025.2, xcvp1902-vsva6865-2MP-e-S):
//   * synth_design / opt_design accept hand-instantiated XPHYs (implement_xphy_cores only
//     handles the XPHYs of AMD's IP), but every XPHY needs a LOC (DRC AVAL-314): the XPHY
//     site of the XPIO_NIBBLE tile that holds the nibble's pins. The Huins build derives
//     them from the pins (hw/fpga/huins_vp1902/tcl/cam_xphy.tcl).
//   * RX_RST / TX_RST only on the slices used in XPHY mode (those with a DATAIN), else DRC
//     REQPXA-314/315/318: the N slice of a pair only carries the complementary pad.
//   * The XDC creates the byte clock on the strobe nibble's FIFO_WR_CLK pin (pad clocks do
//     not propagate through the XPHY), puts BLI on the capture flops (*bli_q_reg*), cuts the
//     paths to the BUFGCE CE and from the LP outputs, and sets the MIPI_DPHY pads to
//     DIFF_TERM_ADV TERM_100, EQUALIZATION EQ_LEVEL5, OFFSET_CNTRL CNTRL_NONE (VCCO 1.2 V):
//     hw/fpga/huins_vp1902/constr/cam_pads.xdc and huins_vp1902_cam.xdc.
//   * HSRX_O may only feed an XPHY DATAIN, never the fabric as well (AM010).
// Simulation: xsim with unisims_ver + secureip (the XPHY model is encrypted, Verilator can
// only lint this file against port stubs). Two xsim 2025.2 bugs shape the coding style:
// (a) "q[l] <= 0; if (c) q[l] <= 1;" in a for loop loses the second write, (b) "x[l] <=
// y[f(l)]" with a constant function f is evaluated as y[l]. Hence next-state variables in
// always_ff and genvar / localparam for every static lane / slice mapping.

module bow_dphy_io_versal #(
  // nibble plan, see "Nibble plan" above (default: synthetic)
  parameter int unsigned Lanes         = 4,                    // data lanes 1..4
  parameter int unsigned NumNib        = 4,                    // XPHY instances 1..4
  parameter logic [15:0] NibPhys       = 16'h2564,             // [4n +: 4] physical nibble 0..8
  parameter logic [7:0]  NibBank       = 8'h00,                // [2n +: 2] bank (= XPLL) index
  parameter logic [7:0]  NibRole       = 8'b10_01_10_00,       // [2n +: 2] 0 STROBE 1 NIBBLE 2 BYTE
  parameter logic [7:0]  NibSrc        = 8'b00_00_00_00,       // [2n +: 2] source instance
  parameter logic [7:0]  LaneNib       = 8'b11_01_10_00,       // [2l +: 2] instance of lane l
  parameter logic [11:0] LaneSlice     = 12'b010_000_100_010,  // [3l +: 3] P slice 0 / 2 / 4
  parameter int unsigned NumPll        = 1,                    // banks / XPLLs 1..3
  parameter bit          CheckPlan     = 1'b1,                 // 0: rule probes only
  parameter bit          FwdDqsLocal   = 1'b0,                 // DQS_SRC of NIBBLE receivers
  // XPLL: PLL_CLK = REFCLK_FREQUENCY of the nibbles. 200 MHz x 15 / 1 = VCO 3000 MHz
  // (2160..4320), DIV2 -> 1500 MHz: AMD's MIPI_RX uses this for every rate <= 1500 Mbit/s.
  parameter real         ClkInPeriodNs = 5.0,
  parameter int unsigned XpllMult      = 15,
  parameter int unsigned XpllDivclk    = 1,
  parameter              XpllPhyDiv    = "DIV2",
  parameter real         PllClkMhz     = 1500.0,
  parameter bit          EnVtcEarly    = 1'b1,   // see "Options" above
  parameter bit          RdenReg       = 1'b1,
  parameter bit          BitRev        = 1'b0,
  parameter              SimDevice     = "VERSAL_PREMIUM"
) (
  // pads (top level ports, nothing in between)
  input  wire                   clk_p,
  input  wire                   clk_n,
  input  wire  [Lanes-1:0]      data_p,
  input  wire  [Lanes-1:0]      data_n,
  // clocks and reset
  input  logic                  ctrl_clk_i,       // free running CTRL_CLK (Huins: video clock)
  input  logic                  ctrl_rst_ni,      // async assert, release synchronous to ctrl_clk_i
  input  logic                  pll_clkin_i,      // XPLL CLKIN (from a BUFG)
  // run-time knobs, asynchronous levels (see "Run-time knobs" above; 0 = AMD-like)
  input  logic                  reinit_i,         // 1: held in the init reset, 1 -> 0: init again
  input  logic                  burst_rst_en_i,   // 1: RX_RST of the used slices while byte_ce_i = 0
  // status, ctrl_clk_i domain
  output logic                  phy_rdy_o,        // XPLL locked, BISC done, PHY_RDY of all nibbles
  output logic [3:0]            phy_status_o,     // {PHY_RDY all, DLY_RDY all, LOCKED_FB, LOCKED}
  // Bow32 D-PHY contract
  output logic                  byte_clk_o,       // strobe FIFO_WR_CLK (HS clock / 4) via BUFGCE
  input  logic                  byte_ce_i,        // BUFGCE CE (changes while the clock lane is static)
  input  logic                  byte_rst_i,       // unused on Versal
  output logic [1:0]            clk_lp_o,         // clock lane LP {P, N}, async
  input  logic                  clk_hs_en_i,      // 1: clock lane HS receiver on
  output logic [Lanes-1:0][1:0] lp_o,             // data lane LP {P, N}, async
  input  logic [Lanes-1:0]      hs_en_i,          // 1: data lane HS receiver on
  output logic [Lanes-1:0][7:0] rx_data_o,        // byte_clk_o domain, bit 0 = first bit
  output logic [Lanes-1:0]      rx_valid_o,       // byte_clk_o domain, new word this cycle
  output logic [7:0]            clk_q_o,          // byte_clk_o domain, clock lane samples
  input  logic [Lanes-1:0][8:0] dly_tap_i,        // ctrl domain: total input delay to load
  input  logic [Lanes-1:0]      dly_load_i,       // ctrl domain: one cycle load request
  output logic [Lanes-1:0][8:0] dly_tap_o         // ctrl domain: CNTVALUEOUT of the lane slice
);

  localparam int unsigned MaxNib = 4;
  localparam int unsigned RoleStrobe = 0, RoleNibble = 1, RoleByte = 2;

  // Input delay control (ctrl_clk_i cycles): the wait after RX_EN_VTC 1 -> 0 before the
  // first load of a lane (AM010 gives no number, the simulation model needs none:
  // UNVERIFIED; 12 keeps the first load inside the receiver's 16 cycle request spacing, so
  // every request of the DlyVid contract becomes its own load), and the minimum distance
  // between two loads of a lane (AM010: >= 3)
  localparam int unsigned VtcWait = 12;
  localparam int unsigned LdGap   = 4;

  // ---------------------------------------------------------------------------
  // Plan helpers (constant functions, elaboration time)
  // ---------------------------------------------------------------------------
  // (an index beyond the 4 parameter fields reads 0: plan_ok() then reports the plan)
  function automatic int unsigned phys_of(input int unsigned n);
    return (n < MaxNib) ? int'(NibPhys[4*n +: 4]) : 0;
  endfunction
  function automatic int unsigned bank_of(input int unsigned n);
    return (n < MaxNib) ? int'(NibBank[2*n +: 2]) : 0;
  endfunction
  function automatic int unsigned role_of(input int unsigned n);
    return (n < MaxNib) ? int'(NibRole[2*n +: 2]) : 0;
  endfunction
  function automatic int unsigned src_of(input int unsigned n);
    return (n < MaxNib) ? int'(NibSrc[2*n +: 2]) : 0;
  endfunction
  function automatic int unsigned lane_nib(input int unsigned l);
    return (l < 4) ? int'(LaneNib[2*l +: 2]) : 0;
  endfunction
  function automatic int unsigned lane_slice(input int unsigned l);
    return (l < 4) ? int'(LaneSlice[3*l +: 3]) : 0;
  endfunction

  // an inter-byte receiver n takes CLK_TO_LOWER of its source (nibbles 0-3 and 8) or
  // CLK_TO_UPPER (nibbles 4-7)
  function automatic bit uses_lower(input int unsigned n);
    return (phys_of(n) < 4) || (phys_of(n) == 8);
  endfunction

  // physical source nibble of an inter-byte receiver at physical nibble p
  function automatic int byte_src_phys(input int unsigned p);
    if (p < 4)  return int'(p) + 2;
    if (p == 8) return 6;
    return int'(p) - 2;
  endfunction

  // instance m drives CLK_TO_LOWER (lower = 1) / CLK_TO_UPPER (lower = 0) for a receiver
  function automatic bit fwd_byte(input int unsigned m, input bit lower);
    bit f;
    f = 1'b0;
    for (int unsigned n = 0; n < NumNib; n++)
      if ((role_of(n) == RoleByte) && (src_of(n) == m) && (uses_lower(n) == lower)) f = 1'b1;
    return f;
  endfunction

  function automatic int unsigned strobe_idx();
    int unsigned s;
    s = 0;
    for (int unsigned n = 0; n < NumNib; n++) if (role_of(n) == RoleStrobe) s = n;
    return s;
  endfunction

  // instance at (bank b, physical nibble p), -1 if none
  function automatic int inst_at(input int unsigned b, input int unsigned p);
    int r;
    r = -1;
    for (int unsigned n = 0; n < NumNib; n++)
      if ((bank_of(n) == b) && (phys_of(n) == p)) r = int'(n);
    return r;
  endfunction

  // source of NIBBLESLICE s of instance n: -1 clock lane, 0..Lanes-1 data lane, -2 none
  function automatic int slice_src(input int unsigned n, input int unsigned s);
    int src;
    src = -2;
    if ((role_of(n) == RoleStrobe) && (s == 0)) src = -1;
    for (int unsigned l = 0; l < Lanes; l++)
      if ((lane_nib(l) == n) && (lane_slice(l) == s)) src = int'(l);
    return src;
  endfunction

  // Slices used in XPHY mode = slices with a DATAIN (strobe slice 0, data P slices):
  // FIFO_MODE ASYNC, RX_RST / TX_RST driven. The N slice of a pair only carries the
  // complementary pad of the IBUFDS_DPHY; Vivado counts it as not used in XPHY mode and
  // rejects resets on it (DRC REQPXA-314/315/318).
  function automatic logic [5:0] used_mask(input int unsigned n);
    logic [5:0] m;
    m = '0;
    if (role_of(n) == RoleStrobe) m[0] = 1'b1;
    for (int unsigned l = 0; l < Lanes; l++)
      if (lane_nib(l) == n) m[lane_slice(l)] = 1'b1;
    return m;
  endfunction

  // XPHY Q -> byte. AM010 Table 2 (RX_DATA_WIDTH 8): the serial bits P0 N0 P1 N1 P2 N2 P3
  // N3 land in Q[4] Q[0] Q[5] Q[1] Q[6] Q[2] Q[7] Q[3] (AMD's bank wrapper applies the same
  // remap). P0 = first bit on the wire, D-PHY sends the LSB first (verified in xsim).
  function automatic logic [7:0] xphy_byte(input logic [7:0] q);
    logic [7:0] b, r;
    b = {q[3], q[7], q[2], q[6], q[1], q[5], q[0], q[4]};
    for (int i = 0; i < 8; i++) r[i] = b[7 - i];
    return BitRev ? r : b;
  endfunction

  // Plan check (elaboration).
  function automatic bit plan_ok();
    bit              ok;
    int unsigned     nstrobe;
    bit [MaxNib-1:0] reach;
    ok      = 1'b1;
    nstrobe = 0;
    if ((NumNib < 1) || (NumNib > MaxNib) || (Lanes < 1) || (Lanes > 4)) ok = 1'b0;
    if ((NumPll < 1) || (NumPll > 3)) ok = 1'b0;
    if (CheckPlan && (NumPll != 1)) ok = 1'b0;         // the strobe never leaves its bank
    for (int unsigned n = 0; n < NumNib; n++) begin
      if ((phys_of(n) > 8) || (bank_of(n) >= NumPll) || (role_of(n) > RoleByte)) ok = 1'b0;
      for (int unsigned k = 0; k < n; k++)
        if ((bank_of(k) == bank_of(n)) && (phys_of(k) == phys_of(n))) ok = 1'b0;
      if (role_of(n) == RoleStrobe) nstrobe++;
      else if ((src_of(n) >= NumNib) || (src_of(n) == n)) ok = 1'b0;
      else begin
        if (role_of(src_of(n)) == RoleNibble) ok = 1'b0;   // inter-nibble receivers forward nothing
        if (CheckPlan) begin
          if (bank_of(src_of(n)) != bank_of(n)) ok = 1'b0;
          if ((role_of(n) == RoleNibble) &&
              ((phys_of(n) == 8) || (phys_of(src_of(n)) != (phys_of(n) ^ 1)))) ok = 1'b0;
          if ((role_of(n) == RoleByte) && (int'(phys_of(src_of(n))) != byte_src_phys(phys_of(n))))
            ok = 1'b0;
        end
      end
    end
    if (nstrobe != 1) ok = 1'b0;
    // every nibble must be reachable from the strobe nibble
    reach = '0;
    for (int unsigned n = 0; n < NumNib; n++) if (role_of(n) == RoleStrobe) reach[n] = 1'b1;
    for (int unsigned it = 0; it < MaxNib; it++)
      for (int unsigned n = 0; n < NumNib; n++)
        if ((role_of(n) != RoleStrobe) && (src_of(n) < NumNib) && reach[src_of(n)]) reach[n] = 1'b1;
    for (int unsigned n = 0; n < NumNib; n++) if (!reach[n]) ok = 1'b0;
    for (int unsigned l = 0; l < Lanes; l++) begin
      if ((lane_slice(l) % 2 != 0) || (lane_slice(l) > 4) || (lane_nib(l) >= NumNib)) ok = 1'b0;
      else if ((role_of(lane_nib(l)) == RoleStrobe) && (lane_slice(l) == 0)) ok = 1'b0;
      for (int unsigned k = 0; k < l; k++)
        if ((lane_nib(k) == lane_nib(l)) && (lane_slice(k) == lane_slice(l))) ok = 1'b0;
    end
    return ok;
  endfunction

  if (!plan_ok()) begin : g_bad_plan
    $error("bow_dphy_io_versal: inconsistent nibble plan (NibPhys/NibBank/NibRole/NibSrc/LaneNib/LaneSlice/NumPll)");
  end

  localparam int unsigned StrobeIdx = strobe_idx();

  // ---------------------------------------------------------------------------
  // Input buffers. IBUFDS_DPHY with SIM_DEVICE VERSAL_PREMIUM (DPHY_DIFFINBUF is the
  // SIMPRIM cell behind it and cannot be instantiated); IOSTANDARD MIPI_DPHY and the
  // termination come from the XDC. HSRX_DISABLE = 1 also gives HSRX_O = 0, so the strobe
  // is static while the lane is in LP. The LP receivers stay on (as AMD).
  // ---------------------------------------------------------------------------
  logic             clk_hs;
  logic [Lanes-1:0] lane_hs;

  IBUFDS_DPHY #(
    .SIM_DEVICE (SimDevice)
  ) u_clk_ibuf (
    .I            (clk_p),
    .IB           (clk_n),
    .HSRX_DISABLE (~clk_hs_en_i),
    .LPRX_DISABLE (1'b0),
    .HSRX_O       (clk_hs),
    .LPRX_O_P     (clk_lp_o[1]),
    .LPRX_O_N     (clk_lp_o[0])
  );

  for (genvar l = 0; l < Lanes; l++) begin : g_ibuf
    IBUFDS_DPHY #(
      .SIM_DEVICE (SimDevice)
    ) u_ibuf (
      .I            (data_p[l]),
      .IB           (data_n[l]),
      .HSRX_DISABLE (~hs_en_i[l]),
      .LPRX_DISABLE (1'b0),
      .HSRX_O       (lane_hs[l]),
      .LPRX_O_P     (lp_o[l][1]),
      .LPRX_O_N     (lp_o[l][0])
    );
  end

  // ---------------------------------------------------------------------------
  // Init sequencer, ctrl_clk_i domain, in the order of the AM010 reset sequence
  // (SERIAL_MODE FALSE) and of AMD's Advanced I/O Wizard reset state machine:
  // XPLL reset -> LOCKED_FB -> release RST / RX_RST / TX_RST -> 64 CTRL_CLK ->
  // CLKOUTPHYEN -> (EnVtcEarly = 0: wait DLY_RDY, then EN_VTC) -> PHY_RDY of all nibbles
  // for 16 cycles (PLL_CLK >= 500 MHz: wait PHY_RDY, not DLY_RDY) -> ready while PHY_RDY
  // and LOCKED. A loss of LOCKED_FB takes the whole interface back to reset, and reinit_i
  // holds it there (the release starts at the XPLL reset again).
  // BISC completes with the clock lane idle in LP-11 (xsim: ~38 us after the release; AM010
  // allows up to 1.3 ms in silicon) and with the clock lane toggling (xsim).
  // ---------------------------------------------------------------------------
  logic [NumPll-1:0] pll_locked, pll_locked_fb;
  logic [MaxNib-1:0] dly_rdy_n, phy_rdy_n;
  logic              dly_rdy_all, phy_rdy_all, lock_all, lock_fb_all;

  always_comb begin
    dly_rdy_all = 1'b1;
    phy_rdy_all = 1'b1;
    for (int unsigned n = 0; n < NumNib; n++) begin
      dly_rdy_all &= dly_rdy_n[n];
      phy_rdy_all &= phy_rdy_n[n];
    end
    lock_all    = &pll_locked;
    lock_fb_all = &pll_locked_fb;
  end

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_lock_fb, sync_lock, sync_dly, sync_phy;
  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_reinit, sync_burst;

  always_ff @(posedge ctrl_clk_i or negedge ctrl_rst_ni) begin
    if (!ctrl_rst_ni) begin
      sync_lock_fb <= '0;
      sync_lock    <= '0;
      sync_dly     <= '0;
      sync_phy     <= '0;
      sync_reinit  <= '0;
      sync_burst   <= '0;
    end else begin
      sync_lock_fb <= {sync_lock_fb[0], lock_fb_all};
      sync_lock    <= {sync_lock[0],    lock_all};
      sync_dly     <= {sync_dly[0],     dly_rdy_all};
      sync_phy     <= {sync_phy[0],     phy_rdy_all};
      sync_reinit  <= {sync_reinit[0],  reinit_i};
      sync_burst   <= {sync_burst[0],   burst_rst_en_i};
    end
  end

  logic lock_fb_s, lock_s, dly_s, phy_s, reinit_s, burst_en_s;
  assign lock_fb_s  = sync_lock_fb[1];
  assign lock_s     = sync_lock[1];
  assign dly_s      = sync_dly[1];
  assign phy_s      = sync_phy[1];
  assign reinit_s   = sync_reinit[1];
  assign burst_en_s = sync_burst[1];

  typedef enum logic [2:0] {
    SPllRst, SLock, SRelease, SDly, SPhy, SReady
  } seq_e;

  seq_e       seq_q;
  logic [6:0] cnt_q;
  logic       pll_rst_q, xphy_rst_q, clkoutphyen_q, en_vtc_q, ready_q;

  always_ff @(posedge ctrl_clk_i or negedge ctrl_rst_ni) begin
    if (!ctrl_rst_ni) begin
      seq_q         <= SPllRst;
      cnt_q         <= '0;
      pll_rst_q     <= 1'b1;
      xphy_rst_q    <= 1'b1;
      clkoutphyen_q <= 1'b0;
      en_vtc_q      <= EnVtcEarly;
      ready_q       <= 1'b0;
    end else if (reinit_s || ((seq_q != SPllRst) && (seq_q != SLock) && !lock_fb_s)) begin
      // reinit_i, or a loss of XPLL lock: back to the XPLL reset (held while reinit_i = 1)
      seq_q         <= SPllRst;
      cnt_q         <= '0;
      pll_rst_q     <= 1'b1;
      xphy_rst_q    <= 1'b1;
      clkoutphyen_q <= 1'b0;
      en_vtc_q      <= EnVtcEarly;
      ready_q       <= 1'b0;
    end else begin
      cnt_q <= cnt_q + 7'd1;
      unique case (seq_q)
        SPllRst: if (cnt_q == 7'd15) begin       // XPLL RST >= 16 ctrl cycles
          pll_rst_q <= 1'b0;
          seq_q     <= SLock;
        end
        SLock: if (lock_fb_s) begin
          xphy_rst_q <= 1'b0;                     // RST, RX_RST, TX_RST together (AMD)
          cnt_q      <= '0;
          seq_q      <= SRelease;
        end
        SRelease: if (cnt_q == 7'd64) begin       // 64 CTRL_CLK after the release
          clkoutphyen_q <= 1'b1;
          seq_q         <= EnVtcEarly ? SPhy : SDly;
          cnt_q         <= '0;
        end
        SDly: if (dly_s) begin                    // BISC alignment + delay calibration done
          en_vtc_q <= 1'b1;
          seq_q    <= SPhy;
          cnt_q    <= '0;
        end
        SPhy: begin
          if (!phy_s) cnt_q <= '0;
          else if (cnt_q == 7'd16) begin          // PHY_RDY stable for 16 CTRL_CLK
            ready_q <= 1'b1;
            seq_q   <= SReady;
          end
        end
        SReady: ready_q <= phy_s && lock_s;
        default: seq_q <= SPllRst;
      endcase
    end
  end

  assign phy_rdy_o    = ready_q;
  assign phy_status_o = {phy_s, dly_s, lock_fb_s, lock_s};

  // burst_rst_en_i = 1: RX_RST (asynchronous, "does not reset the input delay", AM010) of
  // the used slices while the byte clock gate is closed. RX_RST = the init reset OR this
  // flop, two flops of one domain: the burst term is 0 unless ready_q = 1, and xphy_rst_q
  // only changes while ready_q = 0 or rises when ready_q falls. The only cycle in which
  // they can move in opposite directions (the gate opens as a re-init starts) asserts RST
  // of the whole nibble at the same edge, so a glitch of the OR does no harm.
  logic burst_rst_q;

  always_ff @(posedge ctrl_clk_i or negedge ctrl_rst_ni) begin
    if (!ctrl_rst_ni) burst_rst_q <= 1'b0;
    else              burst_rst_q <= burst_en_s & ready_q & ~byte_ce_i;
  end

  logic slice_rst;
  assign slice_rst = xphy_rst_q | burst_rst_q;

  // ---------------------------------------------------------------------------
  // XPLL, one per bank (CLKOUTPHY reaches only the nibbles of its own bank). No deskew:
  // AMD adds the CLKOUT0 / CLKOUT3 deskew loop for its fabric clocks; in strobe mode the
  // fabric side runs on the strobe derived byte clock. CLKOUT0..3 unused (/16, in range).
  // ---------------------------------------------------------------------------
  logic [NumPll-1:0] pll_clk;

  for (genvar b = 0; b < NumPll; b++) begin : g_pll
    XPLL #(
      .CLKIN_PERIOD     (ClkInPeriodNs),
      .CLKFBOUT_MULT    (XpllMult),
      .DIVCLK_DIVIDE    (XpllDivclk),
      .CLKOUTPHY_DIVIDE (XpllPhyDiv),
      .CLKOUT0_DIVIDE   (16),
      .CLKOUT1_DIVIDE   (16),
      .CLKOUT2_DIVIDE   (16),
      .CLKOUT3_DIVIDE   (16),
      .REF_JITTER       (0.010)
    ) u_xpll (
      .CLKIN              (pll_clkin_i),
      .RST                (pll_rst_q),
      .PWRDWN             (1'b0),
      .CLKOUTPHYEN        (clkoutphyen_q),
      .CLKOUTPHY          (pll_clk[b]),
      .CLKOUT0            (),
      .CLKOUT1            (),
      .CLKOUT2            (),
      .CLKOUT3            (),
      .LOCKED             (pll_locked[b]),
      .LOCKED_FB          (pll_locked_fb[b]),
      .LOCKED1_DESKEW     (),
      .LOCKED2_DESKEW     (),
      .CLKFB1_DESKEW      (1'b0),
      .CLKFB2_DESKEW      (1'b0),
      .CLKIN1_DESKEW      (1'b0),
      .CLKIN2_DESKEW      (1'b0),
      .CLKOUTPHY_CASC_IN  (1'b0),
      .CLKOUTPHY_CASC_OUT (),
      .DADDR              (7'h00),
      .DCLK               (1'b0),
      .DEN                (1'b0),
      .DI                 (16'h0000),
      .DWE                (1'b0),
      .DO                 (),
      .DRDY               (),
      .PSCLK              (1'b0),
      .PSEN               (1'b0),
      .PSINCDEC           (1'b0),
      .PSDONE             (),
      .RIU_ADDR           (8'h00),
      .RIU_CLK            (1'b0),
      .RIU_NIBBLE_SEL     (1'b0),
      .RIU_WR_DATA        (16'h0000),
      .RIU_WR_EN          (1'b0),
      .RIU_RD_DATA        (),
      .RIU_VALID          ()
    );
  end

  // ---------------------------------------------------------------------------
  // Input delay control (ctrl_clk_i domain), see "Input delays" in the header. Per lane:
  // user_q = user mode (RX_EN_VTC = 0 on the lane's P slice), pend_q = a load is waiting,
  // wait_q = cycles until it may happen, cntin_q = the tap of the next / last load.
  // ---------------------------------------------------------------------------
  logic [Lanes-1:0]      user_q, pend_q, ld_q;
  logic [Lanes-1:0][8:0] cntin_q;
  logic [Lanes-1:0][4:0] wait_q;

  // Next state in blocking variables, one non-blocking write per register (xsim bug (a)).
  always_ff @(posedge ctrl_clk_i or negedge ctrl_rst_ni) begin
    logic [Lanes-1:0]      user_d, pend_d, ld_d;
    logic [Lanes-1:0][8:0] cntin_d;
    logic [Lanes-1:0][4:0] wait_d;
    if (!ctrl_rst_ni) begin
      user_q  <= '0;
      pend_q  <= '0;
      ld_q    <= '0;
      cntin_q <= '0;
      wait_q  <= '0;
    end else begin
      user_d  = user_q;
      pend_d  = pend_q;
      ld_d    = '0;
      cntin_d = cntin_q;
      wait_d  = wait_q;
      if (!ready_q) begin
        user_d = '0;
        pend_d = '0;
        wait_d = '0;
      end else begin
        for (int unsigned l = 0; l < Lanes; l++) begin
          if (wait_q[l] != 5'd0) wait_d[l] = wait_q[l] - 5'd1;
          if (pend_q[l] && (wait_q[l] == 5'd0)) begin
            ld_d[l]   = 1'b1;                     // XPHY samples LD and cntin_q next edge
            pend_d[l] = 1'b0;
            wait_d[l] = 5'(LdGap - 1);
          end
          if (dly_load_i[l]) begin                // the newest request wins
            cntin_d[l] = dly_tap_i[l];
            pend_d[l]  = 1'b1;
            if (!user_q[l]) begin
              user_d[l] = 1'b1;                   // RX_EN_VTC -> 0 first
              wait_d[l] = 5'(VtcWait);
            end
          end
        end
      end
      user_q  <= user_d;
      pend_q  <= pend_d;
      ld_q    <= ld_d;
      cntin_q <= cntin_d;
      wait_q  <= wait_d;
    end
  end

  // ---------------------------------------------------------------------------
  // XPHY nibbles
  // ---------------------------------------------------------------------------
  wire  [MaxNib-1:0]       fifo_empty, fifo_wr_clk;
  wire  [MaxNib-1:0]       clk_to_upper, clk_to_lower, pclk_out, nclk_out;
  wire  [MaxNib-1:0]       bisc_start_in, bisc_start_out, bisc_stop_in, bisc_stop_out;
  wire  [7:0]              q_nib [MaxNib][6];
  wire  [MaxNib-1:0][53:0] cntout_nib;
  logic [MaxNib-1:0]       rden;
  logic                    byte_clk;

  // BISC daisy chain, per bank in physical nibble order (as AMD's bank wrapper): START runs
  // up, STOP runs down, the lowest nibble's START comes from its own STOP, the top STOP
  // input is 1. Dedicated wires between neighbours; the simulation model needs them too.
  for (genvar b = 0; b < NumPll; b++) begin : g_bisc
    wire [9:0] start_w, stop_w;
    wire       unused_start;
    assign start_w[0]   = stop_w[0];
    assign stop_w[9]    = 1'b1;
    assign unused_start = start_w[9];             // START out of the top nibble: open
    for (genvar p = 0; p < 9; p++) begin : g_p
      localparam int N = inst_at(b, p);
      if (N >= 0) begin : g_inst
        assign bisc_start_in[N] = start_w[p];
        assign start_w[p+1]     = bisc_start_out[N];
        assign bisc_stop_in[N]  = stop_w[p+1];
        assign stop_w[p]        = bisc_stop_out[N];
      end else begin : g_skip
        assign stop_w[p]    = stop_w[p+1];
        assign start_w[p+1] = start_w[p];
      end
    end
  end

  for (genvar n = 0; n < NumNib; n++) begin : g_nib
    localparam int unsigned Role     = role_of(n);
    localparam int unsigned Src      = src_of(n);
    localparam bit          IsStrobe = (Role == RoleStrobe);
    localparam bit          IsNibble = (Role == RoleNibble);
    localparam bit          IsByte   = (Role == RoleByte);
    localparam bit          FwdLower = fwd_byte(n, 1'b1);
    localparam bit          FwdUpper = fwd_byte(n, 1'b0);
    localparam logic [5:0]  Used     = used_mask(n);

    logic [5:0]  datain, ld, rx_en_vtc, slice_rst_v;
    logic [53:0] cntin;
    logic        clk_from_other, pclk_in, nclk_in;

    // Per slice, a static mapping as genvar / localparam (xsim bug (b)): DATAIN straight
    // from the IBUFDS_DPHY HSRX_O (dedicated IOB -> nibble path); delay control on the data
    // P slices, RX_EN_VTC 1 everywhere else (as AMD).
    for (genvar s = 0; s < 6; s++) begin : g_din
      localparam int SlSrc = slice_src(n, s);
      if (SlSrc == -1) begin : g_clk
        assign datain[s]       = clk_hs;
        assign ld[s]           = 1'b0;
        assign cntin[9*s +: 9] = '0;
        assign rx_en_vtc[s]    = 1'b1;
      end else if (SlSrc >= 0) begin : g_lane
        assign datain[s]       = lane_hs[SlSrc];
        assign ld[s]           = ld_q[SlSrc];
        assign cntin[9*s +: 9] = cntin_q[SlSrc];
        assign rx_en_vtc[s]    = ~user_q[SlSrc];
      end else begin : g_none
        assign datain[s]       = 1'b0;
        assign ld[s]           = 1'b0;
        assign cntin[9*s +: 9] = '0;
        assign rx_en_vtc[s]    = 1'b1;
      end
    end

    // RX_RST / TX_RST: the init (and optional burst) reset on the used slices only
    assign slice_rst_v = Used & {6{slice_rst}};

    // Strobe forwarding inputs; unused ones tied like AMD's bank wrapper ties a missing
    // neighbour (CLK_FROM_OTHER_XPHY 1, PCLK/NCLK_NIBBLE_IN 0).
    if (IsNibble) begin : g_fwd_nib
      assign pclk_in        = pclk_out[Src];
      assign nclk_in        = nclk_out[Src];
      assign clk_from_other = 1'b1;
    end else if (IsByte) begin : g_fwd_byte
      assign pclk_in        = 1'b0;
      assign nclk_in        = 1'b0;
      assign clk_from_other = uses_lower(n) ? clk_to_lower[Src] : clk_to_upper[Src];
    end else begin : g_strobe
      assign pclk_in        = 1'b0;
      assign nclk_in        = 1'b0;
      assign clk_from_other = 1'b1;
    end

    XPHY #(
      // ---- receive mode: strobe based source synchronous capture ----
      .SERIAL_MODE          ("FALSE"),     // strobe mode (serial mode has no strobe)
      .DQS_SRC              ((IsStrobe || (IsNibble && FwdDqsLocal)) ? "LOCAL" : "EXTERN"),
                                           // LOCAL: strobe from DATAIN[0] of this nibble;
                                           // EXTERN: forwarded strobe (AMD: EXTERN on
                                           // inter-nibble and inter-byte receivers)
      .CONTINUOUS_DQS       ("FALSE"),     // the clock lane may stop between bursts
      .RX_GATING            ("DISABLE"),   // no DQS gate, PHY_RDEN ignored
      .RX_DATA_WIDTH        (8),           // 1:8, FIFO_WR_CLK = strobe / 4 = 180 MHz
      .RX_CLK_PHASE_P       ("SHIFT_0"),   // the D-PHY clock is already in quadrature
      .RX_CLK_PHASE_N       ("SHIFT_0"),   //   with the data (centre aligned DDR)
      .INV_RXCLK            ("FALSE"),     // must be FALSE with DQS_SRC EXTERN
      .CRSE_DLY_EN          ("FALSE"),     // coarse delay: edge aligned <= 1 GHz only
      .SELF_CALIBRATE       ("ENABLE"),    // BISC: aligns strobe and data paths incl. the
                                           //   inter-nibble / inter-byte forwarding skew
      .REFCLK_FREQUENCY     (PllClkMhz),   // = PLL_CLK in MHz
      .EN_CLK_TO_UPPER      (FwdUpper ? "ENABLE" : "DISABLE"),  // only on the source of
      .EN_CLK_TO_LOWER      (FwdLower ? "ENABLE" : "DISABLE"),  //   an inter-byte receiver
      .EN_OTHER_PCLK        (IsNibble ? "TRUE" : "FALSE"),      // inter-nibble receiver
      .EN_OTHER_NCLK        (IsNibble ? "TRUE" : "FALSE"),
      .DIS_IDLY_VT_TRACK    ("FALSE"),     // VT tracking on
      .DIS_ODLY_VT_TRACK    ("FALSE"),
      .DIS_QDLY_VT_TRACK    ("FALSE"),
      .DELAY_VALUE_0        (0),           // must be 0 on the strobe slice; the data lanes
      .DELAY_VALUE_1        (0),           //   start at the BISC position and are moved at
      .DELAY_VALUE_2        (0),           //   run time (dly_load_i)
      .DELAY_VALUE_3        (0),
      .DELAY_VALUE_4        (0),
      .DELAY_VALUE_5        (0),
      .CASCADE_0            ("FALSE"),     // TRUE would double the input delay range
      .CASCADE_1            ("FALSE"),     //   (>= 1250 ps, RX only): not needed at a
      .CASCADE_2            ("FALSE"),     //   694 ps UI
      .CASCADE_3            ("FALSE"),
      .CASCADE_4            ("FALSE"),
      .CASCADE_5            ("FALSE"),
      .FIFO_MODE_0          (Used[0] ? "ASYNC" : "BYPASS"),  // ASYNC: read clock of the
      .FIFO_MODE_1          (Used[1] ? "ASYNC" : "BYPASS"),  //   write frequency, any
      .FIFO_MODE_2          (Used[2] ? "ASYNC" : "BYPASS"),  //   phase: the only mode for
      .FIFO_MODE_3          (Used[3] ? "ASYNC" : "BYPASS"),  //   a stopping strobe. BYPASS
      .FIFO_MODE_4          (Used[4] ? "ASYNC" : "BYPASS"),  //   on slices without DATAIN
      .FIFO_MODE_5          (Used[5] ? "ASYNC" : "BYPASS"),  //   (N sides, unused)
      // ---- memory / transmit features: defaults (= AMD's MIPI_RX values) ----
      .DQS_MODE             ("DDR4_1TCK"),
      .EN_DYN_DLY_MODE      ("FALSE"),
      .FAST_CK              ("FALSE"),
      .LP4_DQS              ("FALSE"),
      .WRITE_LEVELING       ("FALSE"),
      .PRIME_VAL            (1'b0),
      .IBUF_DIS_SRC_0       ("EXTERNAL"),
      .IBUF_DIS_SRC_1       ("EXTERNAL"),
      .IBUF_DIS_SRC_2       ("EXTERNAL"),
      .IBUF_DIS_SRC_3       ("EXTERNAL"),
      .IBUF_DIS_SRC_4       ("EXTERNAL"),
      .IBUF_DIS_SRC_5       ("EXTERNAL"),
      .ODT_SRC_0            ("EXTERNAL"),
      .ODT_SRC_1            ("EXTERNAL"),
      .ODT_SRC_2            ("EXTERNAL"),
      .ODT_SRC_3            ("EXTERNAL"),
      .ODT_SRC_4            ("EXTERNAL"),
      .ODT_SRC_5            ("EXTERNAL"),
      .ODELAY_BYPASS_0      ("FALSE"),
      .ODELAY_BYPASS_1      ("FALSE"),
      .ODELAY_BYPASS_2      ("FALSE"),
      .ODELAY_BYPASS_3      ("FALSE"),
      .ODELAY_BYPASS_4      ("FALSE"),
      .ODELAY_BYPASS_5      ("FALSE"),
      .TBYTE_CTL_0          ("T"),
      .TBYTE_CTL_1          ("T"),
      .TBYTE_CTL_2          ("T"),
      .TBYTE_CTL_3          ("T"),
      .TBYTE_CTL_4          ("T"),
      .TBYTE_CTL_5          ("T"),
      .TXRX_LOOPBACK_0      ("FALSE"),
      .TXRX_LOOPBACK_1      ("FALSE"),
      .TXRX_LOOPBACK_2      ("FALSE"),
      .TXRX_LOOPBACK_3      ("FALSE"),
      .TXRX_LOOPBACK_4      ("FALSE"),
      .TXRX_LOOPBACK_5      ("FALSE"),
      .TX_DATA_WIDTH        (8),
      .TX_GATING            ("DISABLE"),
      .TX_INIT_0            (1'b0),
      .TX_INIT_1            (1'b0),
      .TX_INIT_2            (1'b0),
      .TX_INIT_3            (1'b0),
      .TX_INIT_4            (1'b0),
      .TX_INIT_5            (1'b0),
      .TX_INIT_TRI          (1'b1),
      .TX_OUTPUT_PHASE_90_0 ("FALSE"),
      .TX_OUTPUT_PHASE_90_1 ("FALSE"),
      .TX_OUTPUT_PHASE_90_2 ("FALSE"),
      .TX_OUTPUT_PHASE_90_3 ("FALSE"),
      .TX_OUTPUT_PHASE_90_4 ("FALSE"),
      .TX_OUTPUT_PHASE_90_5 ("FALSE"),
      .TX_OUTPUT_PHASE_90_TRI ("FALSE")
    ) u_xphy (
      // clocks
      .PLL_CLK             (pll_clk[bank_of(n)]),   // XPLL CLKOUTPHY of the same bank
      .CTRL_CLK            (ctrl_clk_i),
      .FIFO_RD_CLK         (byte_clk),              // the BUFG of the strobe FIFO_WR_CLK
      .FIFO_WR_CLK         (fifo_wr_clk[n]),
      // resets / calibration
      .RST                 (xphy_rst_q),
      .RX_RST              (slice_rst_v),
      .TX_RST              (slice_rst_v),
      .EN_VTC              (en_vtc_q),
      .RX_EN_VTC           (rx_en_vtc),
      .TX_EN_VTC           (6'h3F),
      .DLY_RDY             (dly_rdy_n[n]),
      .PHY_RDY             (phy_rdy_n[n]),
      .BISC_START_IN       (bisc_start_in[n]),
      .BISC_START_OUT      (bisc_start_out[n]),
      .BISC_STOP_IN        (bisc_stop_in[n]),
      .BISC_STOP_OUT       (bisc_stop_out[n]),
      // strobe forwarding
      .CLK_FROM_OTHER_XPHY (clk_from_other),
      .CLK_TO_UPPER        (clk_to_upper[n]),
      .CLK_TO_LOWER        (clk_to_lower[n]),
      .PCLK_NIBBLE_IN      (pclk_in),
      .NCLK_NIBBLE_IN      (nclk_in),
      .PCLK_NIBBLE_OUT     (pclk_out[n]),
      .NCLK_NIBBLE_OUT     (nclk_out[n]),
      // receive data
      .DATAIN              (datain),
      .FIFO_RDEN           (rden[n]),
      .FIFO_EMPTY          (fifo_empty[n]),
      .PHY_RDEN            (4'h0),                  // ignored with RX_GATING DISABLE
      .Q0                  (q_nib[n][0]),
      .Q1                  (q_nib[n][1]),
      .Q2                  (q_nib[n][2]),
      .Q3                  (q_nib[n][3]),
      .Q4                  (q_nib[n][4]),
      .Q5                  (q_nib[n][5]),
      // input delays (CTRL_CLK domain)
      .CE                  (6'h00),
      .INC                 (6'h00),
      .LD                  (ld),
      .RXTX_SEL            (6'h00),                 // 0 = input delay (load and readback)
      .CNTVALUEIN          (cntin),
      .CNTVALUEOUT         (cntout_nib[n]),
      // transmit side unused
      .D0                  (8'h00),
      .D1                  (8'h00),
      .D2                  (8'h00),
      .D3                  (8'h00),
      .D4                  (8'h00),
      .D5                  (8'h00),
      .T                   (6'h00),
      .O0                  (),
      .T_OUT               (),
      .PHY_WREN            (4'h0),
      .PHY_RDCS0           (4'hF),
      .PHY_RDCS1           (4'hF),
      .PHY_WRCS0           (4'hF),
      .PHY_WRCS1           (4'hF),
      .GT_STATUS           (),
      .IBUF_DISABLE        (),
      .DYN_DCI             (),
      // RIU unused (delays through the PL ports)
      .RIU_ADDR            (8'h00),
      .RIU_NIBBLE_SEL      (1'b0),
      .RIU_WR_DATA         (16'h0000),
      .RIU_WR_EN           (1'b0),
      .RIU_RD_DATA         (),
      .RIU_RD_VALID        ()
    );
  end

  for (genvar n = NumNib; n < MaxNib; n++) begin : g_nonib
    assign fifo_empty[n]     = 1'b1;
    assign fifo_wr_clk[n]    = 1'b0;
    assign clk_to_upper[n]   = 1'b1;
    assign clk_to_lower[n]   = 1'b1;
    assign pclk_out[n]       = 1'b0;
    assign nclk_out[n]       = 1'b0;
    assign dly_rdy_n[n]      = 1'b1;
    assign phy_rdy_n[n]      = 1'b1;
    assign bisc_start_in[n]  = 1'b0;
    assign bisc_start_out[n] = 1'b0;
    assign bisc_stop_in[n]   = 1'b0;
    assign bisc_stop_out[n]  = 1'b0;
    assign cntout_nib[n]     = '0;
    for (genvar s = 0; s < 6; s++) begin : g_q
      assign q_nib[n][s] = 8'h00;
    end
  end

  // ---------------------------------------------------------------------------
  // Byte clock: FIFO_WR_CLK of the strobe nibble (720 MHz strobe / 4 = 180 MHz at 1440
  // Mbit/s) through a BUFGCE in the bank's clock region. AMD uses a plain BUFG; the CE keeps
  // the Bow32 gating. CE_TYPE SYNC: no runt pulse from CE. The XDC selects this buffer by
  // its instance name (u_byte_bufg), keep it.
  // ---------------------------------------------------------------------------
  BUFGCE #(
    .CE_TYPE    ("SYNC"),
    .SIM_DEVICE (SimDevice)
  ) u_byte_bufg (
    .I  (fifo_wr_clk[StrobeIdx]),
    .CE (byte_ce_i),
    .O  (byte_clk)
  );

  assign byte_clk_o = byte_clk;

  // ---------------------------------------------------------------------------
  // FIFO read side (byte clock domain). Every nibble reads whenever its FIFO is not empty;
  // all FIFOs are written by the same strobe, so they run in step. RdenReg = 1 registers
  // FIFO_EMPTY once (no reset, starts empty) and reads with its inverse (as AMD).
  // ---------------------------------------------------------------------------
  logic [MaxNib-1:0] empty_q = '1;

  always_ff @(posedge byte_clk) empty_q <= fifo_empty;

  assign rden = RdenReg ? ~empty_q : ~fifo_empty;

  // Capture: Q straight into flops (BLI TRUE in the XDC: the flops sit in the XPIO's
  // BLI sites), the bit order remap is wiring only. rx_valid_o: the word now in the capture
  // flops was read (FIFO_RDEN one byte clock earlier). The clock lane samples are kept even
  // when clk_q_o is not used (DONT_TOUCH): the strobe slice then has the same read path as
  // in the verified builds.
  (* DONT_TOUCH = "TRUE" *) logic [7:0] clk_bli_q;
  logic [MaxNib-1:0] rden_q;

  always_ff @(posedge byte_clk) begin
    clk_bli_q <= q_nib[StrobeIdx][0];
    rden_q    <= rden;
  end

  for (genvar l = 0; l < Lanes; l++) begin : g_lane_out
    localparam int unsigned Nib = lane_nib(l);
    localparam int unsigned Sl  = lane_slice(l);
    logic [7:0] bli_q;
    logic       valid_q;

    always_ff @(posedge byte_clk) begin
      bli_q   <= q_nib[Nib][Sl];
      valid_q <= rden_q[Nib];
    end

    assign rx_data_o[l]  = xphy_byte(bli_q);
    assign rx_valid_o[l] = valid_q;
    assign dly_tap_o[l]  = cntout_nib[Nib][9*Sl +: 9];
  end

  assign clk_q_o = xphy_byte(clk_bli_q);

  logic unused;
  assign unused = ^{byte_rst_i, clk_to_upper, clk_to_lower, pclk_out, nclk_out, fifo_wr_clk,
                    cntout_nib, bisc_start_in, bisc_stop_in};

endmodule
