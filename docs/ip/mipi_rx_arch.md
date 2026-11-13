# Kiến trúc bộ thu MIPI cho ASIC: AFE, D-PHY số, PPI và bộ điều khiển CSI-2

Đặc tả kiến trúc (RTL: bước 1 và 2 của mục 10 xong, đã chạy trên bo Huins; bước 3, kiểm chứng
controller ở PPI, xong trong mô phỏng; bước 4 và 5 xong trong mô phỏng và build, chờ chạy trên bo
Huins) cho bộ thu MIPI mà
Bow32 sở hữu trọn vẹn trên **ASIC**: cả **D-PHY** (phần analog lẫn phần số) và **bộ điều khiển
CSI-2**, chia theo các lớp chuẩn của MIPI:

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
| Lớp vật lý | D-PHY RX một chiều: 1 lane clock + 1, 2 hoặc 4 data lane (tham số tới 8), clock liên tục hoặc không; 80 Mbit/s … 2,5 Gbit/s mỗi lane (đích B, đã chốt ở mục 0: `clk_act` của AFE bắt buộc, mục 1.2) |
| D-PHY số | máy LP, settle, termination, cổng byte clock, SoT và căn byte, deskew (nhận ra, rồi hiệu chỉnh), lỗi, ULPS; escape LPDT/trigger để sau |
| Ranh giới | giao diện AFE (dưới PPI: word chưa căn, byte clock, mức LP, điều khiển analog) và PPI 8 bit mỗi lane (16 bit ở v2) |
| CSI-2 | lớp giao thức v1.x trên D-PHY, mốc v1.3; đường lên v2.x |
| Khối mới | `bow_dphy_rx`, `bow_dphy_rx_regs`, `bow_dphy_raw`, `bow_dphy_dsk`, `bow_dphy_prbs`, `bow_ppi_pkg`, `bow_mipi_rx` (wrapper Bow32), `bow_mipi_rx_apb` (wrapper APB4 cho ASIC), `bow_csi2rx_ppi_flat` (controller với cổng PPI phẳng cho PHY chuẩn, bước 3); FPGA: `bow_dphy_dly_xusp`, `bow_dphy_dly_xphy` (logic adapter không có primitive); DV: `bow_ppi_bfm` và `tb_csi2rx_ppi` (bước 3), `bow_dphy_afe_model`, `bow_dphy_tx` |
| Đổi vai | `bow_dphy_io_xusp`, `bow_dphy_io_versal` thành **adapter AFE** (giữ tên file và tên instance mà XDC dùng) |
| Giữ nguyên | lớp CSI-2 của `bow_csi2rx` (ghép lane, packet, unpack, FIFO, đầu ra, LOG); bản đồ `CSI2RX` ở `0x4000_8000` (thanh ghi PHY chuyển sang D-PHY ở `0x4000_8C00`; không có alias, driver chọn theo `INFO[6]`, mục 6.3) |
| Trạng thái | đặc tả; RTL: bước 1 và 2 xong, `csi2_test` `test` PASS 17/17 trên bo Huins ngày 2026-11-11 (bước 1: `bow_dphy_rx` tách bên trong `bow_csi2rx`; bước 2: `bow_mipi_rx` ghép `bow_dphy_rx` và controller `bow_csi2rx` bằng PPI v1 cộng một dải phụ tạm thời; cổng và thanh ghi không đổi, tương đương chứng minh bằng Synopsys Formality, D8 sửa đổi đã duyệt, mục 0 và 10); bước 3 xong trong mô phỏng 2026-11-12: bench controller ở PPI `tb_csi2rx_ppi` với `bow_ppi_bfm`, hai chế độ thời gian (D-PHY Bow32, PHY chuẩn qua wrapper cổng phẳng) đều sạch, hồ sơ PPI mục 5.5 sửa theo kết quả, không đổi RTL nào có sẵn; bước 4 xong trong mô phỏng và build 2026-11-12 (chờ chạy bo Huins): D-PHY có thanh ghi riêng ở `0x4000_8C00` (tập con v1 của mục 4.10, [dphy_rx.md](dphy_rx.md)), reset và RAW riêng, dải phụ tạm thời đã bỏ, driver `bow_dphy_rx`, không alias; bước 5 xong trong mô phỏng và build 2026-11-13 (chờ chạy bo Huins): `bow_dphy_rx` nói giao diện AFE của mục 3.2 (mã delay tĩnh + OWN, `des_rst` = ¬`clk_gate_en`, `pd` / `ready`, `hsrx_en` / `term_en` riêng; tập con v1 và chỗ lệch ở [dphy_rx.md](dphy_rx.md)), nạp tap và reset đường thu nằm trong adapter (`bow_dphy_dly_xusp`, `bow_dphy_dly_xphy`, chạy cả trong Verilator), `DlyVid` bỏ, `make lint` phủ sáu top và `bow_dphy_io_xusp`, tương đương với bước 4 chứng minh bằng Formality trừ đúng các thay đổi có chủ ý; sửa sau review cùng ngày: `lane_pd` chỉ theo READY mới, bench đơn vị của phía AFE trong CI, bus skew mã delay của KV260 và kiểm tra ngoài ngữ cảnh của nó, lint đầu vào nối rỗng, hợp đồng `ready` của AFE (mục 3.5, 3.6); các quyết định kiến trúc đã chốt ngày 2026-11-11 (mục 0); kế hoạch chuyển gồm các bước 0–11, mỗi bước giữ mọi test hiện có, build và chạy trên bo Huins (KV260 chỉ kiểm bằng mô phỏng, quyết định D1), kỳ vọng nào đổi thì ghi rõ (mục 10) |

## 0. Quyết định đã chốt (2026-11-11)

Chủ dự án đã duyệt các điểm sau trong review PR #19. Các mục còn lại của tài liệu đã được sửa cho
khớp; số **[ĐỀ XUẤT]** vẫn chờ đội liên quan chốt như ghi ở từng mục.

| ID | Quyết định | Hệ quả | Mục |
|---|---|---|---|
| D1 | Thanh ghi D-PHY ở `0x4000_8C00`, **không có alias**; driver đọc `INFO[6]` và từ chối bitstream cũ | firmware và bitstream luôn build từ cùng commit. Ở các bước chuyển, phần cứng chỉ **build và chạy thử trên Huins** (PDI camera, `csi2_test`); KV260 không build bitstream và không chạy trên bo cho tới khi cần (cấu hình KV260 vẫn kiểm bằng mô phỏng trong CI); lần chạy KV260 sau phải nạp bitstream mới cùng firmware mới | 6.3, 10 |
| D2 | Đích tốc độ ASIC: **B = 80 Mbit/s … 2,5 Gbit/s** | `clk_act` bắt buộc trong AFE; ba sửa tốc độ thấp (a)–(c) của mục 4.5 và bộ máy deskew (trên 1,5 Gbit/s) là điều kiện sign-off; PPI 16 bit có thể cần ở node chậm (quyết ở bước 9, Q5); cổng sẵn sàng theo cột B của mục 9.7 | 1.2, 4.5, 4.6, 9.7 |
| D3 | Hợp đồng đồng bộ AFE: phát ở cạnh xuống, bắt ở cạnh lên kế tiếp, với các số của mục 3.3; cổng clock đồng bộ trong AFE, squelch ở bộ thu HS lane clock, `des_rst` không dừng bộ chia | dùng làm đề xuất ban đầu giao đội analog; số cuối chốt theo node | 3.2, 3.3 |
| D4 | Tư cách thành viên MIPI (quyền đọc đặc tả, chọn phiên bản D-PHY, kế hoạch tuân thủ / CTS) là **điều kiện trước khi đóng băng AFE** | không đóng băng hợp đồng AFE trước khi có | 9.7, R1 |
| D5 | Bật termination: mặc định **(a)** `lp_clk` của ASIC ≥ 250 MHz chạy liên tục, `LP_FILTER` = 1; **(b)** termination tự động trong AFE (`AfeTermAuto`) là phương án dự phòng | chốt cuối cùng với đội clock / nguồn của SoC | 3.4, Q1, Q2 |
| D6 | Ranh giới AFE nằm **dưới PPI**: AFE giao word chưa căn, byte clock và mức LP thô; mọi quyết định giao thức nằm ở `bow_dphy_rx` | `bow_dphy_rx` dùng lại được với mọi AFE theo hợp đồng mục 3 | 3.1 |
| D7 | PPI **8 bit** mỗi lane ở v1; 16 bit quyết sau tổng hợp thử | — | 5, bước 9 |
| D8 | Kế hoạch chuyển bước 0–11, **mỗi bước một PR**; bước 1–3 là refactor, chứng minh tương đương bằng Yosys eqy (**sửa ngày 2026-11-11: Synopsys Formality**, xem dưới) | — | 10 |

**D8 sửa đổi, đã duyệt (2026-11-11).** Chứng minh tương đương của các bước refactor dùng
**Synopsys Formality**, RTL với RTL (`make -C hw/ip/dphy_rx/fm equiv STEP=<n>`): mọi compare point
khớp và tương đương, mọi cặp khớp mang đúng tên của reference sau luật đổi tên, mọi cell nằm đúng
khối, không black box, user match hay constant. Lý do: Yosys eqy không có trên máy build (không
được cài công cụ ngoài) và Yosys gốc chỉ đọc một phần SystemVerilog; Formality có license trên
máy, là công cụ kiểm tương đương chuẩn cho ASIC và sẽ dùng tiếp để so RTL với netlist (bước 9).
Formality cần license nên **không chạy trong CI**: luồng chạy ở máy build trước mỗi PR của một
bước refactor, kết quả ghi trong PR; CI vẫn chạy toàn bộ mô phỏng. Thêm Yosys eqy vào CI (trên
runner của CI) để ai cũng chạy lại được là tuỳ chọn về sau.

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
   controller khác) qua wrapper cổng phẳng, trong giới hạn của hồ sơ PPI ở mục 5.5. Bước 3 đạt mục
   tiêu này ở mức mô phỏng cho controller: `bow_csi2rx_ppi_flat` với thời gian kiểu PHY chuẩn chạy
   sạch như thời gian của D-PHY Bow32 (mục 5.5, 10), với bốn điều mà phần dựng PHY chuẩn còn mượn
   của D-PHY Bow32 (mục 5.5, *Bước 3*). Chưa thử với PHY của hãng nào: với một PHY cụ
   thể vẫn là mục tiêu thiết kế, chưa phải khả năng đã chứng minh. Mọi chỗ Bow32 lệch khỏi PPI
   công khai được ghi ở mục 5.3.
5. **Hiệu chỉnh dựa trên dữ liệu.** Bài học của bo Huins (tự hiệu chỉnh BISC đặt điểm lấy mẫu ở
   mép sớm của eye) thành yêu cầu kiến trúc: tự hiệu chỉnh trong phần cứng của PHY (BISC của XPHY,
   hay của AFE ASIC) chỉ là điểm xuất phát, điểm lấy mẫu cuối cùng phải được đo trên dữ liệu
   (mục 7).

### 1.2 Dải hỗ trợ

| Hạng mục | RTL v1 (sau khi tách) | Mục tiêu ASIC | Để ngỏ cho |
|---|---|---|---|
| Data lane | 1, 2, 4 (tham số `Lanes`, chọn lúc chạy) | 1, 2, 4 | 8: tham số, địa chỉ thanh ghi và PPI đã có chỗ (logic của lane 4–7 chỉ sinh khi `Lanes` > 4); ghép lane và lớp packet cần mở rộng (mục 6.5) |
| Tốc độ mỗi lane | thiết kế cho ~350 Mbit/s … 1,5 Gbit/s; đã kiểm 770–1050 Mbit/s trong DV, 912 Mbit/s (KV260) và 1440 Mbit/s (Huins) trên bo; giới hạn dưới ở mục 4.5; trên 1,5 Gbit/s hiệu chỉnh bằng eye walk tới khi có bộ máy deskew | **đích B (đã chốt, D2): 80 Mbit/s … 2,5 Gbit/s.** Cần `clk_act` của AFE (bắt buộc, mục 3.2), các sửa (a)–(c) của mục 4.5 (bước 10) và bộ máy deskew trên 1,5 Gbit/s (bước 8); cả ba là điều kiện sign-off (mục 9.7) | trên 2,5 Gbit/s (D-PHY v2.x: equalization, ACS) ngoài phạm vi |
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
| Huins + IMX274 (lần 1–3): trễ BISC ở mép dưới (tap nhỏ) của eye trên cả 4 lane, cách tâm 98…178 tap = 0,26–0,48 UI (1 tap ≈ 1,87 ps, 1 UI ≈ 374 tap, đo lần 3); eye ~352–360 tap; ở trễ BISC có lỗi CRC (~11 % dòng ở lần 1, 0,2–1,5 lỗi mỗi frame ở lần 2–3); BISC cho cùng kết quả khi cảm biến còn bị reset (LP-00) và khi đang stream | hiệu chỉnh dựa trên dữ liệu, `DLYn.OWN` (mục 3.5, 7) |
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
| núm PA4 (`reinit_i`), PA5 (`burst_rst_en_i`), trạng thái PB6/PB7 | GPIO của top camera Huins | bước 4: `CMD.REINIT` (xung `reinit_o`), `CTRL.DES_RST_DIS` (0 từ reset: luôn bật), `AFE_STATUS[15:8]` của D-PHY; bước 5: `AFE_CTRL.PD`, `des_rst` |
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

**v1 (bước 5).** `bow_dphy_rx` có mọi cổng của các nhóm A–F trừ `scan_mode` và `tst_clk` (DFT,
bước 9), tên `afe_<tên>_i` / `_o`; bảng cổng, cách v1 lái hay dùng từng tín hiệu và những tín hiệu
còn nối cố định (`clk_act`, `clk_hs_samp`, delay lane clock, sampler giám sát, `trim`, `tst_*`,
`atb_sel`, `hs_raw`) ở [dphy_rx.md](dphy_rx.md) (mục *Giao diện AFE*). Chỗ lệch bảng trên, có chủ ý:
`dly_code`, `dly_own`, `pd`, `lprx_en`, `lane_pd` và `cal_start` ra từ flop **miền bus** (bảng
ghi lp): AFE coi mọi điều khiển là bất đồng bộ (mục 3.1), và như vậy mã 9 bit mỗi lane không phải
qua bus → lp; mã + OWN vào bộ đồng bộ của adapter có một `set_bus_skew` trên mỗi bo (Huins giữ 11
ràng buộc, KV260 thêm ràng buộc này ở review bước 5: 10); mã delay sang miền lp cùng bộ máy
deskew, chủ thứ hai của mã (bước 8, mục 4.10). `cal_start` là `CMD.REINIT`, 32 chu kỳ bus
(`CMD.AFE_CAL` riêng ở bước 6); `term_en` = `hsrx_en` và `lprx_en` / `lane_pd` một flop cho mọi
lane tới bước 6. `bow_mipi_rx` chỉ đưa ra tập con mà hai adapter FPGA dùng.

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
6. **`ready` và mã đã áp** (rõ thêm sau review bước 5). `ready` xuống nghĩa là AFE mất mã đã áp
   (khởi động lại, mất khoá); phần số thấy nó qua 2 flop miền bus và xoá mọi OWN một chu kỳ sau.
   Vì vậy mỗi lần `ready` xuống phải giữ 0 ít nhất 2 chu kỳ `clk_i` của `bow_dphy_rx`
   (**[ĐỀ XUẤT]** ≥ 100 ns, đủ cho `clk_i` ≥ 20 MHz), không thì phần số có thể không thấy và giữ
   OWN. `pd` = 1 kéo `ready` xuống ngay (đầu ra kẹp, mục 3.2) và AFE giữ nó 0 tới khi khởi động lại
   xong sau khi `pd` xuống, nên xung PD ngắn nhất cũng đủ. Khi `ready` lên, AFE áp `dly_code[l]`
   cho **mọi lane có `dly_own[l]` = 1 lúc đó**, không chờ một cạnh lên của `dly_own`: ở ranh giới
   `ready` lên OWN của một lane có thể vẫn 1 (phần số chưa kịp thấy `ready` xuống), và lane đó vẫn
   phải về đúng mã; lane có `dly_own` = 0 dùng giá trị của AFE. Adapter Versal làm vậy (`ready` = 0
   xoá trạng thái của `bow_dphy_dly_xphy`, nên OWN = 1 lúc `ready` lên là một yêu cầu mới;
   `tb_afe_dly` kiểm); adapter UltraScale+ có `ready` luôn 1.

### 3.6 Trình tự

```
reset:      pd = AfePdRst, lprx_en = ¬pd, hsrx_en = term_en = 0, clk_gate_en = 0, des_rst = 1,
            dly_own = 0, lane_pd = 1
AFE bật:    AFE_CTRL.PD = 0: pd = 0, lprx_en = 1 (mọi lane của bản build) → chờ ready mới
            (≤ 100 µs) → lane_pd = 0 (lane trong LANE_EN); ready lên: T_INIT phải được đếm (một lần)
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

**`lane_pd` chỉ theo `ready` mới** (sửa sau review bước 5). Phần số thấy `ready` qua 2 flop miền
bus, nên ngay sau khi PD lên nó còn đọc `ready` = 1 thêm 2–3 chu kỳ. Một xung PD ngắn (PD = 1 rồi 0
ở lần ghi kế tiếp) không được nhả `lane_pd` theo `ready` cũ ấy: AFE khởi động lại sau mọi xung PD.
Luật: `lane_pd` = 1 từ reset và khi PD; nó xuống khi phần số thấy `ready` = 1 với PD = 0 **sau
khi** đã thấy `ready` = 0 ít nhất một chu kỳ kể từ lần PD lên gần nhất (hay từ reset); xuống rồi
thì giữ 0 tới lần PD sau (`ready` xuống mà không có PD, như `cal_start` hay mất khoá, không bật lại
`lane_pd`). AFE nào giữ `ready` = 1 qua `pd` (trái mục 3.2: adapter UltraScale+, vốn không có `pd`
lẫn `lane_pd`) thì sau một xung PD `lane_pd` ở 1 tới reset. `bow_afe_chk` kiểm luật này ở mọi chu
kỳ bus; DV `dly` có một xung PD hai lần ghi liền nhau, `tb_dphy_afe` xung PD dài thêm 0–3 chu kỳ,
`ready` xuống muộn, `ready` kẹt ở 1.

**Hai miền reset của điều khiển AFE.** `pd`, `lprx_en`, `lane_pd`, `dly_own`, `dly_code` và
`cal_start` là flop miền bus (`bow_dphy_rx_regs`), reset bởi `rst_ni`; `clk_gate_en`, `des_rst`,
`hsrx_en` và `term_en` là flop miền lp (máy LP), reset bởi reset lp `lrst_n` (`rst_ni` ∧
`lp_rst_ni`: bật bất đồng bộ cùng lúc với `rst_ni`, nhả đồng bộ theo `lp_clk`). Suốt lúc reset
bật, các đầu ra giữ giá trị của dòng `reset:` trên (`bow_afe_chk` kiểm ở mọi cạnh clock trong
reset của từng miền; `tb_dphy_afe` cả lúc reset giữa chừng).

**Stop/start không chạy lại hiệu chỉnh của AFE.** `CTRL.PHY_EN` của controller lái `Enable` của
PPI và bị xoá ở mỗi lần `start`/`stop` (`rx_off()`, `bow_csi2rx.c:81-84`). Nếu `Enable` = 0 kéo
theo `pd`, adapter Versal sẽ khởi động lại XPLL + XPHY ở mỗi lần dừng (`pd` = `reinit_i`): mọi lane
về trễ BISC (~11 % dòng lỗi CRC trên bo) và tap đã hiệu chỉnh mất. Vì vậy `Enable` chỉ đóng cổng,
tắt bộ thu HS và đỗ FSM; `pd` chỉ đến từ `AFE_CTRL.PD`.

**`Enable` = 0 khi lane clock còn chạy.** Cổng đồng bộ của AFE chịu được, nhưng driver vẫn tránh:
`bow_csi2rx_stop()` chờ FSM lane clock đóng cổng (`RxClkActiveHS` = 0) rồi mới hạ `Enable`, như
nó chờ `STATUS.CE` tới bước 3 (từ bước 4: `LANE_HS[17]` của D-PHY). Với `CLK_CONT` cổng mở và
đóng khi clock đang chạy: chỉ AFE có cổng đồng bộ mới hỗ trợ.

### 3.7 `bow_dphy_io_xusp` và `bow_dphy_io_versal` thành adapter AFE

Hai module giữ tên file và tên instance mà XDC dùng (`u_hs_bufg`, `u_byte_bufg`, cell BLI), nhận
thêm logic adapter chuyển từ `bow_dphy_rx` (nạp tap, reset ISERDES) và đổi cổng sang tên của giao
diện AFE (bước 5, xong). Logic fabric của adapter (nạp khi mã đổi hay OWN lên, trình tự nạp của
XPHY, reset đường thu từ `des_rst`) nằm trong hai module không có primitive, `bow_dphy_dly_xusp`
(`u_dly` trong `bow_dphy_io_xusp`) và `bow_dphy_dly_xphy` (`u_dly` trong `bow_dphy_io_versal`), để
Verilator (CI) vẫn kiểm được nó: `csi2_tx_model` của DV và mô phỏng hệ thống chạy chính hai module
đó; chỉ phần primitive còn lại cần xsim. Cả hai adapter dựa trên `IBUFDS_DPHY` (bộ thu HS và hai
bộ thu LP trên cùng cặp chân, chân tắt HS riêng [S7]).

| Tín hiệu AFE | `bow_dphy_io_xusp` (KV260, UltraScale+) | `bow_dphy_io_versal` (Huins, Versal) |
|---|---|---|
| `hs_byte_clk` | `BUFGCE_DIV` /4 từ `HSRX_O` của lane clock | `BUFGCE` của `FIFO_WR_CLK` nibble strobe |
| `hs_data[l]` | `Q` của `ISERDESE3` 1:8 (qua `IDELAYE3`) | `Q` của XPHY qua FIFO RX + flop BLI, sắp lại bit (`xphy_byte`) |
| `hs_valid[l]` | `'1` | word đọc được từ FIFO (có khe) |
| `clk_gate_en` | CE chung của hai `BUFGCE_DIV` (/1 và /4, `CE_TYPE SYNC`) | CE của `BUFGCE` (`CE_TYPE SYNC`) |
| `des_rst` | `RST` của `ISERDESE3`: `bow_dphy_dly_xusp` (`u_iserdes_rst`, `bow_rst_sync` theo byte clock) bật bất đồng bộ khi `des_rst` = 1 và nhả 2 cạnh byte clock sau khi clock chạy lại (bắt buộc: căn bộ chia /4 bên trong ISERDES; không treo vì `BUFGCE_DIV` không bị reset). Bước 4 lấy nó từ cổng (`byte_rst_o`), nên `CTRL.DES_RST_DIS` = 1 nay cũng tắt reset này | `RX_RST` các slice dữ liệu: `burst_rst_q` của `bow_dphy_dly_xphy` = `ready` ∧ `des_rst`, một flop `ctrl_clk` (= `lp_clk`, nên không cần đồng bộ): bật 1 chu kỳ sau khi cổng đóng, nhả 1 chu kỳ sau khi mở, lúc lane clock còn tĩnh, đúng như `burst_rst_q` của bước 4 (= PA5 = 1). Không nhả theo cạnh byte clock: giữ `RX_RST` của slice strobe có thể dừng chính `FIFO_WR_CLK` **[CHƯA CHẮC]** |
| `clk_act` | — (mất clock thấy qua cạnh byte clock) | — (như bên trái) |
| `lp[l]`, `clk_lp` | `LPRX_O_P/N` của `IBUFDS_DPHY` | như bên trái |
| `lprx_en` | không mô hình (`LPRX_DISABLE` = 0; cổng không dùng) | như bên trái |
| `hsrx_en` ∨ `term_en` | `~HSRX_DISABLE` (một chân cho cả bộ thu HS và termination) | như bên trái |
| `dly_code`/`dly_own`/`dly_q` | `IDELAYE3` `CNTVALUEIN`/`LOAD`/`CNTVALUEOUT`: `bow_dphy_dly_xusp` đồng bộ mã và OWN theo byte clock (`u_sync_code`, `u_sync_own`), tap = OWN ? mã : 0, nạp khi tap ổn định 2 chu kỳ và khác tap đã nạp (chỉ khi byte clock chạy: burst sau); `dly_own` 1 → 0 từng lane: tap 0 (làm được từng lane: `INFO[30]` sẽ = 1 khi có `CMD.DLY_REL`, bước 6; v1 đọc `INFO[31:24]` = 0); XDC KV260 ràng buộc bus skew của mã + OWN tới bộ đồng bộ (một chu kỳ byte clock, từ review bước 5) | XPHY `CNTVALUEIN`/`LD`/`CNTVALUEOUT` ở `CTRL_CLK`: `bow_dphy_dly_xphy` đồng bộ mã và OWN (`u_sync_code`, `u_sync_own`; XDC Huins ràng buộc bus skew của chúng), yêu cầu khi giá trị ổn định 2 chu kỳ, OWN = 1 và OWN vừa lên hoặc mã khác mã đã áp; lần đầu của lane `RX_EN_VTC` = 0 rồi chờ `VtcWait` (12), nạp; lần nạp cách nhau ≥ `LdGap` (4), yêu cầu trong lúc chờ gộp (mã mới nhất); `ready` = 0 xoá trạng thái. `dly_own` 1 → 0 từng lane: không làm được (`INFO[30]` = 0); mọi lane cùng về tap BISC + bám VT chỉ qua `pd` / `cal_start` |
| `pd` | — (không tắt được; cổng không dùng, `ready` vẫn 1) | `pd_i` (thay `reinit_i` của bước 4) qua 2 flop: giữ ở reset khởi động (XPLL, XPHY); chỉ từ `AFE_CTRL.PD`, nên stop/start không chạy lại BISC |
| `ready` | 1 | `ready_o` (XPLL khoá + BISC xong + PHY_RDY mọi nibble; `phy_rdy_o` trước bước 5) |
| `cal_start` | — | `cal_start_i` (xung `CMD.REINIT`) qua 2 flop, OR với `pd`: XPLL, BISC, VT chạy lại; mã đã nạp bị bỏ |
| `status` | 0 | `status_o` = {0, PHY_RDY, DLY_RDY, LOCKED_FB, LOCKED} (`phy_status_o` trước bước 5) |
| `clk_hs_samp` | — | `clk_hs_samp_o` (`clk_q_o` trước bước 5; top để hở, D-PHY v1 không dùng) |
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
| `EscWait` | lệnh khác ULPS (bước 6): chờ LP-11, `ErrEsc` một bước | 0 | — | v1.x |
| `Ulps` | lệnh ULPS: phần HS tắt, `UlpsActiveNot` = 0 | 0 | — | v1.x |
| `UlpsExit` | LP-10 kéo dài (thức dậy): `lane_pd` = 0 ngay, chờ LP-11 | 0 | — | v1.x |

Chuyển trạng thái như `bow_dphy_lp` hôm nay ([csi2rx.md](csi2rx.md) mục *Máy trạng thái LP*),
thêm các nhánh escape. Chuỗi vào escape, mã lệnh "spaced-one-hot" (mỗi bit là một trạng thái
"mark" — dây nào lên cho biết giá trị bit — rồi một "space" LP-00) và lệnh ULPS lấy theo tài liệu
công khai [S18]; thoát ULPS bằng LP-10 giữ ≥ T_WAKEUP (≥ 1 ms [S10]) rồi LP-11 [S8][S18]. Phía thu
không cần đo T_WAKEUP: nó chỉ chờ LP-11. LP-11 giữa chuỗi vào escape huỷ việc vào escape (về
`Stop`, không lỗi) [S18].

**Hiện thực ở bước 6** (`bow_dphy_lp`, [dphy_rx.md](dphy_rx.md) mục *Chức năng v1.x*): các trạng
thái mới lấy những giá trị trạng thái 4 bit mà v1 bỏ trống (9…14), và khi `ULPS_EN` = 0 chúng về
`Off` như v1 làm với những giá trị đó, nên với cấu hình reset máy LP tương đương v1 ở mọi giá trị
trạng thái (Formality, mục 10 *Kết quả bước 6*). Mỗi bit lệnh là một mark (LP-01 = 0, LP-10 = 1)
rồi một space LP-00; bit nhận trước thành bit 7 của mã so với lệnh ULPS; thứ tự bit này lấy theo
cách đọc của Bow32 với mô tả công khai [S18] **[CHƯA CHẮC]**: chưa kiểm với một máy phát thật (bench
bước 6 dùng chính quy ước đó). LP-11 ở bất kỳ trạng thái escape nào trước khi giải xong lệnh huỷ
(về `Stop`, không lỗi); LP-01 ở `EscRqst`, LP-10 ở `EscGo` và hai mark liền nhau không có space là
lỗi LP (CONTROL, về `WaitStop`). `ESC_TMO` đếm từ LP-10 của lần vào tới khi giải xong lệnh.
`T_INIT` đếm chu kỳ LP-11 **liên tiếp** ở `WaitStop` (mức khác đếm lại từ 0); `CMD.REINIT`, và
`ready` lên khi `T_INIT` ≠ 0, đưa mọi lane đang bật về `WaitStop` ngay (data lane đang HS rời HS,
burst đang dở mất). `HS_TMO` đếm từ 0 khi vào `Hs`, sau `HS_TMO` chu kỳ thì lỗi CONTROL + HS_TMO.

