# Bộ thu MIPI CSI-2 (`bow_mipi_rx`: `bow_dphy_rx` + `bow_csi2rx`)

Bộ thu **MIPI CSI-2** của Bow32 nhận ảnh RAW10/RAW8 của cảm biến qua **D-PHY**
1, 2 hoặc 4 lane và đưa pixel vào ISP dưới dạng AXI4-Stream RAW10, **1 pixel/clock**.
Nó thay MIPI CSI-2 RX Subsystem của AMD trong bitstream `kv260_cam`: không cần
IP hay license của hãng, mọi tầng (D-PHY, SerDes, CDC, protocol) đọc được trong
RTL, và có sẵn công cụ để học và bring-up: bộ đếm lỗi, log packet, word thô của
PHY, bản đồ eye. RTL (độc lập công nghệ): `hw/ip/csi2rx/rtl/` (controller CSI-2 `bow_csi2rx`
với thanh ghi, wrapper `bow_mipi_rx`) và `hw/ip/dphy_rx/rtl/` (phần số của D-PHY `bow_dphy_rx`,
PPI `bow_ppi_pkg`). `bow_mipi_rx` (instance `u_csi2rx` trong `bow32_top`) ghép `bow_dphy_rx`
(`u_dphy_rx`) và `bow_csi2rx` (`u_csi2rx`) bằng PPI, mục *Phân cấp và PPI*; I/O của FPGA
`hw/fpga/common/rtl/bow_dphy_io_xusp.sv` (UltraScale+, KV260) hoặc
`hw/fpga/common/rtl/bow_dphy_io_versal.sv` (XPHY của Versal, Huins MFP-VP1902,
IMX274 4 lane, mục *Bốn lane, PHY Versal và IMX274*). Driver:
`sw/common/include/bow_csi2rx.h`. Mô hình tham chiếu: `tools/csi2/csi2_model.py`.
Chạy trên board: [../camera_kv260.md](../camera_kv260.md) (KV260, IMX219, 2 lane),
[../camera_huins.md](../camera_huins.md) (Huins MFP-VP1902, IMX274, 4 lane).
Đánh giá cho camera công nghiệp và SoC camera AI:
[../csi2rx_review.md](../csi2rx_review.md). Kiến trúc cho ASIC (D-PHY analog và số, PPI, bộ
điều khiển sau khi tách, kế hoạch chuyển): [mipi_rx_arch.md](mipi_rx_arch.md).

```
          FPGA (bow_dphy_io_xusp)        bow_mipi_rx (u_csi2rx) = bow_dphy_rx + bow_csi2rx
                                ┌ bow_dphy_rx (u_dphy_rx) ────────┐ PPI
 J9 ──► IBUFDS_DPHY, IDELAYE3,  ──rx_data──► dphy_align ×2 ───────┼─► lane_merge ──► packet ───┐
        ISERDESE3 1:8,          ──byte_clk─► (miền byte, 114 MHz) │                (ECC, CRC,  │
        BUFGCE_DIV /1, /4       ──LP {P,N}─► dphy_lp ×3 (video)   │                VC/DT,      │
                                ◄── hs_en, byte_ce, byte_rst, tap │                FS/FE)      ▼
                                └──────── dải phụ (tạm thời) ─────┘                         unpack
 ISP ◄── m_axis RAW10 (1 pixel/clock) ◄── csi2rx_out ◄── fifo_async ◄──────────────── (RAW10/RAW8)
                                          (video)        (byte → video)
 bus ◄─► csi2rx_regs (CPU): CTRL, STATUS, IRQ, bộ đếm, DLY, LOG, RAW, FRAME/LINE_TIME, BYTECLK
         bow_csi2rx (u_csi2rx): mọi khối ngoài bow_dphy_rx, kể cả thanh ghi
```

Tên module trong RTL có tiền tố `bow_` (`bow_dphy_rx`, `bow_dphy_lp`, `bow_dphy_align`,
`bow_fifo_async`, `bow_sync_bus`) hoặc `bow_csi2_` / `bow_csi2rx_` (`bow_csi2_packet`,
`bow_csi2rx_out`...).

| Thông số | Giá trị |
|----------|---------|
| Đầu vào | D-PHY v1.x, 1, 2 hoặc 4 data lane, clock lane liên tục hoặc không; KV260: IMX219, 2 lane × 912 Mbit/s; Huins MFP-VP1902: IMX274, 4 lane × 1440 Mbit/s |
| Packet | CSI-2 v1.x: ECC header (sửa 1 bit), CRC-16, VC 2 bit, FS/FE; nhận RAW10 (0x2B) hoặc RAW8 (0x2A) của một VC, packet khác được kiểm CRC rồi bỏ |
| Đầu ra | AXI4-Stream `tdata[9:0]`, `tuser[0]` = pixel (0, 0) của frame (frame không ra được dòng đầu thì bị bỏ cả frame), `tlast` = cuối dòng (khung của ISP), `tuser[1]` = dòng lỗi (cùng `tlast`); RAW8 thành `byte << 2`; tôn trọng `tready`, tràn FIFO vẫn giữ khung dòng; `FRAME_ERR` = cờ lỗi của từng frame, chốt ở FE |
| Thông lượng | 1 pixel/clock video (200 Mpx/s ở 200 MHz), FIFO `FifoDepth` nhóm × 4 pixel (KV260 256, Huins 512); miền byte nhận 8 × `Lanes` bit mỗi byte clock |
| Clock | CPU `clk_i`, video `vid_clk_i`, byte `byte_clk_i` = HS clock / 4 (chỉ chạy khi có HS; 114 MHz trên KV260, 180 MHz với IMX274) |
| Thanh ghi | peripheral bus `0x4000_8000` (4 KiB), ngắt `irq_fast[7]` |
| Tham số | `Lanes` (1, 2, 4; giá trị khác: `$error` lúc elaboration), `PhyClkHz` (tần số `vid_clk_i`), `CpuClkHz` (tần số `clk_i`, 0 = không kiểm; elaborate báo lỗi nếu `vid_clk_i` > 16/3 × `clk_i`), `HasPhy` (có D-PHY), `FifoDepth` (256), `DlyVid` (0: tap ở miền byte như IDELAYE3; 1: miền video như XPHY của Versal) |

## D-PHY trong một trang

Mỗi lane là một cặp dây `P`/`N` với hai chế độ:

- **LP** (low power): hai dây được lái riêng, 0 hoặc 1,2 V. Trạng thái ghi
  `{P, N}`: LP-11 = *stop* (nghỉ), LP-01 = xin vào HS, LP-00 = cầu sang HS,
  LP-10 = vào escape mode (Bow32 không hỗ trợ: báo lỗi LP).
- **HS** (high speed): vi sai ~200 mV, bộ thu phải bật **termination 100 Ω**.
  Bit thấp của mỗi byte đi trước.

```
data lane:  LP-11 │ LP-01 │ LP-00   │ HS-0 (HS-ZERO) │ 0xB8 │ byte 0, byte 1 ... │ HS-TRAIL │ LP-11
                    T_LPX   PREPARE   ≥ 145 ns+10 UI   sync                         đảo bit cuối
clock lane: LP-11 │ LP-01 │ LP-00   │ HS-0 (CLK-ZERO) │ clock DDR 456 MHz ...... │ HS-0 (CLK-TRAIL) │ LP-11
                                      PREPARE+ZERO ≥ 300 ns  CLK-PRE trước data,   ≥ 60 ns
                                                             CLK-POST sau data
```

- Một lần vào HS gọi là một **burst**: LP-11 → LP-01 → LP-00 → HS-0 dài
  (HS-ZERO) → **byte sync `0xB8`** (chuỗi `00011101` trên dây) → dữ liệu →
  HS-TRAIL (đảo bit cuối và giữ) → LP-11. Bộ thu bật termination ngay sau
  LP-00, bỏ qua dây trong thời gian *settle*, rồi dò byte sync: word của SerDes
  có pha bit không biết trước. Trail và lúc chuyển về LP sinh vài byte rác, nên
  packet phải kết thúc theo **số byte** trong header, không theo cuối burst.
- Clock lane: clock DDR (912 Mbit/s → 456 MHz, 1 UI = 1,096 ns), vào HS bằng
  cùng chuỗi LP, chạy trước data lane (CLK-PRE) và dừng sau nó (CLK-POST, rồi
  HS-0 trong CLK-TRAIL). Clock **liên tục** ở HS mãi; clock **không liên tục**
  về LP-11 giữa các burst. IMX219 trên KV260 ở giữa: lane clock ở HS suốt một
  frame và chỉ về LP-11 trong vertical blanking (số lần vào HS của lane clock
  = số frame); data lane về LP-11 sau **mỗi packet** (mỗi frame H + 4 burst:
  FS, 2 dòng embedded, H dòng, FE).

| Thời gian (D-PHY v1.2) | Giới hạn | Bow32 (mặc định, video 200 MHz) |
|---|---|---|
| T_D-TERM-EN: bật termination sau LP-00 | ≤ 35 ns + 4 UI | ~34 ns: bộ thu LP 8 ns + 2 sync + 2 lọc + 1 FSM (chu kỳ video) |
| T_HS-SETTLE: bỏ qua dây, tính từ LP-00 | 85 ns + 6 UI … 145 ns + 10 UI | `SETTLE` theo tốc độ lane (driver), xem *Tìm sync*: aligner nhìn cả 2 word ISERDES trước `hs_active` (16–24 UI), nên bit cũ nhất nó xét phải nằm sau T_HS-PREPARE max (85 ns + 6 UI) và trước byte 0 của sync sớm nhất (145 ns + 2 UI). 22 ở 912 Mbit/s và 200 MHz: `hs_active` ~133–138 ns từ chân, bit cũ nhất ~111–126 ns, cách hai đầu 91,6/147,2 ns ~20 ns (giá trị reset 14: bit cũ nhất ~73–84 ns, **trước** khi hết HS-PREPARE). PHY Versal (`DLY_VID`): 19 = 95 ns, vì FIFO của XPHY lùi cửa sổ dò thêm, xem mục *Bốn lane* |
| T_CLK-PREPARE + T_CLK-ZERO | ≥ 300 ns | `CLK_SETTLE` 30 = 150 ns, rồi mở cổng byte clock (lane vẫn ở HS-0) |
| T_CLK-MISS: phát hiện mất clock | ≤ 60 ns | `CLK_MISS` theo tốc độ lane (driver): 1 chu kỳ byte clock + 3 chu kỳ video = 5 (25 ns) ở 912 Mbit/s → cổng đóng ~30–45 ns sau cạnh cuối |
| T_HS-TRAIL + T_CLK-POST | ≥ ~180 ns (~20 byte clock) | packet cần ~11 byte clock sau byte cuối |

## Nửa FPGA: `bow_dphy_io_xusp`

Chỉ có primitive của UltraScale+ ở chế độ *component* (không có IP D-PHY) và
không có logic fabric; `bow_mipi_rx` (`bow_dphy_rx`) đăng ký `rx_data` và tap trên byte clock.

```
 clock lane  IBUFDS_DPHY ─HSRX_O─┬─► BUFGCE_DIV /1 ─► hs_clk    ISERDES CLK, CLK_B (đảo)
                                 └─► BUFGCE_DIV /4 ─► byte_clk  ISERDES CLKDIV, IDELAY CLK, bow_mipi_rx
 data lane   IBUFDS_DPHY ─HSRX_O───► IDELAYE3 ─► ISERDESE3 1:8 ─► rx_data (Q[0] = bit đến trước)
 mọi lane    LPRX_O_P/N ─────────────────────────────────────────► lp {P, N} (bất đồng bộ)
```

| Primitive / thuộc tính | Vì sao |
|---|---|
| `IBUFDS_DPHY`, IOSTANDARD `MIPI_DPHY_DCI` (bank 66) | một buffer có cả bộ thu HS vi sai lẫn hai bộ thu LP trên cùng chân. `HSRX_DISABLE = ~hs_en` tắt bộ thu HS **và** termination (`HSRX_O = 0` khi tắt); bộ thu LP luôn bật (trễ ~8 ns). Termination đặt bằng `DIFF_TERM_ADV TERM_100` trong XDC |
| 2 × `BUFGCE_DIV` chung CE, `CE_TYPE SYNC` | /1 cho `CLK`/`CLK_B` của ISERDES, /4 = byte clock. Cổng đóng làm hai bộ chia dừng cùng lúc nên /1 và /4 luôn thẳng pha (gate bằng `CLR` thì không). Bộ thu chỉ đổi CE khi lane clock đứng yên ở HS-0, nên CE là false path |
| `CLOCK_DELAY_GROUP bow_dphy_rx_clk` | cân bằng hai cây clock /1 và /4. Đặt trong XDC qua chân `O` của `u_hs_bufg`/`u_byte_bufg`: synthesis của Vivado bỏ attribute trong RTL và còn đổi tên net (ở đây thành `u_dphy/dphy_byte_clk`). Giữ nguyên tên instance |
| `IDELAYE3` `COUNT`, `VAR_LOAD`, `EN_VTC 0`, không IDELAYCTRL | 511 tap × 2,7–4,7 ps > 1 UI ở mọi góc PVT, phần mềm chọn tap lúc chạy. `CLK` **phải** là net `CLKDIV` của ISERDES (nếu không: DRC REQP-1742 báo lỗi ở `write_bitstream` và cặp này không được xếp chung một bitslice), nên tap chỉ được nạp khi byte clock chạy, tức ở burst sau |
| `ISERDESE3` 1:8 DDR, FIFO tắt, `IS_CLK_B_INVERTED 1` | `Q[0]` là bit đến trước; D-PHY gửi LSB trước nên word đã căn chính là byte. Bộ chia /4 bên trong (đẩy `Q` ra) chỉ thẳng pha với `CLKDIV` nhờ `RST`: thừa hay thiếu một cạnh `CLK` (khi clock dừng) làm lệch tới lần `RST` sau, vì vậy `byte_rst` bật khi cổng đóng và nhả 2 byte clock sau khi clock chạy lại, mỗi lần mở cổng |

Static timing của đường bắt data không đạt được: clock đi qua BUFGCE_DIV và
cây clock toàn cục nên tới ISERDES trễ hơn data (đường trong site, 0,44–0,78 ns)
0,4–1,4 ns tuỳ PVT, gần 1 UI. Vì vậy chân data là false path và điểm lấy mẫu
được hiệu chỉnh bằng phần mềm (mục *Hiệu chỉnh eye*). Bản `kv260` cơ bản không
có `bow_dphy_io_xusp`: `bow32_kv260_top` nối mọi lane LP-11, byte clock 0,
`CsiPhy = 0` (`INFO.PHY = 0`).

## Bốn lane, PHY Versal và IMX274

Trên Huins MFP-VP1902 (Versal Premium xcvp1902), module Leopard
LI-IMX274MIPI-FMC gửi **4 data lane × 1440 Mbit/s** (HS clock 720 MHz DDR,
byte clock 180 MHz, RAW10). Bản dựng camera dùng `Lanes = 4`, `DlyVid = 1`,
`FifoDepth = 512`, clock video 200 MHz (`INFO` = `0x0200C834`).

**Miền byte với 4 lane.** Mỗi byte clock có 32 bit (720 MB/s). Ghép lane đưa
ra word 1, 2 hoặc 4 byte (lane đang dùng, `CTRL.LANES`/`LANES4`), byte
`n·k + l` nằm ở lane `l`. Header 4 byte luôn lấp đầy word: với 4 lane header
chính là word `sop` (lớp packet quyết định P3 ngay chu kỳ word đó ở stage D),
thân packet bắt đầu ở byte 0 của một word. CRC-16 tính 1–4 byte mỗi chu kỳ
(các ứng viên sau 1, 2, 3, 4 byte song song rồi chọn). Word cuối có thể chứa cả
payload lẫn CRC (CRC ở byte 1–2 hoặc 2–3): khi đó `px_eol` đến một chu kỳ sau
các byte cuối. Unpack vẫn tạo tối đa một nhóm 4 pixel mỗi chu kỳ (RAW10 4 lane
= 0,8 nhóm/chu kỳ trong burst). 3 lane không được hỗ trợ (header sẽ không chia
hết cho word).

**Hợp đồng với PHY** (ngoài các cổng của `bow_dphy_io_xusp`):

| Cổng / tham số | Miền | Ý nghĩa |
|---|---|---|
| `rx_valid_i[l]` | byte | 1 = `rx_data_i[l]` là word mới trong chu kỳ này. Aligner của lane chỉ tiến (lịch sử 3 word, dò sync, xuất byte) trên word valid, nên lane thấy đúng chuỗi word như khi có word mỗi chu kỳ. RAW chỉ ghi chu kỳ có word valid ở lane 0. Cạnh byte clock (phát hiện mất clock của lane clock) không phụ thuộc `rx_valid`. PHY có word ở mọi byte clock (`bow_dphy_io_xusp`) nối `'1` |
| `phy_rdy_i` | bất đồng bộ | PHY sẵn sàng (Versal: XPLL khoá, BISC xong; về 0 khi PHY khởi động lại) → `STATUS.PHY_RDY`. PHY không có trạng thái này nối `1'b1` |
| `dly_*`, `DlyVid` = 0 | byte | IDELAYE3 (KV260), như cũ: tap được nạp khi giá trị đồng bộ ổn định 2 chu kỳ và khác tap đã nạp, giá trị đầu sau reset luôn được nạp; chỉ khi byte clock chạy |
| `dly_*`, `DlyVid` = 1 | video | XPHY (Versal, CTRL_CLK = `vid_clk_i`): **không nạp sau reset** (PHY giữ delay của BISC, đọc ở `DLYn[24:16]`); mỗi lần CPU ghi `DLYn` cho đúng một lần nạp lane n với tap đã ghi: `dly_load_o[n]` cao một chu kỳ video, `dly_tap_o[n]` đổi một chu kỳ trước và giữ tới lần nạp sau; các lần nạp của một lane cách nhau ≥ 16 chu kỳ, yêu cầu đến khi lần trước còn chờ được gộp (nạp tap mới nhất). Không cần byte clock |

