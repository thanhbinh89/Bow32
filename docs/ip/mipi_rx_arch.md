# Kiến trúc bộ thu MIPI cho ASIC: AFE, D-PHY số, PPI và bộ điều khiển CSI-2

Đặc tả kiến trúc (chưa có RTL) cho bộ thu MIPI mà Bow32 sở hữu trọn vẹn trên **ASIC**: cả
**D-PHY** (phần analog lẫn phần số) và **bộ điều khiển CSI-2**, chia theo các lớp chuẩn của MIPI:

```
module camera ─► D-PHY analog (AFE) ─► [giao diện AFE] ─► D-PHY số ─► PPI ─► bộ điều khiển CSI-2 ─► AXI / ISP
```

FPGA chỉ là nơi kiểm chứng RTL số: trên FPGA, primitive I/O của hãng đứng thay D-PHY analog sau
một adapter. Điểm xuất phát là mã ở `main` `458dd33` (bộ thu 4 lane đã chạy trên bo Huins với
IMX274; PR #17, PR #18). [csi2rx.md](csi2rx.md) mô tả bộ thu hiện tại;
[../csi2rx_review.md](../csi2rx_review.md) mục 5–7 đã đề xuất tách PPI cho SoC camera AI. Tài liệu
này biến đề xuất đó thành đặc tả: giao diện AFE, khối D-PHY số mới `bow_dphy_rx`, PPI của Bow32,
bộ điều khiển sau khi tách, hiệu chỉnh, kiểm chứng, sẵn sàng ASIC và kế hoạch chuyển từng bước.
Chạy trên bo: [../camera_kv260.md](../camera_kv260.md), [../camera_huins.md](../camera_huins.md).

**Quy ước.** Đặc tả MIPI chỉ dành cho thành viên: tài liệu này không chép văn bản nào của nó;
hành vi được mô tả bằng lời của tài liệu này, con số thời gian lấy từ nguồn công khai có dẫn
([S1]…[S23], mục *Nguồn* ở cuối). **[CHƯA CHẮC]** = chưa kiểm được ở nguồn gốc; **[ĐỀ XUẤT]** =
con số do tài liệu này đề nghị, đội liên quan phải xác nhận. Không có số chân, nibble hay slice
của bo Huins. Tên module, tín hiệu và thanh ghi giữ tiếng Anh. "Hiện nay" = `main` `458dd33`;
số dòng theo commit đó.

| Thông số | Giá trị |
|---|---|
| Đích | ASIC: Bow32 sở hữu AFE (D-PHY analog), D-PHY số và controller CSI-2; FPGA (KV260, Huins MFP-VP1902) kiểm chứng phần số |
| Lớp vật lý | D-PHY RX một chiều: 1 lane clock + 1, 2 hoặc 4 data lane (tham số tới 8), clock liên tục hoặc không; 80 Mbit/s … 2,5 Gbit/s mỗi lane (dưới ~350 Mbit/s chỉ khi AFE có `clk_act`, mục 1.2) |
| D-PHY số | máy LP, settle, termination, cổng byte clock, SoT và căn byte, deskew (nhận ra, rồi hiệu chỉnh), lỗi, ULPS; escape LPDT/trigger để sau |
| Ranh giới | giao diện AFE (dưới PPI: word chưa căn, byte clock, mức LP, điều khiển analog) và PPI 8 bit mỗi lane (16 bit ở v2) |
| CSI-2 | lớp giao thức v1.x trên D-PHY, mốc v1.3; đường lên v2.x |
| Khối mới | `bow_dphy_rx`, `bow_dphy_rx_regs`, `bow_dphy_raw`, `bow_dphy_dsk`, `bow_dphy_prbs`, `bow_ppi_pkg`, `bow_mipi_rx` (wrapper Bow32), `bow_mipi_rx_apb` (wrapper APB4 cho ASIC); FPGA: `bow_dphy_dly_xusp`, `bow_dphy_dly_xphy` (logic adapter không có primitive); DV: `bow_ppi_bfm`, `bow_dphy_afe_model`, `bow_dphy_tx` |
| Đổi vai | `bow_dphy_io_xusp`, `bow_dphy_io_versal` thành **adapter AFE** (giữ tên file và tên instance mà XDC dùng) |
| Giữ nguyên | lớp CSI-2 của `bow_csi2rx` (ghép lane, packet, unpack, FIFO, đầu ra, LOG); bản đồ `CSI2RX` ở `0x4000_8000` (thanh ghi PHY chuyển sang D-PHY ở `0x4000_8C00`; không có alias, driver chọn theo `INFO[6]`, mục 6.3) |
| Trạng thái | đặc tả, chưa có RTL; kế hoạch chuyển gồm các bước 0–11, mỗi bước giữ bản build KV260 / Huins và mọi test hiện có, kỳ vọng nào đổi thì ghi rõ (mục 10) |

## 1. Mục tiêu và phạm vi

### 1.1 Mục tiêu

1. **ASIC trước.** Bow32 sở hữu cả D-PHY RX (analog và số) lẫn bộ điều khiển CSI-2 RX. Đội analog
   chỉ cần mục 3 (giao diện AFE) để làm macro; phần số không chứa gì riêng của FPGA.
2. **FPGA để kiểm chứng phần số.** `bow_dphy_rx` và `bow_csi2rx` là cùng một RTL trên FPGA và
   ASIC; mọi khác biệt của FPGA nằm trong adapter AFE. Số liệu đo trên FPGA (eye, tap, BISC) là
   của adapter, không phải của ASIC.
3. **Giữ những gì đã chạy trên bo.** Máy LP, aligner, ghép lane, lớp packet, unpack, eye walk và
   kiểm tra lề đã chạy trên KV260 (IMX219, 2 × 912 Mbit/s) và Huins (IMX274, 4 × 1440 Mbit/s):
   chúng được chuyển nguyên trạng trước, cải tiến sau, và mỗi bước giữ test và bản build xanh.
4. **Ranh giới chuẩn ở giữa.** PPI là giao diện tham khảo giữa PHY và lớp giao thức [S1][S4][S15].
   Controller CSI-2 của Bow32 được thiết kế để ghép với D-PHY của hãng khác (và D-PHY của Bow32 với
   controller khác) qua wrapper cổng phẳng, trong giới hạn của hồ sơ PPI ở mục 5.5. Chưa thử với
   PHY của hãng nào: đây là mục tiêu thiết kế, chưa phải khả năng đã chứng minh. Mọi chỗ Bow32 lệch
   khỏi PPI công khai được ghi ở mục 5.3.
5. **Hiệu chỉnh dựa trên dữ liệu.** Bài học của bo Huins (tự hiệu chỉnh BISC đặt điểm lấy mẫu ở
   mép sớm của eye) thành yêu cầu kiến trúc: tự hiệu chỉnh trong phần cứng của PHY (BISC của XPHY,
   hay của AFE ASIC) chỉ là điểm xuất phát, điểm lấy mẫu cuối cùng phải được đo trên dữ liệu
   (mục 7).

### 1.2 Dải hỗ trợ

| Hạng mục | RTL v1 (sau khi tách) | Mục tiêu ASIC | Để ngỏ cho |
|---|---|---|---|
| Data lane | 1, 2, 4 (tham số `Lanes`, chọn lúc chạy) | 1, 2, 4 | 8: tham số, địa chỉ thanh ghi và PPI đã có chỗ (logic của lane 4–7 chỉ sinh khi `Lanes` > 4); ghép lane và lớp packet cần mở rộng (mục 6.5) |
| Tốc độ mỗi lane | thiết kế cho ~350 Mbit/s … 1,5 Gbit/s; đã kiểm 770–1050 Mbit/s trong DV, 912 Mbit/s (KV260) và 1440 Mbit/s (Huins) trên bo; giới hạn dưới ở mục 4.5; trên 1,5 Gbit/s hiệu chỉnh bằng eye walk tới khi có bộ máy deskew | 80 Mbit/s … 2,5 Gbit/s. Phần dưới ~350 Mbit/s có điều kiện: AFE có `clk_act` (bắt buộc với macro ASIC, mục 3.2) và các sửa (b), (c) của mục 4.5 (bước 10). Trên 1,5 Gbit/s cần bộ máy deskew | trên 2,5 Gbit/s (D-PHY v2.x: equalization, ACS) ngoài phạm vi |
| Lane clock | liên tục hoặc không (dừng mỗi burst hoặc mỗi frame) | như v1 | — |
| Chức năng D-PHY phía thu | LP/HS, SoT, nhận ra burst deskew, lỗi SoT/LP, watchdog HS | + timer lập trình được, ULPS, `ErrSotHS`, bộ máy deskew, ánh xạ lane (`LANE_MAP`) | escape LPDT, trigger |
| PPI | 8 bit mỗi lane | 8 bit; 16 bit cho 2,5 Gbit/s ở node chậm | 16/32 bit (tuỳ chọn từ D-PHY v2.0 [S13]) |
| CSI-2 | v1.x: VC 2 bit, ECC, CRC, FS/FE, RAW8/RAW10, một packet mỗi burst | mốc v1.3 trên D-PHY | v2.x: VCX, RAW16/RAW20, LRTE/EPD (nhiều packet mỗi burst) |

**Mốc CSI-2 v1.3** ở đây là lớp giao thức chung của các bản v1.x trên D-PHY: header 4 byte (DI =
VC 2 bit + DT 6 bit, WC 16 bit, ECC 6 bit), CRC-16 của long packet, short packet FS/FE/LS/LE và
generic, các kiểu dữ liệu ảnh và embedded. Những gì v1.3 thêm so với v1.1 khi dùng D-PHY phải được
một thành viên MIPI kiểm ở đặc tả **[CHƯA CHẮC]**; C-PHY không thuộc phạm vi. Các tính năng v2.x
kể trên lấy theo tài liệu hiện có của Bow32 ([csi2rx.md](csi2rx.md) mục *Giới hạn*,
[../csi2rx_review.md](../csi2rx_review.md) mục 5); phiên bản chính xác đưa vào từng tính năng
**[CHƯA CHẮC]**.

### 1.3 Ngoài phạm vi

- C-PHY, A-PHY, D-PHY TX trên ASIC, DSI, lane hai chiều (turnaround, contention detect,
  `TurnRequest`/`Direction`): bộ thu camera không cần [S1][S4].
- D-PHY trên 2,5 Gbit/s: equalization phía thu (CTLE, đánh dấu từ v3.0 [S13]), alternate
  calibration (ACS) [S4][S5][S9], preamble, embedded clock (v3.5 [S13]).
- Thiết kế mạch analog: tài liệu chỉ đặt giao diện và yêu cầu; kiến trúc mạch, layout, ESD và
  đặc tính điện là việc của đội analog.
- Các tính năng CSI-2 từ v3.0 trở đi (ví dụ bảo mật CSE mà review đã nêu).
- Nhiều PHY hay nhiều cảm biến trên một controller, router N luồng, AXI4 master ghi DDR: kiến
  trúc để ngỏ (mục 6.5), đặc tả riêng sau.
- Thay đổi ISP (2 pixel/clock, RAW12): theo [../csi2rx_review.md](../csi2rx_review.md) mục 7.

### 1.4 Số liệu bo làm đầu vào

| Số liệu (2026-11-09/10) | Dùng ở |
|---|---|
| Huins + IMX274: trễ BISC ở mép sớm của eye trên cả 4 lane (sớm hơn tâm 98…178 tap; eye ~352–360 trên 512 tap; ~11 % dòng lỗi CRC ở trễ BISC); BISC cho cùng kết quả khi cảm biến còn bị reset (LP-00) và khi đang stream | hiệu chỉnh dựa trên dữ liệu, `DLYn.OWN` (mục 3.5, 7) |
| Huins: reset FIFO RX của XPHY mỗi lần cổng byte clock đóng (PA5 = 1; trong mã gọi là "mỗi burst") sạch với `SETTLE` 65–170 ns; PA5 = 0 hỏng sau lần bật lại bộ thu đầu tiên. Cổng chỉ đóng khi lane clock rời HS, nên với IMX274 reset này xảy ra mỗi frame, không phải mỗi burst dữ liệu | `des_rst` bắt buộc, theo mỗi lần mở cổng (mục 3.2, 7.1) |
| IMX274: đúng một packet mỗi HS burst (1091 burst mỗi frame 1080p) | giả định "một packet mỗi burst" của lớp packet vẫn đúng; LRTE chỉ ở đường v2.x |
| IMX274 (và IMX219): lane clock vào HS một lần mỗi frame, LP-11 trong vertical blanking | byte clock chạy suốt frame; D-PHY và controller phải đúng cả khi clock dừng mỗi burst (DV có cả hai) |
| IMX274: standby là LP-00 trên cả 5 lane trước lần stream đầu | `WaitStop` không coi LP-00 là lỗi (mục 4.2) |
| IMX274: `b8` ngay sau HS-zero, lệch giữa lane 1 bit và ổn định; byte clock 180,078 MHz | ghép lane chịu lệch 6 byte clock là đủ |
| KV260 + IMX219: `SETTLE` 6…30 chu kỳ sạch, eye 256–272 tap `IDELAYE3`, tâm đổi theo route của mỗi lần build | adapter UltraScale+ (mục 3.7), eye walk (mục 7.3) |

## 2. Mô hình lớp và sơ đồ khối

### 2.1 Các lớp

```
 Lớp                ASIC                                     FPGA (KV260 / Huins)                     Chủ
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────
 L0 cảm biến        module camera (D-PHY TX)                 IMX219 / IMX274; bow_dphy_tx (loopback)   ngoài / DV
 L1 AFE             macro analog D-PHY RX                     bow_dphy_io_xusp / bow_dphy_io_versal     analog
 ══ giao diện AFE ═════════════════════════════════════════════════════════════════════════════════════════
 L2 D-PHY số        bow_dphy_rx (std cell)                    bow_dphy_rx (cùng RTL)                    PHY số
 ══ PPI (bow_ppi_pkg) ═════════════════════════════════════════════════════════════════════════════════════
 L3 CSI-2 RX        bow_csi2rx: ghép lane, packet, unpack     bow_csi2rx (cùng RTL)                     controller
 ══ AXI4-Stream (pixel) · APB / bus Bow32 (thanh ghi) ═════════════════════════════════════════════════════
 L4 ứng dụng        ISP, DMA, NPU                             ISP Bow32, VRAM                           SoC
```

### 2.2 Sơ đồ khối

```
 chân P/N (lane clock + data lane)      bow_mipi_rx (wrapper Bow32: cửa sổ 4 KiB, ngắt)
     │          ┌──────────────────────────────────────────────────────────────────────────┐
     ▼          │                                                                          │
  ┌──────┐ AFE  │  ┌──────────────────────────┐   PPI   ┌─────────────────────────────┐    │  m_axis RAW10
  │ AFE  │══════╪═►│ bow_dphy_rx              │════════►│ bow_csi2rx                  │────┼──► ISP
  │      │◄═════╪══│ máy LP, timer, termin.,  │         │ ghép lane, packet (ECC,     │    │
  └──────┘      │  │ cổng clock, SoT + căn,   │         │ CRC, VC/DT), unpack, FIFO,  │    │
  HS RX, term,  │  │ deskew, lỗi, ULPS, RAW   │         │ LOG                         │    │
  LP RX, 1:8,   │  │ thanh ghi @ 0xC00        │         │ thanh ghi @ 0x000           │    │
  chia, delay   │  └────────────▲─────────────┘         └──────────────▲──────────────┘    │
                │               └────────────── bus (clk_i) ───────────┴───────────────────┼──► periph 0x4000_8000
                └──────────────────────────────────────────────────────────────────────────┘
 FPGA: AFE = bow_dphy_io_xusp (IBUFDS_DPHY, IDELAYE3, ISERDESE3, BUFGCE_DIV) hoặc
             bow_dphy_io_versal (IBUFDS_DPHY, XPHY native strobe, XPLL, BUFGCE); phần còn lại: cùng RTL
```

### 2.3 Khối, chủ và tái dùng

| Khối | Lớp | Chủ | FPGA | ASIC | Tái dùng |
|---|---|---|---|---|---|
| Cảm biến / mô hình TX (`csi2_tx_model`, `bow_dphy_tx`) | L0 | nhà cung cấp cảm biến; mô hình: DV | IMX219, IMX274; `bow_dphy_tx` trên Huins (bước 8, tuỳ chọn) | cảm biến đích | mô hình dùng cho cả hai |
| AFE | L1 | analog | `bow_dphy_io_xusp`, `bow_dphy_io_versal` (primitive AMD) + `bow_dphy_dly_xusp`, `bow_dphy_dly_xphy` (logic adapter, không có primitive) | macro analog cứng (.lib, .lef, mô hình hành vi) | chỉ giao diện |
| Giao diện AFE | L1/L2 | analog và PHY số cùng ký | adapter hiện thực | macro hiện thực | tên, độ rộng, ý nghĩa: 100 % |
| `bow_dphy_rx` | L2 | PHY số | cùng RTL | cùng RTL, std cell | 100 % |
| PPI (`bow_ppi_pkg`) | L2/L3 | PHY số + controller | cùng | cùng | 100 % |
| `bow_csi2rx` | L3 | controller | cùng RTL | cùng RTL | 100 % |
| `bow_mipi_rx` | tích hợp | SoC | Bow32 | thay bằng wrapper của SoC (APB4) | tuỳ SoC |
| Driver `bow_dphy_rx.c`, `bow_csi2rx.c` | SW | SW | cùng | cùng | 100 % |
| Cell phụ thuộc công nghệ (`bow_sync`, `bow_rst_sync`, `bow_cdc_pulse`, `bow_fifo_async`, `bow_ram_sdp`, clock gate, mux clock test) | — | SoC | RTL / primitive FPGA | cell thư viện, SRAM macro | qua wrapper |

### 2.4 Mã hiện nay đi về đâu

| Hiện nay | Ở đâu | Sau khi tách |
|---|---|---|
| `bow_dphy_lp` × (1 + `Lanes`): lọc LP, máy LP data/clock, SETTLE, `hs_en`, `byte_ce` | `bow_csi2rx.sv:273-317` (miền video) | `bow_dphy_rx` (miền lp) |
| phát hiện cạnh byte clock (`clk_tog`) | `bow_csi2rx.sv:319-342` | `bow_dphy_rx` |
| `byte_rst_o` (RST của ISERDES mỗi lần cổng mở) | `bow_csi2rx.sv:171-177` | `des_rst` của giao diện AFE (= ¬`clk_gate_en`, miền lp); adapter UltraScale+ giữ bộ đồng bộ nhả theo byte clock cho `RST` của `ISERDESE3` |
| thanh ghi `rx_data`/`rx_valid`, đồng bộ `arm` | `bow_csi2rx.sv:411-426`, `:451-458` | `bow_dphy_rx` (miền byte) |
| `bow_dphy_align` × `Lanes` | `bow_csi2rx.sv:463-477` | `bow_dphy_rx`, ra PPI |
| nạp tap `g_dly_byte` / `g_dly_vid` (`DlyVid`) | `bow_csi2rx.sv:655-792` | adapter AFE (FPGA: `bow_dphy_dly_xusp` / `bow_dphy_dly_xphy`, không có primitive, test bằng Verilator); trên ASIC: mã tĩnh, không có giao thức nạp |
| đồng hồ đo byte clock | `bow_csi2rx.sv:794-817`, `bow_csi2rx_regs.sv:487-516` | `bow_dphy_rx` |
| RAW (64 word thô mỗi lane) | `bow_csi2_capture.sv:153-230` | `bow_dphy_rx` |
| `PHY_CFG`, phần PHY của `STATUS`, `DLYn`, `BYTECLK`, `CNT_BURST*`, `CNT_MISC[23:0]`, `CTRL.CLK_FORCE`, `INFO[5]` | `bow_csi2rx_regs.sv` | thanh ghi D-PHY ở `0xC00` của cửa sổ `CSI2RX` (mục 6.3; không có alias) |
| núm PA4 (`reinit_i`), PA5 (`burst_rst_en_i`), trạng thái PB6/PB7 | GPIO của top camera Huins | `AFE_CTRL.PD`, `des_rst` luôn bật, `AFE_STATUS` của D-PHY |
| ghép lane, packet, unpack, FIFO, đầu ra, LOG, phần còn lại của thanh ghi | `bow_csi2rx` | giữ trong controller |

## 3. Giao diện AFE

### 3.1 Nguyên tắc

- **Ranh giới nằm dưới PPI, ngay sau deserializer.** AFE đưa word song song chưa căn byte, byte
  clock lấy từ lane clock và mức LP thô; mọi quyết định giao thức (khi nào bật termination, mở
  cổng clock, tìm sync, đổi delay) do phần số làm. Đây là cách Lattice tách khi bỏ CIL (logic
  điều khiển lane) của hard D-PHY [S8] và là ranh giới raw của Bow32 hiện nay, được làm sạch. PHY
  cứng thương mại thường đưa PPI ra ngoài, giữ CIL bên trong [S14][S16]; Bow32 đặt ranh giới thấp
  hơn vì nó sở hữu cả hai phía, và phần số thì kiểm được trên FPGA còn macro analog thì không.
- **Điều khiển là mức từ flop.** Mọi tín hiệu từ phần số sang AFE ra thẳng từ flop (không logic
  tổ hợp sau flop) và đổi chậm so với HS: AFE coi chúng là bất đồng bộ. Mọi đầu ra của AFE là
  bất đồng bộ (phần số đồng bộ chúng), trừ nhóm đồng bộ theo `hs_byte_clk`: `hs_data`,
  `hs_valid`, `clk_hs_samp`, `mon_data` và, theo chiều ngược lại, `tst_data`. Nhóm này có timing
  bằng số ở mục 3.3.
- **Không có gì của FPGA.** Không có tap của IDELAY, giao thức nạp của XPHY hay FIFO bắt buộc: các
  thứ đó nằm trong adapter (mục 3.7).
- **Tham số:** `Lanes` (1…8 data lane), `DesW` (8; 16 tuỳ chọn), `DlyW` (≤ 10 bit), `TrimW` (≤ 64),
  `StatW` (≤ 8). Trong RTL của `bow_dphy_rx` các cổng có tiền tố `afe_` và hậu tố `_i`/`_o` (ví dụ
  `afe_hs_data_i`); macro AFE dùng đúng tên trong bảng. `[l]` = data lane l; tiền tố `clk_` = lane
  clock. "Miền lp" = `lp_clk_i` của `bow_dphy_rx` (mục 4.11).

### 3.2 Tín hiệu

**A. HS: dữ liệu và byte clock**

| Tín hiệu | Rộng | Hướng | Miền | Mô tả |
|---|---|---|---|---|
| `hs_byte_clk` | 1 | AFE → số | (clock) | byte clock lấy từ lane clock: clock DDR ÷ 4 khi `DesW` = 8 (= bit rate / 8, 312,5 MHz ở 2,5 Gbit/s), ÷ 8 khi `DesW` = 16. Chạy khi `clk_gate_en` = 1 và lane clock đang chạy; không bao giờ có xung ngắn (runt). `des_rst` không bao giờ dừng hay reset nó. Một clock chung cho mọi data lane |
| `hs_data[l]` | `DesW` | AFE → số | `hs_byte_clk` | word giải nối tiếp của data lane l; bit 0 = bit nhận trước trên dây (D-PHY gửi LSB trước); ranh giới byte bất kỳ (phần số tìm sync). AFE đổi nó ở cạnh xuống của `hs_byte_clk`, phần số bắt ở cạnh lên kế tiếp (nửa chu kỳ, số ở mục 3.3). Khi `hsrx_en[l]` = 0 giá trị không xác định (word cũ, rác): phần số không dựa vào nó |
| `hs_valid[l]` | 1 | AFE → số | `hs_byte_clk` | 1 = `hs_data[l]` là word mới; timing như `hs_data`. Chỉ AFE có FIFO bên trong (adapter Versal) dùng; macro ASIC không có FIFO nối 1 |
| `clk_gate_en` | 1 | số → AFE | lp, mức | mở cổng byte clock. AFE gate không glitch với enable bất đồng bộ: enable được đồng bộ lại trong AFE theo chính clock bị gate (như `CE_TYPE SYNC` của `BUFGCE_DIV` ở adapter UltraScale+), nên khi lane clock tĩnh, thay đổi có hiệu lực ở cạnh kế tiếp. Phần số chỉ đổi nó khi lane clock tĩnh (HS-0 của CLK-ZERO hoặc CLK-TRAIL) hoặc bộ thu HS lane clock tắt, trừ hai trường hợp: `CLK_CONT` và `Enable` = 0 (mục 3.6) |
| `des_rst` | 1 | số → AFE | lp, mức | flop miền lp, luôn bằng ¬`clk_gate_en` (trừ bit thử `CTRL.DES_RST_DIS`): bật khi cổng đóng, nhả cùng cạnh lp với lúc mở cổng, khi lane clock còn ở HS-0 tĩnh. Chỉ xoá đường dữ liệu của AFE (thanh ghi deserializer, FIFO); **không bao giờ** reset hay dừng bộ chia sinh `hs_byte_clk`, nếu không byte clock không chạy lại và reset không bao giờ nhả. AFE cần nhả đồng bộ thì tự đồng bộ theo clock của nó (các word đó được phép là rác, mục 3.3). Đường thu bắt đầu từ trạng thái xác định mỗi lần cổng mở lại, tức một lần mỗi giai đoạn HS của lane clock: mỗi frame với IMX219 / IMX274 (mục 7.1). Phần số không giả định có reset giữa các burst dữ liệu. AFE không có trạng thái cần xoá thì bỏ qua |
| `clk_hs_samp` | `DesW` | AFE → số | `hs_byte_clk` | tuỳ chọn, chẩn đoán: mẫu của chính lane clock (`clk_q_o` của adapter Versal: `55`/`aa` khi clock chạy); timing như `hs_data` |
| `clk_act` | 1 | AFE → số | bất đồng bộ | bộ phát hiện "lane clock đang chạy" trong AFE (ví dụ one-shot kích lại theo mọi cạnh). **Bắt buộc với macro ASIC**, vì mục tiêu 80 Mbit/s (mục 1.2); adapter FPGA không có (phát hiện qua cạnh byte clock, chỉ đủ trên ~350 Mbit/s). Timing ở mục 3.3; phần số dùng nó thay cho flop đảo (mục 4.3) |

**B. LP**

| Tín hiệu | Rộng | Hướng | Miền | Mô tả |
|---|---|---|---|---|
| `lp[l]`, `clk_lp` | 2 = {P, N} | AFE → số | bất đồng bộ | đầu ra hai bộ so sánh LP của mỗi lane (ngưỡng LP có hysteresis, gai ngắn đã lọc trong analog). Trong HS cả hai thấy 0 (LP-00). Phần số đồng bộ 2 flop rồi lọc `LP_FILTER` chu kỳ |
| `lprx_en[l]`, `clk_lprx_en` | 1 | số → AFE | lp, mức | bật bộ thu LP. Bật cho mọi lane của bản build khi `AFE_CTRL.PD` = 0, bất kể `Enable` và `LANE_EN` (đọc mức LP khi bộ thu tắt: `LANE_LP`, bring-up), kể cả ULPS (phải thấy chuỗi thoát); tắt khi `pd` = 1 |

**C. Bộ thu HS và termination**

| Tín hiệu | Rộng | Hướng | Miền | Mô tả |
|---|---|---|---|---|
| `hsrx_en[l]`, `clk_hsrx_en` | 1 | số → AFE | lp, mức | bật bộ khuếch đại/so sánh HS và sampler. Bật cùng lúc hoặc trước `term_en` (`CTRL.HSRX_EARLY`: từ HS-Rqst, cho AFE có bộ thu HS khởi động chậm). Khi `clk_hsrx_en` = 0, đầu ra bộ thu HS lane clock giữ mức tĩnh, không tạo cạnh vào bộ chia và cổng |
| `term_en[l]`, `clk_term_en` | 1 | số → AFE | lp, mức | đóng termination vi sai ~100 Ω. Data lane: bật khi phần số thấy LP-00 sau LP-01, tắt khi thấy LP-11. Lane clock: bật như data lane, tắt khi phát hiện mất clock hoặc thấy LP-11. Yêu cầu thời gian ở mục 3.4 |

**D. Delay / deskew**

| Tín hiệu | Rộng | Hướng | Miền | Mô tả |
|---|---|---|---|---|
| `dly_code[l]` | `DlyW` | số → AFE | lp, tĩnh | mã delay của data lane l (trễ dữ liệu so với clock); lớn hơn = trễ hơn. Mã tĩnh, không có xung nạp; quy tắc đổi mã ở mục 3.5 |
| `dly_own[l]` | 1 | số → AFE | lp, mức | 1: lane dùng `dly_code[l]`; 0: lane dùng giá trị của AFE (mặc định sau reset, hoặc kết quả tự hiệu chỉnh có bám VT như BISC của XPHY). Macro ASIC phải đổi được 1 → 0 từng lane. Khi `ready` = 0 AFE bỏ qua `dly_code`/`dly_own`; phần số hạ mọi `dly_own` khi `ready` xuống (mục 3.5) |
| `dly_q[l]` | `DlyW` | AFE → số | bất đồng bộ, gần tĩnh | mã đang có hiệu lực: bằng `dly_code[l]` khi đã áp xong (`dly_own` = 1); khi `dly_own` = 0 là giá trị của AFE (có thể đổi theo VT). Phần số chỉ tin khi hai lần đọc liên tiếp giống nhau |
| `clk_dly_code`, `clk_dly_own`, `clk_dly_q` | như trên | như trên | như trên | tuỳ chọn: delay của lane clock (dời mọi lane cùng lúc, cho phép chỉnh "âm" so với data) |
| `mon_en[l]`, `mon_code[l]`, `mon_data[l]` | 1, `DlyW`, `DesW` | số → AFE (2 cái đầu), AFE → số | lp; `mon_data`: `hs_byte_clk` | tuỳ chọn (v3): sampler giám sát thứ hai với delay riêng; phần số so `mon_data` với `hs_data` để thấy mép eye mà không gây lỗi (mục 7.2); timing của `mon_data` như `hs_data` |

**E. Nguồn, hiệu chỉnh nội, trạng thái**

| Tín hiệu | Rộng | Hướng | Miền | Mô tả |
|---|---|---|---|---|
| `pd` | 1 | số → AFE | lp, mức | tắt toàn AFE (bias, tham chiếu, mọi lane). Chỉ đến từ `AFE_CTRL.PD` hoặc reset, không bao giờ từ `Enable` (mục 3.6). Khi `pd` = 1 mọi đầu ra của AFE bị kẹp về 0 (cách ly theo power intent, mục 9.4) |
| `lane_pd[l]`, `clk_lane_pd` | 1 | số → AFE | lp, mức | tắt phần HS của một lane: lane ngoài `LANE_EN`, hoặc lane ở ULPS (bật lại ngay ở LP-10 đầu tiên của chuỗi thoát, mục 3.6); bộ thu LP theo `lprx_en` |
| `ready` | 1 | AFE → số | bất đồng bộ | AFE sẵn sàng: bias ổn định, hiệu chỉnh nội xong. Versal: XPLL khoá + BISC xong (`phy_rdy_o`); UltraScale+: 1 |
| `cal_start` | 1 | số → AFE | lp, xung ≥ 4 chu kỳ | chạy lại hiệu chỉnh nội của AFE (offset bộ so sánh, trim termination, DLL của delay line) |
| `cal_done`, `cal_err` | 1 | AFE → số | bất đồng bộ | kết quả của hiệu chỉnh nội |
| `trim` | `TrimW` | số → AFE | lp, tĩnh | bit trim / cấu hình analog, ý nghĩa do đội analog định nghĩa (termination, offset, bias…); nằm ở `AFE_TRIM0/1`, nạp từ OTP/eFuse của SoC nếu có |
| `status` | `StatW` | AFE → số | bất đồng bộ | trạng thái thô cho chẩn đoán. Versal: {PHY_RDY mọi nibble, DLY_RDY mọi nibble, LOCKED_FB, LOCKED} (= PB6/PB7 hiện nay) |

**F. Test**

| Tín hiệu | Rộng | Hướng | Miền | Mô tả |
|---|---|---|---|---|
| `tst_mode` | 3 | số → AFE | lp, tĩnh | 0 bình thường; 1 loopback nội: AFE thay tín hiệu ở chân bằng chuỗi test (`tst_data`, `tst_clk`); 2 quan sát DC: `hs_raw` theo đầu ra bộ so sánh HS; 3–7 do đội analog định nghĩa |
| `tst_clk` | 1 | SoC → AFE | (clock) | clock bit (DDR) cho loopback nội (PLL test của SoC hoặc ATE); trong loopback, `hs_byte_clk` lấy từ nó. Dải: 50 MHz … nửa tốc độ lane tối đa (1,25 GHz); test sản xuất mặc định ở tốc độ giảm (`tst_clk` ≤ 500 MHz, ≤ 1 Gbit/s), tốc độ thật chỉ khi SoC có PLL đủ nhanh **[ĐỀ XUẤT]** |
| `tst_data[l]` | `DesW` | số → AFE | `hs_byte_clk` | word của bộ sinh PRBS phía số: phần số phát ở cạnh lên, AFE bắt ở cạnh xuống kế tiếp tại chân của nó (mục 3.3); AFE nối tiếp hoá và đưa vào đường thu ngay sau chân |
| `hs_raw[l]`, `clk_hs_raw` | 1 | AFE → số | bất đồng bộ | đầu ra bộ so sánh HS trước sampler, chỉ để kiểm DC / ATE (`tst_mode` = 2) |
| `atb_sel` | 8 | số → AFE | lp, tĩnh | chọn nút analog ra bus test analog |
| `scan_mode` | 1 | SoC → AFE, số | tĩnh | AFE giữ điều khiển nội ở trạng thái an toàn; phần số đổi clock miền byte sang clock test (mục 9.2) |

### 3.3 Yêu cầu thời gian phía AFE

| Ký hiệu | Yêu cầu [ĐỀ XUẤT] | Vì sao |
|---|---|---|
| t_LPRX | trễ bộ thu LP (chân → `lp`) ≤ 10 ns cả hai cạnh | ngân sách T_D-TERM-EN (mục 3.4); trên FPGA ~8 ns |
| Lọc gai LP | AFE bỏ qua gai ngắn trên đường LP theo yêu cầu lọc gai của đặc tả (đội analog lấy con số từ bản có bản quyền, tức cần tư cách thành viên MIPI, mục 9.7) | phần số chỉ cần lọc ít (`LP_FILTER` = 1) |
| t_TON, t_TOFF | termination có hiệu lực / mở ≤ 5 ns sau khi `term_en` đổi | ngân sách T_D-TERM-EN |
| t_HSRX | bộ thu HS dùng được ≤ 40 ns sau `hsrx_en` | phải xong trước khi hết T_HS-SETTLE tối thiểu (85 ns + 6 UI [S10]) |
| t_LPD | phần HS của lane dùng được ≤ 100 µs sau `lane_pd` 1 → 0 | thoát ULPS: phần HS bật ở LP-10 đầu tiên, còn ≥ T_WAKEUP (≥ 1 ms [S10]) tới LP-11; bật lane qua `LANE_EN` |
| `hs_byte_clk` | ≤ 312,5 MHz (`DesW` 8) hoặc ≤ 156,25 MHz (16); duty 45–55 % ở chân macro; không runt khi gate; chân lái gốc cây clock của phần số, chuyển mạch ≤ 80 ps **[ĐỀ XUẤT, theo node]** | timing của phần số |
| Nhóm đồng bộ | `hs_data`, `hs_valid`, `clk_hs_samp`, `mon_data`, `tst_data`: bảng *Đường dữ liệu đồng bộ* ngay dưới | đường đồng bộ duy nhất giữa hai đội |
| `clk_act` | lên ≤ 10 ns sau cạnh đầu của lane clock; xuống 20–40 ns sau cạnh cuối; không xuống giữa hai cạnh khi UI ≤ 12,5 ns (80 Mbit/s) | đóng cổng trước khi hết T_CLK-TRAIL (≥ 60 ns) và tắt bộ thu trong T_CLK-MISS (≤ 60 ns) [S10] ở mọi tốc độ: 40 ns + 2 flop đồng bộ + 1 flop FSM + ≤ 1 chu kỳ lấy mẫu = 56 ns ở `lp_clk` 250 MHz |
| Bộ thu HS lane clock khi chân về mức LP | đầu ra tĩnh (squelch), không dao động khi lane rời HS-0 về LP-11 | lối ra dự phòng `Exit` (LP-11 khi cổng còn mở) và khi `CLK_MISS_OFF` = 0: cổng đồng bộ chỉ đổi ở cạnh kế tiếp, nên dao động ở đây sẽ thành xung ngắn trên `hs_byte_clk` |
| Lệch clock–data trong AFE | ≤ 0,15 UI ở 1,5 Gbit/s khi mã delay ở giữa tầm | dưới 1,5 Gbit/s cảm biến thường không gửi burst deskew [S9][S14][S20]: phải chạy được ở mã mặc định |
| Delay line | đơn điệu; tầm ≥ 1 UI ở 1,5 Gbit/s (667 ps) + lệch tĩnh; bước ≤ UI/32 ở 2,5 Gbit/s (12,5 ps); áp mã mới ≤ 50 ns; khai rõ bước ±1 có không glitch hay không | eye walk, deskew, bám VT (mục 7) |
| `ready` | ≤ 100 µs sau khi nhả `pd` | cỡ T_INIT [S3][S10]; lâu hơn thì driver chờ (như `PHY_RDY` hôm nay) |
| Word đầu sau khi mở cổng | ≤ 2 word đầu (cổng đồng bộ, `des_rst` nhả đồng bộ trong AFE) được phép là rác; từ word thứ 3 phải đúng | aligner chịu rác trước SoT: HS-ZERO dài hơn nhiều |

**Đường dữ liệu đồng bộ (miền `hs_byte_clk`).** Đây là đường đồng bộ duy nhất giữa đội analog và
đội số, ở 312,5 MHz (3,2 ns). Bow32 chọn **phát ở cạnh xuống, bắt ở cạnh lên** (nửa chu kỳ): ngân
sách setup và hold đều cỡ T/2, nên trễ cây clock của phần số tới flop bắt (L_tree) không ăn hết
lề hold như khi phát và bắt cùng một cạnh. Tầng bắt đầu tiên (flop word mỗi lane, `hs_valid`, và
flop phát `tst_data`) thuộc `bow_dphy_rx` (đội số), được đặt sát macro (vùng đặt cell trong
floorplan) trên một nhánh riêng, ngắn của cây byte clock; từ tầng đó trở đi miền byte là đường
đồng bộ thường. Mọi số dưới đây là **[ĐỀ XUẤT]**, đội analog và đội số cùng chốt theo node.

| Ký hiệu | Giá trị | Ghi chú |
|---|---|---|
| Cạnh | AFE phát `hs_data`, `hs_valid`, `clk_hs_samp`, `mon_data` ở cạnh xuống của `hs_byte_clk` tại chân macro; phần số bắt ở cạnh lên kế tiếp | khai trong .lib của macro |
| t_CO | 0,05 … 0,6 ns sau cạnh xuống, ở tải dưới đây | |
| Tải, chuyển mạch | ≤ 15 fF mỗi chân dữ liệu; chuyển mạch ≤ 100 ps | một chân D + dây ≤ 50 µm |
| L_tree | 0 … 0,5 ns, từ chân `hs_byte_clk` của macro tới chân clock của flop bắt | nhánh riêng của cây byte clock |
| Dây dữ liệu | ≤ 0,15 ns: flop bắt cách chân macro ≤ 50 µm | ràng buộc đặt cell |
| Kiểm ở T = 3,2 ns, duty 45–55 % (T_high, T_low ≥ 1,44 ns) | setup: t_CO,max + dây + t_su ≤ T_low + L_tree,min, tức 0,6 + 0,15 + 0,1 = 0,85 ≤ 1,44 ns; hold: L_tree,max + t_h ≤ T_high + t_CO,min, tức 0,5 + 0,05 = 0,55 ≤ 1,49 ns | lề ~0,6 ns (setup) và ~0,9 ns (hold) cho jitter và OCV |
| Chiều ngược (`tst_data`) | phần số phát ở cạnh lên tại flop (sau L_tree), AFE bắt ở cạnh xuống kế tiếp tại chân: L_tree,max + t_cq + dây + t_su,AFE ≤ T_high | ở tốc độ giảm của loopback còn dư nhiều |
| Phương án khác | phát và bắt cùng cạnh lên: t_CO,min ≥ L_tree,max + t_h và t_CO,max ≤ T − L_tree,min − t_su | chỉ khi đội analog muốn; macro phải có trễ tối thiểu bên trong |

### 3.4 Ngân sách bật termination

Từ LP-00 ở chân tới termination có hiệu lực:

```
t_LPRX + (3 + F) · T_lp (+ tới 1 · T_lp do pha lấy mẫu) + t_TON  ≤  T_D-TERM-EN = 35 ns + 4 UI  [S10]
3 = 2 flop đồng bộ + 1 flop của máy trạng thái; F = LP_FILTER; lane clock: ≤ T_CLK-TERM-EN = 38 ns [S10]
```

| `lp_clk` | F | phần số, tốt nhất (xấu nhất) | + t_LPRX 8 ns + t_TON 3 ns | so với 36,6 ns (2,5 Gbit/s) |
|---|---|---|---|---|
| 200 MHz (FPGA hôm nay) | 2 | 25 (30) ns | 36 (41) ns | sát / vượt ở tốc độ cao; ~34 ns hôm nay ở 912 Mbit/s ([csi2rx.md](csi2rx.md)) |
| 250 MHz | 2 | 20 (24) ns | 31 (35) ns | sát |
| 250 MHz | 1 | 16 (20) ns | 27 (31) ns | đạt |
| 400 MHz | 2 | 12,5 (15) ns | 23,5 (26) ns | đạt |

Hai cách giữ ngân sách: (a) **mặc định**: `lp_clk` ≥ 250 MHz và `LP_FILTER` = 1, AFE lọc gai bằng
analog; (b) **termination tự động** (tham số `AfeTermAuto`): phần số đặt `term_en` ngay ở HS-Rqst
với nghĩa "cho phép", AFE tự đóng termination khi bộ thu LP của chính nó thấy LP-00; không phụ
thuộc `lp_clk` nhưng chuyển việc lọc gai sang analog (câu hỏi mở Q2). Lattice ghi các tín hiệu
termination của họ bật từ LP-01 [S8], sớm hơn mốc LP-00 của Bow32; I/O áp chúng thế nào thì tài
liệu không nói **[CHƯA CHẮC]**.

Lane clock còn có T_CLK-MISS ≤ 60 ns [S10]: thời gian để phía thu thấy clock đã dừng và tắt bộ
thu HS của lane clock. Hôm nay cổng đóng sau ~30–45 ns nhưng bộ thu HS lane clock còn bật tới
LP-11 (trạng thái `Trail` của `bow_dphy_lp`). `bow_dphy_rx` hạ `clk_hsrx_en`/`clk_term_en` ngay khi
phát hiện mất clock (từ v1.x, khi `CTRL.CLK_MISS_OFF` = 1; bắt buộc với ASIC, mục 9.7): bộ thu tắt
khi lane còn ở HS-0, nên bộ so sánh không dao động lúc lane chuyển về LP-11. Việc termination có
phải mở cùng lúc hay không cần một thành viên kiểm ở đặc tả **[CHƯA CHẮC]**.

### 3.5 Giao thức delay

1. `dly_code[l]` và `dly_own[l]` là mức tĩnh. AFE áp giá trị mới trong ≤ 50 ns; `dly_q[l]` cho
   biết khi nào xong. Không có xung nạp, không có bộ đếm yêu cầu.
2. Phần số chỉ đổi mã của một lane khi (a) lane không ở HS (`hsrx_en[l]` = 0), hoặc (b) burst đang
   chạy là burst được phép hỏng (eye walk, burst deskew), hoặc (c) từng bước ±1 cách nhau ≥ 50 ns
   khi AFE khai bước không glitch (`INFO[29]`, mục 4.10).
3. `dly_own` 0 → 1: AFE chuyển sang mã của phần số (Versal: tắt bám VT của slice rồi nạp).
   1 → 0: AFE quay về giá trị của nó; macro ASIC phải làm được việc này từng lane
   (`INFO[30]` = 1). Adapter Versal không làm được từng lane (`INFO[30]` = 0, `CMD.DLY_REL` bị bỏ
   qua): chỉ khởi động lại AFE (`CMD.AFE_CAL` hoặc `AFE_CTRL.PD`) mới đưa lane về trễ BISC + bám
   VT, và việc đó hạ `ready` nên xoá OWN của mọi lane cùng lúc (hạn chế, mục 3.7).
4. So với `DlyVid` = 1 hôm nay ("mỗi lần ghi `DLYn` là một lần nạp"): nạp khi mã đổi hoặc
   `dly_own` lên. Khi `ready` xuống (khởi động lại, mất khoá XPLL) AFE mất mã đã nạp và phần số
   xoá mọi OWN, nên lần ghi sau, kể cả cùng mã, tạo lại cạnh lên của `dly_own` và nạp lại. Khi
   `ready` vẫn 1, ghi lại đúng mã đang dùng không cần nạp.
5. Một chủ cho mỗi lane. Phần mềm (`DLYn`) và bộ máy deskew (mục 4.6) ghi cùng một thanh ghi mã
   ở miền lp; lần ghi của bộ máy cũng đặt OWN = 1. Phần mềm ghi `DLYn` khi bộ máy đang giữ delay
   (`DSK_CTRL.MODE` ≠ 0 hoặc `CMD.DSK_RUN` còn chờ) thì bộ máy dừng trước (`MODE` đọc 0,
   `DSK_STATUS.ABORT` = 1), rồi lần ghi mới được áp: eye walk không bao giờ giành mã với chế độ
   bám.

### 3.6 Trình tự

```
reset:      pd = AfePdRst, lprx_en = ¬pd, hsrx_en = term_en = 0, clk_gate_en = 0, des_rst = 1,
            dly_own = 0, lane_pd = 1
AFE bật:    AFE_CTRL.PD = 0: pd = 0, lprx_en = 1 (mọi lane của bản build) → chờ ready (≤ 100 µs)
            → lane_pd = 0 (lane trong LANE_EN); ready lên: T_INIT phải được đếm (một lần)
Enable = 1: FSM: WaitStop → LP-11 (giữ ≥ T_INIT nếu còn phải đếm) → Stop
burst:      lane clock: LP-01 → LP-00: clk_hsrx_en, clk_term_en → CLK_SETTLE → clk_gate_en = 1,
                        des_rst = 0 (lane clock còn ở HS-0 tĩnh) → clock chạy
            data lane:  LP-01 [hsrx_en nếu HSRX_EARLY] → LP-00: hsrx_en, term_en → SETTLE → dò sync
                        → dữ liệu → LP-11: hsrx_en = term_en = 0
            lane clock: mất clock (cạnh byte clock hoặc clk_act) → clk_gate_en = 0, des_rst = 1;
                        CLK_MISS_OFF = 1: clk_hsrx_en = clk_term_en = 0 ngay → LP-11 → Stop
ULPS:       lệnh ULPS: hsrx_en = term_en = 0, lane_pd = 1 (lprx_en vẫn 1) → LP-10 (thức dậy):
            lane_pd = 0 ngay (còn ≥ T_WAKEUP tới LP-11) → LP-11 → Stop
Enable = 0: clk_gate_en = 0, des_rst = 1 ngay; hsrx/term = 0 sau 8 chu kỳ (như hôm nay); FSM về Off.
            pd, lprx_en, lane_pd, dly_code, dly_own giữ nguyên: stop/start không đụng tới AFE
AFE tắt:    AFE_CTRL.PD = 1 (bow_dphy_rx_power(0), sau Enable = 0): lane_pd = 1, lprx_en = 0, pd = 1;
            ready xuống → mọi OWN xoá
```

`AfePdRst` (tham số): 1 cho ASIC (an toàn khi bật nguồn, driver bật AFE), 0 cho FPGA (XPLL và BISC
chạy ngay sau khi nạp bitstream, như hôm nay).

**Stop/start không chạy lại hiệu chỉnh của AFE.** `CTRL.PHY_EN` của controller lái `Enable` của
PPI và bị xoá ở mỗi lần `start`/`stop` (`rx_off()`, `bow_csi2rx.c:81-84`). Nếu `Enable` = 0 kéo
theo `pd`, adapter Versal sẽ khởi động lại XPLL + XPHY ở mỗi lần dừng (`pd` = `reinit_i`): mọi lane
về trễ BISC (~11 % dòng lỗi CRC trên bo) và tap đã hiệu chỉnh mất. Vì vậy `Enable` chỉ đóng cổng,
tắt bộ thu HS và đỗ FSM; `pd` chỉ đến từ `AFE_CTRL.PD`.

**`Enable` = 0 khi lane clock còn chạy.** Cổng đồng bộ của AFE chịu được, nhưng driver vẫn tránh:
`bow_csi2rx_stop()` chờ FSM lane clock đóng cổng (`RxClkActiveHS` = 0) rồi mới hạ `Enable`, như
hôm nay nó chờ `STATUS.CE`. Với `CLK_CONT` cổng mở và đóng khi clock đang chạy: chỉ AFE có cổng
đồng bộ mới hỗ trợ.

### 3.7 `bow_dphy_io_xusp` và `bow_dphy_io_versal` thành adapter AFE

Hai module giữ tên file và tên instance mà XDC dùng (`u_hs_bufg`, `u_byte_bufg`, cell BLI), nhận
thêm logic adapter chuyển từ `bow_csi2rx` (nạp tap, `des_rst`) và đổi cổng sang tên của giao diện
AFE. Logic fabric của adapter (nạp khi mã đổi, trình tự nạp của XPHY, `des_rst`) nằm trong hai
module không có primitive, `bow_dphy_dly_xusp` và `bow_dphy_dly_xphy`, để Verilator (CI) vẫn
kiểm được nó; chỉ phần primitive còn lại cần xsim. Cả hai adapter dựa trên `IBUFDS_DPHY` (bộ thu
HS và hai bộ thu LP trên cùng cặp chân, chân tắt HS riêng [S7]).

| Tín hiệu AFE | `bow_dphy_io_xusp` (KV260, UltraScale+) | `bow_dphy_io_versal` (Huins, Versal) |
|---|---|---|
| `hs_byte_clk` | `BUFGCE_DIV` /4 từ `HSRX_O` của lane clock | `BUFGCE` của `FIFO_WR_CLK` nibble strobe |
| `hs_data[l]` | `Q` của `ISERDESE3` 1:8 (qua `IDELAYE3`) | `Q` của XPHY qua FIFO RX + flop BLI, sắp lại bit (`xphy_byte`) |
| `hs_valid[l]` | `'1` | word đọc được từ FIFO (có khe) |
| `clk_gate_en` | CE chung của hai `BUFGCE_DIV` (/1 và /4, `CE_TYPE SYNC`) | CE của `BUFGCE` (`CE_TYPE SYNC`) |
| `des_rst` | `RST` của `ISERDESE3`, adapter nhả 2 cạnh byte clock sau khi clock chạy lại (bắt buộc: căn bộ chia /4 bên trong ISERDES; không treo vì `BUFGCE_DIV` không bị reset) | `RX_RST` các slice dùng, tính ở miền `ctrl_clk` từ `clk_gate_en` như `burst_rst_q` hôm nay (`bow_dphy_io_versal.sv:502-507`): bật khi cổng đóng, nhả 1 chu kỳ sau khi mở, lúc lane clock còn tĩnh (= PA5 = 1). Không nhả theo cạnh byte clock: giữ `RX_RST` của slice strobe có thể dừng chính `FIFO_WR_CLK` **[CHƯA CHẮC]** |
| `clk_act` | — (mất clock thấy qua cạnh byte clock) | — (như bên trái) |
| `lp[l]`, `clk_lp` | `LPRX_O_P/N` của `IBUFDS_DPHY` | như bên trái |
| `lprx_en` | không mô hình (`LPRX_DISABLE` = 0) | như bên trái |
| `hsrx_en` ∨ `term_en` | `~HSRX_DISABLE` (một chân cho cả bộ thu HS và termination) | như bên trái |
| `dly_code`/`dly_own`/`dly_q` | `IDELAYE3` `CNTVALUEIN`/`LOAD`/`CNTVALUEOUT`: `bow_dphy_dly_xusp` nạp khi mã đổi, ở miền byte (chỉ khi byte clock chạy: burst sau); `dly_own` 1 → 0 từng lane: tap 0 (`INFO[30]` = 1) | XPHY `CNTVALUEIN`/`LD`/`CNTVALUEOUT` ở `CTRL_CLK`: `bow_dphy_dly_xphy`: `dly_own` lên → `RX_EN_VTC` = 0, chờ `VtcWait`, nạp; lần nạp cách nhau ≥ `LdGap`. `dly_own` 1 → 0 từng lane: không làm được (`INFO[30]` = 0); mọi lane cùng về tap BISC + bám VT chỉ qua `pd` / `cal_start` |
| `pd` | — (không tắt được; adapter giữ `HSRX_DISABLE`) | `reinit_i` (giữ ở reset khởi động: XPLL, XPHY); chỉ từ `AFE_CTRL.PD`, nên stop/start không chạy lại BISC |
| `ready` | 1 | `phy_rdy_o` (XPLL khoá + BISC xong + PHY_RDY mọi nibble) |
| `cal_start` | — | xung `reinit_i` (XPLL, BISC, VT chạy lại; tap đã nạp bị bỏ) |
| `status` | 0 | `phy_status_o` |
| `clk_hs_samp` | — | `clk_q_o` |
| `trim`, `tst_*`, `hs_raw`, `atb_sel`, `mon_*` | — | — |

**Những gì adapter FPGA không mô hình được** (kết quả trên FPGA ở các điểm này không nói gì về
ASIC):

1. Bật bộ thu HS và termination riêng: `IBUFDS_DPHY` chỉ có một chân `HSRX_DISABLE`; thời gian
   đóng/mở termination nằm trong primitive, không đo được: chỉ kiểm được phần số của T_D-TERM-EN.
2. Ngưỡng, hysteresis, lọc gai và công suất của bộ thu LP (luôn bật).
3. Power-down, tắt từng lane, tiết kiệm năng lượng ở ULPS, cách ly; thời gian `ready` của một AFE
   thật (bias, DLL).
4. Delay line: tap của `IDELAYE3` (2,7–4,7 ps, không VTC) và XPHY (512 tap ≥ 625 ps theo AM010 [S23],
   chưa đo trên silicon) khác delay line ASIC về bước, độ đơn điệu, glitch khi đổi mã giữa burst
   và trôi VT; `IDELAYE3` chỉ nạp được khi byte clock chạy.
5. Đường clock: byte clock đi qua bộ đệm clock toàn cục với trễ cỡ 1 UI, nên đường bắt dữ liệu
   không có static timing (vị trí tâm eye đổi theo route của mỗi lần build: [csi2rx.md](csi2rx.md));
   AFE ASIC có đường clock cục bộ, lệch được kiểm soát.
6. FIFO RX của XPHY (trễ 2–3 word, word cũ, khe `hs_valid`, quay vòng) và BISC chỉ có trên Versal;
   reset `ISERDESE3` mỗi lần cổng mở chỉ có trên UltraScale+. Glitch của strobe khi lane clock vào/ra HS
   là đặc điểm của FPGA.
7. Điểm móc test (loopback, ATB, quan sát DC, sampler giám sát): không có.
8. Tốc độ: hai adapter phủ 912 và 1440 Mbit/s đã chạy; 2,5 Gbit/s trên các FPGA này phụ thuộc
   thiết bị và speed grade **[CHƯA CHẮC]** và cần PPI 16 bit. Không có `clk_act`, nên phần dưới
   ~350 Mbit/s của mục tiêu ASIC không kiểm được trên bo.
9. Kênh: tín hiệu ở chân đi qua cáp, đầu nối và bo chuyển FMC; kênh của sản phẩm ASIC khác.

## 4. D-PHY số `bow_dphy_rx`

### 4.1 Sơ đồ và tham số

```
              miền lp (lp_clk_i, chạy liên tục)                                 │  miền byte (hs_byte_clk, bị gate)
                                                                                │
 AFE_CTRL.PD ─► pd, lprx_en (mọi lane của bản build) ───────────────────────────────► AFE
 lp[l]   ─► sync 2 flop + lọc ─► FSM data lane l ─── hsrx_en, term_en, lane_pd ─────► AFE
 clk_lp  ─► sync 2 flop + lọc ─► FSM lane clock ─── clk_*_en, clk_gate_en, des_rst ─► AFE
 clk_act ─► sync 2 flop ─────────────▲ clk_edge ◄── sync ◄──────────────────────┼── flop đảo ÷2^CLK_TOG_DIV
              timer: SETTLE, CLK_SETTLE, CLK_MISS, HS_TMO, T_INIT, ESC_TMO      │
              giải escape / ULPS (v1.x)                                         │
              Stopstate, RxClkActiveHS, ULPS, ErrControl* (v1.x: gray) ────► PPI│
              hs_active[l] (hết SETTLE) ──────── sync 2 flop ──────────────────►│ RxActiveHS ─► aligner[l] ◄── flop word, LANE_POL ◄── hs_data[l], hs_valid[l]
                                                                                │                   │
                                                                                │                   └─► LANE_MAP ─► RxDataHS, RxValidHS, RxSyncHS,
                                                                                │                                   ErrSotSyncHS, ErrSotHS, RxSkewCalHS ─► PPI
              sequencer deskew ◄──── kết quả từng điểm (req/ack) ◄──────────────┼── kiểm mẫu deskew[l] (không cần byte tham chiếu)
              DLYn + bộ máy deskew ──► dly_code[l], dly_own[l] ──► AFE          │  bộ kiểm PRBS[l], RAW, đồng hồ đo byte clock
 bus (clk_i) ◄─► bow_dphy_rx_regs: shadow + APPLY ─► miền lp; bộ đếm, trạng thái, ngắt ─► irq_o
```

| Tham số | Giá trị | Ý nghĩa |
|---|---|---|
| `Lanes` | 1…8 (v1: 1, 2, 4) | data lane vật lý |
| `PpiW` | 8 (16 ở v2) | độ rộng `RxDataHS` mỗi lane; v1: `DesW` = `PpiW` |
| `DlyW` | 1…10 (FPGA: 9) | độ rộng mã delay |
| `LpClkHz`, `BusClkHz` | Hz | `INFO[17:8]` (MHz của `lp_clk`, 10 bit), giá trị reset của timer khi `TimRstNs` = 1, kiểm quan hệ clock khi elaborate (như `CpuClkHz` hôm nay) |
| `TimRstNs` | bit | 0 (FPGA): giá trị reset của timer là số chu kỳ hôm nay (14/2/30/8/2^20), giữ đúng hành vi và kỳ vọng DV; 1 (ASIC): tính từ thời gian theo `LpClkHz` (mục 4.4) |
| `AfeKind` | 0 macro ASIC, 1 adapter UltraScale+, 2 adapter Versal, 3 mô hình | `INFO[7:5]` |
| `AfeSettleNs`, `AfeSettleUi`, `AfeTrailB` | ns, UI, byte | đích của `SETTLE` (phần ns và phần UI, từ LP-00 ở đầu ra bộ thu LP tới lúc bắt đầu dò sync) và byte thêm cuối burst do AFE: `INFO2`; driver tính `SETTLE` (mục 4.4) và `CTRL.EXTRA` của controller |
| `AfePdRst`, `AfeTermAuto`, `AfeDlyGf`, `AfeDlyRel`, `AfeClkAct` | bit | reset của `AFE_CTRL.PD`; termination tự động (mục 3.4); bước delay ±1 không glitch (`INFO[29]`); nhả delay từng lane được (`INFO[30]`); AFE có `clk_act` (`INFO[31]`) |
| `HasDsk`, `HasPrbs`, `HasUlps`, `HasRaw` | bit | khối tuỳ chọn (tổng hợp được bỏ đi) |

Thanh ghi và logic của lane 4–7 chỉ được sinh khi `Lanes` > 4: địa chỉ của chúng có sẵn trong bản
đồ (mục 4.10) nhưng đọc 0, cho tới khi có cảm biến cần 8 lane (Q11).

### 4.2 Máy trạng thái data lane

| Trạng thái | Nghĩa | `hsrx_en`, `term_en` | v1 | Thêm ở |
|---|---|---|---|---|
| `Off` | lane tắt (`Enable` = 0): chỉ FSM dừng; `pd`, `lprx_en`, `lane_pd`, mã delay giữ nguyên | 0 | ✓ | |
| `WaitStop` | chờ LP-11; LP-00 lúc này không phải lỗi (IMX274 standby LP-00) | 0 | ✓ | v1.x: lần đầu sau khi `ready` lên hoặc sau `CMD.REINIT` (không phải sau mỗi lần `Enable`) phải giữ LP-11 ≥ `T_INIT` mới sang `Stop` (PG435: `Stopstate` chỉ sau T_INIT [S4]) |
| `Stop` | LP-11, `Stopstate` = 1 | 0 | ✓ | |
| `HsRqst` | LP-01 | 0 (`hsrx_en` = 1 nếu `HSRX_EARLY`) | ✓ | `HSRX_EARLY`: v1.x |
| `Settle` | LP-00: bật bộ thu HS + termination, đếm `SETTLE` | 1 | ✓ | |
| `Hs` | dò sync / nhận; watchdog `HS_TMO` | 1 | ✓ (2^20 cố định) | `HS_TMO` lập trình được: v1.x |
| `EscRqst`, `EscGo`, `EscCmd` | LP-10 → LP-00 → LP-01 → LP-00, rồi giải 8 bit lệnh | 0 | — (LP-10 ở `Stop` là lỗi LP) | v1.x: chỉ lệnh ULPS; quá `ESC_TMO` mà chưa giải xong lệnh → lỗi ESC_TMO, về `WaitStop`; sau: LPDT, trigger |
| `Ulps` | lệnh ULPS: phần HS tắt, `UlpsActiveNot` = 0 | 0 | — | v1.x |
| `UlpsExit` | LP-10 kéo dài (thức dậy): `lane_pd` = 0 ngay, chờ LP-11 | 0 | — | v1.x |

Chuyển trạng thái như `bow_dphy_lp` hôm nay ([csi2rx.md](csi2rx.md) mục *Máy trạng thái LP*),
thêm các nhánh escape. Chuỗi vào escape, mã lệnh "spaced-one-hot" (mỗi bit là một trạng thái
"mark" — dây nào lên cho biết giá trị bit — rồi một "space" LP-00) và lệnh ULPS lấy theo tài liệu
công khai [S18]; thoát ULPS bằng LP-10 giữ ≥ T_WAKEUP (≥ 1 ms [S10]) rồi LP-11 [S8][S18]. Phía thu
không cần đo T_WAKEUP: nó chỉ chờ LP-11. LP-11 giữa chuỗi vào escape huỷ việc vào escape (về
`Stop`, không lỗi) [S18].

### 4.3 Máy trạng thái lane clock

| Trạng thái | Nghĩa | v1 | Thêm ở |
|---|---|---|---|
| `Off`, `WaitStop`, `Stop`, `HsRqst` | như data lane | ✓ | |
| `Settle` | LP-00: `clk_hsrx_en`, `clk_term_en`, đếm `CLK_SETTLE` (T_CLK-SETTLE 95…300 ns [S10]) | ✓ | |
| `Hs` | mở cổng (`clk_gate_en`, `RxClkActiveHS`) trong HS-0 của CLK-ZERO; sau khi đã thấy cạnh, `CLK_MISS` chu kỳ không có cạnh → `Trail` | ✓ | |
| `Trail` | đóng cổng; bộ thu HS còn bật tới LP-11 (như hôm nay), hoặc tắt ngay cùng termination khi `CTRL.CLK_MISS_OFF` = 1 (T_CLK-MISS, mục 3.4) | ✓ | `CLK_MISS_OFF`: v1.x |
| `Exit` | LP-11 khi cổng còn mở: đóng cổng trước, tắt bộ thu 2 chu kỳ sau | ✓ | |
| `UlpsRqst`, `Ulps`, `UlpsExit` | LP-11 → LP-10 → LP-00 (ULPS); thoát: LP-10 (`clk_lane_pd` = 0 ngay) → LP-11 [S8][S18] | — | v1.x |
| chế độ `CLK_CONT` | clock liên tục: bộ thu, termination, cổng luôn bật khi `Enable` (không phải một trạng thái) | ✓ (`CLK_FORCE`) | |

**Phát hiện mất clock.** Như hôm nay: một flop đảo ở miền byte, đồng bộ sang miền lp; mỗi thay
đổi là một cạnh. Flop đảo mỗi 2^`CLK_TOG_DIV` byte clock (v1.x) thì tỉ số cho phép là byte clock ≤
~1,5 · 2^`CLK_TOG_DIV` · `lp_clk` (hôm nay `CLK_TOG_DIV` = 0: byte ≤ ~1,5 × `vid_clk`), đổi lại trễ
phát hiện tăng 2^`CLK_TOG_DIV` byte clock. AFE có `clk_act` (bắt buộc với macro ASIC) thì dùng nó
thay cho flop đảo: không phụ thuộc tỉ số clock, và cổng đóng trong ≤ 56 ns sau cạnh cuối ở
`lp_clk` 250 MHz (mục 3.3), tức trước khi hết T_CLK-TRAIL tối thiểu và trong T_CLK-MISS (60 ns
[S10]) ở mọi tốc độ từ 80 Mbit/s. Không có nó, dưới ~333 Mbit/s cổng đóng muộn hơn T_CLK-TRAIL
tối thiểu: lane clock đã rời HS-0, bộ so sánh của nó có thể dao động và tạo xung ngắn trên
`hs_byte_clk`, phá điều kiện "không runt" của mục 3.2 và làm hỏng trạng thái miền byte không được
reset mỗi burst (toggle CDC, bộ đếm gray, RAW).

### 4.4 Timer

| Timer | Thanh ghi | Đơn vị | Rộng | Reset (`TimRstNs` = 0 / 1) | Ghi chú |
|---|---|---|---|---|---|
| `SETTLE` | `TIM0[7:0]` | chu kỳ `lp_clk` | 8 | 14 / 70 ns | từ LP-00 (máy trạng thái thấy) tới bắt đầu dò sync; driver tính theo công thức dưới bảng |
| `LP_FILTER` | `TIM0[11:8]` | chu kỳ | 4 | 2 / 1 | mức LP mới được nhận sau ngần ấy chu kỳ liên tiếp |
| `CLK_SETTLE` | `TIM0[23:16]` | chu kỳ | 8 | 30 / 150 ns | lane clock: từ LP-00 tới mở cổng |
| `CLK_MISS` | `TIM0[31:24]` | chu kỳ | 8 | 8 / 40 ns | 0 = tắt |
| `HS_TMO` | `TIM1[23:0]` | chu kỳ `lp_clk` | 24 | 2^20 / 5 ms | watchdog HS; 0 = tắt. Đếm chu kỳ `lp_clk`, còn `HS_TIMEOUT` của PG202 đếm byte nhận rồi báo `HS_ABORT` [S3] |
| `CLK_TOG_DIV` | `TIM1[27:24]` | log2 | 4 | 0 / 0 | mục 4.3 |
| `T_INIT` | `TIM2[19:0]` | chu kỳ | 20 | 0 / 0 | đếm từ khi `ready` lên hoặc `CMD.REINIT`, không bao giờ từ `Enable` (mục 4.2); 0 = như hôm nay |
| `ESC_TMO` | `TIM2[31:20]` | 64 chu kỳ | 12 | 0 / 0 | v1.x: thời gian tối đa từ lúc vào escape tới khi giải xong lệnh; quá thì lỗi ESC_TMO (như `ESC_TIMEOUT` → `ESC_ABORT` của PG202 [S1][S3]); 0 = tắt |

Giá trị reset: bản FPGA (`TimRstNs` = 0) giữ số chu kỳ của hôm nay, nên hành vi trước khi driver
ghi `TIM*` và mọi kỳ vọng DV không đổi; bản ASIC (`TimRstNs` = 1) tính từ thời gian ở cột Reset
theo `LpClkHz`, kẹp theo độ rộng trường.

**`T_INIT`.** Luật T_INIT của các PHY công khai là luật lúc bật nguồn (PG202 mặc định 100 µs phía
thu [S3]); áp nó ở mỗi lần `Enable` (mỗi `start`) thì với lane clock dừng mỗi frame (IMX219,
IMX274: LP-11 chỉ trong vertical blanking) một bộ thu bật giữa stream không bao giờ tới `Stop`
nếu VBLANK < T_INIT, và một bộ thu bật trước stream mất frame đầu nếu cảm biến giữ LP-11 trước
burst đầu ngắn hơn T_INIT (với IMX274, standby là LP-00, thời gian này chưa biết). Vì vậy T_INIT
chỉ đếm sau khi `ready` lên hoặc sau `CMD.REINIT`; reset 0, driver mặc định ngắn (~1 µs)
**[ĐỀ XUẤT]**; giá trị phía thu mà đặc tả đòi **[CHƯA CHẮC]**.

**Công thức `SETTLE` của driver**, một công thức cho mọi AFE, thay hai công thức riêng hôm nay
(`settle_cycles()` và `SETTLE_VID_NS`):

```
SETTLE = kẹp_1..255( round((INFO2.SETTLE_NS + INFO2.SETTLE_UI · UI) · f_lp) − (3 + LP_FILTER) )
```

`SETTLE_NS` + `SETTLE_UI` · UI là đích từ LP-00 ở đầu ra bộ thu LP tới lúc `RxActiveHS` lên (bắt
đầu dò sync); 3 + `LP_FILTER` là trễ đồng bộ, lọc và FSM. Giá trị của mỗi AFE tái tạo đúng từng bit
điểm làm việc đã kiểm trên bo:

| AFE | `SETTLE_NS` / `SETTLE_UI` | Ở `lp_clk` 200 MHz, `LP_FILTER` 2 | Hôm nay |
|---|---|---|---|
| UltraScale+ (KV260) | 107 ns / 24 UI: giữa cửa sổ của aligner nhìn lùi 2 word, đã trừ ~8 ns bộ thu LP (`bow_csi2rx.c` `settle_cycles()`) | 912 Mbit/s: round(133,3 ns · 0,2) − 5 = 22 | `settle_cycles()` = 22 |
| Versal (Huins) | 120 ns / 0 UI | round(24) − 5 = 19 = `0x13` (95 ns) | `SETTLE_VID_NS` = 95 ns = `0x13`; sạch 65–170 ns, 3,2 triệu burst không lỗi ở 95 ns |
| Macro ASIC | theo AFE, khi có số của mục 3.3 **[ĐỀ XUẤT]** | — | — |

Test `csi2_274` giữ phép so `TIM0` = `051e0213` làm chốt chặn (hôm nay là `rd 4000800c`);
`csi2` (KV260) thêm phép so tương tự với giá trị `settle_cycles()` của mô phỏng. Đổi giá trị của
Huins chỉ sau một lần quét `SETTLE` trên bo (bo đang cho mượn).

`TIM0` giữ đúng bố cục và đơn vị của `PHY_CFG` hiện nay: driver giữ mã, test so cùng giá trị.
Các hãng đếm settle theo những clock khác nhau: PG202 có thanh ghi `HS_SETTLE` đếm chu kỳ `core_clk` [S2],
i.MX8 đếm chu kỳ escape clock [S12], Lattice đếm byte clock [S8], còn driver Cadence chỉ chọn band
theo tốc độ lane, settle coi như do PHY tự lấy **[CHƯA CHẮC]** [S11]. Bow32 giữ cách của PG202:
một clock chạy liên tục, độc lập với byte clock bị gate.

### 4.5 Dò sync và căn byte

**v1** dùng nguyên `bow_dphy_align` (đã chạy trên bo, 301 case unit test): cửa sổ 24 bit gồm word
hiện tại và 2 word trước; sync = 8 bit 0 rồi `0xB8`; dò từ cạnh lên của `RxActiveHS` tới khi khớp;
mọi trạng thái chỉ tiến trên word `hs_valid`; burst deskew (HS-zero rồi 16 bit 1) chỉ được nhận
ở chỗ HS-zero kết thúc ([csi2rx.md](csi2rx.md) mục *Tìm sync*). Độ trễ từ word của AFE tới
`RxDataHS`: 2 byte clock (flop word + flop ra).

**v2** sửa ba giới hạn đã biết:

1. **Tốc độ thấp.** Giới hạn dưới ~350 Mbit/s hôm nay có ba nguyên nhân ([csi2rx.md](csi2rx.md)
   mục *Giới hạn*): (a) mất clock chỉ thấy qua cạnh byte clock (8 UI một cạnh), nên dưới
   ~333 Mbit/s cổng đóng muộn hơn T_CLK-TRAIL tối thiểu; (b) cuối burst, pipeline aligner → ghép
   lane (~5–6 byte clock) phải xả kịp trước khi `RxActiveHS` xuống, nếu không packet bị cắt dưới
   ~220 Mbit/s; (c) aligner nhìn lùi 2 word và đòi 8 bit 0 trước `0xB8`. Sửa: (a) `clk_act` của
   AFE (phát hiện ở mức UI; bắt buộc với macro ASIC, mục 3.2, 4.3); (b) aligner và ghép lane xả
   hết word đã nhận rồi mới kết thúc burst; (c) **cửa sổ có mặt nạ**: chỉ xét bit nhận từ đầu lần
   dò trở đi, đòi `SYNC_MINZ` = k bit 0 ngay trước `0xB8` (0…8). Bit đầu được xét phải nằm sau
   HS-PREPARE dài nhất (85 ns + 6 UI) và
   trước sync sớm nhất (145 ns + 10 UI) ít nhất k UI [S10]: cửa sổ rộng 60 ns + (4 − k) UI, phải
   chứa độ bất định của bit đầu (1 word = 8 UI, cộng δ ≈ 10 ns do lấy mẫu LP và CDC). k = 8 tương
   đương hôm nay (> ~220–240 Mbit/s); k = 4: > ~160 Mbit/s; k = 2: > ~120 Mbit/s; k = 0: ~80 Mbit/s,
   sát biên **[ƯỚC LƯỢNG]**. k nhỏ làm yếu khả năng chống sync giả trong nhiễu HS-PREPARE khi
   `SETTLE` đặt sai, nên driver chọn k lớn nhất mà tốc độ lane cho phép.
2. **`ErrSotHS`.** Với `CTRL.SOT_TOL` = 1, sync sai đúng 1 bit (ở cùng vị trí sau HS-zero) được
   nhận, `RxSyncHS` kèm `ErrSotHS` [S1][S4]. Phải chứng minh không tăng sync giả trong nhiễu
   HS-PREPARE (test ở mục 8.6).
3. **`ErrSotSyncHS` sớm.** Hôm nay lỗi được báo khi `RxActiveHS` xuống (cuối burst). v2 báo ngay
   khi HS-zero đã kết thúc (aligner đã có cờ "leader over") mà không có sync hay deskew, gần với ý
   nghĩa "lỗi ở SoT" của tín hiệu này ở PHY công khai [S1][S4]; thời điểm chính xác của họ
   **[CHƯA CHẮC]**. PG202 vẫn đưa payload của burst đó ra PPI, PG435 thì chặn [S3][S4]: Bow32 chặn
   (không `RxValidHS`), như hôm nay.

Với PPI 16 bit (v2): cửa sổ 40 bit, 16 offset, `RxValidHS[1:0]` theo byte; packet có thể kết thúc ở
nửa word [S4].

### 4.6 Deskew: nhận ra và hiệu chỉnh

- **Nhận ra** (v1): như hôm nay, nhưng mỗi lane ra `RxSkewCalHS[l]` (hôm nay chỉ lane 0 được đếm;
  lane khác lệch thì ghép lane báo SKEW). v1.x: `RxSkewCalHS` là mức từ lúc nhận ra tới hết burst,
  như PHY công khai [S1][S4]; controller đếm cạnh lên ở lane 0, nên `CNT_EXT[31:16]` không đổi
  (ngoại lệ có chủ ý, mục 4.12).
- **Bộ máy hiệu chỉnh** (v2, `CTRL.DSK_EN`, `DSK_CTRL`): chạy khi mọi lane đang dùng đều nhận ra
  burst deskew; sau `FFFFh` là mẫu xen kẽ `0101…` [S8]. Mỗi lane có một bộ kiểm ở miền byte **không
  cần byte tham chiếu**: với p = bit cuối của word trước, word đạt khi
  `(w ^ {w[6:0], p}) == 8'hFF`, tức mỗi bit khác bit ngay trước nó. Phép kiểm không phụ thuộc pha
  hay trượt bit và bắt mọi lỗi một bit. So một byte tham chiếu lấy ở mã đầu thì hỏng theo ba cách:
  khi điểm lấy mẫu qua ranh giới UI, dòng bit trượt một bit (`0x55` thành `0xAA`) và eye bên cạnh
  sạch vẫn bị đếm lỗi; mẫu lặp lại sau 2 UI nên trượt 2 bit lại khớp (đạt giả ở eye khác); và byte
  tham chiếu tự nó có thể hỏng khi mã đầu nằm ở mép eye (bài học Huins). Mỗi điểm ghi thêm pha của
  mẫu (`0x55` hay `0xAA`): pha đổi giữa hai điểm liền nhau nghĩa là đã qua ranh giới UI (đếm riêng
  là số lần trượt), nên dải đạt bị tách ở đó. Một sequencer ở miền lp duyệt mã delay: đặt mã (lần
  ghi đặt OWN = 1, mục 3.5), bỏ `SET_W` word, đếm lỗi trong `WORDS` word, ghi đạt/hỏng và pha; cuối
  burst chọn dải đạt rộng nhất (bằng nhau thì dải gần giữa tầm mã, còn chỗ bám VT), đặt tâm, ghi
  `DSK_EYEn`. Tầm delay (≥ 1 UI + lệch tĩnh) có thể vượt 2 UI ở 2,5 Gbit/s; eye nào cũng cho dữ liệu
  đúng (aligner tìm sync lại mỗi burst), nên chọn eye chỉ là chuyện lề bám. Hai miền nói chuyện
  bằng bắt tay req/ack, nên đổi một điểm tốn vài chu kỳ lp + thời gian áp mã của AFE.
- **Mẫu deskew lạc quan:** `0101…` không có ISI, nên eye của nó rộng hơn eye của dữ liệu thật; sau
  deskew driver vẫn chạy kiểm tra lề trên dữ liệu (`bow_csi2rx_margin()`, mục 6.4).
- **Cỡ**: burst deskew ban đầu dài tối thiểu 2^15 UI, định kỳ 2^10 UI theo một nguồn công khai
  (đoạn trích lỗi định dạng) **[CHƯA CHẮC]** [S9]: 2^15 UI = 4096 word mỗi lane, đủ cho ~32 điểm ×
  (8 + 64) word + bắt tay; 2^10 UI = 128 word: chỉ đủ bám ±1–2 điểm quanh hai mép đã biết
  (`DSK_CTRL.MODE` = 2).
- **Khi không có burst deskew** (cảm biến dưới 1,5 Gbit/s, hay IMX219/IMX274 hôm nay): eye walk
  bằng phần mềm (mục 6.4) với bộ đếm lỗi CSI-2 của controller, như hôm nay.

Nhiều bằng sáng chế mô tả delay line phía thu cho deskew D-PHY [S22]: bộ máy này phải được rà
quyền sử dụng trước khi đưa vào sản phẩm (rủi ro R9).

### 4.7 Phát hiện lỗi

| Lỗi | Điều kiện | PPI | `ERR_STATUS` (D-PHY) | Hôm nay |
|---|---|---|---|---|
| SoT không đồng bộ | v1: `RxActiveHS` xuống mà chưa có sync/deskew; v2: HS-zero kết thúc mà không có | `ErrSotSyncHS` | [0] SOT_SYNC | `ERR_STATUS.SOT` |
| SoT lỗi mềm | sync sai 1 bit được nhận (`SOT_TOL`) | `ErrSotHS` + `RxSyncHS` | [1] SOT | — |
| Chuỗi LP sai | `Stop` thấy LP-00 không qua LP-01; `HsRqst` thấy LP-10; LP-10 ở `Stop` khi `ULPS_EN` = 0 | data lane: `ErrControl[l]`; lane clock: `ErrControlClk` (Bow32, D-PHY chặn khi `CLK_CONT` = 1) | [2] CONTROL | `ERR_STATUS.LP` (lane clock chỉ khi không `CLK_FORCE`) |
| HS quá lâu | ở `Hs` quá `HS_TMO` | `ErrControl` (Bow32) | [3] HS_TMO | watchdog → LP |
| Lệnh escape lạ | lệnh không phải ULPS (chưa hỗ trợ LPDT/trigger) | `ErrEsc` | [4] ESC | lỗi LP |
| LPDT lẻ bit | (sau) | `ErrSyncEsc` | [5] SYNC_ESC | — |
| Mất clock khi data ở HS | data lane vào `Settle`/`Hs` khi lane clock không ở `Hs` (trừ `CLK_CONT`); chỉ khi `CTRL.CLK_LOST_EN` = 1 | `ErrControl` (Bow32) | [6] CLK_LOST | lỗi LP của lane clock khi cổng đóng |
| Kết thúc burst muộn | data lane về `Stop` khi lane clock đã rời `Hs`: `RxActiveHS` không xuống kịp trong miền byte | — | [7] LATE_EOT | F7: sự kiện tới ở burst sau |
| Deskew hỏng | bộ máy không tìm được dải đạt ≥ `MIN_EYE` | — | [8] DSK_FAIL | — |
| AFE mất sẵn sàng | `ready` xuống khi `Enable` = 1 | — | [9] AFE | `PHY_RDY` = 0 |
| Escape quá lâu | ở `EscRqst`/`EscGo`/`EscCmd` quá `ESC_TMO` (v1.x) | `ErrEsc` | [10] ESC_TMO | — |

### 4.8 ULPS và escape: phân kỳ

| Chức năng | v1 | v1.x | Sau |
|---|---|---|---|
| LP-00 standby (trước stream đầu) không là lỗi | ✓ (`WaitStop`) | | |
| Escape vào ULPS, data lane: giải lệnh, `RxUlpsEsc`, `UlpsActiveNot`, `lane_pd` | — (lỗi LP) | ✓ (`CTRL.ULPS_EN`) | |
| ULPS lane clock: `RxUlpsClkNot`, `UlpsActiveNot` của lane clock | — | ✓ | |
| Thức dậy không cần `lp_clk` (bộ thu LP đánh thức bộ điều khiển clock của SoC) | — | — | ✓ (mục 9.4) |
| LPDT (`RxLPDTEsc`, `RxDataEsc`, `RxValidEsc`, `RxClkEsc`), trigger (`RxTriggerEsc`) | — | — | khi có cảm biến cần; giải bằng lấy mẫu dư ở miền lp, không cần clock escape riêng (`RxClkEsc` lấy từ chính hai dây LP [S1][S4]) |

Camera CSI-2 gần như chỉ dùng HS và Stop; escape (LPDT, trigger) hiếm khi được dùng, ULPS thì có
thể có ở cảm biến/bridge.

### 4.9 Sinh PPI

| PPI | Sinh từ | Miền |
|---|---|---|
| `RxByteClkHS` | `hs_byte_clk` của AFE (một bộ đệm clock) | — |
| `RxActiveHS[l]` | `Hs` của FSM data lane, đồng bộ 2 flop vào miền byte | byte |
| `RxDataHS[l]`, `RxValidHS[l]`, `RxSyncHS[l]`, `ErrSotSyncHS[l]`, `ErrSotHS[l]`, `RxSkewCalHS[l]` | aligner của lane vật lý `LANE_MAP[l]` (v2; reset: lane l) | byte |
| `Stopstate[l]`, `StopstateClk` | FSM ở `Stop` (và đã qua `T_INIT`) | lp |
| `RxClkActiveHS` | FSM lane clock ở `Hs`, cổng mở | lp |
| `UlpsActiveNot[l]`, `UlpsActiveNotClk`, `RxUlpsEsc[l]`, `RxUlpsClkNot` | FSM ở `Ulps*` | lp |
| `ErrControl[l]`, `ErrControlClk`, `ErrEsc[l]`, `ErrSyncEsc[l]` | sự kiện của FSM. v1.x: bộ đếm gray 2 bit, mỗi tín hiệu ≤ 1 bước mỗi 16 chu kỳ lp (sự kiện dồn lại thì gộp; `ERR_STATUS` và bộ đếm của D-PHY vẫn đếm đủ). v1 (bước 2–5): xung một chu kỳ, như sự kiện hôm nay, chỉ hợp lệ khi controller chạy cùng clock (FPGA: `lp_clk` = `vid_clk`, kiểm khi elaborate), để bước 2 tương đương từng chu kỳ với hôm nay | lp |
| `PhyReady` (Bow32) | `ready` của AFE ∧ `CTRL.EN` ∧ không có `AFE` lỗi | lp |

Giá trị khi chức năng chưa có (v1, chưa có ULPS và escape): `UlpsActiveNot[l]` = `UlpsActiveNotClk`
= 1 và `RxUlpsClkNot` = 1 (cả ba tích cực thấp), `RxUlpsEsc[l]` = 0, `ErrEsc`/`ErrSyncEsc` đứng yên
ở 0; mọi bộ đếm gray (v1.x) reset về 0. `ErrSotHS` = 0 tới v2.

Yêu cầu: mọi byte của một burst ra PPI trước khi `RxActiveHS` xuống; độ trễ từ word của AFE tới
`RxDataHS` ≤ 3 byte clock; `RxActiveHS` xuống trong vòng (phát hiện LP-11 + 2 byte clock), tức
trong thời gian lane clock còn chạy nếu máy phát giữ đúng T_CLK-POST (mục 5.4).

### 4.10 Thanh ghi

Bus của Bow32 (`bus_req_t`/`bus_rsp_t`, như các IP khác), wrapper APB4 cho ASIC (`bow_mipi_rx_apb`,
bước 9). Bow32 đặt khối ở `0x4000_8C00` (offset `0xC00` trong cửa sổ 4 KiB của `CSI2RX`: bus ngoại
vi đã dùng hết 16 khe, và `0xC00`–`0xFFF` hôm nay trống). Byte enable và W1C như
`bow_csi2rx_regs`; bộ đếm 32 bit bão hoà (F11 của review: bộ đếm 16 bit bão hoà sau ~60 frame
1080p ở 1091 burst mỗi frame), trừ hai thanh ghi ghép đã ghi rõ. Trường của lane 4–7 đọc 0 khi
`Lanes` ≤ 4. SoT chỉ được đếm ở controller (`CNT_SOT`, qua `ErrSotSyncHS` của PPI); D-PHY giữ cờ
dính `ERR_LANE` theo lane. Cửa sổ này có những tên trùng với thanh ghi của controller (`ID`,
`INFO`, `CTRL`, `IRQ_*`, `ERR_STATUS`, `CNT_MISC`, `BYTECLK`, `RAW_CTRL`): trong `bow_dphy_rx.h`
mọi tên có tiền tố `DPHY_` (struct `DPHY`, macro `DPHY_CTRL_*`…).

| Offset | Tên | Truy cập | Bit (giá trị reset) |
|---:|---|:--:|---|
| 0x000 | `ID` | R | `0x44505201` ("DPR", phiên bản 1) |
| 0x004 | `INFO` | R | [3:0] `Lanes`, [4] PPI 16 bit, [7:5] `AfeKind`, [17:8] `lp_clk` (MHz, 10 bit: tới 1023 MHz), [21:18] `DlyW`, [22] delay lane clock, [23] AFE tự hiệu chỉnh delay (kiểu BISC: phần mềm bắt đầu từ trễ đang dùng), [24] sampler giám sát, [25] bộ máy deskew, [26] PRBS, [27] ULPS, [28] loopback AFE, [29] bước delay không glitch, [30] nhả delay từng lane (`CMD.DLY_REL`), [31] AFE có `clk_act` |
| 0x008 | `INFO2` | R | [7:0] `SETTLE_NS`, [15:8] `SETTLE_UI` (đích của `SETTLE`, mục 4.4), [23:16] byte thêm mỗi lane cuối burst do AFE (XPHY: 8), [31:24] 0 |
| 0x00C | `CTRL` | RW | [0] EN (1), [1] CLK_CONT (0), [2] ULPS_EN (0), [3] HSRX_EARLY (0), [4] SOT_TOL (0), [5] DSK_EN (0), [6] DES_RST_DIS (0; chỉ để thử, bo Huins hỏng khi tắt reset này), [7] CLK_LOST_EN (0), [15:8] LANE_EN (1 cho mọi lane có), [16] CLK_MISS_OFF (0) |
| 0x010 | `CMD` | W | [0] APPLY (chép shadow `CTRL`, `TIM*`, `LANE_MAP`, `LANE_POL` sang miền lp), [1] REINIT (≈ `ForceRxmode`: các FSM về `WaitStop`, `T_INIT` đếm lại), [2] AFE_CAL (`cal_start`), [3] CNT_CLR, [4] DSK_RUN (chạy bộ máy ở burst deskew kế tiếp), [15:8] DLY_REL (lane l về giá trị của AFE; bỏ qua khi `INFO[30]` = 0), [16] DLY_CLK_REL |
| 0x014 | `AFE_CTRL` | RW | [0] PD (`AfePdRst`), [3:1] TST_MODE (0), [15:8] ATB_SEL (0) |
| 0x018 | `AFE_STATUS` | R | [0] READY, [1] CAL_DONE, [2] CAL_ERR, [15:8] `status` thô của AFE |
| 0x01C, 0x020 | `AFE_TRIM0`, `AFE_TRIM1` | RW | `trim[31:0]`, `trim[63:32]` (0) |
| 0x024 | `TIM0` | RW | bố cục của `PHY_CFG`: [7:0] SETTLE, [11:8] LP_FILTER, [23:16] CLK_SETTLE, [31:24] CLK_MISS (reset: mục 4.4) |
| 0x028 | `TIM1` | RW | [23:0] HS_TMO (0 = tắt; reset: mục 4.4), [27:24] CLK_TOG_DIV (0) |
| 0x02C | `TIM2` | RW | [19:0] T_INIT (0), [31:20] ESC_TMO (đơn vị 64 chu kỳ, 0 = tắt) (0) |
| 0x030 | `LANE_LP` | R | LP {P,N} sau lọc, đọc được cả khi `Enable` = 0 (mục 3.2): [1:0] lane clock, [2l+3:2l+2] data lane l |
| 0x034 | `LANE_HS` | R | [0] bộ thu HS + termination lane clock, [l+1] data lane l; [16] cổng byte clock mở, [17] `RxClkActiveHS`, [18] BYTECLK_OK |
| 0x038 | `LANE_STOP` | R | [0] `Stopstate` lane clock, [l+1] data lane l; [16] ULPS lane clock, [l+17] ULPS data lane l |
| 0x03C | `IRQ_STATUS` | W1C | [0] ERR, [1] ULPS (vào/ra), [2] DSK_DONE, [3] RAW_DONE, [4] AFE (READY đổi, CAL_DONE), [5] PRBS |
| 0x040 | `IRQ_EN` | RW | như `IRQ_STATUS` (0) |
| 0x044 | `ERR_STATUS` | W1C | [0] SOT_SYNC, [1] SOT, [2] CONTROL, [3] HS_TMO, [4] ESC, [5] SYNC_ESC, [6] CLK_LOST, [7] LATE_EOT, [8] DSK_FAIL, [9] AFE, [10] ESC_TMO (mục 4.7) |
| 0x048 | `ERR_LANE` | W1C | [l] SOT_SYNC data lane l, [8+l] CONTROL data lane l, [16] CONTROL lane clock |
| 0x04C | `BYTECLK` | R | [19:0] byte clock trong 65536 chu kỳ bus (như hôm nay) |
| 0x050–0x06C | `CNT_BURST0`…`CNT_BURST7` | R | số lần vào HS của data lane l |
| 0x070 | `CNT_CLK` | R | số lần vào HS của lane clock |
| 0x074 | `CNT_LPERR` | R | lỗi LP (CONTROL) của mọi lane |
| 0x078 | `CNT_DSK` | R | [15:0] burst deskew, [31:16] lần vào ULPS (hai bộ đếm 16 bit bão hoà) |
| 0x07C | `CNT_MISC` | R | [15:0] `ErrSotHS`, [31:16] HS_TMO + CLK_LOST + LATE_EOT + ESC_TMO (hai bộ đếm 16 bit bão hoà) |
| 0x080–0x09C | `DLY0`…`DLY7` | RW | [9:0] CODE: ghi = mã yêu cầu, đọc = mã đang lái AFE, đồng bộ ngược từ miền lp (0); [15] PEND (R): lần ghi chưa được miền lp áp; [25:16] `dly_q` của AFE; [31] OWN (R, 0). Lần ghi có byte 0 hoặc 1 đặt CODE và OWN := 1, bất kể [31]; lần ghi chỉ có byte 2–3 không làm gì. Lane về giá trị của AFE bằng `CMD.DLY_REL` |
| 0x0A0 | `DLY_CLK` | RW | như `DLYn` cho lane clock (khi `INFO[22]`); nhả bằng `CMD.DLY_CLK_REL` |
| 0x0A4 | `AFE_OVR` | RW | chỉ để test (0): [8:0] EN (bit 0 = lane clock, bit l+1 = data lane l), [31:16] KEY. EN chỉ có hiệu lực khi `scan_mode` = 1 hoặc khi lần ghi mang KEY = `0x7E57`; ghi không có KEY xoá EN; [31:16] đọc 0 |
| 0x0A8 | `AFE_OVR_V0` | RW | giá trị ép lên AFE khi EN của lane bật: [8:0] `hsrx_en`, [24:16] `term_en` (0) |
| 0x0AC | `AFE_OVR_V1` | RW | [8:0] `lprx_en`, [24:16] `lane_pd` (0) |
| 0x0B0 | `DSK_CTRL` | RW | [1:0] MODE (0 tắt, 1 quét ở burst deskew, 2 quét rồi bám; về 0 khi phần mềm ghi `DLYn`, mục 3.5), [7:4] STEP (mã), [15:8] WORDS (/8), [23:16] SET_W (word), [31:24] MIN_EYE (mã) |
| 0x0B4 | `DSK_STATUS` | R | [7:0] DONE mỗi lane, [15:8] FAIL mỗi lane, [23:16] số lần chạy (bão hoà), [24] ABORT (phần mềm ghi `DLYn` khi bộ máy đang giữ delay; xoá ở `DSK_RUN` kế tiếp) |
| 0x0C0–0x0DC | `DSK_EYE0`…`DSK_EYE7` | R | [9:0] mép trái, [25:16] mép phải (mã) của lần quét cuối, [31:28] số lần trượt UI trong tầm quét |
| 0x0E0 | `PRBS_CTRL` | RW | [0] EN, [2:1] đa thức (chọn theo bộ phát test **[CHƯA CHẮC]**), [15:8] mask lane |
| 0x0E4 | `PRBS_STATUS` | R | [7:0] đã khoá mỗi lane |
| 0x0E8–0x0F4 | `PRBS_ERR01/23/45/67` | R | lỗi mỗi lane, 16 bit bão hoà |
| 0x100 | `RAW_CTRL` | RW | như hôm nay: ghi [0] ARM, [1] NOW; đọc [0] ARMED, [1] NOW, [8] DONE |
| 0x104 | `LANE_MAP` | RW | v2: [3l+2:3l] lane vật lý cấp cho PPI lane l (reset: l, tức không đổi); shadow + APPLY, chỉ đổi khi `Enable` = 0 |
| 0x108 | `LANE_POL` | RW | v2: [0] lane clock, [l+1] data lane l: đảo P/N (0). Data lane: đảo bit HS (ở flop word, trước aligner) và đổi chỗ P/N của LP; lane clock: chỉ LP (LP-01 ↔ LP-10), phần HS không cần vì aligner tìm sync ở mọi pha bit |
| 0x200–0x3FC | `RAW[64]` | R | entry i: `0x200 + 8i` = lane 0–3 (byte k = lane k), `0x204 + 8i` = lane 4–7 |

**Ánh xạ lane** (`LANE_MAP`, `LANE_POL`; v2; lane swap ở [../csi2rx_review.md](../csi2rx_review.md)
mục 4): trên ASIC, package và đường mạch in hay buộc đổi thứ tự hoặc cực của lane; trong D-PHY số
việc này rẻ. Ánh xạ đặt ở đầu ra PPI, sau aligner: mọi thứ bên trong D-PHY (FSM, delay, `DLYn`,
`LANE_LP`, `ERR_LANE`, bộ đếm) giữ số lane vật lý, khớp với chân và delay line; PPI và controller
dùng số lane logic (thứ tự byte của CSI-2). Về chức năng, đặt trước aligner cũng như nhau.

**Cấu hình qua shadow + APPLY** (v1.x, sửa F12 của review cho phần PHY): `CTRL`, `TIM*`,
`LANE_MAP` và `LANE_POL` ghi vào bản shadow ở miền bus; `CMD.APPLY` lật một toggle, miền lp chép cả
bộ trong một chu kỳ khi thấy toggle đã đồng bộ và trả ack. Không còn bus `bow_sync` từng bit cần
waiver. Driver ghi rồi APPLY; luật cũ "đổi `PHY_CFG` khi PHY_EN = 0" vẫn giữ cho các trường ảnh
hưởng tới lane đang chạy. Ở v1 (bước 4–5) các trường này qua `bow_sync` từng bit như hôm nay và chỉ
được đổi khi lane tắt; `CMD.APPLY` đã có nhưng không làm gì.

**Mã delay.** Thanh ghi lái `dly_code`/`dly_own` sang AFE nằm ở miền lp, là chủ duy nhất phía AFE;
phần mềm ghi `DLYn` qua bộ đếm gray yêu cầu + dữ liệu giữ ổn định (cơ chế `DlyVid` = 1 hôm nay),
bộ máy deskew ghi trực tiếp ở miền lp; luật một chủ ở mục 3.5. Khi `ready` xuống, miền lp xoá mọi
OWN. Đọc lại: `DLYn[9:0]` là mã thật sự đang lái AFE (sau một lần deskew là mã bộ máy đặt, không
phải lần ghi cuối của phần mềm); `PEND` = 1 từ lúc ghi tới khi miền lp xác nhận đã áp (ack gray).
`wait_delay()` chờ `PEND` = 0 và `[9:0]` = `[25:16]` trên các lane có OWN = 1, nên không bao giờ so
nhầm mã cũ và không chờ mãi sau một lần deskew. `[25:16]` là `dly_q` của AFE (đọc hai lần giống
nhau, mục 4.11).

**Byte enable của `DLYn`.** Driver hôm nay ghi cả word (`CSI2RX->DLY[lane] = tap`,
`bow_csi2rx.c:300-305`): byte 0–1 và byte 3 đến cùng lúc, với bit 31 = 0. Vì OWN chỉ đọc và việc
nhả đi qua `CMD.DLY_REL`, không có hai luật nào cùng bắn: lần ghi nào có byte 0 hoặc 1 cũng đặt
CODE và OWN = 1. DV `be` kiểm ba trường hợp: ghi cả word, ghi chỉ byte 3 (không đổi gì), và
`DLY_REL`.

### 4.11 Clock, reset, CDC

| Clock | Nguồn | Tần số | Dùng cho |
|---|---|---|---|
| `clk_i` | bus của SoC | 50 MHz (Bow32) | thanh ghi, bộ đếm, đọc RAM RAW |
| `lp_clk_i` | SoC, chạy liên tục khi PHY bật | FPGA: 200 MHz (`vid_clk`); ASIC: ≥ 250 MHz [ĐỀ XUẤT] (mục 3.4) | máy LP, timer, điều khiển AFE, escape/ULPS, sequencer deskew |
| `hs_byte_clk` | AFE (lane clock ÷ 4), bị gate | ≤ 312,5 MHz (PPI 8 bit) | aligner, PPI, kiểm mẫu deskew, PRBS, RAW, đồng hồ đo |
| clock test | DFT | — | thay `hs_byte_clk` khi `scan_mode` (mục 9.2) |

**Gating.** Cổng của byte clock nằm trong AFE (`clk_gate_en`, mục 3.2) vì nó phải gate cả bộ chia;
phần số không gate thêm byte clock. `lp_clk_i` chạy liên tục khi PHY bật; wrapper của SoC có thể
gate nó (ICG) khi `CTRL.EN` = 0 và `pd` = 1, không gate trong ULPS ở v1.x (cần thấy chuỗi thoát,
mục 4.8). Logic của một lane không dùng đứng yên vì FSM ở `Off` và không có word.

| Reset | Miền | Nguồn | Ghi chú |
|---|---|---|---|
| `bus_rst_n` | `clk_i` | `rst_ni` | |
| `lp_rst_n` | lp | `rst_ni` & `lp_rst_ni` | điều khiển AFE về trạng thái an toàn (mục 3.6) |
| `byte_rst_n` | byte | `rst_ni` | bật bất đồng bộ, nhả đồng bộ khi byte clock chạy (tức ở burst sau) |
| `des_rst` | lp → AFE | flop miền lp = ¬`clk_gate_en` | chỉ xoá đường dữ liệu của AFE, không đụng bộ chia (mục 3.2) |

| Đường qua miền | Cách | Ràng buộc |
|---|---|---|
| AFE → lp: `lp`, `ready`, `cal_done`, `status`, `hs_raw`, `clk_act` | 2 flop (+ lọc cho `lp`) | false path / max delay |
| AFE → bus: `dly_q` | 2 flop từng bit, đọc hai lần giống nhau (driver) | gần tĩnh |
| lp → AFE: mọi điều khiển | flop của FSM, không logic sau flop | AFE coi là bất đồng bộ |
| lp → byte: `hs_active` (→ `RxActiveHS`) | 2 flop mỗi lane | |
| byte → lp: cạnh byte clock | flop đảo ÷2^N, 2 flop | tỉ số clock (mục 4.3) |
| byte → lp: kết quả kiểm deskew | req/ack | |
| bus ↔ lp: `CTRL`, `TIM*`, `LANE_MAP`, `LANE_POL` | shadow + APPLY toggle (v1.x; v1: `bow_sync` từng bit) | không còn bus đồng bộ từng bit |
| bus → lp: `DLYn` (mã) | bộ đếm gray yêu cầu 2 bit + dữ liệu ổn định (như `DlyVid` = 1 hôm nay); ack gray ngược lại cho `PEND` | mỗi lần ghi một lần cập nhật; lần cập nhật cách nhau ≥ 16 chu kỳ |
| lp → bus: mã đang lái AFE, OWN | 2 flop từng bit, gần tĩnh (chỉ đổi sau một lần ghi đã ack hay một bước của bộ máy) | đọc khi `PEND` = 0 |
| lp → bus: sự kiện (vào HS, lỗi LP, ULPS) | bộ đếm ở miền nguồn, đọc qua mã gray (v1.x) | bỏ ràng buộc `lp_clk` ≤ 16/3 × `clk_i` của hôm nay (F10) |
| byte → bus: sự kiện (SoT, deskew) | `bow_cdc_pulse` (như hôm nay) | mỗi loại ≤ 1 lần mỗi burst |
| bus ↔ byte: lệnh RAW | bộ đếm gray req/ack 4 bit (như hôm nay) | `set_bus_skew` |
| byte → bus: đồng hồ đo byte clock | gray 20 bit | `set_bus_skew` |

Phía controller (đường PPI qua miền; controller không có `lp_clk`):

| Đường qua miền | Cách | Ràng buộc |
|---|---|---|
| PPI byte → controller | cùng `RxByteClkHS`, không qua miền | đồng bộ thường |
| PPI lp → controller: `ErrControl[l]`, `ErrControlClk`, `ErrEsc[l]`, `ErrSyncEsc[l]` | v1.x: bộ đếm gray 2 bit mỗi tín hiệu, 2 flop từng bit ở miền luôn chạy của controller (`vid_clk_i`; `csi_clk` sau bước 7; trên FPGA cả hai là `vid_clk`); mỗi lần giá trị đổi là ≥ 1 sự kiện. Từ đó tới miền byte: req/ack gộp, không mất (như `lpl_*` hôm nay). v1 (bước 2–5): xung cùng clock, không qua miền | D-PHY phát ≤ 1 bước mỗi 16 chu kỳ lp, nên chỉ mất sự kiện khi bộ đếm quay đủ vòng (4 bước, ≥ 64 chu kỳ lp) giữa hai lần lấy mẫu: cần clock của controller ≥ `lp_clk` / 32 (kiểm khi elaborate); `set_bus_skew` ≤ 1 chu kỳ lp |
| PPI lp → controller: `Stopstate*`, `RxClkActiveHS`, `UlpsActiveNot*`, `PhyReady` | 2 flop, mức | dùng cho: trạng thái (`STATUS`), `bow_csi2rx_stop()` chờ `RxClkActiveHS` = 0, ngắt ULPS (v1.x); không có đường dữ liệu nào phụ thuộc chúng |

Vì sao không dùng toggle một bit: toggle lật hai lần giữa hai lần lấy mẫu thì đọc ra như không có
sự kiện; nếu controller lấy mẫu nó ở byte clock bị gate, hai lỗi trong một khoảng blanking triệt
tiêu nhau. Đường req/ack hôm nay (`bow_csi2rx.sv:376-395`) gộp yêu cầu nhưng không bao giờ mất;
bộ đếm gray giữ tính chất đó mà không cần đường ack ngược qua PPI. Miền lấy mẫu là `vid_clk_i`
chứ không phải `clk_i`: yêu cầu "burst mất" hôm nay đã sinh ở miền video rồi mới sang miền byte,
và sau bước 7 lớp packet chạy ở `csi_clk` liên tục, nên không thêm một lần qua miền nào.

### 4.12 Phân kỳ

| Mức | Nội dung | Bước (mục 10) |
|---|---|---|
| v1 | chức năng bằng hôm nay: FSM, timer `TIM0`, aligner, nhận ra deskew, RAW, đồng hồ đo, PPI 8 bit (lỗi lp: xung cùng clock, có `ErrControlClk`), thanh ghi D-PHY, giao diện AFE | 1–5 |
| v1.x | `T_INIT`, `HS_TMO`, `ESC_TMO`, `HSRX_EARLY`, `CLK_MISS_OFF`, `RxSkewCalHS` mức trên mọi lane, `CLK_TOG_DIV`, lỗi lp của PPI dạng bộ đếm gray, ULPS, shadow + APPLY, bộ đếm gray phía bus, `CLK_LOST_EN`, LATE_EOT | 6 |
| v2 | bộ máy deskew, PRBS, tốc độ thấp ((a)–(c) của mục 4.5: aligner có mặt nạ, `clk_act`, xả pipeline), `ErrSotHS`, `ErrSotSyncHS` sớm, PPI 16 bit, `LANE_MAP` / `LANE_POL`, 8 lane (khi có nhu cầu) | 8, 10 |
| v3 / sau | sampler giám sát và bám nền, LPDT, trigger, thức dậy không cần `lp_clk` | sau 10 |

**Hành vi mặc định.** Mọi tính năng v1.x đổi hành vi đều sau một bit có giá trị reset = hành vi
hôm nay: `CLK_MISS_OFF` = 0 (bộ thu HS lane clock còn bật tới LP-11), `CLK_LOST_EN` = 0 (không
thêm vào `ErrControl`, nên không đổi luật đánh dấu burst mất và `ERR_STATUS.LP` của controller),
`ULPS_EN` = 0, `HSRX_EARLY` = 0, `T_INIT` = 0, `ESC_TMO` = 0; `HS_TMO` reset = 2^20 như watchdog
cố định hôm nay. Hai ngoại lệ có chủ ý: (1) `RxSkewCalHS` thành mức: controller đếm cạnh lên ở
lane 0, nên `CNT_EXT[31:16]` không đổi, các case `deskew` của DV là bằng chứng; (2) reset đường
thu khi cổng đóng luôn bật từ bước 4 (`burst_rst_en_i` = ¬`DES_RST_DIS` thay cho PA5; từ bước 5 là `des_rst`),
vì PA5 = 0 đã hỏng trên bo; chỉ tắt được bằng bit thử `DES_RST_DIS`; các tuỳ chọn `S274_PA5=0` /
`FW=brst0` của mô phỏng chuyển sang bit này.

## 5. PPI

### 5.1 Nguyên tắc

PPI là giao diện tham khảo giữa PHY và lớp giao thức, nằm ở một phụ lục của đặc tả D-PHY [S15];
tên tín hiệu giống nhau giữa các hãng nhưng độ rộng, miền clock và chi tiết thời gian khác nhau
[S1][S4][S8][S9]. Bow32 lấy tập tín hiệu phía thu cho CSI-2 (không có phần TX, turnaround,
contention), 8 bit mỗi lane, giữ tên công khai, và ghi lại mọi chỗ lệch. RTL dùng struct trong
`bow_ppi_pkg` (`ppi_hs_t` mỗi lane ở miền byte, `ppi_lp_t` ở miền lp); wrapper tuỳ chọn đưa ra
cổng phẳng với tên PPI khi ghép với PHY hay controller của hãng khác.

### 5.2 Tín hiệu

| Tín hiệu | Rộng | Hướng | Miền | Ý nghĩa ở Bow32 |
|---|---|---|---|---|
| `RxByteClkHS` | 1 | PHY → CTRL | (clock) | byte clock (bit rate / 8), một cho mọi lane; dừng khi cổng đóng (clock không liên tục) [S1][S3]. Bản 16 bit (v2) gọi là `RxWordClkHS` (bit rate / 16) [S4][S9] |
| `RxDataHS[l]` | 8 (16) | PHY → CTRL | byte | byte đã căn sau SoT, bit 0 = bit đến trước [S1] |
| `RxValidHS[l]` | 1 (2) | PHY → CTRL | byte | byte hợp lệ; không có backpressure: phía nhận phải lấy mọi byte [S1][S4][S8]; **có thể có khe** (5.3) |
| `RxActiveHS[l]` | 1 | PHY → CTRL | byte | lên khi hết `SETTLE` (bắt đầu dò sync), xuống sau khi thấy LP-11 + 2 byte clock |
| `RxSyncHS[l]` | 1 | PHY → CTRL | byte | xung, cùng chu kỳ với byte đầu sau sync |
| `RxSkewCalHS[l]` | 1 | PHY → CTRL | byte | v1: xung khi nhận ra burst deskew; v1.x: mức tới hết burst [S1][S4] |
| `ErrSotHS[l]` | 1 | PHY → CTRL | byte | v2: sync sai 1 bit đã được nhận, đi cùng `RxSyncHS` [S1][S4]; v1: 0 |
| `ErrSotSyncHS[l]` | 1 | PHY → CTRL | byte | xung: burst không đồng bộ được; v1 ở cuối burst, v2 ngay khi HS-zero kết thúc |
| `Stopstate[l]`, `StopstateClk` | 1 | PHY → CTRL | lp (mức) | lane ở `Stop` [S1][S4] |
| `RxClkActiveHS` | 1 | PHY → CTRL | lp (mức) | lane clock ở HS và cổng mở [S1][S4] |
| `UlpsActiveNot[l]`, `UlpsActiveNotClk` | 1 | PHY → CTRL | lp (mức) | tích cực thấp: 0 khi lane ở ULPS (v1.x; v1: nối 1) [S1][S4] |
| `RxUlpsEsc[l]` | 1 | PHY → CTRL | lp (mức) | tích cực cao: lệnh ULPS đã nhận (v1.x; v1: nối 0) [S1][S4] |
| `RxUlpsClkNot` | 1 | PHY → CTRL | lp (mức) | tích cực thấp: lane clock vào ULPS (v1.x; v1: nối 1) [S1][S4] |
| `ErrControl[l]`, `ErrEsc[l]`, `ErrSyncEsc[l]` | 2 | PHY → CTRL | lp, **bộ đếm gray** | v1.x: mỗi sự kiện tăng bộ đếm một bước, reset 0; controller coi mỗi lần đổi giá trị là ≥ 1 sự kiện (5.3, mục 4.11). v1 (bước 2–5): xung một chu kỳ ở bit 0, controller chạy cùng clock |
| `ErrControlClk` | 2 | PHY → CTRL | lp, bộ đếm gray | Bow32: lỗi chuỗi LP của lane clock, cùng dạng với `ErrControl`; D-PHY chặn khi `CLK_CONT` = 1 (5.3) |
| `RxLPDTEsc`, `RxDataEsc`, `RxValidEsc`, `RxClkEsc`, `RxTriggerEsc` | | PHY → CTRL | lp | để sau: nối hằng |
| `Enable[l]`, `EnableClk` | 1 | CTRL → PHY | bất kỳ (PHY đồng bộ) | bật lane [S3][S4]; AND với `CTRL.EN` và `LANE_EN` của D-PHY |
| `PhyReady` | 1 | PHY → CTRL | lp (mức) | Bow32: AFE sẵn sàng và PHY bật (giống `INIT_DONE` của PG202 [S3]) |

`ForceRxmode` không có trên PPI của Bow32: `CMD.REINIT` của D-PHY làm việc đó.

### 5.3 Chỗ Bow32 lệch và vì sao

| Chỗ lệch | Vì sao |
|---|---|
| `RxValidHS` có khe giữa burst | FIFO RX của XPHY (adapter Versal) không có word ở vài chu kỳ đầu burst và đôi khi giữa burst; khe đi qua aligner ra PPI. Macro ASIC không có khe, nhưng controller phải chịu được (ghép lane đã chịu) |
| `RxActiveHS` lên ở cuối `SETTLE`, trước sync | để controller (ghép lane) biết burst bắt đầu cả khi sync hỏng; PG435 cũng ghi `RxActiveHS` không có quan hệ thời gian cố định với `Stopstate` [S4] |
| `ErrSotSyncHS` ở cuối burst (v1) | giữ aligner đã kiểm trên bo; v2 báo sớm (mục 4.5) |
| `RxSkewCalHS` là xung (v1) | như trên; v1.x thành mức |
| Lỗi miền lp ra dạng bộ đếm gray 2 bit (v1.x) | controller không có `lp_clk`: lấy mẫu bộ đếm gray ở miền luôn chạy của nó là CDC sạch và không mất sự kiện trong giới hạn tốc độ của mục 4.11; một xung (như PHY công khai) hay một toggle thì mất. PG202 và PG435 cũng để các tín hiệu này ở những miền khác nhau [S1][S4]; wrapper cổng phẳng đổi qua lại. v1 giữ xung cùng clock để bước 2 tương đương từng chu kỳ với hôm nay |
| Thêm `ErrControlClk` | hôm nay lỗi LP của lane clock cũng đánh dấu burst mất (`bow_csi2rx.sv:383`, trừ khi `CLK_FORCE`; DV `loss`); PPI công khai chỉ có `ErrControl` của data lane, còn controller sau khi tách không biết `CLK_CONT`, nên D-PHY chặn sẵn |
| `ErrControl` gồm cả HS timeout và CLK_LOST (khi `CLK_LOST_EN` = 1) | controller chỉ cần biết "có thể đã mất một burst" (luật `drop_i` hôm nay); D-PHY tách chi tiết trong `ERR_STATUS` riêng |
| Byte clock chạy thêm sau `RxActiveHS` xuống | với máy phát đúng T_CLK-POST, D-PHY bảo đảm `RxActiveHS` xuống khi lane clock còn chạy (mục 5.4); không bảo đảm được thì báo LATE_EOT thay vì để controller treo burst |
| Một `RxByteClkHS` cho mọi lane | mọi lane lấy mẫu bằng cùng lane clock; như PG202 và Lattice [S1][S8] |
| `PhyReady` thêm vào | AFE có hiệu chỉnh lúc khởi động (BISC; ASIC: DLL, offset): controller và driver phải biết khi nào PHY dùng được |

### 5.4 Một burst trên PPI

```
data lane (chân)    LP-11 │LP-01│ LP-00 HS-PREPARE │ HS-ZERO ........ │ B8 │ byte 0 … byte n │ HS-TRAIL │ LP-11
FSM data lane (lp)  Stop   HsRqst  Settle (SETTLE) ─────► Hs ................................................... Stop
hsrx_en, term_en    0       0    ┌───────────────────────────────────────────────────────────────────────┐   0
RxActiveHS (byte)   0       0      0                   ┌───────────────────────────────────────────────────────┐ (+2 byte clock)
RxSyncHS                                                         ┌┐ cùng byte 0
RxValidHS                                                        ┌──────────── (khe có thể có: XPHY) ───────────┐
RxDataHS                                                         byte 0, 1, …, n, byte rác của trail
Stopstate (lp)      1       0 ..................................................................................... 1
lane clock          HS (CLK-PRE) ............................................ clock chạy thêm T_CLK-POST ≥ 60 ns + 52 UI [S10]
```

Byte rác của HS-TRAIL và lúc chuyển về LP đi ra PPI như byte thường [S8]; controller cắt packet
theo WC. Sau khi data lane về LP-11, lane clock còn chạy ít nhất T_CLK-POST: ở 80 Mbit/s là
710 ns (~7 byte clock), ở 2,5 Gbit/s là 81 ns (~25 byte clock). `RxActiveHS` xuống sau ~35 ns (phát
hiện LP-11) + 2 byte clock: còn ≥ 4 byte clock cho ghép lane đánh dấu cuối burst trước khi clock
dừng, ở mọi tốc độ. Lattice đặt điều kiện tương tự (khoảng LP tối thiểu giữa hai burst tính theo
byte clock) cho hard D-PHY của họ [S8].

### 5.5 Hồ sơ PPI của controller

Controller của Bow32 chỉ dựa vào những gì liệt kê dưới đây. Một PHY khác (của một hãng, hay theo
PPI công khai của PG202, PG435, Lattice [S1][S4][S8]) ghép được qua wrapper cổng phẳng nếu thoả cột
"Cần"; cột "Chịu được" là những biến thể DV phải phủ.

| Tín hiệu | Controller cần | Controller chịu được | Wrapper cho PHY chuẩn |
|---|---|---|---|
| `RxByteClkHS` | chạy suốt burst và ≥ 4 byte clock sau khi `RxActiveHS` xuống (sau bước 7: chỉ đủ để đẩy dấu cuối burst qua FIFO) | dừng giữa các burst; chạy liên tục | — |
| `RxActiveHS` | lên trước hoặc cùng chu kỳ với `RxSyncHS`; xuống sau byte cuối của burst | lên ở bất kỳ chỗ nào từ cuối SETTLE (Bow32) tới `RxSyncHS` (PHY khác) | — |
| `RxSyncHS` | một xung mỗi burst đồng bộ được, cùng chu kỳ với byte đầu | — | — |
| `RxValidHS` | không có backpressure | khe ở bất kỳ đâu trong burst (XPHY), hay không khe | — |
| `ErrSotSyncHS` | ≤ 1 xung mỗi burst | ở cuối burst (Bow32 v1) hay ngay sau HS-zero (v2, PHY khác); có hay không có `RxActiveHS` đi kèm | — |
| `RxSkewCalHS` | — (chỉ đếm cạnh lên ở lane 0) | xung hay mức | — |
| `ErrControl*`, `ErrEsc`, `ErrSyncEsc` | bộ đếm gray ở miền lp (v1.x, mục 4.11) | — | đổi xung của PHY (ở clock của PHY) thành bộ đếm gray |
| `ErrControlClk` | — | không có: lỗi LP của lane clock không đánh dấu burst mất | nối 0 |
| `Stopstate*`, `RxClkActiveHS` | mức; `RxClkActiveHS` xuống khi lane clock dừng (driver chờ nó trước khi hạ `Enable`) | — | — |
| `PhyReady` | mức | không có | nối 1, hay `INIT_DONE` của PG202 [S3] |
| `Enable` | PHY bật/tắt lane theo nó | — | — |

Bước 3 chạy `tb_csi2rx_ppi` với `bow_ppi_bfm` ở hai chế độ: thời gian của D-PHY Bow32, và thời gian
kiểu PHY chuẩn đi qua wrapper cổng phẳng (`RxActiveHS` lên cùng `RxSyncHS`, không khe,
`ErrSotSyncHS` sớm, lỗi dạng xung, không `PhyReady`). Chỉ khi cả hai chạy sạch thì mục tiêu 4 của
mục 1.1 mới coi là đạt ở mức mô phỏng; với PHY của một hãng cụ thể vẫn phải kiểm riêng.

## 6. Bộ điều khiển CSI-2 sau khi tách

### 6.1 Giữ lại và chuyển đi

| Phần | Sau khi tách |
|---|---|
| Ghép lane (`bow_csi2_lane_merge`): FIFO 8 byte mỗi lane, chịu lệch 6 byte clock, `sop`/`eob`, SKEW | **giữ**; đầu vào là PPI (`RxActiveHS` thay `arm`, `RxSyncHS` thay `sot`) |
| Lớp packet (`bow_csi2_packet`): ECC, CRC 1–4 byte/chu kỳ, VC/DT, FS/FE, EXTRA, LOG entry | **giữ** |
| Unpack, FIFO pixel 2 clock, đầu ra AXI4-Stream, `FRAME_ERR`, SKIP | **giữ** |
| Bộ lọc VC/DT (một luồng) | **giữ**; thành router N luồng sau (mục 6.5) |
| LOG (`bow_csi2_capture`, nửa LOG) | **giữ** |
| Đánh dấu "burst mất ở mức LP" (`lpl_*`, `drop_i`) | **giữ**, nguồn là `ErrControl`/`ErrControlClk` của PPI (v1: xung cùng clock; v1.x: bộ đếm gray lấy mẫu ở `vid_clk_i`, sau bước 7 ở `csi_clk`), sang miền byte bằng req/ack gộp như hôm nay (mục 4.11) |
| Đếm `ErrSotSyncHS` (`CNT_SOT*`), deskew (`CNT_EXT[31:16]`), `ERR_STATUS.SOT/LP` | **giữ**, nguồn là PPI; `CNT_SOT*` là bộ đếm SoT duy nhất |
| Máy LP, termination, cổng clock, SETTLE, phát hiện mất clock, aligner, `byte_rst`, nạp tap, đồng hồ đo, RAW, `PHY_CFG`, trạng thái PHY | **chuyển** sang `bow_dphy_rx` / adapter AFE |
| Tham số `DlyVid`, `HasPhy` | `DlyVid` **bỏ** (adapter lo); `HasPhy` giữ (`INFO[4]`) |

Ghép lane ở lại controller như cách AMD chia: D-PHY không xử lý lệch giữa các lane, khối *Lane
Management* nằm trong CSI-2 RX, sau PPI [S3][S6]. Lattice thì có lane aligner tuỳ chọn ngay trong
IP D-PHY RX mềm [S8]: một lựa chọn để ngỏ khi ghép với controller của hãng khác.

### 6.2 Cổng của `bow_csi2rx` sau khi tách

Bus + `irq_o` (như hôm nay); `vid_clk_i` (đầu ra, FIFO phía đọc, và miền lấy mẫu các tín hiệu lp
của PPI, mục 4.11); PPI (`RxByteClkHS` và nhóm `ppi_hs_t` mỗi lane ở miền byte, `ppi_lp_t` ở miền
lp, `Enable` mỗi lane); `irq_i` của D-PHY (vào `IRQ_STATUS[5]`). Không có đường thanh ghi nào giữa
hai khối: `bow_mipi_rx` giải mã cửa sổ 4 KiB và chuyển mỗi phần cho khối của nó. `bow_mipi_rx` ghép
`bow_dphy_rx` + `bow_csi2rx` và có đúng các cổng của `bow_csi2rx` hôm nay ở bước 2, cổng AFE từ
bước 5.

### 6.3 Chuyển bản đồ thanh ghi

Bản đồ `CSI2RX` ([csi2rx.md](csi2rx.md) mục *Bản đồ thanh ghi*) giữ nguyên ở `0x000`–`0x0FC`
(controller), `0x400` (LOG); D-PHY ở `0xC00`. `INFO[6]` mới của controller = "D-PHY ở `0xC00`".

**Không có alias.** Giữ các địa chỉ PHY cũ làm alias (chuyển địa chỉ, ghép `STATUS` và
`CNT_MISC`, dịch `DLYn`/OWN, đổi bước của RAW, một bus "xem thanh ghi" giữa hai khối) chỉ để
firmware cũ chạy được trên bitstream mới. Trong Bow32, firmware và bitstream build từ cùng một
commit, nên alias là logic và kiểm chứng cho một trường hợp không xảy ra, rồi bị bỏ trên ASIC.
Driver thay vào đó đọc `INFO[6]`: 1 → mọi thanh ghi PHY ở D-PHY; 0 → bitstream trước bước 4: driver báo
`csi2rx: bitstream before the D-PHY split, rebuild it` và từ chối chạy (không giữ hai đường mã).
Hệ quả: sau khi gộp bước 4, bo nào cũng phải nạp bitstream mới cùng firmware mới (PDI của Huins
build trên hw-station-1).

| Thanh ghi hôm nay | Sau khi tách (`INFO[6]` = 1) |
|---|---|
| `INFO` [4] PHY, [5] DLY_VID, [15:8] MHz | [4] giữ; [5] đọc 0 (thay bằng `INFO[23]` của D-PHY); [15:8] = MHz của clock của chính controller (`vid_clk`, sau bước 7 `csi_clk`), bão hoà ở 255; timer PHY dùng `INFO[17:8]` 10 bit của D-PHY; [6] mới = 1 |
| `CTRL.PHY_EN`, `LANES`, `LANES4` | giữ: lái `Enable` của PPI (PHY_EN ∧ lane đang dùng) |
| `CTRL.CLK_FORCE` [3] | `CTRL.CLK_CONT` của D-PHY; bit [3] của controller đọc 0 |
| `PHY_CFG` (0x00C) | `TIM0` của D-PHY (cùng bố cục, cùng đơn vị); `0x00C` của controller đọc 0 |
| `STATUS` LP/HS/CE/BYTECLK_OK/PHY_RDY | `LANE_LP`, `LANE_HS`, `AFE_STATUS` của D-PHY; `IN_FRAME` giữ ở controller |
| `ERR_STATUS` [0] SOT, [9] LP | giữ (nguồn PPI; [9] gồm cả `ErrControlClk`) |
| `CNT_SOT`, `CNT_SOT23` | giữ (nguồn PPI): bộ đếm SoT duy nhất |
| `CNT_BURST`, `CNT_BURST23` | `CNT_BURST0`…`CNT_BURST3` của D-PHY (32 bit) |
| `CNT_MISC` [15:0] vào HS lane clock, [23:16] lỗi LP, [31:24] | `CNT_CLK`, `CNT_LPERR` của D-PHY (32 bit); [31:24] giữ ở controller |
| `CNT_CLR` | chỉ xoá bộ đếm của controller; `bow_csi2rx_clear()` ghi thêm `CMD.CNT_CLR` của D-PHY |
| `BYTECLK` (0x064) | `BYTECLK` của D-PHY |
| `DLY0`…`DLY3` (0x070–0x07C) | `DLY0`…`DLY3` của D-PHY: [9:0] mã đang lái, PEND, OWN chỉ đọc (mục 4.10) |
| `RAW_CTRL` (0x084), `RAW` (0x800 + 4i) | `RAW_CTRL`, `RAW` (0x200 + 8i) của D-PHY |
| `IRQ_STATUS` | thêm [5] PHY (= `irq_o` của D-PHY) |
| GPIO PA4/PA5/PB6/PB7 (top Huins) | `AFE_CTRL.PD`, `des_rst` luôn bật, `AFE_STATUS[15:8]`; top camera Huins thôi nối bốn chân GPIO này |

Ngắt: D-PHY có `irq_o` riêng; trong Bow32 nó vào `IRQ_STATUS[5]` của controller và chung đường
`irq_fast[7]`; SoC khác có thể nối riêng (hai đường `irq_fast[13:14]` còn trống).

### 6.4 Driver và luồng hiệu chỉnh

| `sw/common/src/bow_dphy_rx.c` (mới) | `sw/common/src/bow_csi2rx.c` (giữ) |
|---|---|
| `bow_dphy_rx_probe()`, `bow_dphy_rx_info()` | `bow_csi2rx_probe()` (đọc `INFO[6]`: 0 → báo bitstream cũ và dừng) |
| `bow_dphy_rx_power(on)`: bật / tắt hẳn AFE (`AFE_CTRL.PD`), không bao giờ gọi trong start/stop; `bow_dphy_rx_wait_ready(ms)`; `bow_dphy_rx_reinit()` (thay PA4: chạy lại hiệu chỉnh nội, mọi OWN xoá) | `bow_csi2rx_start(lanes, dt, lane_rate)`: gọi `bow_dphy_rx_timing()` rồi bật `CTRL`; không đụng `AFE_CTRL` |
| `bow_dphy_rx_timing(lane_rate)`: công thức `SETTLE` của mục 4.4 từ `INFO2`, `clk_miss_cycles()` chuyển sang đây; kết thúc bằng `CMD.APPLY` | `bow_csi2rx_stop()`: chờ `RxClkActiveHS` = 0 (`LANE_HS[17]`) rồi mới hạ `PHY_EN`, như hôm nay chờ `STATUS.CE`; `set_rx()`, `clear()` (+ `CMD.CNT_CLR`), bộ đếm, `link_check()`, `wait_frame()`, LOG |
| `bow_dphy_rx_set_delay(l, code)`, `release_delay(l)` (`CMD.DLY_REL`), `get_delay(l)` (đọc hai lần), `wait_delay(ms)` (`PEND` = 0 và mã = `dly_q` trên lane có OWN) | `extra_bytes()`: byte trail của AFE lấy từ `INFO2[23:16]` thay cho "+8 nếu `DLY_VID`" |
| `bow_dphy_rx_deskew(mode, ms)`, `deskew_result()` | `bow_csi2rx_calibrate()`, `bow_csi2rx_margin()`: thuật toán giữ nguyên, delay qua `bow_dphy_rx_*`, lỗi từ controller |
| `bow_dphy_rx_prbs()`, `raw()`, `byteclk_hz()`, `print_status()`, `print_delays()` | `print_status()` (gọi phần PHY bên trái) |

`cam_sensor.c` thôi đặt PA5; lệnh `phy` của `csi2_test` đọc `AFE_STATUS`/`DLYn` của D-PHY,
`phy reinit` gọi `bow_dphy_rx_reinit()`. Driver bỏ mặt nạ `dly_written` và
`bow_csi2rx_forget_delays()`: lane nào còn giữ mã của phần mềm thì đọc OWN (phần cứng xoá OWN khi
AFE khởi động lại).

**Luồng hiệu chỉnh** (eye walk dùng bộ đếm lỗi của controller cộng delay của PHY):

```
1. bow_dphy_rx_power(1); bow_dphy_rx_wait_ready()        AFE: bias, hiệu chỉnh nội (Versal: XPLL + BISC)
2. bow_csi2rx_start(); cảm biến stream                    PPI Enable, timer theo lane_rate
3. có bộ máy deskew và cảm biến gửi burst deskew?
     có:   bow_dphy_rx_deskew() → DSK_STATUS, DSK_EYEn       hiệu chỉnh trong phần cứng (mục 4.6), rồi bước 5
     không: điểm xuất phát = bow_dphy_rx_get_delay() (mặc định / BISC); link sạch ở đó thì vẫn đi bước 4
4. eye walk: mỗi điểm: bow_dphy_rx_set_delay() → wait_delay() (PEND = 0, mã = dly_q) → chờ 50 µs →
            bow_csi2rx_clear() → tốt khi CNT_LINE ≥ 32 trước lỗi CSI2RX_ERR_TAP (SOT, ECC, CRC, TRUNC, SKEW)
   pass 1 mọi lane cùng mã (hoặc đi từ điểm xuất phát), pass 2 từng lane; chọn tâm dải tốt dài nhất
5. bow_csi2rx_margin(): BER ở tâm và tâm ± k, trên dữ liệu thật (cả sau deskew); chỉ báo
6. định kỳ / theo nhiệt độ: deskew định kỳ (MODE 2) hoặc lặp 4–5 khi tỉ lệ ECC_CORR/CRC vượt ngưỡng
```

Stop/start (`bow_csi2rx_stop()`, `bow_csi2rx_start()`) giữ nguyên `DLYn` và OWN: tap đã hiệu chỉnh
còn đó ở lần `cam` sau, như hôm nay trên cả KV260 và Huins, vì `Enable` không kéo `pd` (mục 3.6).

### 6.5 Để ngỏ

- **Miền clock liên tục (F7 của review, bước 7):** FIFO 2 clock ngay sau ghép lane; packet, unpack,
  router chạy ở `csi_clk` liên tục (`vid_clk` trên FPGA); dấu cuối burst đi qua FIFO cùng dữ liệu.
  Sự kiện FE, ngắt, `FRAME_SUM` không còn phụ thuộc byte clock.
- **Router VC/DT** N bộ lọc, metadata mỗi frame, AXI4 master: [../csi2rx_review.md](../csi2rx_review.md)
  mục 6.
- **8 lane / PPI 16 bit:** word của ghép lane thành 8 byte; header 4 byte không còn lấp đầy word,
  lớp packet phải xử lý header ở nửa word và packet kết thúc giữa word (như PPI 16 bit × 4 lane).
- **CSI-2 v2.x:** VCX (`ECC[7:6]` thành VC[3:2] thay vì bị bỏ), RAW16/RAW20, LRTE/EPD (nhiều packet
  mỗi burst: lớp packet thành vòng lặp, cờ EXTRA hôm nay thành phân tách packet).

## 7. Hiệu chỉnh

### 7.1 Vì sao BISC nằm ở mép sớm của eye trên bo Huins

**Số liệu** (IMX274, 4 × 1440 Mbit/s, 2026-11-10, [../camera_huins.md](../camera_huins.md) mục 6.3,
9): trễ BISC 122/75/118/130 tap, tâm sau eye walk 300/184/264/228, tức BISC sớm hơn tâm
178/109/146/98 tap; eye 352–360 trên 512 tap; ở trễ BISC ~11 % dòng có lỗi CRC. BISC cho cùng kết quả
khi cảm biến còn bị reset và các lane ở LP-00 (lúc nạp PDI) và khi lane clock đang chạy
(`phy reinit` lúc stream). Kích thước tap thật chưa đo (AM010 [S23] chỉ bảo đảm 512 tap ≥ 625 ps;
1 UI = 694 ps).

**Giả thuyết** (chưa kiểm):

| ID | Giả thuyết | Phù hợp với số liệu | Kiểm bằng |
|---|---|---|---|
| H1 | BISC căn trễ cho một strobe **căn mép** dữ liệu (như DQS khi đọc bộ nhớ), phần dịch 1/4 chu kỳ để vào giữa eye thường do một thuộc tính pha của XPHY làm; adapter đặt `RX_CLK_PHASE_P/N` = `SHIFT_0` vì lane clock D-PHY đã **căn giữa** dữ liệu, nên điểm lấy mẫu lệch về một mép | điểm BISC nằm từ mép sớm tới ~1/4 eye, mọi lane cùng phía | bản build với `RX_CLK_PHASE` khác **[CHƯA CHẮC: có hợp lệ với `DQS_SRC` EXTERN]**; hoặc PHY MIPI RX của AMD (PG435) trên cùng chân làm tham chiếu và đọc trễ của nó |
| H2 | phần bù lệch của dây chuyển strobe (inter-nibble, inter-byte) khác nhau giữa các nibble | độ lệch khác nhau giữa các lane (98…178 tap) | so lane cùng nibble strobe với lane nhận strobe chuyển tiếp |
| H3 | lệch thật ở cảm biến/bo (lane 1 sớm hơn các lane khác 1 bit ở RAW) | một phần chênh lệch giữa các lane | eye walk cho từng lane đã bù; không giải thích phần chung |

**Hệ quả kiến trúc** (đúng với mọi giả thuyết): (1) độ lệch không phải hằng số giữa các lane, nên
cộng một hằng sau BISC không đủ; (2) tự hiệu chỉnh của PMA chỉ là điểm xuất phát (`DLYn.OWN` = 0),
điểm cuối phải đo trên dữ liệu; (3) tự hiệu chỉnh của AFE ASIC (nếu có) phải được thiết kế cho
clock **căn giữa** được chuyển tiếp và được kiểm bằng phép đo eye trên dữ liệu ngay trên silicon
đầu tiên; (4) mỗi lane có delay riêng.

**Reset FIFO khi cổng đóng (PA5).** Với PA5 = 1, `SETTLE` sạch 65–170 ns và 95 ns chạy hơn 3,2
triệu burst không lỗi; PA5 = 0 hỏng sau lần bật lại bộ thu đầu tiên ở mọi `SETTLE` 50–150 ns, mô
hình FIFO của XPHY chưa giải thích được. PA5 reset FIFO RX của XPHY trong lúc cổng byte clock đóng
(`bow_dphy_io_versal.sv:502-507`); cổng chỉ đóng khi lane clock rời HS, và IMX274 giữ lane clock ở
HS suốt frame, nên reset này xảy ra **mỗi frame**: các burst dữ liệu trong một frame chưa bao giờ
có reset đi trước. Thành yêu cầu: đường thu của AFE bắt đầu từ trạng thái xác định mỗi lần cổng
byte clock mở lại, tức một lần mỗi giai đoạn HS của lane clock (mỗi frame với IMX219 / IMX274;
mỗi burst với lane clock dừng mỗi burst); phần số không được giả định có reset giữa các burst dữ
liệu (`des_rst`, mục 3.2). Không có núm tắt ngoài bit thử `DES_RST_DIS`. Adapter Versal giữ đúng
thời điểm đã kiểm: `RX_RST` tính từ `clk_gate_en` ở miền `ctrl_clk`, như `burst_rst_q` hôm nay.

### 7.2 Kiến trúc đề xuất cho ASIC

| Mức | Khi nào | Cách | Ai làm |
|---|---|---|---|
| 0. Hiệu chỉnh nội của AFE | bật nguồn, `cal_start` | offset bộ so sánh HS, trim termination (RCAL), khoá DLL của delay line: bước delay = phân số của chu kỳ tham chiếu, ổn định theo VT | AFE |
| 1. Mặc định | ≤ 1,5 Gbit/s không có deskew | mã giữa tầm; yêu cầu lệch trong AFE ≤ 0,15 UI (mục 3.3) để link chạy ngay | AFE (thiết kế) |
| 2. Deskew ban đầu | cảm biến gửi burst deskew (bắt buộc trên 1,5 Gbit/s theo nguồn công khai [S9][S14][S20]) | bộ máy deskew quét mỗi lane, đặt tâm (mục 4.6) | `bow_dphy_rx` |
| 3. Eye walk | không có burst deskew, hoặc kiểm lại | phần mềm, bộ đếm lỗi của controller (mục 6.4) | driver |
| 4. Deskew định kỳ | burst deskew ngắn trong blanking | bám ±1–2 bước quanh hai mép đã biết | `bow_dphy_rx` |
| 5. Bám nền | luôn (tuỳ chọn, v3) | sampler giám sát quét mép eye trên dữ liệu thật, dời mã chính ±1 bước không glitch | AFE (sampler) + `bow_dphy_rx` |
| 6. Theo VT | nhiệt độ đổi quá ngưỡng (cảm biến nhiệt của SoC), hoặc tỉ lệ ECC_CORR tăng | chạy lại mức 3 hoặc 4 | driver |
| 7. Kiểm tra lề | sản xuất, chẩn đoán | `bow_csi2rx_margin()`: BER ở tâm ± k | driver |

Mức 5 tốn một sampler + một delay line mỗi lane: câu hỏi mở cho đội analog (Q4). Không có mức 5,
trôi VT giữa hai lần deskew định kỳ phải nằm trong lề (đo ở mục 8.5).

### 7.3 Trên FPGA

| | KV260 (UltraScale+) | Huins (Versal) |
|---|---|---|
| Điểm xuất phát | tap 0 (`IDELAYE3` không VTC) | trễ BISC (bám VT tới khi nạp tap) |
| Hiệu chỉnh | eye walk phần mềm (quét 0…511) | eye walk phần mềm (đi từ trễ BISC); luôn chạy ở lần khởi động đầu |
| Deskew | bộ máy kiểm bằng mô phỏng; trên bo không có burst deskew (IMX219 không gửi) | bộ máy kiểm bằng mô phỏng (bước 8); loopback `bow_dphy_tx` trên bo là tuỳ chọn và chỉ phủ HS |
| VT | không bù; hiệu chỉnh lại khi `link_check` thấy lỗi tap | nạp tap làm slice thôi bám VT: hiệu chỉnh lại định kỳ hoặc theo lỗi; giữ VT thì phải chấp nhận điểm BISC sớm |
| Lề | `margin` ±68/±66 tap, BER < 3,6×10^-10 mỗi điểm (720p60) | `margin` chạy trong mô phỏng; trên bo: lần chạy sau |

Cả hai đều hiệu chỉnh lúc chạy, trên dữ liệu; một bộ thu mã mở cho 7-series thì đặt tap lúc biên
dịch và không có đầu vào LP [S21]: không đủ khi tâm eye đổi theo route của từng lần build như
trên KV260.

## 8. Kế hoạch kiểm chứng

### 8.1 Theo lớp

| Lớp | Bench | Kích thích | Kiểm | CI |
|---|---|---|---|---|
| AFE (mô hình) | `bow_dphy_afe_model` tự kiểm (từ bước 8) | máy phát D-PHY mức bit | ngưỡng LP, termination, lấy mẫu, delay, cổng, `des_rst`, `clk_act` | có (Verilator) |
| D-PHY số | `tb_bow_dphy_rx` (mới, bước 6) + `tb_dphy_align` (giữ) | máy phát mức bit → `bow_dphy_afe_model`, hoặc `csi2_tx_model` ở cổng AFE | PPI so với scoreboard, timer, FSM, lỗi, ULPS, deskew, thanh ghi | có: thêm `hw/ip/dphy_rx/dv` vào `ci.yml` |
| Logic adapter | `bow_dphy_dly_xusp`, `bow_dphy_dly_xphy` (bước 5), trong `tb_bow_csi2rx` và bench riêng | ghi mã, `ready`, cổng | nạp khi mã đổi, `VtcWait` / `LdGap`, không nạp trước `ready`, `des_rst` | có (Verilator) |
| Controller | `tb_csi2rx_ppi` (mới) | `bow_ppi_bfm` theo `csi2_model.py gen --ppi`, hai chế độ thời gian (mục 5.5) | như DV hôm nay: pixel, bộ đếm, `FRAME_ERR`, LOG | có |
| Cả bộ thu | `tb_bow_csi2rx` (giữ, DUT = `bow_mipi_rx`) | `csi2_tx_model` (UltraScale+ / Versal) | như hôm nay: 105 case, một trong số đó là unit test aligner (301 case con) | có |
| Tương đương (bước 1–2) | Yosys eqy: `bow_csi2rx` trước và sau khi tách (cổng không đổi) | — | tương đương hình thức | có (thêm Yosys vào CI) |
| FPGA mức chân | `tb_bow_dphy_io_xusp`, `tb_bow_dphy_io_versal` (giữ; probe hộp trắng qua `bind`) | máy phát mức bit, unisim / secureip | adapter + phần số | không (cần Vivado) |
| Hệ thống | `sim/` (giữ) + test `dphy` mới | firmware thật, mô hình IMX219/IMX274 | `camera`, `csi2`, `camera274`, `csi2_274`, `video274`, `dphy` | có |
| Bo | `csi2_test`, `camera`, `video` | cảm biến thật; loopback `bow_dphy_tx` (tuỳ chọn) | mục 8.5 | không |

### 8.2 Mô hình AFE số thực (`bow_dphy_afe_model`)

Mô hình hành vi SystemVerilog dùng `real` cho điện áp và thời gian (RNM), chạy được với Verilator
(CI) và với trình mô phỏng thương mại; cổng = giao diện AFE (mục 3.2), phía chân là cặp `real`
P/N mỗi lane do máy phát mức bit lái. Bản đầu (bước 8) có những gì bộ máy deskew, ULPS và test
LP cần (delay line, eye, bộ thu LP, termination); bản đủ, khớp datasheet của AFE thật, là điều kiện
của sign-off (bước 11, mục 9.7).

- **LP:** bộ so sánh với ngưỡng và hysteresis; gai ngắn hơn ngưỡng lọc bị bỏ; trễ t_LPRX ngẫu nhiên
  trong khoảng khai báo.
- **Termination:** đóng termination khi máy phát còn lái LP-01/LP-10 làm mức LP sai (mô hình báo
  lỗi); đo T_D-TERM-EN từ LP-00 ở chân tới termination có hiệu lực, so với 35 ns + 4 UI [S10].
- **HS:** ngưỡng vi sai, offset; lấy mẫu ở cạnh clock (đã cộng lệch clock–data mỗi lane, jitter
  ngẫu nhiên, delay theo mã); 1:8 với pha bộ chia ngẫu nhiên mỗi burst; `hs_data` là rác (word cũ
  hay ngẫu nhiên) khi tắt, để phần số không dựa vào nó; phát ở cạnh xuống như mục 3.3.
- **Delay line:** mã → ps (phi tuyến, bước theo VT qua núm "nhiệt độ"), thời gian áp mã, glitch
  khi đổi mã giữa burst (tuỳ `AfeDlyGf`).
- **Cổng và reset:** cổng đồng bộ: enable đổi ở bất kỳ pha nào của clock không tạo runt; kiểm
  `clk_gate_en` chỉ đổi khi clock tĩnh, trừ `CLK_CONT` và `Enable` = 0; đếm runt (phải 0);
  assertion: khi cổng mở và lane clock chạy, `hs_byte_clk` vẫn chạy dù `des_rst` = 1 (`des_rst`
  không bao giờ dừng byte clock); `clk_act` theo timing của mục 3.3.
- **Nguồn:** `pd`, `lane_pd`, `ready` sau thời gian khai báo, `cal_start`; đầu ra kẹp 0 khi tắt.
- **Test:** loopback nội (`tst_data` qua đường thu), quan sát DC (`hs_raw`).
- **Eye:** BER theo lệch và jitter: quét mã cho ra bản đồ eye để kiểm bộ máy deskew và eye walk
  trên cùng một "eye" mà phần mềm thấy.

### 8.3 Bench D-PHY và PPI BFM

- **`tb_bow_dphy_rx`:** máy phát D-PHY mức bit (tách từ `tb_bow_dphy_io_xusp` và `csi2_tx_model`)
  với mọi góc thời gian; scoreboard theo burst (byte mỗi lane, `RxSyncHS`, lỗi); kiểm bất biến
  (LP-00 → `term_en` ≤ ngân sách, `clk_gate_en` chỉ đổi khi clock tĩnh, `RxActiveHS` xuống trước
  khi clock dừng nếu T_CLK-POST đúng, delay chỉ đổi theo luật mục 3.5).
- **Case mới bắt buộc** (mỗi case gắn với một quyết định của đặc tả): `T_INIT` (cảm biến giữ LP-11
  trước burst đầu ngắn hơn `T_INIT`; VBLANK ngắn hơn `T_INIT`; bộ thu bật giữa stream); stop/start
  giữ `DLYn`, OWN và không đụng `pd`; `ErrControlClk` (lỗi LP của lane clock, bị chặn khi
  `CLK_CONT`); bộ đếm gray của PPI ở tốc độ sự kiện tối đa và clock controller ở giới hạn
  `lp_clk` / 32; `DLYn` (ghi cả word, chỉ byte 3, `DLY_REL`, ghi khi bộ máy deskew chạy → ABORT,
  `ready` xuống → OWN xoá, `PEND`); bộ máy deskew (qua ranh giới UI, tầm quét > 2 UI, mã đầu ở mép
  eye); `LANE_MAP` / `LANE_POL` (cả lane clock: LP-01 ↔ LP-10); `ESC_TMO`.
- **`bow_ppi_bfm`:** lái PPI ở mức byte theo file kích thích của `csi2_model.py gen --ppi`: khe
  `RxValidHS`, lệch lane (byte), thời điểm `RxActiveHS`, lỗi lp, clock dừng sớm (T_CLK-POST
  ngắn), burst deskew; hai chế độ thời gian: D-PHY Bow32 và PHY chuẩn qua wrapper cổng phẳng
  (mục 5.5). Mô hình Python giữ vai trò tham chiếu viết từ quy tắc, không từ RTL
  ([csi2rx.md](csi2rx.md) mục *Kiểm chứng*). Bench controller nhanh hơn nhiều so với đi qua mô
  hình D-PHY, nên chạy được nhiều seed.
- **Mutant:** mỗi thay đổi RTL của các bước 1–7 kèm mutant chứng minh test bắt được nó, như 57
  mutant của PR #17. Harness viết theo `hw/ip/mkv/dv` (Verilator, `make mutants`: bỏ một biện
  pháp nào cũng phải làm test fail); `hw/fpga/common/dv/mutants.py` là harness xsim của
  DDR/HyperRAM, không dùng làm mẫu ở đây.