### 4.3 Máy trạng thái lane clock

| Trạng thái | Nghĩa | v1 | Thêm ở |
|---|---|---|---|
| `Off`, `WaitStop`, `Stop`, `HsRqst` | như data lane | ✓ | |
| `Settle` | LP-00: `clk_hsrx_en`, `clk_term_en`, đếm `CLK_SETTLE` (T_CLK-SETTLE 95…300 ns [S10]) | ✓ | |
| `Hs` | mở cổng (`clk_gate_en`, `RxClkActiveHS`) trong HS-0 của CLK-ZERO; sau khi đã thấy cạnh, `CLK_MISS` chu kỳ không có cạnh → `Trail` | ✓ | |
| `Trail` | đóng cổng; bộ thu HS còn bật tới LP-11 (như hôm nay), hoặc tắt ngay cùng termination khi `CTRL.CLK_MISS_OFF` = 1 (T_CLK-MISS, mục 3.4) | ✓ | `CLK_MISS_OFF`: v1.x |
| `Exit` | LP-11 khi cổng còn mở: đóng cổng trước, tắt bộ thu 2 chu kỳ sau | ✓ | |
| `UlpsRqst`, `Ulps`, `UlpsExit` | LP-11 → LP-10 → LP-00 (ULPS); thoát: LP-10 (`clk_lane_pd` = 0 ngay) → LP-11 [S8][S18]. RTL (bước 6): `UlpsRqst` là `EscRqst` chung với data lane (LP-10), LP-00 → `Ulps` không có lệnh | — | v1.x |
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
theo `LpClkHz`, kẹp theo độ rộng trường. Bước 6 hiện thực cột `TimRstNs` = 0 (`TIM1` reset
`0x00100000`, `TIM2` 0); tham số `TimRstNs` đến cùng bản ASIC (bước 9).

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
| Chuỗi LP sai | `Stop` thấy LP-00 không qua LP-01; `HsRqst` thấy LP-10; LP-10 ở `Stop` khi `ULPS_EN` = 0 | data lane: `ErrControl[l]`; lane clock: `ErrControlClk` (Bow32, D-PHY chặn khi `CLK_CONT` = 1 từ bước 4; bước 2–3 controller che) | [2] CONTROL | `ERR_STATUS.LP` (lane clock chỉ khi không `CLK_FORCE`) |
| HS quá lâu | ở `Hs` quá `HS_TMO` | `ErrControl` (Bow32) | [3] HS_TMO (bước 6: cùng [2] CONTROL và `CNT_LPERR`, như watchdog hôm nay) | watchdog → LP |
| Lệnh escape lạ | lệnh không phải ULPS (chưa hỗ trợ LPDT/trigger) | `ErrEsc` | [4] ESC | lỗi LP |
| LPDT lẻ bit | (sau) | `ErrSyncEsc` | [5] SYNC_ESC | — |
| Mất clock khi data ở HS | data lane vào `Settle`/`Hs` khi lane clock không ở `Hs` (trừ `CLK_CONT`); chỉ khi `CTRL.CLK_LOST_EN` = 1. Bước 6: ở cạnh lên của `Hs` của data lane (hết `SETTLE`) khi cổng byte clock đang đóng | `ErrControl` (Bow32) | [6] CLK_LOST | lỗi LP của lane clock khi cổng đóng |
| Kết thúc burst muộn | data lane về `Stop` khi lane clock đã rời `Hs`: `RxActiveHS` không xuống kịp trong miền byte. Bước 6: cổng byte clock đóng (không do `Enable` của lane clock hay `CMD.REINIT`) khi `RxActiveHS` của một data lane đang bật còn 1 ở miền byte (giá trị controller lấy ở cạnh byte clock cuối), một lần mỗi lane mỗi lần kết thúc burst | — | [7] LATE_EOT | F7: sự kiện tới ở burst sau |
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
| `Stopstate[l]`, `StopstateClk` | FSM ở `Stop` (và đã qua `T_INIT`). v1 (bước 2): giải mã thanh ghi trạng thái, chỉ dùng được ở chính `lp_clk`; lấy mẫu ở miền khác (mục 4.11) cần bản có flop, khi controller bắt đầu dùng nó | lp |
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

**v1 (bước 4–5, [dphy_rx.md](dphy_rx.md)).** RTL có tập con sau của bảng; offset hay trường chưa có
đọc 0, ghi bị bỏ. `ID`, `INFO` ([3:0], [7:5], [17:8], [21:18] = 9, [23]; bit khối [24]–[31] = 0),
`INFO2`; `CTRL` chỉ [1] CLK_CONT và [6] DES_RST_DIS ([0] EN và các bit khác của v1.x ở bước 6, 8,
10); `CMD` [1] REINIT và [3] CNT_CLR: REINIT ở v1 chỉ là xung 32 chu kỳ bus tới AFE (`reinit_o` ở
bước 4, `cal_start` của giao diện AFE từ bước 5; thay GPIO PA4: adapter Versal chạy lại XPLL, BISC,
VT; UltraScale+ không có), phần "các FSM về `WaitStop`, `T_INIT` đếm lại" và `CMD.AFE_CAL` riêng đến
ở bước 6; `AFE_CTRL` [0] PD (bước 5; TST_MODE, ATB_SEL khi AFE có điểm móc test); `AFE_STATUS` [0]
READY, [1] CAL_DONE, [2] CAL_ERR (bước 5) và [15:8] `status`; `TIM0`; `LANE_LP`; `LANE_HS` ([17]
`RxClkActiveHS` = cổng, mục 5.3); `IRQ_STATUS` / `IRQ_EN` [0] ERR, [3] RAW_DONE; `ERR_STATUS` [2]
CONTROL; `ERR_LANE` [8+l], [16]; `BYTECLK`; `CNT_BURST0`…`3`, `CNT_CLK`, `CNT_LPERR`; `DLY0`…`3`;
`RAW_CTRL`, `RAW`. `DLYn` ở v1 **chưa có chủ thứ hai** của mã: CODE và OWN là flop miền bus lái
thẳng `dly_code` / `dly_own` của AFE (bước 4: qua giao thức nạp `DlyVid` của D-PHY; từ bước 5 không
còn giao thức nạp, AFE áp mã khi OWN lên hay mã đổi, mục 3.5), [8:0] CODE đọc lại mã đã ghi (không
đồng bộ ngược), `PEND` = OWN ∧ (`dly_q` ≠ CODE) lấy từ delay của chính PHY thay cho ack gray (không
thêm bus gray mới, nên phép đếm 9 / 11 ràng buộc bus skew không đổi); OWN đặt bởi lần ghi khi
`AFE_STATUS.READY` = 1, xoá khi READY = 0; chưa có `CMD.DLY_REL`, nên DV `be` kiểm hai trường hợp
đầu (ghi cả word, ghi chỉ byte 2–3). Bộ đếm 32 bit bão hoà, xoá bằng `CMD.CNT_CLR`.

**v1.x (bước 6).** Thêm vào tập con trên: `INFO[27]` = 1; `CTRL` [2] ULPS_EN, [3] HSRX_EARLY, [7]
CLK_LOST_EN, [16] CLK_MISS_OFF; `CMD` [0] APPLY (đọc [0] = APPLY đang chờ), [1] REINIT (máy LP về
`WaitStop`, `T_INIT` đếm lại), [2] AFE_CAL (`cal_start`, tức REINIT của bước 4–5), [3] CNT_CLR;
`TIM1`, `TIM2` đủ trường; `LANE_STOP`; `IRQ_STATUS` / `IRQ_EN` [1] ULPS; `ERR_STATUS` [3] HS_TMO, [4]
ESC, [6] CLK_LOST, [7] LATE_EOT, [10] ESC_TMO; `CNT_DSK[31:16]` (lần vào ULPS), `CNT_MISC[31:16]`.
Vẫn chưa có (đọc 0): `CTRL` [0] EN, [4] SOT_TOL, [5] DSK_EN, [15:8] LANE_EN (lane tắt bằng `Enable`
của PPI), `CMD` [4] DSK_RUN, DLY_REL, DLY_CLK_REL (`INFO[30]` = 0), `ERR_STATUS` [0] SOT_SYNC, [1]
SOT (controller đếm SoT), [5] SYNC_ESC, [8] DSK_FAIL, [9] AFE, `ERR_LANE[l]` SOT_SYNC,
`CNT_DSK[15:0]` (controller đếm burst deskew, `CNT_EXT[31:16]`), `CNT_MISC[15:0]` (`ErrSotHS`,
v2); `INFO2`, `AFE_*`, `DLYn`, RAW như v1. Chi tiết: [dphy_rx.md](dphy_rx.md).

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
được đổi khi lane tắt. **Bước 6** hiện thực nó cho `CTRL` và `TIM0`–`TIM2` (`LANE_MAP` / `LANE_POL`
ở v2): `CMD[0]` đọc 1 từ lần ghi APPLY tới khi ack về; driver không ghi shadow khi đó; một APPLY ghi
khi một APPLY khác đang chờ được nhớ và làm lại sau ack (lần ghi cuối luôn được áp); sau reset miền
lp chép shadow một lần không cần APPLY. Vivado xếp đường shadow → miền lp vào CDC có CE (CDC-15,
cảnh báo).

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
| bus ↔ lp: `CTRL`, `TIM*`, `LANE_MAP`, `LANE_POL` | shadow + APPLY toggle (v1.x, bước 6: `u_sync_apply`, ack `u_sync_apply_ack`; v1: `bow_sync` từng bit) | không còn bus đồng bộ từng bit; CE (CDC-15) |
| lp → byte: `CLK_TOG_DIV` | 2 flop từng bit (`u_sync_tdiv`), gần tĩnh (đổi ở APPLY) | một giá trị trộn chỉ làm một chu kỳ đảo dài / ngắn hơn |
| byte → lp: `RxActiveHS` cho LATE_EOT | 2 flop mỗi lane (`u_sync_eot`), đọc 3 chu kỳ lp sau khi cổng đóng (byte clock đã dừng) | |
| bus → lp: `DLYn` (mã) | bộ đếm gray yêu cầu 2 bit + dữ liệu ổn định (như `DlyVid` = 1 hôm nay); ack gray ngược lại cho `PEND` | mỗi lần ghi một lần cập nhật; lần cập nhật cách nhau ≥ 16 chu kỳ |
| lp → bus: mã đang lái AFE, OWN | 2 flop từng bit, gần tĩnh (chỉ đổi sau một lần ghi đã ack hay một bước của bộ máy) | đọc khi `PEND` = 0 |
| lp → bus: sự kiện (vào HS, lỗi LP, ULPS) | bộ đếm ở miền nguồn, đọc qua mã gray (v1.x). Bước 6: bộ đếm gray 4 bit mỗi loại (`evc_gray_q`: vào HS và lỗi LP mỗi lane, HS_TMO, ESC, ESC_TMO, CLK_LOST, LATE_EOT, vào / ra ULPS), ≤ 1 bước mỗi chu kỳ lp, sự kiện của nhiều lane cùng chu kỳ bước dần ở các chu kỳ sau; `u_sync_evc`; thanh ghi cộng hiệu | bỏ ràng buộc `lp_clk` ≤ 16/3 × `clk_i` của hôm nay (F10); thay bằng `lp_clk` ≤ 12 × `clk_i` (không quá 15 bước giữa hai lần đọc, kiểm khi elaborate); `set_bus_skew` một chu kỳ lp |
| byte → bus: sự kiện (SoT, deskew) | `bow_cdc_pulse` (như hôm nay) | mỗi loại ≤ 1 lần mỗi burst |
| bus ↔ byte: lệnh RAW | bộ đếm gray req/ack 4 bit (như hôm nay) | `set_bus_skew` |
| byte → bus: đồng hồ đo byte clock | gray 20 bit | `set_bus_skew` |

**v1 (bước 5).** `dly_code`, `dly_own`, `pd`, `lprx_en`, `lane_pd` và `cal_start` ra từ flop miền
bus (mục 3.2, *v1*), không qua bus → lp; hàng `DLYn` của bảng (bộ đếm yêu cầu + ack) đến cùng bộ
máy deskew (bước 8). Adapter FPGA đồng bộ mã và OWN theo clock của primitive và chỉ nhận giá trị đã
ổn định 2 chu kỳ: `bow_dphy_dly_xusp` ở byte clock, `bow_dphy_dly_xphy` ở `CTRL_CLK` (= `vid_clk`;
XDC Huins giữ `set_bus_skew` một chu kỳ `vid_clk` từ CODE + OWN tới bộ đồng bộ đó, XDC KV260 một
chu kỳ byte clock từ review bước 5: không có nó, bit của một lần ghi tới lệch nhau hơn một chu kỳ
có thể cho một mã trộn ổn định 2 chu kỳ và bị nạp).

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
vì PA5 = 0 đã hỏng trên bo; chỉ tắt được bằng bit thử `DES_RST_DIS`; các tuỳ chọn của mô phỏng
chuyển sang bit này (`+S274_PA5=0` thành `+S274_DESRST=0`, `FW=brst0` ghi `DES_RST_DIS` = 1).

## 5. PPI

### 5.1 Nguyên tắc

PPI là giao diện tham khảo giữa PHY và lớp giao thức, nằm ở một phụ lục của đặc tả D-PHY [S15];
tên tín hiệu giống nhau giữa các hãng nhưng độ rộng, miền clock và chi tiết thời gian khác nhau
[S1][S4][S8][S9]. Bow32 lấy tập tín hiệu phía thu cho CSI-2 (không có phần TX, turnaround,
contention), 8 bit mỗi lane, giữ tên công khai, và ghi lại mọi chỗ lệch. RTL dùng struct trong
`bow_ppi_pkg` (`hw/ip/common/rtl/bow_ppi_pkg.sv` trong `common.f`, dùng chung cho D-PHY và controller, từ bước 2): `ppi_hs_t` mỗi data lane ở miền
byte, `ppi_lp_t` mỗi data lane và `ppi_lp_clk_t` của lane clock ở miền lp; `RxByteClkHS`
(`rx_byte_clk_hs`) và `Enable[l]` / `EnableClk` (`enable`, `enable_clk`) là cổng riêng. Tên trường
là tên PPI viết thường có gạch dưới (`RxActiveHS` → `rx_active_hs`). Wrapper tuỳ chọn đưa ra cổng
phẳng với tên PPI khi ghép với PHY hay controller của hãng khác.

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
| `ErrControl[l]`, `ErrEsc[l]`, `ErrSyncEsc[l]` | 2 | PHY → CTRL | lp, **bộ đếm gray** | v1.x: mỗi sự kiện tăng bộ đếm một bước, reset 0 (bước 6: các bước cách nhau ≥ 16 chu kỳ lp, sự kiện tới trong lúc chờ gộp vào bước kế tiếp); controller coi mỗi lần đổi giá trị là ≥ 1 sự kiện (5.3, mục 4.11). v1 (bước 2–5): xung một chu kỳ ở bit 0, controller chạy cùng clock |
| `ErrControlClk` | 2 | PHY → CTRL | lp, bộ đếm gray | Bow32: lỗi chuỗi LP của lane clock, cùng dạng với `ErrControl`; D-PHY chặn khi `CLK_CONT` = 1 (từ bước 4; bước 2–3 controller che, 5.3) |
| `RxLPDTEsc`, `RxDataEsc`, `RxValidEsc`, `RxClkEsc`, `RxTriggerEsc` | | PHY → CTRL | lp | để sau: nối hằng |
| `Enable[l]`, `EnableClk` | 1 | CTRL → PHY | bất kỳ (PHY đồng bộ) | bật lane [S3][S4]; AND với `CTRL.EN` và `LANE_EN` của D-PHY |
| `PhyReady` | 1 | PHY → CTRL | lp (mức) | Bow32: AFE sẵn sàng và PHY bật (giống `INIT_DONE` của PG202 [S3]); từ bước 4–5 (cần `ready` của AFE ở miền lp), PPI v1 chưa có |

`ForceRxmode` không có trên PPI của Bow32: `CMD.REINIT` của D-PHY làm việc đó.

### 5.3 Chỗ Bow32 lệch và vì sao

| Chỗ lệch | Vì sao |
|---|---|
| `RxValidHS` có khe giữa burst | FIFO RX của XPHY (adapter Versal) không có word ở vài chu kỳ đầu burst và đôi khi giữa burst; khe đi qua aligner ra PPI. Macro ASIC không có khe, nhưng controller phải chịu được (ghép lane đã chịu) |
| `RxActiveHS` lên ở cuối `SETTLE`, trước sync | để controller (ghép lane) biết burst bắt đầu cả khi sync hỏng; PG435 cũng ghi `RxActiveHS` không có quan hệ thời gian cố định với `Stopstate` [S4] |
| `ErrSotSyncHS` ở cuối burst (v1) | giữ aligner đã kiểm trên bo; v2 báo sớm (mục 4.5) |
| `RxSkewCalHS` là xung (v1) | như trên; v1.x thành mức |
| Lỗi miền lp ra dạng bộ đếm gray 2 bit (v1.x) | controller không có `lp_clk`: lấy mẫu bộ đếm gray ở miền luôn chạy của nó là CDC sạch và không mất sự kiện trong giới hạn tốc độ của mục 4.11; một xung (như PHY công khai) hay một toggle thì mất. PG202 và PG435 cũng để các tín hiệu này ở những miền khác nhau [S1][S4]; wrapper cổng phẳng đổi qua lại. v1 giữ xung cùng clock để bước 2 tương đương từng chu kỳ với hôm nay |
| Thêm `ErrControlClk` | hôm nay lỗi LP của lane clock cũng đánh dấu burst mất (`bow_csi2rx.sv:383`, trừ khi `CLK_FORCE`; DV `loss`); PPI công khai chỉ có `ErrControl` của data lane, còn controller sau khi tách không biết `CLK_CONT`, nên D-PHY chặn sẵn. Bước 2–3: `CLK_FORCE` còn là thanh ghi của controller, D-PHY chưa chặn; controller che (`ErrControl` theo enable lane, `ErrControlClk` theo `CLK_FORCE`, cả hai như D-PHY thấy, qua dải phụ tạm thời, mục 10); bước 4 chuyển phép che về D-PHY |
| `ErrControl` gồm cả HS timeout và CLK_LOST (khi `CLK_LOST_EN` = 1) | controller chỉ cần biết "có thể đã mất một burst" (luật `drop_i` hôm nay); D-PHY tách chi tiết trong `ERR_STATUS` riêng |
| Byte clock chạy thêm sau `RxActiveHS` xuống | với máy phát đúng T_CLK-POST, D-PHY bảo đảm `RxActiveHS` xuống khi lane clock còn chạy (mục 5.4); không bảo đảm được thì báo LATE_EOT thay vì để controller treo burst |
| Một `RxByteClkHS` cho mọi lane | mọi lane lấy mẫu bằng cùng lane clock; như PG202 và Lattice [S1][S8] |
| `PhyReady` thêm vào | AFE có hiệu chỉnh lúc khởi động (BISC; ASIC: DLL, offset): controller và driver phải biết khi nào PHY dùng được |
| `RxClkActiveHS` là cổng byte clock (v1) | trong v1 nó là `hs_active` của FSM lane clock, tức cổng byte clock: với `CLK_FORCE` / `CLK_CONT` (clock liên tục) nó = 1 suốt lúc lane clock được bật, kể cả ở `Stop` cùng `StopstateClk`. Trình tự dừng không được chờ nó xuống trong chế độ này (hạ `EnableClk` mới đóng cổng). Nghĩa chuẩn (lane clock ở HS) phải có trước khi controller hay driver dùng tín hiệu này |

**PPI v1 trong RTL (bước 2).** `bow_dphy_rx` sinh PPI từ đúng các tín hiệu mà ở bước 1 nó đưa cho
lớp CSI-2 bên trong `bow_csi2rx`; không có flop mới. Cột cuối là chỗ controller (`bow_csi2rx`) dùng.

| PPI | Trong RTL (`bow_ppi_pkg`) | Nguồn trong `bow_dphy_rx` (tên ở bước 1) | Controller dùng ở |
|---|---|---|---|
| `RxByteClkHS` | cổng `rx_byte_clk_hs` | `byte_clk_i` của I/O PHY | clock miền byte |
| `RxActiveHS[l]` | `ppi_hs_t.rx_active_hs` | `arm` (`u_sync_arm`; `rx_active_hs_o`) | ghép lane, cổng sự kiện aligner (`stale_q`, từ bước 4); RAW (lane 0) ở bước 2–3, từ bước 4 RAW nằm trong D-PHY |
| `RxValidHS[l]`, `RxDataHS[l]`, `RxSyncHS[l]` | `.rx_valid_hs`, `.rx_data_hs`, `.rx_sync_hs` | `valid_o`, `data_o`, `sot_o` của aligner | ghép lane |
| `RxSkewCalHS[l]` | `.rx_skew_cal_hs` | `ev_deskew_o` của aligner (xung) | `CNT_EXT[31:16]` (chỉ lane 0; từ bước 4 chỉ khi RX bật, mục 5.5) |
| `ErrSotSyncHS[l]` | `.err_sot_sync_hs` | `ev_sync_err_o` của aligner | `CNT_SOT*`, `ERR_STATUS.SOT` (từ bước 4 chỉ khi RX bật, mục 5.5), `drop_i` |
| `ErrSotHS[l]` | `.err_sot_hs` | 0 (v2) | — |
| `Stopstate[l]`, `StopstateClk` | `ppi_lp_t.stopstate`, `ppi_lp_clk_t.stopstate` | FSM ở `Stop`: giải mã thanh ghi trạng thái (`stop_o` mới của `bow_dphy_lp`, không thêm flop) | — |
| `RxClkActiveHS` | `ppi_lp_clk_t.rx_clk_active_hs` | `hs_active` của FSM lane clock (= cổng mở) | — |
| `ErrControl[l]` | `ppi_lp_t.err_control` (xung ở [0], [1] = 0) | `ev_err_o` của FSM data lane l (`ev_lp_err_o[1 + l]`); từ bước 4 che theo `Enable[l]` đã đồng bộ trong D-PHY | `ERR_STATUS.LP`, burst mất (OR); bước 2–3 thêm `CNT_MISC[23:16]` và controller che theo enable lane của dải phụ |
| `ErrControlClk` | `ppi_lp_clk_t.err_control` (như trên) | `ev_err_o` của FSM lane clock (`ev_lp_err_o[0]`); từ bước 4 che khi `CTRL.CLK_CONT` trong D-PHY | như trên; bước 2–3 controller che khi `CLK_FORCE` |
| `UlpsActiveNot[l]`, `RxUlpsEsc[l]`, `ErrEsc[l]`, `ErrSyncEsc[l]`, `UlpsActiveNotClk`, `RxUlpsClkNot` | các trường cùng tên | hằng 1, 0, 0, 0, 1, 1 (v1) | — |
| `Enable[l]`, `EnableClk` | cổng `enable`, `enable_clk` (controller → D-PHY) | vào `u_sync_vcfg` thay cho `lane_en_i`, cùng thứ tự bit | lái từ `lane_en_q` của `bow_csi2rx_regs` (flop miền CPU) |
| `PhyReady` | — | — | bước 2–3: `STATUS.PHY_RDY` qua dải phụ; từ bước 4 không dùng (`AFE_STATUS.READY` của D-PHY) |

`ev_lp_loss_o` của bước 1 (luật đánh dấu burst mất tính trong D-PHY) không còn; phép gộp và phép
che nằm ở controller (mục 10, bước 2). Phần nào của ranh giới hôm nay chưa là PPI thì đi qua dải
phụ tạm thời liệt kê ở mục 10.

**PPI v1.x trong RTL (bước 6).** Khác bảng trên ở: `ErrControl[l]`, `ErrControlClk`, `ErrEsc[l]`
là bộ đếm gray 2 bit (`bow_ppi_err_tx`, flop `gray_q`, ≤ 1 bước mỗi 16 chu kỳ lp, sự kiện tới
trong lúc chờ gộp vào bước kế tiếp; nguồn: lỗi chuỗi LP, HS_TMO, CLK_LOST khi bật cho `ErrControl`; lệnh escape lạ
và ESC_TMO cho `ErrEsc`; che như trước theo `Enable` / `CLK_CONT`), `ErrSyncEsc` 0; `RxSkewCalHS`
là mức trên mọi lane (`ev_deskew_o` của aligner OR `dsk_lvl_q`: từ xung deskew tới khi `RxActiveHS`
xuống); `Stopstate` vẫn là giải mã trạng thái `Stop` (sau `T_INIT`); `UlpsActiveNot[l]` =
¬(`Ulps` ∨ `UlpsExit`), `RxUlpsEsc[l]` = `Ulps`, `UlpsActiveNotClk` và `RxUlpsClkNot` tương tự của
lane clock. Controller lấy mẫu `ErrControl*` ở `vid_clk_i` (`bow_ppi_err_rx`, `u_lperr`: 2 flop mỗi
bit, giá trị trước, "đổi" = ≥ 1 lỗi) và đếm `RxSkewCalHS` lane 0 ở cạnh lên (`dsk_last_q`).

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
byte clock) cho hard D-PHY của họ [S8]. Mốc thời gian FS / dòng của controller v1 cần nhiều hơn:
≥ 8 cạnh byte clock sau byte cuối của packet (mục 5.5), tức T_CLK-POST cộng trail; ở 80 Mbit/s
ngân sách trên chỉ vừa đủ, sau wrapper cổng phẳng thì thiếu, tới khi bước 7 đưa packet sang
`csi_clk`.

### 5.5 Hồ sơ PPI của controller

Controller của Bow32 chỉ dựa vào những gì liệt kê dưới đây. Một PHY khác (của một hãng, hay theo
PPI công khai của PG202, PG435, Lattice [S1][S4][S8]) ghép được qua wrapper cổng phẳng
`bow_csi2rx_ppi_flat` nếu thoả cột "Cần" (sau những gì cột cuối làm thay nó); cột "Chịu được" là
những biến thể DV phủ (`tb_csi2rx_ppi`, bước 3). Bảng đã sửa theo kết quả bench của bước 3: ba
điều bảng cũ ghi sai cho controller v1 (`RxActiveHS` cùng chu kỳ `RxSyncHS`, `RxActiveHS` xuống
ngay sau byte cuối, `RxSkewCalHS` dạng mức) và ba điều kiện bảng cũ không ghi (mỗi lane đưa byte
tới hết word cuối, các lane lệch nhau trong FIFO 8 byte, `RxActiveHS` của các lane chồng nhau).
Từ bước 4 controller không còn dải phụ: PHY tự che `ErrControl*` (một yêu cầu mới ở cột Cần), trạng
thái lane, sẵn sàng, bộ đếm và RAW là thanh ghi của PHY; controller bỏ `ErrSotSyncHS` /
`RxSkewCalHS` khi RX tắt và của burst đã chạy lúc RX bật.