PHY của Versal là `hw/fpga/common/rtl/bow_dphy_io_versal.sv` (XPHY chế độ
native, lane clock làm strobe, không dùng IP D-PHY của AMD; chi tiết và ràng
buộc trong file đó). Byte clock là `BUFGCE` của `FIFO_WR_CLK` nibble strobe nên
cũng dừng theo lane clock như trên KV260. Mỗi nibble có FIFO RX 8 word: ghi bằng
strobe khi bộ thu HS của lane clock bật, đọc bằng byte clock (`FIFO_RDEN` =
`~FIFO_EMPTY`). Ghi và đọc cùng một strobe nên số word trong FIFO (trễ) không bao
giờ giảm: sau khi PHY khởi động FIFO rỗng (vài chu kỳ không có word valid), rồi
trễ 2–3 word; các word cuối của burst trước ra trước trong burst sau (word cũ,
trước HS-zero và byte sync: chỉ lấp lịch sử của aligner, `arm` chưa lên). Mỗi cạnh
strobe khi cổng byte clock đóng (glitch lúc lane clock vào hoặc ra HS; chưa đo
trên board) thêm một word trễ mãi mãi; word thứ 9 đè word cũ nhất chưa đọc: con
trỏ ghi vượt con trỏ đọc và bộ đọc nhảy qua 8 word (FIFO quay vòng). Cổng
`burst_rst_en_i` của PHY (`BurstRxRst`; bản camera: PA5, 0 sau reset như PHY của
AMD, firmware đặt 1 mỗi lần khởi động bộ thu) = 1 giữ FIFO ở reset khi cổng byte
clock đóng: mỗi burst bắt đầu lại với trễ 2–3 word. `reinit_i` (PA4) khởi động lại PHY: `PHY_RDY` về 0, tap đã nạp bị bỏ,
XPLL, BISC và bù VT chạy lại; `csi2_test` có lệnh `phy`, `phy reinit`, `phy
burstrst 0|1`.

Trễ FIFO cộng vào lệch lane: ghép lane chịu tới 6 byte clock giữa byte đầu của
các lane (lệch 4 byte + 2). Nếu mọi nibble có cùng trễ (như mô hình XPHY của
AMD) thì trôi và quay vòng xảy ra cùng lúc ở mọi lane và chỉ mất word cũ giữa
các burst; nếu trễ khác nhau giữa các nibble, một nibble quay vòng trước, lệch
lane tạm thời tới 7 word và burst bị bỏ (SKEW): khi đó dùng `BurstRxRst` = 1.

Cửa sổ dò sync lúc `arm` lên lùi lại theo trễ FIFO: với `SETTLE` 70 ns và trễ tới
~4 word nó bắt đầu từ ~62 ns sau LP-00, còn trong HS-PREPARE dài nhất mà D-PHY
cho phép (85 ns + 6 UI = 89 ns ở 1440 Mbit/s) — bit ngẫu nhiên của HS-PREPARE có
thể khớp sync giả (mô phỏng hệ thống `csi2_274` với `+DPHY_CORNER=1`: hiệu chỉnh
bị một lỗi giả làm lệch). Vì vậy driver đặt `SETTLE` 95 ns khi `INFO.DLY_VID =
1`: với trễ tới ~4 word cửa sổ bắt đầu sau mọi HS-PREPARE mà vẫn trước byte sync
sớm nhất (HS-PREPARE + HS-ZERO ≥ 145 ns + 10 UI). Trễ trôi tới 8 word
(`BurstRxRst` = 0 có glitch) lùi cửa sổ thêm ~22 ns, lại vào HS-PREPARE dài nhất:
mô phỏng `csi2_274` (corner 1, 20 % lần vào HS có word glitch) mất dòng và hiệu
chỉnh lệch với `SETTLE` 95 ns, còn chạy sạch với `SETTLE` 115 ns (cả corner 1 và
2, ~2000 word glitch, ~360 lần quay vòng mỗi lane), với `BurstRxRst` = 1, hoặc khi
không có glitch. Ước tính của mô phỏng: với trễ 0–8 word, `SETTLE` hợp lệ chỉ
còn một khoảng hẹp (~108–116 ns với độ trễ phát hiện LP-00 của mô hình), còn với
trễ 0–3 word (`BurstRxRst` = 1) khoảng đó rộng (~80–116 ns). Vì vậy trên bản
Versal firmware đặt PA5 = 1 (`BurstRxRst`) mỗi lần khởi động bộ thu và giữ
`SETTLE` 95 ns (`cam_rx_start()` trong `sw/common/src/cam_sensor.c`).

Đo trên bo Huins (2026-11-10, IMX274 4 × 1440 Mbit/s, 720p60, tap đã hiệu chỉnh,
[camera_huins.md](../camera_huins.md) mục 6.3): với `BurstRxRst` = 1 cửa sổ rộng
hơn mô phỏng: mọi `SETTLE` từ 65 tới 170 ns (13…34 chu kỳ) sạch, 95 ns chạy hơn 3,2
triệu burst không lỗi; 40–60 ns có lỗi SKEW / FRAME, 175 ns có lỗi SOT, từ 180 ns
không còn frame. Với `BurstRxRst` = 0 link chỉ sạch tới lần bật lại bộ thu đầu
tiên trong lúc stream; sau đó lane 0 lỗi SOT / ECC / CRC, SKEW và FRAME liên tục ở
mọi `SETTLE` 50–150 ns, tới khi `BurstRxRst` = 1 lại. Cấu hình `BurstRxRst` = 0
với `SETTLE` ~115 ns (tuỳ chọn build `-DCAM_BURST_RST=0 -DSETTLE_VID_NS=115`,
mô phỏng `make -C sim run TEST=csi2_274 FW=brst0`) vì vậy **chỉ dùng cho mô
phỏng**: mô hình FIFO của XPHY chưa giải thích được lỗi đó trên silicon.

**Ngân sách IMX274 (clock video 200 MHz, ISP 1 pixel/clock).** Cảm biến gửi
một dòng CSI-2 mỗi **2 × HMAX** chu kỳ 72 MHz (T_line = 2 · HMAX / 72 MHz). Một
dòng RAW10 đến trong burst với 576 Mpx/s (4 × 1440 Mbit/s / 10), đầu ra lấy
200 Mpx/s, vậy:

- Điều kiện xả: T_line ≥ (W + 3) / 200 MHz ⇒ HMAX ≥ 36·10⁶ · (W + 3) / f_vid
  (1280 px: 231, tối thiểu của cảm biến là 260; 1920 px: 346).
- FIFO cuối burst chứa ≈ W · (1 − 200/576) pixel: 1280 px → 836 px = 209 nhóm,
  1920 px → 1253 px = 314 nhóm (+ vài nhóm trễ con trỏ). FIFO 256 nhóm không đủ
  cho 1080p: bản Huins dùng **512** (vẫn một RAMB36, 512 × 45 bit). Đỉnh này là
  của từng dòng, HMAX chỉ quyết định FIFO có xả hết trước dòng sau hay không:
  3840 px → 2507 px = 627 nhóm, quá 512 ở mọi HMAX (mục *Giới hạn*).
- Điểm làm việc: 1280×720 (mode 5 + cắt) HMAX ≥ 260, 60 fps = HMAX 300 /
  VMAX 4000; 1920×1080 (mode 3 + cắt) HMAX ≥ 400 khi chỉ dùng ISP. Khi bộ mã
  H.264 nhận luồng (392 chu kỳ mỗi macroblock ở 200 MHz, một dải 16 dòng = 32
  HMAX) tải là 0,2756 · W / HMAX: app `video` đặt HMAX ≈ 0,35 · W (~79 %, như
  IMX219 trên KV260) khi số fps còn chỗ, ít nhất 0,276 · W (100 %): 1080p30 HMAX
  672 / VMAX 3571, 720p30 448 / 5357, 1080p60 542 / 2214 (98 %).
- Quan hệ clock: clock video phải nhanh hơn byte clock (cạnh byte clock được
  lấy mẫu ở miền video để phát hiện mất clock: 200 > 180 MHz) và ≤ 16/3 × clock
  CPU (xung sự kiện LP, kiểm khi elaborate qua `CpuClkHz`: 200 ≤ 266 MHz).
  `CLK_MISS` của driver ở 1440 Mbit/s: 1 chu kỳ byte clock (2 chu kỳ video) + 3
  = 5. `CTRL.EXTRA` của driver: 4 × (38 + 8) + 8 = 192 byte (trail của 4 lane ở
  1440 Mbit/s, + 8 word FIFO XPHY mỗi lane), thay cho giá trị reset 64 chỉ hợp
  1–2 lane.
- Packet DT ≠ `CTRL.DT` (dòng embedded 0x12, dòng optical black 0x37 của
  IMX274) bị bỏ mà không tính là lỗi (`CNT_DROP`); ECC và CRC của chúng vẫn
  được kiểm (CRC sai vẫn vào `CNT_CRC`), và packet kết thúc theo WC nên không
  ảnh hưởng packet sau.

## Miền clock, reset và CDC

| Miền | Clock | Nội dung |
|------|-------|----------|
| CPU | `clk_i` (50 MHz) | `bow_csi2rx_regs`: thanh ghi, bộ đếm, IRQ, đo thời gian, đọc RAM LOG/RAW |
| Video | `vid_clk_i` (200 MHz trên KV260 và Huins) | 1 + `Lanes` máy trạng thái LP (`hs_en`, `byte_ce`), FIFO phía đọc, đầu ra `m_axis`; nạp tap khi `DlyVid` = 1 |
| Byte | `byte_clk_i` (114 MHz ở 912 Mbit/s, 180 MHz ở 1440 Mbit/s) | aligner, ghép lane, packet, unpack, FIFO phía ghi, nạp tap khi `DlyVid` = 0, LOG/RAW, đồng hồ đo byte clock |

Byte clock chỉ chạy khi cổng mở (`byte_ce = 1`) **và** lane clock đang chạy:
logic miền byte phải đúng dù clock dừng bất cứ lúc nào. Reset (assert bất đồng
bộ, nhả đồng bộ, `bow_rst_sync`):

| Reset | Clock | Nguồn | Reset cái gì |
|-------|-------|-------|--------------|
| `vrst_n` | video | `vid_rst_ni & rst_ni` | máy trạng thái LP, đồng bộ cấu hình/trạng thái |
| `brst_n` | byte | `vid_rst_ni & rst_ni` | toggle của `bow_cdc_pulse`, bộ đếm req/ack, LOG/RAW, đồng hồ đo, nạp tap (`DlyVid` = 0), thanh ghi `rx_data`/`rx_valid` |
| `drst_n` | byte | như trên `& rx_on` | aligner, ghép lane, packet (cả trạng thái frame), unpack, FIFO phía ghi |
| `vdrst_n` | video | như trên `& rx_on` | FIFO phía đọc, `bow_csi2rx_out` |
| `byte_rst_o` | byte | cổng đóng (`byte_ce = 0`) | `RST` của ISERDESE3, nhả 2 byte clock sau khi clock chạy lại |

`rx_on` = `CTRL.PHY_EN & CTRL.RX_EN` (một flop miền CPU). Tắt RX_EN hoặc PHY_EN
reset datapath ngay, kể cả khi byte clock đang dừng; phía byte được nhả ở những
byte clock đầu của burst sau. Packet, dòng, nhóm pixel dở dang, trạng thái frame
và FIFO đều bị xoá. Đồng bộ giữa các miền:

| Tín hiệu | Cách qua | Ghi chú |
|----------|----------|---------|
| cấu hình (CTRL, PHY_CFG) | `bow_sync` từng bit | gần tĩnh, không handshake: đổi LANES/VC/VC_ANY/DT khi RX_EN = 0, PHY_CFG/CLK_FORCE khi PHY_EN = 0 |
| sự kiện (FS, FE, dòng, lỗi, vào HS…) | một `bow_cdc_pulse` mỗi loại | miền byte: ≤ 1 lần mỗi packet/burst (burst cách nhau ≥ ~370 ns; SKIP ≤ 1 lần mỗi frame); miền video: giới hạn 1 xung / 16 chu kỳ, nên cần `vid_clk_i` ≤ 16/3 × `clk_i` (`bow_cdc_pulse` cần 3 chu kỳ đích mỗi xung; elaborate kiểm khi `CpuClkHz` ≠ 0, `make lint` có một case âm 50/300 MHz) |
| dữ liệu kèm sự kiện (FRAME_INFO, FRAME_SUM, LINE_INFO) | trực tiếp | nguồn giữ nguyên tới sự kiện cùng loại sau; CPU chép khi nhận xung |
| lệnh LOG/RAW | bộ đếm gray 4 bit: req (CPU), ack (byte) | là mức nên chạy được khi byte clock dừng (phục vụ khi có burst); tối đa 15 lệnh treo |
| tap IDELAY (`DlyVid` = 0) | `bow_sync` từng bit, nạp khi ổn định 2 chu kỳ và khác tap đã nạp | chỉ khi byte clock chạy; CNTVALUEOUT về CPU qua `bow_sync` |
| tap XPHY (`DlyVid` = 1) | mỗi lần ghi `DLYn` tăng bộ đếm gray 2 bit của lane; miền video thấy bộ đếm đổi qua `bow_sync`, lấy tap (cùng chu kỳ CPU, `bow_sync` từng bit) 2 chu kỳ sau | không cần byte clock; CNTVALUEOUT (miền video) về CPU qua `bow_sync` |
| `phy_rdy_i` | `bow_sync` | mức, cho `STATUS.PHY_RDY` |
| đồng hồ đo byte clock | bộ đếm gray 20 bit | cho `BYTECLK` |
| pixel | `bow_fifo_async` (con trỏ gray) | hai phía reset cùng một nguồn |
| RAM LOG/RAW | `bow_ram_sdp` (ghi ở byte, đọc ở CPU) | CPU đọc sau DONE |

Bộ đồng bộ của phần D-PHY (cấu hình PHY_CFG / CLK_FORCE / enable lane sang miền video,
trạng thái LP / HS / CE và `phy_rdy_i` về CPU, tap và CNTVALUEOUT, `arm`, cạnh byte clock,
đồng hồ đo) nằm trong `bow_dphy_rx`; `bow_csi2rx` giữ phần của lớp CSI-2 (sự kiện LP về bộ
đếm, đánh dấu burst mất ở mức LP, cấu hình lớp packet, LOG/RAW, FIFO pixel, sự kiện miền
byte). Giữa hai khối (PPI và dải phụ) không có lần qua miền mới: cấu hình miền CPU vẫn qua đúng
các bộ đồng bộ cũ trong `bow_dphy_rx`, mọi tín hiệu khác được dùng ở miền của nó (miền lp của
D-PHY là `vid_clk_i`). Các bus gray có ràng buộc `set_bus_skew` (mục *Ràng buộc*). Hoạt động của
lane clock được thấy qua một flop miền byte đảo mỗi chu kỳ, lấy mẫu ở `vid_clk_i`: cần byte
clock ≤ ~1,5 × `vid_clk_i` (ở 200 MHz: lane ≤ ~2,4 Gbit/s, xa hơn khả năng của I/O này), nếu
không phát hiện mất clock (`CLK_MISS`) có thể đóng cổng giữa burst.

## Pipeline

### Phân cấp và PPI (`bow_mipi_rx`, `bow_dphy_rx`, `bow_csi2rx`)

Bước 1 và 2 của kế hoạch chuyển sang bộ thu MIPI của ASIC ([mipi_rx_arch.md](mipi_rx_arch.md)
mục 10) chia bộ thu thành hai khối, không đổi chức năng, cổng hay bản đồ thanh ghi:

```
 bow32_top: bow_mipi_rx u_csi2rx (cổng, tham số: như bow_csi2rx trước bước 2)
   ├─ bow_dphy_rx u_dphy_rx   phần số của D-PHY (hw/ip/dphy_rx/rtl/)
   │     ═══ PPI (bow_ppi_pkg) ═══►   + dải phụ tạm thời (band_*) ◄══►
   └─ bow_csi2rx  u_csi2rx    controller CSI-2: ghép lane .. đầu ra, LOG/RAW, thanh ghi (u_regs)
```

- **`bow_dphy_rx`** (`hw/ip/dphy_rx/rtl/bow_dphy_rx.sv`) gom các chức năng D-PHY số, chuyển
  nguyên trạng từ `bow_csi2rx` (tên instance và thanh ghi giữ nguyên, XDC chọn cell theo tên):
  máy LP (`u_lp_clk`, `g_lp[l].u_lp`) và đồng bộ cấu hình của chúng (`u_sync_vcfg`), phát hiện
  cạnh byte clock (`clk_tog`), reset ISERDES (`u_iserdes_rst`, `byte_rst_o`), flop word
  `rx_data`/`rx_valid`, đồng bộ `arm`, aligner (`g_align[l].u_align`), nạp tap (`g_dly_byte` /
  `g_dly_vid`) và đọc lại tap (`u_sync_tap_out`), đồng hồ đo byte clock (`meter_gray_q`,
  `u_sync_meter`), trạng thái PHY về CPU (`u_sync_vst`, `PHY_RDY`). Cổng PHY của nó là cổng PHY
  của `bow_mipi_rx`; clock miền lp `lp_clk_i` là `vid_clk_i`.
- **PPI v1** (`bow_ppi_pkg`, [mipi_rx_arch.md](mipi_rx_arch.md) mục 5): `rx_byte_clk_hs`
  (= `byte_clk_i`); mỗi data lane `ppi_hs_t` ở miền byte (`RxActiveHS` = `arm`, `RxValidHS`,
  `RxDataHS`, `RxSyncHS`, `ErrSotSyncHS`, `RxSkewCalHS` của aligner; `ErrSotHS` = 0) và
  `ppi_lp_t` ở miền lp (`Stopstate`, `ErrControl` = xung lỗi LP của FSM ở bit 0); lane clock
  `ppi_lp_clk_t` (`StopstateClk`, `RxClkActiveHS`, `ErrControlClk`); tín hiệu ULPS / escape đứng
  ở giá trị nghỉ. Controller lái `Enable[l]` / `EnableClk` từ flop enable lane của
  `bow_csi2rx_regs`. Lỗi lp là xung một chu kỳ, nên controller phải chạy cùng clock với
  `lp_clk` của D-PHY: tham số `PpiLpClkHz` của `bow_csi2rx` phải bằng `PhyClkHz` (lỗi elaborate
  nếu khác; `bow_mipi_rx` đặt bằng nhau).
