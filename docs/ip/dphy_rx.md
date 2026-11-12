# D-PHY số (`bow_dphy_rx`) và thanh ghi D-PHY (`0x4000_8C00`)

Phần số của D-PHY RX của Bow32: máy LP, timer, cổng byte clock, dò sync và căn byte, đồng hồ đo
byte clock, RAW và, từ bước 4 của kế hoạch chuyển ([mipi_rx_arch.md](mipi_rx_arch.md) mục 10),
**thanh ghi riêng** ở `0x4000_8C00` (offset `0xC00` của cửa sổ 4 KiB `CSI2RX`). Nó nói PPI
(`bow_ppi_pkg`, [mipi_rx_arch.md](mipi_rx_arch.md) mục 5) với controller CSI-2 `bow_csi2rx`
([csi2rx.md](csi2rx.md)); `bow_mipi_rx` (instance `u_csi2rx` trong `bow32_top`) ghép hai khối và
chia cửa sổ thanh ghi. Phía dưới là I/O của FPGA (`bow_dphy_io_xusp` trên KV260,
`bow_dphy_io_versal` trên Huins), từ bước 5 là giao diện AFE. Đặc tả đầy đủ (mọi trường, cả những
trường của các bước sau): [mipi_rx_arch.md](mipi_rx_arch.md) mục 4.10; tài liệu này là **v1**, tức
những gì RTL có từ bước 4.

| Thông số | Giá trị |
|---|---|
| RTL | `hw/ip/dphy_rx/rtl/`: `bow_dphy_rx.sv` (khối), `bow_dphy_rx_regs.sv` (thanh ghi, miền bus), `bow_dphy_raw.sv` (RAW), `bow_dphy_lp.sv` (máy LP), `bow_dphy_align.sv` (aligner); `hw/ip/dphy_rx/dphy_rx.f` (cần `common.f`, `bus.f`) |
| Thanh ghi | cửa sổ 1 KiB ở `0x4000_8C00` (`bow_mipi_rx` chuyển offset `0xC00`–`0xFFF` của `CSI2RX` cho D-PHY); ngắt `irq_o` vào `IRQ_STATUS[5]` của controller (chung `irq_fast[7]`) |
| Driver | `sw/common/include/bow_dphy_rx.h` (mọi tên có tiền tố `DPHY_`), `sw/common/src/bow_dphy_rx.c` |
| Clock | `clk_i` (bus, 50 MHz), `lp_clk_i` (miền lp; FPGA: `vid_clk`, 200 MHz), `byte_clk_i` (byte clock của PHY, bị gate) |
| Reset | của chính D-PHY (mục 4.11 của đặc tả): `rst_ni` (bus), `rst_ni & lp_rst_ni` đồng bộ ở miền lp (`u_lrst`) và miền byte (`u_brst`); không còn reset dùng chung với controller |

## Tham số

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `Lanes` | 2 | data lane 1, 2 hoặc 4 (giá trị khác: lỗi elaborate) |
| `DlyVid` | 0 | giao thức nạp tap: 0 miền byte (`IDELAYE3`), 1 miền lp (XPHY của Versal); bỏ ở bước 5 |
| `LpClkHz` | 200 MHz | tần số `lp_clk_i`: `INFO[17:8]` (MHz, bão hoà ở 1023) |
| `BusClkHz` | 0 | tần số `clk_i` (0 = không kiểm); elaborate báo lỗi nếu `lp_clk` > 16/3 × `clk_i` (sự kiện miền lp về bus, như `CpuClkHz` của controller) |
| `AfeKind` | `DlyVid` ? 2 : 1 | `INFO[7:5]`: 0 macro ASIC, 1 adapter UltraScale+, 2 adapter Versal, 3 mô hình |
| `AfeSettleNs`, `AfeSettleUi` | 107 / 24 (UltraScale+), 120 / 0 (Versal) | `INFO2[15:0]`: đích của `SETTLE` (mục *SETTLE*) |
| `AfeTrailB` | 0 (UltraScale+), 8 (Versal) | `INFO2[23:16]`: byte thêm mỗi lane cuối burst do AFE (FIFO RX của XPHY) |

