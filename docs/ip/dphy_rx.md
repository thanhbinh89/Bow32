# D-PHY số (`bow_dphy_rx`) và thanh ghi D-PHY (`0x4000_8C00`)

Phần số của D-PHY RX của Bow32: máy LP, timer, cổng byte clock, dò sync và căn byte, đồng hồ đo
byte clock, RAW và, từ bước 4 của kế hoạch chuyển ([mipi_rx_arch.md](mipi_rx_arch.md) mục 10),
**thanh ghi riêng** ở `0x4000_8C00` (offset `0xC00` của cửa sổ 4 KiB `CSI2RX`). Nó nói PPI
(`bow_ppi_pkg`, [mipi_rx_arch.md](mipi_rx_arch.md) mục 5) với controller CSI-2 `bow_csi2rx`
([csi2rx.md](csi2rx.md)); `bow_mipi_rx` (instance `u_csi2rx` trong `bow32_top`) ghép hai khối và
chia cửa sổ thanh ghi. Phía dưới, từ bước 5, là **giao diện AFE** ([mipi_rx_arch.md](mipi_rx_arch.md)
mục 3.2; mục *Giao diện AFE* dưới đây): trên FPGA hai adapter hiện thực nó bằng primitive
(`bow_dphy_io_xusp` trên KV260, `bow_dphy_io_versal` trên Huins, mục 3.7 của đặc tả). Đặc tả đầy
đủ (mọi trường, cả những trường của các bước sau): [mipi_rx_arch.md](mipi_rx_arch.md) mục 4.10;
tài liệu này là **v1.x**, tức những gì RTL có từ bước 4, 5 và 6 (bước 6: các chức năng D-PHY v1.x,
mục *Chức năng v1.x* dưới đây, với các sửa sau review của bước 6).

| Thông số | Giá trị |
|---|---|
| RTL | `hw/ip/dphy_rx/rtl/`: `bow_dphy_rx.sv` (khối), `bow_dphy_rx_regs.sv` (thanh ghi, miền bus), `bow_dphy_raw.sv` (RAW), `bow_dphy_lp.sv` (máy LP), `bow_dphy_align.sv` (aligner), `bow_ppi_err_tx.sv` (bộ đếm gray lỗi của PPI, bước 6); `hw/ip/dphy_rx/dphy_rx.f` (cần `common.f`, `bus.f`) |
| Thanh ghi | cửa sổ 1 KiB ở `0x4000_8C00` (`bow_mipi_rx` chuyển offset `0xC00`–`0xFFF` của `CSI2RX` cho D-PHY); ngắt `irq_o` vào `IRQ_STATUS[5]` của controller (chung `irq_fast[7]`) |
| Driver | `sw/common/include/bow_dphy_rx.h` (mọi tên có tiền tố `DPHY_`), `sw/common/src/bow_dphy_rx.c` |
| Clock | `clk_i` (bus, 50 MHz), `lp_clk_i` (miền lp; FPGA: `vid_clk`, 200 MHz), `afe_hs_byte_clk_i` (byte clock của AFE, bị gate bằng `afe_clk_gate_en_o`) |
| Reset | của chính D-PHY (mục 4.11 của đặc tả): `rst_ni` (bus), `rst_ni & lp_rst_ni` đồng bộ ở miền lp (`u_lrst`) và miền byte (`u_brst`); không còn reset dùng chung với controller |

## Tham số

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `Lanes` | 2 | data lane 1, 2 hoặc 4 (giá trị khác: lỗi elaborate) |
| `LpClkHz` | 200 MHz | tần số `lp_clk_i`: `INFO[17:8]` (MHz, bão hoà ở 1023) |
| `BusClkHz` | 0 | tần số `clk_i` (0 = không kiểm); elaborate báo lỗi nếu `lp_clk` > 12 × `clk_i` (bộ đếm gray sự kiện miền lp về bus, bước 6; trước đó xung, 16/3 ×) |
| `AfeKind` | 1 | `INFO[7:5]`: 0 macro ASIC, 1 adapter UltraScale+, 2 adapter Versal, 3 mô hình; chọn mặc định của `AfeSettle*`, `AfeTrailB` và `INFO[23]` (= 1 khi 2). Thay `DlyVid` của bước 4 (`DlyVid` = 1 ↔ `AfeKind` = 2): từ bước 5 giao thức nạp delay không còn trong D-PHY |
| `AfeSettleNs`, `AfeSettleUi` | 107 / 24 (UltraScale+), 120 / 0 (Versal) | `INFO2[15:0]`: đích của `SETTLE` (mục *SETTLE*) |
| `AfeTrailB` | 0 (UltraScale+), 8 (Versal) | `INFO2[23:16]`: byte thêm mỗi lane cuối burst do AFE (FIFO RX của XPHY) |
| `AfePdRst` | 0 | `AFE_CTRL.PD` sau reset: 1 cho ASIC (AFE tắt tới khi driver bật), 0 cho FPGA (XPLL, BISC chạy ngay sau khi nạp bitstream, như trước bước 5) |
| `TrimW` | 64 | số bit của `afe_trim_o` (1…64); v1 lái 0 |

`bow_mipi_rx` đặt `LpClkHz` = `PhyClkHz`, `BusClkHz` = `CpuClkHz`, truyền `AfeKind` của nó
(`bow32_top`: `CsiAfeKind`; 1 trên KV260 và trong mô phỏng KV260, 2 trên bản camera Huins và
trong mô phỏng IMX274) và để `AfeSettle*`, `AfeTrailB`, `AfePdRst`, `TrimW` mặc định.

## Bản đồ thanh ghi (v1.x)

Offset trong cửa sổ D-PHY (cộng `0x4000_8C00`). Byte enable và W1C như controller: byte không
ghi giữ nguyên, bit W1C ngoài các byte ghi không bị xoá, phần cứng set cùng chu kỳ thì set thắng,
lệnh cần byte 0. Bộ đếm 32 bit bão hoà (trừ hai thanh ghi ghép 16 + 16 bit ghi rõ). Trường của lane
trên `Lanes` (và lane 4–7) đọc 0, ghi bị bỏ. **Offset hay trường ghi "sau" chưa có: đọc 0, ghi bị
bỏ** (bước thêm nó ở cột cuối). `CTRL`, `TIM0`, `TIM1`, `TIM2` là **shadow** (bước 6): lần ghi chỉ
đổi bản ở miền bus (đọc lại ngay: chúng đọc bản shadow, không phải bản miền lp đang dùng), miền lp
dùng chúng sau `CMD.APPLY` (mục *Shadow và APPLY*); `CMD` đọc 0 khi miền lp dùng đúng những gì
chúng đọc.