- **Dải phụ tạm thời** (cổng `band_*`, mỗi tín hiệu ghi bước bỏ nó; bảng ở
  [mipi_rx_arch.md](mipi_rx_arch.md) mục 10): phần PHY của thanh ghi và reset dùng chung, tới khi
  D-PHY có thanh ghi và reset riêng (bước 4) và giao diện AFE (bước 5). Controller → D-PHY: reset
  đã đồng bộ (`vrst_n`, `brst_n`, `drst_n`: aligner vẫn bị reset khi RX tắt) và nguồn của chúng,
  `CTRL.CLK_FORCE`, `PHY_CFG`, tap và bộ đếm ghi của `DLYn`. D-PHY → controller: `STATUS`
  LP / HS / CE / `PHY_RDY`, đồng hồ đo, `DLYn[24:16]` (miền CPU), xung vào HS (bộ đếm
  `CNT_BURST*`, `CNT_MISC[15:0]`), enable lane và `CLK_FORCE` đã đồng bộ ở miền lp, flop word cho
  RAW (miền byte; RAW vẫn ở `bow_csi2_capture`).
- **`bow_csi2rx`** (controller) giữ lớp CSI-2: ghép lane, packet, unpack, FIFO, đầu ra, LOG/RAW,
  sự kiện về bộ đếm, và luật đánh dấu burst mất ở mức LP: `ErrControl` của data lane đang bật
  hoặc `ErrControlClk` khi không có `CLK_FORCE` (enable và `CLK_FORCE` như D-PHY thấy, qua dải
  phụ). `ERR_STATUS.LP` và `CNT_MISC[23:16]` đếm `ErrControl*` không che, như trước.

- **`bow_csi2rx_ppi_flat`** (bước 3, `hw/ip/csi2rx/rtl/bow_csi2rx_ppi_flat.sv`, không nằm trong
  `csi2rx.f` và không có trong bản build nào): controller với cổng PPI phẳng theo tên công khai,
  cho một D-PHY chuẩn thay D-PHY của Bow32. Nó làm thay PHY ba việc controller v1 cần (miền byte
  trễ 1 chu kỳ trừ cạnh lên của `RxActiveHS`, `RxActiveHS` giữ thêm 2 chu kỳ khi xuống, cạnh lên của
  `RxSkewCalHS` thành xung), đổi xung `ErrControl` ở clock lp của PHY thành xung `vid_clk_i`
  (`bow_cdc_pulse`), lái dải phụ khi có thứ tương ứng (enable lane qua 2 flop như D-PHY;
  `STATUS.CE` = `RxClkActiveHS`, `STATUS.PHY_RDY` = `phy_ready_i`) và nối hằng phần còn lại:
  không `ErrControlClk`; `CNT_BURST*`, `CNT_MISC[15:0]`, `BYTECLK`, `DLYn[24:16]` đọc 0; RAW không
  bao giờ xong; `CLK_FORCE`, `PHY_CFG`, `DLYn` không có tác dụng ([mipi_rx_arch.md](mipi_rx_arch.md)
  mục 5.5).

Tương đương với RTL trước khi tách được chứng minh hình thức (mục *Kiểm chứng*). `make lint` lint
riêng `bow_mipi_rx`, controller `bow_csi2rx` với cổng PPI (1, 2, 4 lane, không PHY; từ chối
`PpiLpClkHz` khác `PhyClkHz`), wrapper `bow_csi2rx_ppi_flat` (1, 2, 4 lane, clock video 50 MHz)
và `bow_dphy_rx` (1, 2, 4 lane, `DlyVid` 0 / 1). Trong netlist, cell
D-PHY ở `u_soc/u_csi2rx/u_dphy_rx/...` (như bước 1), cell của controller ở
`u_soc/u_csi2rx/u_csi2rx/...`: selector theo đuôi tên của XDC (`*/u_csi2rx/u_fifo/...`) vẫn khớp.

### Máy trạng thái LP (`bow_dphy_lp`, video, 1 + `Lanes` bản)

```
 Off --en--> WaitStop --LP-11--> Stop --LP-01--> HsRqst --LP-00--> Settle --SETTLE--> Hs
                ^                 |  ^             |  |              |                 |
                +---- LP-10/00 ---+  +---- LP-11 --+  |              +--- LP-11: Stop -+
                +------------------------- LP-10 -----+
```

- Hai bộ thu LP qua `bow_sync`, rồi lọc glitch: mức mới được nhận khi đã thấy
  `LP_FILTER` chu kỳ liên tiếp (0 tính là 1). LP-00 ở chân → `hs_en` sau
  2 + `LP_FILTER` + 1 chu kỳ video.
- `hs_en` (bộ thu HS + termination) bật từ LP-00 sau LP-01 tới LP-11; LP-01,
  LP-10 trong HS bị bỏ qua (khi ở HS, bộ thu LP thấy LP-00).
- Data lane: trạng thái `Hs` cho aligner dò sync. Ở HS quá 2^20 chu kỳ
  (5,2 ms ở 200 MHz) → lỗi LP (watchdog), tắt bộ thu, chờ LP-11.
- Lane clock: sau `CLK_SETTLE` chu kỳ mở cổng (`byte_ce = 1`) trong HS-0 của
  CLK-ZERO, khi chưa có cạnh nào. Đã thấy cạnh byte clock mà `CLK_MISS` chu kỳ
  liên tiếp không có cạnh → đóng cổng trong HS-0 của CLK-TRAIL (trạng thái
  `Trail`, bộ thu còn bật tới LP-11). LP-11 khi cổng còn mở: đóng cổng trước,
  tắt bộ thu 2 chu kỳ sau. Cạnh byte clock được thấy qua một flop miền byte đảo
  mỗi chu kỳ, `bow_sync` sang miền video. Lane clock không có watchdog.
- `PHY_EN = 0`: cổng đóng ngay, bộ thu tắt 8 chu kỳ sau (cũng khi HS clock còn
  chạy, vì vậy `bow_csi2rx_stop` chờ FSM tự đóng cổng trước). `CLK_FORCE = 1`
  (với PHY_EN = 1): bộ thu và cổng lane clock luôn bật, cho cảm biến clock liên
  tục.
- Lỗi LP (`ERR_STATUS.LP`): ở Stop thấy LP-10 (escape) hoặc LP-00 không qua
  LP-01, ở HsRqst thấy LP-10, watchdog.

### Tìm sync, căn byte (`bow_dphy_align`, byte, mỗi data lane)

Với `w24 = {rx, q1, q2}` (3 word cuối, bit j đến sau bit j−1), offset `o` khớp
khi `w24[o +: 8] == 0x00` (HS-zero) và `w24[o+8 +: 8] == 0xB8`; chỉ một offset
khớp được. Việc dò bắt đầu ở cạnh lên của `arm` (`hs_active` của lane, đã đồng
bộ); từ word sau, mỗi chu kỳ ra một byte `{rx, q1}[o +: 8]`, `sot` đi cùng byte
đầu sau sync, cho tới khi `arm` xuống. `arm` xuống mà chưa khớp → lỗi SOT.
Không chấp nhận sync sai 1 bit. `arm` đã cao lúc nhả reset (bật RX giữa burst)
không bắt đầu dò: phải chờ burst sau. Chu kỳ `rx_valid` = 0 (PHY có FIFO) không
dịch lịch sử, không khớp và không ra byte: aligner chỉ nhìn chuỗi word valid.

Lần dò đầu tiên đã nhìn cả `q1`, `q2`: bit cũ nhất được xét đến 16–24 UI trước
`hs_active` (`arm` qua 2 flop đồng bộ, `rx` qua 1 flop). Đó là mốc thật sự của
T_HS-SETTLE, và driver đặt `SETTLE` theo nó (mục *Driver*).

Burst **deskew** (skew calibration của D-PHY v1.2, bắt buộc trên 1,5 Gbit/s):
HS-zero rồi sync toàn bit 1 (`FFFFh`) thay cho `0xB8`, sau đó mẫu `0101…`.
Aligner nhận 8 bit 0 rồi **16** bit 1: 8 bit 0 rồi 8 bit 1 (`w24[o+8 +: 8] ==
0xFF`) là ứng viên, word sau phải có thêm 8 bit 1 ở cùng offset (`w24[o +: 16]
== 0xFFFF`). Ứng viên **chỉ được lấy ở chỗ HS-zero kết thúc**: word cũ nhất
(`q2`) là word 0 và từ word 0 đầu tiên của lần dò chưa thấy bit 1 nào; tối đa 2
word nhiễu HS-PREPARE ở đầu lần dò được bỏ qua, word thứ 3 vẫn khác 0 thì lần dò
không bắt đầu trong HS-zero và không còn nhận deskew. Khi đó aligner dừng dò,
không khoá và không báo lỗi SOT; lane 0 đếm vào `CNT_EXT[31:16]`. Nhờ vậy burst
có byte sync hỏng **vẫn là lỗi SOT** dù dữ liệu sau đó chứa `0x00 0xFF` (pixel
đen cạnh pixel trắng, byte 0x00 rồi trail toàn bit 1 của short packet trên lane
0), hay sync hỏng thành `0xFC`/`0xFE`/`0xFF` mà bit thấp của DI `0x2B` nối thêm
thành 8–10 bit 1; chỉ khi sync hỏng và dữ liệu sau nó có 16 bit 1 liền nhau thì
mới thành deskew. Bản đầu của giai đoạn 0 nhận 8 bit 0 + 8 bit 1 ở bất kỳ đâu
(sau review đầu: ở cuối HS-zero nhưng chỉ 8 bit 1) và biến các burst đó thành
"deskew" im lặng. Lần dò bắt đầu sau HS-zero (`SETTLE` quá muộn: sync bị lỡ đằng
nào cũng vậy) có thể lấy header toàn 0 (FS/FE số frame 0) làm HS-zero. Hai mẫu
không thể khớp cách nhau dưới 8 bit. Deskew chỉ trên một lane (lane kia khoá bình
thường) là lỗi SKEW, lane kia không khoá là SOT trên lane đó; với 4 lane: deskew
trên một số lane mà lane khác khoá là SKEW.

Với `rx_valid` (PHY Versal) mọi trạng thái của luật này tính theo **word valid**,
không theo chu kỳ: lịch sử `q1`/`q2`, ứng viên deskew chờ word valid kế tiếp (một
chu kỳ trống không xác nhận nó), tuổi lần dò và theo dõi HS-zero; "word đầu của lần
dò" là word valid đầu tiên từ cạnh lên của `arm` (cạnh lên có thể rơi vào chu kỳ
trống). Word cũ của FIFO XPHY và word trễ của nó lùi cửa sổ dò về trước như
HS-PREPARE: `SETTLE` 95 ns của driver giữ cửa sổ trong HS-zero (mục *Bốn lane*).
Unit test `tb_dphy_align.sv` chạy mọi case thêm 3 lượt có chu kỳ trống với word rác
`00`/`FF`/`B8` (cả lúc `arm` lên) và đòi cùng kết quả.

### Ghép lane (`bow_csi2_lane_merge`)

Với n lane đang dùng (1, 2, 4: các lane thấp nhất), byte n·k + l nằm ở lane l
(2 lane: byte 2k ở lane 0, 2k+1 ở lane 1). Mỗi lane có FIFO 8 byte ghi từ `sot`;
đầu ra chạy khi mọi lane đều có byte, rồi lấy mỗi lane một byte mỗi chu kỳ:
tới 6 byte clock giữa byte đầu của các lane được hấp thụ (ví dụ lệch lane 4 byte
cộng trễ FIFO khác nhau của PHY); lane đến có khoảng trống thì đầu ra cũng có
khoảng trống. Mỗi burst đúng một xung `eob` (cả burst không có dữ liệu). Lỗi
SKEW (ở cuối burst): chỉ một số lane khoá được, hoặc FIFO của lane sớm nhất tràn
trước khi xuất (từ 7 byte clock trở lên: lane đó đẩy byte thứ 9 đúng chu kỳ mà
byte đầu của lane muộn nhất cho phép lần lấy đầu). Burst đó không ra gì cả:
không pixel, không packet, không TRUNC; chu kỳ tràn cũng chặn lần lấy của chính
nó (test directed `skew`: 0, 4, 5, 6 byte clock nhận đúng; 7, 8, 12 → SKEW).
Clock không liên tục có thể dừng trước khi cuối burst tới miền byte; `eob` khi
đó đến lúc clock chạy lại cho burst sau, trước byte đầu của nó (≥ ~20 byte clock).

### Lớp packet (`bow_csi2_packet`)

- 4 byte đầu là header `{DI, WC LSB, WC MSB, ECC}`, DI = `{VC[1:0], DT[5:0]}`.
  ECC (CSI-2 v1.x, 24 bit data + 6 bit parity) được giải trong pipeline 3 tầng
  cạnh luồng byte trễ 3 chu kỳ: syndrome = parity(D) ⊕ ECC[5:0] (ECC[7:6] bỏ
  qua). Syndrome 0 → đúng; bằng cột của một bit data → lật bit đó (đã sửa); chỉ
  một bit 1 → lỗi ở bit parity (đã sửa); còn lại → không sửa được, bỏ phần còn
  lại của burst.
- Short packet (DT 0x00–0x0F) của VC được chọn (`CTRL.VC`, hoặc mọi VC với
  `VC_ANY`): FS bắt đầu frame (số frame = WC; FS trong frame → lỗi FRAME), FE
  hoàn tất frame và chốt `FRAME_INFO`, `FRAME_SUM` (FE không có FS → lỗi FRAME,
  trừ FE trước FS đầu tiên sau khi bật RX). Short packet khác chỉ được đếm và log.
- Long packet (DT ≥ 0x10): WC byte payload rồi CRC (byte thấp trước).
  **Accepted** = VC khớp, DT = `CTRL.DT` và là RAW8/RAW10: payload sang unpack.
  Packet khác vẫn được kiểm CRC rồi bỏ (`CNT_DROP`); 2 dòng embedded (DT 0x12)
  mỗi frame của IMX219 thuộc loại này.
- Packet kết thúc khi đủ header + WC + 2 byte, **không bao giờ** theo `eob`: so
  CRC, sự kiện, LOG; byte sau CRC bị bỏ tới burst sau. `eob` khi packet chưa đủ
  byte → TRUNC (unpack kết thúc dòng). Mỗi burst một packet.
- **EXTRA**: CSI-2 v1.x (mục *Packet Spacing*) bắt buộc EoT → LP-11 → SoT giữa
  hai packet; nhiều packet trong một HS burst chỉ đến từ máy phát sai chuẩn, hoặc
  từ LRTE/EPD của CSI-2 v2.0+ (tuỳ chọn, hai đầu cùng bật; không hỗ trợ ở đây).
  Byte theo sau một packet hoàn chỉnh (short hoặc long) trong cùng burst được
  đếm tới `eob`; quá `CTRL.EXTRA` byte (0 = tắt, reset 64) → `ERR_STATUS.EXTRA`
  và `CNT_EXT[15:0]`, một lần mỗi burst, và packet theo sau bị bỏ (trong frame:
  dòng sau có `tuser[1]`, trước dòng đầu: cả frame bị bỏ, xem *Unpack*). Cuối
  burst (HS-TRAIL, phát hiện LP-11) cũng sinh byte rác, nên ngưỡng phải cao hơn
  (driver: `(105 ns + 12 UI + 60 ns) / 8 UI + 6` byte mỗi lane, PHY Versal + 8
  cho FIFO XPHY, × số lane đang dùng + 8: 62 ở 2 × 912 Mbit/s, 192 ở 4 × 1440
  Mbit/s trên Versal). Byte được đếm theo word của ghép lane (1, 2 hay 4 byte),
  cả các byte sau CRC trong word cuối của long packet; với 4 lane header là word
  `sop` nên P3 của short packet đến cùng word đó và đếm bắt đầu từ word sau. Trên KV260 + IMX219 đo được 17–20 byte sau packet (2
  lane, T_HS-TRAIL của cảm biến): `EXTRA` ≤ 16 báo mọi burst, 18 báo ~56 %, ≥ 20
  không báo; deskew 0. Vì vậy chỉ packet theo sau đủ lớn mới bị báo: một long
  packet có payload ≥ ~57 byte (6 + WC + trail > 62) luôn bị; short packet
  (4 byte) và long packet nhỏ (Null/blanking, embedded ngắn, dòng ROI hẹp) có thể
  bị bỏ không có cờ, bộ đếm hay LOG (DV: trail 16 byte ở T_HS-TRAIL 70 ns → báo
  từ WC ≥ 41). Hạ `CTRL.EXTRA` về gần trail đo trên board thu hẹp vùng mù.
- Dòng lỗi: `px_err` đi cùng `eol` khi dòng có lỗi CRC, lỗi FORMAT hoặc bị cắt
  (TRUNC); unpack đưa nó ra `tuser[1]`. Khi word cuối có cả payload lẫn CRC (4
  byte mỗi word) `eol` đến một chu kỳ sau word đó, `px_err` (CRC tính trên cả
  word cuối) đi cùng nó.
- CRC-16: x^16 + x^12 + x^5 + 1 phản xạ (0x8408), khởi tạo 0xFFFF, không XOR
  cuối (CRC-16/MCRF4XX), 1–4 byte mỗi chu kỳ; chạy qua payload rồi qua 2 byte
  CRC nhận được, kết quả 0 là đúng. Pixel đi trước khi biết CRC: lỗi CRC không
  bỏ dữ liệu.
- FORMAT: dòng accepted có WC = 0, hoặc RAW10 có WC % 5 ≠ 0.

### Unpack (`bow_csi2_unpack`)