`bow_mipi_rx` đặt `LpClkHz` = `PhyClkHz`, `BusClkHz` = `CpuClkHz` và để `AfeKind`, `AfeSettle*`,
`AfeTrailB` theo `DlyVid`.

## Bản đồ thanh ghi v1

Offset trong cửa sổ D-PHY (cộng `0x4000_8C00`). Byte enable và W1C như controller: byte không
ghi giữ nguyên, bit W1C ngoài các byte ghi không bị xoá, phần cứng set cùng chu kỳ thì set thắng,
lệnh cần byte 0. Bộ đếm 32 bit bão hoà. Trường của lane trên `Lanes` (và lane 4–7) đọc 0, ghi bị
bỏ. **Offset hay trường ghi "sau" chưa có ở v1: đọc 0, ghi bị bỏ** (bước thêm nó ở cột cuối).

| Offset | Tên | Truy cập | v1: bit (giá trị reset) | Thêm sau |
|---:|---|:--:|---|---|
| 0x000 | `ID` | R | `0x44505201` ("DPR", phiên bản 1) | |
| 0x004 | `INFO` | R | [3:0] `Lanes`, [4] PPI 16 bit (0), [7:5] `AfeKind`, [17:8] `lp_clk` MHz, [21:18] `DlyW` (9), [22] delay lane clock (0), [23] AFE tự hiệu chỉnh delay (BISC: `AfeKind` = 2), [31:24] 0. KV260: `0x0024C822`, Huins: `0x00A4C844` | [24]–[31] theo khối: bước 6, 8, 10 |
| 0x008 | `INFO2` | R | [7:0] `SETTLE_NS`, [15:8] `SETTLE_UI`, [23:16] byte trail của AFE, [31:24] 0. KV260: `0x0000186B`, Huins: `0x00080078` | |
| 0x00C | `CTRL` | RW | [1] CLK_CONT (0): lane clock liên tục, bộ thu + cổng lane clock bật suốt khi `EnableClk` (thay `CTRL.CLK_FORCE` của controller); [6] DES_RST_DIS (0): 1 tắt reset đường thu khi cổng đóng (`burst_rst_en_o` = 0; chỉ để thử, bo Huins hỏng khi tắt) | [0] EN, [2] ULPS_EN, [3] HSRX_EARLY, [4] SOT_TOL, [5] DSK_EN, [7] CLK_LOST_EN, [15:8] LANE_EN, [16] CLK_MISS_OFF: bước 6, 8, 10 |
| 0x010 | `CMD` | W | [1] REINIT: khởi động lại I/O của PHY (`reinit_o` = 1 trong 32 chu kỳ bus; adapter Versal: XPLL, BISC, VT chạy lại, tap đã nạp mất; adapter UltraScale+: không có); [3] CNT_CLR: xoá `CNT_*` của D-PHY. Đọc 0 | [0] APPLY, [2] AFE_CAL, [4] DSK_RUN, [15:8] DLY_REL, [16] DLY_CLK_REL: bước 5, 6, 8 |
| 0x014 | `AFE_CTRL` | — | sau | bước 5 |
| 0x018 | `AFE_STATUS` | R | [0] READY (`phy_rdy_i` qua 2 flop), [15:8] `status` thô của AFE qua 2 flop (Versal: [11] PHY_RDY mọi nibble, [10] DLY_RDY mọi nibble, [9] XPLL LOCKED_FB, [8] LOCKED; thay GPIO PB6 / PB7 của top Huins) | [1] CAL_DONE, [2] CAL_ERR: bước 5 |
| 0x01C, 0x020 | `AFE_TRIM0/1` | — | sau | bước 5 |
| 0x024 | `TIM0` | RW | bố cục và đơn vị của `PHY_CFG` cũ (chu kỳ `lp_clk`): [7:0] SETTLE (14), [11:8] LP_FILTER (2), [23:16] CLK_SETTLE (30), [31:24] CLK_MISS (8, 0 = tắt); reset `0x081E020E`. Chỉ đổi khi PHY tắt (`CTRL.PHY_EN` = 0 của controller): v1 qua `bow_sync` từng bit | |
| 0x028, 0x02C | `TIM1`, `TIM2` | — | sau | bước 6 |
| 0x030 | `LANE_LP` | R | LP {P, N} sau lọc, cả khi PHY tắt: [1:0] lane clock, [2l+3:2l+2] data lane l (reset LP-11) | |
| 0x034 | `LANE_HS` | R | [0] bộ thu HS + termination lane clock, [l+1] data lane l; [16] cổng byte clock mở; [17] `RxClkActiveHS` (v1: chính cổng, mục 5.3 của đặc tả: với CLK_CONT là 1 suốt khi lane clock bật); [18] BYTECLK_OK (`BYTECLK` ≠ 0) | |
| 0x038 | `LANE_STOP` | — | sau | bước 6 |
| 0x03C | `IRQ_STATUS` | W1C | [0] ERR (một bit `ERR_STATUS` được set), [3] RAW_DONE | [1] ULPS, [2] DSK_DONE, [4] AFE, [5] PRBS |
| 0x040 | `IRQ_EN` | RW | [0], [3] như `IRQ_STATUS` (0); `irq_o` = \|(`IRQ_STATUS` & `IRQ_EN`) | |
| 0x044 | `ERR_STATUS` | W1C | [2] CONTROL: lỗi chuỗi LP hoặc watchdog HS của một lane bất kỳ (mọi lỗi của FSM, không che) | [0] SOT_SYNC, [1] SOT, [3] HS_TMO, [4]–[10]: bước 6, 8, 10 |
| 0x048 | `ERR_LANE` | W1C | [8+l] CONTROL data lane l, [16] CONTROL lane clock | [l] SOT_SYNC: bước 6 |
| 0x04C | `BYTECLK` | R | [19:0] byte clock trong 65536 chu kỳ bus (như `BYTECLK` cũ) | |
| 0x050–0x05C | `CNT_BURST0`…`3` | R | số lần vào HS của data lane l | |
| 0x060–0x06C | `CNT_BURST4`…`7` | R | 0 (lane 4–7) | khi có 8 lane |
| 0x070 | `CNT_CLK` | R | số lần vào HS của lane clock | |
| 0x074 | `CNT_LPERR` | R | lỗi LP (CONTROL) của mọi lane | |
| 0x078, 0x07C | `CNT_DSK`, `CNT_MISC` | — | sau | bước 6, 8 |
| 0x080–0x08C | `DLY0`…`DLY3` | RW | [8:0] CODE (0): ghi = mã delay yêu cầu, đọc = mã đã yêu cầu (v1: phần mềm là chủ duy nhất, mã D-PHY lái tới PHY bằng nó khi PEND = 0); [15] PEND (R): OWN = 1 và delay của PHY ([24:16]) chưa bằng CODE; [24:16] `dly_q`: delay PHY đang dùng (CNTVALUEOUT, qua 2 flop từng bit); [31] OWN (R, 0): 1 = lane dùng mã của phần mềm. Lần ghi có byte 0 hoặc 1 đặt CODE và OWN = 1 (khi AFE_STATUS.READY = 1) và tạo một yêu cầu nạp; ghi chỉ byte 2–3 không làm gì. OWN = 0 khi READY = 0 (PHY khởi động lại: tap đã nạp mất) | [9] (DlyW 10), nhả bằng `CMD.DLY_REL`, mã do bộ máy deskew đặt: bước 5, 8 |
| 0x090–0x09C | `DLY4`…`7` | RW | đọc 0, ghi bị bỏ | khi có 8 lane |
| 0x0A0–0x0FC | `DLY_CLK`, `AFE_OVR*`, `DSK_*`, `PRBS_*` | — | sau | bước 5, 8 |
| 0x100 | `RAW_CTRL` | RW | như `RAW_CTRL` cũ: ghi [0] ARM, [1] NOW; đọc [0] ARMED, [1] NOW, [8] DONE | |
| 0x104, 0x108 | `LANE_MAP`, `LANE_POL` | — | sau | bước 10 |
| 0x200–0x3FC | `RAW[64]` | R | entry i: `0x200 + 8i` = lane 0–3 (byte k = lane k), `0x204 + 8i` = lane 4–7 (0) | |