### 8.4 Mô phỏng hệ thống

Mọi test của `sim/` chạy sau mỗi bước. Bước 1–3 không đổi kỳ vọng nào (refactor, mục 10); bước 4
và 5 đổi một số kỳ vọng, liệt kê ở bước 4 của mục 10. Test `dphy` mới (firmware `csi2_test` mở
rộng): `AFE_STATUS`; `phy reinit` qua `bow_dphy_rx_reinit()`; stop/start giữ `DLYn` và không có
xung nào trên `reinit_i` (testbench đếm cạnh); ULPS (mô hình cảm biến vào/ra ULPS); bộ máy deskew
với mô hình gửi burst deskew; PRBS qua loopback của mô hình AFE. Firmware build trước bước 4 trên
bitstream mới không được hỗ trợ (mục 6.3), nên không có test cho trường hợp đó.

### 8.5 FPGA

| Bo | Mục đích | Chạy gì |
|---|---|---|
| KV260 + IMX219 (2 × 912 Mbit/s) | adapter UltraScale+ và phần số không đổi | `csi2_test` `test` (18/18 hôm nay), `camera`, `video`; quét `SETTLE`; `margin 0 1800` |
| Huins + IMX274 (4 × 1440 Mbit/s) | adapter Versal, PPI có khe, 4 lane | `csi2_test` `test` (17 check sau PR #17), `camera`, `video`; quét `SETTLE` với `des_rst`; trễ BISC đọc qua `DLYn`; stop/start giữ tap |
| Huins + `bow_dphy_tx` (loopback, **tuỳ chọn**) | HS ngoài khả năng của cảm biến: burst deskew, PRBS, tốc độ khác | máy phát D-PHY tổng hợp được (`bow_dphy_tx`: PPI TX + bộ tuần tự LP/HS) và adapter TX của Versal. Loopback trong nibble của XPHY (`TXRX_LOOPBACK`) đi vòng qua `IBUFDS_DPHY` nên không có đường LP: chỉ phủ HS (deskew, PRBS), không phủ ULPS, escape, thời gian LP hay T_D-TERM-EN. Loopback qua chân cần cáp/bo FMC mà dự án chưa có, và chỉ khe của bo chuyển camera giữ năm cặp trong một bank XPIO ([../camera_huins.md](../camera_huins.md) mục 3) **[CHƯA CHẮC: khả thi]**. Điều kiện xong của bước 8 nằm trong mô phỏng |
| Buồng nhiệt (khi có) | trôi VT | hiệu chỉnh ở 25 °C, `margin` ở −40 / +85 °C ([../csi2rx_review.md](../csi2rx_review.md) mục 8) |

Bo Huins đang cho đội khác mượn: các bước 4–8 kiểm trên bo khi bo về; giữa chừng chỉ mô phỏng.
KV260 không có đầu ra D-PHY nên không làm loopback được.

### 8.6 Danh sách test hướng tuân thủ và coverage

Mô tả mục đích bằng lời của tài liệu này; giới hạn số lấy từ [S10]. Cột cuối: ✓ = đã có hôm nay,
+ = cần thêm.

| Nhóm | Test | Ở đâu | Hôm nay |
|---|---|---|---|
| Khởi tạo | LP-11 sau `ready` (`T_INIT`), LP-11 trước burst đầu ngắn, VBLANK < `T_INIT`, LP-00 standby không lỗi, bật/tắt lane giữa burst, `REINIT`, stop/start giữ `DLYn` | D-PHY, hệ thống | ✓ LP-00, + `T_INIT`, + stop/start |
| Chuỗi LP | HS-Rqst bị bỏ (LP-01 → LP-11), chuỗi sai ở mỗi trạng thái (data lane và lane clock), gai ngắn hơn / dài hơn bộ lọc, T_LPX tối thiểu | D-PHY | ✓ (`lp`, `loss`), + T_LPX |
| Vào HS | HS-PREPARE min/max có nhiễu kết thúc bằng `00 B8` giả, HS-ZERO đúng tối thiểu, quét `SETTLE` (giữ 22 / `0x13`), T_D-TERM-EN đo được, T_CLK-TERM-EN, T_CLK-SETTLE, CLK-PRE tối thiểu | D-PHY, AFE model, xsim | ✓ (xsim), + AFE model |
| Đồng bộ | sync ở mọi pha bit, sync sai 1 bit (`ErrSotHS`), sync hỏng (`ErrSotSyncHS`), deskew `FFFFh` ở cuối HS-zero, mẫu deskew trong dữ liệu | unit aligner, D-PHY | ✓ (301 case), + `ErrSotHS` |
| Dữ liệu, kết thúc | dữ liệu ngẫu nhiên, toàn 0 / toàn 1, HS-TRAIL min, T_EOT max, T_CLK-POST tối thiểu và ngắn hơn (LATE_EOT), burst 1 byte tới `HS_TMO` | D-PHY, controller (BFM) | ✓ một phần, + LATE_EOT |
| Lane | lệch lane tới giới hạn ghép lane (6 nhận / 7 bỏ), tập lane con, `LANE_MAP`, `LANE_POL` (cả lane clock), delay khác nhau mỗi lane | controller, D-PHY | ✓ (`skew`), + `LANE_MAP` / `LANE_POL` |
| Lane clock | không liên tục mỗi burst / mỗi frame, liên tục, T_CLK-MISS, `CLK_MISS_OFF`, `ErrControlClk`, cổng với enable bất đồng bộ, ULPS lane clock, glitch lúc vào HS (XPHY), CLK-TRAIL ngắn | D-PHY, AFE model, xsim | ✓ một phần, + ULPS, + cổng |
| Escape / ULPS | vào/ra ULPS data lane (`lane_pd` bật lại ở LP-10), lệnh lạ (`ErrEsc`), huỷ giữa chuỗi vào escape, `ESC_TMO` | D-PHY | + |
| Hiệu chỉnh | bộ máy deskew: eye rộng / hẹp / không có, lệch mỗi lane, qua ranh giới UI, tầm > 2 UI, mã đầu ở mép eye, burst định kỳ; eye walk; `margin`; trôi VT (núm nhiệt của mô hình) | D-PHY, hệ thống | ✓ eye walk, + bộ máy |
| Thanh ghi, CDC | byte enable mọi thanh ghi (`DLYn`: cả word, chỉ byte 3, `DLY_REL`), `PEND`, APPLY, reset giữa burst, bộ đếm gray của PPI, jitter CDC (`BOW_CDC_JITTER`) | D-PHY, cả bộ thu | ✓ (`be`), + `DLYn`, + gray |
| Analog (mô hình, silicon) | BER theo jitter và lệch, ngưỡng/hysteresis LP, termination, `ready`, loopback + PRBS ở tốc độ thật | AFE model, silicon | + |
| Hệ thống | các test `sim/`, `dphy` mới | hệ thống | ✓, + |

**Coverage** (covergroup ở bench D-PHY và bench controller): trạng thái và chuyển trạng thái của
FSM data/clock; giá trị timer ở biên (0, 1, tối đa); 8 offset của aligner × số lane × mẫu (sync,
deskew, sync sai 1 bit, nhiễu); khe `RxValidHS` (đầu burst, giữa, cạnh lên của `RxActiveHS`); độ
lệch lane 0…7; kết quả bộ máy deskew (tìm được, hẹp, không có, có trượt UI); mã delay ở hai đầu
tầm; vào/ra ULPS; mọi bit của `ERR_STATUS`; mọi trường thanh ghi bật/tắt. Tuân thủ thật trên
silicon cần bộ phát/phân tích giao thức D-PHY (ví dụ [S19]) và VIP thương mại (ví dụ [S15]), tức cần
đặc tả có bản quyền ở phía người chạy (mục 9.7).

## 9. Sẵn sàng ASIC

### 9.1 CDC / RDC

- Chạy công cụ CDC/RDC thương mại trên `bow_dphy_rx`, `bow_csi2rx`, `bow_mipi_rx` với danh sách
  đường qua miền ở mục 4.11 làm đặc tả; mỗi đường có một cell đồng bộ nhận diện được (`bow_sync`,
  `bow_cdc_pulse`, `bow_fifo_async` thay bằng cell / module đã được thư viện CDC biết), kể cả bộ
  đếm gray của PPI (`ErrControl*`) và cặp req/ack của `DLYn`.
- Bỏ các bus `bow_sync` từng bit của cấu hình (shadow + APPLY ở D-PHY; tương tự cho `CTRL` của
  controller, F12 của review).
- RDC: reset miền byte nhả khi byte clock chạy lại (burst sau): kiểm không flop nào của miền byte
  lái đường bất đồng bộ trong lúc reset; điều khiển AFE ở trạng thái an toàn trong mọi reset;
  `des_rst` là flop miền lp, không phải reset của phần số.
- Đầu vào bất đồng bộ từ AFE (`lp`, `ready`, `clk_act`…) được khai báo trong mô hình CDC của macro
  AFE.

### 9.2 DFT

- **Scan** cho mọi flop của ba miền (bus, lp, byte); reset bất đồng bộ điều khiển được khi scan
  (mux reset test ở bộ đồng bộ reset).
- **Mux clock test cho miền byte:** `hs_byte_clk` không có khi scan (AFE không chạy) → một mux
  clock (`scan_mode`) ở ranh giới `bow_dphy_rx` chọn clock test cho cả cây byte; mux phải là cell
  clock của thư viện. Tương tự cho `RxByteClkHS` đi vào controller (cùng cây).
- **Test ở tốc độ thật của logic (at-speed):** bộ điều khiển clock trên chip (OCC) cho miền byte và
  miền lp, lấy clock từ PLL của SoC qua mux clock test, để test chuyển tiếp (launch / capture) ở
  312,5 MHz và ở tần số `lp_clk`.
- **Ranh giới AFE:** flop bọc (wrapper) ở mọi tín hiệu AFE → số để điều khiển/quan sát khi scan;
  điều khiển số → AFE giữ trạng thái an toàn khi `scan_mode` (`pd` = 1, `term_en` = 0) trừ khi
  chạy test loopback hay khi `AFE_OVR` ép giá trị (mục 4.10: chỉ khi `scan_mode` hoặc khoá test).
- **MBIST:** FIFO pixel (512 × 45 trên Huins) thành SRAM macro + MBIST; RAM LOG (64 × 30) và RAW
  (64 × 64) nhỏ: làm bằng flop/latch (vào scan) hoặc đưa vào MBIST.
- **Test ở tốc độ thật của đường HS:** loopback nội của AFE (`tst_mode` = 1) + bộ sinh/kiểm PRBS
  của `bow_dphy_rx`; Mixel mô tả loopback tách khỏi chân để test sản xuất mà không cần TX [S17],
  Arasan có PRBS + loopback nội [S14]. `tst_clk` cần một clock cỡ bit rate từ SoC; mặc định test
  sản xuất chạy ở tốc độ giảm (`tst_clk` ≤ 500 MHz, mục 3.2), tốc độ thật chỉ khi PLL của SoC đủ
  nhanh.
- **Test DC của AFE:** ATE lái mức ở chân, đọc `LANE_LP` (bộ thu LP) và `hs_raw` (`tst_mode` = 2);
  termination đo trên chân với `term_en` ép qua `AFE_OVR` / `AFE_OVR_V0`; ATB cho bias và tham
  chiếu.

### 9.3 SDC (phác thảo)

Phác thảo không dùng cú pháp riêng của Vivado (`-datapath_only`, `set_input_delay` trên chân của
macro): thời điểm phát của nhóm đồng bộ so với `hs_byte_clk` lấy từ mô hình timing của macro AFE
(.lib, hay một .lib tạm viết từ số **[ĐỀ XUẤT]** của mục 3.3 khi chưa có .lib thật), đường bất
đồng bộ dùng `set_max_delay -ignore_clock_latency` (cú pháp kiểu PrimeTime; cách khai clock ra của
macro và tên lệnh tương đương ở công cụ khác **[CHƯA CHẮC]**).

```
create_clock -name bus_clk  -period 20.0  [get_ports clk_i]
create_clock -name lp_clk   -period 4.0   [get_ports lp_clk_i]                ;# 250 MHz
create_clock -name csi_clk  -period 3.333 [get_ports csi_clk_i]               ;# controller (bước 7)
create_clock -name byte_clk -period 3.2   [get_pins u_afe/hs_byte_clk]        ;# 2,5 Gbit/s, PPI 8 bit; nguồn ở chân macro
set_clock_groups -asynchronous -group bus_clk -group lp_clk -group byte_clk -group csi_clk
# hs_data, hs_valid, clk_hs_samp, mon_data: arc của .lib, phát ở cạnh xuống của hs_byte_clk (mục 3.3);
# tst_data: arc kiểm setup/hold của .lib so với cạnh xuống tại chân macro
# flop bắt đầu tiên: vùng đặt cell sát macro, nhánh clock riêng (L_tree ≤ 0,5 ns), kiểm sau CTS
# điều khiển tĩnh sang AFE, đầu vào bất đồng bộ từ AFE
set_false_path -to   [get_pins u_afe/{dly_code* dly_own* trim* pd lane_pd* lprx_en* atb_sel* tst_mode*}]
set_max_delay 2.0 -ignore_clock_latency -to [get_pins u_afe/{hsrx_en* term_en* clk_gate_en des_rst}]  ;# ngân sách T_D-TERM-EN
set_false_path -from [get_pins u_afe/{lp* clk_lp* ready cal_* status* dly_q* hs_raw* clk_act}]
# bus gray (con trỏ FIFO, đồng hồ đo, req/ack RAW và DLYn, ErrControl*): set_max_delay -ignore_clock_latency
#   ≤ một chu kỳ clock nguồn (hoặc ràng buộc skew của công cụ)
# cổng clock nằm trong AFE (không có cổng trong phần số); scan: set_case_analysis trên scan_mode
```

### 9.4 Công suất thấp

- **Miền nguồn** (UPF/CPF): AFE (nguồn analog, tắt được với `pd`), D-PHY số và controller (miền
  logic, tắt cùng camera); cách ly đầu ra AFE kẹp 0 khi AFE tắt; dịch mức nếu nguồn điều khiển
  của AFE khác lõi số.
- **Tắt lane:** lane không dùng: `lane_pd` (phần HS); `lprx_en` vẫn 1 khi `AFE_CTRL.PD` = 0 (bộ thu
  LP tốn ít, và mức LP phải đọc được khi bộ thu tắt), chỉ tắt cùng `pd`; logic lane đứng yên
  (không có byte clock, FSM ở `Off`).
- **ULPS:** phần HS của lane tắt, byte clock dừng, bộ thu LP còn bật; `lp_clk` còn chạy (v1.x).
  Sau: thức dậy không cần `lp_clk` (đầu ra bộ thu LP đánh thức bộ điều khiển clock của SoC).
- **Clock gating:** controller gate `csi_clk`/`vid_clk` khi không có luồng; byte clock đã tự dừng
  giữa các burst (clock không liên tục).

### 9.5 Ước lượng diện tích và timing

Số liệu FPGA hôm nay ([csi2rx.md](csi2rx.md) mục *Tài nguyên*): `bow_csi2rx` 1962 LUT / 2375 FF
(KV260, 2 lane), 2506 LUT / 2809 FF (Huins, 4 lane, out-of-context), trong đó phần sẽ thành D-PHY
số: 5 × `bow_dphy_lp` 422 LUT, 4 × `bow_dphy_align` (~90 LUT mỗi cái), nạp tap, đồng hồ đo, RAW,
một phần `bow_csi2rx_regs` (856 LUT). Ước lượng thô cho ASIC **[ĐỀ XUẤT, cần tổng hợp thử]**:

| Khối (4 lane) | FF | Cỡ (kGE) | Bộ nhớ |
|---|---:|---:|---|
| D-PHY số v1 (FSM, aligner, CDC, thanh ghi, bộ đếm 32 bit, đồng hồ đo) | ~1 100–1 400 | ~15–25 | RAW 64 × 32 bit (flop: ~+10 kGE) |
| + bộ máy deskew, PRBS (v2) | ~300–500 | ~5–10 | — |
| Controller (ghép lane, packet, unpack, đầu ra, thanh ghi, LOG) | ~2 000 | ~25–35 | FIFO pixel 512 × 45 (SRAM), LOG 64 × 30 |

Quy đổi theo kinh nghiệm: một flop có scan ~6–8 GE, logic tổ hợp cỡ ngang phần flop; diện tích
theo node lấy từ thư viện. Đường găng ở miền byte: trong bản Huins out-of-context hôm nay là unpack
(`n_q` → tổng pixel, 8 mức logic), không phải CRC 4 byte/chu kỳ ([csi2rx.md](csi2rx.md) mục *Tài
nguyên*); trong D-PHY là so sánh cửa sổ 24 bit × 8 offset của aligner. 312,5 MHz (PPI 8 bit,
2,5 Gbit/s) hợp node ≤ 40 nm **[CHƯA CHẮC]**; node 130–180 nm (PDK mở) cần PPI 16 bit (156 MHz)
hoặc tốc độ lane thấp hơn.

### 9.6 Tổng hợp thử

Bước 9, bắt đầu sớm (ngay khi bước 5 xong, song song với 6–8) vì nó quyết định PPI 8 hay 16 bit
(Q5); sign-off là bước 11, sau bước 10 (mục 9.7).

1. **Làm sạch cho ASIC:** `bow_dphy_rx`/`bow_csi2rx` không có primitive FPGA (đã đúng); RAM suy
   luận (`bow_ram_sdp`, `bow_fifo_async`) qua wrapper chọn SRAM macro hoặc flop; `bow_sync`,
   `bow_rst_sync`, clock gate, mux clock test qua wrapper cell của thư viện.
2. **PDK mở** (SKY130, GF180MCU, IHP SG13G2) với Yosys + OpenROAD: số đầu tiên về diện tích theo
   khối, tần số tối đa của miền byte (quyết định PPI 8 hay 16 bit cho node chậm), kiểm RTL tổng
   hợp được bằng công cụ khác Vivado.
3. **PDK của chủ dự án** với công cụ thương mại: số thật, SDC mục 9.3, chèn scan thử, CDC/RDC trên
   netlist, LEC.
4. Mỗi lần thử ghi kết quả vào tài liệu này (bảng 9.5) và giữ script trong repo (thư mục
   `hw/asic/`, bước 9), không giữ file của PDK có bản quyền.

### 9.7 Cổng sẵn sàng ASIC

Hai đích: **A** = ~350 Mbit/s … 1,5 Gbit/s, không cần deskew (dải thiết kế của RTL hôm nay);
**B** = 80 Mbit/s … 2,5 Gbit/s (mục tiêu ASIC của mục 1.2). Sign-off (bước 11) chỉ khi mọi mục
bắt buộc của đích đã chọn đã xong.

| Hạng mục | Đích A | Đích B | Ở đâu |
|---|---|---|---|
| Tư cách thành viên MIPI và quyền đọc đặc tả D-PHY / CSI-2; chọn phiên bản điện cho AFE (ví dụ D-PHY v1.2 phía thu, kênh chuẩn **[CHƯA CHẮC]**); kế hoạch tuân thủ (CTS, thiết bị đo, VIP) | bắt buộc, trước khi đóng băng AFE | bắt buộc, trước khi đóng băng AFE | R1 |
| Hợp đồng AFE (mục 3) được đội analog xác nhận: số **[ĐỀ XUẤT]** đã chốt (đường đồng bộ, cổng, `des_rst`, `clk_act`, delay line) | bắt buộc | bắt buộc | mục 3 |
| `clk_act` (hoặc AFE tự đóng cổng khi mất clock trong T_CLK-MISS) | tuỳ chọn | bắt buộc | mục 3.2, 4.3 |
| `CLK_MISS_OFF` = 1 (bộ thu HS lane clock tắt khi mất clock) | bắt buộc | bắt buộc | mục 3.4 |
| Aligner có mặt nạ, xả pipeline cuối burst (v2 (b), (c) của mục 4.5) | — | bắt buộc | bước 10 |
| Bộ máy deskew (trên 1,5 Gbit/s) | tuỳ chọn | bắt buộc | mục 4.6, bước 8 |
| PPI 16 bit, nếu 312,5 MHz không đạt ở node đã chọn | — | theo tổng hợp thử (Q5) | bước 9, 10 |
| Shadow + APPLY, bộ đếm gray (sign-off CDC không cần waiver) | bắt buộc | bắt buộc | mục 4.10, 4.11 |
| CDC / RDC sạch trên RTL và netlist | bắt buộc | bắt buộc | mục 9.1 |
| DFT: scan, mux clock test, OCC, `AFE_OVR`, MBIST, loopback + PRBS | bắt buộc | bắt buộc | mục 9.2 |
| Mô hình AFE RNM khớp datasheet của AFE; đồng mô phỏng AMS với netlist AFE | bắt buộc | bắt buộc | mục 8.2, R8 |
| Rà bằng sáng chế về deskew phía thu | — | bắt buộc nếu bộ máy deskew vào sản phẩm | R9 |
| `LANE_MAP` / `LANE_POL` | theo package / mạch in | theo package / mạch in | mục 4.10 |

## 10. Kế hoạch chuyển

Mỗi bước là một PR nhỏ; "xanh" = `make lint` (từ bước 5: mọi top có `bow32_top` và
`bow_dphy_io_xusp`), `make -C hw/ip/csi2rx/dv test` và từ bước 6 `make -C hw/ip/dphy_rx/dv test`
(cùng `make test-ip`, CI), `make test` (`sim/`), `make test-tools`, `make sw`, `make gen-check`; với
Vivado: `make -C hw/fpga/common/dv test` (`test-dphy`, `test-dphy-versal`), bản build `kv260_cam` và
PDI camera Huins (`make pdi CARD=cam`, build trên hw-station-1: trên hw-station-2 bước PLM cần
`mb-gcc` thiếu thư viện, [../ddr_huins.md](../ddr_huins.md)) đạt timing, đủ số ràng buộc bus skew
(9 trong `kv260_cam.xdc`, 11 trong `huins_vp1902_cam.xdc`; script build đếm) và qua kiểm tra CDC
của build; trên bo khi có bo: `csi2_test` `test` trên KV260 và Huins.

**Những kiểm tra gắn với tên cell.** Một số ràng buộc và test trỏ tới cell bằng đường phân cấp đầy
đủ, nên bước nào dời cell thì làm hỏng chúng dù RTL đúng; bước đó phải sửa chúng trong cùng PR:

- `set_bus_skew` trên `u_soc/u_csi2rx/meter_gray_q_reg[*]`, `u_sync_meter`, `g_dly_vid.u_sync_req`,
  `u_sync_tap_out` (`hw/fpga/kv260_cam/constr/kv260_cam.xdc:66-81`,
  `hw/fpga/huins_vp1902/constr/huins_vp1902_cam.xdc:103-133`); build đếm 9 / 11 ràng buộc
  (`hw/fpga/kv260_cam/tcl/build.tcl:106-116`, `hw/fpga/huins_vp1902/tcl/build.tcl`), thiếu một là
  CRITICAL WARNING;
- danh sách duyệt CDC-11 / CDC-13 theo đường chính xác (`u_soc/u_csi2rx/u_regs/lane_en_q_reg[*]`,
  `u_sync_vcfg`, `u_soc/u_csi2rx/u_lp_clk/ce_q_reg/C`) trong
  `hw/fpga/huins_vp1902/tcl/timing_checks_cam.tcl:70-81`;
- probe hộp trắng `u_rx.g_align[l].u_align.{arm_i,arm_q,q2_q}` của
  `hw/fpga/common/dv/tb_bow_dphy_io_xusp.sv:113-118`;
- `dut.u_csi2rx.cfg.phy_en` (`sim/tb/tb_bow32.sv:819`) và các kỳ vọng văn bản của `csi2_274` (dòng
  in của `phy`, PA5, `rd 4000800c`, `tb_bow32.sv:2776-2808`);
- sáu nơi dùng `bow32_top` với cổng `dphy_*`: `hw/fpga/kv260/rtl/bow32_kv260_top.sv`,
  `hw/fpga/kv260_cam/rtl/bow32_kv260_cam_top.sv`, `hw/fpga/huins_vp1902/rtl/bow32_huins_vp1902_top.sv`,
  `hw/fpga/huins_vp1902/rtl/bow32_huins_vp1902_cam_top.sv`, `hw/fpga/mps4/rtl/bow32_mps4_top.sv`,
  `sim/tb/tb_bow32.sv`. Hôm nay `make lint` chỉ phủ `bow32_top`, `bow_dphy_io_versal` và top camera
  Huins (`Makefile:64-92`), và `hw/lint/xilinx_versal_stubs.sv` không có primitive UltraScale+, nên
  `bow_dphy_io_xusp` chưa bao giờ được lint.

| Bước | Nội dung | File / module | Chứng minh |
|---|---|---|---|
| 0 | Đặc tả này | `docs/ip/mipi_rx_arch.md` | — |
| 1 | **1a. Bộ chọn không phụ thuộc phân cấp**, trước khi dời cell: XDC / tcl chọn cell bằng `get_cells -hierarchical -filter {NAME =~ */meter_gray_q_reg*}` (như luật BLI của `u_dphy` đã làm) và giữ phép đếm 9 / 11; danh sách duyệt CDC khớp theo đuôi đường; probe của `tb_bow_dphy_io_xusp` chuyển sang `bind` vào `bow_dphy_align`. **1b. Tách `bow_dphy_rx` bên trong `bow_csi2rx`**, cổng và thanh ghi không đổi: FSM LP, phát hiện cạnh clock, flop word, đồng bộ `arm`, aligner, `byte_rst`, nạp tap, đồng hồ đo vào module mới; RAW vẫn ở `bow_csi2_capture` (D-PHY xuất word thô) | 1a: `kv260_cam.xdc`, `huins_vp1902_cam.xdc`, `build.tcl` của hai bản build, `timing_checks_cam.tcl`, `tb_bow_dphy_io_xusp.sv`. 1b: mới `hw/ip/dphy_rx/rtl/bow_dphy_rx.sv`, `hw/ip/dphy_rx/dphy_rx.f`; chuyển `bow_dphy_lp.sv`, `bow_dphy_align.sv` sang `hw/ip/dphy_rx/rtl/`, `bow_csi2_sync.sv` sang `hw/ip/common/rtl/` với tên module mới `bow_sync_bus` (giữ tên instance `u_sync_*` và `g_bit` mà XDC dùng); đổi `bow_csi2rx.sv`, `csi2rx.f`, Makefile DV, filelist lint / FPGA / `sim` | 1a: trên RTL cũ, bus skew vẫn đủ 9 / 11, kiểm tra CDC không đổi, xsim chạy. 1b: Yosys eqy chứng minh tương đương với `bow_csi2rx` cũ; mọi test không đổi kết quả; LUT/FF lệch ≈ 0; `bow_dphy_rx` lint riêng được |
| 2 | **Đảo cấp:** `bow_mipi_rx` (cổng = `bow_csi2rx` hôm nay) chứa `bow_dphy_rx` + `bow_csi2rx` (controller, cổng PPI + dải cấu hình/trạng thái PHY tạm thời từ `bow_csi2rx_regs`); lỗi lp trên PPI là xung cùng clock (FPGA: `lp_clk` = `vid_clk`, kiểm khi elaborate), có `ErrControlClk` | mới: `bow_ppi_pkg.sv`, `hw/ip/csi2rx/rtl/bow_mipi_rx.sv`; đổi: `bow_csi2rx.sv`, `hw/top/rtl/bow32_top.sv` (một instance), `tb_bow_csi2rx.sv`, `sim/tb/tb_bow32.sv` (đường `cfg.phy_en` mới) | Yosys eqy: `bow_mipi_rx` so với `bow_csi2rx` cũ (cổng không đổi); controller chỉ cần PPI + một dải phụ đã liệt kê; dải phụ biến mất ở bước 4–5 |
| 3 | **PPI BFM + bench controller**, hai chế độ thời gian: D-PHY Bow32 và PHY chuẩn qua wrapper cổng phẳng (mục 5.5) | mới: `hw/ip/csi2rx/dv/bow_ppi_bfm.sv`, `tb_csi2rx_ppi.sv`, `csi2_model.py gen --ppi`, wrapper cổng phẳng; đổi: Makefile DV | hành vi controller định nghĩa ở mức PPI (khe, lệch lane, lỗi, clock dừng sớm) ở cả hai chế độ; DV nhanh hơn |
| 4 | **Tách thanh ghi + driver**, không alias: driver đọc `INFO[6]` (mục 6.3); RAW sang D-PHY; GPIO PA4/PA5/PB6/PB7 thành thanh ghi (`burst_rst_en_i` = ¬`CTRL.DES_RST_DIS`); công thức `SETTLE` thống nhất (mục 4.4) | mới: `bow_dphy_rx_regs.sv`, `bow_dphy_raw.sv` (nửa RAW của `bow_csi2_capture`), `sw/common/include/bow_dphy_rx.h` (tên `DPHY_*`), `sw/common/src/bow_dphy_rx.c`; đổi: `bow_csi2rx_regs.sv`, `bow_csi2_capture.sv`, `bow_mipi_rx.sv`, `bow_csi2rx.c`, `cam_sensor.c`, `csi2_test`, top camera Huins (bỏ bốn dây GPIO), `bow32_memmap.yaml` (mô tả), `sim/tb/tb_bow32.sv`, tài liệu | firmware mới chạy trên phần cứng mới; `SETTLE` từng bit như hôm nay (22 trên KV260 ở 912 Mbit/s, 200 MHz; `0x13` trên Huins); DV `be` phủ cửa sổ D-PHY. Kỳ vọng mô phỏng đổi, ghi trong PR: `csi2_274` so `TIM0` (`rd 40008c24` = `051e0213`) thay cho `rd 4000800c`, `csi2` (KV260) thêm phép so tương tự; dòng in của `phy` đổi từ "(PB6 PB7) … (PA4 PA5)" sang `AFE_STATUS` / `DLYn`; không còn kiểm PA5 (`des_rst` luôn bật); `phy reinit` đếm xung `reinit_i` thay cho xung PA4 |
| 5 | **Giao diện AFE + adapter:** `bow_dphy_rx` nói giao diện AFE (mã delay tĩnh + OWN, `des_rst` = ¬`clk_gate_en`, `pd`/`ready`, `hsrx_en`/`term_en` riêng); logic nạp tap và `des_rst` vào `bow_dphy_dly_xusp` / `bow_dphy_dly_xphy` (không primitive, chạy trong Verilator) bên trong hai adapter; bỏ `DlyVid`. Sáu nơi dùng `bow32_top` đổi trong cùng PR (hoặc giữ cổng cũ của `bow32_top` tới khi mọi nơi đã chuyển) | đổi: `bow_dphy_rx.sv`, `bow_dphy_io_xusp.sv`, `bow_dphy_io_versal.sv`, `csi2_tx_model.sv` (tên cổng AFE, núm `versal` giữ), sáu file dùng `bow32_top` (danh sách ở trên), `tb_bow_dphy_io_*.sv`, `Makefile` (lint mọi top); mới: `bow_dphy_dly_xusp.sv`, `bow_dphy_dly_xphy.sv`, stub UltraScale+ trong `hw/lint/` (`IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`, và `IBUFDS_DPHY` nếu stub Versal không khớp); XDC giữ tên instance | một RTL số cho hai họ FPGA; logic adapter vẫn trong CI; `make lint` phủ sáu top và `bow_dphy_io_xusp`; giao diện AFE hiện thực được bằng primitive; xsim mức chân + bo |
| 6 | **D-PHY v1.x:** `T_INIT` (sau `ready` / `REINIT`), `HS_TMO`, `ESC_TMO`, `HSRX_EARLY`, `CLK_MISS_OFF`, `RxSkewCalHS` mọi lane, `CLK_TOG_DIV`, lỗi lp của PPI dạng bộ đếm gray (lấy mẫu ở clock của controller), ULPS, shadow + APPLY, bộ đếm gray phía bus, `CLK_LOST_EN`, LATE_EOT | đổi: `bow_dphy_rx*.sv`, `bow_dphy_lp.sv`, `bow_csi2rx.sv` (lấy mẫu bộ đếm gray); mới: `tb_bow_dphy_rx.sv` (máy phát mức bit), `hw/ip/dphy_rx/dv/Makefile`, bước CI trong `.github/workflows/ci.yml`, harness mutant (mục 8.3) | từng tính năng có test + mutant; mọi bit mới có reset = hành vi hôm nay, hai ngoại lệ có chủ ý (mục 4.12) |
| 7 | **Controller ở clock liên tục (F7):** FIFO 2 clock sau ghép lane, packet/unpack ở `csi_clk` | đổi: `bow_csi2rx.sv`, `bow_csi2_lane_merge.sv`; mới: dấu cuối burst qua FIFO | FE và ngắt không phụ thuộc byte clock (test T_CLK-POST ngắn); timing FPGA đạt |
| 8 | **Bộ máy deskew, PRBS, mô hình AFE (bản đầu)**; máy phát D-PHY và loopback trên bo là tuỳ chọn | mới: `bow_dphy_dsk.sv` (kiểm không cần byte tham chiếu, mục 4.6), `bow_dphy_prbs.sv`, `hw/ip/dphy_rx/dv/bow_dphy_afe_model.sv`; tuỳ chọn: `hw/ip/dphy_tx/rtl/bow_dphy_tx.sv`, adapter TX Versal, build loopback Huins | điều kiện xong nằm trong mô phỏng: `tb_bow_dphy_rx` với `bow_dphy_afe_model` + `csi2_tx_model` (đã gửi được burst deskew thô) phủ deskew, PRBS, ULPS, góc thời gian; loopback trên bo nếu có thì chỉ phủ HS |
| 9 | **Tổng hợp thử ASIC** (bắt đầu sớm, ngay sau bước 5) | mới: wrapper APB4 `bow_mipi_rx_apb`, `hw/asic/` (script tổng hợp, SDC, CDC) | số diện tích / timing đầu tiên (bảng 9.5); quyết định PPI 8 hay 16 bit (Q5); RTL tổng hợp được ngoài Vivado |
| 10 | **v2:** PPI 16 bit (nếu bước 9 cần), tốc độ thấp ((a)–(c) của mục 4.5), `ErrSotHS`, `LANE_MAP` / `LANE_POL`, 8 lane khi có nhu cầu; CSI-2 v2.x theo nhu cầu cảm biến | `bow_dphy_align`, `bow_dphy_lp`, `bow_dphy_rx_regs`, ghép lane, lớp packet | 2,5 Gbit/s ở node chậm; tốc độ thấp tới ~80 Mbit/s với `bow_dphy_afe_model` có `clk_act` |
| 11 | **Sign-off ASIC** | mô hình AFE RNM đủ, CDC/RDC, DFT, kế hoạch tuân thủ | mọi mục bắt buộc của đích đã chọn ở mục 9.7 |

Bước 1–3 không đổi hành vi (refactor; bước 1–2 chứng minh bằng eqy, bước 3 chỉ thêm DV); bước 4–5
đổi bản đồ và giao diện, các kỳ vọng mô phỏng đổi được liệt kê ở bước 4; từ bước 6, mỗi tính năng
nằm sau một bit cấu hình có giá trị reset = hành vi hôm nay, trừ hai ngoại lệ có chủ ý ở mục 4.12.

## 11. Câu hỏi mở và rủi ro

| ID | Câu hỏi / rủi ro | Ảnh hưởng | Hướng xử lý |
|---|---|---|---|
| Q1 | `lp_clk` của ASIC: ≥ 250 MHz chạy liên tục có chấp nhận được (công suất, nguồn clock) | ngân sách T_D-TERM-EN, phát hiện mất clock | quyết định cùng đội SoC; nếu không: Q2 |
| Q2 | Termination tự động trong AFE (`AfeTermAuto`) | bỏ phụ thuộc `lp_clk`, chuyển lọc gai sang analog | đội analog đánh giá; mô hình AFE thử cả hai |
| Q3 | Delay line: tham chiếu DLL hay RC; bước ±1 không glitch; có delay lane clock không; nhả delay từng lane | bám VT, deskew giữa burst | đội analog; ảnh hưởng `INFO[22]`, `INFO[29]`, `INFO[30]` |
| Q4 | Sampler giám sát (mức 5 của hiệu chỉnh) | diện tích/công suất AFE so với lề VT | đo trôi VT trên FPGA và mô hình trước khi chọn |
| Q5 | Deserializer 8 hay 16 bit ở node đích | tần số miền byte, độ rộng PPI | tổng hợp thử (bước 9) |
| Q6 | Cảm biến đích trên 1,5 Gbit/s có gửi burst deskew không, dài bao nhiêu; con số 2^15 / 2^10 UI **[CHƯA CHẮC]** | cỡ bộ máy deskew | datasheet cảm biến đích; đặc tả có bản quyền |
| Q7 | Nguyên nhân BISC ở mép sớm (H1–H3, mục 7.1) | chỉ ảnh hưởng FPGA, nhưng là bài học cho AFE | thử trên bo Huins khi bo về |
| Q8 | PA5 = 0 hỏng trên silicon, mô hình không giải thích | adapter Versal | giữ `des_rst` luôn bật; thử lại với RTL đã gộp khi có bo |
| Q9 | Termination có phải mở cùng lúc khi phát hiện mất clock (T_CLK-MISS) **[CHƯA CHẮC]** | tuân thủ | thành viên MIPI kiểm ở đặc tả |
| Q10 | Loopback trên bo Huins có làm không: trong nibble (chỉ HS) hay qua chân (cần phần cứng mới) **[CHƯA CHẮC]** | tuỳ chọn của bước 8; điều kiện xong của bước 8 đã ở mô phỏng | thử loopback trong nibble trong mô phỏng XPHY trước |
| Q11 | 8 lane: cảm biến / bridge nào cần, CSI-2 phiên bản nào cho phép **[CHƯA CHẮC]** | ghép lane, lớp packet | chỉ làm khi có nhu cầu (bước 10); tới đó trường lane 4–7 đọc 0 |
| Q12 | Thời gian cảm biến giữ LP-11 trước burst đầu (IMX274: standby LP-00) và giá trị `T_INIT` phía thu mà đặc tả đòi **[CHƯA CHẮC]** | frame đầu, `T_INIT` mặc định | đo trên bo khi bo về; thành viên MIPI kiểm |
| R1 | Đặc tả MIPI chỉ cho thành viên: con số lấy từ nguồn công khai [S10] có thể thiếu hoặc lệch; ngưỡng, hysteresis và lọc gai LP, độ nhạy HS, common mode, dung sai termination chỉ có trong bản có bản quyền; không có tư cách thành viên thì không có CTS và không thể tuyên bố tuân thủ | không đóng băng được hợp đồng AFE | điều kiện tiên quyết trước khi đóng băng AFE (mục 9.7): tư cách thành viên, chọn phiên bản điện, kế hoạch tuân thủ; VIP thương mại cho sign-off |
| R2 | Lệch PPI của Bow32 (mục 5.3) làm khó ghép PHY / controller của hãng khác | tái dùng | hồ sơ PPI (mục 5.5), BFM hai chế độ (bước 3), wrapper phẳng; giữ lệch ở mức tối thiểu, ghi rõ |
| R3 | Bỏ alias: bitstream trước bước 4 không chạy với firmware mới | bo phải nạp lại bitstream một lần | firmware và bitstream build cùng commit; driver báo rõ khi `INFO[6]` = 0 (mục 6.3) |
| R4 | Test mức chân cần Vivado, không chạy trong CI | lỗi adapter lọt | logic adapter ở module không primitive chạy trong CI (bước 5); chạy `make test-fpga-dv` trước mỗi PR đụng adapter |
| R5 | Bo Huins đang cho mượn | kiểm trên bo bước 4–8 bị trễ; giá trị `SETTLE` của Huins không đổi được | mô phỏng trước; KV260 cho phần không phụ thuộc Versal; giữ `0x13` từng bit (mục 4.4) |
| R6 | Tốc độ thấp (< ~350 Mbit/s) cần ba sửa (a)–(c) của mục 4.5, trong đó (a) cần `clk_act` của AFE | dải hỗ trợ của đích B | `clk_act` bắt buộc với macro ASIC (mục 3.2), đội analog xác nhận sớm; sửa (b), (c) ở bước 10; tới đó cam kết đích A |
| R7 | Ràng buộc clock ẩn (byte ≤ ~1,5 × `lp_clk`, `lp_clk` ≤ 16/3 × `clk_i`, clock controller ≥ `lp_clk` / 32) | tích hợp SoC | `CLK_TOG_DIV`, bộ đếm gray (v1.x); kiểm khi elaborate |
| R8 | Đồng mô phỏng analog–số với netlist AFE thật chưa có | lỗi ở ranh giới AFE | mô hình RNM khớp datasheet AFE; đồng mô phỏng AMS trước tape-out |
| R9 | Bằng sáng chế về deskew phía thu [S22] | pháp lý | rà quyền sử dụng trước khi đưa bộ máy deskew vào sản phẩm |

## Nguồn

| ID | Nguồn (công khai) |
|---|---|
| S1 | AMD PG202 MIPI D-PHY v4.3, *PPI Signals*: https://docs.amd.com/r/en-US/pg202-mipi-dphy/PPI-Signals |
| S2 | PG202 *HS_SETTLE Register*: https://docs.amd.com/r/en-US/pg202-mipi-dphy/HS_SETTLE-Register |
| S3 | PG202 *INIT Register*, *DL_STATUS Register*, *D-PHY Protocol Checks*, *HS Data Transfer*, *Example 8*, *Clocking*, *Features*: https://docs.amd.com/r/en-US/pg202-mipi-dphy/INIT-Register và các trang cùng thư mục |
| S4 | AMD PG435 MIPI RX C-PHY/D-PHY (Versal), *PPI Signals*: https://docs.amd.com/r/en-US/pg435-mipi-rx-phy/PPI-Signals |
| S5 | AMD PG436 MIPI TX PHY, *PPI Signals*: https://docs.amd.com/r/en-US/pg436-mipi-tx-phy/PPI-Signals |
| S6 | AMD PG232 CSI-2 RX Subsystem: https://docs.amd.com/r/5.4-English/pg232-mipi-csi2-rx/MIPI-CSI-2-RX-Controller |
| S7 | AMD UG974 `IBUFDS_DPHY`: https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/IBUFDS_DPHY |
| S8 | Lattice FPGA-IPUG-02081 v2.6, CSI-2/DSI D-PHY Rx IP (mục 2.5–2.7, 2.11, bảng cổng): https://www.latticesemi.com/view_document?document_id=52445 |
| S9 | Altera/Intel MIPI D-PHY IP User Guide (Agilex 3/5), 817561, trang *calibration* và *PPI*: https://www.intel.com/content/www/us/en/docs/programmable/817561/25-1/calibration.html — chỉ đọc được đoạn trích **[CHƯA CHẮC]** |
| S10 | Linux `include/linux/phy/phy-mipi-dphy.h`, `drivers/phy/phy-core-mipi-dphy.c`: https://github.com/torvalds/linux/blob/master/drivers/phy/phy-core-mipi-dphy.c |
| S11 | Linux `drivers/phy/cadence/cdns-dphy-rx.c`: https://github.com/torvalds/linux/blob/master/drivers/phy/cadence/cdns-dphy-rx.c |
| S12 | Linux `drivers/media/platform/nxp/imx8mq-mipi-csi2.c`: https://github.com/torvalds/linux/blob/master/drivers/media/platform/nxp/imx8mq-mipi-csi2.c |
| S13 | MIPI, trang D-PHY: https://www.mipi.org/specifications/d-phy ; bảng lịch sử phiên bản D-PHY (3/2026): https://www.mipi.org/hubfs/Specification-Feature-Tables/MIPI-D-PHY-Version-History-Table-March-2026.pdf ; DevCon 2016 (deskew): https://de.slideshare.net/MIPI-Alliance/mipi-devcon-2016-mipi-dphy-physical-layer-test-measurement-challenges |
| S14 | Arasan C-PHY v2.0 + D-PHY v2.5 combo datasheet: https://www.arasan.com/wp-content/uploads/2021/03/CPHY-2.0-_-DPHY-2.5-datasheet.pdf |
| S15 | Cadence MIPI PHY: https://www.cadence.com/en_US/home/tools/silicon-solutions/design-ip/interface-ip/mipi/mipi-phy.html ; Cadence VIP D-PHY: https://www.cadence.com/en_US/home/tools/system-design-and-verification/verification-ip/simulation-vip/mipi/mipi-d-phy-c-phy-a-phy.html (đoạn trích) |
| S16 | Synopsys MIPI D-PHY datasheet (tóm tắt): https://www.synopsys.com/resources/mipi-d-phy-ip-datasheet.html |
| S17 | Mixel D-PHY RX+ (2020): https://www.design-reuse.com/news/news48486.html |
| S18 | Microchip, *Escape Mode* (D-PHY trong tài liệu sản phẩm): https://onlinedocs.microchip.com/oxy/GUID-51CE727C-126C-4670-A2BA-189781F25924-en-US-2/GUID-8DE957CE-D9C6-427A-8827-EAB389A55351.html |
| S19 | Keysight M8085A user manual: https://www.keysight.com/us/en/assets/9018-04460/user-manuals/9018-04460.pdf.html (đoạn trích) |
| S20 | TI AM67 TRM, DPHY_RX (đoạn trích): https://ti.com/document-viewer/lit/html/SPRUJB3/GUID-28414FDA-CF73-42D9-9A1B-D8D0FCAE624B |
| S21 | Mã mở daveshah1/CSI2Rx (MIT): https://github.com/daveshah1/CSI2Rx |
| S22 | Bằng sáng chế về deskew D-PHY bằng delay line phía thu: https://patents.google.com/patent/US9355054 , https://patents.google.com/patent/US10936007 (đoạn trích) |
| S23 | AMD AM010, *Versal Adaptive SoC SelectIO Resources Architecture Manual* (mục XPHY, BISC, VT tracking): https://docs.amd.com/r/en-US/am010-versal-selectio — trang chặn tải tự động; con số ở đây lấy theo trích dẫn AM010 trong chú thích của `bow_dphy_io_versal.sv` **[CHƯA CHẮC]** |

Tài liệu Bow32 liên quan: [csi2rx.md](csi2rx.md), [../csi2rx_review.md](../csi2rx_review.md),
[../camera_huins.md](../camera_huins.md), [../camera_kv260.md](../camera_kv260.md),
[../ddr_huins.md](../ddr_huins.md), [../simulation.md](../simulation.md),
[../memory_map.md](../memory_map.md).