```
RAW10: 5 byte -> 4 pixel   P_i = {B_i, B4[2i+1:2i]}        RAW8: P_i = {B_i, 2'b00}
nhóm FIFO, 45 bit: {err, sof, eol, số pixel - 1 [1:0], px3 .. px0}, px0 ở [9:0]
```

Nhận tới 4 byte mỗi chu kỳ nhưng vẫn tạo tối đa một nhóm mỗi chu kỳ (bộ đệm
giữ < 5 byte chờ nhóm sau). Dòng RAW8 có WC % 4 ≠ 0 kết thúc bằng một nhóm
thiếu; byte thừa của RAW10 bị bỏ. Nhóm cuối được giữ lại một bước để `eol` nằm đúng nhóm cuối (cả khi dòng bị
cắt). `FRAME_SUM` = tổng giá trị 10 bit của mọi pixel đã vào FIFO từ FS tới FE.

**Khung frame.** `sof` chỉ nằm ở nhóm đầu của dòng đầu (cờ chờ từ FS tới khi
nhóm đầu được tạo) và **không bao giờ chuyển** sang nhóm khác. Nếu nhóm đó không
ghi được (FIFO), dòng accepted đầu tiên không có nhóm pixel nào (RAW10 WC < 5
hay WC 0), hoặc một burst của frame bị mất trước khi có nhóm đầu (`drop_i`, bên
dưới), phần còn lại của frame bị **bỏ** tới FS/FE sau: không
nhóm nào vào FIFO, `ERR_STATUS.SKIP` (`CNT_MISC[31:24]`) một lần, `FRAME_SUM`
= 0, nhóm bị bỏ vì skip không bật OVF. Khối sau (ISP, DMA, NPU) vì vậy nhận mỗi
frame hoặc từ pixel (0, 0), hoặc không nhận gì; trước đây `tuser[0]` có thể rơi
vào dòng k > 0 và ISP (chỉ dùng `tuser[0]`) lấy dòng k làm y = 0. FS và FE xoá
trạng thái frame (`sof` chờ, dòng mất, skip); dòng mất chỉ được ghi nhận trong
frame (từ FS tới FE): dòng nằm ngoài frame không bao giờ mang `sof` hay `err` của
dòng mất, kể cả sau một dòng không có nhóm pixel ngoài frame.

**Burst mất trước unpack** (`drop_i` = trong frame và một trong: header không
sửa được, lỗi sync, SKEW, EXTRA, packet bị cắt mà không phải dòng accepted (có
thể là một dòng có header hỏng), hoặc đầu packet đầu tiên sau một lần vào HS bị
từ chối ở mức LP: lỗi LP của data lane đang dùng, hay của lane clock khi không
`CLK_FORCE`, burst đó có thể đã mất): dòng sau của frame vào được FIFO có
`tuser[1]`, như sau một dòng Lost; trước nhóm đầu của frame thì frame bị bỏ
(skip). Quy tắc thận trọng: burst mất có thể không phải dòng pixel (embedded
data, VC khác), dòng sau vẫn bị đánh dấu. Lỗi LP (miền video) qua một bắt tay
toggle sang miền byte và chờ ở đó tới đầu packet sau (`lpl_pend_q`).

Tràn FIFO **không làm hỏng khung dòng** của đầu ra: nhóm không phải nhóm cuối
dòng chỉ được ghi khi FIFO còn ≥ 2 chỗ (`afull` của `bow_fifo_async` = 0), nên
nhóm cuối của một dòng đã bắt đầu luôn còn chỗ:

| Chế độ của dòng | Khi nào | Đầu ra |
|---|---|---|
| Ok | đủ chỗ | dòng đủ pixel |
| Cut | một nhóm thấy FIFO còn 1 chỗ | các nhóm đã ghi + nhóm cuối, `tlast`, `tuser[1]` = 1 (dòng ngắn) |
| Lost | FIFO đầy | không có gì (cả nhóm cuối); dòng kế tiếp của frame vào được FIFO có `tuser[1]` = 1 |

Mọi nhóm bị FIFO bỏ bật cờ OVF của packet đó (`CNT_DROP[31:16]`, LOG). Nhóm
`sof` bị bỏ → cả frame bị bỏ (khung frame ở trên). `err` của nhóm cuối = lỗi
CRC/FORMAT/TRUNC của dòng, hoặc dòng bị Cut, hoặc trước đó trong frame có dòng
Lost, dòng accepted không có nhóm pixel nào (ví dụ RAW10 WC < 5) hay burst mất
trước unpack. `tuser[1]` **không** báo được dòng mất sau dòng ra cuối cùng của
frame (đuôi frame mất, frame mất hết): những mất mát đó, và mọi lỗi khác của
frame, nằm trong `FRAME_ERR` chốt ở FE. `FRAME_INFO` vẫn đếm packet (dòng) đã
nhận, không phải dòng đã ra: khối sau cần đếm dòng giữa hai `tuser[0]`, phần
mềm đọc `FRAME_ERR` ở mỗi FE.

### FIFO và đầu ra (`bow_fifo_async`, `bow_csi2rx_out`)

FIFO 2 clock `FifoDepth` nhóm × 45 bit (256 trên KV260, 512 trên Huins; 1
RAMB36), con trỏ gray qua 2 flop `ASYNC_REG`,
phía đọc kiểu first-word-fall-through. Đầu ra giữ hai nhóm (`cur`, `next`), lấy
nhóm mới khi `next` trống (thêm pixel đang nằm trong flop `m_axis`: nhóm 1 pixel
đi hết vào đó, nên khi `tready` thấp đầu ra giữ 3 nhóm thay cho 2, điểm Cut/Lost
lùi một nhóm); `tready` chỉ đẩy pixel đi: 1 pixel/clock liên tục,
`tuser[0]` ở pixel 0 của nhóm `sof`, `tlast` ở pixel cuối của nhóm `eol`,
`tuser[1]` = `err` của nhóm `eol` (chỉ cùng `tlast`), mọi `m_axis_*` ra từ flop.
ISP của Bow32 hiện chỉ dùng `tuser[0]` (frame sai kích thước bị ISP huỷ ở `tuser[0]`
sau, dòng lỗi CRC thì đi qua).

Thông lượng: đầu ra 200 Mpx/s ở 200 MHz. RAW10 ở 2 × 912 Mbit/s là 182,4 Mpx/s:
vừa. RAW8 là 228 Mpx/s trong burst: FIFO (1024 pixel) hấp thụ phần dư của một
dòng (12 %, dòng 1920 pixel → ~240 pixel) khi các dòng cách nhau một line time
như của IMX219; các dòng RAW8 liền nhau liên tục sẽ làm tràn FIFO (OVF).

## Lỗi và bộ đếm

| `ERR_STATUS` | Bộ đếm | Ý nghĩa | Thường do |
|----|----|----|----|
| [0] SOT | `CNT_SOT` lane 0 / 1, `CNT_SOT23` lane 2 / 3 | lane vào HS mà không thấy sync (cũng khi byte sync hỏng mà dữ liệu sau đó chứa mẫu deskew) | tap IDELAY ngoài eye |
| [1] ECC_CORR | `CNT_ECC[15:0]` | header sai 1 bit, đã sửa | eye hẹp |
| [2] ECC_ERR | `CNT_ECC[31:16]` | header không sửa được, burst bị bỏ | tap sai |
| [3] CRC | `CNT_CRC[15:0]` | CRC sai (pixel vẫn được đưa ra, `tuser[1]` ở `tlast`) | tap sai, nhiễu |
| [4] TRUNC | `CNT_CRC[31:16]` | burst hết trước khi đủ packet (`tuser[1]` khi bị cắt trong payload) | lỗi bit giữa burst, tắt RX giữa packet |
| [5] OVF | `CNT_DROP[31:16]` | FIFO pixel đầy, nhóm/dòng bị bỏ (`tuser[1]` ở dòng Cut và ở dòng sau của frame nếu có) | RAW8 liền nhau, `tready` thấp lâu |
| [6] SKEW | `CNT_MISC[31:24]` | các lane không cùng khoá, burst bị bỏ | sync hỏng trên một lane |
| [7] FORMAT | `CNT_MISC[31:24]` | WC không hợp RAW10/RAW8 | cảm biến sai format |
| [8] FRAME | `CNT_MISC[31:24]` | FS trong frame, FE không có FS | mất FS/FE khi đổi tap, đổi VC |
| [9] LP | `CNT_MISC[23:16]` | chuỗi LP sai, watchdog HS (một burst có thể đã mất: packet sau trong frame tính như burst mất, xem *Unpack*) | escape mode, nhiễu, dây hở |
| [10] EXTRA | `CNT_EXT[15:0]` | quá `CTRL.EXTRA` byte sau một packet trong burst | máy phát không về LP-11 giữa các packet (sai CSI-2 v1.x, hoặc LRTE của v2.0+), packet sau bị bỏ; hoặc `CTRL.EXTRA` thấp hơn trail của cảm biến |
| [11] SKIP | `CNT_MISC[31:24]` | phần còn lại của một frame bị bỏ: dòng đầu không ra được (nhóm `sof` gặp FIFO đầy, hoặc burst mất trước dòng đầu) | `tready` thấp lâu qua đầu frame, lỗi link ở đầu frame |

`ERR_STATUS` là cờ dính (W1C). Bộ đếm bão hoà, xoá bằng `CNT_CLR`.
`FRAME_ERR` (0x04C) giữ các bit trên của **một frame**: OR các sự kiện lỗi từ
FE trước (hoặc lúc bật RX) tới FE của frame, chốt cùng `FRAME_INFO`; 0 = frame
nhận không lỗi. Sự kiện tới trong 2 chu kỳ sau FE (ví dụ ECC_CORR của chính
header FE, qua một đường CDC khác) vẫn thuộc frame vừa kết thúc, không thuộc
frame sau. Lỗi trong vertical blanking tính cho frame sau (burst mất có thể là FS
hay một dòng của nó). Đây là nơi duy nhất thấy được dòng mất ở đuôi frame.
`bow_csi2rx_link_errors()` = ECC (cả hai) + CRC + TRUNC + SOT (4 lane) + OVF +
misc + EXTRA; link tốt là 0 (`bow_csi2rx_print_errors()` in đúng các số hạng này,
`sot` có 4 giá trị khi đang dùng 4 lane). Bộ đếm khác: `CNT_FRAME` (FS), `CNT_PKT`
(header đúng hoặc đã sửa, mọi VC/DT), `CNT_LINE`, `CNT_DROP[15:0]`,
`CNT_BURST`/`CNT_BURST23` (số lần vào HS mỗi data lane), `CNT_MISC[15:0]` (lane
clock), `CNT_EXT[31:16]` (burst deskew, không phải lỗi). `CNT_MISC[23:16]` cộng
lỗi LP của cả 1 + `Lanes` máy trạng thái.

## Bản đồ thanh ghi (`0x4000_8000`)

| Offset | Tên | Truy cập | Bit (giá trị reset) |
|-------:|-----|:--:|-----|
| 0x000 | `ID` | R | `0x43533201` ("CS2", phiên bản 1) |
| 0x004 | `INFO` | R | [3:0] số data lane (`Lanes`), [4] PHY (có D-PHY), [5] DLY_VID (`DlyVid`), [15:8] clock video (MHz), [31:16] độ sâu FIFO (nhóm). `kv260_cam`: `0x0100C812`, `kv260`: `0x01003202`, Huins camera: `0x0200C834` |
| 0x008 | `CTRL` | RW | [0] PHY_EN (0), [1] RX_EN (0), [2] LANES: 2 lane, [3] CLK_FORCE (0), [4] VC_ANY (0), [6:5] VC (0), [7] LANES4: 4 lane (thắng LANES), [13:8] DT (0x2B), [23:16] EXTRA: số byte sau packet trong burst trước khi báo EXTRA (64, 0 = tắt; trail tính theo byte của mọi lane đang dùng nên với 4 lane driver đặt cao hơn, xem *Bốn lane*). Số lane dùng = LANES4 ? 4 : (LANES ? 2 : 1), không bao giờ quá `Lanes`; bit của số lane lớn hơn `Lanes` đọc 0, ghi bị bỏ. Reset: dùng `Lanes` lane (`Lanes` = 2: LANES = 1; 4: LANES4 = 1) |
| 0x00C | `PHY_CFG` | RW | chu kỳ video: [7:0] SETTLE (14), [11:8] LP_FILTER (2), [23:16] CLK_SETTLE (30), [31:24] CLK_MISS (8, 0 = tắt) |
| 0x010 | `STATUS` | R | LP sau bộ lọc `{P,N}`: [1:0] lane clock, [3:2] lane 0, [5:4] lane 1, [17:16] lane 2, [19:18] lane 3; HS bật: [8] lane clock, [9] lane 0, [10] lane 1, [20] lane 2, [21] lane 3; [11] CE (cổng byte clock mở), [12] IN_FRAME, [13] BYTECLK_OK, [14] PHY_RDY (`phy_rdy_i`). Lane không có (trên `Lanes`) đọc 0 |
| 0x014 | `IRQ_STATUS` | R/W1C | [0] FS, [1] FE, [2] ERR (một bit `ERR_STATUS` được set), [3] LOG_DONE, [4] RAW_DONE |
| 0x018 | `IRQ_EN` | RW | bit giống `IRQ_STATUS` (0); `irq = \|(IRQ_STATUS & IRQ_EN)` → `irq_fast[7]` |
| 0x01C | `ERR_STATUS` | R/W1C | [11:0] cờ dính, xem *Lỗi và bộ đếm* |
| 0x020 | `CNT_CLR` | W | [0] = 1: xoá mọi bộ đếm 0x024…0x048, 0x068, 0x06C |
| 0x024 | `CNT_FRAME` | R | số FS của VC được chọn |
| 0x028 | `CNT_PKT` | R | packet có header đúng hoặc đã sửa |
| 0x02C | `CNT_LINE` | R | packet pixel accepted đã đủ byte |
| 0x030 | `CNT_ECC` | R | [15:0] đã sửa, [31:16] không sửa được |
| 0x034 | `CNT_CRC` | R | [15:0] lỗi CRC, [31:16] packet bị cắt |
| 0x038 | `CNT_SOT` | R | lỗi sync: [15:0] lane 0, [31:16] lane 1 |
| 0x03C | `CNT_DROP` | R | [15:0] long packet bị bộ lọc VC/DT bỏ, [31:16] packet bị tràn FIFO |
| 0x040 | `CNT_BURST` | R | số lần vào HS: [15:0] lane 0, [31:16] lane 1 |
| 0x044 | `CNT_MISC` | R | [15:0] số lần vào HS của lane clock, [23:16] lỗi LP, [31:24] lỗi skew + format + frame + frame bị bỏ (SKIP) |
| 0x048 | `CNT_EXT` | R | [15:0] burst có quá `CTRL.EXTRA` byte sau packet, [31:16] burst deskew (lane 0) |
| 0x04C | `FRAME_ERR` | R | [11:0] bit `ERR_STATUS` của frame hoàn chỉnh cuối (từ FE trước tới FE của nó), chốt ở FE |
| 0x050 | `FRAME_INFO` | R | frame hoàn chỉnh cuối: [15:0] số dòng, [31:16] số frame (WC của FS) |
| 0x054 | `LINE_INFO` | R | dòng accepted cuối: [15:0] WC, [21:16] DT, [23:22] VC |
| 0x058 | `FRAME_SUM` | R | tổng giá trị pixel của frame hoàn chỉnh cuối |
| 0x05C | `FRAME_TIME` | R | chu kỳ CPU giữa hai FS cuối |
| 0x060 | `LINE_TIME` | R | chu kỳ CPU giữa hai lần kết thúc dòng cuối trong một frame |
| 0x064 | `BYTECLK` | R | [19:0] số byte clock trong 65536 chu kỳ CPU (khi clock chạy) |
| 0x068 | `CNT_SOT23` | R | lỗi sync: [15:0] lane 2, [31:16] lane 3 (0 khi `Lanes` < 4) |
| 0x06C | `CNT_BURST23` | R | số lần vào HS: [15:0] lane 2, [31:16] lane 3 (0 khi `Lanes` < 4) |
| 0x070 | `DLY0` | RW | ghi [8:0] tap lane 0; đọc [8:0] tap đã ghi, [24:16] tap đang dùng (CNTVALUEOUT). `DlyVid` = 1: sau reset [24:16] là tap BISC của PHY (khi `PHY_RDY`), mỗi lần ghi nạp tap ngay (không cần burst) |
| 0x074 | `DLY1` | RW | như `DLY0` cho lane 1 (đọc 0, ghi bị bỏ khi `Lanes = 1`) |
| 0x078, 0x07C | `DLY2`, `DLY3` | RW | như `DLY0` cho lane 2, 3 (đọc 0, ghi bị bỏ khi `Lanes` < 4) |
| 0x080 | `LOG_CTRL` | RW | ghi: [0] ARM, [1] TRIG_FS, [2] STOP_FE. Đọc: [0] ARMED, [1] TRIG_FS, [2] STOP_FE, [8] DONE, [21:16] WPTR |
| 0x084 | `RAW_CTRL` | RW | ghi: [0] ARM, [1] NOW. Đọc: [0] ARMED, [1] NOW, [8] DONE |
| 0x400–0x4FC | `LOG[0..63]` | R | packet log (bên dưới) |
| 0x800–0x8FC | `RAW[0..63]` | R | 8 × `Lanes` bit: [8k+7:8k] word lane k ([7:0] lane 0, [15:8] lane 1, ... [31:24] lane 3) |

W1C: ghi 1 để xoá; nếu phần cứng set đúng chu kỳ đó thì set thắng. Offset không
có thanh ghi đọc ra 0, ghi bị bỏ qua (không bus error). Ghi tôn trọng byte
enable: byte không ghi giữ nguyên, bit W1C ngoài các byte đó không bị xoá, lệnh
(`CNT_CLR`, `LOG_CTRL`, `RAW_CTRL`) cần byte 0; ghi `DLYn` không có byte 0 và 1
không đổi tap và (với `DlyVid` = 1) không nạp. Bộ đếm 32/16/8 bit bão hoà
(`CNT_BURST` đầy sau ~60 frame 1080p).