Giá trị `INFO` ở bảng: KV260 (2 lane, `lp_clk` 200 MHz, `AfeKind` 1) và Huins (4 lane, 200 MHz,
`AfeKind` 2, bit 23).

### Ghi chú

- **Thanh ghi PHY cũ của controller không còn, không có alias** (quyết định D1, mục 6.3 của đặc
  tả): `PHY_CFG`, phần LP/HS/CE/BYTECLK_OK/PHY_RDY của `STATUS`, `CNT_BURST`, `CNT_BURST23`,
  `CNT_MISC[23:0]`, `BYTECLK`, `DLY0`…`DLY3`, `RAW_CTRL`, `RAW`, `CTRL.CLK_FORCE` và
  `INFO[5]` của controller đọc 0. `INFO[6]` = 1 của controller báo "D-PHY ở `0xC00`"; driver
  đọc nó và từ chối bitstream trước bước 4.
- **Che `ErrControl`.** D-PHY che lỗi LP trước khi đưa lên PPI: `ErrControl[l]` theo `Enable[l]`
  (đã đồng bộ, như máy LP thấy nó), `ErrControlClk` khi `CTRL.CLK_CONT` = 1; controller chỉ còn
  phép OR cho luật đánh dấu burst mất và `ERR_STATUS.LP` của nó. `CNT_LPERR`, `ERR_STATUS.CONTROL`
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
- **DLYn ở v1.** Giao thức nạp tap vẫn là của trước bước 5 (`DlyVid` 0: nạp ở byte clock khi
  mã đổi, tức ở burst sau; 1: mỗi lần ghi một lần nạp ở miền lp, không cần byte clock). Chưa có
  chủ thứ hai của mã, nên CODE đọc lại là mã đã ghi và PEND lấy từ chính delay của PHY: `wait_delay`
  chờ PEND = 0 trên các lane có OWN. OWN thay mặt nạ `dly_written` của driver cũ.