| Offset | Tên | Truy cập | v1.x: bit (giá trị reset) | Thêm sau |
|---:|---|:--:|---|---|
| 0x000 | `ID` | R | `0x44505202`: [31:8] "DPR", [7:0] phiên bản của bản đồ thanh ghi: 2 từ bước 6 (`CMD[1]` thành REINIT, `CTRL` / `TIM0` cần `CMD.APPLY`), 1 ở bước 4–5 (`0x44505201`). Driver chỉ nhận đúng phiên bản của nó (mục *Driver*) | |
| 0x004 | `INFO` | R | [3:0] `Lanes`, [4] PPI 16 bit (0), [7:5] `AfeKind`, [17:8] `lp_clk` MHz, [21:18] `DlyW` (9), [22] delay lane clock (0), [23] AFE tự hiệu chỉnh delay (BISC: `AfeKind` = 2), [27] ULPS (1, bước 6), các bit khác của [31:24] 0. KV260: `0x0824C822`, Huins: `0x08A4C844` (bước 4–5: `0x0024C822`, `0x00A4C844`) | [24]–[26], [28]–[31] theo khối: bước 8, 10 |
| 0x008 | `INFO2` | R | [7:0] `SETTLE_NS`, [15:8] `SETTLE_UI`, [23:16] byte trail của AFE, [31:24] 0. KV260: `0x0000186B`, Huins: `0x00080078` | |
| 0x00C | `CTRL` | RW, shadow | [1] CLK_CONT (0): lane clock liên tục, bộ thu + cổng lane clock bật suốt khi `EnableClk` (thay `CTRL.CLK_FORCE` của controller); [2] ULPS_EN (0): vào escape và lệnh ULPS (bước 6); [3] HSRX_EARLY (0): bộ thu HS của data lane bật từ LP-01 (`HsRqst`), termination vẫn từ LP-00 (bước 6; hai adapter FPGA: không tác dụng ở chân, `HSRX_DISABLE` theo `term_en`, mục *Giao diện AFE*); [6] DES_RST_DIS (0): 1 giữ `des_rst` của AFE ở 0, tức tắt reset đường thu khi cổng đóng (adapter Versal: `RX_RST` của slice dữ liệu; adapter UltraScale+, từ bước 5: reset `ISERDESE3`; chỉ để thử, bo Huins hỏng khi tắt); [7] CLK_LOST_EN (0): CLK_LOST vào `ErrControl` và `ERR_STATUS` (bước 6); [16] CLK_MISS_OFF (0): ở `Trail` lane clock tắt cả bộ thu HS và termination (bước 6) | [5] DSK_EN: bước 8; [0] EN, [4] SOT_TOL, [15:8] LANE_EN: bước 10 (tới đó lane bật / tắt chỉ bằng `Enable` của PPI) |
| 0x010 | `CMD` | W (R: [0], [31]) | [0] APPLY: miền lp chép `CTRL`, `TIM0`–`TIM2` shadow trong một chu kỳ; đọc [0] = 1 tới khi đã chép (bước 6); [1] REINIT: mọi máy LP (đang bật) về `WaitStop`, data lane đang HS rời HS ngay, lane clock đang ở `Hs` qua `Exit` (đóng cổng trước, tắt bộ thu 2 chu kỳ lp sau, sửa sau review), `T_INIT` đếm lại (≈ `ForceRxmode`, bước 6; bước 4–5 bit này là AFE_CAL dưới đây); [2] AFE_CAL: chạy lại hiệu chỉnh của AFE (`cal_start` của giao diện AFE = 1 trong 32 chu kỳ bus; adapter Versal: XPLL, BISC, VT chạy lại, mã đã nạp mất, OWN xoá; adapter UltraScale+: không có; bước 4–5: `CMD[1]` REINIT); [3] CNT_CLR: xoá `CNT_*` của D-PHY. Đọc [31] DIRTY (sửa sau review): 1 từ một lần ghi `CTRL` / `TIM0`–`TIM2` (ít nhất một byte, cả cùng giá trị) tới khi một APPLY được gửi; [30:1] 0 | [4] DSK_RUN, [15:8] DLY_REL, [16] DLY_CLK_REL: bước 8 |
| 0x014 | `AFE_CTRL` | RW | [0] PD (`AfePdRst`; FPGA: 0): `pd` của giao diện AFE; khi 1 thì `lprx_en` = 0 và `lane_pd` = 1 ở mọi lane; `lane_pd` về 0 khi READY mới (0 từ lúc PD lên, rồi 1) với PD = 0. Adapter Versal: PHY giữ ở reset khởi động như sau khi mất khoá XPLL (READY xuống, OWN mọi lane xoá); PD = 0 chạy lại XPLL, BISC, VT như sau reset. Adapter UltraScale+: không tắt được (READY vẫn 1). Không bao giờ từ `Enable`: stop / start không đụng tới AFE (từ bước 5) | [3:1] TST_MODE, [15:8] ATB_SEL: khi AFE có điểm móc test |
| 0x018 | `AFE_STATUS` | R | [0] READY (`afe_ready_i` qua 2 flop), [1] CAL_DONE, [2] CAL_ERR (`afe_cal_done_i`, `afe_cal_err_i` qua 2 flop, từ bước 5; hai adapter FPGA: 0), [15:8] `status` thô của AFE qua 2 flop (Versal: [11] PHY_RDY mọi nibble, [10] DLY_RDY mọi nibble, [9] XPLL LOCKED_FB, [8] LOCKED; thay GPIO PB6 / PB7 của top Huins; UltraScale+: 0) | |
| 0x01C, 0x020 | `AFE_TRIM0/1` | — | sau (v1 lái `trim` = 0) | khi một AFE định nghĩa bit trim |
| 0x024 | `TIM0` | RW, shadow | bố cục và đơn vị của `PHY_CFG` cũ (chu kỳ `lp_clk`): [7:0] SETTLE (14), [11:8] LP_FILTER (2), [23:16] CLK_SETTLE (30), [31:24] CLK_MISS (8, 0 = tắt); reset `0x081E020E`. Áp bằng `CMD.APPLY` (bước 4–5: qua `bow_sync` từng bit, có hiệu lực ngay); driver đổi nó khi PHY tắt (`CTRL.PHY_EN` = 0 của controller) | |
| 0x028 | `TIM1` | RW, shadow | [23:0] HS_TMO (`0x100000` = 2^20, watchdog cố định của bước 1–5; 0 = tắt): số chu kỳ `lp_clk` một data lane được ở `Hs` trước khi về `WaitStop` với lỗi HS_TMO (so ≥: một giá trị nhỏ hơn số đếm đang chạy, áp bằng APPLY, có tác dụng ngay); [27:24] CLK_TOG_DIV (0): flop đảo của miền byte lật mỗi 2^CLK_TOG_DIV byte clock (2^CLK_TOG_DIV byte clock phải dài hơn một chu kỳ `lp_clk`, mục *Chức năng v1.x*); reset `0x00100000` (bước 6) | |
| 0x02C | `TIM2` | RW, shadow | [19:0] T_INIT (0 = không đợi): số chu kỳ `lp_clk` LP-11 liên tiếp ở `WaitStop` trước `Stop`, chỉ sau khi READY lên hay `CMD.REINIT`; [31:20] ESC_TMO (0 = tắt, đơn vị 64 chu kỳ `lp_clk`): thời gian tối đa từ LP-10 của lần vào escape tới khi giải xong lệnh (so ≥ như HS_TMO); reset 0 (bước 6) | |
| 0x030 | `LANE_LP` | R | LP {P, N} sau lọc, cả khi PHY tắt: [1:0] lane clock, [2l+3:2l+2] data lane l (reset LP-11) | |
| 0x034 | `LANE_HS` | R | [0] bộ thu HS + termination lane clock, [l+1] data lane l; [16] cổng byte clock mở; [17] `RxClkActiveHS` (v1: chính cổng, mục 5.3 của đặc tả: với CLK_CONT là 1 suốt khi lane clock bật); [18] BYTECLK_OK (`BYTECLK` ≠ 0) | |
| 0x038 | `LANE_STOP` | R | [0] `Stopstate` lane clock, [l+1] data lane l (máy LP ở `Stop`, đã qua `T_INIT`); [16] ULPS lane clock, [l+17] ULPS data lane l (từ lệnh ULPS tới LP-11 kết thúc lần thức dậy, tức như `RxUlpsEsc` / ¬`RxUlpsClkNot` của PPI) (bước 6) | |
| 0x03C | `IRQ_STATUS` | W1C | [0] ERR (một bit `ERR_STATUS` được set), [1] ULPS (một lane vào ULPS, hay ra khỏi nó ở LP-11 cuối lần thức dậy; mark thức dậy chưa phải là ra, bước 6), [3] RAW_DONE | [2] DSK_DONE, [4] AFE, [5] PRBS |
| 0x040 | `IRQ_EN` | RW | [0], [1], [3] như `IRQ_STATUS` (0); `irq_o` = \|(`IRQ_STATUS` & `IRQ_EN`) | |
| 0x044 | `ERR_STATUS` | W1C | [2] CONTROL: lỗi chuỗi LP hoặc HS_TMO của một lane bất kỳ (mọi lỗi của FSM, không che); bước 6: [3] HS_TMO, [4] ESC (lệnh escape không phải ULPS), [6] CLK_LOST (khi `CTRL.CLK_LOST_EN`), [7] LATE_EOT, [10] ESC_TMO | [8] DSK_FAIL: bước 8; [0] SOT_SYNC, [1] SOT, [9] AFE: bước 10; [5] SYNC_ESC: khi có LPDT |
| 0x048 | `ERR_LANE` | W1C | [8+l] CONTROL data lane l, [16] CONTROL lane clock | [l] SOT_SYNC: bước 10 (cùng `ERR_STATUS[0]`; tới đó controller đếm SoT, `CNT_SOT*`) |
| 0x04C | `BYTECLK` | R | [19:0] byte clock trong 65536 chu kỳ bus (như `BYTECLK` cũ) | |
| 0x050–0x05C | `CNT_BURST0`…`3` | R | số lần vào HS của data lane l | |
| 0x060–0x06C | `CNT_BURST4`…`7` | R | 0 (lane 4–7) | khi có 8 lane |
| 0x070 | `CNT_CLK` | R | số lần vào HS của lane clock | |
| 0x074 | `CNT_LPERR` | R | lỗi LP (CONTROL) của mọi lane, cả HS_TMO (như watchdog của bước 1–5) | |
| 0x078 | `CNT_DSK` | R | [15:0] 0, [31:16] số lần vào ULPS của mọi lane (16 bit bão hoà, bước 6) | [15:0] burst deskew: bước 8 (hôm nay controller đếm, `CNT_EXT[31:16]`) |
| 0x07C | `CNT_MISC` | R | [15:0] 0, [31:16] HS_TMO + CLK_LOST + LATE_EOT + ESC_TMO của mọi lane (16 bit bão hoà, bước 6) | [15:0] `ErrSotHS`: bước 10 |
| 0x080–0x08C | `DLY0`…`DLY3` | RW | [8:0] CODE (0): ghi = mã delay yêu cầu, đọc = mã đã yêu cầu (v1: phần mềm là chủ duy nhất); flop miền bus, lái thẳng `afe_dly_code_o[l]` (mức tĩnh); [15] PEND (R): OWN = 1 và delay của AFE ([24:16]) chưa bằng CODE; [24:16] `dly_q`: delay AFE đang dùng (CNTVALUEOUT trên FPGA, qua 2 flop từng bit); [31] OWN (R, 0; `afe_dly_own_o[l]`): 1 = lane dùng mã của phần mềm. Lần ghi có byte 0 hoặc 1 đặt CODE và, khi `AFE_STATUS.READY` = 1, OWN = 1; ghi chỉ byte 2–3 không làm gì. Từ bước 5 D-PHY không có giao thức nạp: AFE áp mã khi OWN lên hoặc mã đổi, nên ghi lại đúng mã đang dùng không nạp gì. OWN = 0 khi READY = 0 (AFE khởi động lại: mã đã nạp mất; lần ghi sau, kể cả cùng mã, nạp lại) | nhả bằng `CMD.DLY_REL` (`INFO[30]`, `release_delay()`) và mã do bộ máy deskew đặt: bước 8; [9] (DlyW 10): khi một AFE cần |
| 0x090–0x09C | `DLY4`…`7` | RW | đọc 0, ghi bị bỏ | khi có 8 lane |
| 0x0A0–0x0FC | `DLY_CLK`, `AFE_OVR*`, `DSK_*`, `PRBS_*` | — | sau (v1 lái delay lane clock 0, OWN 0) | `DLY_CLK` khi AFE có delay lane clock (`INFO[22]`), `AFE_OVR*` cùng điểm móc test, `DSK_*`, `PRBS_*` ở bước 8 |
| 0x100 | `RAW_CTRL` | RW | như `RAW_CTRL` cũ: ghi [0] ARM, [1] NOW; đọc [0] ARMED, [1] NOW, [8] DONE | |
| 0x104, 0x108 | `LANE_MAP`, `LANE_POL` | — | sau | bước 10 |
| 0x200–0x3FC | `RAW[64]` | R | entry i: `0x200 + 8i` = lane 0–3 (byte k = lane k), `0x204 + 8i` = lane 4–7 (0) | |