```
LOG entry: [5:0] DT  [7:6] VC  [23:8] WC (sau khi sửa ECC)
           [25:24] ECC: 0 đúng, 1 đã sửa, 2 không sửa được (header thô)
           [26] lỗi CRC  [27] bị cắt  [28] accepted  [29] tràn FIFO
```

Mỗi packet có header giải được cho một entry, ghi lúc packet kết thúc (long
packet: 3 byte clock sau, để có cờ tràn FIFO); burst bị cắt trước khi đủ header
không có entry.

## Đo thời gian: `FRAME_TIME`, `LINE_TIME`, `BYTECLK`

- `FRAME_TIME`: chu kỳ CPU giữa hai FS cuối của VC được chọn, 0 sau reset tới
  khi thấy 2 FS. `LINE_TIME`: chu kỳ CPU giữa hai lần kết thúc dòng accepted gần nhất
  **trong cùng frame** (mốc reset ở FS).
- Tắt RX xoá các mốc nhưng giữ giá trị thanh ghi: sau khi bật lại, giá trị cũ
  còn thấy tới khi có hai FS mới, nên hãy đọc sau ít nhất hai frame.
- `BYTECLK`: cứ 256 chu kỳ CPU lấy hiệu của đồng hồ gray (mod 2^20), giữ max
  của 256 cửa sổ rồi nhân 256 (cập nhật mỗi 1,3 ms ở 50 MHz). f_byte =
  `BYTECLK` × f_cpu / 65536 (`bow_csi2rx_byteclk_hz()`), độ phân giải
  ~195 kHz, cần burst dài hơn ~2 cửa sổ (10 µs). Trên board đo được
  114,06 MHz (danh định 912/8 = 114 MHz).
- Packet kết thúc theo số byte, nhưng phần việc cuối (so CRC, sự kiện, LOG, CDC)
  cần **~11 byte clock** sau byte dữ liệu cuối. Máy phát đúng D-PHY cho ~20
  (T_HS-TRAIL + T_CLK-POST). Nếu clock dừng sớm hơn, phần việc đó chạy khi
  clock chạy lại ở burst sau: bộ đếm và pixel vẫn đúng, chỉ thời điểm sự kiện
  (và FRAME_TIME/LINE_TIME) bị lệch.

## Debug: STATUS, LOG, RAW, CLK_FORCE

- `STATUS`: PHY bật, cảm biến standby → `0x403F` với 2 lane (mọi lane LP-11, bit
  14 = PHY_RDY), `0x000F403F` với 4 lane; bitstream dựng trước khi có bit
  PHY_RDY đọc `0x003F`. Lane nằm ở LP-00 mãi: IMX219 sau khi bật nguồn chưa
  stream lần nào, vì vậy `imx219_probe()` stream 100 µs rồi dừng (như probe của
  Linux). IMX274 ở standby thì mọi lane đều LP-00 (bit LP của lane đọc 0): vẫn bình
  thường.
- LOG: 64 entry, một entry mỗi packet:

  | `LOG_CTRL` (ghi) | Ghi gì | Kết thúc |
  |---|---|---|
  | `ARM` | 64 packet kế tiếp | entry thứ 64 |
  | `ARM` + `TRIG_FS` | 64 packet từ FS kế tiếp của VC được chọn | entry thứ 64 |
  | `ARM` + `STOP_FE` | vòng tròn | sau khi log một FE của VC được chọn; `WPTR` = entry cũ nhất (0 nếu chưa quay vòng) |
  | `ARM` + `TRIG_FS` + `STOP_FE` | từ FS tới FE | FE, tối đa 64 entry |

  `ARMED` = đang chờ; xong thì `DONE = 1` và `IRQ_STATUS.LOG_DONE`. ARM khi
  đang chờ thì bắt đầu lại. `bow_csi2rx_log()` trả entry theo thứ tự thời gian,
  `bow_csi2rx_print_log()` in mỗi entry một dòng `<i> vc<v> dt <xx> <tên> wc <n>`
  cùng các cờ `ecc-corrected`, `ecc-error`, `crc-error`, `truncated`,
  `accepted`, `overflow`. Một frame IMX219 bình thường: FS (wc = số frame),
  2 × EMB (dt 12), H dòng RAW10 `accepted`, FE.
- RAW: 64 word liên tiếp `{lane Lanes−1, …, lane 0}` từ chu kỳ `hs_active` của
  lane 0 lên (ARM) hoặc ngay lập tức (NOW), chỉ các chu kỳ có word valid ở lane 0: thấy HS-zero, byte sync ở một pha bit bất
  kỳ và header. Lệnh `raw` của `csi2_test` in các word và tìm byte sync
  (`sync byte at bit …`).
- Lệnh LOG/RAW là mức: ARM khi byte clock dừng vẫn được phục vụ ở burst sau.
  DONE đến 2 byte clock sau word cuối; nếu clock dừng ngay sau đó, DONE đến ở
  burst kế tiếp.
- `CLK_FORCE`: cảm biến clock liên tục đã ở HS lúc bộ thu bật thì lane clock
  không bao giờ đi qua LP-11 → LP-01 → LP-00. `CLK_FORCE = 1` bật bộ thu và cổng
  lane clock ngay khi PHY_EN = 1. IMX219 không cần. Chỉ đặt khi lane clock
  **đã ở HS**: termination và cổng khi đó bật cả ở trạng thái LP (cạnh rác
  của bộ thu HS lọt vào byte clock), và `ISERDESE3` chỉ được reset (căn lại
  clock /4 bên trong) một lần mỗi lần bật PHY_EN.

## Hiệu chỉnh eye

Vì clock trễ 0,4–1,4 ns so với data tuỳ chip và nhiệt độ, không có tap cố định
dùng được cho mọi board: `bow_csi2rx_calibrate(step, tap_ms, &cal, verbose)`
tìm tap IDELAY của mỗi data lane trong lúc cảm biến stream (nội dung bất kỳ).

1. Một điểm đo: ghi `DLY0`/`DLY1`, chờ CNTVALUEOUT = tap (cần một burst; hết
   giờ = không có byte clock → huỷ), chờ 50 µs (sự kiện của burst cũ), xoá bộ
   đếm và `ERR_STATUS`, rồi tap **tốt** nếu `CNT_LINE` đạt 32 trước lỗi đầu
   tiên (SOT, ECC_CORR, ECC_ERR, CRC, TRUNC, SKEW), **xấu** ở lỗi đầu tiên hoặc
   sau `tap_ms`. Lỗi FRAME không tính (frame mất FS ở tap trước kết thúc bằng
   FE không có FS). `tap_ms` ≥ 1,2 × chu kỳ frame + 2 ms: một tap có thể phải
   chờ hết vertical blanking.
2. Pass 1: hai lane cùng tap, tap 0…511 bước `step`. Không có eye chung (lệch
   lane lớn): lane 1 cố định ở 0, 128, 256, 384 và quét lane 0, lấy tổ hợp đầu
   tiên có eye.
3. Pass 2: quét từng lane, lane kia ở tâm của pass 1.
4. Chọn dải tap tốt dài nhất (không quay vòng 511 → 0); dải không chạm đầu nào
   (0 hay 511) được ưu tiên nếu dài ít nhất một nửa (eye có thể còn tiếp ngoài
   dải quét). Tap = tâm dải, độ rộng = số điểm × `step`.
5. Nạp kết quả, chờ một FE, xoá bộ đếm và `ERR_STATUS`. Thất bại: trả lại tap
   cũ và `false`.

Bản đồ đo trên KV260 (`csi2_test`, bước 8, 64 điểm = tap 0, 8, …, 504; `#` =
32 dòng không lỗi ở tap đó):

```
lanes |###......################################......#################| tap 196 width 256
lane0 |####.....##################################....#################| tap 204 width 272 (other lane at 196)
lane1 |###.....#################################....###################| tap 192 width 264 (other lane at 196)
```

Mỗi lane có ~260 tap tốt (~0,94 ns). Mẫu lặp lại sau ~304 tap = 1 UI (1096 ps),
tức ~3,6 ps/tap. Tap chọn được 204/192. Tap reset 0 tình cờ nằm trong vùng tốt
nhưng chỉ cách mép ~24 tap, nên ứng dụng `camera` hiệu chỉnh ở `cam` đầu tiên
(bước 16: `csi2rx: calibrated taps 208/200 eye 272/256`) và chỉ làm lại khi
`bow_csi2rx_link_check()` ở lần `cam` sau thấy lỗi do tap (`ERR_STATUS &
CSI2RX_ERR_TAP`; EXTRA, FORMAT, FRAME, OVF không phải lỗi tap, chỉ được báo:
`taps kept`), hoặc không thấy đủ 64 packet trong 2 × thời gian chờ một tap (2,4
frame + 6 ms) mà không có lỗi nào: không có dữ liệu thì hiệu chỉnh thất bại rõ
ràng (`calibration failed`, `cam` trả `error`) thay vì báo "streaming". Tap được
giữ trong thanh ghi qua stop/start, mất khi reset SoC.

Tiêu chí 32 dòng (~3×10^5 bit, BER < ~10^-5) lạc quan ở mép eye. Đo dài trên
KV260 (720p60, 3 s mỗi tap ≈ 8,6×10^8 bit mỗi lane, lane kia ở tâm): lane 0 sạch
ở tap 76…332 (tap 72: 7 lỗi CRC, 68: 65107; 336: 5346, 340: hỏng hẳn), lane 1
sạch ở 64…320 (60: 10140, 324: 7199). Cả hai eye rộng 256 tap (~0,92 ns), tâm
204/192, lề ±128 tap (~±460 ps) ở nhiệt độ phòng; tiêu chí 32 dòng gọi các tap
cách mép thật 4–8 tap là tốt.

### Kiểm tra lề sau hiệu chỉnh (`bow_csi2rx_margin`)

Hiệu chỉnh chỉ nói tap đang ở giữa eye **lúc đó**. Kiểm tra lề đo lâu ở tâm và
ở tâm ± k của từng lane để có một con số BER và biết còn bao nhiêu tap trước khi
lỗi:

1. Điểm đo: 5 điểm với 2 lane (tâm, lane 0 −k / +k, lane 1 −k / +k, lane kia ở
   tâm), 3 điểm với 1 lane, 9 điểm với 4 lane (tâm, rồi −k / +k của từng lane,
   các lane khác ở tâm; thanh ghi `DLY` được ghi như khi hiệu chỉnh: các lane đang
   dùng, ít nhất 2 với `DLY_VID` = 0; với PHY Versal tap nạp ngay, không cần
   burst). Mỗi điểm: `frames` FE hoặc tới lỗi lấy mẫu đầu tiên
   (`CSI2RX_ERR_TAP`: SOT, ECC đã sửa và không sửa được, CRC, TRUNC, SKEW). Sau
   một điểm sạch (vừa thấy FE, không burst nào đang tới) bộ đếm được xoá rồi mới
   ghi tap: tap mới có hiệu lực ở burst sau (FS), không packet nào bị cắt, và một
   FS bị mất ở tap mới là lỗi của điểm đó. Các trường hợp khác (điểm đầu, điểm
   sau một điểm lỗi): ghi tap, chờ tap được dùng, 50 µs cho burst đang tới, rồi
   xoá bộ đếm. Một frame mất FS (ở tap trước) kết thúc bằng FE không có FS, không
   bật `IRQ_STATUS.FE`: timer chờ được khởi động lại ở FS đầu tiên sau mỗi FE,
   nên frame sau vẫn được đếm thay vì hết giờ (−1, "not measured"). Lỗi đã thấy
   ở một điểm vẫn là kết quả (0) dù điểm sau không đo được. Chỉ in sau khi đo
   xong (in một dòng ở 115200 baud dài hơn vertical blanking 720p60).
2. `k = max(eye / 4, CSI2RX_MARGIN_MIN = 40)` tap theo độ rộng eye của lần hiệu
   chỉnh: KV260 68/66 tap ≈ ±240 ps ≈ ±0,22 UI, còn ~64 tap tới mép eye đo dài.
3. Bit được tính: dòng accepted × (WC + 6) × 8 / số lane, mỗi lane; 0 lỗi trong
   n bit → BER < −ln(0,05)/n = 3/n (95 %). CRC-16 bắt mọi lỗi 1–3 bit và mọi
   burst ≤ 16 bit, header có ECC: 0 lỗi phát hiện ≈ 0 lỗi bit.
4. Chỉ báo, không dời tap: tap luôn trở về tâm đã hiệu chỉnh. Ba điểm mỗi lane
   chỉ nói mép eye (ở BER đó) nằm ngoài tâm ± k; dời tap mà không đo hai mép là
   đổi lề bên này lấy lề bên kia. Bám eye thật (tìm hai mép bằng tiêu chí dài)
   là việc của giai đoạn 1, dùng lại `margin_point`.

| Frame mỗi điểm | 1080p30 | 720p60 |
|---|---|---|
| 8 (`camera`, `video` sau hiệu chỉnh) | 8,3×10^7 bit/lane, BER < 3,7×10^-8, 0,27 s/điểm | 3,7×10^7, < 8,1×10^-8, 0,13 s |
| 60 (`csi2_test`, lệnh `margin`) | 6,2×10^8, < 4,9×10^-9, 2 s/điểm | 2,8×10^8, < 1,1×10^-8, 1 s |
| 1800 (`margin 0 1800`) | 1,9×10^10, < 1,6×10^-10, 60 s/điểm | 8,3×10^9, < 3,6×10^-10, 30 s |

`csi2_test` chạy kiểm tra này (check `margin`) với dữ liệu PN9 của cảm biến
(màu đơn thân thiện với link hơn) ngay sau `calibrate`, ở mỗi chế độ; `camera`
và `video` chạy 8 frame mỗi điểm sau mỗi lần hiệu chỉnh và in một dòng
`csi2rx: margin ok|low …`. Kết quả chỉ đúng ở nhiệt độ/điện áp lúc đo: để đo trôi
nhiệt, hiệu chỉnh một lần ở 25 °C rồi chạy `margin` (không hiệu chỉnh lại) ở
−40 và +85 °C.

Với PHY Versal (`INFO.DLY_VID` = 1) khác ở ba điểm: sau reset bộ thu không nạp
tap nào, PHY giữ delay mà BISC (tự hiệu chỉnh) tìm được, đọc ở `DLYn[24:16]`
khi `STATUS.PHY_RDY` = 1; mỗi lần ghi `DLYn` nạp tap ngay, không cần burst; và
4 lane cùng đi qua strobe của lane clock nên eye của các lane gần nhau. Vì vậy
hiệu chỉnh bắt đầu từ tap BISC và quét quanh nó, không bao giờ nạp mù tap 0
(tap 0 có thể nằm ngoài eye). 512 tap của XPHY phủ ≥ 625 ps theo AM010, cỡ
một UI ở 1440 Mbit/s (694 ps); độ lớn thật của một tap trên silicon chưa đo
(UNVERIFIED). Trên bo Huins (2026-11-10) trễ BISC nằm ở **mép sớm** của eye trên
mọi lane (122/75/118/130 so với tâm 300/184/264/228 sau hiệu chỉnh, eye rộng
352–360 tap; ~11 % dòng lỗi CRC ở trễ BISC), nên app `camera` và `video` luôn
hiệu chỉnh ở lần khởi động đầu, như trên KV260 (nạp tap làm các lane đó thôi bù
VT), và `margin` của chúng đo quanh trễ đang dùng (`bow_csi2rx_get_delays()`),
không bao giờ quanh tap 0 khi chưa hiệu chỉnh. Vì sao BISC ở chế độ native
strobe đặt điểm lấy mẫu sớm khoảng 1/4 UI là câu hỏi mở của RTL
([camera_huins.md](../camera_huins.md) mục 9: giả thuyết strobe căn mép so với lane
clock căn giữa của D-PHY).

## Ràng buộc và kiểm tra sau build (`kv260_cam`)

| Ràng buộc (`constr/kv260_cam.xdc`) | Tác dụng |
|---|---|
| `PACKAGE_PIN` D7/D6, E5/D5, G6/F6 | lane clock, lane 0, lane 1 của J9 (bank 66), như platform của AMD |
| `IOSTANDARD MIPI_DPHY_DCI`, `DIFF_TERM_ADV TERM_100` | bộ thu D-PHY (HS + LP) trong bank HP; termination 100 Ω bật/tắt cùng `HSRX_DISABLE` |
| `create_clock -name dphy_hs_clk -period 2.193` trên `clk_p` | HS clock 456 MHz; Vivado tự suy ra byte clock /4 (`dphy_byte_clk`, 8,772 ns) và clock /4 bên trong ISERDES (`dphy_hs_clk_DIV4_INV`) |
| `set_clock_groups -asynchronous`: `clk_sys`, `clk_vid`, `dphy_hs_clk` + clock suy ra | mọi đường giữa các nhóm đi qua bộ đồng bộ, bus gray hoặc RAM 2 clock; gồm cả bộ thu LP của chân clock (lấy mẫu ở `clk_vid`) |
| `set_false_path -from` chân data | bắt data không có static timing (eye hiệu chỉnh lúc chạy); bộ thu LP của chân data được đồng bộ ở `clk_vid` |
| `set_false_path -to` chân CE của hai BUFGCE_DIV | CE là flop `clk_vid`, FSM chỉ đổi nó khi lane clock đứng yên ở HS-0 (PHY_EN = 0 đóng cổng ngay, nên driver chờ `STATUS.CE` = 0 trước khi xoá PHY_EN) |
| `CLOCK_DELAY_GROUP bow_dphy_rx_clk` | cân bằng cây clock /1 và /4; net được tìm qua chân `O` của buffer |
| 7 × `set_bus_skew` | bus gray (clock group không che `set_bus_skew`): con trỏ ghi FIFO 8,7 ns, con trỏ đọc 5 ns, đồng hồ đo byte clock 8,7 ns, req/ack LOG/RAW 5 ns; đích là flop đồng bộ đầu tiên. Cell được chọn theo đuôi tên phân cấp (`get_cells -hierarchical -filter`): cell D-PHY theo tên của nó (`*/meter_gray_q_reg[*]`, `*/u_sync_meter/...`), FIFO, thanh ghi, capture theo đường dưới `u_csi2rx`, nên ràng buộc không phụ thuộc chỗ đặt khối D-PHY ([mipi_rx_arch.md](mipi_rx_arch.md) mục 10, bước 1). Vì selector theo đuôi tên cũng bắt cell cùng tên ở chỗ khác, `tcl/build.tcl` kiểm cell của từng ràng buộc (`hw/fpga/common/tcl/bus_skew_checks.tcl`) |