| Tín hiệu | Controller cần | Controller chịu được | Wrapper cho PHY chuẩn |
|---|---|---|---|
| `RxByteClkHS` | chạy suốt burst; ≥ 4 byte clock sau khi `RxActiveHS` xuống (mục 5.4; sau bước 7: chỉ đủ để đẩy dấu cuối burst qua FIFO). Đo ở bước 3: pixel, bộ đếm, LOG, `FRAME_ERR` vẫn đúng khi clock dừng sớm hơn, cả trước khi `RxActiveHS` xuống (việc cuối burst: kết thúc burst, SKEW, `ErrSotSyncHS`, cắt packet xong khi clock chạy lại); FS và dòng có mốc thời gian đúng (`FRAME_TIME`, `LINE_TIME`) khi clock còn ≥ 8 cạnh sau cạnh mang byte cuối của packet (đo: 7 thì sai). Ở v1 số cạnh này là T_CLK-POST cộng trail sau byte cuối: ở 80 Mbit/s, với các số của mục 5.4 (clock chạy ~7 byte clock sau khi data lane về LP-11, `RxActiveHS` xuống ~2,4 byte clock sau LP-11, HS-TRAIL ~1,1 byte clock), ước lượng còn ~8 cạnh, đúng bằng giới hạn; sau wrapper (cần 9 ở PHY) thì thiếu. Bench chỉ chạy byte clock 5,6–10,4 ns và trail 8+ byte của D-PHY Bow32 che giới hạn này; bước 7 (packet ở `csi_clk`, mục 6.5) bỏ nó | dừng giữa các burst, đúng 4 cạnh sau cạnh `RxActiveHS` xuống, 0–3, trước khi nó xuống; chạy liên tục | PHY chạy thêm 2 byte clock sau khi `RxActiveHS` xuống (wrapper giữ `RxActiveHS`, dưới) và 1 sau byte cuối (9 cạnh) |
| `RxActiveHS` | lên ≥ 1 chu kỳ trước `RxSyncHS` của lane sớm nhất (ghép lane chỉ nhận byte của một lane từ chu kỳ sau cạnh lên; cùng chu kỳ thì mất sync, mất burst); còn cao ≥ 1 chu kỳ sau byte cuối mà packet cần (word của byte đó rời FIFO ghép lane một chu kỳ sau); `RxActiveHS` của các lane chồng nhau trong một burst (một chu kỳ mọi lane cùng thấp là hết burst: lane trễ thành burst khác, SKEW hai lần) | lên ở bất kỳ chỗ nào từ cuối SETTLE (Bow32) tới 1 chu kỳ trước `RxSyncHS`; byte còn ra sau khi nó xuống (aligner của Bow32: tới 2 byte) bị bỏ | mọi tín hiệu miền byte trễ 1 chu kỳ, trừ cạnh lên của `RxActiveHS`; `RxActiveHS` giữ thêm 2 chu kỳ khi xuống: PHY được nâng `RxActiveHS` cùng `RxSyncHS` (PG202, PG435) và hạ nó ngay sau byte cuối; PHY giữ `RxActiveHS` thấp ≥ 3 chu kỳ giữa hai burst |
| `RxSyncHS` | một xung mỗi burst đồng bộ được, cùng chu kỳ với byte đầu | — | trễ 1 chu kỳ |
| `RxValidHS` | không có backpressure; mỗi lane đưa byte tới hết word cuối của packet (ghép lane lấy cả word, một byte mỗi lane: byte rác của HS-TRAIL làm đầy word; PHY cắt hết trail phải đưa thêm byte trên lane ngắn hơn, nếu không packet bị cắt); sau khi word đầu đã ra, các lane lệch nhau không quá FIFO 8 byte (byte vào FIFO đầy bị mất, không báo lỗi). Trước word đầu, lệch ≥ 7 byte clock giữa byte đầu của các lane chỉ thành SKEW khi lane sớm đã đưa ≥ 9 byte (kể cả trail) tới hết chu kỳ ngay sau byte đầu của lane muộn (FIFO của nó tràn); với trail ngắn của PHY chuẩn, một packet ngắn lệch ≥ 7 được ghép đúng, hay thành hai burst (SKEW hai lần) nếu `RxActiveHS` không chồng nhau | khe ở bất kỳ đâu trong burst: chung mọi lane, hay ở lane đang đi trước (XPHY); không khe | trễ 1 chu kỳ |
| `ErrSotSyncHS` | ≤ 1 xung mỗi burst. Từ bước 4 controller chỉ đếm khi RX bật (reset đường dữ liệu `drst_n` đã nhả) và bỏ xung của burst mà `RxActiveHS` của lane đã cao lúc RX bật (tới một chu kỳ sau khi nó xuống), như khi aligner còn bị reset cùng đường dữ liệu (bước 1–3) | ở cuối burst (Bow32 v1) hay ngay sau HS-zero (v2, PHY khác); có hay không có `RxActiveHS` đi kèm (không kèm: đếm từ chu kỳ thứ hai sau khi `drst_n` nhả) | trễ 1 chu kỳ |
| `RxSkewCalHS` | v1: xung (controller đếm ở lane 0 mọi chu kỳ nó cao, qua bộ đồng bộ xung; từ bước 4 bỏ như `ErrSotSyncHS` khi RX tắt và ở burst đã chạy lúc RX bật); v1.x (bước 6): controller đếm cạnh lên, một lần mỗi burst deskew | xung; mức (bước 6) | v1: cạnh lên thành xung 1 chu kỳ; bước 6: chỉ trễ 1 chu kỳ (controller tự lấy cạnh lên): chịu được mức (PG202) |
| `ErrSotHS` | — (v1 chưa dùng) | đi cùng `RxSyncHS` | trễ 1 chu kỳ |
| `ErrControl*`, `ErrEsc`, `ErrSyncEsc` | v1: xung một chu kỳ `vid_clk_i` (`PpiLpClkHz` = `PhyClkHz`); v1.x (bước 6): bộ đếm gray 2 bit ở miền lp, các bước cách nhau ≥ 16 chu kỳ lp, controller lấy mẫu ở `vid_clk_i` ≥ `lp_clk` / 32 (`PpiLpClkHz` ≤ 32 × `PhyClkHz`, mục 4.11). Từ bước 4: PHY chỉ báo `ErrControl[l]` khi `Enable[l]` = 1. Controller chỉ lấy OR của chúng cho luật đánh dấu burst mất và `ERR_STATUS.LP`, không che lại: lỗi báo sau khi `Enable` đã xuống, dù chỉ một hai chu kỳ, đánh dấu burst mất. D-PHY Bow32 che bằng `Enable` đã đồng bộ (`u_sync_vcfg`), đúng mặt nạ controller dùng ở bước 2–3 | — | v1: mỗi xung ở clock lp của PHY (`lp_clk_i`) thành một xung `vid_clk_i` (`bow_cdc_pulse` mỗi lane; xung của một lane cách ≥ 3 chu kỳ video); v1.x (bước 6): mỗi xung thành một bước của bộ đếm gray ở chính clock lp của PHY (`bow_ppi_err_tx`, tham số `LpClkHz` của wrapper). Không che (bước 3 còn che theo `Enable` qua 2 flop). `ErrEsc`, `ErrSyncEsc`: v1 chưa dùng |
| `ErrControlClk` | PHY không báo khi lane clock chạy liên tục (D-PHY Bow32: che khi `CTRL.CLK_CONT`, từ bước 4) | không có: lỗi LP của lane clock không đánh dấu burst mất | nối 0 |
| `Stopstate*`, `RxClkActiveHS` | mức; `RxClkActiveHS` xuống khi lane clock dừng (driver chờ nó trước khi hạ `Enable`; trừ clock liên tục ở v1, mục 5.3). Từ bước 4 controller không đọc chúng: driver đọc trạng thái lane ở thanh ghi của PHY (D-PHY Bow32: `LANE_HS[17]`) | — | không dùng (bước 3: `RxClkActiveHS` qua 2 flop thành `STATUS.CE`) |
| `PhyReady` | — (từ bước 4: sẵn sàng là thanh ghi của PHY; D-PHY Bow32: `AFE_STATUS.READY`) | không có | không có cổng (bước 3: `phy_ready_i` qua 2 flop thành `STATUS.PHY_RDY`) |
| `Enable` | PHY bật/tắt lane theo nó | — | — |

**v1 (bước 2–5).** Bảng trên là hồ sơ đích (v1.x) cùng những gì controller v1 đo được ở bước 3,
với các yêu cầu bước 4 thêm. Ở bước 2–3 controller v1 còn cần dải phụ tạm thời của mục 10 (enable
lane và `CLK_FORCE` đã đồng bộ cho luật đánh dấu burst mất, `band_ev_hs` cho `CNT_BURST*` /
`CNT_MISC[15:0]`, word thô cho RAW, `STATUS` / `BYTECLK` / đọc lại `DLYn`). Từ bước 4 dải phụ
không còn: controller chỉ cần PPI, với `ErrControl*` là xung một chu kỳ ở `vid_clk_i`
(`PpiLpClkHz` = `PhyClkHz`) mà PHY đã che (cột Cần), và ngắt của PHY (`irq_i`, `IRQ_STATUS[5]`)
là tuỳ chọn. Wrapper cổng phẳng (bước 3, `hw/ip/csi2rx/rtl/bow_csi2rx_ppi_flat.sv`, không nằm
trong `csi2rx.f`) ghép controller v1 với một PHY chuẩn: ba việc ở miền byte (cột cuối), bộ đồng bộ
xung của `ErrControl`, còn `ErrControlClk` và `irq_i` nối 0, với hệ quả: lỗi LP của lane clock
không đếm và không đánh dấu burst mất; `IRQ_STATUS[5]` đọc 0; `INFO[6]` đọc 0 (không có D-PHY Bow32
ở `0xC00`); trạng thái lane, sẵn sàng, bộ đếm HS entry và lỗi LP, đồng hồ đo, delay và RAW là thanh
ghi riêng của PHY. Ở bước 3 wrapper còn lái dải phụ từ cổng PPI (enable lane cho luật burst mất:
`Enable` qua 2 flop `vid_clk_i` như `u_sync_vcfg` của D-PHY; `STATUS.CE` từ `RxClkActiveHS`;
`STATUS.PHY_RDY` từ `phy_ready_i`) và nối hằng phần còn lại; bước 4 bỏ hết, kể cả mặt nạ enable
lane (việc của PHY, cột Cần của `ErrControl*`) và cổng `phy_ready_i`.

**v1.x (bước 6).** Controller cần PPI v1.x của bảng: `ErrControl*` là bộ đếm gray đã che (mỗi lần
đổi là ≥ 1 lỗi, lấy mẫu ở `vid_clk_i` ≥ `lp_clk` / 32), `RxSkewCalHS` xung hay mức (đếm cạnh lên).
Một PHY chỉ phát xung lỗi ghép qua wrapper (bộ đếm ở clock của PHY); một PHY giữ `RxSkewCalHS` cao
liên tiếp qua hai burst deskew không có `RxActiveHS` thấp ở giữa thì chỉ được đếm một lần (D-PHY
Bow32 hạ nó cùng `RxActiveHS`). BFM của bench PPI phát lỗi dạng bộ đếm gray (chế độ `bow`) và
`RxSkewCalHS` dạng mức như D-PHY; chế độ `std` giữ xung ở PHY. Mọi case của bước 3–5 giữ kết quả.

**Bước 3 (xong, mục 10).** `tb_csi2rx_ppi` chạy controller với `bow_ppi_bfm` ở hai chế độ: thời
gian của D-PHY Bow32 (`RxActiveHS` lên ở cuối SETTLE, khe `RxValidHS` như XPHY, `ErrSotSyncHS` cuối
burst, byte còn ra khi `RxActiveHS` đã xuống, lỗi lp và HS entry là xung `vid_clk_i`,
`band_lane_en_lp` = `Enable` qua 2 flop như D-PHY, word thô của RAW có khe theo khe của lane 0),
và thời gian PHY chuẩn qua wrapper
(`RxActiveHS` lên cùng `RxSyncHS` và xuống ngay sau byte cuối, không khe, trail 0–3 byte,
`ErrSotSyncHS` sớm có hoặc không có `RxActiveHS`, `RxSkewCalHS` xung hay mức, `ErrSotHS`, lỗi dạng
xung ở clock lp riêng của PHY, không `ErrControlClk`, không `PhyReady`). Cả hai chạy sạch: mục tiêu
4 của mục 1.1 đạt ở mức mô phỏng với hồ sơ như bảng trên. Ba việc của wrapper (trễ miền byte, giữ
`RxActiveHS`, cạnh lên của `RxSkewCalHS`) là điều kiện: bỏ một việc thì chế độ PHY chuẩn hỏng
(mutant của bước 3). Mặt nạ enable lane của wrapper được kiểm ở trạng thái đã ổn định (`lpmask`:
lỗi LP của lane mà `CTRL` đã tắt từ trước chỉ được đếm, của lane đang bật thì đánh dấu burst mất);
hai flop đồng bộ của nó là cấu trúc CDC mà mô phỏng không nhắm được (lỗi của PHY tới controller
qua bộ đồng bộ xung của wrapper, 2–3 chu kỳ video), nên chỉ chế độ D-PHY Bow32 kiểm chu kỳ cuối
trước / đầu sau khi mặt nạ áp dụng. Từ bước 4 mặt nạ này không còn ở controller hay wrapper (D-PHY
che; `bow_ppi_chk`, gắn vào D-PHY trong bench cả bộ thu, kiểm ở mọi chu kỳ rằng không có
`ErrControl[l]` khi `Enable[l]` = 0 và không có `ErrControlClk` khi `CLK_CONT`): `lpmask` kiểm phép
OR (lỗi của lane mà `CTRL` đã tắt cũng đánh dấu burst mất), BFM không còn dải phụ hay word thô của
RAW (RAW của D-PHY kiểm ở bench cả bộ thu, test `raw`).

Phần dựng thời gian PHY chuẩn còn mượn bốn điều của D-PHY Bow32, nên chưa phủ một PHY làm khác
ở những chỗ đó: (a) burst mà mô hình bỏ vì lệch lane có trail 9–12 byte mỗi lane thay cho 0–3,
vì luật SKEW ≥ 7 của mô hình cần lane sớm làm tràn FIFO (cột Cần của `RxValidHS`); (b) đoạn 1 của
`clkstop` dùng trail 8–12 byte để mốc thời gian còn đúng khi clock dừng đúng 4 cạnh sau khi
`RxActiveHS` xuống (≥ 8 cạnh sau byte cuối, cột Cần của `RxByteClkHS`); (c) `RxActiveHS` của lane
sớm được kéo dài tới sau khi lane muộn lên (điều kiện chồng nhau của cột Cần), nên bench không có
PHY hạ `RxActiveHS` của một lane trước khi lane muộn lên; (d) lane khoá hay không là do mô hình
aligner của Bow32 quyết (`lane_receive`): byte sync sai 1 bit thành `ErrSotSyncHS` không có
`RxSyncHS`, trong khi một PHY v2 có thể nhận nó với `ErrSotHS` cùng `RxSyncHS` và đưa byte ra;
`ErrSotHS` trong bench chỉ là cờ ngẫu nhiên trên sync đúng (controller v1 bỏ qua nó). Với PHY của
một hãng cụ thể vẫn phải kiểm riêng.

## 6. Bộ điều khiển CSI-2 sau khi tách

### 6.1 Giữ lại và chuyển đi

| Phần | Sau khi tách |
|---|---|
| Ghép lane (`bow_csi2_lane_merge`): FIFO 8 byte mỗi lane, chịu lệch 6 byte clock, `sop`/`eob`, SKEW | **giữ**; đầu vào là PPI (`RxActiveHS` thay `arm`, `RxSyncHS` thay `sot`) |
| Lớp packet (`bow_csi2_packet`): ECC, CRC 1–4 byte/chu kỳ, VC/DT, FS/FE, EXTRA, LOG entry | **giữ** |
| Unpack, FIFO pixel 2 clock, đầu ra AXI4-Stream, `FRAME_ERR`, SKIP | **giữ** |
| Bộ lọc VC/DT (một luồng) | **giữ**; thành router N luồng sau (mục 6.5) |
| LOG (`bow_csi2_capture`, nửa LOG) | **giữ** |
| Đánh dấu "burst mất ở mức LP" (`lpl_*`, `drop_i`) | **giữ**, nguồn là `ErrControl`/`ErrControlClk` của PPI (v1: xung cùng clock; v1.x: bộ đếm gray lấy mẫu ở `vid_clk_i`, sau bước 7 ở `csi_clk`), sang miền byte bằng req/ack gộp như hôm nay (mục 4.11); bước 2–3: controller che theo enable lane và `CLK_FORCE` như D-PHY thấy chúng (dải phụ, mục 10) |
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
bước 5. Ở bước 2–3, khi thanh ghi PHY còn ở `bow_csi2rx_regs`, controller còn thêm dải phụ tạm thời
(cổng `band_*`, mục 10) và chưa có `irq_i`; tham số `PpiLpClkHz` (tần số `lp_clk` của PHY) phải bằng
`PhyClkHz` vì lỗi lp của PPI v1 là xung lấy mẫu ở `vid_clk_i` (kiểm khi elaborate).

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
| GPIO PA4/PA5/PB6/PB7 (top Huins) | bước 4: `CMD.REINIT`, `CTRL.DES_RST_DIS` (0 từ reset: luôn bật), `AFE_STATUS[15:8]`; bước 5: `AFE_CTRL.PD`, `des_rst`; top camera Huins thôi nối bốn chân GPIO này (PA4…PA6 không còn chân, PB6 / PB7 đọc 0) |

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

**v1 (bước 4).** `bow_dphy_rx.c` có `probe()`, `lanes()` / `afe()` / `self_cal()` / `lp_mhz()`
(thay `info()`), `timing()` (không `CMD.APPLY` ở v1), `ready()`, `wait_ready()`, `reinit(ms, &us)`
(`CMD.REINIT`: READY phải xuống trong 20 µs, không thì PHY không có re-init), `des_rst(on)`,
`set_delay()`, `read_delay()` (đọc tới khi hai lần giống nhau), `wait_delay()` (PEND = 0 trên lane
có OWN), `get_delays()`, `print_delays()`, `counters()`, `snapshot()` (bộ đếm cùng `LANE_LP` /
`LANE_HS`, đọc tới khi hai lần giống nhau: dòng `phy:` của `stat`; sửa sau review), `clear()`,
`raw()`, `byteclk_hz()`;
`power()` và `release_delay()` chưa có (sửa sau review bước 5: bước 5 chỉ thêm thanh ghi
`AFE_CTRL.PD`, driver chưa ghi nó, FPGA để PD = 0 từ reset; `power()` cho cấu hình ASIC `AfePdRst`
= 1 và `release_delay()` cùng `CMD.DLY_REL` đến ở bước 6), `deskew()`, `prbs()` ở bước 8.
`cam_sensor.c` thôi đặt PA5
mà ghi `DES_RST_DIS` = 0 (giá trị reset) mỗi lần khởi động bộ thu trên Versal (`-DCAM_BURST_RST=0`
của mô phỏng ghi 1); lệnh `phy` của `csi2_test` đọc `AFE_STATUS`/`DLYn` của D-PHY,
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

**Số liệu** (IMX274, 4 × 1440 Mbit/s, lần chạy bo 1–3 ngày 2026-11-10/11,
[../camera_huins.md](../camera_huins.md) mục 6.3, 9): trễ BISC 122/75/118/130 tap, tâm sau eye walk
300/184/264/228, tức tâm cao hơn BISC 178/109/146/98 tap; eye 352–360 tap; lặp lại giống hệt ở
lần 2 và 3. Lần 3 đo kích thước tap từ hai chuyển tiếp liên tiếp của mỗi lane: 1 tap ≈ 1,87 ps,
1 UI ≈ 374 tap (AM010 [S23] chỉ bảo đảm 512 tap ≥ 625 ps), nên tâm cách BISC **0,26–0,48 UI**,
không phải 1/4 UI như ước lượng ban đầu; theo nghĩa thời gian, điểm lấy mẫu của BISC rơi về cuối
bit. Ở trễ BISC có lỗi CRC (~11 % dòng ở lần 1; 0,2–1,5 lỗi mỗi frame ở lần 2–3). BISC cho cùng kết
quả khi cảm biến còn bị reset và các lane ở LP-00 (lúc nạp PDI) và khi lane clock đang chạy
(`phy reinit` lúc stream).

**Giả thuyết và kết quả kiểm** (lần chạy bo 3, 2026-11-11; chi tiết ở
[../camera_huins.md](../camera_huins.md) mục 9.1):

| ID | Giả thuyết | Kết quả |
|---|---|---|
| H1 | thuộc tính pha / kiểu strobe của XPHY khác cấu hình chuẩn (strobe căn mép như DQS, `RX_CLK_PHASE`) | **loại**: mọi thuộc tính XPHY giống netlist PHY MIPI RX của AMD trên cùng chân (gồm `RX_CLK_PHASE_P/N` = `SHIFT_0`, `DQS_MODE`, `RX_GATING`); trong mô hình XPHY, `SHIFT_90` chỉ đẩy clock muộn thêm ~0,48 UI, tức lật sai số sang phía kia |
| H2 | phần bù chuyển strobe (inter-nibble, inter-byte) khác nhau giữa các nibble | **loại cho phần chênh giữa lane**: BISC đã bù chuyển tiếp (mô hình +50 tap cho 2 chặng, khớp chênh 43–53 tap trên bo); độ lệch tâm − BISC không theo số chặng |
| H3 | lệch thật ở cảm biến / module / adapter / mạch | **đúng cho phần chênh giữa lane**: hai lane cùng một XPHY (cùng clock chuyển tiếp) vẫn lệch 78 tap ≈ 0,21 UI; package FPGA chỉ giải thích ~2 ps |
| H4 | cách cấu hình N slice (chỗ khác duy nhất so với netlist AMD) | **loại**: bản PDI có N slice như AMD cho trễ BISC và tâm như mặc định trong ±1 tap |
| H5 | phần chung (~0,37 UI) là một khoảng thời gian cố định mà BISC không thấy: lệch clock–data chung ngoài FPGA, hoặc một số hạng pha của silicon theo `PLL_CLK` | **còn mở**: thêm `DELAY_VALUE` 250 ps cho data lane dời mọi trễ BISC +132 tap trong khi tâm đứng yên (link sạch ngay ở trễ BISC, còn lệch +44/−24/+8/−34 tap); kiểm tiếp bằng PDI với `PLL_CLK` 3000 MHz và phép đo lệch clock–data phía thu |

**Hệ quả kiến trúc** (đúng với mọi giả thuyết, được lần 3 khẳng định): (1) độ lệch không phải hằng
số giữa các lane (≥ 0,2 UI đến từ ngoài FPGA), nên cộng một hằng sau BISC không đủ: trên Huins,
`DELAY_VALUE` 250 ps làm trễ BISC dùng được nhưng vẫn phải eye walk từng lane; (2) tự hiệu chỉnh của PMA chỉ là điểm xuất phát (`DLYn.OWN` = 0),
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
| Lề | `margin` ±68/±66 tap, BER < 3,6×10^-10 mỗi điểm (720p60) | trên bo (lần 2–3): `margin` ±86–90 tap, 0 lỗi trong 9 × 60 frame mỗi điểm (BER < 1,0×10^-8); 30 phút ở 1080p30 không lỗi, tap không trôi |

Cả hai đều hiệu chỉnh lúc chạy, trên dữ liệu; một bộ thu mã mở cho 7-series thì đặt tap lúc biên
dịch và không có đầu vào LP [S21]: không đủ khi tâm eye đổi theo route của từng lần build như
trên KV260.

## 8. Kế hoạch kiểm chứng

### 8.1 Theo lớp

| Lớp | Bench | Kích thích | Kiểm | CI |
|---|---|---|---|---|
| AFE (mô hình) | `bow_dphy_afe_model` tự kiểm (từ bước 8) | máy phát D-PHY mức bit | ngưỡng LP, termination, lấy mẫu, delay, cổng, `des_rst`, `clk_act` | có (Verilator) |
| D-PHY số | `tb_bow_dphy_rx` (mới, bước 6) + `tb_dphy_align` (giữ) | máy phát mức bit → `bow_dphy_afe_model`, hoặc `csi2_tx_model` ở cổng AFE | PPI so với scoreboard, timer, FSM, lỗi, ULPS, deskew, thanh ghi | có: thêm `hw/ip/dphy_rx/dv` vào `ci.yml` |
| Logic adapter | `bow_dphy_dly_xusp`, `bow_dphy_dly_xphy` (bước 5): trong `tb_bow_csi2rx` (`csi2_tx_model`) và bench riêng `tb_afe_dly` (review bước 5; `make -C hw/ip/csi2rx/dv afe`, trong `test-rx`) với mô hình primitive | ghi mã + OWN ở pha bất kỳ, bit lệch tới một chu kỳ; `ready`, cổng, `des_rst` | nạp khi mã đổi / OWN lên, không nạp mã đang dùng hay mã trộn, `VtcWait` / `LdGap`, không nạp và `RX_EN_VTC` = 1, `RX_RST` = 0 khi không `ready`, nạp lại lane OWN khi `ready` lên, reset `ISERDESE3` theo `des_rst`; 16 mutant (`make mutants-rx`) | có (Verilator) |
| Điều khiển AFE của D-PHY | `tb_dphy_afe` (review bước 5): `bow_dphy_rx` một mình với mô hình AFE, bản ASIC (`AfeKind` 0, `AfePdRst` 1) và FPGA; `bow_afe_chk` bind vào mọi bench | ghi thanh ghi; `ready` (xuống sau `pd`, kẹt ở 1), `cal_done` / `cal_err` / `status` | giá trị reset (lúc bật nguồn và reset giữa chừng), `AFE_STATUS` từng bit, `pd` / `lprx_en` / `lane_pd` (xung PD ngắn), OWN, `cal_start`, `DES_RST_DIS` | có (Verilator) |
| Controller | `tb_csi2rx_ppi` (bước 3, `make -C hw/ip/csi2rx/dv test-ppi`): `bow_csi2rx` với PPI và dải phụ do BFM lái, và wrapper cổng phẳng `bow_csi2rx_ppi_flat` | `bow_ppi_bfm` theo `csi2_model.py gen --ppi bow\|std`, hai chế độ thời gian (mục 5.5): D-PHY Bow32, PHY chuẩn qua wrapper; kỳ vọng từ cùng mô hình bộ thu | như DV hôm nay: pixel, bộ đếm, `FRAME_ERR`, `FRAME_TIME` / `LINE_TIME`, LOG, RAW (D-PHY Bow32), `STATUS` (CE theo `RxClkActiveHS`); 20 mutant của controller và wrapper (`make mutants-ppi`) | có |
| Cả bộ thu | `tb_bow_csi2rx` (giữ, DUT = `bow_mipi_rx`) | `csi2_tx_model` (UltraScale+ / Versal) | như hôm nay: 111 case từ bước 4 (105 ở bước 3), một trong số đó là unit test aligner (301 case con); RAW của D-PHY (`raw`) và cổng sự kiện aligner của controller (`rxoff`) chỉ bench này thấy (`mutants-rx`); thêm `bow_ppi_chk` (`hw/ip/dphy_rx/dv`, bind vào `bow_dphy_rx`, cả trong `tb_bow32`): các đầu ra PPI v1 mà controller chưa dùng (`Stopstate*`, `RxClkActiveHS`, bit 1 của `ErrControl*`, giá trị nghỉ) | có |
| Tương đương (bước 1–2) | D8: Yosys eqy, `bow_csi2rx` trước và sau khi tách (cổng không đổi). Bước 1 và 2 dùng Synopsys Formality, RTL với RTL, mọi cấu hình build (`hw/ip/dphy_rx/fm`, `make equiv STEP=<n>`: top và luật đổi tên của từng bước; D8 sửa đổi đã duyệt, mục 0) | — | tương đương hình thức; mọi cặp khớp có tên giống hệt sau luật đổi tên | eqy: có (thêm Yosys vào CI); Formality: không (cần license), chạy tay trước mỗi PR của bước 1–2 |
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
- **Bước 6** dựng bench này (`hw/ip/dphy_rx/dv/tb_bow_dphy_rx.sv`, [../simulation.md](../simulation.md)
  mục *D-PHY số*): máy phát là chính `csi2_tx_model.sv` của bench bộ thu trên giao diện AFE (chưa
  có `bow_dphy_afe_model`: bước 8), scoreboard byte mỗi lane mỗi burst, `bow_ppi_chk` /
  `bow_afe_chk` gắn vào, mọi bộ đồng bộ với jitter (`BOW_CDC_JITTER`, `BOW_SYNC_JITTER`); 12 test
  tự kiểm của các chức năng v1.x (2 và 4 lane), 35 mutant (`mutants_dphy.py`). Phủ ở bước 6 trong
  các case dưới: `T_INIT` (sau READY lên, sau `CMD.REINIT`, không ở `Enable`; một burst tới trước khi
  đủ `T_INIT` LP-11 không được nhận), `ErrControlClk`
  bị chặn khi `CLK_CONT`, bộ đếm gray của PPI ở tốc độ sự kiện tối đa với bộ lấy mẫu ở `lp_clk` / 32,
  `ESC_TMO`. Còn lại cho bước 8 (cần bộ máy deskew, `LANE_MAP` / `LANE_POL`, `DLY_REL`, mô hình
  AFE): các case `DLYn`, deskew, ánh xạ lane, và `T_INIT` với cảm biến giữ LP-11 ngắn hơn `T_INIT`
  trước burst đầu / VBLANK ngắn hơn `T_INIT` (bench bước 6 kiểm luật đếm, chưa kiểm hai kịch bản
  cảm biến đó).