Giá trị `INFO` ở bảng: KV260 (2 lane, `lp_clk` 200 MHz, `AfeKind` 1) và Huins (4 lane, 200 MHz,
`AfeKind` 2, bit 23); bit 27 từ bước 6.

### Ghi chú

- **Thanh ghi PHY cũ của controller không còn, không có alias** (quyết định D1, mục 6.3 của đặc
  tả): `PHY_CFG`, phần LP/HS/CE/BYTECLK_OK/PHY_RDY của `STATUS`, `CNT_BURST`, `CNT_BURST23`,
  `CNT_MISC[23:0]`, `BYTECLK`, `DLY0`…`DLY3`, `RAW_CTRL`, `RAW`, `CTRL.CLK_FORCE` và
  `INFO[5]` của controller đọc 0. `INFO[6]` = 1 của controller báo "D-PHY ở `0xC00`"; driver
  đọc nó và từ chối bitstream trước bước 4.
- **Che `ErrControl`.** D-PHY che lỗi LP trước khi đưa lên PPI: `ErrControl[l]` theo `Enable[l]`
  (đã đồng bộ, như máy LP thấy nó), `ErrControlClk` khi `CTRL.CLK_CONT` = 1; controller chỉ còn
  phép OR cho luật đánh dấu burst mất và `ERR_STATUS.LP` của nó. Từ bước 6 `ErrControl*` và
  `ErrEsc` là bộ đếm gray 2 bit (mục *Chức năng v1.x*); che nghĩa là bộ đếm không bước. `CNT_LPERR`, `ERR_STATUS.CONTROL`
  và `ERR_LANE` của D-PHY đếm mọi lỗi của máy LP, không che. Hệ quả (bước 4): lỗi LP của lane clock
  khi `CLK_CONT` = 1 và lỗi của một data lane ở chu kỳ enable của nó vừa xuống không còn vào
  `ERR_STATUS.LP` của controller; `CNT_LPERR` / `ERR_STATUS.CONTROL` vẫn thấy chúng. Một PHY
  khác ghép qua wrapper cổng phẳng phải che như vậy (cột Cần của mục 5.5 trong đặc tả).
- **Reset riêng.** Aligner dùng reset byte của D-PHY: nó không còn bị reset khi RX tắt
  (`CTRL.RX_EN` / `PHY_EN` của controller); burst đang dở khi RX tắt kết thúc ở aligner như mọi
  burst (controller vẫn xoá datapath của nó). Sự kiện của aligner trên PPI (`ErrSotSyncHS` mọi
  lane, `RxSkewCalHS` lane 0) controller chỉ đếm cho burst nó thấy bắt đầu: không khi đường dữ
  liệu của nó đang reset (`drst_n`: RX tắt, bật ngay khi `CTRL` xoá `RX_EN` hay `PHY_EN`, trước
  khi `RxActiveHS` kịp xuống), không cho burst mà `RxActiveHS` của lane đã cao lúc `drst_n` nhả
  (`stale_q` mỗi lane, xoá một chu kỳ sau khi thấy `RxActiveHS` thấp). Nhờ vậy `CNT_SOT`,
  `ERR_STATUS.SOT`, `CNT_EXT[31:16]` và `IRQ_STATUS.ERR` đếm đúng như bước 1–3: burst khi `RX_EN`
  = 0 mà `PHY_EN` = 1 không được đếm, burst đang chạy lúc RX bật không được đếm, và dừng giữa lúc
  dò sync không sinh lỗi SoT giả. Ở trường hợp cuối, dừng bộ thu cũng kết thúc HS của lane clock
  (cùng `Enable`), nên byte clock thường dừng trước khi `RxActiveHS` của burst bị cắt xuống ở miền
  byte: nó xuống, và lỗi sync tới, cùng byte clock của burst đầu tiên sau khi bộ thu chạy lại, tức
  sau khi `drst_n` đã nhả và `bow_csi2rx_start()` đã xoá bộ đếm (bản đầu của bước 4 đếm khi đó một
  lỗi SoT trên mọi lane đang dò, có thể làm hỏng link check sau một lần chạy lại). Sửa sau review
  của bước 4; DV `rxoff`.
- **DLYn ở v1 (từ bước 5).** D-PHY không còn giao thức nạp (bước 4: `DlyVid` 0 nạp ở byte clock
  khi mã đổi, 1 mỗi lần ghi một lần nạp ở miền lp). CODE và OWN là flop miền bus lái thẳng
  `afe_dly_code_o` / `afe_dly_own_o`; AFE coi chúng là bất đồng bộ (mục 3.1 của đặc tả) và áp mã
  khi OWN lên hoặc mã đổi (mục 3.5). Trên FPGA việc đó nằm trong adapter: `bow_dphy_dly_xusp`
  (KV260: mã và OWN đồng bộ theo byte clock, nạp `IDELAYE3` khi giá trị ổn định 2 chu kỳ và khác
  giá trị đã nạp, tức ở burst sau như trước; OWN = 0 nạp tap 0) và `bow_dphy_dly_xphy` (Huins: đồng
  bộ ở `CTRL_CLK` = `vid_clk`, không cần byte clock; `RX_EN_VTC` = 0 rồi chờ 12 chu kỳ trước lần
  nạp đầu của lane, các lần nạp cách nhau ≥ 4 chu kỳ; OWN 1 → 0 không về trễ BISC: chỉ
  `AFE_CTRL.PD` hay `CMD.AFE_CAL` (bước 4–5: `CMD.REINIT`) làm được, `INFO[30]` = 0). Khác bước 4 trên Versal: ghi lại đúng
  mã đang dùng không nạp; lần ghi đầu sau khi READY lên lại vẫn nạp (OWN lên); lần nạp tới XPHY
  sớm hơn vài chu kỳ lp (không còn bộ đếm yêu cầu). Chưa có chủ thứ hai của mã, nên CODE đọc lại
  là mã đã ghi và PEND lấy từ chính delay của AFE: `wait_delay` chờ PEND = 0 trên các lane có OWN.
  OWN thay mặt nạ `dly_written` của driver cũ.
- **AFE_CAL / REINIT** thay GPIO PA4 của top camera Huins: một xung phần cứng (không còn mức phần
  mềm giữ); `AFE_STATUS.READY` xuống rồi lên lại sau XPLL lock + BISC. Từ bước 5 nó là `cal_start`
  của giao diện AFE. Bước 4–5 nó là `CMD[1]` REINIT; từ bước 6 nó là `CMD[2]` AFE_CAL, còn `CMD[1]`
  REINIT đưa các máy LP về `WaitStop` (`T_INIT` đếm lại). Driver (`bow_dphy_rx_reinit()`) ghi cả
  hai trong một lần, nên `phy reinit` của `csi2_test` làm như trước và thêm phần máy LP. Vì `CMD[1]`
  đổi nghĩa, `ID[7:0]` lên 2 ở bước 6 và driver từ chối phiên bản khác (mục *Driver*): firmware của
  bước 6 trên PDI của bước 5 sẽ ghi `CMD[1]` = hiệu chỉnh AFE giữa stream.