`tcl/build.tcl` ghi thêm `clocks.rpt`, `clock_interaction.rpt`,
`check_timing.rpt`, `methodology.rpt`, `drc.rpt`, `bus_skew.rpt`, chép
`clockInfo.txt`, và in `CRITICAL WARNING` khi timing không đạt (setup, hold
hoặc pulse width: dòng kết luận của `timing_summary.rpt`), khi bus skew bị vi
phạm hoặc không đủ 9 `Slack (MET)` (7 của bộ thu, 2 của H.264: ràng buộc mất
cell vì RTL đổi tên sẽ biến mất khỏi báo cáo), khi cell của một ràng buộc không
đúng (`hw/fpga/common/tcl/bus_skew_checks.tcl`: cell ngoài `u_soc/u_csi2rx` và
FIFO ra của H.264, flop đích không có đường từ nguồn, số flop nguồn khác số flop
đích), khi `CLOCK_DELAY_GROUP` không có đủ 2 net, hoặc khi không có
`clockInfo.txt` để kiểm tra. Bản hiện tại
(Vivado 2025.2, 2026-11-10, sau giai đoạn 0): WNS +0,005 ns (`clk_vid` 200 MHz, đường
găng ở bộ macroblock H.264: không có `phys_opt_design` sau route thì -0,026 ns, nên
`tcl/build.tcl` bật bước đó), `clk_sys` +2,349 ns, byte clock +2,952 ns, WHS
+0,010 ns, bus skew đạt (7 của bộ thu + 2 của H.264), 0 lỗi DRC. Cảnh báo bình thường:
[../camera_kv260.md](../camera_kv260.md) mục 3.

## Driver

```c
#include "bow32.h"      /* bow_csi2rx.h */
#include "imx219.h"     /* driver cảm biến, sw/common */

uint32_t lanes;
bool phy;
if (!bow_csi2rx_probe(&lanes, &phy) || !phy) return;   /* bitstream không có D-PHY */

bow_csi2rx_start(2, CSI2_DT_RAW10, IMX219_LANE_RATE);  /* TRƯỚC stream-on: phải thấy LP-11 */
imx219_configure(1920, 1080, 1763);         /* 1080p30 */
imx219_stream(true);
bow_csi2rx_cnt_t c;                         /* tap_ms = 42 >= 1,2 frame + 2 ms */
if (!bow_csi2rx_link_check(64, 2 * 42)) {   /* 2,4 frame: frame đầu có thể còn xa 1 frame */
  bow_csi2rx_counters(&c);
  if (bow_csi2rx_link_errors(&c) == 0 || (CSI2RX->ERR_STATUS & CSI2RX_ERR_TAP)) {
    bow_csi2rx_cal_t cal;                   /* không có dữ liệu, hoặc lỗi do tap */
    bow_csi2rx_margin_t m;
    if (bow_csi2rx_calibrate(16, 42, &cal, true))     /* false: không có byte clock */
      bow_csi2rx_margin(&cal, 0, 8, 42, &m, true);   /* tâm, tâm +-k: chỉ báo */
  }
}
bow_csi2rx_wait_frame(100);                 /* FE kế tiếp */
uint32_t h = CSI2RX_FRAME_LINES(CSI2RX->FRAME_INFO);   /* 1080 */
bool ok = CSI2RX->FRAME_ERR == 0;           /* frame đó không lỗi */
bow_csi2rx_print_status();                  /* "csi2rx: link ok" ... */

imx219_stream(false);
bow_csi2rx_stop(34 + 10);                   /* SAU stream-off: chờ hết frame đang gửi */
```

| Hàm | Việc |
|-----|------|
| `bow_csi2rx_probe(&lanes, &phy)` | kiểm tra `ID`, đọc `INFO`; `false` nếu không có bộ thu (bitstream cũ: bus error được bắt) |
| `bow_csi2rx_start(lanes, dt, lane_rate)` | `PHY_CFG` theo `INFO` MHz và tốc độ lane (bit/s, ví dụ `IMX219_LANE_RATE`): SETTLE đặt `hs_active` ở 107 ns + 24 UI sau LP-00 ở chân (= giữa 85 ns + 6 UI … 145 ns + 2 UI, cộng nhìn lùi trung bình 20 UI, trừ 8 ns bộ thu LP), trừ 3 + LP_FILTER chu kỳ trễ của bộ lọc và FSM: 22 ở 912 Mbit/s và 200 MHz, 70 ns nếu `lane_rate` = 0; với `INFO.DLY_VID` (PHY Versal) 95 ns (mục *Bốn lane*); CLK_SETTLE 150 ns, LP_FILTER 2, CLK_MISS = 1 chu kỳ byte clock (8 UI) + 3 chu kỳ video; `CTRL` = PHY_EN + RX_EN + lane + DT (VC 0) + EXTRA trên số byte trail của mọi lane đang dùng (mục *Lớp packet*; PHY Versal thêm 8 byte mỗi lane cho FIFO), xoá bộ đếm và cờ |
| `bow_csi2rx_stop(ms)` | gọi sau stream-off: chờ hết frame (FE, hoặc IN_FRAME = 0 và không có burst mới trong 2 line time), chờ FSM lane clock đóng cổng (`STATUS.CE` = 0, tối đa 1 ms), rồi `CTRL = 0`; giữ tap |
| `bow_csi2rx_set_rx(on)` | chỉ RX_EN, quanh việc đổi VC/DT |
| `bow_csi2rx_clear()` | xoá bộ đếm và `ERR_STATUS` |
| `bow_csi2rx_counters(&c)`, `bow_csi2rx_link_errors(&c)`, `bow_csi2rx_print_errors(&c)` | đọc bộ đếm; tổng lỗi link; in đúng các số hạng của tổng (`ecc a/b crc … extra n`) |
| `bow_csi2rx_link_check(n, ms)` | xoá bộ đếm, `true` khi có `n` packet không lỗi; khi `false`: `bow_csi2rx_link_errors()` = 0 là hết giờ (ít packet hơn: không có dữ liệu hay link rất chậm; `ERR_STATUS` vẫn có thể có LP, không được đếm), còn lại `ERR_STATUS & CSI2RX_ERR_TAP` cho biết hiệu chỉnh lại có giúp được không |
| `bow_csi2rx_wait_frame(ms)` | chờ FE kế tiếp của VC được chọn |
| `bow_csi2rx_set_delay(lane, tap)`, `bow_csi2rx_wait_delay(ms)` | ghi tap; chờ tới khi mọi lane dùng tap đã ghi (cần một burst) |
| `bow_csi2rx_calibrate(step, tap_ms, &cal, verbose)` | hiệu chỉnh eye; `verbose` in một dòng bản đồ mỗi lần quét |
| `bow_csi2rx_margin(&cal, k, frames, tap_ms, &m, verbose)`, `bow_csi2rx_print_margin(&m, r)` | kiểm tra lề (mục *Hiệu chỉnh eye*): 1 = không lỗi ở mọi điểm, 0 = có lỗi (`m` nói ở đâu), −1 = không đo được; tap trở về tâm; `+-68/+-66 taps: 0 errors in 5 x 60 frames, BER < 4.9e-9` |
| `bow_csi2rx_log(e, mode, ms)`, `bow_csi2rx_print_log(e, n)` | LOG theo thứ tự thời gian, số entry (0 = hết giờ) |
| `bow_csi2rx_raw(w, now, ms)` | 64 word thô mỗi lane |
| `bow_csi2rx_byteclk_hz(ms)` | tần số byte clock (max của `BYTECLK` trong `ms`) |
| `bow_csi2rx_print_status()` | `csi2rx: link ok` / `link errors` / `no data` / `no lines`, bộ đếm (`frame errors` = `FRAME_ERR` của frame cuối; `errors: …` như `print_errors`, rồi số packet bị bộ lọc DT/VC bỏ), thời gian, PHY; byte clock đo trong 1 frame + 2 ms (clock không liên tục dừng suốt vertical blanking, `BYTECLK` chỉ nhìn 65536 chu kỳ CPU). Danh sách theo lane (`sot`, LP, burst, delay) có 4 giá trị khi đang dùng 4 lane, và khi bộ thu tắt (`CTRL.PHY_EN` = 0) theo số lane của bản build (`INFO`: 4 trên Huins), không theo `CTRL` đã xoá |
| `bow_csi2rx_print_delays()`, `bow_csi2rx_get_delays(taps)` | trễ đang dùng của các lane (`DLY_VID` = 1: `[24:16]`, trễ BISC tới khi nạp tap; 0: tap đã ghi): in như `stat`, hoặc cả 4 lane vào `taps[]` (tâm của kiểm tra lề ở tap đang dùng: `csi2_test` `margin` sau `delay` hay `phy reinit`, `camera` `margin` khi chưa hiệu chỉnh) |

4 lane trên Versal (Huins, IMX274): `bow_csi2rx_start(4, CSI2_DT_RAW10, 1440000000)`
đặt `LANES4` và `CTRL.EXTRA` 192 (4 × (38 + 8) + 8; PHY UltraScale+ ở cùng tốc độ:
160); khi `INFO.DLY_VID` = 1 (chỉ XPHY của Versal có hiệu chỉnh lúc khởi
động: XPLL khoá + BISC) hàm chờ `STATUS.PHY_RDY` (tối đa 10 ms, quá hạn: mã lỗi
`CSI2RX_ENOTRDY`) trước khi bật bộ thu. Với `DLY_VID` = 0 không chờ: PHY
UltraScale+ nối `PHY_RDY` = 1, còn bitstream `kv260_cam` dựng trước khi có bit này
đọc 0 và firmware mới vẫn chạy trên nó. RAW là `uint32_t` (8 bit mỗi lane), bộ
đếm, tap và kiểm tra lề (`bow_csi2rx_margin`: tâm rồi tâm ± k của từng lane đang
dùng) có 4 lane.

Quy tắc: đổi LANES/LANES4/VC/VC_ANY/DT/EXTRA khi RX_EN = 0, PHY_CFG và CLK_FORCE khi
PHY_EN = 0; bật bộ thu trước khi cảm biến stream và tắt sau khi cảm biến gửi
xong frame cuối; tap ghi vào `DLYn` có hiệu lực ở burst sau (`DLY_VID` = 0) hoặc
ngay (`DLY_VID` = 1). Ngắt: `IRQ_EN`,
`bow_irq_fast_enable(BOW32_IRQ_FAST_CSI2RX)` (mcause `0x80000017`), ISR ghi 1 vào
`IRQ_STATUS` để xoá (ví dụ: `sw/apps/csi2_test/main.c`).

## Kiểm chứng