- **Case mới bắt buộc** (mỗi case gắn với một quyết định của đặc tả): `T_INIT` (cảm biến giữ LP-11
  trước burst đầu ngắn hơn `T_INIT`; VBLANK ngắn hơn `T_INIT`; bộ thu bật giữa stream); stop/start
  giữ `DLYn`, OWN và không đụng `pd`; `ErrControlClk` (lỗi LP của lane clock, bị chặn khi
  `CLK_CONT`); bộ đếm gray của PPI ở tốc độ sự kiện tối đa và clock controller ở giới hạn
  `lp_clk` / 32; `DLYn` (ghi cả word, chỉ byte 3, `DLY_REL`, ghi khi bộ máy deskew chạy → ABORT,
  `ready` xuống → OWN xoá, `PEND`); bộ máy deskew (qua ranh giới UI, tầm quét > 2 UI, mã đầu ở mép
  eye); `LANE_MAP` / `LANE_POL` (cả lane clock: LP-01 ↔ LP-10); `ESC_TMO`.
- **`bow_ppi_bfm`** (bước 3, `hw/ip/csi2rx/dv/bow_ppi_bfm.sv`): lái PPI ở mức byte theo file kích
  thích của `csi2_model.py gen --ppi`: khe `RxValidHS`, lệch lane (byte), thời điểm `RxActiveHS`,
  lỗi lp, clock dừng sớm (T_CLK-POST ngắn), burst deskew; hai chế độ thời gian: D-PHY Bow32 và PHY
  chuẩn qua wrapper cổng phẳng (mục 5.5). Mô hình Python giữ vai trò tham chiếu viết từ quy tắc,
  không từ RTL ([csi2rx.md](csi2rx.md) mục *Kiểm chứng*): mỗi item TX của test case được mô hình
  bộ thu xử lý như với cả bộ thu (kỳ vọng không đổi), rồi được dựng lại ở PPI (lớp `Ppi`: sự kiện
  của máy LP, lane đã vào HS, `lane_receive` / `burst_receive` cho byte và lệch lane), kèm phép
  kiểm luật ghép lane trên đúng các chu kỳ đã dựng (`ppi_merge`: khe, FIFO 8 byte) để kỳ vọng
  của mô hình vẫn đúng. Bench này không nhanh hơn bench cả bộ thu: trên cùng case, mô phỏng
  controller một mình không rẻ hơn mô phỏng cả bộ thu (máy phát mức bit và D-PHY số rẻ trong
  Verilator), thời gian nằm ở mô hình Python, phần dựng PPI còn thêm vào bước sinh; cả hai bench
  chạy các case song song (`PJOBS`) nên chạy được nhiều seed (mục 10, kết quả bước 3).
- **Mutant:** mỗi thay đổi RTL của các bước 1–7 kèm mutant chứng minh test bắt được nó, như 57
  mutant của PR #17. Harness viết theo `hw/ip/mkv/dv` (Verilator, `make mutants`: bỏ một biện
  pháp nào cũng phải làm test fail); `hw/fpga/common/dv/mutants.py` là harness xsim của
  DDR/HyperRAM, không dùng làm mẫu ở đây.

### 8.4 Mô phỏng hệ thống

Mọi test của `sim/` chạy sau mỗi bước. Bước 1–3 không đổi kỳ vọng nào (refactor, mục 10); bước 4
đổi một số kỳ vọng (hàng bước 4 của bảng mục 10), bước 5 nữa (*Hành vi đổi có chủ ý* và *Kết quả
bước 5* của mục 10: số lần nạp delay và mốc thời gian của bản IMX274). Test `dphy` mới (firmware
`csi2_test` mở rộng): `AFE_STATUS`; `phy reinit` qua `bow_dphy_rx_reinit()`; stop/start giữ `DLYn`
và không có xung nào trên `cal_start` / `pd` của giao diện AFE (testbench đếm cạnh; `reinit_i` của
adapter trước bước 5); ULPS (mô hình cảm biến vào/ra ULPS); bộ máy deskew
với mô hình gửi burst deskew; PRBS qua loopback của mô hình AFE. Firmware build trước bước 4 trên
bitstream mới không được hỗ trợ (mục 6.3), nên không có test cho trường hợp đó.

### 8.5 FPGA