- **AFE_CTRL.PD** (bước 5) là `pd` của giao diện AFE: `AFE_CTRL.PD` = 1 giữ AFE tắt (`lprx_en` = 0,
  `lane_pd` = 1; adapter Versal: reset khởi động, như mức `reinit_i` = 1 của bước 4) tới khi phần
  mềm xoá nó; `lane_pd` về 0 khi D-PHY thấy một READY **mới** với PD = 0: READY = 0 ít nhất một
  chu kỳ kể từ lần PD lên gần nhất (hay từ reset), rồi 1 (sửa sau review: READY qua 2 flop còn
  đọc 1 vài chu kỳ sau khi PD lên, và một xung PD ngắn từng nhả `lane_pd` theo READY cũ ấy suốt
  lúc AFE khởi động lại; AFE giữ READY = 1 qua PD, như adapter UltraScale+, thì `lane_pd` ở 1 sau
  xung PD; hai adapter FPGA không dùng `lane_pd`). Driver v1 không dùng nó (FPGA:
  PD = 0 từ reset). Chỉ đến từ thanh ghi, không từ `Enable`: stop / start không chạy lại BISC.
- **DES_RST_DIS** thay GPIO PA5: reset đường thu khi cổng đóng **luôn bật** từ reset, chỉ tắt
  bằng bit thử này. Từ bước 5 đó là `des_rst` của giao diện AFE: flop miền lp trong máy LP lane
  clock (`u_lp_clk`), = ¬cổng, đặt và nhả ở cùng cạnh lp với lúc cổng đóng / mở, 0 khi
  DES_RST_DIS = 1 (bit qua `u_sync_vcfg` ở bước 5; từ bước 6 qua shadow + APPLY), 1 từ reset. Adapter Versal lấy `RX_RST` của slice dữ
  liệu từ nó (`ready` ∧ `des_rst`, một flop `CTRL_CLK`: cùng chu kỳ như `burst_rst_q` của bước 4),
  adapter UltraScale+ lấy reset `ISERDESE3` (nhả 2 cạnh byte clock sau khi `des_rst` xuống, như
  `byte_rst_o` của bước 4). Khác bước 4: DES_RST_DIS = 1 nay cũng tắt reset `ISERDESE3` trên KV260
  (trước bước 5 reset đó chỉ theo cổng). Trước bước 4 phần mềm đặt PA5 = 1 ở mỗi lần `start`;
  driver mới vẫn ghi DES_RST_DIS = 0 ở mỗi lần start trên Versal (tuỳ chọn mô phỏng
  `CAM_BURST_RST=0` ghi 1).

## Chức năng v1.x (bước 6)

Mỗi chức năng nằm sau một bit hay trường có giá trị reset = hành vi của bước 5 (mục 4.12 của đặc
tả, hai ngoại lệ có chủ ý: `RxSkewCalHS` thành mức, `des_rst` luôn bật từ bước 4; và hai phần chỉ
báo cáo, LATE_EOT và các bit HS_TMO của watchdog, mà không firmware nào đọc để quyết định gì).

- **Shadow và APPLY.** `CTRL`, `TIM0`, `TIM1`, `TIM2` ghi vào flop miền bus (đọc lại ngay);
  `CMD.APPLY` lật một toggle (`apply_q`), miền lp thấy nó qua một `bow_sync` (`u_sync_apply`) và
  chép cả bộ vào `cfg_lp_q` trong một chu kỳ, rồi trả ack (`u_sync_apply_ack`); `CMD[0]` đọc 1 từ
  lần ghi tới khi ack về (vài chu kỳ lp + 2 chu kỳ bus). Luật của driver: không ghi shadow khi
  `CMD[0]` = 1; APPLY ghi khi một APPLY đang chờ được nhớ (`apply_again_q`) và làm lại sau ack, nên
  lần ghi cuối luôn được áp. Sau reset miền lp, nó chép shadow một lần không cần APPLY
  (`apply_first_q`), tức giá trị reset. Thanh ghi đọc lại bản shadow, không phải bản đang dùng:
  `CMD[31]` DIRTY (sửa sau review) = 1 từ một lần ghi shadow (ít nhất một byte, cả cùng giá trị) tới
  khi một APPLY được gửi, nên `CMD` = 0 nghĩa là miền lp dùng đúng những gì `CTRL` / `TIM0`–`TIM2`
  đọc (một cờ thay cho một bản sao ngược 94 bit: rẻ nhất; bảo thủ, ghi lại cùng giá trị cũng là
  DIRTY). Vivado thấy đường shadow → `cfg_lp_q` là CDC có CE (CDC-15, cảnh báo, không phải lỗi);
  `set_bus_skew` ≤ 2 chu kỳ lp giữa mọi bit chép và toggle (`apply_q` → `u_sync_apply`) trên cả
  hai bo (sửa sau review): bản chép lấy hai chu kỳ lp sau khi toggle tới bộ đồng bộ, nên không bit
  nào còn đang đi. Đổi một trường đang ảnh hưởng tới lane đang chạy (TIM0, CLK_CONT) vẫn chỉ khi
  PHY tắt (luật cũ của `PHY_CFG`).
- **`T_INIT`** (`TIM2[19:0]`). Khi READY lên (cạnh của `AFE_STATUS.READY`) hay `CMD.REINIT`, mỗi
  máy LP đang bật phải thấy `T_INIT` chu kỳ LP-11 liên tiếp ở `WaitStop` mới sang `Stop` (một lần
  LP khác LP-11 đếm lại từ 0); không bao giờ ở `Enable`. `CMD.REINIT` (và READY lên khi `T_INIT` ≠
  0) đưa lane đang ở trạng thái khác về `WaitStop` ngay; lane clock đang ở `Hs` (cổng mở, clock có
  thể còn chạy) đi qua `Exit` như lối ra dự phòng: đóng cổng trước, tắt bộ thu HS và termination 2
  chu kỳ lp sau, rồi `WaitStop` (`exit_wait_q`; sửa sau review: trước đó cổng và bộ thu tắt cùng
  một cạnh, và `HSRX_DISABLE` của adapter Versal cắt strobe ngay, có thể giữa một xung byte clock mà
  `BUFGCE` chưa kịp đóng). `T_INIT` = 0: như bước 5 (Stop ngay khi thấy LP-11). Kiểm ở
  `bow_ppi_chk` (giới hạn thời gian tới `Stopstate` = 12 + `T_INIT` chu kỳ).
- **`HS_TMO`** (`TIM1[23:0]`): bộ đếm 24 bit của data lane, từ 0 khi vào `Hs`; sau `HS_TMO` chu
  kỳ ở `Hs` lane về `WaitStop` với lỗi CONTROL và HS_TMO (`ErrControl`, `ERR_STATUS[2]`, `[3]`, `CNT_LPERR`,
  `CNT_MISC[31:16]`). Reset 2^20 = watchdog cố định của bước 1–5; 0 = tắt. So bằng ≥ (sửa sau
  review): `HS_TMO` mới, nhỏ hơn số đếm của một lane đang ở `Hs`, có tác dụng ở chu kỳ sau APPLY,
  không phải sau khi bộ đếm 24 bit quay vòng (84 ms ở 200 MHz). Phần thêm so với watchdog cũ
  (`ERR_STATUS[3]`, `CNT_MISC`) chỉ báo cáo: CONTROL, `CNT_LPERR` và `ErrControl` như bước 5.
- **Escape và ULPS** (`CTRL.ULPS_EN`). Data lane: LP-10 ở `Stop` → `EscRqst`, LP-00 → `EscGo`,
  LP-01 (mark của lần vào) → `EscCmd`: mỗi bit lệnh là một mark (LP-01 = 0, LP-10 = 1) rồi một space
  LP-00, bit đầu tiên nhận được thành bit 7 của lệnh, so với `8'b0001_1110` viết theo thứ tự trên dây
  (bit phát trước ở bên trái): đúng thứ tự "bit đầu tới bit cuối được phát" của bảng lệnh escape
  công khai của Microchip [S18] và của PG202 / PG436 [S1][S5] (review bước 6 đã đối chiếu; không còn
  **[CHƯA CHẮC]**) → `Ulps`, lệnh khác → `EscWait` tới LP-11 với lỗi ESC. LP-11 giữa chừng huỷ (về
  `Stop`, không lỗi); hai mark liền nhau không có space hay LP-01 ở `EscRqst` / LP-10 ở `EscGo` là
  lỗi CONTROL. Lane clock: LP-10 ở `Stop` → `EscRqst`, LP-00 → `Ulps` (không có lệnh). Thoát: LP-10
  (mark thức dậy) → `UlpsExit`, `lane_pd` của lane xuống ngay; LP-11 → `Stop`; LP-00 thay vì LP-11
  (một LP-10 lạc khi máy phát vẫn ở ULPS) → về `Ulps`, `lane_pd` lên lại (sửa sau review: trước đó
  lane được cấp nguồn tới LP-11 kế tiếp). `ULPS_EN` = 0 (reset): LP-10 ở `Stop` là lỗi LP như bước 5,
  và một lane đang ở các trạng thái mới về `Off` (như các giá trị trạng thái không dùng của bước
  5). Trên PPI, theo thứ tự của PPI công khai (PG202 *Example 12: ULPS Operation at D-PHY RX (Slave)
  Clock Lane*, mục *Nguồn* [S1] của [mipi_rx_arch.md](mipi_rx_arch.md); sửa sau review, trước đó
  ngược lại):
  `UlpsActiveNot*` = 0 từ lệnh tới mark thức dậy (`Ulps`), `RxUlpsEsc` = 1 / `RxUlpsClkNot` = 0 từ
  lệnh tới LP-11 cuối lần thức dậy (`Ulps` ∨ `UlpsExit`); `LANE_STOP[31:16]` như `RxUlpsEsc`,
  `CNT_DSK[31:16]` (lần vào), `IRQ_STATUS[1]` ở lần vào và ở LP-11 cuối lần thức dậy (không ở mark:
  một mark lạc không phải lần ra); `lane_pd` của lane = 1 suốt `Ulps` (ngoài luật PD / READY).