- **REINIT** thay GPIO PA4 của top camera Huins: một xung phần cứng (không còn mức phần mềm giữ);
  `AFE_STATUS.READY` xuống rồi lên lại sau XPLL lock + BISC. Phần "FSM về `WaitStop`, `T_INIT`
  đếm lại" của `CMD.REINIT` trong đặc tả đến ở bước 6; chạy lại hiệu chỉnh của AFE thành
  `CMD.AFE_CAL` ở bước 5.
- **DES_RST_DIS** thay GPIO PA5: reset đường thu khi cổng đóng **luôn bật** từ reset
  (`burst_rst_en_o` = 1, flop miền bus), chỉ tắt bằng bit thử này. Trước bước 4 phần mềm đặt PA5 = 1
  ở mỗi lần `start`; driver mới vẫn ghi DES_RST_DIS = 0 ở mỗi lần start trên Versal (tuỳ chọn mô
  phỏng `CAM_BURST_RST=0` ghi 1).

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
| `bow_dphy_rx_probe()` | `ID` = `0x44505201` (đọc có bắt bus error) |
| `bow_dphy_rx_lanes()`, `bow_dphy_rx_afe()`, `bow_dphy_rx_self_cal()`, `bow_dphy_rx_lp_mhz()` | các trường của `INFO` (số lane, loại AFE `DPHY_AFE_*`, `INFO[23]`, MHz của `lp_clk`) |
| `bow_dphy_rx_settle(ns, ui, lane_rate, mhz, lp_filter)` | công thức `SETTLE` (inline trong header, test host) |
| `bow_dphy_rx_timing(lane_rate)` | `TIM0`: SETTLE theo công thức trên từ `INFO2`, LP_FILTER 2, CLK_SETTLE 150 ns, CLK_MISS 1 byte clock + 3 chu kỳ (như trước) |
| `bow_dphy_rx_ready()`, `bow_dphy_rx_wait_ready(ms)` | `AFE_STATUS.READY` (driver chỉ chờ nó với AFE tự hiệu chỉnh, `INFO[23]`) |
| `bow_dphy_rx_reinit(ms, &us)` | `CMD.REINIT`, chờ READY xuống (≤ 20 µs; không xuống = PHY này không có re-init: `DPHY_ENOREINIT`) rồi lên (≤ `ms`: `DPHY_ENOTRDY`); `us` = thời gian từ lệnh tới READY |
| `bow_dphy_rx_des_rst(on)`, `bow_dphy_rx_des_rst_on()` | `CTRL.DES_RST_DIS` = ¬on |
| `bow_dphy_rx_set_delay(lane, code)`, `bow_dphy_rx_read_delay(lane)` (với AFE tự hiệu chỉnh: đọc tới khi hai lần giống nhau), `bow_dphy_rx_wait_delay(ms)` (PEND = 0 trên mọi lane có OWN), `bow_dphy_rx_get_delays(d)` (Q với AFE tự hiệu chỉnh, CODE nếu không), `bow_dphy_rx_print_delays(n)` | `DLYn` |
| `bow_dphy_rx_counters(&c)`, `bow_dphy_rx_clear()` | `CNT_BURSTn`, `CNT_CLK`, `CNT_LPERR` (mỗi bộ đếm một lần đọc: cho vòng chờ); `CMD.CNT_CLR`, `ERR_STATUS`, `ERR_LANE` |
| `bow_dphy_rx_snapshot(&c, &lp, &hs)` | các bộ đếm trên cùng `LANE_LP`, `LANE_HS` làm một ảnh chụp (đọc tới khi hai lần đọc tất cả giống nhau, tối đa 9 lần; trước bước 4 `STATUS` giữ cả hai trạng thái lane và `CNT_BURST` ghép lane 0 / 1): để in |
| `bow_dphy_rx_raw(w, now, ms)`, `bow_dphy_rx_byteclk_hz(ms)` | RAW (64 word mỗi lane), tần số byte clock (max của `BYTECLK`) |