| Bo | Mục đích | Chạy gì |
|---|---|---|
| KV260 + IMX219 (2 × 912 Mbit/s) | adapter UltraScale+ và phần số không đổi | **hoãn (D1)**: không build và không chạy trên bo ở các bước chuyển; khi cần: `csi2_test` `test` (18/18 hôm nay), `camera`, `video`; quét `SETTLE`; `margin 0 1800` |
| Huins + IMX274 (4 × 1440 Mbit/s) | adapter Versal, PPI có khe, 4 lane | `csi2_test` `test` (17 check sau PR #17), `camera`, `video`; quét `SETTLE` với `des_rst`; trễ BISC đọc qua `DLYn`; stop/start giữ tap |
| Huins + `bow_dphy_tx` (loopback, **tuỳ chọn**) | HS ngoài khả năng của cảm biến: burst deskew, PRBS, tốc độ khác | máy phát D-PHY tổng hợp được (`bow_dphy_tx`: PPI TX + bộ tuần tự LP/HS) và adapter TX của Versal. Loopback trong nibble của XPHY (`TXRX_LOOPBACK`) đi vòng qua `IBUFDS_DPHY` nên không có đường LP: chỉ phủ HS (deskew, PRBS), không phủ ULPS, escape, thời gian LP hay T_D-TERM-EN. Loopback qua chân cần cáp/bo FMC mà dự án chưa có, và chỉ khe của bo chuyển camera giữ năm cặp trong một bank XPIO ([../camera_huins.md](../camera_huins.md) mục 3) **[CHƯA CHẮC: khả thi]**. Điều kiện xong của bước 8 nằm trong mô phỏng |
| Buồng nhiệt (khi có) | trôi VT | hiệu chỉnh ở 25 °C, `margin` ở −40 / +85 °C ([../csi2rx_review.md](../csi2rx_review.md) mục 8) |

Mọi lần kiểm trên bo của các bước chuyển chạy trên Huins (D1); bo Huins dùng chung với đội khác
nên lần chạy được xếp lịch theo chủ bo, giữa chừng chỉ mô phỏng. KV260 không có đầu ra D-PHY nên
không làm loopback được.

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
**B** = 80 Mbit/s … 2,5 Gbit/s (mục tiêu ASIC của mục 1.2). **Đã chốt đích B (D2)**: sign-off
(bước 11) chỉ khi mọi mục bắt buộc của cột B đã xong; cột A giữ để so sánh.

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
Vivado: `make -C hw/fpga/common/dv test` (`test-dphy`, `test-dphy-versal`) và PDI camera Huins
(`make pdi CARD=cam`, build trên hw-station-1: trên hw-station-2 bước PLM cần `mb-gcc` thiếu thư
viện, [../ddr_huins.md](../ddr_huins.md)) đạt timing, đủ 11 ràng buộc bus skew của
`huins_vp1902_cam.xdc` (12 từ bước 6; script build đếm) và qua kiểm tra CDC của build; trên bo: `csi2_test`
`test` trên Huins. **KV260 (quyết định D1):** không build `kv260_cam` và không chạy trên bo ở các
bước chuyển; cấu hình KV260 (2 lane, adapter UltraScale+) vẫn kiểm bằng mô phỏng trong CI, và các
bước đụng tên cell vẫn sửa `kv260_cam.xdc` cho khớp (10 ràng buộc bus skew từ review bước 5, 11 từ
bước 6, được đếm ở lần build KV260 kế tiếp); từ review bước 5 phần bộ thu của bản KV260 được đặt và đi dây ngoài
ngữ cảnh bằng `make -C hw/fpga/kv260_cam rx-ooc` (timing, bus skew, CDC; không cần block design
hay bitstream).

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
  `bow_dphy_io_xusp` chưa bao giờ được lint (bước 5: `make lint` phủ năm top của bo, kết nối của
  `tb_bow32` (`make -C sim lint`) và `bow_dphy_io_xusp`, stub UltraScale+ ở
  `hw/lint/xilinx_xusp_stubs.sv`).

Bước 1a đã đổi ba mục đầu sang cách chọn không phụ thuộc phân cấp: `set_bus_skew` chọn cell theo
đuôi tên (`get_cells -hierarchical -filter {NAME =~ */meter_gray_q_reg[*]}`; cell của FIFO, thanh
ghi, capture theo đường dưới `u_csi2rx`), danh sách CDC khớp theo đuôi đường (`make -C
hw/fpga/huins_vp1902 test-cdc`), probe gắn vào mọi `bow_dphy_align` bằng `bind`. Hai mục cuối
không đổi ở bước 1: thanh ghi (`cfg`) và cổng của `bow_csi2rx` giữ nguyên. Selector theo đuôi
tên cũng bắt cell cùng tên ở chỗ khác, nên `build.tcl` của hai bản camera kiểm cell của từng
`set_bus_skew` (`hw/fpga/common/tcl/bus_skew_checks.tcl`: mọi cell trong `u_soc/u_csi2rx`, FIFO ra
của H.264 hay `u_dphy`, mọi flop đích có đường từ nguồn, số flop nguồn bằng số flop đích), hai
nhóm cell của một phía là danh sách hai selector (Vivado cảnh báo riêng selector không khớp gì)
thay cho một OR trong filter, và danh sách CDC chỉ nhận cell D-PHY ở dưới `u_csi2rx` (flop enable
lane và bộ đồng bộ của cùng một bộ thu).

| Bước | Nội dung | File / module | Chứng minh |
|---|---|---|---|
| 0 | Đặc tả này | `docs/ip/mipi_rx_arch.md` | — |
| 1 | **1a. Bộ chọn không phụ thuộc phân cấp**, trước khi dời cell: XDC / tcl chọn cell bằng `get_cells -hierarchical -filter {NAME =~ */meter_gray_q_reg*}` (như luật BLI của `u_dphy` đã làm) và giữ phép đếm 9 / 11; danh sách duyệt CDC khớp theo đuôi đường; probe của `tb_bow_dphy_io_xusp` chuyển sang `bind` vào `bow_dphy_align`. **1b. Tách `bow_dphy_rx` bên trong `bow_csi2rx`**, cổng và thanh ghi không đổi: FSM LP, phát hiện cạnh clock, flop word, đồng bộ `arm`, aligner, `byte_rst`, nạp tap, đồng hồ đo vào module mới; RAW vẫn ở `bow_csi2_capture` (D-PHY xuất word thô) | 1a: `kv260_cam.xdc`, `huins_vp1902_cam.xdc`, `build.tcl` của hai bản build, `timing_checks_cam.tcl`, `tb_bow_dphy_io_xusp.sv`. 1b: mới `hw/ip/dphy_rx/rtl/bow_dphy_rx.sv`, `hw/ip/dphy_rx/dphy_rx.f`; chuyển `bow_dphy_lp.sv`, `bow_dphy_align.sv` sang `hw/ip/dphy_rx/rtl/`, `bow_csi2_sync.sv` sang `hw/ip/common/rtl/` với tên module mới `bow_sync_bus` (giữ tên instance `u_sync_*` và `g_bit` mà XDC dùng); đổi `bow_csi2rx.sv`, `csi2rx.f`, Makefile DV, filelist lint / FPGA / `sim` | 1a: trên RTL cũ, PDI Huins vẫn đủ 11 ràng buộc bus skew (9 của `kv260_cam` đếm ở lần build KV260 kế tiếp, D1), kiểm tra CDC không đổi, xsim chạy. 1b: tương đương với `bow_csi2rx` cũ (Synopsys Formality, D8 sửa đổi, mục 0); mọi test không đổi kết quả; LUT/FF lệch ≈ 0; `bow_dphy_rx` lint riêng được. **Xong** (bo Huins: `csi2_test` `test` PASS 17/17), kết quả dưới bảng |
| 2 | **Đảo cấp:** `bow_mipi_rx` (cổng = `bow_csi2rx` hôm nay) chứa `bow_dphy_rx` + `bow_csi2rx` (controller, cổng PPI + dải cấu hình/trạng thái PHY tạm thời từ `bow_csi2rx_regs`); lỗi lp trên PPI là xung cùng clock (FPGA: `lp_clk` = `vid_clk`, kiểm khi elaborate), có `ErrControlClk` | mới: `hw/ip/dphy_rx/rtl/bow_ppi_pkg.sv`, `hw/ip/csi2rx/rtl/bow_mipi_rx.sv`; đổi: `bow_csi2rx.sv`, `bow_dphy_rx.sv`, `bow_dphy_lp.sv` (`stop_o`), `hw/top/rtl/bow32_top.sv` (một instance, giữ tên `u_csi2rx`), `tb_bow_csi2rx.sv`, `tb_bow_dphy_io_xusp.sv`, `sim/tb/tb_bow32.sv` (đường `cfg.phy_en` mới: `dut.u_csi2rx.u_csi2rx.cfg.phy_en`), file list, `Makefile` (lint), `timing_checks_cam.tcl` (CDC-11 giữa hai khối), `hw/ip/dphy_rx/fm` (`STEP=2`) | tương đương hình thức (Formality như bước 1, D8 sửa đổi, mục 0; luật đổi tên của bước 2 trong `hw/ip/dphy_rx/fm/equiv.tcl`): `bow_mipi_rx` so với `bow_csi2rx` cũ (cổng không đổi); controller chỉ cần PPI + một dải phụ đã liệt kê; dải phụ biến mất ở bước 4–5. **Xong** (bo Huins: `csi2_test` `test` PASS 17/17), kết quả dưới bảng |
| 3 | **PPI BFM + bench controller**, hai chế độ thời gian: D-PHY Bow32 và PHY chuẩn qua wrapper cổng phẳng (mục 5.5) | mới: `hw/ip/csi2rx/dv/bow_ppi_bfm.sv`, `tb_csi2rx_ppi.sv`, `mutants_ppi.py`, `csi2_model.py gen --ppi` (lớp `Ppi`, `ppi_merge`, test `clkstop`, `gaps`, `lpmask`), wrapper cổng phẳng `hw/ip/csi2rx/rtl/bow_csi2rx_ppi_flat.sv` (không trong `csi2rx.f`); đổi: Makefile DV (`test` = `test-rx` + `test-ppi`, `run-ppi`, `mutants-ppi`; case của `test-rx` cũng chạy song song), `ci.yml` (bước `test-ppi`), `Makefile` (lint wrapper), `tools/tests/test_csi2_model.py`. Ở v1, BFM lái hoặc nối dải phụ (`band_lane_en_lp` theo `Enable` với độ trễ đồng bộ như D-PHY thật, để luật burst mất chạy như trên bo) và phát lỗi lp dạng xung ở `vid_clk_i` | hành vi controller định nghĩa ở mức PPI (khe, lệch lane, lỗi, clock dừng sớm) ở cả hai chế độ. DV nhanh hơn: **không đạt** (cùng case, cùng cách chạy song song, bench PPI không nhanh hơn bench cả bộ thu; chủ dự án quyết bỏ hay viết lại yêu cầu này, kết quả dưới bảng). **Xong** trong mô phỏng (không đổi RTL nào có sẵn: không cần Formality, PDI hay bo), kết quả dưới bảng |
| 4 | **Tách thanh ghi + driver**, không alias: driver đọc `INFO[6]` (mục 6.3); RAW sang D-PHY; GPIO PA4/PA5/PB6/PB7 thành thanh ghi (`burst_rst_en_i` = ¬`CTRL.DES_RST_DIS`); công thức `SETTLE` thống nhất (mục 4.4) | mới: `bow_dphy_rx_regs.sv`, `bow_dphy_raw.sv` (nửa RAW của `bow_csi2_capture`), `sw/common/include/bow_dphy_rx.h` (tên `DPHY_*`), `sw/common/src/bow_dphy_rx.c`; đổi: `bow_csi2rx_regs.sv`, `bow_csi2_capture.sv`, `bow_mipi_rx.sv`, `bow_csi2rx.c`, `cam_sensor.c`, `csi2_test`, top camera Huins (bỏ bốn dây GPIO), `bow32_memmap.yaml` (mô tả), `sim/tb/tb_bow32.sv`, tài liệu | firmware mới chạy trên phần cứng mới; `SETTLE` từng bit như hôm nay (22 trên KV260 ở 912 Mbit/s, 200 MHz; `0x13` trên Huins); DV `be` phủ cửa sổ D-PHY. Kỳ vọng mô phỏng đổi, ghi trong PR: `csi2_274` so `TIM0` (`rd 40008c24` = `051e0213`) thay cho `rd 4000800c`, `csi2` (KV260) thêm phép so tương tự; dòng in của `phy` đổi từ "(PB6 PB7) … (PA4 PA5)" sang `AFE_STATUS` / `DLYn`; không còn kiểm PA5 (`des_rst` luôn bật); `phy reinit` đếm xung `reinit_i` thay cho xung PA4. Hành vi đổi theo ghi chú bước 2 (mục 10): lỗi LP của lane clock khi `CLK_CONT` = 1 và lỗi của một lane ở chu kỳ nó vừa tắt không còn vào `ERR_STATUS.LP` / `CNT_MISC[23:16]` của controller; aligner thôi bị reset khi RX tắt (DV `stop`), controller vẫn đếm sự kiện của nó như trước (DV `rxoff`, sửa sau review). **Xong** trong mô phỏng và build (chờ bo Huins), kết quả dưới bảng |
| 5 | **Giao diện AFE + adapter:** `bow_dphy_rx` nói giao diện AFE (mã delay tĩnh + OWN, `des_rst` = ¬`clk_gate_en`, `pd`/`ready`, `hsrx_en`/`term_en` riêng); logic nạp tap và `des_rst` vào `bow_dphy_dly_xusp` / `bow_dphy_dly_xphy` (không primitive, chạy trong Verilator) bên trong hai adapter; bỏ `DlyVid`. Sáu nơi dùng `bow32_top` đổi trong cùng PR (hoặc giữ cổng cũ của `bow32_top` tới khi mọi nơi đã chuyển) | đổi: `bow_dphy_rx.sv`, `bow_dphy_io_xusp.sv`, `bow_dphy_io_versal.sv`, `csi2_tx_model.sv` (tên cổng AFE, núm `versal` giữ), sáu file dùng `bow32_top` (danh sách ở trên), `tb_bow_dphy_io_*.sv`, `Makefile` (lint mọi top); mới: `bow_dphy_dly_xusp.sv`, `bow_dphy_dly_xphy.sv`, stub UltraScale+ trong `hw/lint/` (`IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`, và `IBUFDS_DPHY` nếu stub Versal không khớp); XDC giữ tên instance | một RTL số cho hai họ FPGA; logic adapter vẫn trong CI; `make lint` phủ sáu top và `bow_dphy_io_xusp`; giao diện AFE hiện thực được bằng primitive; xsim mức chân + bo. **Xong** trong mô phỏng và build 2026-11-13 (chờ bo Huins): sáu nơi dùng `bow32_top` đổi trong cùng PR (cổng cũ không giữ), kết quả dưới bảng |
| 6 | **D-PHY v1.x:** `T_INIT` (sau `ready` / `REINIT`), `HS_TMO`, `ESC_TMO`, `HSRX_EARLY`, `CLK_MISS_OFF`, `RxSkewCalHS` mọi lane, `CLK_TOG_DIV`, lỗi lp của PPI dạng bộ đếm gray (lấy mẫu ở clock của controller), ULPS, shadow + APPLY, bộ đếm gray phía bus, `CLK_LOST_EN`, LATE_EOT | đổi: `bow_dphy_rx*.sv`, `bow_dphy_lp.sv`, `bow_csi2rx.sv` (lấy mẫu bộ đếm gray); mới: `tb_bow_dphy_rx.sv` (máy phát mức bit), `hw/ip/dphy_rx/dv/Makefile`, bước CI trong `.github/workflows/ci.yml`, harness mutant (mục 8.3) | từng tính năng có test + mutant; mọi bit mới có reset = hành vi hôm nay, hai ngoại lệ có chủ ý (mục 4.12). **Xong** trong mô phỏng và build 2026-11-13 (chờ bo Huins): tương đương hình thức của controller và máy LP với bước 5 (cả bộ thu không tương đương theo thiết kế), bench mới `hw/ip/dphy_rx/dv` (12 test, 35/35 mutant), kết quả dưới bảng |
| 7 | **Controller ở clock liên tục (F7):** FIFO 2 clock sau ghép lane, packet/unpack ở `csi_clk` | đổi: `bow_csi2rx.sv`, `bow_csi2_lane_merge.sv`; mới: dấu cuối burst qua FIFO | FE và ngắt không phụ thuộc byte clock (test T_CLK-POST ngắn); timing FPGA đạt |
| 8 | **Bộ máy deskew, PRBS, mô hình AFE (bản đầu)**; máy phát D-PHY và loopback trên bo là tuỳ chọn | mới: `bow_dphy_dsk.sv` (kiểm không cần byte tham chiếu, mục 4.6), `bow_dphy_prbs.sv`, `hw/ip/dphy_rx/dv/bow_dphy_afe_model.sv`; tuỳ chọn: `hw/ip/dphy_tx/rtl/bow_dphy_tx.sv`, adapter TX Versal, build loopback Huins | điều kiện xong nằm trong mô phỏng: `tb_bow_dphy_rx` với `bow_dphy_afe_model` + `csi2_tx_model` (đã gửi được burst deskew thô) phủ deskew, PRBS, ULPS, góc thời gian; loopback trên bo nếu có thì chỉ phủ HS |
| 9 | **Tổng hợp thử ASIC** (bắt đầu sớm, ngay sau bước 5) | mới: wrapper APB4 `bow_mipi_rx_apb`, `hw/asic/` (script tổng hợp, SDC, CDC) | số diện tích / timing đầu tiên (bảng 9.5); quyết định PPI 8 hay 16 bit (Q5); RTL tổng hợp được ngoài Vivado |
| 10 | **v2:** PPI 16 bit (nếu bước 9 cần), tốc độ thấp ((a)–(c) của mục 4.5), `ErrSotHS`, `LANE_MAP` / `LANE_POL`, 8 lane khi có nhu cầu; CSI-2 v2.x theo nhu cầu cảm biến | `bow_dphy_align`, `bow_dphy_lp`, `bow_dphy_rx_regs`, ghép lane, lớp packet | 2,5 Gbit/s ở node chậm; tốc độ thấp tới ~80 Mbit/s với `bow_dphy_afe_model` có `clk_act` |
| 11 | **Sign-off ASIC** | mô hình AFE RNM đủ, CDC/RDC, DFT, kế hoạch tuân thủ | mọi mục bắt buộc của đích đã chọn ở mục 9.7 |

**Kết quả bước 1 (2026-11-11)**, hai commit trên `main` `3a1e780` (1a rồi 1b), Vivado 2025.2:

- **1a, trên RTL cũ.** Mọi selector mới của hai XDC được tính cùng lúc với đường đầy đủ cũ, từng
  ràng buộc: trên netlist tổng hợp của PDI camera Huins cả 11 ràng buộc chọn đúng cùng danh sách
  cell, không cell nào ngoài `u_soc/u_csi2rx`, FIFO ra của H.264 và `u_dphy`; trên netlist
  out-of-context của `bow_csi2rx` đặt ở `u_soc/u_csi2rx` với tham số KV260 (2 lane, FIFO 256),
  cả 7 ràng buộc của bộ thu trong `kv260_cam.xdc`. KV260 không build (D1): phần `kv260_cam.xdc`
  chỉ được chứng minh bằng phép so danh sách cell này. Danh sách CDC mới cho đúng kết quả của
  danh sách cũ trên 991 dòng nghiêm trọng của `report_cdc` một bản build camera, và vẫn nhận các
  dòng đó khi cell D-PHY nằm dưới `u_dphy_rx/` (`make -C hw/fpga/huins_vp1902 test-cdc`, 47
  check). xsim `test-dphy` seed 1–3 đạt, 2 probe `bind`, mỗi probe 37 lần dò cho 37 burst; với
  `+SETTLE=14` probe báo 14 cửa sổ trong nhiễu HS-PREPARE và test hỏng, như phải thế. PDI camera
  Huins (25,5 phút): timing đạt, WNS +0,780 ns, WHS +0,014 ns (như bản build cuối của `main`),
  bus skew 11/11 (+3,893 … +5,004 ns), kiểm tra clock / CDC 0 lỗi, sơ đồ nibble đạt, không có
  `CRITICAL WARNING`.
- **1b.** Synopsys Formality X-2025.06-SP4, RTL với RTL, `bow_csi2rx` của `3a1e780` so với bản
  tách (`make -C hw/ip/dphy_rx/fm equiv`): 5 cấu hình đều *Verification SUCCEEDED*, mọi compare
  point khớp theo tên và mọi cặp khớp có tên giống hệt sau luật đổi tên `u_dphy_rx/` → rỗng
  (compare rule cho cả hai design, tắt khớp theo tên net), không điểm unmatched, failing,
  aborted hay unverified, không black box (RAM đọc thành thanh ghi), user match, constant hay
  don't-verify: KV260 17 197 point (75 cổng, 17 122 flop), Huins (4 lane, FIFO 512, `DlyVid` = 1)
  30 397 (97, 30 300), 1 lane 16 352 (64, 16 288), `HasPhy` = 0 và mô phỏng hệ thống 17 197 mỗi
  cấu hình. Điểm không so (thanh ghi hằng hay không được đọc theo tham số, ví dụ `ce_q` / `seen_q`
  của máy LP data lane, `ev_deskew_o` của lane 1–3, `dly_req_q` khi `DlyVid` = 0) là cùng một
  cặp tên ở hai phía. Hai mutant chức năng bị bắt (đảo điều kiện `CLK_FORCE` của burst mất ở mức
  LP: 1 point hỏng; đổi chỗ SETTLE và CLK_SETTLE: 16). DV `csi2rx` 105/105, 104 case cho
  `out.txt`, `regs.txt`, `sim.log` giống từng byte với RTL cũ; `make test` 15/15, log của `camera`,
  `csi2`, `camera274`, `csi2_274`, `video274` giống RTL cũ (cả thời điểm và số chu kỳ); ISP 12/12,
  H.264 8/8; `make lint` (thêm `bow_dphy_rx` một mình: 1, 2, 4 lane, `DlyVid` 0 / 1, từ chối 3
  lane); `make test-tools` 196 test; xsim `test-dphy` seed 1–3 đạt với cùng số burst (37) và
  số byte clock như ở 1a, probe `bind` ở chỗ mới `u_rx.u_dphy_rx.g_align[l]` (với `+SETTLE=14`
  vẫn báo 14 cửa sổ trong nhiễu), `test-dphy-versal` 24/24 cấu hình. PDI camera Huins (25,5 phút):
  timing đạt, WNS +0,443 ns (đường recovery của reset trong H.264, ngoài bộ thu), WHS +0,013 ns,
  bus skew 11/11 (+3,966 … +5,031 ns); cùng XDC chọn đúng các cell của bản 1a, 120 cell giờ dưới
  `u_dphy_rx/` (đồng hồ đo, yêu cầu nạp tap + tap, đọc lại tap), kiểm cả trên netlist
  out-of-context với tham số KV260; kiểm tra clock / CDC 0 lỗi (4 dòng CDC-11 tới
  `u_dphy_rx/u_sync_vcfg` và cổng byte clock từ `u_dphy_rx/u_lp_clk` khớp danh sách đã duyệt),
  sơ đồ nibble đạt, không có `CRITICAL WARNING`. `bow_csi2rx` sau route 2547 LUT / 2967 FF so
  với 2536 / 2967 ở 1a (`bow_dphy_rx` 827 / 846); cả thiết kế sau tổng hợp 39 842 LUT / 24 967
  thanh ghi so với 39 835 / 24 967, sau route +53 LUT / +36 FF do `phys_opt_design` của lần place
  này (34 thanh ghi DSP chuyển ra fabric, 2 cell nhân bản thêm), ngoài bộ thu.
- **Sửa sau review** (commit thứ ba; RTL chỉ đổi một chú thích của `bow_csi2rx`). Formality: ngoài
  các điều kiện trên, mọi cặp khớp phải có tên giống hệt sau luật đổi tên (`names.rpt`) và đều
  khớp theo tên, khớp theo tên net bị tắt, luật `u_dphy_rx/` → rỗng áp cho cả hai design nên `REF`
  là commit từ bước 1 trở đi cũng được. Với `3a1e780`: 5/5 đạt, cùng số compare point như trên,
  mọi cặp cùng tên (KV260 17 307 cặp, 532 qua luật đổi tên; Huins 30 540, 849; 1 lane 16 446,
  365); với `REF=a7b2a03` (bản 1b): 5/5. Hai mutant mà Formality vẫn *Verification SUCCEEDED* nay
  bị bắt (2 cặp khác tên mỗi mutant): `u_sync_tog` viết lại bằng hai flop thường (mất
  `ASYNC_REG`), và chỉ đổi tên instance `u_sync_tog`. Danh sách CDC: `test-cdc` 136 check; trên
  991 dòng nghiêm trọng của `report_cdc` của bản build 1a và của bản 1b, kết luận giống danh sách
  của `main` và của 1b. `bus_skew_checks.tcl`: trên netlist sau route của bản 1b, 11 ràng buộc,
  không lỗi, và ba ràng buộc hỏng thêm vào đều bị bắt (thiếu nhóm nguồn, thiếu nhóm đích, thêm
  một flop ngoài bộ thu); trên netlist out-of-context của `bow_csi2rx` đặt ở `u_soc/u_csi2rx`:
  tham số KV260 7 ràng buộc, Huins 8, không lỗi; XDC không nhận `concat` (Designutils 20-1307),
  nhận `list`. PDI camera Huins (25,8 phút): timing đạt, WNS +0,443 ns, WHS +0,013 ns, WPWS
  +0,231 ns, bus skew 11/11 (+3,966 … +5,031 ns), `INFO: bus skew cells: 0 problems in 11
  constraints`, kiểm tra clock / CDC 0 lỗi, không có `CRITICAL WARNING`, 39 348 LUT / 24 974 FF
  (bằng bản 1b). DV `csi2rx` 105/105 (dòng kết quả giống bản 1b); `make test` 15/15, log của
  `camera`, `csi2`, `camera274`, `csi2_274`, `video274` và luồng H.264 của `video274` giống bản
  chạy trên RTL cũ; `make lint`, `make test-tools` 197 test, `make sw`, `make gen-check`.
- **Trên bo Huins** (2026-11-11, chung lần chạy với bước 2, PDI của bước 2 vốn chứa bước 1):
  `csi2_test` `test` PASS 17/17, xem kết quả bước 2. KV260 không build và không chạy trên bo
  (D1). PR #21 gộp ngày 2026-11-11 sau khi chủ dự án duyệt D8 sửa đổi (mục 0).

**Bước 2: PPI, dải phụ tạm thời và hai chỗ nối của bước 1.** `bow32_top` có một instance
`bow_mipi_rx` tên `u_csi2rx` (cổng và tham số như `bow_csi2rx` trước bước 2); bên trong là
`bow_dphy_rx` (`u_csi2rx/u_dphy_rx`, đúng đường của bước 1) và controller `bow_csi2rx`
(`u_csi2rx/u_csi2rx`, thấp hơn một cấp). Nhờ vậy selector theo đuôi tên của hai XDC
(`*/u_csi2rx/u_fifo/...`, `*/u_csi2rx/u_regs/...`, `*/u_sync_meter/...`), tiền tố
`u_soc/u_csi2rx/` của `bus_skew_checks.tcl` và probe `bind` vẫn khớp mà không sửa; danh sách CDC
đổi luật CDC-11 (flop enable lane ở controller, bộ đồng bộ ở D-PHY): đường được cắt ở instance
`u_csi2rx` đầu tiên (bộ thu), phần dưới phải là một chỗ đã biết của cell (`u_csi2rx/u_regs`
hay `u_regs`; `u_dphy_rx/` hay ngay dưới bộ thu), hai đầu cùng một bộ thu. PPI v1 và ánh xạ tín
hiệu: mục 5.3. Dải phụ tạm thời (cổng `band_*` của `bow_dphy_rx` và `bow_csi2rx`, mỗi tín hiệu có
chú thích bước bỏ nó):

| Dải phụ | Hướng | Miền | Vì sao chưa là PPI | Bỏ ở |
|---|---|---|---|---|
| `lp_rst_n` (= `vrst_n`), `brst_n`, `drst_n` | controller → D-PHY | đã đồng bộ: video (`lp_clk`), byte | bộ đồng bộ reset dùng chung, không nhân đôi flop; `drst_n` = `rst_src_n & rx_on` reset aligner | bước 4: reset của chính D-PHY (mục 4.11) |
| `rst_src_n` | controller → D-PHY | bất đồng bộ | nguồn của bộ đồng bộ reset ISERDES (`u_iserdes_rst`, `byte_rst_o`) | bước 5 (`des_rst` của giao diện AFE) |
| `clk_force` | controller → D-PHY | CPU | `CTRL.CLK_FORCE` của `bow_csi2rx_regs` | bước 4 (`CTRL.CLK_CONT` của D-PHY) |
| `settle`, `lp_filter`, `clk_settle`, `clk_miss` | controller → D-PHY | CPU | `PHY_CFG` | bước 4 (`TIM0`) |
| `dly`, `dly_req` | controller → D-PHY | CPU | `DLYn`: tap và bộ đếm ghi (gray) | bước 4 (`DLYn` của D-PHY); giao thức nạp sang adapter ở bước 5 |
| `lp_sys`, `hs_en_sys`, `ce_sys`, `phy_rdy_sys` | D-PHY → controller | CPU | `STATUS` LP / HS / CE / PHY_RDY | bước 4 (`LANE_LP`, `LANE_HS`, `AFE_STATUS`) |
| `meter_sys`, `dly_sys` | D-PHY → controller | CPU | `BYTECLK` (gray), `DLYn[24:16]` | bước 4 |
| `ev_hs` (1 + `Lanes` bit) | D-PHY → controller | lp | xung vào HS cho `CNT_BURST*`, `CNT_MISC[15:0]` | bước 4 (`CNT_BURSTn`, `CNT_CLK`) |
| `lane_en_lp` (`Lanes` bit), `clk_force_lp` | D-PHY → controller | lp | đầu ra của `u_sync_vcfg`: controller che `ErrControl*` đúng như hôm nay | bước 4 (xem dưới) |
| `raw_data`, `raw_valid` | D-PHY → controller | byte | flop word cho RAW (vẫn ở `bow_csi2_capture`; RAW bắt đầu ở cạnh lên `RxActiveHS[0]` của PPI) | bước 4 (`bow_dphy_raw`) |

Hai chỗ nối mà review bước 1 ghi lại (F7) được đặt lại như sau, vẫn chứng minh bằng tương đương:

- **Đánh dấu burst mất.** `ev_lp_loss_o` bị bỏ. D-PHY xuất `ErrControl[l]` / `ErrControlClk`
  là xung `ev_err_o` của FSM ở bit 0, không che; controller tính `lpl_ev` = OR của
  `ErrControl[l][0]` & `lane_en_lp[l]` và `ErrControlClk[0]` & ¬`clk_force_lp`. Phép che dùng
  bản đồng bộ của D-PHY (dải phụ) vì nó không thừa: xung lỗi ra một chu kỳ sau khi FSM thấy
  enable, nên ở chu kỳ enable đã đồng bộ vừa xuống thì phép che có tác dụng; một bộ đồng bộ thứ
  hai trong controller là flop mới và không tương đương. `ERR_STATUS.LP`, `CNT_MISC[23:16]` đếm
  `ErrControl*` không che, như hôm nay. Bước 4: `CLK_FORCE` thành `CTRL.CLK_CONT` của D-PHY, nên
  D-PHY che `ErrControlClk` (mục 5.3) và `ErrControl[l]` theo `Enable` của nó, controller chỉ còn
  phép OR và dải `lane_en_lp` / `clk_force_lp` biến mất. Hành vi đổi ở bước 4 phải ghi trong PR:
  lỗi LP của lane clock khi `CLK_CONT` = 1 và lỗi của lane ở chu kỳ nó vừa tắt không còn vào
  `ERR_STATUS.LP` của controller (bộ đếm `CNT_LPERR` và cờ `ERR_STATUS.CONTROL` của D-PHY vẫn
  thấy chúng).
- **Reset của aligner.** `drst_n` (`u_drst` của controller, `rst_src_n & rx_on`) đi qua dải phụ
  (`band_drst_n`). Bước 4 thay bằng `byte_rst_n` của chính D-PHY (mục 4.11, = `rst_ni`): aligner
  thôi bị reset khi RX tắt; PR của bước 4 ghi rõ và DV `stop` kiểm.

Lỗi lp trên PPI v1 là xung của `lp_clk`, lấy mẫu ở `vid_clk_i` của controller: `bow_mipi_rx` cho
`lp_clk_i` của D-PHY chạy bằng `vid_clk_i` và đặt `PpiLpClkHz` = `PhyClkHz` cho controller;
controller báo lỗi elaborate khi hai tần số khác nhau (`make lint` có case âm).

**Kết quả bước 2 (2026-11-11)**, trên `35ef151` (cuối bước 1), Vivado 2025.2, Synopsys Formality
X-2025.06-SP4:

- **Tương đương.** `make -C hw/ip/dphy_rx/fm equiv STEP=2`: `bow_mipi_rx` so với `bow_csi2rx` của
  `3a1e780` (trước bước 1) và của `35ef151` (cuối bước 1), 5 cấu hình mỗi bên, đều *Verification
  SUCCEEDED*; mọi compare point khớp theo tên; không unmatched, failing, aborted hay unverified,
  không black box (RAM đọc thành thanh ghi), user match, constant hay don't-verify. Sau review
  (F1), luật đổi tên của các bước giữa reference và implementation chỉ áp lên **implementation**
  (bước 2: `u_csi2rx/` → rỗng; bước 1: `u_dphy_rx/` → rỗng), nên reference giữ cấu trúc của nó;
  mọi cặp khớp, kể cả flop không được đọc, phải mang đúng tên của reference, và mọi cell phải nằm
  cùng khối ở hai phía (`partition.rpt`: với reference từ bước 1 trở đi, khối D-PHY `u_dphy_rx/`
  và khối controller; không cell nào nằm ngay trong `bow_mipi_rx`). KV260, `HasPhy` = 0 và mô
  phỏng 17 197 compare point (75 cổng, 17 122 flop; 17 343 cặp khớp kể cả 36 cặp không được đọc),
  Huins 30 397 (97, 30 300; 30 578 cặp), 1 lane 16 352 (64, 16 288; 16 481 cặp): đúng số của bước
  1. So với `35ef151`, từng cặp nằm đúng khối: KV260 16 611 controller / 538 D-PHY / 194 cổng,
  Huins 29 461 / 861 / 256, 1 lane 15 950 / 368 / 163, 0 cặp đổi khối. Đối chứng của review (MA:
  bộ đồng bộ `phy_rdy` dời từ D-PHY sang controller) qua được luật cũ với cùng số, nay hỏng: 2 cặp
  khác tên và 2 cặp ra khỏi khối của reference. Đối chứng âm (KV260): đảo phép che `CLK_FORCE` của `ErrControlClk`
  trong controller (một bit) → 1 point hỏng (`lpl_req_q`); xung `ErrControl` của data lane đặt ở
  bit 1 thay cho bit 0 trên PPI (một bit) → 3 (`lpl_req_q`, hai bit `vev_pend_q`); aligner nhận
  `brst_n` thay cho `drst_n` qua dải phụ → 20; đổi tên một instance trong controller → vẫn
  *Verification SUCCEEDED* nhưng run hỏng vì 2 cặp khác tên.
- **Mô phỏng** (trên commit RTL). DV `csi2rx` 105/105: `cfg`, `stim`, `out`, `regs` của 104 case
  giống từng byte với bước 1, `sim.log` chỉ khác số dòng của `$finish` (testbench thêm một dòng chú
  thích); `make test` 15/15, log của cả 15 test (trong đó `camera`, `csi2`, `camera274`, `csi2_274`,
  `video274`) và luồng H.264 của `video274` giống bước 1, kể cả số chu kỳ (15 474 542 / 9 362 645 /
  20 660 123 / 21 226 235 / 13 873 312); ISP 12/12, H.264 8/8; xsim `test-dphy` seed 1–3 đạt (37
  burst; 2977 / 2985 / 2967 byte clock như bước 1; với `+SETTLE=14` probe
  `u_rx.u_dphy_rx.g_align[l]` vẫn báo 14 cửa sổ trong nhiễu), `test-dphy-versal` 24/24.
- **Kiểm tra khác.** `make lint` (thêm `bow_mipi_rx` và controller một mình, 4 cấu hình mỗi
  module, case âm `PpiLpClkHz` ≠ `PhyClkHz`); `make test-tools` 197 test (1 bỏ qua: PyAV);
  `make sw`, `make gen-check`; `test-cdc` 204 check (danh sách của bước 1 hỏng 15 trong số đó: 12
  dòng CDC-11 của cấu trúc bước 2 bị từ chối, 3 chỗ quá rộng); `test-plan` 16. Trên 991 dòng
  nghiêm trọng của `report_cdc` bản build bước 1 và 991 dòng của bản build bước 2, danh sách mới
  cho cùng kết luận với danh sách của bước 1 (đường của bản bước 2 đã bỏ cấp controller); với
  đường thật của bản bước 2, danh sách của bước 1 từ chối 4 dòng CDC-11, lý do phải đổi luật.
- **PDI camera Huins** (từ đúng cây của commit RTL, 26,1 phút; bản build trước đó từ một snapshot
  chỉ khác chú thích cho cùng mọi số dưới đây): timing đạt, WNS +0,535 ns (đường `clk_vid` trong H.264, ngoài bộ thu), WHS +0,015 ns, WPWS
  +0,231 ns; byte clock +1,821 / +0,040 ns; bus skew 11/11 (+3,878 … +4,948 ns), `INFO: bus skew
  cells: 0 problems in 11 constraints`; kiểm tra clock / CDC 0 lỗi (4 dòng CDC-11 từ
  `u_csi2rx/u_csi2rx/u_regs` tới `u_csi2rx/u_dphy_rx/u_sync_vcfg`, cổng byte clock từ
  `u_csi2rx/u_dphy_rx/u_lp_clk`, đều thuộc danh sách đã duyệt), sơ đồ nibble đạt, không có
  `CRITICAL WARNING`. Cả thiết kế sau tổng hợp 39 844 LUT / 24 967 thanh ghi (bước 1: 39 842 /
  24 967, 1a: 39 835 / 24 967); sau route 39 393 LUT / 25 171 FF, so với 39 348 / 24 974 ở bước 1
  (+45 / +197) và 39 295 / 24 938 ở 1a (+98 / +233). Phần chênh sau route nằm trong H.264
  (`phys_opt_design` của lần place này: 72 thanh ghi DSP chuyển ra fabric so với 34, 29 cell nhân
  bản so với 4); bộ thu `bow_mipi_rx` 2545 LUT / 2967 FF so với 2547 / 2967 của `bow_csi2rx` ở
  bước 1 (`bow_dphy_rx` 819 / 846, controller 1728 / 2121).
- **KV260** (không build, D1): netlist out-of-context của bộ thu đặt ở `u_soc/u_csi2rx`, bản bước 1
  và bản bước 2, tham số KV260 và Huins: mọi `set_bus_skew` của bộ thu trong `kv260_cam.xdc` (7
  ràng buộc, 9/9/20/4/4/4/4 cell mỗi phía) và `huins_vp1902_cam.xdc` (8: 10/10/20/4/4/4/4/44) chọn
  đúng cùng cell sau khi bỏ cấp controller, `bow32_bus_skew_checks` 0 lỗi.
- **Trên bo Huins** (2026-11-11, PDI của commit sửa review bước 2, firmware cùng commit): nạp qua
  JTAG, `camera: IMX274 found`, `phy`: `PHY_RDY` 1, trễ BISC 122/75/118/130 (như các lần trước);
  `start` ở trễ BISC báo lỗi link như dự kiến (mục 7.1); `cal 8`: tap 300/184/260/228, eye
  352/360/352/352 (trùng lần chạy 1–3); `test` **PASS 17/17**: 1080p30 và 720p60, lề ±88–90 tap
  mỗi lane, 0 lỗi trong 60 frame mỗi điểm (BER < 1,0×10^-8 ở 1080p), byte clock 180 078 kHz,
  không lỗi `extra`. KV260 không build và không chạy trên bo (D1); duyệt lệch D8 (mục 0).

**Bước 3: bench controller ở PPI.** `tb_csi2rx_ppi` (`hw/ip/csi2rx/dv`) chạy controller một mình
với `bow_ppi_bfm` làm PHY, ở hai chế độ thời gian (mục 5.5). Chế độ `bow`: DUT là `bow_csi2rx` với
PPI v1, dải phụ do BFM lái như D-PHY Bow32 lái nó (`band_lane_en_lp` / `band_clk_force_lp` =
`Enable` / `CTRL.CLK_FORCE` qua 2 flop `vid_clk_i` reset bằng `band_lp_rst_no` như `u_sync_vcfg`,
nên lỗi LP ở chu kỳ cuối trước khi mặt nạ của lane áp dụng đánh dấu burst mất, ở chu kỳ đầu sau
thì không; `band_ev_hs` xung ở mỗi HS entry; word thô của RAW với valid chung mọi lane (FIFO của
XPHY đọc cùng nhịp), thấp ở chu kỳ mà lane 0 có khe 2 chu kỳ sau: word khác trước cạnh lên
`RxActiveHS`, rồi `00`, `B8` (3 chu kỳ trước `RxSyncHS` khi không khe nào làm trễ) và byte của lane
không khe, mỗi chu kỳ có valid một word; `STATUS` LP-11, HS 0, CE = `RxClkActiveHS` qua 2
flop `clk_i`, `PHY_RDY` 1; `BYTECLK`, `DLYn[24:16]` 0). Chế độ `std`: DUT là wrapper cổng phẳng
`bow_csi2rx_ppi_flat`, dải phụ do wrapper lái hay nối hằng (mục 5.5). Một model Verilator mỗi
`Lanes` chứa cả hai DUT; DUT không dùng không có clock. Kích thích và kỳ vọng từ cùng mô hình bộ
thu (`csi2_model.py`, mục 8.3): mỗi item TX của test case được mô hình xử lý như ở cả bộ thu, rồi
dựng lại ở PPI (`gen --ppi`): sự kiện của máy LP thành xung lp (`ppev`), byte của mỗi lane từ
`lane_receive` (cả khoá muộn khi sync hỏng) với chu kỳ của `RxActiveHS`, `RxSyncHS`, khe,
`ErrSotSyncHS`, `RxSkewCalHS`, `ErrSotHS` và lần chạy byte clock (`ppl`, `ppb`). Mô hình theo dải
phụ của chế độ (`cfg ppi`): `std` không đếm HS entry, không có lỗi LP của lane clock, RAW không
xong. Phần dựng giữ cho kỳ vọng đúng: trail mỗi lane trong giới hạn của mô hình, mỗi lane đủ byte
cho word cuối, luật ghép lane (khe, FIFO 8 byte) kiểm trên đúng chu kỳ đã dựng (`ppi_merge`; dựng
lại nếu khác quyết định của mô hình), byte clock còn ≥ 10 cạnh sau cạnh mang byte cuối của packet
khi mô hình coi thời điểm sự kiện là chính xác (lề 2 trên mức đo được, dưới).

**Kết quả bước 3 (2026-11-12)**, trên `320f2ec`, Verilator 5.020 (số sau các sửa của review,
bullet cuối):

- **Bench.** `make -C hw/ip/csi2rx/dv test-ppi`: 167/167 case đạt, cả hai chế độ. Mỗi chế độ 32
  random (seed 1–4 × {2 lane, 2 lane + lỗi, 1 lane + lỗi, 1 trên 2 + lỗi, 4 lane, 4 lane + lỗi, 2
  trên 4 + lỗi, 1 trên 4 + lỗi}, xen kẽ RAW8 và clock liên tục) và directed `cmd`, `ovf`, `stop`,
  `skew`, `deskew`, `extra`, `loss`, `ovf2`, `ovf8`, `be`, `clkstop` trên 2 và 4 lane, một phần với
  1 lane, 1 trên 2, 2 trên 4, clock liên tục; `lpmask` trên 1, 2, 4 lane (cạnh mặt nạ chỉ ở `bow`);
  `gaps` (chỉ `bow`) trên 1, 2, 4 lane. Tổng 173 389 pixel, 15 801 lần đọc thanh ghi, 993 frame.
  `SEEDS="1 … 40"`: 743/743. Phủ (dòng `bow_ppi_bfm:` của `sim.log`, cộng 167 case): `bow` 4296
  burst; byte clock dừng đúng 4 cạnh sau cạnh `RxActiveHS` cuối xuống ở 1217 burst, sớm hơn ở 353
  (290 trong số đó trước khi nó xuống); `RxActiveHS` lên trước `RxSyncHS` 9535 lần (lane × burst);
  26 173 chu kỳ khe trên 384 331 byte; 8836 byte ra khi `RxActiveHS` đã xuống; 175 `ErrSotSyncHS`
  sau khi xuống; 58 xung `RxSkewCalHS`; 13 385 HS entry và 73 lỗi LP dạng xung `vid_clk_i`; 5 + 5
  lỗi LP ở chu kỳ cuối trước / đầu sau khi mặt nạ áp dụng; 11 919 chu kỳ không có word RAW. `std`
  4096 burst; 111 dừng đúng 4 cạnh sau, 352 sớm hơn (170 trước khi xuống); `RxActiveHS` lên cùng
  `RxSyncHS` 9078 lần, 125 lần lane không có `RxActiveHS` (chỉ `ErrSotSyncHS` hay xung
  `RxSkewCalHS`); 170 `ErrSotSyncHS` sớm; `RxSkewCalHS` 33 xung, 25 mức; 913 `ErrSotHS`; 53 lỗi LP
  ở clock lp 25 MHz của PHY.
- **Mutant** (`make -C hw/ip/csi2rx/dv mutants-ppi`, 24 case mỗi mutant, `--every`: case và chế độ
  nào bắt): 20/20 chết. Controller: giới hạn lệch lane 6 → 5 (kiểm tràn trước word đầu coi FIFO 7
  byte là đầy; các case `skew` ở cả hai chế độ), FIFO ghép lane 16 byte (cả hai), push không xét
  `RxValidHS` (chỉ `bow`: khe), burst kết thúc khi một lane xuống, bắt đầu khi mọi lane lên, CRC 1
  byte (cả hai), không cờ lỗi CRC khi word cuối của packet có byte payload (`loss` 4 lane, cả hai),
  không báo EXTRA (`clkstop`, cả hai),
  bỏ mặt nạ enable lane của luật burst mất (`lpmask` 2 lane, cả hai), bỏ mặt nạ `CLK_FORCE` (chỉ
  `bow`: lane clock không có `ErrControlClk` ở `std`), tắt luật burst mất, burst mất đang chờ bị
  xoá ở cuối burst thay vì ở packet sau (`loss`, cả hai), lỗi sync không đánh dấu dòng sau, đếm
  deskew ở lane cuối (cả hai), RAW nhận cả word không valid, RAW bắt đầu ở cạnh lên của lane bất kỳ
  (chỉ `bow gaps`). Wrapper: bỏ trễ miền byte, bỏ giữ `RxActiveHS`, `RxSkewCalHS` mức, mặt nạ enable
  lane nối 1 (chỉ `std`). Mutant đếm deskew ở lane cuối lúc đầu sống: test `deskew` chỉ đọc
  `CNT_EXT` sau cặp burst deskew một phần liền nhau (lane 0 riêng, rồi mọi lane trừ lane 0), lỗi
  hai chiều triệt tiêu; cuối test nay có thêm hai burst đó, mỗi burst một mình với `CNT_EXT` đọc
  sau nó (cặp liền nhau giữ nguyên như `main`). Không thành mutant: `Enable` vào mặt nạ của wrapper
  không qua 2 flop (cấu trúc CDC, mục 5.5: không kích thích nào nhắm được 2 chu kỳ đó; sống, như
  dự kiến).
- **Hồ sơ PPI** (mục 5.5, sửa theo kết quả). Chế độ `std` chỉ sạch sau khi wrapper làm ba việc mà
  bảng cũ ghi là controller tự chịu được: controller v1 mất burst khi `RxActiveHS` lên cùng chu kỳ
  `RxSyncHS` (ghép lane chỉ nhận byte từ chu kỳ sau cạnh lên), mất word cuối khi `RxActiveHS` xuống
  ngay sau byte cuối, và đếm `RxSkewCalHS` dạng mức mỗi chu kỳ. Ba điều kiện bảng cũ không ghi:
  mỗi lane đưa byte tới hết word cuối (trail), các lane lệch nhau không quá FIFO 8 byte sau khi
  bắt đầu (byte vào FIFO đầy mất, không báo), `RxActiveHS` của các lane chồng nhau (nếu không: hai
  burst, SKEW hai lần). Byte clock dừng sớm (cả trước khi `RxActiveHS` xuống) không làm sai dữ
  liệu; thời điểm FS / dòng đúng khi clock còn ≥ 8 cạnh sau cạnh mang byte cuối của packet (đo
  bằng cách giảm lề của mô hình: 7 cạnh thì `FRAME_TIME` / `LINE_TIME` sai ở 7/12 case `std`, 6
  cạnh 10/12; 8 và 9 cạnh 0/12).
- **Thời gian: "DV nhanh hơn" không đạt.** Trên cùng case, bench PPI không nhanh hơn bench cả bộ
  thu: 26 case như nhau (random 1, 2 lane có và không có lỗi, seed 1–4, và 10 test directed trên 2
  lane), tuần tự, tốn 5,7 s ở mỗi chế độ so với 5,2 s qua cả bộ thu (đo của review: 30 case gồm cả
  4 lane, 5,6 s so với 5,0 s; sinh 2,4 / 2,0 s, mô phỏng 1,3–1,5 / 1,2 s, kiểm 1,8 / 1,8 s). Mô
  phỏng controller một mình không rẻ hơn mô phỏng cả bộ thu (máy phát mức bit và D-PHY số rẻ trong
  Verilator); thời gian nằm ở mô hình Python, sinh (phần dựng PPI thêm vào đó) rồi `check` chạy lại
  mô hình trên item TX; bớt phần Python (ví dụ để `gen` ghi kỳ vọng cho `check`) làm cả hai bench
  nhanh như nhau, không làm bench PPI nhanh hơn. Cả hai bench nay chạy case song song như nhau
  (`PJOBS`, mặc định số CPU, như bench DDR / HyperRAM): `test-rx` 105 case 2,6 / 6,6 / 25,7 s với
  24 / 4 / 1 job, `test-ppi` 167 case 3,0 / 9,6 / 37,8 s. Yêu cầu "DV nhanh hơn" của bước 3 vì vậy
  chưa đạt và chờ chủ dự án quyết: bỏ, hay viết lại (ví dụ "chạy được nhiều seed trong thời gian
  CI", hai bench đều đạt).
- **Kiểm tra khác.** `make -C hw/ip/csi2rx/dv test` 272/272 (`test-rx` 105, `test-ppi` 167);
  `test-rx` với `SEEDS="1 … 12"` 193/193; `make lint` (thêm wrapper: 2, 1, 4 lane, clock video 50
  MHz); `make test-tools` 202 test (1 bỏ qua: PyAV; 41 của mô hình CSI-2, 5 mới cho PPI);
  `make gen-check`; `make test` 15/15, log giống hệt `main` (cả số chu kỳ; chạy trên commit đầu
  của bước 3, các sửa sau review không đụng RTL, `sim/` hay file nào `sim/` dùng). Không đổi RTL nào
  có sẵn (wrapper là file mới, không nằm trong `csi2rx.f` hay bản build nào): không cần Formality,
  PDI hay chạy bo (D1).
- **Sửa sau review** (commit thứ hai, không đổi RTL). Mặt nạ enable lane của wrapper chưa có test
  nào chạm tới (nối nó bằng 1 vẫn qua mọi case): `lpmask` chạy cả ở `std` với các case đã ổn định
  (lỗi của lane đã tắt chỉ đếm, của lane đang bật đánh dấu burst mất), và `lperr` của mô hình xét
  enable lane (`Receiver.lp_loss`). Bốn mutant của controller mà review thấy sống nay chết: dòng
  lỗi CRC 4 / 8 / 20 / 24 pixel (WC mod 4 = 1, 2) và một burst mất ở mức LP đi qua burst deskew
  trên mọi lane được thêm vào cuối `loss` (hai mutant này chết cả ở `test-rx`: CRC ở `loss` 4 lane,
  burst mất ở cả 7 case `loss`); BFM cho word thô của RAW khe theo khe của lane 0 (valid
  thấp, word khác) và word khác trước cạnh lên `RxActiveHS`, `gaps` bắt RAW một dòng ở khe 0,75,
  burst đó có lane 0 lên sau một lane khác, `check` kiểm word đầu của lane 0 là `00` (chỉ chế độ
  `bow`). `deskew` giữ cặp burst deskew một phần liền nhau như `main` (lần đọc xen giữa của commit
  đầu thêm cả một burst chỉ có clock và một `wait` giữa hai burst đó) và thêm hai burst đó riêng ở
  cuối. Kích thích của bench cả bộ thu: 94 trong 104 case giống từng byte với `main`; 3 case
  `deskew` và 7 case `loss` chỉ thêm một khối trước lần đọc cuối. `test-rx` chạy song song như
  `test-ppi`; mỗi bản build model chạy lại Verilator một lần nếu nó hỏng (Verilator 5.020 đôi khi
  abort lúc thoát sau một bản build tốt, "attempted to destroy locked Thread Pool", gặp ở lần
  `build-ppi` đầu của phần sửa) và `touch` binary (Verilator không ghi lại model mà C++ không đổi,
  binary cũ hơn nguồn làm mọi case chạy song song cùng build lại một lúc). `mutants_ppi.py` gọi
  Verilator không kèm `PYTHONHOME` / `PYTHONPATH` của trình Python đang chạy (bản build một file của
  một mutant nhỏ chạy `verilator_includer` bằng python3 của hệ thống); mutant tắt EXTRA, bản build
  một file như thế với 1 lane, nay build được và vào danh sách. Mô tả khe của `gaps` sửa
  thành tham số 0,4 / 0,75 (≈ 20 % / 38 % chu kỳ); mục 5.5 ghi bốn điều phần dựng PHY chuẩn mượn
  của D-PHY Bow32, điều kiện SKEW ở lệch ≥ 7 và giới hạn mốc thời gian ở 80 Mbit/s.

**Bước 4: thanh ghi D-PHY riêng.** `bow_dphy_rx` có thanh ghi riêng (`bow_dphy_rx_regs`, miền bus,
`u_dphy_rx/u_regs`) ở offset `0xC00` của cửa sổ `CSI2RX`: tập con v1 của mục 4.10
([dphy_rx.md](dphy_rx.md)). `bow_mipi_rx` chia cửa sổ (`addr[11:10]` = 3 → D-PHY; hai khối grant
ngay và trả lời một chu kỳ sau, nên phản hồi lấy từ khối có `rvalid`) và nối `irq_o` của D-PHY vào
`IRQ_STATUS[5]` của controller. RAW sang D-PHY (`bow_dphy_raw`, `u_dphy_rx/u_raw`: nửa RAW của
`bow_csi2_capture`, cùng flop word và cùng `arm` của lane 0), D-PHY đồng bộ reset của mình
(`u_lrst` miền lp, `u_brst` miền byte, từ `rst_ni & lp_rst_ni`), sự kiện HS entry / lỗi LP về bus
cho bộ đếm của nó (một `bow_cdc_pulse` mỗi lane và loại, như controller làm trước đó). Dải phụ bỏ
hẳn: D-PHY che `ErrControl[l]` theo `lane_en` (enable đã đồng bộ) và `ErrControlClk` khi
`CLK_CONT` (đã đồng bộ), đúng hai mặt nạ controller dùng ở bước 2–3, cùng chu kỳ, nên luật đánh
dấu burst mất không đổi; controller chỉ còn OR của chúng. Aligner dùng `u_brst` của D-PHY nên
không còn bị reset khi RX tắt; controller chỉ đếm sự kiện của nó (`ErrSotSyncHS`, `RxSkewCalHS`)
cho burst nó thấy bắt đầu (`stale_q` mỗi lane, sửa sau review), như ở bước 1–3. Controller: thanh
ghi PHY cũ đọc 0 (không alias), `INFO[6]` = 1 (tham số `DphyWin`; wrapper cổng phẳng: 0), `INFO[5]` = 0,
`CNT_MISC` chỉ còn [31:24], `ERR_STATUS.LP` = OR các lỗi trên PPI. `DLYn.PEND` = OWN ∧ Q ≠ CODE
(mục 4.10, v1) không cần bus ack mới: số ràng buộc bus skew giữ 9 / 11, cell mới chỉ là chỗ ở mới
của req / ack RAW và yêu cầu / mã `DLYn`. Top camera Huins: `reinit_i` ← `reinit_o` (`CMD.REINIT`,
xung 32 chu kỳ bus), `burst_rst_en_i` ← `burst_rst_en_o` (¬`CTRL.DES_RST_DIS`, 1 từ reset),
`phy_status_o` → `AFE_STATUS[15:8]`, LED10 ← `AFE_STATUS.READY`; PA4…PA6 không ra chân, PB6 /
PB7 đọc 0. Driver `bow_dphy_rx` (mục 6.4, v1), `bow_csi2rx` từ chối bitstream trước bước 4.
Danh sách duyệt CDC không đổi (CDC-11 vẫn từ `u_csi2rx/u_regs/lane_en_q` của controller tới
`u_dphy_rx/u_sync_vcfg`).

**Kết quả bước 4 (2026-11-12)**, trên `21e16d6` (bước 3 gộp `main` `e56793f`), Verilator 5.020,
Vivado 2025.2. Commit: `a485e82` (RTL, phần mềm, mô phỏng / DV; ba commit đầu `0c4331c`, `e2f64d0`,
`281f53e` gộp làm một sau review để mỗi commit tự build và chạy được, cây không đổi), `0a00118`
(tài liệu), sửa sau review `68836d1`, `2318f33` và một commit tài liệu (bullet cuối). Các bullet trước *Sửa
sau review* là số của bản đầu:

- **`SETTLE`.** `tools/tests/test_dphy_settle.py` biên dịch `bow_dphy_rx_settle()` của
  `bow_dphy_rx.h` bằng `cc` của máy host cùng hai công thức cũ: KV260 (107 ns + 24 UI) 912 Mbit/s,
  200 MHz: 22 = `settle_cycles()` = 22 (`TIM0` `0x051E0216`); Huins (120 ns + 0 UI) 1440 Mbit/s:
  `0x13` = `phy_cycles(95)` (`TIM0` `0x051E0213`); mô phỏng KV260 (108 MHz): 9 = 9; lưới lp clock
  50–400 MHz × LP_FILTER 0/5/10/15 × lane rate 0 và 80 Mbit/s…2,5 Gbit/s (bước 7 Mbit/s, hơn
  100 000 điểm): 0 điểm khác; Versal: 0x13 ở mọi lane rate như `SETTLE_VID_NS` = 95 (lane rate 0:
  chỉ từ phần sửa sau review, bản đầu cho 14 ở đó).
- **DV.** `make -C hw/ip/csi2rx/dv test` 272/272 (`test-rx` 105 gồm unit test aligner, `test-ppi`
  167); `SEEDS="1 … 10"` 434/434 (171 + 263); `mutants-ppi` 19/19 chết. So với bước 3 trên cùng
  case (HEAD dựng lại trong một cây riêng): `out.txt` (pixel, `tuser`, `tlast`) của `test-rx` giống
  từng byte ở 91/104 case, mọi case 1 và 2 lane; 13 case khác đều trên bộ thu 4 lane với PHY
  Versal (lần ghi `DES_RST_DIS` đầu test đổi thời gian, nên trạng thái ngẫu nhiên của FIFO PHY khác;
  khác ở dòng bị cắt / dừng mà mô hình cho phép mọi độ dài, mô hình kiểm đúng). Item TX chỉ đổi ở
  `be` (một lỗi LP của lane 0 với RX tắt để kiểm W1C của D-PHY) và `dly` (re-init bằng
  `CMD.REINIT`). Lỗi có từ trước, tìm thấy ở bước này: `deskew` và `loss` trên bộ thu 4 lane với
  PHY Versal hỏng ở ~1/3 seed Verilator (trên `main`: 9/30 và 10/30, bước 4 trước khi sửa 14/30 và
  11/30; directed test chỉ chạy seed 1): trễ FIFO trôi theo word glitch (`BurstRxRst` = 0) đưa cửa
  sổ dò sync vào nhiễu HS-PREPARE, nơi luật leader của deskew không nhận burst deskew, còn mô hình
  coi cửa sổ bắt đầu trong HS-zero. Hai test đó nay chạy không word glitch: 0/30 hỏng ở 4 lane, 2
  trên 4, cả hai test (random vẫn có trôi). `clk` 4 lane hỏng 1/30 seed ở bước 4 (0/30 ở `main`):
  một sync giả `00 B8` trong các word nhiễu ngay ở chu kỳ đầu của lần dò (lane 3, đoạn clock liên
  tục), cùng loại cửa sổ bắt đầu trong nhiễu, hiếm; không sửa (seed 1 đạt).
- **Hành vi đổi** (ghi chú bước 2): lỗi LP của lane clock khi `CLK_CONT` = 1: DV `loss` frame 16
  (`ERR_STATUS.LP` = 0, `CNT_LPERR` +1, `ERR_LANE[16]`; trước bước 4 `ERR_STATUS.LP` và
  `CNT_MISC[23:16]` đếm); aligner không bị reset khi RX tắt: DV `stop` (1, 2, 4, 2 trên 4 lane)
  đạt, pixel của `stop` 1 và 2 lane giống từng byte bước 3 (bản đầu còn đếm sự kiện của aligner
  khi RX tắt, ngoài danh sách: sửa sau review, bullet cuối); lỗi của data lane ở chu kỳ enable vừa
  xuống: không test nào nhắm được chu kỳ đó bằng chuỗi LP, `bow_ppi_chk` kiểm ở mọi chu kỳ rằng
  không có `ErrControl[l]` khi `Enable[l]` = 0 và không `ErrControlClk` khi `CLK_CONT`.
- **Hệ thống.** `make test` 15/15. So với gốc của nhánh `21e16d6` (= `main` `e56793f` + bước 3,
  chạy lại trong một cây riêng): 9 test không dùng firmware của bộ thu (`boot`, `load`, `break`,
  `flash`, `irq`, `gpio`, `mkv`, `ddr`, `hyperram`) có log giống hệt, kể cả số chu kỳ, trừ số dòng
  của `$finish` trong `tb_bow32.sv`; bốn luồng H.264 (`h264.hex`, `h264_rc.hex`, `h264_274a.hex`,
  `h264_274b.hex`) giống từng byte. Kỳ vọng đổi: `csi2_274`: dòng `phy` (`phy: READY 1, every
  nibble PHY_RDY 1 DLY_RDY 1, XPLL LOCKED 1 LOCKED_FB 1 (AFE_STATUS 00000f01), DES_RST_DIS 0`, trước
  `phy: STATUS.PHY_RDY 1, ... (PB6 PB7), reinit 0 burstrst 0 (PA4 PA5)`), `phy reinit` (`phy: READY
  40 us after CMD.REINIT`, đúng một xung `reinit_i`; trước `phy: PHY_RDY 40 us after the reinit
  pulse`, xung PA4), sau `test quick` `DES_RST_DIS` = 0 và `rd 40008c24` = `051e0213` (trước PA5 = 1
  và `rd 4000800c`): thanh ghi đã sang D-PHY; `csi2`: thêm `rd 40008c24` = `04100209` (`TIM0` của
  mô phỏng KV260); `camera274`: `error: D-PHY not ready (AFE_STATUS.READY = 0)` (trước `(CSI2RX
  STATUS.PHY_RDY = 0)`); `FW=brst0`: `DES_RST_DIS` = 1 và `-DDPHY_SETTLE_NS=140u` (SETTLE 23 =
  115 ns; `csi2_274 brst0` của `test-extra` đạt). Dòng `phy-idle` đổi theo thanh ghi (`LANE_LP 03f
  LANE_HS 00000` ở `csi2`, `LANE_LP 000 LANE_HS 00000` ở `csi2_274`; trước `STATUS 403f` /
  `004000`). Khác nữa, không phải kỳ vọng: firmware `camera` / `csi2_test` / `video` lớn hơn 308 /
  644 / 308 byte và đọc bộ đếm của hai khối, nên mọi thứ phụ thuộc thời gian của firmware đổi: số
  chu kỳ (`camera` 15 472 414 → 15 495 059, `csi2` 9 400 680 → 9 485 995, `h264` 8 166 368 →
  8 144 303, `camera274` 20 661 121 → 20 754 099, `csi2_274` 23 280 285 → 23 359 335, `video274`
  13 899 003 → 13 900 313), số frame / burst trong các dòng `stat` và của testbench, `link-up
  bursts 13/13` → `16/16` (số burst đếm được trong lúc chờ), số đo `timing` / byte clock, pha bit
  và số word HS-zero của `raw` (trạng thái ngẫu nhiên của mô hình), điểm khoá của AE ở `camera274`
  (`exp=60` → `65`).
- **xsim.** `test-dphy` seed 1–3 đạt: 37 burst, 2977 / 2985 / 2967 byte clock như bước 2, RAW của
  D-PHY khớp 46–51 byte sau sync mỗi lane, `DLYn` PEND tới burst sau; `test-dphy-versal` 25/25,
  mới `reinit_pulse` (`reinit_i` 651 ns: `phy_rdy_o` xuống sau 3 chu kỳ, trễ trở về BISC).
- **Kiểm tra khác.** `make lint`; `make test-tools` 207 test (1 bỏ qua: PyAV; 42 của mô hình
  CSI-2, 3 của `SETTLE`); `make sw` không cảnh báo, 8 binary không dùng bộ thu giống từng byte
  (`bootrom`, `ddr`, `flash_demo`, `gpio_demo`, `hello`, `hyperram`, `mkv`, `uart_irq`); `make
  gen-check`; `test-cdc` 204 check; ISP DV 12/12, H.264 DV 8/8; `make -C sim test-extra` 9/9
  (`csi2_274` corner 2, clock liên tục, `brst0`, `noglitch`; `camera274` corner 1, `brst0`;
  `video274` corner 0; `geo274` 1080p, 720p).
- **KV260 (không build, D1).** Netlist out-of-context của bộ thu ở `u_soc/u_csi2rx`, bản bước 3 và
  bản bước 4, tham số KV260 và Huins: mọi `set_bus_skew` của bộ thu trong `kv260_cam.xdc` (7) và
  `huins_vp1902_cam.xdc` (8; cái thứ 9 có phía XPHY, kiểm ở PDI) chọn cùng cell, cùng số
  (9/9/20/4/4/4/4 và 10/10/20/4/4/4/4/44) sau các đổi chỗ đã biết (req RAW `u_csi2rx/u_regs` →
  `u_dphy_rx/u_regs`, ack RAW `u_csi2rx/u_capture` → `u_dphy_rx/u_raw`, đích `u_sync_raw_*` vào
  `u_dphy_rx`, 44 cell nguồn của `DLYn` → `u_dphy_rx/u_regs`), `bow32_bus_skew_checks` 0 lỗi.
- **PDI camera Huins** (hw-station-1, `make -C hw/fpga/huins_vp1902 pdi CARD=cam ... JOBS=8`, 25,9
  phút, từ đúng cây của `281f53e` (= cây của `a485e82`): `git archive` cộng Ibex; một bản build
  trước từ snapshot có cùng RTL / XDC / Tcl cho cùng mọi số): timing đạt, WNS +0,342 ns (đường recovery trong H.264, ngoài bộ
  thu), WHS +0,017 ns, WPWS +0,231 ns; `clk_vid` +0,797 / +0,017 ns, `clk_sys` +3,761 / +0,040 ns,
  byte clock +1,669 / +0,039 ns; bus skew 11/11 (+3,893 … +5,042 ns), `INFO: bus skew cells: 0
  problems in 11 constraints`; kiểm tra clock / CDC 0 lỗi (mọi dòng nghiêm trọng thuộc danh sách
  duyệt: CDC-10 12 = 1 H.264 + 11 chân CLR của bộ đồng bộ reset, CDC-11 4 enable lane, CDC-13 709 =
  708 ISP + 1 cổng byte clock, CDC-1 245, CDC-4 4, CDC-14 18), sơ đồ nibble đạt, không có dòng
  `CRITICAL WARNING` (Vivado: 0 critical warning). Sau route 39 657 LUT / 25 266 FF (bước 2:
  39 393 / 25 171); bộ thu `bow_mipi_rx` 2816 LUT / 3156 FF (bước 2: 2545 / 2967): `bow_dphy_rx`
  1304 / 1405 (thanh ghi `u_regs` 381 / 416, RAW `u_raw` 55 / 52), controller 1516 / 1751 (thanh
  ghi 510 / 659); phần tăng là bộ đếm 32 bit, cửa sổ thanh ghi thứ hai và các bộ đồng bộ sự kiện
  của D-PHY.
- **Formality.** Không chạy ở bước 4: bản đồ thanh ghi và cổng bus đổi, nên không có phép so tương
  đương ở cổng. Phần không đổi được chứng minh bằng cách khác: file của datapath pixel (ghép lane,
  packet, unpack, đầu ra, FIFO) và của aligner, máy LP giống từng byte bước 3; pixel của DV như
  trên. Không chứng minh hình thức: rằng logic mới (thanh ghi, RAW, mặt nạ) đúng: phần đó là DV.
- **Sửa sau review** (commit `68836d1`, `2318f33` + tài liệu; review: một P2, sáu P3, không P0 / P1;
  mọi điểm được sửa):
  - **Sự kiện của aligner khi RX tắt (P2).** Bản đầu chuyển aligner sang reset của D-PHY nhưng
    controller vẫn biến `ErrSotSyncHS` / `RxSkewCalHS` thành `CNT_SOT`, `ERR_STATUS.SOT`,
    `CNT_EXT[31:16]`, `IRQ_STATUS.ERR` mà không xét RX: burst khi `RX_EN` = 0 mà `PHY_EN` = 1 được
    đếm, và dừng bộ thu khi một burst đang dò sync sinh lỗi SoT trên mọi lane (case `stopsync` của
    review: `CNT_SOT` = `0x00010001` khi `CTRL` = 0 ở 610–690 ns sau đầu burst; gốc nhánh: 0). Hai
    hiệu ứng đó không nằm trong danh sách hành vi đổi. Controller nay có cổng `stale_q` mỗi lane
    (`bow_csi2rx.sv`: đặt bởi `drst_n`, xoá một chu kỳ sau khi thấy `RxActiveHS` của lane thấp): bỏ
    sự kiện khi `drst_n` bật và của burst mà `RxActiveHS` đã cao lúc `drst_n` nhả; đó đúng là cách
    đếm của bước 1–3 (aligner reset cùng `drst_n`, `arm_q` reset = 1), nên không thêm hành vi đổi
    nào. Cách review đề xuất trước (flop reset bằng `drst_n` trước `bev`) chưa đủ: dừng bộ thu cũng
    kết thúc HS của lane clock (cùng `Enable`), nên byte clock thường dừng trước khi `RxActiveHS`
    của burst bị cắt xuống ở miền byte, và lỗi sync của nó chỉ tới cùng byte clock của burst đầu sau
    khi chạy lại, khi `drst_n` đã nhả và `bow_csi2rx_start()` đã xoá bộ đếm: bản đầu vì vậy đếm một
    lỗi SoT trên mọi lane đang dò ở burst đầu sau một lần chạy lại (có thể làm hỏng link check);
    mutant "chỉ trong reset" dưới hỏng đúng ở các điểm dừng đó. Datapath pixel không đổi (`px_drop`
    vẫn lấy `ErrSotSyncHS` trực tiếp: các burst bị bỏ khi đó ở ngoài frame hay trong reset). Test
    mới `rxoff` (1, 2, 4 lane, và clock liên tục trên 2, 4 lane ở `2318f33`; PHY Versal với
    `BurstRxRst` = 1): `RX_EN` = 0 với `PHY_EN` = 1, burst sync hỏng và burst deskew; `CTRL` = 0
    quét từng 10 ns qua cửa sổ dò sync của một dòng 256 pixel; `RX_EN` bật ở 20 điểm giữa một burst
    sync hỏng; rồi đếm lại khi RX bật. Hai case của review (`sotoff`, `stopsync`) đạt. 271 case cũ
    (104 `test-rx`, 167 `test-ppi`, seed 1–4) cho `cfg`, `stim`, `out`, `regs` giống từng byte với
    bản đầu và `sim.log` giống trừ số dòng của testbench.
  - **Formality** (`make -C hw/ip/dphy_rx/fm equiv REF=a485e82`, cùng cổng `bow_mipi_rx`, 5 cấu
    hình): bản sửa so với bản đầu của bước 4 khác đúng ở cổng sự kiện. Mọi compare point khớp theo
    tên và tương đương, trừ Lanes + 1 flop nguồn (`src_toggle_q`) của bộ đồng bộ sự kiện deskew và
    SoT từng lane (`u_csi2rx/g_cdc_bev[14]`, `[16]`…): KV260 17 314 point tương đương, 3 khác; Huins
    30 580 / 5; 1 lane 16 436 / 2; `HasPhy` = 0 và mô phỏng 17 314 / 3; điểm không khớp chỉ là 2 ×
    Lanes flop mới của implementation (`stale_q`, `arm_lo_q`). Script báo FAIL như phải thế (hành vi
    đổi có chủ ý); nó chứng minh mọi phần khác (D-PHY, datapath pixel, thanh ghi, các sự kiện khác)
    không đổi so với bản đầu. Bản đầu so với bước 3 vẫn không có phép so ở cổng (bản đồ thanh ghi và
    cổng đổi).
  - **RAW (P3).** Hai mutant RAW của bước 3 không còn bench nào bắt sau khi RAW sang D-PHY. Test mới
    `raw` (4 lane, PHY Versal, `BurstRxRst` = 1): núm mới `v_gap_byte` của `csi2_tx_model` đặt một
    khe đọc mỗi burst sau 24 byte packet, `l0_late_ns` cho data lane 0 vào HS muộn 40 ns (LP-01 dài
    hơn, HS-ZERO ngắn hơn, sync không đổi chỗ; hai núm tắt mặc định, không thêm lần rút số ngẫu
    nhiên); sáu lần bắt một dòng 200 pixel, mỗi lane sync rồi byte của lane tới hết cửa sổ, word đầu
    của lane 0 là `00` (cửa sổ của nó bắt đầu 3–7 word trong HS-ZERO; bắt ở cạnh lên của lane khác
    thì rơi vào nhiễu HS-PREPARE). `make -C hw/ip/csi2rx/dv mutants-rx` (`mutants_rx.py`, mới): RAW
    nhận cả word không valid, RAW bắt đầu ở lane bất kỳ (trên `bow_dphy_rx`, chết ở `raw`), cổng sự
    kiện bỏ hẳn, chỉ trong reset, bỏ cho deskew (chết ở `rxoff` cả 1, 2, 4 lane): 5/5. `mutants-ppi`
    19/19 (mutant đếm deskew ở lane cuối đổi theo cổng).
  - **`SETTLE` ở lane rate 0 (P3).** `bow_dphy_rx_settle()` lấy 70 ns cho lane rate 0 cả khi đích
    không có phần UI: trên Versal ra 14 thay cho `0x13` của `SETTLE_VID_NS` (không firmware nào
    truyền 0). Nay 70 ns chỉ khi đích có phần UI; test host quét Versal ở mọi lane rate kể cả 0 và
    đích 140 ns của `brst0` (23 = `phy_cycles(115)`).
  - **Hồ sơ PPI (P3).** Mục 5.5 (bảng, đoạn v1) và các dòng của bảng mục 5.3 theo wrapper của bước 4
    (không `phy_ready_i`, không `STATUS.CE` / `PHY_RDY`, không mặt nạ enable lane), thêm yêu cầu cho
    PHY chuẩn: chỉ báo `ErrControl[l]` khi `Enable[l]` = 1 (controller chỉ lấy OR) và không
    `ErrControlClk` khi lane clock chạy liên tục; cách controller bỏ `ErrSotSyncHS` / `RxSkewCalHS`
    khi RX tắt.
  - **`stat` (P3).** `LANE_LP` / `LANE_HS` và bộ đếm của D-PHY là các thanh ghi riêng (trước:
    `STATUS`, `CNT_BURST` ghép hai lane), nên dòng `phy:` có thể trộn hai thời điểm (mô phỏng
    `camera` của review: `d0 00 d1 00` khi đang HS, `bursts 1948/1949`). Driver đọc chúng tới khi
    hai lần đọc giống nhau (`bow_dphy_rx_snapshot()` mới), chỉ cho dòng đó: bộ đếm cho các vòng chờ
    (`bow_dphy_rx_counters()`) vẫn đọc một lần (đọc lại trong vòng chờ `link-up` của `csi2_test` làm
    bản mô phỏng chờ tới frame sau: 104 burst thay cho 15).
  - **Chú thích, commit (P3).** Chú thích của `bow_dphy_io_versal` (núm từ `CMD.REINIT` /
    `CTRL.DES_RST_DIS`, không còn GPIO PA4 / PA5); ba commit đầu gộp làm một (commit RTL một mình
    không qua được test của commit sau nó).
  - **Chạy lại** (trên `68836d1`; DV trên `2318f33`): DV `make -C hw/ip/csi2rx/dv test` 278/278
    (`test-rx` 111 gồm unit test aligner, `test-ppi` 167); `SEEDS="1 … 10"` 440/440 (177 + 263);
    `rxoff` với clock liên tục 1 / 2 / 4 lane seed 1–20: 60/60; `rxoff` 1 / 2 / 4 lane và `raw` với
    seed 1–40 (sinh và Verilator): 160/160; `make lint`; `make test-tools` 207 (1 bỏ qua); `make
    gen-check`; `make sw` không cảnh báo, 8 binary không dùng bộ thu giống từng byte bản đầu
    (`camera`, `csi2_test` +256 byte, `video` cùng cỡ); `test-cdc` 204 check; `make test` 15/15
    (40,5 phút): 9 test không dùng firmware của bộ thu có log giống từng byte bản đầu, bốn luồng
    H.264 giống từng byte, các test của bộ thu chỉ khác ở số phụ thuộc thời gian của firmware
    (`link-up bursts 15/15` thay cho 16/16, dòng `phy:` của `stat` nay một ảnh chụp: `lp clk 11 d0
    11 d1 11, bursts 1976/1976` thay cho `lp clk HS d0 00 d1 00, bursts 1948/1949` ở `camera`); 9
    biến thể của `test-extra` (`csi2_274` corner 2, clock liên tục, `brst0`, `noglitch`; `camera274`
    corner 1, `brst0`; `video274` corner 0; `geo274` 1080p, 720p) đạt; xsim `test-dphy` seed 1–3 đạt
    (37 burst, 2977 / 2985 / 2967 byte clock như trước, RAW của D-PHY khớp 46–51 byte sau sync) và
    `test-dphy-versal` 25/25 (chạy trước khi một chú thích RTL và phần mềm của `68836d1` đổi lần
    cuối); selector ngoài ngữ cảnh: 7 (KV260) và 8 (Huins) ràng buộc chọn đúng các cell của bản đầu
    (danh sách giống từng byte), 0 lỗi; PDI camera Huins (hw-station-1, cùng lệnh, 26,5 phút, từ
    đúng cây của `68836d1`: `git archive` cộng Ibex): timing đạt, WNS +0,556 ns (`clk_vid`), WHS
    +0,013 ns, WPWS +0,231 ns; byte clock +1,958 / +0,027 ns, `clk_sys` +4,2 / +0,032 ns; bus skew
    11/11 (+3,907 … +5,010 ns), `INFO: bus skew cells: 0 problems in 11 constraints`; kiểm tra clock
    / CDC 0 lỗi (mọi dòng nghiêm trọng thuộc danh sách duyệt, như bản đầu: CDC-10 12, CDC-11 4,
    CDC-13 709; CDC-1 251 / CDC-4 1 của ISP / H.264 thay cho 245 / 4), sơ đồ nibble đạt, 0 `CRITICAL
    WARNING`; sau route 39 694 LUT / 25 212 FF; bộ thu 2818 LUT / 3164 FF (bản đầu 2816 / 3156: +8
    FF là `stale_q`, `arm_lo_q` của 4 lane).
- **Trên bo Huins:** chờ chủ bo (lệnh và kết quả mong đợi đã chuẩn bị); KV260 không build và
  không chạy trên bo (D1).

**Bước 5: giao diện AFE.** `bow_dphy_rx` nói giao diện AFE của mục 3.2 (cổng `afe_*`; tập con v1 và
chỗ lệch ở mục 3.2 *v1* và [dphy_rx.md](dphy_rx.md) mục *Giao diện AFE*) và không còn chút FPGA
nào: `des_rst` là flop miền lp trong máy LP lane clock (`u_lp_clk/g_des_rst`), = ¬cổng, đặt và nhả
ở cùng cạnh với cổng (lấy từ trạng thái kế tiếp của nó), 0 khi `CTRL.DES_RST_DIS` = 1 (bit qua
`u_sync_vcfg`), 1 từ reset; mã delay là CODE / OWN của `DLYn` (flop miền bus, mức tĩnh, không có
giao thức nạp); thanh ghi mới `AFE_CTRL.PD` lái `pd`, `lprx_en` = ¬PD và `lane_pd`; `cal_start` là
xung `CMD.REINIT`; `cal_done` / `cal_err` vào `AFE_STATUS[2:1]`; `hsrx_en` và `term_en` là hai cổng
của cùng flop `hs_en`. Phần FPGA của bước 4 sang hai adapter (mục 3.7): `bow_dphy_dly_xusp` (`u_dly`
của `bow_dphy_io_xusp`: bộ đồng bộ mã + OWN theo byte clock, luật nạp của `g_dly_byte`, reset
ISERDES `u_iserdes_rst` từ `des_rst`) và `bow_dphy_dly_xphy` (`u_dly` của `bow_dphy_io_versal`: bộ
đồng bộ mã + OWN ở `CTRL_CLK`, trình tự nạp XPHY của bước 4 (`RX_EN_VTC`, `VtcWait` 12, `LdGap` 4)
với luật nạp mới, `RX_RST` = `burst_rst_q`); adapter Versal lấy `pd` và `cal_start` qua hai bộ
đồng bộ riêng (thay `reinit_i`). `DlyVid` bỏ; `AfeKind` (1 / 2) thay nó ở `bow_dphy_rx`,
`bow_mipi_rx` và `bow32_top` (`CsiAfeKind`). Sáu nơi dùng `bow32_top` đổi trong cùng PR, cổng cũ
không giữ. Tên instance mà XDC dùng giữ nguyên; ràng buộc bus skew của mã delay trong XDC Huins đổi
đích sang bộ đồng bộ của adapter (`u_dphy/u_dly/u_sync_code`, `u_sync_own`, nguồn CODE + OWN của
`u_dphy_rx/u_regs`: 40 → 40 cell với 4 lane), phép đếm 11 giữ (KV260: 9, thêm ràng buộc tương tự ở
review: 10); danh sách duyệt CDC không đổi.
`make lint` phủ cả sáu nơi dùng `bow32_top`: năm top của bo với stub cổng (stub UltraScale+ mới
`hw/lint/xilinx_xusp_stubs.sv`: `BUFGCE_DIV`, `IDELAYE3`, `ISERDESE3`, `MMCME4_ADV`; stub block
design KV260 `hw/lint/kv260_bd_stubs.sv`) và kết nối của testbench hệ thống `tb_bow32` (`make -C
sim lint`, cả hai bản dựng: chân thiếu là lỗi; từ review cả đầu vào nối rỗng `.pin ()`,
`hw/lint/empty_inputs.py`); thêm `bow_dphy_io_xusp`,
`bow_dphy_rx` (thêm 4 lane `AfeKind` 0 với `AfePdRst` = 1, `TrimW` 32) và logic hai adapter (1, 2,
4 lane). Mô phỏng chạy chính logic adapter: `csi2_tx_model` (DV và `tb_bow32`)
nhận cổng AFE và chạy `bow_dphy_dly_xusp` / `bow_dphy_dly_xphy`, mô hình delay của XPHY kiểm hợp
đồng của chúng (nạp chỉ khi ready, trong user mode, ≥ `VtcWait` sau `RX_EN_VTC` = 0, cách nhau ≥
`LdGap`, một chu kỳ, không nạp khi lần trước còn chờ); `bow_afe_chk` (mới, `hw/ip/dphy_rx/dv`, bind
vào mọi `bow_dphy_rx`) kiểm các luật của tín hiệu AFE; từ review hai bench đơn vị của phía AFE,
`tb_afe_dly` và `tb_dphy_afe` (`make -C hw/ip/csi2rx/dv afe`, trong `test-rx` và CI). Firmware
không đổi.

**Hành vi đổi có chủ ý** (bước 5):

- PHY Versal: lần ghi `DLYn` lại đúng mã đang dùng khi OWN = 1 không nạp nữa (bước 4: mỗi lần ghi
  một lần nạp); lần ghi đầu sau khi READY lên lại (OWN đã xoá) vẫn nạp, cả cùng mã. Lần nạp tới
  XPHY sớm hơn vài chu kỳ lp sau lần ghi (không còn bộ đếm yêu cầu và bước lấy tap trễ 2 chu kỳ).
  Lần ghi khi READY = 0 vẫn chỉ đặt CODE.
- PHY Versal: các lần nạp của một lane khi mã đổi liên tiếp cách nhau `LdGap` = 4 chu kỳ lp
  (`bow_dphy_dly_xphy.sv`: `wait_d = LdGap - 1`), thay cho ≥ 16 chu kỳ lp của bước 4 (bộ đếm yêu
  cầu `g_dly_vid` thả một yêu cầu mỗi 16 chu kỳ, trình tự của adapter đã cách 4). AM010 cho ≥ 3;
  **chưa thử trên silicon** (trên bo, phần mềm ghi `DLYn` cách nhau xa hơn nhiều; hai lần ghi liền
  nhau từ CPU thì cách 4–8 chu kỳ lp). DV, `tb_afe_dly` và xsim kiểm khoảng cách ≥ `LdGap`.
- `CTRL.DES_RST_DIS` = 1 nay cũng tắt reset `ISERDESE3` của KV260 (bước 4: reset đó theo cổng,
  không theo bit); bit thử, firmware chỉ đặt nó qua `phy burstrst 0` / `CAM_BURST_RST=0` trên Versal
  (lệnh `phy` của `csi2_test` chỉ có khi `INFO` báo AFE Versal, `cam_rx_start()` cũng chỉ ghi bit này
  trên Versal; trên KV260 chỉ một `wr` thô tới `CTRL` tắt được reset `ISERDESE3`).
  Đường `DES_RST_DIS` → reset đường thu dài hơn một chu kỳ lp (qua `u_sync_vcfg` rồi flop
  `des_rst`); thời điểm của reset theo cổng không đổi (Versal: `RX_RST` 1 chu kỳ lp sau khi cổng
  đóng / mở như `burst_rst_q` của bước 4; UltraScale+: bật cùng cạnh với cổng, nhả 2 byte clock
  sau khi clock chạy lại).
- `AFE_CTRL` (`0x4000_8C14`) là thanh ghi: đọc PD (0 sau reset trên FPGA, nên đọc như trước),
  ghi PD = 1 giữ adapter Versal ở reset khởi động tới khi xoá (chức năng mới, firmware không dùng).
  `lane_pd` (sửa sau review) chỉ xuống theo READY mới sau một lần PD (mục 3.6); hai adapter FPGA
  không dùng `lane_pd`, nên trên FPGA không thấy khác.
- Mô hình PHY Versal của mô phỏng (không phải RTL): reset FIFO RX lấy từ `RX_RST` của
  `bow_dphy_dly_xphy`, một chu kỳ lp sau cổng như adapter thật; mô hình của bước 4 reset FIFO cùng
  chu kỳ với cổng. Trạng thái ngẫu nhiên của FIFO (word glitch, trễ) vì vậy khác ở các test PHY
  Versal với `BurstRxRst` = 1.

**Kết quả bước 5 (2026-11-13)**, trên `3d3985a` (cuối bước 4), Verilator 5.020, Vivado 2025.2,
Synopsys Formality X-2025.06-SP4. Commit: `de11714` (logic adapter không primitive), `1620cfc`
(RTL, adapter, sáu nơi dùng `bow32_top`, XDC, lint, mô phỏng / DV: một commit, vì tách RTL khỏi mô
phỏng thì commit giữa không build hay không qua test, như bài học của bước 4), `7659c1c`
(Formality), `9924c65` (`bow_dphy_rx.h`) và commit tài liệu. Cây gốc để so: `3d3985a` dựng lại
trong một cây riêng.

- **Formality** (`make -C hw/ip/dphy_rx/fm equiv`, mặc định mới `STEP=5 REF=3d3985a`, ~30 s mỗi cấu
  hình): 5/5 cấu hình PASS. Implementation = `bow_mipi_rx_s4` (bộ thu của bước 5 sau cổng và tham số
  của bước 4), so với `bow_mipi_rx` của bước 4; mọi compare point khớp theo tên (signature analysis
  tắt) và tương đương, 0 failing / aborted / unverified, mọi cặp khớp có tên của tham chiếu sau luật
  đổi tên `u_mipi/` → rỗng và ở đúng khối: KV260, `HasPhy` = 0 và mô phỏng 17 203 compare point (55
  cổng, 17 148 flop; 17 424 cặp, khối ctrl 15 269, dphy 1 973, cổng 182), Huins 30 370 (57, 30 313;
  30 564 cặp: 27 041 / 3 299 / 224), 1 lane 16 379 (54, 16 325; 16 618 cặp: 15 147 / 1 310 / 161).
  Ngoài so sánh, đúng các thay đổi có chủ ý và được đếm: 2 + 10 × `Lanes` bit cổng của bước 4
  (`byte_rst_o`, `burst_rst_en_o`, `dly_tap_o`, `dly_load_o`: 22 / 42 / 12), `AFE_CTRL.PD` giữ 0
  (một user constant), cell không có cặp: tham chiếu KV260 `g_dly_byte` 74, `dly_tap_o` 18,
  `dly_load_o` 2, `u_iserdes_rst` 2 (1 lane: 37 / 9 / 1 / 2), Huins `g_dly_vid` 167, `dly_req_q` 8,
  `dly_load_o` 4, `u_iserdes_rst` 2; implementation `pd_q` 1 và `u_sync_cal` 4 (hằng 0) ở mọi cấu
  hình. Không so: thanh ghi hằng (88 KV260, 17 Huins, 128 1 lane) và flop không được đọc (6 / 10 /
  4), như ở hai phía. Lần chạy đầu với signature analysis bật hỏng ở Huins: Formality ghép 4 flop
  `u_sync_cal` (hằng 0) với 4 flop `g_dly_vid.u_sync_req` của tham chiếu theo chức năng, nên script
  tắt nó cho bước 5 (cell khác tên phải đứng một mình). Không chứng minh hình thức: tín hiệu AFE
  không có ở bước 4 (`des_rst`, `term_en`, `lprx_en`, `lane_pd`, mã và OWN, `pd`: `bow_afe_chk` và
  test của adapter), logic delay của hai adapter (đổi có chủ ý; DV, xsim, mutant).
- **DV** (`make -C hw/ip/csi2rx/dv test`): 278/278 (`test-rx` 111 gồm unit test aligner, `test-ppi`
  167, 22,8 s); `SEEDS="1 … 10"` 440/440 (177 + 263); `mutants-rx` 12/12 chết (5 cũ, 7 mới của giao
  diện AFE: `des_rst` trễ một chu kỳ và bỏ qua `DES_RST_DIS` chết ở `raw` / `dly`, OWN giữ khi READY
  xuống, `lprx_en` không theo PD, XPHY không chờ sau `RX_EN_VTC`, XPHY nạp lại cùng mã chết ở `dly`,
  `IDELAYE3` không nạp chết ở `be`); `mutants-ppi` 19/19. So với bước 4 trên cùng 439 case của
  `SEEDS="1 … 10"`: `cfg` giống ở mọi case; khác `stim` chỉ ở 17 case `be` (cả bench PPI) và `dly`
  (kích thích mới của bước 5); `out` (pixel) khác ở 11 case, `regs` ở 46, `sim.log` ở 20, đều trên
  bộ thu 4 lane với PHY Versal và `BurstRxRst` = 1 (`_brst`, `raw`, `rxoff`) hoặc `be`, `dly`. Thử
  nghiệm (không commit): mô hình PHY Versal reset FIFO cùng chu kỳ với cổng như mô hình của bước 4
  thay cho `RX_RST` của adapter: 176 case của `test-rx` cho `out`, `regs`, `sim.log`, `stim` giống
  từng byte bước 4 trừ đúng 7 case có kích thích mới (`be` ×5, `dly` ×2), tức mọi khác biệt còn lại
  đến từ thời điểm reset FIFO của mô hình (nay như adapter thật), không từ RTL.
- **Mô hình và host:** `make test-tools` 208 test (1 bỏ qua: PyAV; 43 của mô hình CSI-2, mới
  `test_afe_static_codes`: luật nạp, `AFE_CTRL.PD` trên AFE Versal và UltraScale+);
  `make gen-check`; `make sw` không cảnh báo, binary như trước khi đổi `bow_dphy_rx.h` (giống từng
  byte); object code của mọi file firmware giống từng byte bước 4 (61 object của `camera`,
  `csi2_test`, `video` so bằng `objdump -dr`), binary của ba app đó khác bước 4 chỉ do thứ tự link
  (`$(wildcard)` của `sw/mk/app.mk` theo thứ tự thư mục của mỗi checkout) và relaxation của linker
  RISC-V; `make lint` 0 cảnh báo (38,8 s); `make -C hw/fpga/huins_vp1902 test-cdc` 204 check.
- **Hệ thống** (`make test`): 15/15 (42 phút). 9 test không dùng bộ thu (`boot`, `load`, `break`,
  `flash`, `irq`, `gpio`, `mkv`, `ddr`, `hyperram`) có log giống bước 4 (số chu kỳ bằng nhau, khác
  đường dẫn và dòng `$finish`). Test của bộ thu so với RTL bước 4 chạy **cùng firmware** (build của
  cây này; firmware của cây bước 4 có thứ tự link khác): `camera` 15 491 743 chu kỳ, `csi2` 9 509
  375, `h264` 8 212 347: log giống từng dòng; bốn luồng H.264 (`h264.hex`, `h264_rc.hex`,
  `h264_274a.hex`, `h264_274b.hex`) giống từng byte. Bản IMX274 (PHY Versal): `camera274` 20 724 851
  chu kỳ (bằng), `csi2_274` 23 385 435 → 23 384 485, `video274` 13 916 032 → 13 916 003; nội dung
  khác ở số đo thời gian (`line` ±20–80 ns, byte clock đo được), RAW của `csi2_274` (sync ở word 10
  thay cho 9: trễ FIFO của mô hình), `ISP output frames` 173 → 174 của `video274`, và dòng thống kê
  của mô hình (`delay loads` 154 → 66/65/65/66 ở `camera274`, 81 → 35/36/36/36 ở `csi2_274`, 55 →
  16/15/15/16 ở `video274`: lần ghi lại cùng mã không nạp nữa). Thử nghiệm như DV (reset FIFO của mô
  hình cùng chu kỳ với cổng, cây sao chép, không commit), với firmware của cây này: `camera274`,
  `csi2_274`, `video274` cho log giống bước 4 từng dòng, cả mốc thời gian và số chu kỳ (20 724 851 /
  23 385 435 / 13 916 032), trừ dòng thống kê `delay loads` của mô hình (và số bit lật ngoài eye của
  `camera274`: 225 713 → 225 705), luồng H.264 giống từng byte. Điều đó **không đúng với mọi thứ tự
  link** của firmware (sửa sau review): review độc lập, cùng thử nghiệm với firmware của một
  checkout khác, thấy `camera274` còn lệch mốc thời gian ở các dòng `margin` (+240 ns; `csi2_274`,
  `video274` chỉ khác dòng `delay loads`). Phần khác biệt còn lại đó đến từ thay đổi thời điểm nạp
  (luật nạp mới: ít lần nạp hơn, sớm hơn vài chu kỳ) qua trạng thái ngẫu nhiên của mô hình (`$urandom`
  của mô hình delay và FIFO gọi theo thứ tự khác), không từ một thay đổi của những gì bộ thu làm;
  ngoài nó, khác biệt của bản IMX274 đến từ thời điểm reset FIFO của mô hình (nay như adapter thật).
- **xsim** (Vivado 2025.2): `test-dphy` seed 1–3 đạt: 37 burst, 2977 / 2985 / 2967 byte clock và RAW
  của D-PHY 46–51 byte sau sync như bước 4, `des_rst` = ¬cổng ở mọi cạnh `vid_clk` (12 072 / 12 084
  / 12 048 cạnh), `LOAD` của `IDELAYE3` 0 trước lần ghi đầu, 1 mỗi lane sau `DLYn`, ghi lại cùng mã
  vẫn 1; `test-dphy-versal` 25/25 đạt (9,3 phút), với luật nạp mới: lần đầu của mỗi lane OWN lên, 1
  `LD`; MERGE hai mã cách 2 chu kỳ → mã mới nhất, 1 `LD` trong lúc chờ VTC (`vtmode`), 2 ở user
  mode; SPACED 3 mã cách 16 chu kỳ → 3 `LD`; SAME cùng mã → 0 `LD`; OWN của lane 3 xuống → 0 `LD`,
  lên lại cùng mã → 1 `LD`; lane 0 không đụng tới; `reinit_pulse` (`cal_start_i` 640 ns: `ready_o`
  xuống sau 3 chu kỳ, XPLL LOCKED 0, mọi lane về trễ BISC), `reinit_idle` / `reinit_toggle` /
  `reinit_cont` (`pd_i` 2 µs), `burstrst_on` (`des_rst_i` bật giữa burst). Lần chạy đầu hỏng ở
  `vtmode` (SPACED: 2 `LD` thay cho 3): testbench lấy mã mới từ `dly_q_o` + 3, mà ở VT mode lần nạp
  đầu còn đang chờ VTC khi mã thứ hai tới, nên mã thứ hai trùng mã đầu và theo luật mới không nạp;
  testbench nay lấy mã ghi trước + 3.
- **KV260 (không build, D1).** Bộ thu ở `u_soc/u_csi2rx` cùng adapter UltraScale+ ở `u_dphy`, nối
  như `bow32_kv260_cam_top`, tổng hợp, đặt và đi dây trên xck26-sfvc784-2LV-c (Vivado non-project,
  76 s; bus do một LFSR lái, mọi đầu ra gộp vào một chân, `clk_sys` / `clk_vid` là chân) với các
  ràng buộc bộ thu của `kv260_cam.xdc` đúng như viết (chân MIPI, clock, false path CE,
  `CLOCK_DELAY_GROUP`, 7 `set_bus_skew` của bộ thu; 2 của H.264 không có cell ở đây): timing đạt
  (WNS +2,226 ns `clk_vid`, WHS +0,011 ns, WPWS +0,376 ns; byte clock +4,461 / +0,011 ns, `clk_sys`
  +15,817 / +0,026 ns); bus skew 7/7 (+4,424 … +8,101 ns), endpoint 9/9/20/4/4/4/4 như selector của
  bước 4, `bow32_bus_skew_checks` 0 lỗi; false path CE tìm thấy cả hai chân (`u_hs_bufg/CE`,
  `u_byte_bufg/CE`); `CLOCK_DELAY_GROUP bow_dphy_rx_clk` 2 net, `clockInfo.txt` của placer: "The
  following 2 clock nets belong to CLOCK_DELAY_GROUP bow_dphy_rx_clk"; `RST` của `ISERDESE3` do
  `u_dphy/u_dly/u_iserdes_rst`, `LOAD` / `CNTVALUEIN` của `IDELAYE3` do `u_dly` lái; không điểm cuối
  nào thiếu ràng buộc; `report_cdc`: đồng bộ của mã + OWN 20 dòng CDC-3, `u_iserdes_rst` CDC-9 (cả
  hai loại thông tin), dòng nghiêm trọng chỉ thuộc các loại đã biết (CDC-10 9 chân CLR của bộ đồng
  bộ reset, CDC-11 2 enable lane, CDC-13 6: CE của hai `BUFGCE_DIV`, `hs_en` và chân dữ liệu qua
  `IBUFDS_DPHY` tới `ISERDESE3`); 0 critical warning. Bộ thu 2368 LUT / 2468 FF (D-PHY 937 / 865,
  controller 1425 / 1603), logic adapter `u_dly` 24 LUT / 81 FF. Script của lần kiểm này nay ở trong
  repo (`make -C hw/fpga/kv260_cam rx-ooc`, review; kết quả với ràng buộc bus skew mới ở dưới).
- **PDI camera Huins** (hw-station-1, `make -C hw/fpga/huins_vp1902 pdi CARD=cam ... JOBS=8`, 27
  phút, từ cây làm việc ngay trước các commit: RTL / XDC / Tcl như các commit trừ hai chú thích sửa
  sau đó): timing đạt, WNS +0,389 ns (`clk_vid`), WHS +0,013 ns, WPWS +0,231 ns; byte clock +2,072 /
  +0,026 ns, `clk_sys` +4,321 / +0,043 ns; bus skew 11/11 (+3,968 … +4,980 ns; ràng buộc của mã
  delay 40 endpoint: 36 bit mã + 4 OWN), `INFO: bus skew cells: 0 problems in 11 constraints`; kiểm
  tra clock / CDC 0 lỗi, mọi dòng nghiêm trọng thuộc danh sách duyệt không đổi (CDC-10 12 (1 H.264,
  11 chân CLR của bộ đồng bộ reset), CDC-11 4 enable lane, CDC-13 709 (708 ISP, 1 cổng byte clock),
  CDC-1 253, CDC-14 18), sơ đồ nibble đạt (4 XPHY đặt ở chân của chúng), 0 critical warning (tổng
  hợp và implementation); stamp `pdi_site.txt` `CARD=cam FMC_SITE=1 CLK_SRC=ref200`. Sau route 39
  703 LUT / 25 185 FF (bước 4: 39 694 / 25 212); bộ thu `bow_mipi_rx` 2760 LUT / 2993 FF (bước 4:
  2818 / 3164): `bow_dphy_rx` 1243 / 1234 (bước 4: 1304 / 1405), controller 1521 / 1759; adapter
  Versal `u_dphy` 118 LUT / 272 FF, trong đó logic `u_dly` 86 / 193 (bộ đồng bộ của mã + OWN và
  trình tự nạp: trước ở `bow_dphy_rx` và trong adapter). PDI này dựng từ cây làm việc; sau review nó
  được dựng lại từ commit cuối của phần cứng (dưới).
- **Trên bo Huins:** chờ chủ bo (lệnh và kết quả mong đợi đã chuẩn bị: mọi lệnh của bước 4 với kết
  quả như cũ, thêm `AFE_CTRL.PD` và luật nạp delay); KV260 không build và không chạy trên bo (D1).

**Sửa sau review bước 5 (2026-11-13).** Một review độc lập (bench, mutant và log riêng) nêu 8 điểm;
mọi điểm đã sửa, trừ một ý của R5 (dưới). Commit: `82efcad` (`lane_pd`), `d1efcf6` (bench đơn vị
của phía AFE, mutant), `f581df9` (lint đầu vào nối rỗng), `59bfbec` (chú thích driver), `c322346`
(bus skew KV260, kiểm tra ngoài ngữ cảnh) và commit tài liệu.

- **R1 (P2) `lane_pd` nhả theo READY cũ.** `lane_pd` xuống khi thấy READY với PD = 0, mà READY qua 2
  flop còn đọc 1 vài chu kỳ sau khi PD lên: một xung PD hai lần ghi liền nhau nhả `lane_pd` ngay, suốt
  lúc AFE khởi động lại (bench của review: `bow_afe_chk` báo "lane_pd 0 before the AFE was ready").
  Nay `bow_dphy_rx_regs` giữ `rdy_low_q` (READY = 0 đã thấy từ lần PD lên gần nhất, 1 từ reset) và
  `lane_pd` chỉ xuống theo READY mới (mục 3.6). `bow_afe_chk` kiểm `lane_pd` ở mọi chu kỳ bus bằng
  mô hình tham chiếu của luật đó (nhả theo READY cũ hay không bao giờ nhả đều hỏng); DV `dly` kết
  thúc bằng một xung PD hai lần ghi liền nhau. Mutant của luật cũ chết ở `tb_dphy_afe` (hai bản
  dựng), `dly` và `be` (adapter UltraScale+ giữ READY = 1). Formality không đổi: `lane_pd` và
  `rdy_low_q` không lái đầu ra nào của wrapper bước 4.
- **R2 (P2) luật an toàn của logic adapter chỉ xsim thấy.** Bench đơn vị `tb_afe_dly` (CI, trong
  `test-rx`; mục 8.1): hai module logic adapter với mô hình primitive, mã + OWN ghi ở pha bất kỳ của
  clock adapter, bit lệch tới một chu kỳ: `RX_EN_VTC` = 1 và không `LD` sau một chu kỳ không `ready`,
  `RX_RST` = `ready` ∧ `des_rst` chu kỳ trước, OWN xuống rồi lên nạp lại cùng mã, mọi lane OWN nạp lại
  khi `ready` lên, hợp đồng `LD` của XPHY, reset `ISERDESE3` ở mọi lần mở cổng (2 cạnh byte clock),
  số `LOAD` / `LD` của mỗi thay đổi, không bao giờ nạp mã trộn. 16 mutant mới trong `mutants_rx.py`
  (6 của review và các mutant của R1, R3, tính ổn định 2 chu kỳ).
- **R3 (P3) CAL_DONE / CAL_ERR và giá trị reset.** Bench đơn vị `tb_dphy_afe` (`bow_dphy_rx` một mình,
  bản ASIC và bản FPGA) lái `cal_done` / `cal_err` / `status` từng bit; `bow_afe_chk` kiểm giá trị
  reset của mục 3.6 suốt lúc reset bật, ở cả hai miền reset (từ cạnh clock thứ hai trong reset).
- **R4 (P3) lint không thấy đầu vào nối rỗng.** `hw/lint/empty_inputs.py` đọc netlist XML của
  Verilator và báo mọi đầu vào `.pin ()`; `make -C sim lint` chạy nó cho hai bản dựng của `tb_bow32`
  (0 đầu vào); test host `tools/tests/test_empty_inputs.py`.
- **R5 (P3) tài liệu lệch mã.** Mục 6.4 (`power()`, `release_delay()`: bước 6), mục 3.7 (`INFO[30]`
  đọc 0 ở v1), [dphy_rx.md](dphy_rx.md) (chỗ lệch: review chấp nhận, chờ chủ dự án duyệt trong PR),
  danh sách thay đổi có chủ ý (`LdGap` 4 trên Versal), `cam_sensor.h` / `bow_dphy_rx.h` (`des_rst`
  thay `burst_rst_en_i`), mục 8.4, kết luận của thử nghiệm reset FIFO (trên). **Không sửa** ý "`phy
  burstrst 0` không chỉ trên Versal": lệnh `phy` của `csi2_test` chỉ được nhận khi `ct.vid` (INFO
  báo AFE Versal), `cam_rx_start()` cũng chỉ ghi `DES_RST_DIS` trên Versal; chú thích nay nói rõ.
- **R6 (P3) mã + OWN của KV260 không có bus skew.** `kv260_cam.xdc` thêm `set_bus_skew` của CODE +
  OWN tới `u_dphy/u_dly/u_sync_code`, `u_sync_own` (một chu kỳ byte clock, như Huins), `build.tcl`
  đếm 10 và nhận cell `u_dphy/u_dly/`; chú thích của `bow_dphy_dly_xusp` nói ràng buộc đến từ đâu.
- **R7 (P3) bằng chứng không lặp lại được.** Kiểm tra ngoài ngữ cảnh của KV260 vào repo (`make -C
  hw/fpga/kv260_cam rx-ooc`: `ooc/rx_ooc.tcl`, `ooc/rx_ooc_top.sv`, PASS / FAIL); PDI Huins dựng lại
  từ commit cuối của phần cứng.
- **R8 (P3) hợp đồng AFE cho ASIC.** Mục 3.5 ý 6 (áp mã mọi lane có OWN khi `ready` lên; `ready`
  xuống giữ ≥ 2 chu kỳ `clk_i`, đề xuất ≥ 100 ns), mục 3.6 (hai miền reset của điều khiển AFE).

Kiểm chứng sau review (cùng công cụ):

- **DV** (`make -C hw/ip/csi2rx/dv test`): 281/281, 24,9 s (`test-rx` 114: unit test aligner,
  `tb_afe_dly`, `tb_dphy_afe` ASIC và FPGA, 110 case; `test-ppi` 167); `SEEDS="1 … 10"` 443/443;
  `make afe` với `AFE_SEED` 1–40 đều đạt (`tb_afe_dly` 9 631–10 413 phép kiểm, 32–34 µs mô phỏng;
  mỗi lần 33–67 cạnh byte clock và 97–136 cạnh `CTRL_CLK` thấy mã trộn ở đầu vào của adapter, không
  lần nào nạp mã trộn); `mutants-rx` 28/28 chết
  (3 phút; mutant của giao diện AFE và logic adapter chết ở bench đơn vị, `--every`: luật `lane_pd`
  cũ cũng chết ở `dly`, `be`); `mutants-ppi` 19/19 chết (2 phút 46 s, `MJOBS`=1).
- **Formality** (`STEP=5`): 5/5 PASS, số liệu y như trên (17 203 / 30 370 / 16 379 compare point,
  thanh ghi hằng 88 / 17 / 128, flop không được đọc 6 / 10 / 4).
- **Host và lint:** `make test-tools` 211 test (3 mới của `empty_inputs.py`; 1 bỏ qua: PyAV),
  `make gen-check`, `make sw` không cảnh báo, mọi binary giống từng byte (chỉ đổi chú thích),
  `make lint` 0 cảnh báo (54 s, gồm kiểm tra đầu vào nối rỗng).
- **Hệ thống** (`make test`): 15/15 (42,5 phút), số chu kỳ như bản đầu của bước 5 (`camera` 15 491
  743, `csi2` 9 509 375, `h264` 8 212 347, `camera274` 20 724 851, `csi2_274` 23 384 485, `video274`
  13 916 003; dòng `delay loads` của mô hình 66/65/65/66, 35/36/36/36, 16/15/15/16), bốn luồng H.264
  giống từng byte bước 4 và bản đầu; `bow_afe_chk` mới (giá trị reset, mô hình `lane_pd`) không báo
  gì, cả ở `break` (reset SoC giữa chừng).
- **xsim:** `test-dphy` seed 1–3 đạt (37 burst, 2977 / 2985 / 2967 byte clock, `des_rst` = ¬cổng ở
  12 072 / 12 084 / 12 048 cạnh, `LOAD` 1 / 1 như trên); `test-dphy-versal` 25/25 đạt (6 phút; logic
  `u_dly` không đổi từ bản đầu).
- **KV260 ngoài ngữ cảnh** (`make -C hw/fpga/kv260_cam rx-ooc`, 70 s): PASS, timing đạt (WNS +2,270
  ns `clk_vid`, WHS +0,011 ns; byte clock +4,400 / +0,011 ns, `clk_sys` +15,977 / +0,015 ns), bus skew
  8/8 (+4,425 … +8,016 ns; ràng buộc mới của mã + OWN 20 endpoint, +7,749 ns), 0 lỗi cell; CE,
  `CLOCK_DELAY_GROUP`, lái `RST` / `LOAD` / `CNTVALUEIN` như trên; `report_cdc` chỉ các dòng đã
  duyệt (CDC-10 9, CDC-11 2, CDC-13 6); 0 critical warning; bộ thu 2368 LUT / 2468 FF, `u_dly` 24 /
  81 (không đổi).
- **PDI camera Huins** (hw-station-1, `make -C hw/fpga/huins_vp1902 pdi CARD=cam ... JOBS=8` dưới khoá
  Vivado, 27 phút, từ commit `c322346` với cây phần cứng sạch; commit tài liệu sau đó không đổi gì
  của phần cứng): timing đạt, WNS +0,389 ns (`clk_vid`), WHS +0,013 ns, WPWS +0,231 ns; byte clock
  +2,072 / +0,026 ns, `clk_sys` +4,321 / +0,043 ns; bus skew 11/11 (+3,968 … +4,980 ns), `INFO: bus
  skew cells: 0 problems in 11 constraints`; kiểm tra clock / CDC 0 lỗi (mọi dòng nghiêm trọng
  thuộc danh sách duyệt, cùng số như bản đầu), sơ đồ nibble đạt, 0 `CRITICAL WARNING` (các dòng
  nguồn Tcl mà log in lại không tính); 39 703 LUT / 25 185 FF và mọi số timing như bản đầu:
  `lane_pd` không ra khỏi `bow_mipi_rx`, nên luật mới không để lại cell nào trên FPGA; stamp
  `pdi_site.txt` `CARD=cam FMC_SITE=1 CLK_SRC=ref200`.

**Kết quả bước 6 (2026-11-13)**, trên `1c76364` (cuối bước 5), Verilator 5.020, Vivado 2025.2,
Synopsys Formality X-2025.06-SP4. Commit: `431c2d6` (RTL, PPI v1.x, driver, mô hình, checker, XDC,
Formality), `f5e0b0a` (`csi2_test`), `ecc674c` (bench D-PHY, mutant, CI) và commit tài liệu.

- **Chức năng và bit** (mục 4.2–4.12, [dphy_rx.md](dphy_rx.md) mục *Chức năng v1.x*): `T_INIT`
  (`TIM2[19:0]`, reset 0), `HS_TMO` (`TIM1[23:0]`, reset `0x100000`), `ESC_TMO` (`TIM2[31:20]`, 0),
  `HSRX_EARLY` (`CTRL[3]`, 0), `CLK_MISS_OFF` (`CTRL[16]`, 0), `RxSkewCalHS` mức (không có bit:
  ngoại lệ (1) của mục 4.12), `CLK_TOG_DIV` (`TIM1[27:24]`, 0), lỗi lp của PPI dạng bộ đếm gray
  (không có bit: đổi hợp đồng PPI, dưới), ULPS (`CTRL[2]` ULPS_EN, 0), shadow + APPLY (`CMD[0]`),
  bộ đếm gray phía bus (không có bit), `CLK_LOST_EN` (`CTRL[7]`, 0), LATE_EOT (chỉ báo cáo:
  `ERR_STATUS[7]`, `CNT_MISC`; không lên PPI), cùng `CMD[1]` REINIT / `CMD[2]` AFE_CAL,
  `LANE_STOP`, `CNT_MISC[31:16]`, `CNT_DSK[31:16]`, `INFO[27]`, `IRQ_STATUS[1]`. Mỗi chức năng có một
  test của bench mới và ít nhất một mutant bị giết (bảng ở [../simulation.md](../simulation.md) mục
  *D-PHY số*).
- **Hợp đồng PPI** (mục 5.2, 5.3, 5.5): `ErrControl[l]`, `ErrControlClk`, `ErrEsc[l]` là bộ đếm gray 2
  bit (≤ 1 bước mỗi 16 chu kỳ lp, sự kiện tới trong lúc chờ gộp vào bước sau, reset 0), controller
  lấy mẫu ở `vid_clk_i` ≥ `lp_clk` / 32 (`PpiLpClkHz` ≤ 32 × `PhyClkHz`; trước: phải bằng) và coi mỗi
  lần đổi là ≥ 1 lỗi; `ErrSyncEsc` 0; `RxSkewCalHS` mức trên mọi lane tới khi `RxActiveHS` xuống,
  controller đếm cạnh lên ở lane 0; `UlpsActiveNot*`, `RxUlpsEsc`, `RxUlpsClkNot` có nghĩa (trước: hằng);
  `Stopstate` tôn trọng `T_INIT`. Wrapper cổng phẳng đổi xung lỗi của PHY chuẩn thành bộ đếm ở
  clock lp của PHY (`LpClkHz`), `RxSkewCalHS` chỉ trễ.
- **Tương đương** (`make -C hw/ip/dphy_rx/fm equiv`, mặc định mới `STEP=6 REF=1c76364`): cả bộ thu
  không tương đương bước 5 theo thiết kế (APPLY thay `bow_sync` từng bit, bộ đếm gray thay bộ đồng
  bộ xung, bản đồ thanh ghi), nên hai phần được chứng minh, 7/7 PASS, mọi cặp khớp theo tên, 0 điểm
  failing / aborted / unverified: controller `bow_csi2rx` với tham số của 5 cấu hình (KV260,
  `HasPhy` = 0, mô phỏng: 15 287 compare point, 53 cổng + 15 234 flop; Huins 27 068; 1 lane 15 156),
  `ErrControl*` giữ 0 ở hai phía và `dsk_last_q` giữ 0 (9–21 user constant; không cặp: chỉ
  `u_lperr/` 12–30 flop và `dsk_last_q`); máy LP `bow_dphy_lp`, data lane 49 compare point, lane
  clock 52, các đầu vào mới ở giá trị reset (`HS_TMO` 2^20, còn lại 0) và `tmr_hi_q` giữ 0 (65 user
  constant; không cặp: chỉ flop và cổng mới). Không chứng minh được bằng Formality: thanh ghi và top
  của D-PHY (APPLY, bộ đếm gray, thanh ghi mới) và chính tín hiệu PPI: DV dưới phủ chúng.
- **Bench D-PHY mới** (`make -C hw/ip/dphy_rx/dv test`, CI và `make test-ip`): 26 case, `SEEDS="1 2
  3"` 78/78; `make mutants` 35/35 chết (tới 13 lần chạy mỗi mutant). Bench tìm ra trong lúc viết:
  LATE_EOT bị tính khi `CMD.REINIT` đóng cổng giữa burst (sửa: chỉ khi clock của máy phát dừng,
  `force_q`); và bộ đếm sự kiện gray bước ở những chu kỳ lp liền nhau (sự kiện của hai lane cùng
  chu kỳ), nên lệch giữa các bit ở bộ đồng bộ phía bus phải dưới một chu kỳ lp: mô hình jitter của
  `BOW_SYNC_JITTER` chỉ cho bit đổi trong cửa sổ setup về muộn, và FPGA có `set_bus_skew` mới (dưới).
- **DV bộ thu** (`make -C hw/ip/csi2rx/dv test`): 281/281 như bước 5 (`test-rx` 114, `test-ppi` 167);
  `SEEDS="1 … 10"` 443/443 (bước 5: 443/443); `make afe` với `AFE_SEED` 1–10 đều đạt (`tb_afe_dly`
  9 631–10 316 phép kiểm, `tb_dphy_afe` 74 / 68: bước 5 72 / 66, thêm `INFO[27]` và `CMD.AFE_CAL` /
  `CMD.REINIT`); `mutants-ppi` 20/20 (19 của bước 5, bỏ `flat_skew_cal_level`: wrapper không còn đổi
  cạnh lên thành xung; thêm `deskew_level_counted`, `lp_err_bit0_only`), `mutants-rx` 29/29 (thêm
  `reinit_starts_cal`). Kỳ vọng của mô hình đổi đúng ở các chỗ của bước 6 (APPLY, thanh ghi mới,
  LATE_EOT); một thử nghiệm không jitter (cùng kích thích cho RTL bước 5 và bước 6) cho 176/176
  đầu ra pixel giống hệt, 25 khác biệt thanh ghi đều giải thích được (bit `CTRL[16]` của `be`,
  LATE_EOT ở `clk` và `random` s4 / s5, HS_TMO trong `watchdog`, `CMD.AFE_CAL` mà bước 5 bỏ qua ở
  `dly`); `ovf2` chạy không word glitch như `deskew` / `loss` ([../simulation.md](../simulation.md)).
- **Host, lint:** `make test-tools` 211 (1 bỏ qua: PyAV), `make gen-check`, `make sw` 0 cảnh báo,
  `make lint` 0 cảnh báo (thêm: controller với `PpiLpClkHz` = 32 × `PhyClkHz`, từ chối 34 ×;
  `bow_dphy_rx` với `lp_clk` 600 MHz / `clk_i` 50 MHz, từ chối 650 MHz).
- **Hệ thống** (`make test`): 15/15 (42 phút). So với `make test` của `1c76364` (bước 5, chạy lại trong
  một worktree riêng ở đầu bước này, log giữ lại): `boot`, `load`, `break`, `flash`, `irq`, `gpio`,
  `mkv`, `ddr`, `hyperram` giống từng dòng và từng chu kỳ; bốn luồng H.264 (`h264.hex`, `h264_rc.hex`,
  `h264_274a.hex`, `h264_274b.hex`) giống từng byte; dòng `delay loads` của mô hình PHY như bước 5
  (66/65/65/66, 35/36/36/36, 16/15/15/16). Sáu test camera đổi số chu kỳ (`camera` 15 476 726 → 15 519 784,
  `csi2` 9 509 925 → 9 710 665, `h264` 8 165 323 → 8 212 360, `camera274` 20 724 829 → 20 707 074,
  `csi2_274` 23 402 890 → 23 613 382, `video274` 13 916 273 → 13 940 993) và các dòng phụ thuộc thời
  điểm (số frame / burst lúc `stat`, thời gian dòng và byte clock đo được, fps của `tpg`, thứ tự hai
  thông báo AE / AWB, burst mà RAW bắt được). Tách nguyên nhân bằng hai lần chạy nữa trong cùng
  worktree: firmware bước 6 trên phần cứng bước 5 (`1c76364` + driver và `csi2_test` của `ecc674c`;
  chạy được vì APPLY là no-op ở bước 5 và `bow_dphy_rx_reinit()` ghi cả `CMD[1]`) và cả cây `ecc674c`.
  (1) Firmware: bước 5 → firmware bước 6 trên phần cứng bước 5 cho đúng các khác biệt trên (ảnh
  `csi2_test` 40 420 → 42 872 byte vì các lệnh `phy` mới, APPLY và vòng chờ của driver): toàn bộ số
  chu kỳ của `h264`, `camera274`, `csi2_274`, `video274` và gần hết của `camera`, `csi2`. (2) Phần
  cứng, cùng firmware bước 6: `h264`, `camera274`, `csi2_274`, `video274` giống từng dòng và từng chu
  kỳ; `camera` giống từng dòng, +58 chu kỳ; `csi2` +775 chu kỳ, 14 dòng (link-up 15/15 → 16/16 burst,
  6 → 5 lỗi ở điểm margin ngoài eye, thời gian dòng đo được 860 → 920 ns, 37 060 → 37 061 burst).
  Lệch đầu tiên: dòng `phy-idle` của `test quick` ra muộn 160 ns (8 chu kỳ bus): `CMD.APPLY` của
  `bow_dphy_rx_timing()` nay chờ ack của miền lp (vài chu kỳ đọc `CMD[0]` = 1), ở bước 5 nó là no-op;
  phần sau là các lần kiểm rơi vào thời điểm khác so với frame của mô hình. (3) Worktree: cây
  `ecc674c` ở worktree riêng và ở worktree của nhánh cho cùng log và số chu kỳ ở cả sáu test; ảnh
  firmware của hai lần chạy (1) và (2) giống từng byte. Lệch đầu tiên của `camera` cũng là 160 ns ở
  lúc khởi động bộ thu (dòng "IMX219 streaming").
- **xsim** (Vivado 2025.2): `test-dphy` seed 1–3 đạt: 37 burst, 2977 / 2985 / 2967 byte clock như
  bước 5, `des_rst` = ¬cổng ở 12 080 / 12 092 / 12 056 cạnh `vid_clk` (bước 5: 12 072 / 12 084 /
  12 048: bench thêm một lần ghi `CMD.APPLY` sau `TIM0`, 2 chu kỳ bus = 8 cạnh `vid_clk`), `INFO`
  với bit 27, `LOAD` của `IDELAYE3` 1 / 1; `test-dphy-versal` 25/25 đạt (9,3 phút; adapter không đổi).
- **KV260 ngoài ngữ cảnh** (`make -C hw/fpga/kv260_cam rx-ooc`, 77 s): PASS, timing đạt (WNS +1,073
  ns `clk_vid`, WHS +0,005 ns; byte clock +4,757 / +0,028 ns, `clk_sys` +15,558 / +0,042 ns); bus skew
  9/9 (+4,012 … +7,946 ns; ràng buộc mới của bộ đếm sự kiện 52 endpoint, +4,012 ns), 0 lỗi cell;
  `report_cdc`: dòng nghiêm trọng chỉ các loại đã duyệt (CDC-10 9, CDC-11 2, CDC-13 6 như bước 5, một
  trong đó nay từ `term_q` của data lane 1: cổng `HSRX_DISABLE` = ¬(`hsrx_en` ∨ `term_en`) của
  `IBUFDS_DPHY`, nên luật CDC-13 của `rx_ooc.tcl` nhận `(hs_en|term)_q`; lần chạy đầu trước khi sửa
  luật: 1 dòng chưa duyệt); không nghiêm trọng: CDC-15 226 (bước 5: 134; 92 dòng mới là bản chép
  shadow → `cfg_lp_q`, có CE), CDC-3 210 (177: bộ đồng bộ từng bit của bộ đếm sự kiện, APPLY / ack,
  `CLK_TOG_DIV`, LATE_EOT thêm vào; cấu hình qua `u_sync_vcfg` và bộ đồng bộ xung bớt đi), CDC-6 2,
  CDC-9 3 như bước 5; 0 critical warning. Bộ thu 3137 LUT / 2986 FF (bước 5: 2368 / 2468): D-PHY 1706 /
  1364 (937 / 865: shadow và bản chép miền lp của `CTRL` / `TIM0`–`TIM2`, timer 24 bit, bộ giải
  escape, bộ đếm gray hai phía, LATE_EOT), controller 1426 / 1622 (1425 / 1603: `u_lperr`,
  `dsk_last_q`), logic adapter 24 / 81 (không đổi).
- **PDI camera Huins** (hw-station-1, `make -C hw/fpga/huins_vp1902 pdi CARD=cam ... JOBS=8` dưới khoá
  Vivado, 27 phút, từ commit `ecc674c`: phần cứng như `431c2d6`, cây phần cứng sạch, chỉ tài liệu
  chưa commit): timing đạt, WNS +0,722 ns (nhóm `async_default` của `clk_vid`), WHS +0,018 ns, WPWS
  +0,231 ns; `clk_vid` +0,753 / +0,022 ns, byte clock +1,833 / +0,018 ns, `clk_sys` +3,625 / +0,029 ns
  (bước 5: WNS +0,389, WHS +0,013; byte clock +2,072 / +0,026; `clk_sys` +4,321 / +0,043); bus skew
  12/12 (+3,929 … +4,927 ns; ràng buộc mới của bộ đếm sự kiện 68 endpoint: 17 bộ đếm 4 bit với 4 lane),
  `INFO: bus skew cells: 0 problems in 12 constraints`; kiểm tra clock / CDC 0 lỗi, mọi dòng nghiêm
  trọng thuộc danh sách duyệt không đổi và cùng số như bước 5 (CDC-10 12 (1 H.264, 11 chân CLR của
  bộ đồng bộ reset), CDC-11 4 enable lane, CDC-13 709 (708 ISP, 1 cổng byte clock), CDC-1 253,
  CDC-14 18; trên Versal đường `term_q` → `HSRX_DISABLE` không thành dòng nghiêm trọng, như `hs_en_q`
  ở bước 5, nên danh sách của Huins không đổi); không nghiêm trọng CDC-15 2371 (bước 5: 2277: bản chép
  shadow), CDC-3 325 (275), CDC-6 4, CDC-8 1, CDC-9 1; sơ đồ nibble đạt; 0 `CRITICAL WARNING` (các dòng
  nguồn Tcl mà log in lại không tính); 40 836 LUT / 25 873 FF (bước 5: 39 703 / 25 185, +1 133 / +688:
  phần v1.x của D-PHY); stamp `pdi_site.txt` `CARD=cam FMC_SITE=1 CLK_SRC=ref200`; sha256
  `a0c516b758efa0ceb6fa29b41698e7792203c069223cf98936dc43c508764ebc`.
- **Lệnh mới của `csi2_test`** chạy một lần trong một bản tạm của `csi2_274` (thêm vào cuối test, khi
  stream 1920x8 đang chạy; không commit): `phy v1x` đọc `ERR_STATUS` 0 (mô hình IMX274 không gây
  LATE_EOT), `LANE_STOP` `1f`, `TIM1` `00100000`; `phy check` 5/5 [PASS]: HS_TMO 2 µs cắt 136 burst dòng
  (36 lỗi link, `ERR_STATUS` `0c` = CONTROL + HS_TMO), HS_TMO ở giá trị reset 0 timeout và 0 lỗi,
  CLK_MISS_OFF 8 frame không lỗi, T_INIT 100 µs: `Stopstate` 239 µs sau `CMD.REINIT` (trong vertical
  blanking), về giá trị reset 0 lỗi; `stat` sau đó: link ok; test vẫn đạt.
- **Trên bo Huins:** chờ chủ bo. Firmware và PDI của bước 6 phải cùng commit (firmware của bước 5
  không ghi `CMD.APPLY` và ghi hiệu chỉnh AFE vào `CMD[1]`); firmware của bước 6 chạy được trên PDI
  của bước 5. Lệnh và kết quả mong đợi: mọi lệnh của bước 5, rồi `phy v1x`, `phy check` (HS_TMO 2 µs
  cắt các burst dòng, CLK_MISS_OFF 8 frame, T_INIT 100 µs với REINIT, về giá trị reset).
- **Hành vi đổi** (ngoài hai ngoại lệ có chủ ý của mục 4.12): `CMD[1]` là REINIT của máy LP, hiệu
  chỉnh AFE sang `CMD[2]`; `CTRL` / `TIM0` có hiệu lực sau `CMD.APPLY` (phần mềm không qua driver phải
  ghi `CMD` = 1); `INFO[27]` = 1; HS_TMO thêm `ERR_STATUS[3]` và `CNT_MISC` (vẫn là CONTROL và
  `CNT_LPERR` như watchdog cũ); LATE_EOT luôn được báo ở `ERR_STATUS[7]` / `CNT_MISC` (và `IRQ_STATUS.ERR`
  của D-PHY); lỗi lp tới controller muộn hơn tới 2 + 16 chu kỳ lp (bộ lấy mẫu, khoảng giữ của bộ
  đếm), sự kiện tới bộ đếm của D-PHY theo bộ đếm gray (đọc ngay sau một sự kiện có thể còn thiếu nó
  vài chu kỳ, như trước với bộ đồng bộ xung); `make lint` cho phép `PpiLpClkHz` khác `PhyClkHz`;
  KV260 11 / Huins 12 ràng buộc bus skew; danh sách CDC ngoài ngữ cảnh của KV260 nhận thêm
  `term_q` trước `ISERDESE3`.
- **Còn mở:** thứ tự bit của lệnh ULPS **[CHƯA CHẮC]** (mục 4.2); chạy bo (BOARD của bước 6: mọi lệnh
  của bước 5 cộng `phy v1x` / `phy check`); các trường v1.x chưa làm (mục 4.10, *v1.x*: `CTRL.EN`,
  `LANE_EN`, `DLY_REL`, bit SoT của `ERR_STATUS`, `CNT_DSK[15:0]`), tham số `TimRstNs` (bước 9);
  driver chưa đặt `T_INIT` (giữ 0, hành vi bước 5; đề xuất ~1 µs của mục 4.4 chờ một lần đo trên bo);
  `CLK_TOG_DIV` qua miền byte không có `set_bus_skew` (gần tĩnh, mục 4.11).

Bước 1–3 không đổi hành vi (refactor; bước 1–2 chứng minh bằng tương đương hình thức, cả hai bằng
Formality, D8 sửa đổi, mục 0; bước 3 chỉ thêm DV và một wrapper không nằm trong bản build nào);
bước 4–5 đổi bản đồ và giao diện, các kỳ vọng mô phỏng đổi được liệt kê ở bước 4 và 5; từ bước 6, mỗi
tính năng nằm sau một bit cấu hình có giá trị reset = hành vi hôm nay, trừ hai ngoại lệ có chủ ý
ở mục 4.12.

## 11. Câu hỏi mở và rủi ro

| ID | Câu hỏi / rủi ro | Ảnh hưởng | Hướng xử lý |
|---|---|---|---|
| Q1 | `lp_clk` của ASIC: ≥ 250 MHz chạy liên tục có chấp nhận được (công suất, nguồn clock) | ngân sách T_D-TERM-EN, phát hiện mất clock | **đã chốt hướng (D5)**: mặc định ≥ 250 MHz, `LP_FILTER` = 1; chờ đội clock / nguồn SoC xác nhận; nếu không: Q2 |
| Q2 | Termination tự động trong AFE (`AfeTermAuto`) | bỏ phụ thuộc `lp_clk`, chuyển lọc gai sang analog | đội analog đánh giá; mô hình AFE thử cả hai |
| Q3 | Delay line: tham chiếu DLL hay RC; bước ±1 không glitch; có delay lane clock không; nhả delay từng lane | bám VT, deskew giữa burst | đội analog; ảnh hưởng `INFO[22]`, `INFO[29]`, `INFO[30]` |
| Q4 | Sampler giám sát (mức 5 của hiệu chỉnh) | diện tích/công suất AFE so với lề VT | đo trôi VT trên FPGA và mô hình trước khi chọn |
| Q5 | Deserializer 8 hay 16 bit ở node đích | tần số miền byte, độ rộng PPI | tổng hợp thử (bước 9) |
| Q6 | Cảm biến đích trên 1,5 Gbit/s có gửi burst deskew không, dài bao nhiêu; con số 2^15 / 2^10 UI **[CHƯA CHẮC]** | cỡ bộ máy deskew | datasheet cảm biến đích; đặc tả có bản quyền |
| Q7 | Nguyên nhân phần chung (~0,37 UI) của độ lệch BISC (H5, mục 7.1); H1, H2, H4 đã loại, H3 đúng cho phần chênh giữa lane | chỉ ảnh hưởng FPGA, nhưng là bài học cho AFE | PDI với `PLL_CLK` 3000 MHz, đo lệch clock–data phía thu trên Huins |
| Q8 | PA5 = 0 hỏng trên silicon, mô hình không giải thích | adapter Versal | giữ `des_rst` luôn bật; thử lại với RTL đã gộp khi có bo |
| Q9 | Termination có phải mở cùng lúc khi phát hiện mất clock (T_CLK-MISS) **[CHƯA CHẮC]** | tuân thủ | thành viên MIPI kiểm ở đặc tả |
| Q10 | Loopback trên bo Huins có làm không: trong nibble (chỉ HS) hay qua chân (cần phần cứng mới) **[CHƯA CHẮC]** | tuỳ chọn của bước 8; điều kiện xong của bước 8 đã ở mô phỏng | thử loopback trong nibble trong mô phỏng XPHY trước |
| Q11 | 8 lane: cảm biến / bridge nào cần, CSI-2 phiên bản nào cho phép **[CHƯA CHẮC]** | ghép lane, lớp packet | chỉ làm khi có nhu cầu (bước 10); tới đó trường lane 4–7 đọc 0 |
| Q12 | Thời gian cảm biến giữ LP-11 trước burst đầu (IMX274: standby LP-00) và giá trị `T_INIT` phía thu mà đặc tả đòi **[CHƯA CHẮC]** | frame đầu, `T_INIT` mặc định | đo trên bo khi bo về; thành viên MIPI kiểm |
| R1 | Đặc tả MIPI chỉ cho thành viên: con số lấy từ nguồn công khai [S10] có thể thiếu hoặc lệch; ngưỡng, hysteresis và lọc gai LP, độ nhạy HS, common mode, dung sai termination chỉ có trong bản có bản quyền; không có tư cách thành viên thì không có CTS và không thể tuyên bố tuân thủ | không đóng băng được hợp đồng AFE | điều kiện tiên quyết trước khi đóng băng AFE (mục 9.7): tư cách thành viên, chọn phiên bản điện, kế hoạch tuân thủ; VIP thương mại cho sign-off |
| R2 | Lệch PPI của Bow32 (mục 5.3) làm khó ghép PHY / controller của hãng khác | tái dùng | hồ sơ PPI (mục 5.5), BFM hai chế độ (bước 3), wrapper phẳng; giữ lệch ở mức tối thiểu, ghi rõ |
| R3 | Bỏ alias: bitstream trước bước 4 không chạy với firmware mới | bo phải nạp lại bitstream một lần | firmware và bitstream build cùng commit; driver báo rõ khi `INFO[6]` = 0 (mục 6.3) |
| R4 | Test mức chân cần Vivado, không chạy trong CI | lỗi adapter lọt | logic adapter ở module không primitive chạy trong CI (bước 5): trong bench cả bộ thu và bench đơn vị `tb_afe_dly` với mô hình primitive (review bước 5); chạy `make test-fpga-dv` trước mỗi PR đụng adapter |
| R5 | Bo Huins dùng chung với đội khác; KV260 không chạy trên bo ở các bước chuyển (D1) | kiểm trên bo phải xếp lịch theo chủ bo; phần UltraScale+ chỉ kiểm bằng mô phỏng | mô phỏng trước; mỗi bước gom các lần chạy bo Huins; giữ `0x13` từng bit (mục 4.4) |
| R6 | Tốc độ thấp (< ~350 Mbit/s) cần ba sửa (a)–(c) của mục 4.5, trong đó (a) cần `clk_act` của AFE | dải hỗ trợ của đích B (đã chốt, D2) | `clk_act` bắt buộc với macro ASIC (mục 3.2), đội analog xác nhận sớm; sửa (b), (c) ở bước 10, là điều kiện sign-off |
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