- **`ESC_TMO`** (`TIM2[31:20]`, đơn vị 64 chu kỳ): từ LP-10 của lần vào escape tới khi giải xong
  lệnh; quá thì về `WaitStop` với lỗi ESC_TMO (`ErrEsc`, `ERR_STATUS[10]`, `CNT_MISC`). 0 = tắt. So
  bằng ≥ như `HS_TMO` (sửa sau review).
- **`HSRX_EARLY`** (`CTRL[3]`): `hsrx_en` của data lane lên từ LP-01 (`HsRqst`), `term_en` vẫn
  từ LP-00 (`Settle`). Hai adapter FPGA không làm được việc này: `IBUFDS_DPHY` chỉ có một chân
  `HSRX_DISABLE` cho cả bộ thu HS lẫn termination, nên chân theo `term_en` (`HSRX_DISABLE` =
  ¬`term_en`, sửa sau review; trước đó ¬(`hsrx_en` ∨ `term_en`), tức termination đóng ở LP-01 khi
  `HSRX_EARLY` = 1). Với `HSRX_EARLY` = 0 (reset) `hsrx_en` = `term_en` ở mọi chu kỳ (`bow_afe_chk`),
  nên chân không đổi. **`CLK_MISS_OFF`** (`CTRL[16]`): ở `Trail` lane clock tắt cả `hsrx_en` và
  `term_en` (bước 5: còn bật tới LP-11). `term_en` có flop riêng (`term_q`) từ bước 6; luôn kéo theo
  `hsrx_en` (`bow_afe_chk`).
- **`CLK_TOG_DIV`** (`TIM1[27:24]`): flop đảo của miền byte lật mỗi 2^N byte clock (giá trị qua
  `u_sync_tdiv` sang miền byte; `set_bus_skew` một chu kỳ byte clock, sửa sau review). Mỗi mức của
  flop phải dài hơn một chu kỳ `lp_clk` (cộng cửa sổ metastable của bộ đồng bộ): byte clock < 2^N ·
  `lp_clk`, có lề (sửa sau review: tài liệu cũ ghi ~1,5 · 2^N, nhưng khi mỗi mức chỉ dài cỡ một chu
  kỳ lp, một mẫu metastable có thể xoá cả một cặp cạnh, và mô hình jitter của bench, khi đã chạy,
  thấy cổng đóng giữa burst với N = 1 ở byte clock ≈ 2 · `lp_clk`); trễ phát hiện mất clock tăng
  2^N byte clock, nên `CLK_MISS` phải tính theo nó (driver: `bow_dphy_rx_set_clk_tog_div()` tính lại
  `CLK_MISS`). 0 = như bước 5.
- **`CLK_LOST`** (`CTRL.CLK_LOST_EN`): một data lane (đang bật) vào `Hs` khi cổng byte clock đang
  đóng (lane clock không ở `Hs`; với `CLK_CONT` cổng luôn mở nên không bao giờ): lỗi CLK_LOST vào
  `ErrControl` của lane, `ERR_STATUS[6]`, `CNT_MISC`. Reset 0: không thêm gì vào `ErrControl`, nên
  luật đánh dấu burst mất của controller không đổi.
- **LATE_EOT** (luôn bật, chỉ báo cáo): cổng byte clock đóng (không phải vì `Enable` của lane clock
  hay `CMD.REINIT`, tức clock của máy phát đã dừng) khi `RxActiveHS` của một data lane đang bật vẫn
  1 ở miền byte (`arm_q`, giá trị controller lấy ở cạnh byte clock cuối, đọc ở miền lp 3 chu kỳ sau
  khi cổng đóng): byte cuối của burst có thể chưa ra PPI (máy phát giữ T_CLK-POST quá ngắn; từ
  bước 7 của [mipi_rx_arch.md](mipi_rx_arch.md), controller ở clock của nó, chỉ phần cuối burst của
  controller (SKEW, TRUNC, `ErrSotSyncHS` cuối burst) chờ burst sau, packet đã vào FIFO 2 clock của
  ghép lane thì xong, FE và ngắt không trễ). Một lần
  mỗi lane mỗi lần kết thúc burst; `ERR_STATUS[7]`, `CNT_MISC`, `IRQ_STATUS.ERR`; không lên PPI.
  Không sau một bit có giá trị reset (ngoại lệ chỉ báo cáo của mục 4.12 của đặc tả): không firmware
  nào đọc `ERR_STATUS` / `CNT_MISC` của D-PHY để quyết định (chỉ `phy v1x` / `phy check` của
  `csi2_test` in chúng) và không firmware nào bật `IRQ_EN` của D-PHY, nên `irq_o` và
  `IRQ_STATUS[5]` của controller vẫn 0 như bước 5.
- **`RxSkewCalHS`** là mức trên mọi lane: từ lúc aligner nhận ra burst deskew tới khi `RxActiveHS`
  xuống (`dsk_lvl_q`); controller đếm cạnh lên ở lane 0, nên `CNT_EXT[31:16]` không đổi.
- **Lỗi lp trên PPI**: `ErrControl[l]`, `ErrControlClk`, `ErrEsc[l]` là bộ đếm gray 2 bit
  (`bow_ppi_err_tx`): một sự kiện là một bước, các bước cách nhau ≥ 16 chu kỳ lp (sự kiện tới trong
  lúc chờ gộp vào bước kế tiếp: controller chỉ cần biết có ≥ 1 lỗi; bộ đếm của D-PHY đếm đủ), che
  theo `Enable` / `CLK_CONT` như trước (một sự kiện đang chờ bước khi lane bị tắt thì bỏ);
  `ErrSyncEsc` 0. Controller lấy mẫu ở clock của nó (`bow_ppi_err_rx`), cần ≥ `lp_clk` / 32 (đặc tả
  mục 4.11).
- **Bộ đếm sự kiện phía bus**: sự kiện miền lp (vào HS, lỗi LP mỗi lane, HS_TMO, ESC, ESC_TMO,
  CLK_LOST, LATE_EOT, vào / ra ULPS) tới thanh ghi qua bộ đếm gray 4 bit mỗi loại (`evc_gray_q`,
  ≤ 1 bước mỗi chu kỳ lp; sự kiện của nhiều lane cùng chu kỳ đếm dần ở các chu kỳ sau), đọc qua
  `u_sync_evc`; thanh ghi cộng hiệu giữa hai lần đọc. Không mất sự kiện khi `lp_clk` ≤ 12 ×
  `clk_i` (`BusClkHz`, kiểm khi elaborate); FPGA: `set_bus_skew` một chu kỳ lp từ `evc_gray_q` tới
  `u_sync_evc`. Cùng hai ràng buộc của review (bản chép shadow, `CLK_TOG_DIV`): KV260 13, Huins 14
  `set_bus_skew` (bước 6 trước review: 11, 12).

## Giao diện AFE (từ bước 5)

Cổng `afe_<tên>_i` / `_o` của `bow_dphy_rx` theo [mipi_rx_arch.md](mipi_rx_arch.md) mục 3.2 (tên,
nhóm A–F); `[l]` = data lane l, `clk_` = lane clock. Mọi điều khiển sang AFE ra thẳng từ flop,
mọi đầu ra của AFE ngoài nhóm miền byte được đồng bộ trong D-PHY. Cột *v1* là cách RTL lái hay
dùng tín hiệu.