| Mức | Cách chạy | Kiểm tra |
|-----|-----------|----------|
| Mô hình Python | `make test-tools` (`tools/tests/test_csi2_model.py`, 40 test) | vector ECC/CRC, mọi lỗi 1 bit và 2 bit của header, RAW10, aligner ở mọi pha bit, burst deskew (`FFFFh`, chỉ nhận ở cuối HS-zero: sync hỏng + `00 FF` trong dữ liệu, `0xFF` + packet, `0xFC`/`0xFE`/`0xFF` + DI `0x2B` vẫn là lỗi sync; burst thô không có packet; 2 và 4 lane: deskew chỉ trên một số lane là SKEW), chia/ghép và lệch 4 lane (cả luật chính xác 6/7 byte clock), luật của bộ thu, dòng lỗi, burst mất → dòng sau lỗi / frame bị bỏ, `FRAME_ERR` từng frame, tràn FIFO (Cut/Lost, đầu ra giữ 3 nhóm khi nhóm đầu có 1 pixel), EXTRA, byte enable, thanh ghi 4 lane, `DLY` miền video và khởi động lại PHY, cấu hình PHY Versal (`BurstRxRst`, trễ chung / riêng từng lane), chế độ LOG; vòng sinh/kiểm tra mọi test (cả 4 lane + PHY Versal, cả `--ppi` hai chế độ); checker bắt được lỗi cài vào; dựng PPI (`PpiTest`): luật ghép lane trên chu kỳ (6 nhận / 7 SKEW, khe cứu được, FIFO 8 byte đầy sau khi bắt đầu, `RxActiveHS` thấp ngay sau byte cuối làm mất word), byte của các lane ghép lại đúng burst, `RxActiveHS` trước / cùng `RxSyncHS`, lỗi sync và lệch lane ở hai chế độ, những gì dải phụ / wrapper cho controller |
| IP (Verilator) | `make -C hw/ip/csi2rx/dv test-rx` (CI; `make -C hw/ip/csi2rx/dv test` = `test-rx` + `test-ppi`, cũng trong `make test-ip`) | 3 model: `Lanes` 1, 2 (như KV260) và 4 (như Huins: `DlyVid` = 1, FIFO 512, byte clock 180 MHz, clock video 200 MHz). 105 case (~24 s): unit test aligner `tb_dphy_align.sv` (301 case: 75 case × 4 lượt, sync, deskew `FFFFh`, 8 và 15 bit 1, sync hỏng `0xFC`/`0xFE`/`0xFF` + DI, `0xB9` + `00 FF FF`, 1–3 word nhiễu HS-PREPARE, cửa sổ ở word 0 cuối hay sau HS-zero, ở mọi pha bit; lượt 2–4 có chu kỳ `rx_valid` = 0 với word rác `00`/`FF`/`B8`/ngẫu nhiên, cả lúc `arm` lên) + 44 random (seed 1–4 × {2 lane, 2 lane + lỗi, 1 lane + lỗi, 1 trên 2 lane, 1 trên 2 lane + lỗi, 4 lane, 4 lane + lỗi, 4 lane + lỗi với `BurstRxRst` = 1, 2 trên 4 (`BurstRxRst` = 1), 2 trên 4 + lỗi, 1 trên 4 + lỗi (`BurstRxRst` = 1)}, xen kẽ RAW8 và clock liên tục) + directed `lp`, `watchdog`, `clk`, `cmd`, `ovf`, `stop`, `byteclk`, `eye`, `skew`, `deskew`, `extra`, `loss`, `ovf2`, `ovf8`, `be` trên 2 lane và trên 4 lane (+ `dly`); `cmd`, `stop`, `deskew`, `extra`, `ovf`, `ovf2`, `loss`, `be`, `eye` thêm với 1 lane, `deskew`, `extra`, `ovf`, `ovf2`, `loss`, `eye` thêm với 1 trên 2 lane, `cmd`, `stop`, `skew`, `dly`, `deskew`, `extra`, `ovf2`, `loss` với 2 trên 4, `be`, `eye`, `loss` thêm với clock liên tục (2 và 4 lane; `DLY` đọc lại khi byte clock chạy). Bản build DV bật `BOW_CDC_JITTER`: mỗi bộ đồng bộ `bow_cdc_pulse` ngẫu nhiên nhận toggle muộn một chu kỳ (như flop metastable), nên hai sự kiện cùng một packet có thể tới thanh ghi lệch một chu kỳ, theo cả hai thứ tự (`+verilator+seed+` = seed của case). Pixel (`tuser[0]`/`tlast`/`tuser[1]`), bộ đếm, FRAME/LINE_INFO, FRAME_SUM, `FRAME_ERR` ở mỗi FE, FRAME/LINE_TIME, LOG, RAW so với mô hình, cả khi FIFO tràn (`ovf`, `ovf2`: dòng Cut, dòng Lost, nhả `tready` giữa frame, nhóm `sof` bị bỏ → frame bị bỏ, đuôi frame mất; `ovf8`: RAW8 với nhóm đầu 1 pixel; dòng Lost ngoài frame không đánh dấu dòng sau; số dòng theo `FifoDepth`); `deskew`: burst skew calibration thật (burst thô `FFFFh` + `0101…`), sync hỏng với `00 FF` trong pixel hay trail, `0xFC`/`0xFE`/`0xFF` trước DI, bit sync ngay trước cuối HS-zero vẫn là SOT; `loss`: header không sửa được, SOT, SKEW giữa frame, ở dòng đầu, ở dòng cuối, giữa hai frame, dòng đầu không có nhóm pixel (WC 3, WC 0: frame bị bỏ), dòng không có nhóm giữa frame và ngoài frame, vào HS bị từ chối ở mức LP (data lane, lane clock; với `CLK_FORCE` thì không mất), packet bị cắt không phải dòng (EMB, VC khác), dòng accepted lỗi FORMAT bị cắt, ECC_CORR của header FE thuộc frame nó kết thúc; `extra`: EMB + dòng, VC khác + dòng, FS + dòng (frame bị bỏ), long packet nhỏ dưới ngưỡng, bão hoà ở 256 (4 lane: ngưỡng 196 trên trail tới 180 byte, packet sau 156 pixel); `be`: byte enable trên mọi thanh ghi RW/W1C/lệnh (cả `DLY3` không có byte 0/1: không đổi, không nạp); bất biến PHY (LP-00 → `hs_en` ≤ 4 + LP_FILTER chu kỳ, CE chỉ đổi khi lane clock tĩnh; với `DlyVid` = 1: số lần nạp tap mỗi lane, xung nạp 1 chu kỳ, tap ổn định quanh lần nạp, không nạp khi lần trước còn chờ). 57 mutant RTL của các thay đổi giai đoạn 0 (aligner: neo deskew, `FFFFh`, tuổi/HS-zero của lần dò; unpack: skip, dòng mất trong frame; `drop_i` gồm TRUNC và mất ở mức LP; FORMAT WC 0; `FRAME_ERR` cả cửa sổ 2 chu kỳ sau FE; byte enable, EXTRA) đều làm DV của PR #17 fail (`ferr_dly` chỉ nhờ jitter CDC); 8/9 mutant của phần gộp `rx_valid` trong aligner làm unit test fail (còn lại: `search &&` của `dpend_q`, tương đương với kích thích này) |
| Controller ở PPI (Verilator, bước 3 của [mipi_rx_arch.md](mipi_rx_arch.md) mục 10) | `make -C hw/ip/csi2rx/dv test-ppi` (CI); một case: `make -C hw/ip/csi2rx/dv run-ppi MODE=bow\|std TEST=…` | `tb_csi2rx_ppi.sv`: controller một mình, PHY là `bow_ppi_bfm.sv`; 3 model (`Lanes` 1, 2, 4, tham số như trên), mỗi model có hai DUT: `bow_csi2rx` với PPI và dải phụ do BFM lái (chế độ `bow`: thời gian của D-PHY Bow32) và wrapper `bow_csi2rx_ppi_flat` (chế độ `std`: PHY chuẩn); DUT không dùng không có clock. Kích thích: các test của controller trong `csi2_model.py` (random, `cmd`, `ovf`, `stop`, `skew`, `deskew`, `extra`, `loss`, `ovf2`, `ovf8`, `be`) do mô hình bộ thu xử lý như ở cả bộ thu rồi dựng lại ở PPI (`gen --ppi`: byte mỗi lane mỗi burst với chu kỳ, `RxActiveHS`, `RxSyncHS`, khe, lỗi, lần chạy byte clock, xung lp), thêm `clkstop` (byte clock dừng đúng 4 cạnh sau cạnh `RxActiveHS` xuống, FRAME/LINE_TIME vẫn đúng; T_CLK-POST ngắn: dừng từ sau byte cuối cần tới 3 cạnh sau, cuối burst xong khi clock chạy lại), `gaps` (khe 40 % rồi 75 % chu kỳ, `bow`) và `lpmask` (lỗi LP ở chu kỳ cuối trước / đầu sau khi mặt nạ enable lane hay `CLK_FORCE` áp dụng, `bow`). `bow`: `RxActiveHS` lên ở cuối SETTLE, khe như XPHY (chung mọi lane hay ở lane đi trước), byte còn ra khi `RxActiveHS` đã xuống, `ErrSotSyncHS` cuối burst, lỗi lp và HS entry là xung `vid_clk_i`, `band_lane_en_lp` = `Enable` qua 2 flop như D-PHY, RAW nhận word `00`…`B8`…byte; `std`: `RxActiveHS` cùng `RxSyncHS`, xuống ngay sau byte cuối, không khe, trail 0–3 byte, `ErrSotSyncHS` sớm có hay không có `RxActiveHS`, `RxSkewCalHS` xung hay mức, `ErrSotHS`, lỗi dạng xung ở clock lp 25 MHz riêng của PHY, không `ErrControlClk`, không `PhyReady`. Kiểm như bench cả bộ thu: pixel (`tuser[0]`/`tlast`/`tuser[1]`), bộ đếm, `FRAME_ERR`, FRAME/LINE_TIME, LOG, RAW (`bow`), `STATUS` (CE theo `RxClkActiveHS`: bất biến `ppi_ce_bad`; chương trình lane chồng nhau: `ppi_overlap`). 164 case (SEEDS 1–4: 2 chế độ × 8 cấu hình random, directed trên 2 và 4 lane, một phần với 1 lane, 1 trên 2, 2 trên 4, clock liên tục; `gaps`, `lpmask` trên 1, 2, 4 lane) chạy song song `PJOBS` case (mặc định số CPU, như bench DDR / HyperRAM); `sim.log` có dòng phủ của BFM. 14 mutant (`make -C hw/ip/csi2rx/dv mutants-ppi`) đều chết |
| FPGA, mức chân (xsim) | `source <Vivado>/settings64.sh; make -C hw/fpga/common/dv test` | `test-dphy` (UltraScale+): unisim `IBUFDS_DPHY`, `IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`; máy phát D-PHY từng bit ở 912 Mbit/s, clock không liên tục, `PHY_CFG` và `CTRL.EXTRA` của driver: word ISERDES, không có xung runt, CE chỉ đổi ở HS-0, `RST` mỗi burst ≥ 20 byte clock trước sync, `DLY` → CNTVALUEOUT, pixel và thanh ghi (cả `CNT_EXT`, `FRAME_ERR`); burst skew calibration (HS-zero, `FFFFh`, `0101…`) → deskew, không SOT; T_HS-TRAIL = T_EOT max không gây EXTRA; T_HS-PREPARE min và max (nhiễu tới 85 ns + 6 UI, kết thúc bằng `00 B8` giả) với T_HS-PREPARE + T_HS-ZERO đúng tối thiểu 145 ns + 10 UI trên mọi lane (pha bit ngẫu nhiên qua T_CLK-PRE); white box (probe `tb_dphy_align_probe` gắn vào mọi `bow_dphy_align` bằng `bind`, không phụ thuộc chỗ đặt aligner): cửa sổ dò đầu tiên của mỗi lane ở mỗi burst bắt đầu trong HS-zero (word cũ nhất = 0), không chỉ "không khoá vào `00 B8` giả" (vốn chỉ thấy cửa sổ lấn ≥ 16 UI vào nhiễu). Quét `SETTLE` (`+SETTLE=`, 12 seed mỗi giá trị): 20…28 đạt 12/12, 19 đạt 6/12 và ≤ 18 không đạt (cửa sổ bắt đầu trong nhiễu; ≤ 15 còn khoá vào sync giả), ≥ 29 lỡ sync thật. Mô hình không có trễ ~8 ns của bộ thu LP: trên thiết bị cửa sổ muộn hơn ~1,6 chu kỳ, dải ≈ 18…26 và 22 của driver ở giữa. `test-versal`: XPHY của Versal (24 cấu hình, [../simulation.md](../simulation.md)). Cần Vivado, không chạy trong CI; eye không mô phỏng được (unisim không có lệch clock/data) |
| Hệ thống | `make run TEST=camera`, `make run TEST=csi2`; bản IMX274: `camera274`, `csi2_274`, `video274` | firmware thật với `csi2_tx_model.sv` và mô hình IMX219 hoặc IMX274 + PHY Versal ([../simulation.md](../simulation.md)); `camera`: hiệu chỉnh + margin ở `cam` đầu, `cam` lại với tap giữ nguyên (link tốt; lỗi FRAME không phải lỗi tap: `taps kept`), cảm biến im lặng (không có dữ liệu: `calibration failed`, `error`) rồi khởi động lại; `csi2`: `test quick` 12/12 (có check `margin`), lỗi tiêm vào đúng ở bộ đếm, rồi eye lane 0 bị thu hẹp: `margin` báo đúng điểm lane 0 +48, các điểm khác sạch, tap giữ nguyên; lần nữa với thời gian frame như cảm biến thật (~3 ms so với 4 ms chờ một tap) và điểm lỗi là điểm thứ hai (lane 0 −48): các điểm sau vẫn đo đủ frame dù frame đang chạy mất FS; `csi2_274`: `test quick` 11/11 (có `margin` trên 4 lane, mẫu AAAh của IMX274), `margin` quanh tap đang dùng của cả 4 lane sau `delay`, `stat` với bộ thu tắt liệt kê 4 lane; `camera274`: `cam` đầu luôn hiệu chỉnh, khi hiệu chỉnh hỏng `margin` đo quanh trễ đang dùng (không nạp tap 0) |
| Tương đương hình thức | `make -C hw/ip/dphy_rx/fm equiv` (`STEP=2` mặc định; Synopsys Formality, cần license, không chạy trong CI) | bộ thu của commit tham chiếu (`REF`, mặc định `3a1e780`: `main` trước khi tách `bow_dphy_rx`; commit từ bước 1 trở đi, có `hw/ip/dphy_rx`, cũng được, ví dụ `35ef151` cuối bước 1; top là `bow_mipi_rx` nếu commit đó có, không thì `bow_csi2rx`) so với `bow_mipi_rx` hiện tại (cùng cổng), RTL với RTL, 5 cấu hình: KV260 (2 lane, FIFO 256), Huins (4 lane, FIFO 512, `DlyVid` = 1), 1 lane, `HasPhy` = 0 (50 MHz), mô phỏng hệ thống (107,5 MHz). Luật đổi tên của bước (flop đã chuyển giữ tên, thấp hơn một cấp; bước 2: `u_dphy_rx/` → rỗng và `u_csi2rx/` → rỗng, compare rule cho cả hai design), tắt khớp theo tên net, không user match, không constant, không black box (RAM đọc thành thanh ghi); đạt khi mọi compare point khớp theo tên và đều tương đương, không có điểm unmatched / aborted / unverified, và mọi cặp đã khớp có **tên giống hệt** sau luật đổi tên (`names.rpt`; `hw/ip/dphy_rx/fm/equiv.tcl`). Kiểm tên là cần: Formality xếp cả cặp khớp qua tên net vào "matched by name", và tương đương chức năng không thấy thuộc tính tổng hợp, nên một bộ đồng bộ viết lại bằng flop thường (mất `ASYNC_REG`, tên cell mà XDC và danh sách CDC không biết) vẫn *Verification SUCCEEDED*. Kết quả bước 1 và bước 2 (so với `3a1e780` và với `35ef151`) như nhau: KV260, `HasPhy` = 0 và mô phỏng 17 197 compare point, Huins 30 397, 1 lane 16 352, đều tương đương, mọi cặp cùng tên; điểm không so là thanh ghi hằng hay không được đọc theo tham số (ví dụ `ce_q` của máy LP data lane, `ev_deskew_o` của lane 1–3), giống nhau ở hai phía và giống bước 1. Mutant một bit ở controller (đảo phép che `CLK_FORCE` của `ErrControlClk`) và ở dây PPI (xung `ErrControl` sang bit 1) đều hỏng |
| Board | `csi2_test`, lệnh `test` | bên dưới |

Mô hình Python được viết từ đặc tả và quy tắc MIPI, **không** từ RTL, để hai
bên kiểm tra lẫn nhau: `csi2_model.py gen` sinh `cfg.txt`/`stim.txt`, testbench
`tb_bow_csi2rx.sv` lái `csi2_tx_model.sv` (cảm biến + I/O của board) và ghi
`out.txt`/`regs.txt`, `csi2_model.py check` so sánh. `make -C hw/ip/csi2rx/dv run
SEED=7 LANES=1 ERRORS=1` (thêm `DUT_LANES=1|2|4`, `RAW8=1`, `CONTCLK=1`,
`BURSTRST=1`) hoặc `make -C hw/ip/csi2rx/dv run TEST=clk` chạy một case và giữ
file trong `build/csi2rx_dv/<case>/`. Với `SEEDS="1 2 … 40"` (PR #17, chỉ 1 và
2 lane): 233/233 case đạt (~178k pixel, ~20k lần so thanh ghi, mọi vị trí lỗi 1
bit của header), với jitter CDC; sau khi gộp 4 lane, `SEEDS="1 2 … 10"`: 171/171 case đạt (~38 s).

Bench PPI của controller (bước 3) dùng cùng mô hình: `csi2_model.py gen --ppi bow|std` ghi mỗi
item TX như trên, theo sau là phần dựng lại ở PPI (dòng `ppl`, `ppb`, `ppev`, `ppclk`, `ppidle`,
`ppon`, `ppoff`, `lperr`; định dạng ở mục *PPI* của mô hình); `tb_csi2rx_ppi.sv` bỏ qua item TX
và chơi phần PPI qua `bow_ppi_bfm.sv`; `csi2_model.py check` so như trên, cùng kỳ vọng. Phần
dựng giữ cho kỳ vọng của mô hình đúng: trail mỗi lane trong giới hạn của mô hình, mỗi lane đưa đủ
byte của word cuối, luật ghép lane kiểm trên đúng chu kỳ đã dựng (`ppi_merge`: khe, FIFO 8 byte;
dựng lại nếu không khớp quyết định của mô hình). `make -C hw/ip/csi2rx/dv run-ppi MODE=std
TEST=loss LANES=4` chạy một case, giữ file trong `build/csi2rx_dv/ppi_<MODE>_<case>/`. Với
`SEEDS="1 2 … 40"`: 740/740 case đạt. Một case không nhanh hơn một case của bench cả bộ thu (30
case như nhau: 5,6 s so với 5,0 s, phần lớn ở mô hình Python; mô phỏng máy phát mức bit và D-PHY
số không đắt); bench PPI nhanh hơn vì chạy các case song song (`PJOBS`): 164 case ~3 s với 24
job, ~9 s với 4.

`make -C hw/ip/csi2rx/dv mutants-ppi` (`mutants_ppi.py`, không trong `test` hay CI): 14 mutant,
11 ở controller (giới hạn lệch lane 6 → 5, FIFO ghép lane 16 byte, push bỏ qua `RxValidHS`, burst
kết thúc khi một lane xuống, bắt đầu khi mọi lane lên, CRC 1 byte, bỏ mặt nạ lane / `CLK_FORCE`
của luật burst mất, tắt luật đó, lỗi sync không đánh dấu dòng sau, đếm deskew ở lane cuối) và 3 ở
wrapper (bỏ trễ miền byte, bỏ giữ `RxActiveHS`, `RxSkewCalHS` mức), đều làm bench PPI hỏng
(`--every`: case nào và chế độ nào bắt): push bỏ qua `RxValidHS` (khe) và hai mặt nạ chỉ chế độ
`bow` bắt được, ba mutant của wrapper chỉ chế độ `std`. Mutant đếm deskew ở lane cuối lúc đầu sống: test `deskew` chỉ đọc
`CNT_EXT` sau cả hai burst deskew một phần (lane 0 riêng, mọi lane trừ lane 0), lỗi hai chiều triệt
tiêu; nay đọc sau mỗi burst (cả ở bench cả bộ thu).

Model 4 lane chạy `csi2_tx_model.sv` ở chế độ PHY Versal (`--versal` của
mô hình Python, núm `versal` của TX model): `phy_rdy` lên sau 3 µs (trước đó
không có byte clock), tap BISC khác 0 đọc được qua CNTVALUEOUT, tap nạp ở clock
video, khởi động lại PHY (`phy_reinit`: `PHY_RDY` và CNTVALUEOUT về 0, tap BISC
trở lại, test `dly`). FIFO 8 word mỗi lane như XPHY: ghi mỗi cạnh strobe khi bộ
thu HS của lane clock bật (cả khi cổng byte clock đóng), đọc mỗi byte clock khi
FIFO có hơn `vlat` word (0–2: `FIFO_EMPTY` trễ), nên word cũ của burst trước ra
trước ở burst sau và trễ không bao giờ giảm. `BurstRxRst` = 0 (như bản camera
sau reset, trước khi firmware khởi động bộ thu, `--burst-rst 0`): FIFO chỉ bắt đầu lại khi PHY khởi động; mỗi lần
cổng mở thêm một word rác với xác suất `v_glitch_pct` (glitch của strobe lúc lane
clock vào/ra HS) và trễ đó ở lại; word thứ 9 đè word cũ nhất: bộ đọc nhảy qua 8
word (quay vòng). `BurstRxRst` = 1 (`--burst-rst 1`, `BURSTRST=1`): FIFO bị giữ
reset khi cổng đóng, mỗi burst bắt đầu lại với `vlat` mới. Chu kỳ không đọc
(`v_gap_pm`, `FIFO_EMPTY` thấy muộn thêm một chu kỳ) chỉ khi mọi FIFO ở trễ tối
thiểu. `vlat` chung cho mọi lane (mặc định, như mô hình XPHY của AMD) hoặc riêng
từng lane (`v_lat_lane`): random của mô hình Python chỉ dùng trễ riêng với
`BurstRxRst` = 1 hoặc không glitch. Với trễ riêng, glitch và `BurstRxRst` = 0,
các lane quay vòng ở những burst khác nhau, lệch lane tạm thời tới 7 word và bộ
thu bỏ burst (SKEW): seed 1–12 của 4 lane + lỗi với trễ riêng và glitch 50 %
hỏng cả 12, đúng như review đã thấy; vì vậy firmware bật `BurstRxRst` = 1 trên board.
Với trễ chung, trôi và quay vòng xảy ra cùng lúc ở mọi lane và chỉ mất word cũ
giữa các burst.

Các tính năng của PR #17 trên 4 lane (lớp packet 1–4 byte mỗi word, unpack tới 4
byte mỗi chu kỳ, aligner chỉ tiến trên word `rx_valid`): `px_err` cũng đi với
`px_eol` trễ một chu kỳ (word cuối có cả payload lẫn CRC), byte sau packet đếm
cả phần sau CRC trong word cuối và với header 4 byte P3 của short packet trùng
word `sop`; deskew, `tuser[1]`, `FRAME_ERR`, SKIP, Cut/Lost, EXTRA, byte enable
đều chạy trong DV 4 lane với PHY Versal (stale word, khoảng trống `rx_valid`).

Test directed `skew` (2 lane, 4 lane, 2 trên 4): mọi burst dòng có cùng pha bit
ở mọi lane và PHY không thêm lệch giữa các lane, nên byte đầu của các lane tới
ghép lane cách nhau đúng số byte HS-zero thêm vào: 0, 4, 5, 6 byte clock nhận
đúng, 7, 8, 12 cho SKEW và không ra gì (một lane muộn, hoặc với 4 lane một lane
sớm, lần lượt mọi lane). Mô hình Python dùng luật chính xác này (6 nhận, 7 bỏ)
chỉ khi các điều kiện đó đúng; ngoài ra 5–11 byte vẫn là vùng không dự đoán.

Trên KV260 + Raspberry Pi camera v2 (J9), 2026-11-09/10 (bitstream sau giai
đoạn 0, `SETTLE` 22, `CTRL.EXTRA` 62; hai mục đầu và `camera`, `video` chạy lại
2026-11-10 với bitstream sau vòng review thứ hai):