`LANE_LP`, `LANE_HS`, `AFE_STATUS` cũng đọc thẳng được qua struct `DPHY` (`DPHY->LANE_LP`, macro
`DPHY_LANE_*`, `DPHY_AFE_*`), như `csi2_test` làm khi lane đứng yên; dòng `phy:` của `stat`
(`bow_csi2rx_print_status()`) dùng `bow_dphy_rx_snapshot()`.

`bow_csi2rx_probe()` đọc `INFO[6]` của controller: 0 (hay không có `ID` của D-PHY) → in
`csi2rx: bitstream before the D-PHY split, rebuild it` và trả false. `bow_csi2rx_start()` gọi
`bow_dphy_rx_timing()`, `bow_csi2rx_stop()` chờ `LANE_HS[17]` = 0, `bow_csi2rx_clear()` ghi
thêm `CMD.CNT_CLR` của D-PHY; hiệu chỉnh eye và kiểm tra lề dùng delay của D-PHY.

## Kiểm chứng (bước 4)

Kết quả đầy đủ ở [mipi_rx_arch.md](mipi_rx_arch.md) mục 10 (*Kết quả bước 4*). Tóm tắt:

- **Mô hình và DV** (`make -C hw/ip/csi2rx/dv test`): mô hình `csi2_model.py` có bản đồ của cả hai
  khối (D-PHY ở `0xC00`: bộ đếm, `ERR_*`, `IRQ_*`, `LANE_*`, `AFE_STATUS`, `DLYn` với PEND / OWN,
  RAW, `CMD.REINIT`, mặt nạ `ErrControl*`; địa chỉ PHY cũ của controller đọc 0). Bench cả bộ thu
  (`tb_bow_csi2rx`) nối `reinit_o` / `burst_rst_en_o` vào mô hình PHY Versal và kiểm `BurstRxRst` ở
  mỗi burst; mỗi lần dump đọc mọi thanh ghi của hai khối; test `be` phủ byte enable của cửa sổ
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
  (`test-dphy-versal`, 25 cấu hình) thêm `reinit_pulse`: xung 640 ns như `CMD.REINIT`.
- **Host:** `tools/tests/test_dphy_settle.py` (công thức `SETTLE`).