| Nhóm | Tín hiệu | Rộng | Hướng | Miền | v1 |
|---|---|---|---|---|---|
| A | `hs_byte_clk` | 1 | AFE → số | clock | byte clock (`RxByteClkHS` của PPI) |
| A | `hs_data[l]` | 8 | AFE → số | byte | flop word, rồi aligner |
| A | `hs_valid[l]` | 1 | AFE → số | byte | aligner chỉ tiến ở word valid (Versal: khe của FIFO RX; UltraScale+: `'1`) |
| A | `clk_gate_en` | 1 | số → AFE | lp, flop | cổng của máy LP lane clock (`u_lp_clk`, `ce_q`) |
| A | `des_rst` | 1 | số → AFE | lp, flop | ¬cổng, cùng cạnh lp; 0 khi `CTRL.DES_RST_DIS` = 1; 1 từ reset |
| A | `clk_hs_samp` | 8 | AFE → số | byte | không dùng (chẩn đoán; adapter Versal có, top để hở) |
| A | `clk_act` | 1 | AFE → số | bất đồng bộ | không dùng (phát hiện mất clock với nó: bước 10) |
| B | `lp[l]`, `clk_lp` | 2 | AFE → số | bất đồng bộ | 2 flop + lọc `LP_FILTER` |
| B | `lprx_en[l]`, `clk_lprx_en` | 1 | số → AFE | bus, flop | ¬`AFE_CTRL.PD` (một flop cho mọi lane) |
| C | `hsrx_en[l]`, `clk_hsrx_en` | 1 | số → AFE | lp, flop | `hs_en` của máy LP; lane clock: không bao giờ xuống trước cổng khi clock còn chạy (`Exit`, `Disable`: 2 và 8 chu kỳ sau; `CLK_MISS_OFF`: cùng cổng, khi clock đã dừng). Hai adapter FPGA không dùng nó (chân `HSRX_DISABLE` theo `term_en`, sửa sau review) |
| C | `term_en[l]`, `clk_term_en` | 1 | số → AFE | lp, flop | flop riêng của máy LP (`term_q`, bước 6): = `hsrx_en` trừ `HsRqst` với `HSRX_EARLY` (chỉ `hsrx_en`); `CLK_MISS_OFF` tắt cả hai ở `Trail`; bước 5: cùng flop với `hsrx_en`. Hai adapter FPGA: `HSRX_DISABLE` = ¬`term_en` |
| D | `dly_code[l]` | 9 | số → AFE | bus, flop, tĩnh | CODE của `DLYn` |
| D | `dly_own[l]` | 1 | số → AFE | bus, flop | OWN của `DLYn`, xuống khi READY xuống |
| D | `dly_q[l]` | 9 | AFE → số | bất đồng bộ | 2 flop từng bit → `DLYn[24:16]`, PEND |
| D | `clk_dly_code`, `clk_dly_own`, `clk_dly_q` | 9, 1, 9 | | | 0, 0, không dùng (`INFO[22]` = 0) |
| D | `mon_en[l]`, `mon_code[l]`, `mon_data[l]` | 1, 9, 8 | | | 0, 0, không dùng (sampler giám sát: v3) |
| E | `pd` | 1 | số → AFE | bus, flop | `AFE_CTRL.PD` (reset `AfePdRst`) |
| E | `lane_pd[l]`, `clk_lane_pd` | 1 | số → AFE | bus, flop | 1 từ reset và khi PD, 0 khi thấy READY mới (0 từ lúc PD lên, rồi 1) với PD = 0; từ bước 6 mỗi lane một flop, thêm 1 khi lane ở `Ulps` (từ lệnh tới mark thức dậy, và lại khi mark kết thúc bằng LP-00). Lane ngoài `LANE_EN`: bước 10 (tới đó mọi lane của bản build theo luật PD / READY, lane có `Enable` = 0 chỉ có FSM ở `Off`) |
| E | `ready` | 1 | AFE → số | bất đồng bộ | 2 flop → `AFE_STATUS.READY`; READY = 0 xoá OWN |
| E | `cal_start` | 1 | số → AFE | bus, flop | `CMD.AFE_CAL` (bước 6; bước 5: `CMD.REINIT`): 32 chu kỳ bus |
| E | `cal_done`, `cal_err` | 1 | AFE → số | bất đồng bộ | 2 flop → `AFE_STATUS[1]`, `[2]` |
| E | `trim` | `TrimW` | số → AFE | | 0 |
| E | `status` | 8 | AFE → số | bất đồng bộ | 2 flop → `AFE_STATUS[15:8]` |
| F | `tst_mode`, `tst_data[l]`, `atb_sel` | 3, 8, 8 | số → AFE | | 0 |
| F | `hs_raw[l]`, `clk_hs_raw` | 1 | AFE → số | bất đồng bộ | không dùng |

**Chỗ v1 lệch bảng của mục 3.2** (review của bước 5 chấp nhận chúng; chúng chờ chủ dự án duyệt
trong PR, [mipi_rx_arch.md](mipi_rx_arch.md) mục 10):

- `dly_code`, `dly_own`, `pd`, `lprx_en`, `lane_pd`, `cal_start` là flop **miền bus** (bảng: lp).
  AFE coi mọi điều khiển là bất đồng bộ (mục 3.1), nên miền nguồn không đổi gì cho nó; giữ ở miền
  bus thì không thêm bus 9 bit mỗi lane qua bus → lp; mã + OWN vào bộ đồng bộ của adapter có một
  `set_bus_skew` trên mỗi bo (Huins: 11 ràng buộc như trước; KV260 thêm nó ở review: 10). Mã delay
  sang miền lp cùng bộ máy deskew, chủ thứ hai của mã (bước 8, mục 4.10 *Mã delay*).
- `cal_start` là xung 32 chu kỳ bus (640 ns ở 50 MHz) thay cho "≥ 4 chu kỳ lp".
- `lprx_en` một flop cho mọi lane (từ bước 6 `term_en` có flop riêng và `lane_pd` một flop mỗi
  lane).
- `scan_mode`, `tst_clk`: chưa có cổng (DFT, bước 9).
- `bow_mipi_rx` chỉ đưa ra tập con mà hai adapter FPGA dùng (A trừ `clk_hs_samp` / `clk_act`, B, C,
  D trừ lane clock và sampler giám sát, E trừ `lane_pd`, `cal_done` / `cal_err`, `trim`; không có
  F) và nối cố định phần còn lại; wrapper ASIC (`bow_mipi_rx_apb`, bước 9) đưa ra đủ.

`hw/ip/dphy_rx/dv/bow_afe_chk.sv` kiểm các luật trên ở mọi chu kỳ của mọi bench (bind vào mọi
`bow_dphy_rx`, tham số `Lanes`, `TrimW`, `AfePdRst` của nó): `des_rst` = ¬cổng ∧ enable của chu kỳ
trước, `term_en` ⇒ `hsrx_en` luôn, `hsrx_en` = `term_en` khi `HSRX_EARLY` đã tắt ≥ 16 chu kỳ (bước 6),
`lprx_en` = ¬`pd`, `lane_pd` mỗi lane theo mô hình tham chiếu của luật READY mới cộng ULPS (nhả sớm
hay không bao giờ nhả đều hỏng), OWN chỉ khi READY, các nối cố định bằng 0; suốt lúc
reset bật (từ cạnh clock thứ hai) giá trị reset của mục 3.6 ở cả hai miền: `pd` = `AfePdRst`,
`lprx_en`, `lane_pd` = 1, OWN = 0 (bus, `rst_ni`), cổng 0, `des_rst` 1, `hsrx_en` = `term_en` = 0 (lp,
reset lp). Bench đơn vị `hw/ip/csi2rx/dv/tb_dphy_afe.sv` (`make -C hw/ip/csi2rx/dv afe`, review bước 5)
phủ phần mà bench cả bộ thu không chạm tới (`bow_mipi_rx` nối cố định `cal_done` / `cal_err`, adapter
FPGA không có `lane_pd`): `bow_dphy_rx` một mình với mô hình AFE, bản ASIC (`AfeKind` 0, `AfePdRst`
1, 4 lane) và FPGA (`AfeKind` 1, `AfePdRst` 0, 2 lane): giá trị reset lúc bật nguồn và reset giữa
chừng, `INFO`, `AFE_STATUS` từng bit (READY, CAL_DONE, CAL_ERR, `status`), PD và `lane_pd` (bật AFE,
xung PD hai lần ghi liền nhau và dài thêm 1–3 chu kỳ, `ready` xuống muộn, `ready` kẹt ở 1, xung ngẫu
nhiên), OWN chỉ khi READY (lần ghi khi READY = 0 chỉ đặt CODE), `CMD.AFE_CAL` 32 chu kỳ
(`CMD.REINIT` không đụng tới `cal_start`, bước 6), `DES_RST_DIS` (sau `CMD.APPLY`).

Những luật cần biết lane clock có đang chạy (chỉ máy phát biết) nằm trong bench D-PHY
(`tb_bow_dphy_rx.sv`, mục *AFE invariants*, sửa sau review bước 6; mục 8.3 của đặc tả), ở mọi cạnh
lp: cổng byte clock chỉ đổi khi lane clock tĩnh (LP hay HS-0), trừ các ngoại lệ của mục 3.2 của đặc
tả (`CLK_CONT`, `Enable` của lane clock = 0, `CMD.REINIT`); bộ thu HS và termination của lane clock
chỉ tắt khi clock tĩnh hoặc khi cổng đã đóng ≥ 2 chu kỳ; termination của mỗi lane bật trong
(2 + F, 4 + F] chu kỳ lp sau LP-01 → LP-00 ở chân (F = `LP_FILTER`): phần số của ngân sách
T_D-TERM-EN / T_CLK-TERM-EN (mục 3.4).

## SETTLE

Một công thức cho mọi AFE (driver, `bow_dphy_rx_timing()`), thay `settle_cycles()` (UltraScale+)
và `SETTLE_VID_NS` (Versal) của driver cũ:

```
UI_ps  = 10^12 / lane_rate                       (chia nguyên)
SETTLE = kẹp_1..255( ((SETTLE_NS · 1000 + SETTLE_UI · UI_ps) · MHz + 500000) / 10^6 − (3 + LP_FILTER) )
```