- `csi2_test`, lệnh `test`: `csi2_test: PASS (18/18)`: phy-idle; link-up,
  calibrate (tap 284/272, eye 272/264; bitstream trước: 204/192 — tâm eye dời
  theo route của mỗi lần build, độ rộng không đổi), margin (`+-68/+-66 taps: 0
  errors in 5 x 60 frames`, BER < 4,9×10^-9 ở 1080p30, < 1,1×10^-8 ở 720p60),
  integrity (`FRAME_ERR` = 0 ở mọi frame), packets, timing ở 1080p30 rồi
  720p60; isp, raw8, filter, restart, irq. (Trước giai đoạn 0, 2026-10-30:
  16/16.)
- `margin 0 1800` ở 720p60: 0 lỗi ở tâm và tâm ± 68/66 tap, mỗi điểm 1800 frame
  (8,3×10^9 bit mỗi lane), BER < 3,6×10^-10 mỗi điểm.
- Quét `SETTLE` (720p60, 2 s mỗi giá trị): 6…30 sạch (~93k dòng mỗi giá trị),
  ≤ 4 khoá nhầm (SKEW, frame bị bỏ), 34 lỡ một phần sync, ≥ 38 lỡ hết: sync của
  IMX219 tới ~180 ns sau LP-00 (tối thiểu của chuẩn 156 ns), HS-PREPARE gần như
  không có nhiễu. Driver 22 cách mép trên 8 chu kỳ (40 ns).
- Trail sau packet: 17–20 byte (2 lane); `CTRL.EXTRA` ≤ 16 báo mọi burst, 18
  báo ~56 %, ≥ 20 không báo; ngưỡng 62 của driver dư ~3 lần. Không có burst
  deskew.
- 2 lane × 912 Mbit/s, `BYTECLK` 114,06 MHz; frame 33326 µs (1080p30) và
  16653 µs (720p60), dòng 18,86–18,94 µs; `FRAME_SUM` đúng từng bit (1080p màu
  đơn `0x3d2e1c00`, 720p `0x1b30f000`); không có lỗi ECC/CRC/SOT/TRUNC trong
  nhiều phút; 2 dòng embedded mỗi frame vào `CNT_DROP`.
- Ứng dụng `camera`: `cam` hiệu chỉnh (288/272, eye 272/272) rồi
  `csi2rx: margin ok +-68/+-68 taps: 0 errors in 5 x 8 frames`, `csi` →
  `link ok`, `frame errors 000`, `extra 0`; `margin 0 30`: 0 lỗi ở 5 điểm,
  BER < 1,0×10^-8; `cam` lần hai giữ tap (không hiệu chỉnh lại), `link ok`;
  AE/AWB hội tụ, ảnh PNG 1080p30 và 720p60 đúng, ISP không báo lỗi. Ứng dụng
  `video`: hiệu chỉnh + margin, ghi H.264 720p (30 frame, CRC đúng, mô hình
  `h264_model.py` giải mã đủ 30 frame, ảnh đúng).

Trên Huins MFP-VP1902 + LI-IMX274MIPI-FMC, lần chạy bo 1 (2026-11-10, PDI và firmware
của nhánh IMX274 trước khi gộp PR #17, nên chưa có `margin`, `FRAME_ERR`, EXTRA;
[../camera_huins.md](../camera_huins.md) mục 6, 7):

- `csi2_test`, lệnh `test`: `csi2_test: PASS (15/15)`; calibrate tap 300/184/264/228,
  eye 352/360/360/352 tap (trễ BISC 122/75/118/130 ở mép sớm của eye: ~11 % dòng
  lỗi CRC trước `cal`); integrity `2a257400` (555h) / `544ae800` (AAAh) ở 1080p,
  đúng từng bit; timing frame 33333 µs (1080p30) và 16666 µs (720p60), byte clock
  180,078 MHz; packets: FS, 1 dòng embedded (DT 0x12, WC 175), 8 dòng OB (DT 0x37;
  720p: 4), mỗi burst một packet.
- 4 lane × 1440 Mbit/s: `b8` ngay sau HS-zero trên mọi lane, lệch giữa các lane 1
  bit và không đổi trong 2 phút; 0 lỗi ECC/CRC/SOT trong hơn 18 000 frame với
  tap đã hiệu chỉnh (~15 phút qua `csi2_test`, `camera`, `video`).
- `BurstRxRst` = 1: `SETTLE` sạch 65–170 ns (mục *Bốn lane, PHY Versal và IMX274*).
- Ứng dụng `camera`: 1080p30 và 720p60, sọc màu và cảnh thật đúng màu. Ứng dụng
  `video`: H.264 1080p30 giải mã không lỗi (20 frame: rate control cũ làm đầy video
  RAM).

Bản gộp PR #17 cùng các sửa sau lần 1 chưa chạy trên bo này (lần chạy bo 2).

## Tài nguyên (`kv260_cam`, Vivado 2025.2)

| Khối | LUT | FF | Khác |
|------|----:|---:|------|
| `bow_csi2rx` | 1962 (72 LUTRAM) | 2375 | 1 RAMB36 (FIFO pixel) |
| ↳ `bow_csi2rx_regs` | 713 | 826 | |
| ↳ `bow_csi2_packet` | 327 | 340 | |
| ↳ 3 × `bow_dphy_lp` | 256 | 121 | |
| ↳ 2 × `bow_dphy_align` | 178 | 85 | |
| ↳ `bow_csi2_unpack` | 129 | 173 | |
| ↳ `bow_csi2_capture` (LOG, RAW) | 93 (56 LUTRAM) | 100 | |
| ↳ `bow_csi2_lane_merge` | 75 (16 LUTRAM) | 43 | |
| ↳ `bow_fifo_async` | 46 | 70 | 1 RAMB36 |
| ↳ `bow_csi2rx_out` | 17 | 105 | |
| `bow_dphy_io_xusp` | – | – | 3 `IBUFDS_DPHY`; mỗi lane 1 `IDELAYE3` + 1 `ISERDESE3` chung một `BITSLICE_RX_TX`; 2 `BUFGCE_DIV` |

So sánh: Ibex 4425 LUT, ISP 3798 LUT; cả thiết kế `kv260_cam` 36449 LUT,
24369 FF. Giai đoạn 0 thêm 222 LUT và 141 FF (trước: 1740 / 2234): bộ đếm byte
sau packet và EXTRA, `CNT_EXT`, `FRAME_ERR` (cả cửa sổ sau FE), mức FIFO
(`afull`), khung dòng và frame của unpack (Cut/Lost, skip, dòng không có nhóm),
neo deskew và xác nhận `FFFFh` của aligner, mất burst ở mức LP, ghi theo byte
enable. Số liệu thay đổi vài chục LUT giữa các lần build (Vivado tối ưu khác
nhau).

Bản 4 lane của Huins (`Lanes = 4`, `FifoDepth = 512`, `DlyVid = 1`), riêng
`bow_csi2rx` out-of-context trên xcvp1902-vsva6865-2MP-e-S (Vivado 2025.2,
2026-11-10, clock lý tưởng: byte 180 MHz, video 200 MHz, CPU 50 MHz, nhóm bất
đồng bộ): 2506 LUT (108 LUTRAM), 2809 FF, 1 RAMB36; `bow_csi2rx_regs` 856 LUT,
`bow_csi2_packet` 423, 5 × `bow_dphy_lp` 422, `bow_csi2_unpack` 131,
`bow_csi2_lane_merge` 123, `bow_csi2_capture` 116. Timing sau route: byte clock
WNS +2,207 ns (đường dài nhất: `n_q` → tổng pixel trong unpack, 8 mức logic),
WHS +0,040 ns; video WNS +2,228 ns; CPU WNS +16,9 ns. Bộ CRC 4 byte/chu kỳ không
nằm trên đường găng, nên không cần thêm tầng pipeline.

Sau khi tách `bow_dphy_rx` (bước 1 của [mipi_rx_arch.md](mipi_rx_arch.md) mục 10; PDI camera
Huins, Vivado 2025.2, 2026-11-11, sau route): `bow_csi2rx` 2547 LUT (108 LUTRAM), 2967 FF, trong
đó `bow_dphy_rx` 827 LUT / 846 FF (5 × `bow_dphy_lp`, 4 × `bow_dphy_align`, các bộ đồng bộ, nạp
tap, đồng hồ đo), `bow_csi2rx_regs` 696 / 918, `bow_csi2_packet` 419 / 414, `bow_csi2_unpack`
156 / 173, `bow_csi2_lane_merge` 130 / 78, `bow_csi2_capture` 115 / 116. Cùng RTL trước khi tách
(bản build ngay trước): 2536 LUT, 2967 FF.

Sau bước 2 (`bow_mipi_rx`: `bow_dphy_rx` + controller nối bằng PPI; PDI camera Huins, 2026-11-11,
sau route): `bow_mipi_rx` 2545 LUT (108 LUTRAM), 2967 FF; `bow_dphy_rx` 819 / 846, controller
`bow_csi2rx` 1728 / 2121 (`bow_csi2rx_regs` 693 / 918, `bow_csi2_packet` 414 / 414,
`bow_csi2_unpack` 156 / 173, `bow_csi2_lane_merge` 130 / 78, `bow_csi2_capture` 116 / 116). PPI và
dải phụ là dây, không thêm logic: cả thiết kế sau tổng hợp 39 844 LUT / 24 967 thanh ghi (bước 1:
39 842 / 24 967).

## Giới hạn

- Chỉ nhận: không có escape mode, ULPS, turnaround hay LP data (LP-10 từ Stop
  là lỗi LP).
- Mỗi HS burst một packet, như CSI-2 v1.x quy định (LPS giữa các packet; IMX219
  về LP-11 sau mỗi packet): byte sau CRC bị bỏ tới burst sau. Máy phát không về
  LP-11 giữa các packet (sai chuẩn) hoặc dùng LRTE/EPD của CSI-2 v2.0+ thì packet
  sau bị bỏ; quá `CTRL.EXTRA` byte được báo (`ERR_STATUS.EXTRA`), short packet và
  long packet nhỏ theo sau thường nằm dưới ngưỡng (không bị báo). Ngưỡng tính
  theo byte của mọi lane đang dùng: với 4 lane (trail ~160–192 byte) chỉ packet
  sau dài hơn ~200 byte được báo. IMX274 trên bo Huins (lần chạy bo 1): mỗi burst
  đúng một packet (1091 burst mỗi frame 1080p = FS + 1 dòng embedded + 8 dòng OB +
  1080 dòng + FE, 727 ở 720p), tức cảm biến về LP-11 sau mỗi packet; trail thật so
  với ngưỡng 192 chưa đo (firmware của lần 1 có trước `CTRL.EXTRA`: `extra` của
  `stat`, `CNT_EXT`).
- 1, 2 hoặc 4 lane (không có 3), VC 2 bit (CSI-2 v1.x, không có VCX của v2.0),
  một VC/DT tại một thời điểm, ISP chỉ nhận RAW8/RAW10.
- 1 pixel/clock: RAW8 liền nhau ở 2 × 912 Mbit/s (228 Mpx/s) nhanh hơn
  200 Mpx/s; chỉ ổn khi các dòng có khoảng nghỉ. 4 lane × 1440 Mbit/s cho
  576 Mpx/s trong burst: IMX274 phải có HMAX đủ lớn (mục *Bốn lane, PHY Versal
  và IMX274*). 4K (3840 px) cần cả hai: FIFO ≥ 1024 nhóm (đỉnh mỗi dòng ~627
  nhóm, HMAX không làm đỉnh này nhỏ đi) **và** HMAX ≥ ~700 (điều kiện xả), hoặc
  đầu ra 2 pixel/clock (đỉnh ~293 nhóm, vừa FIFO 512). Bản Huins không có cái
  nào: mọi dòng 4K tràn FIFO (OVF, `CNT_DROP[31:16]`), `csi2_test` từ chối `mode
  4k` khi `INFO[31:16]` < 1024.
- Tốc độ lane ≥ ~350 Mbit/s (đã kiểm chứng 770–1050 Mbit/s trong DV, 912 Mbit/s
  trên board). Lý do, đều ở phía tốc độ thấp: (a) bộ thu thấy hoạt động của
  lane clock qua cạnh byte clock (8 UI một cạnh), nên `CLK_MISS` = n phải dài
  hơn một chu kỳ byte clock (driver tính theo `lane_rate`); cổng đóng muộn
  nhất ~20 + 5n ns sau cạnh cuối (45 ns ở 912 Mbit/s), vượt T_CLK-TRAIL tối
  thiểu 60 ns khi dưới ~333 Mbit/s (máy phát có T_CLK-TRAIL dài hơn thì vẫn
  được); (b) cuối burst, các byte còn trong pipeline ISERDES → aligner → ghép
  lane (~5–6 byte clock) phải ra trước khi `arm` tắt, mà T_HS-TRAIL + phát hiện
  LP-11 chỉ dài ~8 byte clock ở 912 Mbit/s và ngắn dần (tính theo byte clock)
  khi tốc độ giảm: dưới ~220 Mbit/s packet bị cắt cụt; (c) aligner nhìn lùi
  2 word (16–24 UI) lúc bắt đầu dò, nên bit cũ nhất nó xét dao động 8 UI + 1 chu
  kỳ video: cửa sổ cho nó (85 ns + 6 UI … 145 ns + 2 UI) rộng 60 ns − 4 UI, chỉ
  chứa được độ dao động đó khi UI < ~4,6 ns (> ~220 Mbit/s); driver đặt `SETTLE`
  giữa cửa sổ theo tốc độ lane (~20 ns lề hai bên ở 912 Mbit/s, ~12 ns ở
  400 Mbit/s). PHY Versal: `SETTLE` cố định 95 ns, vì FIFO của XPHY lùi cửa sổ
  thêm 0–3 word (`BurstRxRst` = 1; mục *Bốn lane*).
- Nếu có frame mà không có dòng nào, `bow_csi2rx_print_status()` báo
  `csi2rx: no lines (DT/VC filter?)` (`CTRL.DT`/`VC` không khớp luồng). Máy phát
  gửi nhiều packet trong một burst thì báo `link errors` với `extra` > 0.
- `tuser[1]` không báo được dòng mất sau dòng ra cuối của frame, frame mất hết,
  hay frame có FS bị mất (dòng của nó nằm ngoài frame: không `tuser[0]`, không
  `tuser[1]`): khối sau phải đếm dòng giữa hai `tuser[0]`, phần mềm đọc
  `FRAME_ERR` ở mỗi FE. Quy tắc `drop_i` thận trọng: burst mất không phải dòng
  pixel (embedded data), packet bị cắt không phải dòng, hay một lần vào HS bị từ
  chối ở mức LP mà thật ra không mất burst nào cũng đánh dấu dòng sau.
- Deskew chỉ được nhận ở chỗ HS-zero kết thúc, với đủ 16 bit 1: nếu cửa sổ dò
  bắt đầu với hơn 2 word nhiễu HS-PREPARE (`SETTLE` quá sớm; PHY Versal: cả word
  trễ của FIFO), burst deskew thật thành lỗi SOT (như trước giai đoạn 0). Sync
  deskew `FFFFh` hỏng cũng là lỗi SOT; sync `0xB8` hỏng mà cùng dữ liệu sau nó
  thành 16 bit 1 liền nhau thì bị coi là deskew (burst mất không có lỗi SOT).
  Chỉ lane 0 được đếm.
- `CLK_FORCE` chỉ dùng khi lane clock đã ở HS (xem mục Debug).
- Tap ở chế độ COUNT, không bù nhiệt/áp (`EN_VTC 0`): điểm lấy mẫu trôi theo
  nhiệt độ, và chỉ được hiệu chỉnh lại khi được gọi (`cam` thấy lỗi do tap hay
  không có dữ liệu, lệnh `cal`). Kiểm tra lề (`bow_csi2rx_margin`) đo lề ở nhiệt độ lúc chạy và chỉ
  báo; chưa có bám eye tự động hay hiệu chỉnh theo nhiệt. Hiệu chỉnh và kiểm tra
  lề cần cảm biến đang stream.
- Thời gian bật termination theo clock video (~34 ns ở 200 MHz, sát giới hạn
  35 ns + 4 UI): clock video thấp hơn hoặc `LP_FILTER` > 2 làm nó trễ hơn.
- Cấu hình qua `bow_sync` từng bit, không handshake: phải theo quy tắc đổi cấu
  hình khi RX/PHY tắt.

## Bài tập mở rộng

- Đầu ra (và ISP) 2 pixel/clock cho 4 lane: 1080p60 với HMAX tối thiểu và 4K30
  của IMX274 cần hơn 200 Mpx/s trung bình mỗi dòng.
- RAW12 (DT 0x2C, 3 byte → 2 pixel) với đầu ra 12 bit; YUV422 8 bit (DT 0x1E).
- LRTE/EPD của CSI-2 v2.0 (nhiều packet trong một burst, phân cách bằng spacer;
  cần đặc tả và một cảm biến dùng nó) và LS/LE làm mốc dòng.
- ISP dùng `tuser[1]` và `FRAME_ERR`: huỷ frame có dòng lỗi (hiện chỉ huỷ khi sai
  kích thước).
- Thống kê, ngắt theo dòng/frame: ngắt mỗi N dòng, min/max của `LINE_TIME`,
  jitter của `FRAME_TIME`, đếm frame hỏng.
- Tự hiệu chỉnh lại eye: ISR theo dõi `ECC_CORR`/`CRC`, hoặc liên tục dò hai
  mép eye bằng tiêu chí dài (chia đôi bằng `margin_point` của driver) để bám theo
  trôi nhiệt.
- Dùng burst deskew của D-PHY v1.2 (đã nhận ra và bỏ qua) để hiệu chỉnh bằng
  phần cứng thay vì đếm dòng.
- Lane chậm (80–350 Mbit/s): xả pipeline ở cuối burst (aligner xuất nốt word
  cuối, ghép lane pop hết FIFO rồi mới `eob`), và phát hiện mất clock bằng
  chính HS clock thay vì byte clock.
- ULPS và escape mode: nhận biết vào/ra ULPS, đọc LP data (LPDT).
- Kiểm chứng formal (SymbiYosys) cho `bow_fifo_async` và giao thức req/ack gray.