`SETTLE_NS`, `SETTLE_UI` từ `INFO2`, `MHz` = `INFO[17:8]`, `LP_FILTER` = 2. Phép tính nguyên giữ
đúng từng bit phép tính của `settle_cycles()` cũ: KV260 912 Mbit/s, 200 MHz: 22 (`TIM0` =
`0x051E0216`); Huins 1440 Mbit/s, 200 MHz: 19 = `0x13` (`TIM0` = `0x051E0213`, như `SETTLE_VID_NS`
= 95 ns cũ). `lane_rate` = 0 (không biết): đích có phần UI (UltraScale+) lấy 70 ns như
`settle_cycles()` cũ; đích không có phần UI (Versal) không cần lane rate, vẫn ra `0x13` như
`SETTLE_VID_NS` cũ (bản đầu của bước 4 lấy 70 ns = 14 ở đây; sửa sau review). Kiểm trên máy host:
`tools/tests/test_dphy_settle.py` (biên dịch `bow_dphy_rx_settle()` của header bằng `cc`): hai
điểm làm việc, lưới UltraScale+ (mọi lp clock 50–400 MHz, LP_FILTER, lane rate 0 và 80
Mbit/s–2,5 Gbit/s), Versal ở mọi lane rate kể cả 0, và đích 140 ns của firmware mô phỏng `brst0`
(23 = 115 ns).

## Driver (`bow_dphy_rx.h`)

| Hàm | Việc |
|---|---|
| `bow_dphy_rx_probe()`, `bow_dphy_rx_version()` | `ID` = `0x44505202`, tức phiên bản bản đồ của driver (`DPHY_MAP_VERSION` 2); `version()` = `ID[7:0]` khi `ID[31:8]` là "DPR", 0 nếu không có D-PHY (đọc có bắt bus error) |
| `bow_dphy_rx_lanes()`, `bow_dphy_rx_afe()`, `bow_dphy_rx_self_cal()`, `bow_dphy_rx_lp_mhz()` | các trường của `INFO` (số lane, loại AFE `DPHY_AFE_*`, `INFO[23]`, MHz của `lp_clk`) |
| `bow_dphy_rx_settle(ns, ui, lane_rate, mhz, lp_filter)` | công thức `SETTLE` (inline trong header, test host) |
| `bow_dphy_rx_timing(lane_rate)` | `TIM0`: SETTLE theo công thức trên từ `INFO2`, LP_FILTER 2, CLK_SETTLE 150 ns, CLK_MISS = 2^CLK_TOG_DIV byte clock (`TIM1`) + 3 chu kỳ (CLK_TOG_DIV 0: 1 byte clock + 3, như trước), rồi `CMD.APPLY` (bước 6); false khi D-PHY không nhận APPLY (sửa sau review: kết quả của APPLY không còn bị bỏ qua) |
| `bow_dphy_rx_apply()` | `CMD.APPLY`, chờ `CMD[0]` = 0 (tối đa 64 lần đọc; false nếu không: không có `lp_clk`?) |
| `bow_dphy_rx_ctrl(set, clear)` | `CTRL` = (`CTRL` & ¬clear) \| set, rồi APPLY (bit `DPHY_CTRL_*`); false: chưa áp |
| `bow_dphy_rx_lp_cycles(ns)`, `bow_dphy_rx_set_hs_tmo(c)`, `bow_dphy_rx_set_clk_tog_div(d)`, `bow_dphy_rx_set_t_init(c)`, `bow_dphy_rx_set_esc_tmo(u)` | số chu kỳ `lp_clk` của ns (làm tròn lên); các trường của `TIM1` / `TIM2`, mỗi hàm một APPLY (`DPHY_TIM1_RESET` = giá trị reset của `TIM1`); false, không ghi gì, khi giá trị vượt trường (`DPHY_TIM*_MAX`), false khi chưa áp. `set_clk_tog_div()` ghi cùng `TIM0.CLK_MISS` theo lane rate của lần `timing()` cuối (CLK_MISS 0 giữ 0; false khi CLK_MISS cần > 255), vì CLK_MISS cho một byte clock sẽ đóng cổng trong mọi burst khi N ≥ 1 |
| `bow_dphy_rx_v1x(&s)` | `ERR_STATUS`, `LANE_STOP`, `CNT_MISC[31:16]`, `CNT_DSK[31:16]`, mỗi thanh ghi một lần đọc |
| `bow_dphy_rx_power(on, ms)` | `AFE_CTRL.PD` = ¬on; với on, chờ READY (không bao giờ giữa một stream) |
| `bow_dphy_rx_ready()`, `bow_dphy_rx_wait_ready(ms)` | `AFE_STATUS.READY` (driver chỉ chờ nó với AFE tự hiệu chỉnh, `INFO[23]`) |
| `bow_dphy_rx_reinit(ms, &us)` | `CMD.AFE_CAL` cùng `CMD.REINIT` (bước 6; trước: `CMD[1]` = hiệu chỉnh AFE), chờ READY xuống (≤ 20 µs; không xuống = PHY này không có re-init: `DPHY_ENOREINIT`) rồi lên (≤ `ms`: `DPHY_ENOTRDY`); `us` = thời gian từ lệnh tới READY |
| `bow_dphy_rx_des_rst(on)`, `bow_dphy_rx_des_rst_on()` | `CTRL.DES_RST_DIS` = ¬on (qua `bow_dphy_rx_ctrl()`: có APPLY; false: chưa áp) |
| `bow_dphy_rx_set_delay(lane, code)`, `bow_dphy_rx_read_delay(lane)` (với AFE tự hiệu chỉnh: đọc tới khi hai lần giống nhau), `bow_dphy_rx_wait_delay(ms)` (PEND = 0 trên mọi lane có OWN), `bow_dphy_rx_get_delays(d)` (Q với AFE tự hiệu chỉnh, CODE nếu không), `bow_dphy_rx_print_delays(n)` | `DLYn` |
| `bow_dphy_rx_counters(&c)`, `bow_dphy_rx_clear()` | `CNT_BURSTn`, `CNT_CLK`, `CNT_LPERR` (mỗi bộ đếm một lần đọc: cho vòng chờ); `CMD.CNT_CLR`, `ERR_STATUS`, `ERR_LANE` |
| `bow_dphy_rx_snapshot(&c, &lp, &hs)` | các bộ đếm trên cùng `LANE_LP`, `LANE_HS` làm một ảnh chụp (đọc tới khi hai lần đọc tất cả giống nhau, tối đa 9 lần; trước bước 4 `STATUS` giữ cả hai trạng thái lane và `CNT_BURST` ghép lane 0 / 1): để in |
| `bow_dphy_rx_raw(w, now, ms)`, `bow_dphy_rx_byteclk_hz(ms)` | RAW (64 word mỗi lane), tần số byte clock (max của `BYTECLK`) |

`LANE_LP`, `LANE_HS`, `AFE_STATUS` cũng đọc thẳng được qua struct `DPHY` (`DPHY->LANE_LP`, macro
`DPHY_LANE_*`, `DPHY_AFE_*`), như `csi2_test` làm khi lane đứng yên; dòng `phy:` của `stat`
(`bow_csi2rx_print_status()`) dùng `bow_dphy_rx_snapshot()`.

Lệnh `phy` của `csi2_test` cho bước 6 (bo): `phy tinit <us>`, `phy hstmo <us>|reset`, `phy missoff
0|1`, `phy v1x` (các thanh ghi v1.x) và `phy check` (HS_TMO 2 µs cắt mọi burst và được đếm, HS_TMO
reset, CLK_MISS_OFF 8 frame không lỗi, T_INIT 100 µs với REINIT, rồi về giá trị reset). Firmware
giữ giá trị reset nếu không dùng các lệnh này. Sửa sau review: `phy tinit` / `phy hstmo` từ chối giá
trị không vừa trường (µs × MHz của `lp_clk` > 2^20 − 1 / 2^24 − 1 chu kỳ: 5242 / 83 886 µs ở
200 MHz; trước đó `tinit` nhận tới 10^6 µs và bị cắt im lặng), mọi lệnh in `error: the D-PHY did
not take CMD.APPLY (no lp clock?)` khi APPLY không được nhận; `csi2_274` (mô phỏng) chạy `phy v1x` và
`phy check`.

`bow_csi2rx_probe()` đọc `INFO[6]` của controller: 0 (hay không có `ID` của D-PHY) → in
`csi2rx: bitstream before the D-PHY split, rebuild it` và trả false; một D-PHY có phiên bản bản đồ
khác của driver (sửa sau review bước 6) → in `csi2rx: D-PHY register map version 1, this firmware
needs 2: bitstream older than the firmware, rebuild them from one commit` (hay ngược lại, firmware
cũ hơn) và trả false. Firmware của bước 5 gặp PDI của bước 6 (`ID` `0x44505202`) không nhận ra
`ID` và in thông báo trước bước 4 (`bitstream before the D-PHY split`): lý do trong câu sai, nhưng nó
vẫn từ chối chạy. `bow_csi2rx_start()` gọi `bow_dphy_rx_timing()` (trả `CSI2RX_EAPPLY` khi APPLY
không được nhận; `bow_csi2rx_strerror()` cho dòng lỗi), `bow_csi2rx_stop()` chờ `LANE_HS[17]` = 0,
`bow_csi2rx_clear()` ghi thêm `CMD.CNT_CLR` của D-PHY; hiệu chỉnh eye và kiểm tra lề dùng delay của
D-PHY.

## Kiểm chứng (bước 4, 5 và 6)

Kết quả đầy đủ ở [mipi_rx_arch.md](mipi_rx_arch.md) mục 10 (*Kết quả bước 4*, *5*, *6*). Tóm tắt
bước 6:

- **Bench D-PHY** (`make -C hw/ip/dphy_rx/dv test`, CI và `make test-ip`): `tb_bow_dphy_rx.sv`,
  `bow_dphy_rx` một mình với máy phát mức bit `csi2_tx_model.sv` trên cổng AFE, `bow_ppi_chk` /
  `bow_afe_chk` gắn vào, bộ đếm lỗi PPI lấy mẫu ở `lp_clk` / 31,87, bất biến AFE của bench (cổng chỉ
  đổi khi lane clock tĩnh, bộ thu lane clock tắt sau cổng, termination trong ngân sách; mục 8.3 của
  [mipi_rx_arch.md](mipi_rx_arch.md)), mọi bộ đồng bộ dựng với `BOW_CDC_JITTER` và
  `BOW_SYNC_JITTER` (một bit đổi trong 0,5 ns trước cạnh clock có thể về muộn một chu kỳ: bus không
  gray sẽ cho giá trị nó chưa từng có). Clock của bench không là bội của nhau; `make test` hỏng khi
  một bản dựng không có lần nhận muộn nào. 12 test (`basic`, `apply`, `tinit`, `hstmo`, `esctmo`,
  `ulps`, `hsrx`, `missoff`, `clklost`, `lateeot`, `gray`, `togdiv`), 2 và 4 lane, `gray` thêm
  `lp_clk` ≈ 10 × `clk_i`, `togdiv` byte clock ≈ 2 × `lp_clk`: 26 case. `make mutants`
  (`mutants_dphy.py`): 53 mutant, ít nhất một mỗi chức năng, với 2 và 4 lane, 53/53 chết.
- **Tương đương** (`make -C hw/ip/dphy_rx/fm equiv`, mặc định `STEP=6 REF=1c76364`): cả bộ thu
  không tương đương bước 5 theo thiết kế (APPLY, bộ đếm gray, bản đồ thanh ghi), nên chứng minh hai
  phần: controller `bow_csi2rx` (5 cấu hình; cắt ở net `lp_err` cả hai phía: logic sau nó được
  chứng minh với mọi chuỗi lỗi lp, `dsk_last_q` giữ 0: `RxSkewCalHS` là xung như v1) và máy LP
  `bow_dphy_lp` (data lane, lane clock; đầu vào mới ở giá trị reset, `tmr_hi_q` và `exit_wait_q`
  giữ 0): 7/7 đạt. Bộ lấy mẫu `bow_ppi_err_rx` trước điểm cắt không có đối tác ở bước 5: chỉ DV phủ
  nó (mutant `lp_err_bit0_only`, `lperr_rx_last_reset`, `ppi_rx_changes_only`).
- **DV cả bộ thu** như trước, với mô hình của shadow / APPLY, DIRTY, thanh ghi mới và LATE_EOT; mọi
  kết quả của bước 5 giữ (hai ngoại lệ của mục 4.12).
- **Sau review** ([mipi_rx_arch.md](mipi_rx_arch.md) mục 10, *Sửa sau review bước 6*): thứ tự ULPS
  của PPI, mô hình jitter của `bow_sync` chạy thật (bản đầu không bao giờ chạy), REINIT qua `Exit`
  ở lane clock, Formality cắt ở `lp_err` (mutant F1–F3 của review nay hỏng), `CMD[31]` DIRTY,
  `ID[7:0]` = 2, `HS_TMO` / `ESC_TMO` so bằng ≥, `HSRX_DISABLE` = ¬`term_en`, bus skew của bản chép
  shadow và của `CLK_TOG_DIV`, `CLK_MISS` theo `CLK_TOG_DIV` trong driver, 18 mutant mới.

Tóm tắt bước 5:

- **Tương đương** (`make -C hw/ip/dphy_rx/fm equiv STEP=5 REF=3d3985a`, mặc định của bước 5): bộ thu của
  bước 5 sau wrapper cổng của bước 4 (`hw/ip/dphy_rx/fm/bow_mipi_rx_s4.sv`) so với bộ thu của
  bước 4, 5 cấu hình, đạt; ngoài so sánh chỉ có đúng các thay đổi có chủ ý (cổng `byte_rst_o`,
  `burst_rst_en_o`, `dly_tap_o`, `dly_load_o` của bước 4; `AFE_CTRL.PD` giữ 0; cell nạp tap và
  reset ISERDES chuyển vào adapter).
- **DV:** mô phỏng hai adapter dùng chính logic của chúng: `csi2_tx_model` chạy
  `bow_dphy_dly_xusp` (nạp tap, reset ISERDES) và `bow_dphy_dly_xphy` (trình tự nạp XPHY, `RX_RST`)
  trên cổng AFE của bộ thu và kiểm hợp đồng XPHY (lần nạp trong user mode, ≥ 12 chu kỳ sau
  `RX_EN_VTC` = 0, cách nhau ≥ 4, không nạp khi chưa ready); `bow_afe_chk` (trên) ở mọi bench;
  `dly` thêm một đoạn bước 5 (ghi lại cùng mã: không nạp; `AFE_CTRL.PD` = 1 rồi 0: OWN xoá, ghi
  lại cùng mã: nạp), `be` phủ byte enable của `AFE_CTRL`; `make mutants-rx` 12/12 (7 mutant mới
  của `des_rst`, OWN, `lprx_en` và logic delay của hai adapter).
- **Sau review** ([mipi_rx_arch.md](mipi_rx_arch.md) mục 10, *Sửa sau review bước 5*): luật
  `lane_pd` mới, `dly` thêm xung PD hai lần ghi liền nhau; bench đơn vị `tb_afe_dly` (logic hai
  adapter với mô hình primitive: `RX_EN_VTC` / `RX_RST` / không `LD` khi không `ready`, OWN xuống / lên,
  nạp lại khi `ready` lên, reset `ISERDESE3`, số lần nạp, không nạp mã trộn khi bit lệch tới một chu
  kỳ) và `tb_dphy_afe` (trên), cả hai trong `test-rx` (CI); `make mutants-rx` 28/28 (16 mới);
  `make -C sim lint` báo cả đầu vào nối rỗng (`hw/lint/empty_inputs.py`).
- **xsim:** UltraScale+ kiểm `des_rst` = ¬cổng ở mọi cạnh `vid_clk` và đếm `LOAD` của `IDELAYE3`
  (0 trước lần ghi đầu, 1 mỗi lane sau `DLYn`, ghi lại cùng mã không nạp); Versal thêm `SAME`
  (cùng mã: 0 `LD`) và `OWN` (OWN của một lane xuống: không `LD`; lên lại: 1 `LD`).

Bước 4:

- **Mô hình và DV** (`make -C hw/ip/csi2rx/dv test`): mô hình `csi2_model.py` có bản đồ của cả hai
  khối (D-PHY ở `0xC00`: bộ đếm, `ERR_*`, `IRQ_*`, `LANE_*`, `AFE_STATUS`, `DLYn` với PEND / OWN,
  RAW, `CMD.REINIT`, mặt nạ `ErrControl*`; địa chỉ PHY cũ của controller đọc 0). Bench cả bộ thu
  (`tb_bow_csi2rx`) nối `reinit_o` / `burst_rst_en_o` (từ bước 5: `afe_cal_start_o`, `afe_pd_o`,
  `afe_des_rst_o`) vào mô hình PHY Versal và kiểm `BurstRxRst` ở mỗi burst; mỗi lần dump đọc mọi thanh ghi của hai khối; test `be` phủ byte enable của cửa sổ
  D-PHY; `dly` dùng `CMD.REINIT`; `loss` kiểm `CLK_CONT` (lỗi lane clock chỉ ở `CNT_LPERR`).
  Checker PPI (`bow_ppi_chk`) thêm hai luật: không `ErrControl[l]` khi `Enable[l]` = 0, không
  `ErrControlClk` khi `CLK_CONT`. Sau review: `rxoff` (1, 2, 4 lane; clock liên tục trên 2, 4
  lane) kiểm cổng sự kiện aligner
  của controller (RX tắt với PHY bật, dừng quét qua cửa sổ dò sync, RX bật giữa một burst sync
  hỏng); `raw` (4 lane, PHY Versal) kiểm RAW với một khe đọc mỗi burst sau sync và data lane 0
  vào HS muộn hơn các lane khác (word đầu của lane 0 phải là `00` của HS-ZERO của nó);
  `make mutants-rx` (`mutants_rx.py`): 2 mutant RAW trên `bow_dphy_rx` và 3 mutant của cổng sự
  kiện, 5/5 chết.
- **xsim:** KV260 (`test-dphy`, seed 1–3) đọc `ID`, `INFO`, `INFO2`, `TIM0`, `LANE_LP` / `LANE_HS`,
  `CNT_BURSTn` / `CNT_CLK`, `DLYn` (PEND tới burst sau, OWN) và RAW của D-PHY; Versal
  (`test-dphy-versal`, 25 cấu hình) thêm `reinit_pulse`: xung 640 ns như `CMD.REINIT` (từ bước 6
  `CMD.AFE_CAL`).
- **Host:** `tools/tests/test_dphy_settle.py` (công thức `SETTLE`).
