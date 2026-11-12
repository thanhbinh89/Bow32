# Camera trên Huins MFP-VP1902: IMX274 (LI-IMX274MIPI-FMC) → ISP của Bow32

Hướng dẫn chạy bộ thu MIPI CSI-2 và ISP của Bow32 với camera Sony IMX274 (module Leopard
LI-IMX274MIPI-FMC, 4 lane × 1440 Mbit/s) trên bo Huins MFP-VP1902-S (AMD Versal Premium
`xcvp1902-vsva6865-2MP-e-S`): build device image (PDI) có D-PHY **của Bow32** trên XPIO của
Versal (không dùng IP MIPI/D-PHY của AMD), nạp qua USB JTAG, nạp ứng dụng qua UART, stream,
chụp ảnh PNG về PC, quay video H.264 và kiểm tra bộ thu bằng `csi2_test`, giống luồng IMX219
trên KV260 ([camera_kv260.md](camera_kv260.md), [video_kv260.md](video_kv260.md)). Trước khi
đọc, hãy chạy được Bow32 trên bo này theo [ddr_huins.md](ddr_huins.md) (JTAG, console
"UART0"). Chi tiết bộ thu: [ip/csi2rx.md](ip/csi2rx.md).

> **Bước 4 của kế hoạch chuyển (2026-11-12, chưa chạy bo; [ip/mipi_rx_arch.md](ip/mipi_rx_arch.md)
> mục 10, [ip/dphy_rx.md](ip/dphy_rx.md)).** Thanh ghi PHY nay ở D-PHY `0x4000_8C00`, không có
> alias: núm PA4 thành `CMD.REINIT` (một xung 32 chu kỳ), PA5 thành `CTRL.DES_RST_DIS` (0 từ reset,
> tức `BurstRxRst` = 1 ngay từ reset), PB6 / PB7 thành `AFE_STATUS` (`rd 40008c18`: [0] READY,
> [8] XPLL LOCKED, [9] LOCKED_FB, [10] DLY_RDY, [11] PHY_RDY của mọi nibble); top camera không
> còn nối bốn chân đó (PA4…PA6 không ra chân, PB6 / PB7 đọc 0). `PHY_CFG` (`rd 4000800c`) thành
> `TIM0` của D-PHY (`rd 40008c24`, cùng bố cục: vẫn `051e0213`). `phy` in
> `phy: READY 1, every nibble PHY_RDY 1 DLY_RDY 1, XPLL LOCKED 1 LOCKED_FB 1 (AFE_STATUS 00000f01),
> DES_RST_DIS 0`; `phy reinit` in `phy: READY n us after CMD.REINIT`. PDI và firmware phải cùng
> commit: firmware mới trên PDI cũ in `csi2rx: bitstream before the D-PHY split, rebuild it`.
> Các lần chạy bo 1–3 dưới đây ghi lệnh và kết quả theo bản trước bước 4 (PA4 / PA5, `STATUS`).
>
> **Trạng thái: đã chạy trên bo ngày 2026-11-11 (lần chạy bo 3)**: PDI của `cd289e3` (RTL như main
> `458dd33`, như lần 2) với firmware `5c68b53` (ba sửa sau lần 2, mục 7). Mọi kiểm tra đạt: link
> check 16 frame của `start` trong `csi2_test` bắt lỗi ở trễ BISC 7 / 7 lần và in gợi ý `cal` (mục
> 6.3); `csi2_test` PASS 17/17 trên PDI mặc định và hai PDI thử; `rec` chọn `QP 37 (auto)` ở 720p
> (45 frame) và `QP 38 (auto)` ở 1080p (30 frame), đủ frame, giải mã không lỗi (6.5); 30 phút
> 1080p30 (53 999 frame) không lỗi, tap không đổi (6.4, mục 7); gợi ý của `make jtag` hiện đúng
> trước hw_server 2025.1 thật của đội khác (mục 5). Tìm nguyên nhân độ lệch của BISC (9.1): một
> tap ~1,86–1,89 ps (1 UI ≈ 374 tap), tâm eye cao hơn trễ BISC 0,26–0,48 UI tuỳ lane (không phải
> 1/4 UI như tài liệu trước ước); PDI thử B (slice N như IP của AMD) không đổi gì; PDI thử A
> (`DELAY_VALUE` 250 ps trên các lane dữ liệu) dời trễ BISC +132 tap với tâm eye không đổi, link
> sạch ở trễ BISC nhưng còn lệch +44/−24/+8/−34 tap (tiêu chí: ±20). Phần chung là một thời gian
> cố định mà BISC không thấy, phần riêng từng lane (~0,2 UI) đến từ ngoài FPGA; RTL và mặc định
> không đổi, ứng dụng vẫn luôn hiệu chỉnh.
>
> Lần chạy bo 2 (2026-11-11, bản cuối: PDI và firmware của `cd289e3`, giống main `458dd33` ở
> firmware và RTL): mọi kiểm tra đạt: firmware không sửa tìm thấy cảm biến (VMAX 0x906 sau reset,
> mục 6.2); `PHY_RDY` = 1 ngay sau khi nạp, đủ 4 trễ BISC (6.3); `csi2_test` PASS 17/17; `extra 0`
> ở 720p60 và 1080p30; `margin` đo cả 4 lane (±88/±90/±90/±88 tap, 0 lỗi, BER < 1,0e-8) và giữ tap
> đặt bằng tay; `cam` đầu tự hiệu chỉnh, sọc màu đúng thứ tự, `flip 0 1` màu tự nhiên (ISP `BAYER`
> RGGB), AE/AWB đứng yên khi test pattern bật, không có frame đen sau `tp 0` (6.4); 5 phút 1080p30
> (9012 frame) không lỗi, tap không đổi; video H.264 1080p30 ghi đủ 30 / 30 frame (QP 37–38),
> 720p30 45 / 45, giải mã không lỗi (6.5). Đo thêm: cửa sổ `SETTLE` như lần 1 (65–170 ns), trail
> sau packet 49–52 byte trên 4 lane (`CTRL.EXTRA` 192 của driver dư 140 byte), tâm eye sau hiệu
> chỉnh cao hơn trễ BISC +99…+177 tap như lần 1. Đầu ra thật ở mục 5 và 6, số đo ở mục 7, việc còn
> mở ở cuối mục 7. Sau lần 2 firmware đổi chữ của một thông báo của `margin`, rồi sửa ba việc phần
> mềm của lần 2 (link check của `start` trong `csi2_test` qua 16 frame nguyên, QP đầu của `rec`
> theo mode, gợi ý của `make jtag` khi hw_server cũ hơn Vivado): cả ba đã kiểm trên bo ở lần 3.
>
> Lần chạy bo 1 (2026-11-10, PDI và firmware của commit trước khi gộp main, `aaf7ed4`): camera
> chạy, 4 lane × 1440 Mbit/s (byte clock 180,078 MHz), `csi2_test` PASS 15/15 sau `cal`, 1080p30 và
> 720p60 không lỗi (hơn 18 000 frame trong ~15 phút với tap đã hiệu chỉnh), sọc màu đúng thứ tự,
> cảnh thật màu tự nhiên, video H.264 1080p30 giải mã không lỗi (20 / 30 frame: rate control cũ).
> Các phát hiện của lần 1 đã sửa trong `cd289e3` (sau khi gộp main PR #17), kiểm trong mô phỏng
> rồi trên bo ở lần 2: probe nhận VMAX 0x906 của cảm biến trên bo (mục 6.2); Bayer vẫn RGGB khi
> lật dọc (6.4); `cam` đầu luôn hiệu chỉnh vì trễ BISC nằm ở mép sớm của eye (6.4, 9); `margin` đo
> quanh trễ đang dùng của mọi lane (6.3, 6.4); `stat` liệt kê 4 lane khi bộ thu tắt (6.3); AE/AWB
> dừng khi test pattern bật (6.4); rate control mới của `rec` (6.5). PA5: firmware vẫn đặt PA5 = 1
> với `SETTLE` 95 ns (đo: sạch 65–170 ns ở cả hai lần); PA5 = 0 hỏng trên bo, nên tài liệu bỏ cách
> dự phòng "PA5 = 0 + `SETTLE` 115 ns" (6.3).
>
> PDI của bản cuối, dùng ở lần 2 và lần 3 (build 2026-11-10, hw-station-1, Vivado 2025.2,
> `JOBS=8`, 26 phút, lệnh của mục 4, RTL của `cd289e3`): timing đạt, WNS +0,780 ns (`clk_vid`), WHS
> +0,014 ns (`clk_vid`), byte clock 180 MHz +1,946 ns / +0,025 ns, `clk_sys` +3,719 ns / +0,016 ns;
> bus skew 11/11 đạt (slack +3,893 … +5,004 ns); Vivado không báo critical warning nào;
> `methodology.rpt` như lần 1; sơ đồ nibble và `pre_opt_cam` đạt; 16 cổng trên VCCIO của FMC+01.
> Kiểm tra CDC của chính build (mục 4) đã in 3 dòng `CRITICAL WARNING`: hai mục CDC-11 từ
> `u_soc/u_csi2rx/u_regs/lane_en_q_reg[4]` tới bộ đồng bộ enable của data lane 2 và 3 (hai enable
> luôn bằng nhau, synthesis gộp chúng thành một flop) và dòng tổng. Cùng loại với mục lane 0/1
> đã duyệt (flop gộp, gần tĩnh: chỉ đổi khi bộ thu tắt), không ảnh hưởng ảnh. Mục này đã được
> thêm vào danh sách duyệt (`tcl/timing_checks_cam.tcl`); chạy lại các kiểm tra của build trên
> checkpoint đã route của PDI này: 0 lỗi, không còn `CRITICAL WARNING`.
>
> Hai PDI thử của lần 3 (2026-11-11, cùng máy và lệnh, mỗi PDI một cây build riêng với generic thêm
> tạm cho `bow_dphy_io_versal`, không có trong repo; mục 9.1): A (`DELAY_VALUE` 250 ps, 28 phút)
> timing như PDI mặc định (WNS +0,780 ns, WHS +0,014 ns); B (slice N như IP của AMD, 27 phút) WNS
> +0,449 ns (nhóm recovery `async_default` của `clk_vid`), WHS +0,027 ns; cả hai bus skew 11/11,
> không có `CRITICAL WARNING`.
>
> PDI của lần 1 (`aaf7ed4`, cùng máy, 25 phút): WNS +0,180 ns, WHS +0,018 ns (`clk_vid`), byte
> clock +1,623 ns / +0,026 ns, `clk_sys` +3,484 ns / +0,037 ns, bus skew 11/11 (+3,781 … +5,016
> ns), không có `CRITICAL WARNING`, `methodology.rpt` 45 mục, 1 mục có waiver, SoC ở SLR0.
> Firmware: mỗi lần khởi động bộ thu đặt PA5 = 1 (`BurstRxRst`) với `SETTLE` 95 ns (mục 6.3). Mô
> phỏng: D-PHY Versal với model XPHY của AMD, 24/24 cấu hình (`make -C hw/fpga/common/dv
> test-dphy-versal`, mục 9); hệ thống với firmware thật (`camera274`, `csi2_274`, `video274`,
> [simulation.md](simulation.md)).

```
 LI-IMX274MIPI-FMC ─adapter Huins─► FMC+01 ──► bow_dphy_io_versal ──► bow_csi2rx ──RAW10──► ISP Bow32 ──► capture / H.264 ──► CPU ──UART0──► PC
 (IMX274)       4 lane × 1440 Mb/s  bank 705   (IBUFDS_DPHY, XPHY,     CSI2RX         AXI4-S    (200 MHz)                      (sw/apps)  (PNG,
      ▲         RAW10                          XPLL, BUFGCE)           0x4000_8000                                                        bow32_cam.py)
      │                                                                     ▲ thanh ghi (peripheral bus)
      └── I2C0 (IMX274 ở 0x1A, không có switch) ◄── Ibex ───────────────────┘
          PA7 = XCLR (1 = cảm biến chạy); núm của D-PHY: thanh ghi ở 0x4000_8C00 (trước bước 4: PA4/PA5)
```

Tài liệu của Huins (user guide, schematic, netlist) là tài liệu mật: thư mục
`docs/fpga/Huins_MFP-VP1902/` bị `.gitignore` và **repo không chứa số chân FPGA nào của
Huins, cũng không chứa nibble hay slice của từng chân**. `hw/fpga/huins_vp1902/constr/pins.txt`
(mục `[card=cam]`) chỉ ghi cổng → tên net của bo; lúc build, `tools/huins_pins.py` tra netlist
trong bản sao cục bộ và sinh file XDC chân vào `build/fpga/huins_vp1902_cam/`, rồi
`tcl/cam_plan.tcl` suy ra sơ đồ nibble của XPHY từ file đó (mục 4). Cả hai file chỉ nằm trong
thư mục build: không bao giờ commit hay gửi đi. Datasheet IMX274 cũng là tài liệu có bản
quyền: không chép vào repo.

## 1. Cần gì

| Thứ | Ghi chú |
|-----|---------|
| Huins MFP-VP1902-S + nguồn | như [ddr_huins.md](ddr_huins.md) mục 1 (SW1 = JTAG, SW12 OFF) |
| Module **Leopard LI-IMX274MIPI-FMC** (Sony IMX274) | cảm biến 8 MP, luôn xuất 4 lane CSI-2 × 1440 Mbit/s, RAW10; dao động 24 MHz trên module |
| **Bo chuyển camera của Huins** ("Camera Adaptor", trong bộ camera của Huins) | nằm giữa module và khe **FMC+01**; đổi chỗ các cặp MIPI để cả 5 cặp và các chân điều khiển rơi vào **một** bank XPIO (705). Không có bo chuyển thì không dùng được (mục 3) |
| Cáp USB-C "USB JTAG" và "UART0" (mặt trước) vào máy build | console của Bow32 là bridge CP2102N của "UART0" (không gửi được BREAK, mục 6.1) |
| Vivado 2025.2 có part `xcvp1902` | MicroBlaze GCC của Vivado (PLM), RISC-V GCC, Python 3 có `openpyxl`, bản sao tài liệu Huins |

Chân dùng (qua bo chuyển; nibble và slice của từng chân là dữ liệu của bo, chỉ có trong thư
mục build):

| Cổng của top | Chân FMC (net của bo) | Bank | Nối tới |
|--------------|-----------------------|------|---------|
| `mipi_clk_p_i` / `_n_i` | CLK0_M2C (`F_FMC1_CLK0_M2C_P/N`) | 705 | lane clock = strobe của XPHY |
| `mipi_data_p_i[0]` / `_n_i[0]` | LA10 | 705 | data lane 0 |
| `mipi_data_p_i[1]` / `_n_i[1]` | CLK1_M2C | 705 | data lane 1 |
| `mipi_data_p_i[2]` / `_n_i[2]` | LA08 | 705 | data lane 2 |
| `mipi_data_p_i[3]` / `_n_i[3]` | LA06 | 705 | data lane 3 |
| `cam_scl_io` / `cam_sda_io` | LA26_P / LA26_N | 705 | I2C của cảm biến (I2C0 của Bow32) |
| `cam_xclr_o` | LA22_N (module: FMC_RST) | 705 | XCLR của cảm biến, 0 = reset (= PA7) |
| `cam_xce_o` | LA27_P (module: FMC_SPI_CS_N) | 705 | XCE của cảm biến, luôn 1 (chế độ I2C) |
| `cam_flash_o` | LA16_N (module: FMC_FLASH) | 705 | luôn 1 (như thiết kế của AMD) |
| `fmc_prsnt_n_i` | PRSNT_M2C_L (`F_FMC1_PRSNT_N`) | 703 | 0 = có module (PB5) |

Không dùng, để trống (input hoặc chưa rõ chức năng): LA22_P (FMC_CLK), LA29 (XVS/XHS), LA24
(LED_EN/PWM), LA28 (cuộn của bộ lọc hồng ngoại: không bao giờ lái), các chân Sub-LVDS và DSI
của module. Giữa chân FMC và FPGA không có điện trở, tụ, terminator hay level shifter nào.

## 2. Chuẩn bị bo (mọi thao tác cắm/rút khi bo đã tắt nguồn)

**VCCIO của khe FMC+01 phải là 1,2 V.** Slide switch **SW192** cấp VCCIO cho bank 703..706
(cả khe FMC+01) và chân VADJ của khe:

* XPIO chỉ có chuẩn `MIPI_DPHY` ở VCCO **1,2 V**; các chân điều khiển là `LVCMOS12` cùng
  bank. XDC của bản camera khai báo đúng như vậy và build kiểm tra mọi cổng của bank 703..706
  (mục 4), nhưng Vivado chỉ thấy ràng buộc, **không thấy vị trí thật của SW192**: PDI vẫn
  build và nạp được khi switch ở 1,5 V (mặc định của Huins), và khi đó bộ thu HS không được
  đảm bảo chạy. Chỉ LED "1.2" và TP29 kiểm được switch;
* **không bao giờ để 1,0 V** khi có module;
* datasheet của Leopard ghi VADJ 1,8 V hoặc 1,5 V, nhưng AMD chạy chính module này ở VADJ
  1,2 V trên VCK190 (và ZCU102/ZCU106); Bow32 làm như AMD;
* bo RAM (FMC+_DDR2_HyperRam) có thể ở yên trên **FMC+10** với **SW196 = 1,5 V**: bản build
  camera không dùng chân nào của FMC+10 (không ràng buộc, level shifter của bo RAM tự cô lập).

### Bo nào ở khe nào, nạp PDI nào

FMC+01 và FMC+10 có VCCIO riêng (SW192, SW196). Bo chuyển camera chỉ dùng FMC+01 (mục 3); bo
RAM ([ddr_huins.md](ddr_huins.md)) mặc định ở FMC+10 nhưng build được cho khe khác
(`FMC_SITE`). LED11 / PB5 chỉ báo "có một bo FMC+ trên khe", **không phân biệt bo camera với
bo RAM**: trước mỗi lần nạp PDI, nhìn tận mắt bo nào đang cắm ở khe nào.

| Đang cắm | Switch | Được nạp | Không bao giờ nạp |
|----------|--------|----------|-------------------|
| bo chuyển camera ở FMC+01 (bo RAM ở FMC+10 hoặc không có) | SW192 vị trí "3" (chỉ LED "1.2", TP29 ≈ 1,2 V); SW196 vị trí "2" (1,5 V) | PDI camera; PDI bo RAM **chỉ khi** build với `FMC_SITE=10` | PDI bo RAM build với `FMC_SITE=1` |
| bo RAM ở FMC+01 (không có bo chuyển camera) | SW192 vị trí "2" (chỉ LED "1.5", TP29 ≈ 1,5 V) | PDI bo RAM `FMC_SITE=1` (khoá ở `make jtag` luôn từ chối PDI này: kiểm xong thì `CONFIRM=1`) | PDI camera |

PDI bo RAM build cho FMC+01 lái 9 đầu ra vào các chân FMC+01 mà bo chuyển nối tới module:

| Chân FMC+01 | PDI bo RAM lái | Phía module (qua bo chuyển) |
|-------------|----------------|-----------------------------|
| LA10_P | `ddr_ls_oe_n_o` | data lane 0, P (đầu ra D-PHY của cảm biến) |
| LA08_P / LA08_N | `hr_ls_dir_dq_o` / `hr_ls_oe_n_o` | data lane 2, P / N: tranh chấp với driver D-PHY của cảm biến |
| LA26_P | `ddr_a_o[5]` | SCL của cảm biến |
| LA27_P | `ddr_a_o[6]` | XCE |
| LA22_P | `ddr_a_o[2]` | FMC_CLK |
| LA24_P | `ddr_a_o[3]` | LED_EN |
| LA28_P | `ddr_a_o[7]` | cuộn của bộ lọc hồng ngoại (không bao giờ được lái) |
| LA29_P | `ddr_a_o[8]` | XVS |

Đổi bo trên FMC+01:

* **bo RAM lên FMC+01** (sau khi tháo bo chuyển camera): tắt nguồn, đặt SW192 về "2", bật
  nguồn khi chưa cắm bo, kiểm tra chỉ LED "1.5" sáng và TP29 ≈ 1,5 V, tắt nguồn, rồi mới cắm
  bo RAM. Bo RAM không bao giờ được cấp nguồn khi VADJ của khe dưới 1,5 V
  ([ddr_huins.md](ddr_huins.md) mục 1), mà cài đặt camera để SW192 ở 1,2 V;
* **camera trở lại FMC+01**: tháo bo RAM, SW192 về "3", kiểm tra LED "1.2" / TP29 như "Lần 1"
  bên dưới, rồi mới cắm bo chuyển.

**Khoá ở `make jtag`.** `make pdi` (cũng là `make fpga BOARD=huins_vp1902 ...`) ghi cạnh PDI
file `pdi_site.txt` (`CARD`, `FMC_SITE`, `CLK_SRC`, loopback của bo RAM); file bị xoá khi một
lần build bắt đầu và chỉ được ghi khi build xong. `make jtag` in nội dung file và bo nào phải
cắm, rồi **từ chối nạp** khi: không có file (khe không rõ, ví dụ PDI dựng trước khi có khoá
này), PDI mới hơn file (build bằng cách khác, ví dụ Makefile của nhánh khác trong cùng thư mục
build: file là của image trước), file của bo kia (`CARD` khác), hoặc PDI bo RAM cho FMC+01. Chỉ
vượt khoá bằng `CONFIRM=1` sau khi đã kiểm bo và switch (mục 5).

**Lần 1, chưa cắm module:**

| Việc | Đặt | Vì sao |
|------|-----|--------|
| **SW192** (VCCIO khe FMC+01) | vị trí **1,2 V** (hình 9 của user guide: vị trí "3"; mặc định "2" = 1,5 V) | xem trên; kiểm tra bằng LED, đừng tin số vị trí |
| DIP **SW1** (boot mode) | cả 4 cần **OFF** (JTAG) | như [ddr_huins.md](ddr_huins.md) |
| **SW12** | **OFF** (dao động 200 MHz) | clock vào của bản build (`CLK_SRC=ref200`) |

Bật nguồn. Kiểm tra: cạnh SW192 **chỉ** LED **"1.2"** sáng; đo test point **TP29** (VADJ của
FMC+01) ≈ **1,2 V**; các LED power good sáng như hình 10 của user guide. Tắt nguồn.

**Lần 2:** gắn module lên bo chuyển camera của Huins, cắm bo chuyển vào **FMC+01** (bo đang
tắt), bật nguồn, kiểm tra lại LED "1.2" / TP29. Lần đầu: đo các mức nghỉ ở mục 7 trước khi nạp
PDI. Sau khi nạp PDI (mục 5), LED11 sáng = có module (PRSNT_M2C_L = 0).

## 3. Vì sao không dùng FMC+10 (hay khe khác)

Ở 1,44 Gbit/s Versal phải nhận bằng XPHY ở chế độ native: lane clock là **strobe**, vào slice 0
của một nibble rồi được chuyển sang các nibble khác bằng dây riêng (inter-nibble trong cặp
nibble, inter-byte sang nibble ±2). Các dây này **không bao giờ ra khỏi một bank XPIO**. Trên
FMC+10 (có hay không có bo chuyển) và mọi khe khác, 5 cặp MIPI của module nằm rải trên 2–3
bank: IP của AMD từ chối (`ADVWIZIO-16`), XPHY của Bow32 qua được synth/place nhưng hỏng ở
route (`[Route 35-7]` unroutable pins). Chỉ có bo chuyển của Huins trên **FMC+01** đưa cả 5
cặp vào bank 705 (vì vậy Huins ghi "FMC+ 01 Port Only"). `tools/huins_pins.py` từ chối khe
khác cho `CARD=cam` (`[card=cam sites=1]` trong `pins.txt`); với `ANY_SITE=1` (chỉ để thử)
`make plan` dừng và nêu những cổng nằm khác bank với lane clock.

## 4. Build

```bash
make sw                                                     # boot ROM + ứng dụng
make fpga BOARD=huins_vp1902 CARD=cam                       # = make -C hw/fpga/huins_vp1902 CARD=cam
# tài liệu Huins ở chỗ khác (ví dụ worktree khác):
make -C hw/fpga/huins_vp1902 CARD=cam HUINS_DOCS=$HOME/Bow32/docs/fpga/Huins_MFP-VP1902
make -C hw/fpga/huins_vp1902 CARD=cam pins HUINS_DOCS=...   # chỉ sinh XDC chân
make -C hw/fpga/huins_vp1902 CARD=cam plan HUINS_DOCS=...   # XDC chân + sơ đồ nibble (Vivado ~30 s, ~3 GB)
make -C hw/fpga/huins_vp1902 test-plan                      # luật của sơ đồ trên bộ chân giả (tclsh, không cần Vivado)
make -C hw/fpga/huins_vp1902 test-cdc                       # danh sách CDC đã duyệt trên các dòng giả (tclsh)
```

| Biến | Mặc định (`CARD=cam`) | Ý nghĩa |
|------|-----------------------|---------|
| `CARD` | `ram` | `cam`: bản camera (top `bow32_huins_vp1902_cam_top`); `ram`: bản bo RAM ([ddr_huins.md](ddr_huins.md)), không đổi |
| `FMC_SITE` | `1` | khe của camera; khe khác bị từ chối (mục 3) trừ khi `ANY_SITE=1` |
| `CLK_SRC` | `ref200` | dao động 200 MHz cố định của main board (bank 718), như bản bo RAM |
| `JOBS` | `2` | mỗi lần chạy Vivado trên xcvp1902 cần ~15 GB RAM |
| `FLASH_VMEM` | | nạp sẵn một ứng dụng vào flash (đường dẫn tuyệt đối) |
| `CONFIRM` | `0` | `make jtag`: `1` vượt khoá (mục 2, mục 5) |

**Sơ đồ nibble của XPHY.** D-PHY phải biết mỗi cặp MIPI nằm ở nibble và slice nào và strobe
tới từng nibble bằng đường nào (mục 9). Trên bo Huins đó là dữ liệu của sơ đồ chân mật, nên
repo không chứa nó. `make plan CARD=cam` (`make pdi CARD=cam` chạy nó trước khi build) chạy
`tcl/cam_plan.tcl`: đọc XDC chân vừa sinh, mở một design rỗng trên part, lấy bank, nibble và
slice của từng chân từ tên chức năng chân của Vivado, kiểm các luật chuyển strobe của AM010 rồi
ghi `build/fpga/huins_vp1902_cam/pins_fmc1_xphy_plan.txt` (**không bao giờ commit**, như XDC
chân). Console chỉ in tóm tắt: `INFO: cam_plan: bank 705, 4 XPHY nibbles, 4 data lanes -> ...`.
Chân không hợp luật (khác bank, P/N đảo, nibble strobe không tới được) dừng build ở đây với
dòng `ERROR: cam_plan: ...`. `tcl/build.tcl` đưa sơ đồ vào top camera thành các generic
`Dphy*` và dừng khi file thiếu, cũ hơn XDC chân hoặc không đủ. Giá trị mặc định trong RTL
(`bow_dphy_io_versal`, top camera) là một sơ đồ tổng hợp hợp lệ, không phải của Huins: một
build dùng chúng dừng ở `pre_opt_cam`.

Kết quả trong `build/fpga/huins_vp1902_cam/`: `bow32_huins_vp1902_cam.pdi`, `pdi_site.txt` và
các báo cáo. Bản bo RAM vẫn ở `build/fpga/huins_vp1902/`, hai bản không ghi đè nhau. Build tự
kiểm tra và in `CRITICAL WARNING` khi:

| Kiểm tra | File | Phải thấy |
|----------|------|-----------|
| timing | `timing_summary.rpt` | WNS ≥ 0, WHS ≥ 0 (byte clock 180 MHz, video 200 MHz, SoC 50 MHz) |
| clock | `clocks.rpt`, `clock_interaction.rpt` | `clk_sys` 20 ns, `clk_vid` 5 ns, `dphy_hs_clk` 1,389 ns, `dphy_byte_clk` 5,556 ns (trên chân `FIFO_WR_CLK` của XPHY strobe), `dphy_pll_clk` 0,667 ns; mọi cặp clock khác nhau là *Asynchronous Groups* (`tcl/timing_checks_cam.tcl`) |
| bus skew | `bus_skew.rpt` | 11 ràng buộc `set_bus_skew` (FIFO pixel 2, đồng hồ đo byte clock, yêu cầu / trả lời LOG và RAW 4, yêu cầu nạp tap `DLYn` + tap, đọc lại tap `DLYn` từ XPHY, FIFO ra của H.264 2), cả 11 `Slack (MET)`. Cell của bộ thu được chọn theo đuôi tên phân cấp (`get_cells -hierarchical -filter {NAME =~ */...}`), nên ràng buộc đi theo flop khi phân cấp của bộ thu đổi ([ip/mipi_rx_arch.md](ip/mipi_rx_arch.md) mục 10, bước 1); build kiểm cell của từng ràng buộc (`hw/fpga/common/tcl/bus_skew_checks.tcl`: mọi cell trong `u_soc/u_csi2rx`, `u_soc/u_h264/u_out` hay `u_dphy`, mọi flop đích có đường từ nguồn, số flop nguồn bằng số flop đích; log: `INFO: bus skew cells: 0 problems in 11 constraints`). PDI của lần chạy bo 1 (`aaf7ed4`): 11/11, slack +3,781 … +5,016 ns; PDI của bản cuối (`cd289e3`): 11/11, +3,893 … +5,004 ns |
| sơ đồ nibble | `vivado.log` | `INFO: XPHY nibble plan pins_fmc1_xphy_plan.txt: bank 705, 4 XPHY nibbles (generics of bow32_huins_vp1902_cam_top)` |
| XPHY | `io_sites.rpt`, log | trước place: `INFO: pre_opt_cam: 4 XPHYs placed at their pins, nibble plan fits bank 705`; sau route: 4 XPHY đúng các nibble của sơ đồ, lane clock ở slice 0 của XPHY strobe, luật chuyển strobe của AM010 đúng (`tcl/cam_xphy.tcl`) |
| chân | `io_sites.rpt` | 4 `ODDRE1` của I2C (I và T, DRC PDCN-2749) trong `XPIOLOGIC`; 40 flop bắt dữ liệu có `BLI` trong site BLI |
| VCCIO của khe | `io_sites.rpt`, log | 16 cổng ở bank 703..706 (cùng nguồn SW192): 10 chân `MIPI_DPHY` và 5 chân `LVCMOS12` ở bank 705, `PRSNT_M2C_L` ở bank 703, không cổng nào dùng chuẩn khác; `INFO: I/O banks used: ... (16 ports on the FMC+01 site VCCIO, 1.2 V)`. Chỉ kiểm ràng buộc: **không thấy SW192**, switch chỉ kiểm được bằng LED "1.2" và TP29 (mục 2) |
| CDC | `cdc.rpt`, log | mọi mục nghiêm trọng của `report_cdc` (CDC-1, -4, -7, -10 … -14) thuộc các loại đã duyệt ở lần build đầy đủ đầu tiên (`bow32_huins_cam_cdc_known` trong `tcl/timing_checks_cam.tcl`: cấu hình ISP / H.264 gần tĩnh, chân CLR của bộ đồng bộ reset, enable lane của bộ thu: các enable luôn bằng nhau mà synthesis gộp flop, lane 0/1 và lane 2/3, cổng byte clock); mục khác là crossing mới phải xem lại; số mục mỗi loại in ở dòng `INFO: report_cdc ...`. Mục của bộ thu đi theo phân cấp của nó: đường được cắt ở instance `u_csi2rx` đầu tiên (bộ thu `bow_mipi_rx`), phần dưới phải là chỗ đã biết của cell (thanh ghi ở `u_csi2rx/u_regs` của controller, hay `u_regs` trước bước 2; cell D-PHY ở `u_dphy_rx/`, hay ngay dưới bộ thu trước bước 1); flop enable lane và bộ đồng bộ phải thuộc cùng một bộ thu ([ip/mipi_rx_arch.md](ip/mipi_rx_arch.md) mục 10), kiểm bằng `make -C hw/fpga/huins_vp1902 test-cdc` |

Trước place, `tcl/pre_opt_cam.tcl` gán LOC cho từng XPHY theo chân của nó (Vivado không tự đặt
XPHY ngoài IP của AMD: DRC AVAL-314) và kiểm lại, độc lập, sơ đồ của netlist với chân thật,
dừng build nếu không khớp; `tcl/pre_place_cam.tcl` đặt MMCM và toàn bộ SoC vào SLR của camera
(SLR0) và cho phép clock 200 MHz (bank 718, SLR3) đi qua các SLR (`CLOCK_DEDICATED_ROUTE`).

Cảnh báo bình thường (`methodology.rpt` của các PDI 2026-11-10, trước và sau các sửa review, cả
PDI của bản cuối: 45 mục, 1 mục có waiver):

- `TIMING-3` trên `FIFO_WR_CLK` và các chân ẩn `RX_DQS_DIV4` của XPHY: có waiver trong XDC
  (byte clock phải tạo trên chân ra của XPHY, như XDC của AMD);
- `TIMING-47` × 2: `clk_sys` và `clk_vid` ra từ cùng một MMCM (clock đồng bộ) nhưng XDC đặt
  chúng vào hai nhóm bất đồng bộ, cố ý: mọi đường giữa hai miền đi qua bộ đồng bộ, bus gray
  (`set_bus_skew`) hoặc RAM 2 clock, như trên KV260;
- `TIMING-9` × 1 (CDC không rõ): có đường `clk_sys` → `clk_vid` không qua bộ đồng bộ 2 flop;
  đó là các mục CDC-1 / -4 / -13 / -14 của `cdc.rpt` (thanh ghi cấu hình ISP / H.264 gần tĩnh,
  ma trận màu và tỉ lệ capture, đọc thẳng ở `clk_vid`), đã duyệt;
- `LUTAR-1` × 6: LUT lái reset bất đồng bộ của các bộ đồng bộ reset (AND của các mức reset:
  glitch chỉ làm reset sớm, nhả reset vẫn đồng bộ), cùng loại với CDC-10;
- `SYNTH-6` × 32: RAM khối không có thanh ghi ra (FIFO pixel của bộ thu, bộ đệm của ISP và
  H.264...);
- `AVAL-344`: chưa đặt `USER_RAM_AVERAGE_ACTIVITY` (chỉ ảnh hưởng ước tính công suất);
- mức Advisory: `CLKC-58` (XPLL của D-PHY lấy clock từ một BUFG, không có LOC) và `CLKC-75`
  (MMCM, cũng vậy): clock 200 MHz đi qua các SLR (mục *Clock và reset*); `CLKC-72` (MMCM có
  thể thay bằng PLL).

### Clock và reset

| Clock | Tần số | Nguồn |
|-------|--------|-------|
| `clk_sys` | 50 MHz | MMCME5 của `bow32_huins_vp1902_cam_clk` (VCO 3200 MHz = 200 × 16, /64) |
| `clk_vid` | 200 MHz | cùng MMCM (/16): ISP, H.264, máy trạng thái LP của bộ thu, `CTRL_CLK` của XPHY |
| `dphy_pll_clk` | 1500 MHz | XPLL của bank 705 (200 MHz × 15 / 2), BUFG riêng từ đầu vào 200 MHz: BISC, theo dõi VT của XPHY |
| `dphy_byte_clk` | 180 MHz | lane clock (720 MHz DDR) / 4 qua XPHY strobe + BUFGCE; chỉ chạy trong burst HS |

Reset SoC = `USER_RESET_N` (nút "H_RESET") AND MMCM khoá. Miền video và D-PHY reset theo cùng
điều kiện; sau reset D-PHY tự chạy: XPLL khoá → BISC → `PHY_RDY` (LED10; trong mô phỏng
~40 µs, AM010: tới 1,3 ms). `CMD.REINIT` của D-PHY (trước bước 4: PA4) khởi động lại riêng I/O
của D-PHY (mục 5). Trên bản này AFE của D-PHY tự hiệu chỉnh (`INFO[23]` của D-PHY; trước bước 4:
`INFO.DLY_VID` = 1), nên `bow_csi2rx_start()` chờ `AFE_STATUS.READY` tối đa 10 ms rồi mới bật bộ
thu (PHY UltraScale+ của KV260: không chờ).

## 5. Nạp PDI qua JTAG

```bash
make fpga-jtag BOARD=huins_vp1902 CARD=cam        # = make -C hw/fpga/huins_vp1902 CARD=cam jtag
make -C hw/fpga/huins_vp1902 CARD=cam jtag JTAG_SERIAL=210357B8AC4E   # khi có nhiều cáp
```

Như [ddr_huins.md](ddr_huins.md) mục 3 (hw_server cục bộ, LED "PS_DONE" xanh). Trước khi nạp,
`make jtag` in file `pdi_site.txt` và bo phải cắm (mục 2):

```
jtag: bow32_huins_vp1902_cam.pdi was built with CARD=cam FMC_SITE=1 CLK_SRC=ref200
jtag: fit: the Huins camera adapter + LI-IMX274MIPI-FMC on FMC+01 (SW192 = 1.2 V, LED 1.2);
jtag:      the RAM card, if fitted, never on FMC+01 (its site VCCIO is 1.2 V)
...
INFO: [Labtools 27-3439] Successfully programmed PDI file: .../bow32_huins_vp1902_cam.pdi.
INFO: [Labtools 27-3477] DONE bit: HIGH
```

Lần chạy bo 2 (PDI của bản cuối, sha256 bắt đầu bằng `9f3dbea8`): đúng các dòng trên, không cần
`CONFIRM`, nạp 10 s (lần 1: 8 s); console (115200) in ngay `Bow32 boot ROM v1.0.0  chip b0320100
clk 50000000 Hz  rst 1`, `boot: flash image invalid (no image)`, `boot: UART loader ready`. Lần 3
cũng vậy ở cả bốn lần nạp (PDI mặc định hai lần, hai PDI thử của mục 9.1, cùng `pdi_site.txt`).

`make jtag` dùng hw_server ở `localhost:3121`, và Vivado không dùng được hw_server cũ hơn nó. Trên
máy dùng chung cổng này có thể của người khác: ở lần 2, một phiên Vivado 2025.1 của đội khác (đang
rảnh) giữ hw_server 2025.1 ở đó, và Vivado 2025.2 dừng trước khi nạp gì (`make` lỗi, console không
in gì):

```
INFO: [Labtools 27-2285] Connecting to hw_server url TCP:localhost:3121
ERROR: [Labtools 27-3366] Cannot support older hw_server version 2025.1
ERROR: [Common 17-39] 'connect_hw_server' failed due to earlier errors.
```

Khi đó chờ hw_server ấy thoát (thường tự thoát sau khi phiên Vivado của họ đóng), hoặc, khi chủ bo
đã xác nhận bo rảnh (như ở lần 2 và 3), nạp bằng một Vivado cùng phiên bản với hw_server đó, chỉ
làm client của nó (biến `VIVADO` của Makefile, mặc định `vivado`; cùng khoá, cùng PDI). Lần 2 và 3:

```bash
VIVADO=/opt/xilinx/2025.1/Vivado/bin/vivado make -C hw/fpga/huins_vp1902 CARD=cam jtag JTAG_SERIAL=210357B8AC4E
```

in `Successfully programmed PDI file` và `DONE bit: HIGH` như trên. Đừng nạp khi người khác đang
dùng JTAG với bo, và không bao giờ dừng hw_server, cs_server hay xsdb của người khác (lần 2 và 3:
các tiến trình của đội kia chạy tiếp, không đổi). Từ sau lần 2, khi gặp lỗi này `make jtag`
(`tcl/jtag.tcl`) in thêm gợi ý: hw_server nào (người dùng, pid, đường dẫn, phiên bản) đang giữ cổng
đó trên máy này, `VIVADO=<vivado cùng phiên bản>` để nạp như một client, hoặc `HW_SERVER=<host:port>`
của một hw_server cùng phiên bản với Vivado, và nhắc không dừng tiến trình của người khác. Lần 3,
Vivado 2025.2 trước hw_server 2025.1 thật của đội kia (người dùng và pid thay bằng `<...>`):

```
ERROR: [Labtools 27-3366] Cannot support older hw_server version 2025.1
jtag: the hw_server at localhost:3121 is of an older Vivado than this one (2025.2), which cannot
jtag: use it: nothing was loaded. On a shared machine it is most likely another
jtag: user's server, started by their Vivado:
jtag:   hw_server 2025.1 of user <user> (pid <pid>): /opt/xilinx/2025.1/Vivado/bin/unwrapped/lnx64.o/hw_server
jtag: Never stop or signal another user's hw_server, cs_server or xsdb. Wait until it
jtag: exits, or, once the board's owner says the board is free, load as a client of
jtag: that server with a Vivado of its version: the same make command with
jtag:   VIVADO=/opt/xilinx/2025.1/Vivado/bin/vivado
jtag: or point it at a hw_server of Vivado 2025.2 elsewhere: HW_SERVER=<host:port>
```

Không nạp gì, `make` lỗi; cùng lệnh với `VIVADO=` đó thì nạp bình thường. Script nhận ra trường hợp
này từ dòng `Labtools 27-3366` trong log của Vivado hoặc từ phiên bản trong đường dẫn của hw_server
cục bộ; với `HW_SERVER` ở máy khác chưa thử (có thể chỉ có lỗi của Vivado).

Khi bị từ chối nó in `jtag: refused: <lý do>.` và `jtag: check the fitted cards and switches,
then: make jtag CONFIRM=1 CARD=cam`. PDI dựng trước khi có khoá (bản đầu của 2026-11-10) không
có `pdi_site.txt`: build lại, hoặc kiểm bo / switch rồi `make fpga-jtag BOARD=huins_vp1902
CARD=cam CONFIRM=1`; PDI build lại (mục 4) có file này. Image
mất khi tắt bo; boot ROM chờ ở loader khi flash chưa có ứng dụng (`boot: flash image invalid
(no image)`; lần nạp ứng dụng đầu không cần BREAK).

| LED (mặt trước) | Nghĩa |
|-----------------|-------|
| U_LED1..4 | PA0..PA3 (GPIO, sáng khi chân là output 1) |
| U_LED5 | có byte clock của D-PHY trong ~84 ms vừa qua (burst HS của lane clock) |
| U_LED6 | frame ra khỏi ISP: đổi trạng thái mỗi 8 frame |
| U_LED7 | XPLL của bank 705 khoá |
| U_LED8 | PA7 = XCLR: cảm biến ra khỏi reset |
| U_LED9 | nhịp tim 1,5 Hz khi SoC đã ra khỏi reset |
| U_LED10 | D-PHY sẵn sàng (XPLL khoá, BISC xong: `AFE_STATUS.READY` của D-PHY; trước bước 4 `CSI2RX.STATUS.PHY_RDY`) |
| U_LED11 | có một bo trên FMC+01 (`PRSNT_M2C_L` = 0; không phân biệt bo camera với bo RAM) |
| U_LED12 | MMCM khoá (clock SoC và video) |

GPIO (sau reset mọi chân PA là input; từ bước 4 các núm của D-PHY là thanh ghi, không còn GPIO):

| Chân | Việc |
|------|------|
| PA0..PA3 | LED U_LED1..4 |
| PA4, PA5, PA6 | không ra chân (bước 4). Trước bước 4: PA4 = khởi động lại D-PHY (output 1 giữ PHY ở reset khởi động), nay `CMD.REINIT` của D-PHY (xung 32 chu kỳ, `csi2_test`: `phy reinit`); PA5 = `BurstRxRst` (output 1 = reset FIFO RX của XPHY mỗi khi cổng byte clock đóng), nay ¬`CTRL.DES_RST_DIS` của D-PHY: 1 từ reset, firmware ghi lại mỗi lần khởi động bộ thu, `csi2_test`: `phy burstrst 0\|1` |
| **PA7** | XCLR: output 1 = cảm biến chạy; sau reset PA7 là input nên cảm biến bị giữ reset (giống "PA7 = 1 → bật camera" của KV260) |
| PB0 / PB1 | UART1 |
| PB2..PB4 | nút U_PB SW01..03 (1 khi nhấn) |
| **PB5** | `PRSNT_M2C_L` của FMC+01, 0 = có module (khác bản bo RAM, nơi PB5 = 1 nghĩa là có bo) |
| PB6, PB7 | đọc 0 (bước 4). Trước bước 4: `PHY_RDY` và `DLY_RDY` của mọi nibble XPHY, nay `AFE_STATUS[11]` / `[10]` của D-PHY (trạng thái thô, không qua bộ tuần tự khởi động như `AFE_STATUS.READY`, vốn cần thêm XPLL khoá; `DLY_RDY` = 1 mà `PHY_RDY` = 0: hiệu chỉnh xong, `PHY_RDY` không lên), cùng `AFE_STATUS[8]` / `[9]` = XPLL LOCKED / LOCKED_FB |

`AFE_STATUS` đi qua bộ đồng bộ của D-PHY (`rd 40008c18`; trước bước 4 PB6 / PB7 qua bộ đồng bộ
đầu vào của GPIO, `rd 40005000`: bit 6, 7). I2C0 nối thẳng cảm
biến (IMX274 ở địa chỉ 7 bit 0x1A, không có switch I2C; pull-up trong FPGA, chạy ở 100 kHz).

## 6. Nạp và chạy ứng dụng

> Các khối đầu ra trong mục này là **đầu ra thật của lần chạy bo 2** (2026-11-11, PDI và
> firmware `cd289e3`, giống main `458dd33`), chỉ giữ các dòng chính; khối nào không phải (của lần
> 1 hay lần 3, hay cách xử lý khi BISC không xong, chưa cần trên bo) thì có ghi. Những gì firmware
> sau lần 2 đổi (`start`, `cal` ở trễ BISC trong 6.3, `rec` trong 6.5) là đầu ra của lần chạy bo 3
> (2026-11-11, cùng PDI, firmware `5c68b53`). Số của lần 1 (2026-11-10, PDI và firmware `aaf7ed4`,
> trước khi gộp main) chỉ còn ở nơi lần 2 không đo lại, có ghi "lần 1". Mô phỏng của firmware cuối:
> `camera274`, `csi2_274`, `video274`, `h264` ([simulation.md](simulation.md)). `a/b/c/d` là giá
> trị của 4 lane. Ở mục 6, 7 và 9, "lần 1" / "lần 2" / "lần 3" là lần chạy bo 1 / 2 / 3, không phải
> các bước bật nguồn của mục 2.

### 6.1 Nạp và đổi ứng dụng

```bash
PORT=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_<số serial>-if00-port0
make sw                                                     # mọi .bin trong build/sw/
python3 tools/bow32_flash.py -p $PORT flash build/sw/csi2_test/csi2_test.bin   # loader đang chờ sau make jtag
python3 tools/bow32_flash.py -p $PORT monitor               # Ctrl-C để thoát
```

Bridge CP2102N không đưa được SoC về loader bằng BREAK ([ddr_huins.md](ddr_huins.md) mục 6).
Đổi ứng dụng: trong `monitor`, gõ vào ứng dụng đang chạy (`camera`, `csi2_test`, `video` đều
có `wr`):

```
> wr 40000010 4c4f4144     # SYSCTRL.BOOT_FLAG = "LOAD"
> wr 4000000c 52535421     # SYSCTRL.RST_CTRL = "RST!": reset ngay (không có "ok"), ROM ở lại loader
```

rồi Ctrl-C và nạp với `--no-break`:

```bash
python3 tools/bow32_flash.py -p $PORT --no-break flash build/sw/camera/camera.bin
```

Hoặc nạp lại PDI (`make jtag`): flash về trống, boot ROM chờ ở loader.

Cách đổi này dùng được cho mọi lần đổi giữa `csi2_test`, `camera` và `video` ở cả ba lần chạy bo
(`boot: loader requested by firmware`, `boot: UART loader ready`; ở 921600 baud các dòng của boot
ROM, vốn ở 115200, hiện thành byte rác). Reset mềm không reset D-PHY: tap đã nạp vẫn ở đó, ứng dụng
sau bắt đầu với tap mà ứng dụng trước nạp (lần 1: `camera` thấy ngay tap 300/184/264/228 do `cal`
của `csi2_test` nạp); `phy reinit` của `csi2_test` đưa mọi lane về trễ BISC mới (lần 2: `stop`,
`phy reinit` rồi đổi sang `camera`: `info` của `camera` thấy trễ BISC 122/76/118/129). Firmware cuối
luôn hiệu chỉnh ở `cam` đầu của `camera` và `video` (mục 6.4), bắt đầu từ trễ đang dùng.

FIFO nhận của UART0 chỉ có 16 byte: `bow32_cam.py` và `bow32_video.py` gửi mỗi lệnh từng ký
tự và chờ echo. Gõ tay trong `monitor` thì không sao; đừng dán (paste) cả dòng dài hay nhiều
lệnh một lúc khi ứng dụng đang bận (ghi I2C), phần đuôi có thể mất.

### 6.2 Khi khởi động

```
csi2_test: Bow32 MIPI CSI-2 receiver test
camera: IMX274 found (id 0274)
csi2rx: Bow32 receiver, 4 lanes, PHY clock 200 MHz
type h for help
```

`camera` in `Bow32 camera demo (ISP + IMX274), type h for help` rồi hai dòng `camera:` /
`csi2rx:` như trên; `video` in thêm `h264: Bow32 encoder, max width 2048, 4 strips; DMA 2
channels; video RAM 1024 KiB`. `id 0274` là id giả của driver: IMX274 không có thanh ghi chip
ID, `imx274_probe()` reset cảm biến (XCLR = PA7) rồi so các giá trị mặc định sau reset: MDSEL1..4
`03 31 00 09`, HMAX 0x0104, VMAX 0x000906 (cảm biến trên bo, đo lần 1; datasheet ghi 0x000905:
driver nhận cả hai), rồi ghi 0x33 vào BLKLEVEL và đọc lại.

Lần 2: firmware cuối, không sửa gì, in các dòng trên ở cả ba ứng dụng (`camera: IMX274 found (id
0274)`); `rd 40005000` (GPIOB) =
`000000c3`: PB5 = 0 (có module), PB6 = PB7 = 1; trước `cam`, `sr 30f8`, `sr 30f9`, `sr 30fa` của
`camera` đọc `06`, `09`, `00` (VMAX 0x000906 sau reset).

Lần 1: firmware `aaf7ed4` chỉ nhận VMAX 0x905 nên cả ba ứng dụng từ chối cảm biến (I2C trả lời,
PB5 = 0, mọi giá trị khác đúng, đọc burst và từng byte như nhau):

```
camera: no IMX219 on I2C (error -1)
camera: unknown sensor at 0x1a (MDSEL 0331, IMX274 not reset?)
csi2rx: Bow32 receiver, 4 lanes, PHY clock 200 MHz
camera: FMC+01 PRSNT_M2C_L (PB5) = 0: a module is plugged in
```

Với VMAX 0x906 sửa tạm trong probe (chỉ ở worktree của bo), cả ba in đúng khối đầu mục này. XCLR
reset được cảm biến: mỗi lần khởi động sau đó probe lại thấy giá trị sau reset (VMAX 0x906) dù
cảm biến vừa chạy 720p hay 1080p. Firmware cuối nhận 0x905 và 0x906, và khi không khớp in các
giá trị đã đọc thay cho gợi ý XCLR (bảng dưới): mô phỏng `camera274` với VMAX 0x906, `video274`
với 0x905; trên bo lần 2 (0x906).

| Thông báo | Nghĩa, việc cần làm |
|-----------|---------------------|
| `camera: no IMX219 on I2C (error -1)`, `camera: no IMX274 on I2C (error -1)` rồi `camera: FMC+01 PRSNT_M2C_L (PB5) = 1: no module on the site` | không có gì trả lời ở 0x1A, không có bo trên FMC+01 |
| như trên nhưng `PB5 = 0: a module is plugged in` | có bo nhưng cảm biến không trả lời: SW192 (LED "1.2"), XCLR (LED8 phải sáng sau probe), I2C (mục 8) |
| `camera: unknown sensor at 0x1a: MDSEL1..4 .. .. .. .., HMAX ...., VMAX ...... (IMX274 after reset: 03 31 00 09, 0104, 000905 or 000906, BLKLEVEL reads back)` | có thiết bị trả lời ở 0x1A nhưng không có giá trị sau reset của IMX274: dòng in đúng các giá trị đã đọc (thêm `BLKLEVEL 33 read back as ..` khi chỉ phép ghi / đọc lại sai). So với giá trị trong ngoặc: một giá trị lệch ít (như VMAX 0x906 của lần chạy đầu, khi driver chỉ nhận 0x905) là biến thể của cảm biến; mọi giá trị khác hẳn: XCLR (LA22_N, PA7) không reset được cảm biến, hoặc một thiết bị khác ở 0x1A |
| `error: D-PHY not ready (AFE_STATUS.READY = 0)` (sau `start` / `cam`, sau 10 ms; trước bước 4: `(CSI2RX STATUS.PHY_RDY = 0)`) | XPLL + BISC chưa xong: LED7 / LED10, `phy` của `csi2_test`, thử lại BISC (mục 6.3) |
| `csi2rx: Bow32 receiver, no D-PHY in this bitstream - ISP test pattern only` | đang chạy PDI bo RAM → nạp PDI camera |
| `csi2rx: bitstream before the D-PHY split, rebuild it` | PDI trước bước 4 (thanh ghi PHY còn ở controller) với firmware mới: build PDI cùng commit với firmware (mục 4) |

### 6.3 Bring-up bằng `csi2_test`

`csi2_test` mặc định 1080p30 (HMAX 400 / VMAX 6000) và test pattern `tp 3` (màu đơn 555h).
Trên bản Versal (AFE của D-PHY tự hiệu chỉnh, `INFO[23]` của D-PHY) có thêm `phy`, `phy reinit`,
`phy burstrst 0|1` và `sensor on|off` (trên KV260 các lệnh này là `unknown command`). Khối dưới là
lần chạy bo 3 (trước bước 4); từ bước 4 `phy` in `AFE_STATUS` của D-PHY thay cho `STATUS` / PB6 /
PB7 / PA4 / PA5, `phy-idle` của `test` in `LANE_LP` / `LANE_HS` (dòng chú thích `# bước 4:`; bộ
lệnh và mọi kết quả khác không đổi):

```
> phy                     # sau khi nạp PDI: READY, trạng thái thô của XPHY, DES_RST_DIS, trễ BISC
phy: READY 1, every nibble PHY_RDY 1 DLY_RDY 1, XPLL LOCKED 1 LOCKED_FB 1 (AFE_STATUS 00000f01), DES_RST_DIS 0
     delays in use 123/76/119/129    # bước 4; lần 3: phy: STATUS.PHY_RDY 1, ... (PB6 PB7), reinit 0 burstrst 0 (PA4 PA5)
> stat                    # bộ thu tắt, cảm biến ở standby: LP-00 trước stream đầu, đủ 4 lane
csi2rx: no data
  frames 0 lines/frame 0 wc 0 dt 00 sum 00000000 frame errors 000
  errors: ecc 0/0 crc 0 trunc 0 sot 0/0/0/0 ovf 0 misc 0 extra 0 (dropped by DT/VC 0)
  timing: frame 0 us, line 0 ns, byte clock 0 kHz
  phy: lp clk 00 d0 00 d1 00 d2 00 d3 00, bursts 0/0/0/0 clk 0, delay 123/76/119/129
> start                   # bộ thu (DES_RST_DIS = 0, trước bước 4 PA5 = 1; SETTLE 95 ns), cảm biến, link check 16 frame ở trễ BISC
streaming 1920x1080 RAW10, link check failed (ERR_STATUS 008), try cal   # lần 3, vừa nạp lại PDI
  errors in frame 1 of 16 at the delays in use 123/76/120/129: after a PDI load or
  phy reinit these are the BISC delays, early in the eye; cal loads the eye centres
> wr 40008020 1           # lần 3, sau một phy reinit (trễ BISC 123/76/119/130): CNT_CLR, rồi 20 s
> stat                    # 601 frame ở trễ BISC: lỗi CRC (đoạn dưới)
csi2rx: link errors
  frames 601 lines/frame 1080 wc 2400 dt 2b sum 2a257400 frame errors 000
  errors: ecc 0/0 crc 799 trunc 0 sot 0/0/0/0 ovf 0 misc 0 extra 0 (dropped by DT/VC 5409)
  timing: frame 33333 us, line 11100 ns, byte clock 180078 kHz
  phy: lp clk HS d0 HS d1 HS d2 HS d3 HS, bursts 65535/65535/65535/65535 clk 601, delay 123/76/119/130
> log fs                  # 64 packet từ FS (lần 2)
   0 vc0 dt 00 FS    wc 0
   1 vc0 dt 12 EMB   wc 175
   2 vc0 dt 37 OB    wc 2400
  ...                     # 8 dòng OB (dt 37), rồi các dòng RAW10
  10 vc0 dt 2b RAW10 wc 2400 accepted
> raw                     # 64 word thô mỗi lane từ burst kế tiếp (lần 2: short packet FS rồi trail)
lane 0: 00 00 00 00 00 00 00 00 00 00 00 00 00 70 01 fe
        ff ff ff ff ff ff ff ff ff ff ff ff f7 eb ff 23
  ...
        sync byte at bit 105 (word 13 + 1)
lane 1: 00 00 00 00 00 00 00 00 00 00 00 00 00 b8 00 ff
        ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
  ...
        sync byte at bit 104 (word 13 + 0)
  ...                     # lane 2, 3 như lane 0: bit 105 (word 13 + 1)
> cal 8                   # bản đồ eye từng lane, bắt đầu từ trễ đang dùng (BISC); nạp tap (lần 3)
delays in use 123/76/119/130: link errors      # có lỗi: quét chung 4 lane trước
lanes |.###...###.###..##############################...##...#...##....| tap 244 width 240
lane0 |---------------.############################################.---| tap 300 width 352 (others at 244 244 244)
lane1 |.#############################################.-----------------| tap 184 width 360 (others at 300 244 244)
lane2 |----------.############################################.--------| tap 260 width 352 (others at 300 184 244)
lane3 |------.############################################.------------| tap 228 width 352 (others at 300 184 260)
csi2rx: calibrated taps 300/184/260/228 eye 352/360/352/352
> wr 40008020 1           # CNT_CLR, rồi 3 s
> stat
csi2rx: link ok
  frames 91 lines/frame 1080 wc 2400 dt 2b sum 2a257400 frame errors 000
  errors: ecc 0/0 crc 0 trunc 0 sot 0/0/0/0 ovf 0 misc 0 extra 0 (dropped by DT/VC 819)
  timing: frame 33333 us, line 11120 ns, byte clock 180078 kHz
  phy: lp clk HS d0 11 d1 11 d2 11 d3 11, bursts 65535/65535/65535/65535 clk 91, delay 300/184/260/228
> test                    # mọi check: 1080p30 rồi 720p60 (HMAX 300 / VMAX 4000); lần 2: 37 s
csi2_test: 1920x1080, frame 33333 us, 60 frames per check, calibration step 8
[PASS] phy-idle all lanes LP-11, no HS (LANE_LP 3ff LANE_HS 00000)   # bước 4; lần 3: (STATUS 0f403f)
[PASS] link-up bursts 2/2/2/2, clock lane 1
...                       # bản đồ eye như cal 8 (từ tap đang dùng: link ok)
[PASS] calibrate taps 300/184/260/228 eye 352/360/352/352
...                       # tâm rồi ±k của từng lane, 60 frame mỗi điểm
[PASS] margin +-88/+-90/+-88/+-88 taps: 0 errors in 9 x 60 frames, BER < 1.0e-8
[PASS] integrity 2 x 60 frames 1920x1080 RAW10: wc 2400, sum 2a257400 (555h, mean 341) 544ae800 (AAAh, mean 682)
[PASS] packets FS, embedded data (1), OB lines (8), lines, FE: headers and CRC ok; frame numbers not used
[PASS] timing frame 33333 us, line 11120 ns, byte clock 180078 kHz
csi2_test: 1280x720, frame 16666 us, 60 frames per check, calibration step 8
...                       # 720p60: link-up, taps 300/184/264/228, margin +-88/+-90/+-90/+-88 (BER < 2.2e-8),
...                       # sum 12bb5000 / 2576a000, OB lines (4), frame 16666 us, line 8340 ns
[PASS] isp colour bars f9f9f9 ffff0b ffff00 00ffff 00ff11 00ff00 ff00ff ff001c (6 colours), 555h grey 145, capture 160x90 (scale 3)
[PASS] filter VC 1: no line, 43500 packets dropped in 60 frame periods; VC 0: frames resume
[PASS] restart 3 x stop/start at random phases, frames resume without errors
[PASS] irq 60 FS interrupts in 60 frames
csi2_test: PASS (17/17)
```

Ở trễ BISC luôn có lỗi CRC (ECC, SOT, `extra` 0), nhiều hay ít tuỳ trễ BISC của lần khởi động đó
(mục 9): lần 3 799 dòng trong 601 frame (1,33 mỗi frame, khối trên) và 4422 dòng trong 91 frame ở
122/75/118/130 (lane 0 cách chỗ chuyển bit 2 tap); lần 2 13 dòng trong 64 frame, 78 trong 151 frame
(`frame errors 008`: CRC), 133 trong 90 frame sau một `phy reinit`, tức 0,2–1,5 dòng mỗi frame
1080p; lần 1 ~11 % số dòng (119–148 dòng mỗi frame). Link check của firmware lần 2 chỉ đếm 64 packet
(~6 % một frame 1080p), nên ở lần 2 nó hai lần in `link check ok` ở trễ BISC: **`link check ok` ở
trễ BISC không có nghĩa là trễ BISC tốt**. Firmware sau lần 2 kiểm 16 frame nguyên
(`bow_csi2rx_link_check_frames()`, ~0,55 s ở 1080p30; 0,2 lỗi mỗi frame bị thấy 96 % số lần): khi
có lỗi do tap, `start` in `link check failed (ERR_STATUS 008), try cal`, và trên bản Versal thêm
`errors in frame k of 16 at the delays in use a/b/c/d: after a PDI load or phy reinit these are
the BISC delays, early in the eye; cal loads the eye centres` (mô phỏng `csi2_274`: một lỗi CRC ở
frame 6, sau 64 packet đầu). Lần 3, sau khi nạp PDI hay `phy reinit`, `start` in đúng các dòng đó
cả 7 / 7 lần (PDI mặc định và PDI thử B; lỗi đầu ở frame 1, 4, 14, 1, 1, 1, 1 của 16); trên PDI
thử A (trễ BISC gần tâm, mục 9) nó in `link check ok`. `cal` cũng thử trễ đang dùng trước: `link
ok` thì bỏ lượt quét chung `lanes |...|` (lần 2, khi 64 packet ở trễ BISC tình cờ sạch), `link
errors` thì quét chung trước (lần 1 và 3: `tap 244 width 240`); tâm như nhau. Trễ BISC nằm ở mép
sớm (tap thấp) của eye trên mọi lane (mục 9): luôn `cal 8` sau `start` đầu (sau khi nạp PDI hay
`phy reinit`), rồi `stat` (cả ba lần: 0 lỗi sau `cal`); tap và eye của `cal 8` như nhau ở cả ba lần
(±4 tap). Tổng 555h / AAAh đúng từng bit như lần 1 (0x155 / 0x2AA × 2 073 600 pixel: không cộng
BLKLEVEL); `tp 11` qua ISP ở 720p chỉ thấy 6 trong 8 sọc (mục 6.4). `raw` của lần 2 bắt được burst
của short packet FS (sau byte sync mỗi lane một byte của packet, rồi trail); lần 1 bắt được một dòng
555h (`aa` / `55`). Lệch giữa các lane như lần 1: lane 1 sớm hơn 1 bit.

So với lần 1, firmware cuối in thêm (PR #17): dòng `frames` của `stat` có `frame errors`
(`FRAME_ERR` của frame cuối), dòng `errors` có `extra` và `(dropped by DT/VC n)` thay cho `drop n`:
số packet bị bộ lọc DT bỏ tăng 9 mỗi frame ở 1080p (1 dòng embedded + 8 dòng optical black), 5 ở
720p (1 + 4), bình thường (bộ đếm 16 bit: dừng ở 65535 sau ~4 phút ở 1080p30, như `bursts`). Khi bộ
thu tắt (`stop`, `sensor on`) `stat` liệt kê cả 4 lane của bản build (khối trên; firmware của lần 1
chỉ in 2: `sot 0/0`, `d0 .. d1 ..`, `bursts a/b`, `delay a/b`, vì đọc số lane từ `CTRL` đã xoá).
Khi link check thấy lỗi, `start` in `streaming 1920x1080 RAW10, link check failed (ERR_STATUS
008), try cal` (bit 3: CRC; định dạng của PR #17; firmware sau lần 2 thêm hai dòng gợi ý trên bản
Versal: khối trên, lần 3). `test` chạy phy-idle; link-up, calibrate, margin (AAAh: IMX274 không
có PN9), integrity (555h rồi AAAh), packets, timing ở 1080p30 rồi 720p60; isp, filter, restart,
irq: 17 check (IMX274 không có RAW8); firmware của lần 1 chưa có check `margin`: 15/15 trong 9,9 s. Lệnh `margin [k] [frames]` (cần một lần `cal` trước) đo quanh
trễ **đang dùng** của mọi lane (sau `delay`, hay trễ BISC sau `phy reinit`), k theo eye của lần
`cal` cuối. Lần 2, ở 1080p30 (AAAh, tap của `cal`), rồi với một tap đặt bằng tay:

```
> margin                  # 60 frame ở trễ đang dùng và ở ±k của từng lane (k = eye / 4); tap giữ nguyên
margin centre taps 300/184/264/228: 60 frames, 0 errors, 3.1e8 bits (64467 lines), BER < 1.0e-8
margin lane0 -88 tap 212: 60 frames, 0 errors, 3.1e8 bits (64800 lines), BER < 1.0e-8
margin lane0 +88 tap 388: 60 frames, 0 errors, 3.1e8 bits (64800 lines), BER < 1.0e-8
...                       # lane1 -90/+90 (tap 94, 274), lane2 -90/+90 (174, 354), lane3 -88/+88 (140, 316)
csi2rx: margin ok +-88/+-90/+-90/+-88 taps: 0 errors in 9 x 60 frames, BER < 1.0e-8
> delay 2 240             # đặt tap 0..511 của một lane bằng tay
lane 2 tap 240: in use
> margin 32 1             # tâm là tap đang dùng của mọi lane, cả lane 2
margin centre taps 300/184/240/228: 1 frames, 0 errors, 4.1e6 bits (855 lines), BER < 7.3e-7
...                       # lane 2: tap 208 và 272
csi2rx: margin ok +-32/+-32/+-32/+-32 taps: 0 errors in 9 x 1 frames, BER < 7.3e-7
> stat                    # lane 2 vẫn ở tap đặt bằng tay
  ...
  phy: lp clk HS d0 HS d1 HS d2 HS d3 HS, bursts 2219/2219/2219/2219 clk 3, delay 300/184/240/228
> cal 8                   # tap hiệu chỉnh trở lại: 300/184/264/228, link ok
```

`margin` 60 frame mỗi điểm mất ~18 s ở 1080p30; điểm tâm đếm ít dòng hơn (64467 thay cho 64800) vì
nó bắt đầu giữa một frame.

`mode 1080p`, `mode 720p`, `mode <w> <h> [fps]` đổi kích thước; `mode 4k` bị từ chối (`error: a
3840 pixel line leaves ~630 groups in the receiver FIFO, it has 512 (4K: 1024 needed)`). Ghi lại:
trễ BISC của từng lane, trạng thái lane ở standby, các dòng `[PASS]` (tổng và mean của 555h /
AAAh, màu của sọc, mức xám), tap và độ rộng eye của `cal 8`.

**Khi BISC không xong** (`start` → `error: D-PHY not ready ...` và gợi ý `phy: nibble status;
sensor on + phy reinit: BISC with a running clock`; LED7 sáng, LED10 tắt). Lúc PDI nạp, cảm
biến còn bị reset và các lane ở LP-00; nếu BISC cần strobe đang chạy, cho cảm biến stream mà
chưa bật bộ thu rồi khởi động lại PHY (cách xử lý; lần 1 và lần 2 không cần, xem dưới khối):

```
> phy                     # DLY_RDY 1, PHY_RDY 0: hiệu chỉnh xong, PHY_RDY không lên; cả hai 0: BISC chưa xong
> sensor on               # cảm biến stream, bộ thu tắt: lane clock chạy
sensor: streaming 1920x1080, receiver off (READY 0)
> phy reinit              # CMD.REINIT (xung 32 chu kỳ; trước bước 4 xung PA4 10 us): XPLL khoá + BISC lại, có strobe
phy: READY n us after CMD.REINIT
phy: READY 1, every nibble PHY_RDY 1 DLY_RDY 1, XPLL LOCKED 1 LOCKED_FB 1 (AFE_STATUS 00000f01), DES_RST_DIS 0
     delays in use a/b/c/d
> start                   # dừng cảm biến, bật bộ thu, chạy lại cảm biến
```

`phy reinit` cũng dùng được lúc đang stream (in thêm `phy: the receiver ran through it:
start`: gõ `start`); nó bỏ mọi tap đã nạp (lane về trễ BISC mới, theo dõi VT bật lại).
`phy: READY still 0 10 ms after CMD.REINIT`: xem VCCIO (SW192), LED7. `error: AFE_STATUS.READY
stayed 1 after CMD.REINIT (no re-init in this PHY?)`: PHY không có re-init (READY không xuống trong
20 µs) → kiểm PDI (trước bước 4 các thông báo là `phy: PHY_RDY ... after the reinit pulse` và `error:
PHY_RDY stayed 1 during the reinit pulse (no PA4 knob ...)`). `sensor off` đưa cảm biến về standby. Sau `sensor on` bộ thu tắt: `cal`, `log` và
`raw` báo `error: receiver off (sensor on): start`. Cả ba lần không cần cách này:
`PHY_RDY` = 1 ngay sau khi nạp PDI (PB6 = PB7 = 1). `phy reinit` khi cảm biến ở standby (trước
stream đầu, hay sau `stop`): lần 2 `phy: PHY_RDY 76 us after the reinit pulse` (75–76 µs) cả ba
lần, trễ 123/76/119/129 (hai lần) và 122/76/118/129; lần 1 cũng 75–76 µs, trễ 122/75/118/130 hoặc
123/76/120/129; lần 3 (PDI mặc định) 75–112 µs, trễ sau khi nạp và sau mỗi `phy reinit` trong
122–124/75–76/118–120/129–130. Lần 1 còn thử sau `sensor on` (lane clock chạy, `sensor: streaming
1920x1080, receiver off (PHY_RDY 1)`): vẫn 75 µs và 122/75/118/130, tức BISC không cần strobe đang
chạy, và có strobe cũng không đặt trễ khác; lần 3 `phy reinit` lúc đang stream cho cùng trễ như
lúc nghỉ trên cả ba PDI.

**`BurstRxRst` và SETTLE.** Firmware giữ `BurstRxRst` = 1 (FIFO RX của XPHY bắt đầu lại mỗi
burst): từ bước 4 là `CTRL.DES_RST_DIS` = 0 của D-PHY (giá trị reset, ghi lại mỗi lần khởi động bộ
thu), trước đó PA5 = 1; và giữ `SETTLE` 95 ns. Các lần đo dưới đây (trước bước 4) gọi nó là PA5. Đo trên bo lần 1 (720p60, tap đã hiệu chỉnh): với PA5 = 1,
`SETTLE` 95 ns chạy 4462 frame (hơn 3,2 triệu burst) không lỗi, và mọi `SETTLE` từ 13 tới 34 chu kỳ
(65–170 ns) đều sạch; 8–12 chu kỳ có lỗi misc (SKEW / FRAME), 35 chu kỳ có lỗi SOT, từ 36 chu kỳ
không còn frame. 95 ns cách mép dưới 30 ns (tâm cửa sổ ~118 ns). Với PA5 = 0 (`phy burstrst 0`) link
chỉ sạch tới lần bật lại bộ thu đầu tiên trong lúc stream; sau đó lane 0 hỏng hẳn (`ERR_STATUS` 14b:
SOT, ECC_CORR, CRC, SKEW, FRAME; `misc` 255 mỗi giây, mất frame) ở mọi `SETTLE` đã thử (50–150 ns)
và chỉ hết khi PA5 = 1 lại. **Không dùng `BurstRxRst` = 0 (PA5 = 0, từ bước 4 `phy burstrst 0`)
trên bo.** Firmware cuối không đổi gì ở đây: mỗi lần khởi động bộ thu đặt `BurstRxRst` = 1 và
`SETTLE` 95 ns (mô phỏng `csi2_274`: testbench kiểm `burst_rst_en` của D-PHY và `rd 40008c24` sau
`test`; trước bước 4 chân PA5 và `rd 4000800c`). Lần 2 (RTL đã gộp main): sau `start`, `phy` in `burstrst 1` và `rd
4000800c` = `051e0213`; quét lại `SETTLE` (720p60, PA5 = 1, tap đã hiệu chỉnh, 3 s ≈ 180 frame mỗi
giá trị) cho đúng cửa sổ của lần 1: 13, 16, 19, 23, 27, 30, 34 chu kỳ (65–170 ns) sạch; 12 chu kỳ
`misc 31`; 35 chu kỳ `sot 0/0/0/1`, `misc 2`. Mô phỏng trước đó dự đoán cửa sổ ~80–116 ns với
PA5 = 1 và cho rằng PA5 = 0 chạy được với `SETTLE` ~115 ns: silicon khác
([ip/csi2rx.md](ip/csi2rx.md), mục *Bốn lane, PHY Versal và IMX274*). `SETTLE` là `TIM0[7:0]` của
D-PHY (`0x4000_8C24`, chu kỳ 5 ns; trước bước 4 `PHY_CFG[7:0]` ở `0x4000_800C`, cùng bố cục), chỉ
đổi được khi `PHY_EN` = 0, và `start` / `mode` ghi lại giá trị của driver: quét lại theo các lệnh
dưới đây (giữ `BurstRxRst` = 1).

```
> start
> rd 40008008              # CTRL của driver (lần 2): 00c02b87 (EXTRA 192, DT 0x2B, 4 lane, PHY_EN, RX_EN; lần 1: 00002b87)
> rd 40008c24              # TIM0 của D-PHY: 051e0213 (SETTLE 0x13 = 19 chu kỳ = 95 ns; lần 2: rd 4000800c, PHY_CFG)
> wr 40008008 c02b84       # CTRL: tắt PHY_EN, RX_EN, giữ các trường khác
> wr 40008c24 051e0217     # SETTLE 0x17 = 23 chu kỳ = 115 ns, các trường khác như driver
> wr 40008008 c02b87       # bật lại PHY_EN, RX_EN
> wr 40008020 1            # CNT_CLR (controller)
> wr 40008c10 8            # CMD.CNT_CLR (bộ đếm của D-PHY)
> stat
```

Tuỳ chọn build `CAM_BURST_RST=0` cùng `DPHY_SETTLE_NS=140u` (đích 140 ns → `SETTLE` 23 = 115 ns;
`sw/common/include/cam_sensor.h`, `sw/common/src/cam_sensor.c`, `sw/common/src/bow_dphy_rx.c`: mọi
lần khởi động bộ thu ghi `DES_RST_DIS` = 1; trước bước 4 `SETTLE_VID_NS=115` và PA5 = 0) chỉ còn cho mô phỏng:
`make -C sim run TEST=csi2_274 FW=brst0` (cũng trong `make -C sim test-extra`) chạy sạch trên mô
hình PHY, bo thật thì không.

**`CTRL.EXTRA` (trail sau packet).** `bow_csi2rx_start()` đặt `CTRL.EXTRA` 192 byte cho 4 lane trên
Versal (`rd 40008008` = `00c02b87`); bộ thu báo `extra` khi sau một packet trong cùng burst có nhiều
byte hơn thế ([ip/csi2rx.md](ip/csi2rx.md), mục *Lớp packet*). Với 192, mọi `stat` / `csi` của lần
2 có `extra 0`, `CNT_EXT` (`rd 40008048`) và `ERR_STATUS` (`rd 4000801c`) 0: 1305 frame 720p60 và
301 frame 1080p30 ngay sau `test`, 9012 frame của lần chạy 5 phút, các phiên `camera` và `video`.
Lần 2 đo trail thật của IMX274 + XPHY bằng cách quét `CTRL.EXTRA` lúc stream (tap đã hiệu chỉnh, 2 s
mỗi giá trị; `start` ghi lại `CTRL` của driver):

```
> wr 40008008 c02b85       # CTRL: tắt RX_EN (PHY_EN, PHY_CFG và tap giữ nguyên)
> wr 40008008 302b85       # EXTRA 0x30 = 48 byte
> wr 40008008 302b87       # bật lại RX_EN
> wr 4000801c fff          # xoá ERR_STATUS (W1C)
> wr 40008020 1            # CNT_CLR, chờ 2 s
> stat                     # 1080p30, EXTRA 48: dưới trail
csi2rx: link errors
  frames 61 lines/frame 1080 wc 2400 dt 2b sum 00000000 frame errors c00
  errors: ecc 0/0 crc 0 trunc 0 sot 0/0/0/0 ovf 0 misc 61 extra 64841 (dropped by DT/VC 549)
  no LP-11 between packets? (bytes after packets: dropped)
  ...
> rd 40008048              # CNT_EXT[15:0] dừng ở 65535
40008048: 0000ffff
```

Ở 1080p30, EXTRA 192, 176, …, 80, 64 sạch (60 frame mỗi giá trị, `CNT_EXT` 0), 48 và 32 hỏng; ở
720p60, 64, 60, 56, 52 sạch (121 frame), 48 hỏng. Trail là 49–52 byte trên 4 lane (~13 byte clock):
192 của driver dư 140 byte, giá trị reset 64 chỉ dư 12. Dưới trail không chỉ là cờ: mọi burst báo
EXTRA, và vì các burst EMB / OB đến trước dòng đầu nên **mọi frame bị bỏ** (`frame errors c00` =
EXTRA + SKIP, `misc` +1 mỗi frame, `sum 00000000`).

### 6.4 Ứng dụng `camera`

```
> cam                      # 1080p30 RGGB (HMAX 400 / VMAX 6000): ISP, bộ thu, cảm biến, hiệu chỉnh, lề
csi2rx: calibrated taps 296/184/264/224 eye 352/352/352/336
csi2rx: margin ok +-88/+-88/+-88/+-84 taps: 0 errors in 9 x 8 frames, BER < 7.3e-8
streaming 1920x1080 RGGB
> csi                      # trạng thái bộ thu như stat của csi2_test
csi2rx: link ok
  frames 1 lines/frame 1080 wc 2400 dt 2b sum 08107b93 frame errors 000
  errors: ecc 0/0 crc 0 trunc 0 sot 0/0/0/0 ovf 0 misc 0 extra 0 (dropped by DT/VC 9)
  ...
  phy: lp clk 11 d0 11 d1 11 d2 11 d3 11, bursts 1091/1091/1091/1091 clk 1, delay 296/184/264/224
> margin                   # lề quanh tap đang dùng, k = eye / 4, 60 frame mỗi điểm
margin centre taps 296/184/264/224: 60 frames, 0 errors, 3.0e8 bits (64331 lines), BER < 1.0e-8
...                        # lane0 tap 208, 384; lane1 96, 272; lane2 176, 352; lane3 140, 308
csi2rx: margin ok +-88/+-88/+-88/+-84 taps: 0 errors in 9 x 60 frames, BER < 1.0e-8
> ae on                    # auto exposure (SHR, rồi gain)
> awb on                   # white balance gray world
ae: locked exp=5992 gain=1453 mean=172
awb: locked r=418 b=458
> info                     # ISP, mode (HMAX, VMAX, fps), cảm biến, AE/AWB, bộ thu (6 s sau ae on)
ISP    id 49535001 ctrl 1 status 00 frames 1570 size 1920x1080 input 1920x1080 modules 1f
mode   1920x1080, HMAX 400, VMAX 6000 = 30 fps
sensor IMX274  exp 5992 gain 1453  tp 0  flip 0/0
ae on (target 180)  awb on (r 418 b 458)  source camera
csi2rx: link ok
  ...
> stat                     # thống kê frame kế tiếp
frame 1573 in 1920x1080  mean R/G/B 148/146/148 (2008413 px)  Y 173  af 14850749  dpc 88
> mode 720p                # 1280x720 @60 fps
mode 1280x720 @60 fps (HMAX 300 VMAX 4000)
streaming 1280x720 RGGB
> mode 1080p
mode 1920x1080 @30 fps (HMAX 400 VMAX 6000)
streaming 1920x1080 RGGB
> mode 4k                  # bị từ chối: ISP tối đa 2048 pixel (chưa thử trên bo)
error: size must be even, 16..2048 x 8..2174
> tp 11                    # sọc màu của cảm biến (0 tắt, 1..4 màu đơn 000/FFF/555/AAA, 12 sọc ngang)
> exp 2000                 # exposure theo chu kỳ HMAX (tắt AE)
> gain 0                   # 0..1957, gain = 2048 / (2048 - code)
> flip 0 1                 # lật dọc (IMX274 không có lật ngang: flip 1 0 bị từ chối)
> rd 40006028              # ISP BAYER: 0 = RGGB (lần 1, firmware cũ: 00000002 = GBRG, sai)
40006028: 00000000
> cal                      # hiệu chỉnh lại eye (bước 16)
```

`cam`: cấu hình ISP → `bow_csi2rx_start(4, RAW10, 1440 Mbit/s)` khi IMX274 còn ở standby
(LP-00; hàm chờ `PHY_RDY`) → bước 1 của chuỗi thoát standby qua I2C 100 kHz (~26 ms) → ISP →
stream (chờ 11 + 8 ms; frame đầu không được xuất) → hiệu chỉnh → kiểm tra lề (8 frame mỗi điểm,
dòng `margin ok`, PR #17). `cam` **đầu tiên luôn hiệu chỉnh**, trên bản Versal cũng vậy: trễ BISC
nằm ở mép sớm của eye trên mọi lane (tâm eye sau hiệu chỉnh cao hơn trễ BISC +98…+178 tap, tức
0,26–0,48 UI; lane 0 sát chỗ chuyển bit; lỗi CRC ở trễ BISC: lần 1 ~11 % dòng, lần 2 0,2–1,5 và
lần 3 1,3–49 dòng mỗi frame 1080p, mục 9), và 64 packet sạch của một link check có thể là may (lần
2: `start` của `csi2_test` in `link check ok` ở trễ BISC, mục 6.3). Lần 2, với trễ BISC mới
(122/76/118/129 sau `phy reinit` của `csi2_test`, mục 6.1): `cam` đầu in đúng khối trên trong 2,7
s, không có dòng `kept`, frame đầu tốt (`csi`: 1 frame, 1091 burst, 0 lỗi), tap và eye như lần 1
sau `phy reinit`; app `video` cũng vậy (mục 6.5).
Firmware của lần 1 chỉ hiệu chỉnh khi link check thấy lỗi, nên khi `camera` chạy ngay sau
`csi2_test` (tap còn từ `cal`) nó giữ chúng: `csi2rx: link ok with the delays in use
300/184/264/228 (kept; cal calibrates)`. Sau `cam` đầu app giữ tap và chỉ hiệu chỉnh lại khi link
check thấy lỗi lấy mẫu (`CSI2RX_ERR_TAP`) hay không có dữ liệu; lỗi khác (EXTRA, FORMAT, FRAME,
OVF) giữ tap (`taps kept`). Mỗi tap nạp làm lane đó thôi theo dõi VT (mục 9), nên sau khi bo nóng
lên hãy xem lại `csi` (`cal` hiệu chỉnh lại; lần 2: 5 phút 1080p30, 9012 frame, 0 lỗi, tap không
đổi; lần 1: 0 lỗi trong ~15 phút; lần 3: 30 phút bằng `csi2_test`, bảng dưới; chưa thử nóng /
nguội, chưa chạy lâu với app `camera`). `margin [k] [frames]` đo quanh trễ đang
dùng của mọi lane: sau hiệu chỉnh là tap đã hiệu chỉnh (k = eye / 4; lần 2: khối trên, `csi` sau đó
vẫn ở 296/184/264/224); nếu lần hiệu chỉnh đầu thất bại thì quanh trễ lane đang giữ, k = 40
(`csi2rx: not calibrated: margin around the delays in use ...`), không bao giờ nạp tap 0. Trước
`cam` (lần 2): `margin` in `error: the camera is not streaming (cam)` và không nạp tap nào (`csi`:
`no data`, 4 lane ở LP-00, delay 122/76/118/129). `stop`, `mode`, `tpg`: IMX274 vào standby là cắt
ngang frame, nên app chờ hết frame, tắt bộ thu rồi mới đưa cảm biến về standby.

Độ ổn định (lần 3): `csi2_test` stream cảnh thật (`tp 0`) ở 1080p30 với tap của `cal 8`
(296/184/264/224, eye 344/360/344/344), `stat` và `phy` mỗi 5 phút:

| t (phút) | frame | lỗi (ecc, crc, trunc, sot × 4, ovf, misc, extra) | tap | `PHY_RDY` |
|----------|-------|--------------------------------------------------|-----|-----------|
| 0 | 0 | 0 | 296/184/264/224 | 1 |
| 5 | 9 000 | 0 | như trên | 1 |
| 10 | 18 000 | 0 | như trên | 1 |
| 15 | 27 000 | 0 | như trên | 1 |
| 20 | 35 999 | 0 | như trên | 1 |
| 25 | 45 000 | 0 | như trên | 1 |
| 30 | 53 999 | 0 | như trên | 1 |

Cuối lần chạy: `margin ok +-86/+-90/+-86/+-86 taps: 0 errors in 9 x 60 frames, BER < 1.0e-8`; `cal
8` cho 300/184/264/224, eye 352/360/344/344: chỉ mép trên của lane 0 dời một bước 8 tap, không trôi.
Ở t = 0, ngay sau khi xoá bộ đếm và trước khi frame đầu kết thúc, `stat` in `csi2rx: link errors`
dù mọi bộ đếm là 0: lỗi chữ của firmware (việc còn mở, mục 7).

AE/AWB ghi cảm biến tối đa một lần mỗi frame và **dừng khi test pattern của cảm biến bật** (`tp`
khác 0): test pattern không đổi theo exposure / gain / white balance. Ở lần 1 (firmware cũ) AE đã
đẩy exposure xuống 1 khi `tp 11` ở 720p (`sensor IMX274  exp 1 gain 0`) và các frame đầu sau `tp 0`
đen (`mean R/G/B 0/0/0 ... Y 0`) tới khi AE tăng lại (~1 s). Lần 2, cùng phép thử ở 720p60:

```
> mode 720p
> ae on
> awb on
ae: locked exp=3992 gain=1742 mean=177
awb: locked r=407 b=429
> stat
frame 3408 in 1280x720  mean R/G/B 151/150/144 (894397 px)  Y 174  af 8629495  dpc 84
> tp 11                    # 5 s và 10 s sau, info in cùng các số
> info
...
sensor IMX274  exp 3992 gain 1742  tp 11  flip 0/0
ae on (target 180)  awb on (r 407 b 429)  source camera
...
> tp 0
> stat                     # frame kế tiếp: cảnh thật, không đen
frame 4016 in 1280x720  mean R/G/B 149/148/142 (894613 px)  Y 172  af 8616222  dpc 84
```

2 s sau, `stat` vẫn 149/148/142, Y 172, và `info` vẫn `exp 3992 gain 1742`, `awb on (r 407 b
429)`: AE/AWB đứng yên khi test pattern bật rồi chạy tiếp từ giá trị cũ.

AE trên cảnh văn phòng: lần 2 (buổi sáng) 1080p30 exp 5992 (tối đa của mode) gain 1363–1497
(3,0–3,7×), `stat` Y 173–186 (đích 180); 720p60 exp 3992 (tối đa) gain 1742 (6,7×), Y 172–174. Lần
1: 1080p30 gain 1576–1582 (~4,3×), Y 182; 720p60 gain 1792 (8×, giới hạn của AE), Y 168–169
(`ae: locked exp=3992 gain=1792 mean=169`). Ảnh đủ sáng, nhiễu màu ở vùng tối (gain cao, chưa có
khử nhiễu).

Ảnh về PC (đóng `monitor` trước):

```bash
python3 tools/bow32_cam.py -p $PORT --fast 921600 cmd cam "ae on" "awb on"
python3 tools/bow32_cam.py -p $PORT -b 921600 snap -o frame.png                # 240x135 ở 1080p, 160x90 ở 720p
python3 tools/bow32_cam.py -p $PORT -b 921600 snap -o crop.png --center 240 135   # 1:1 giữa ảnh
```

Ở cả hai lần 921600 baud chạy được, ~1,3 s một ảnh 240×135 (0,6 s ở 160×90); `--center 240 135`
là `cap 840 472 240 135 0` ở 1080p, `cap 520 292 240 135 0` ở 720p. `tp 11` ra 8 sọc dọc đúng thứ
tự (trắng, vàng, cyan, xanh lá, magenta, đỏ, xanh dương, đen; trong mỗi sọc không nhiễu; lần 2 với
WB 256/256: mỗi sọc 30 px trong ảnh 240×135, trắng 249,249,249) ở 1080p; cửa sổ 720p (mode 5) chỉ
phủ ~3/4 chiều ngang của mẫu: 6 sọc đầu (lần 2: trắng … magenta, rồi 10 px đỏ). `tp 12` ở 1080p: 4
sọc ngang đầu và một phần sọc thứ 5 (cửa sổ 1080 dòng). Cảnh thật của lần 2 (văn phòng; ảnh không
nằm trong repo): mean R/G/B 100,6/98,0/100,6 ở 1080p, 96,5/95,3/95,8 ở 720p, màu tự nhiên, không
có dòng hỏng; crop 1:1 giữa ảnh có nhiễu ở vùng tối (gain cao), nhiều hơn ở 720p.

Khi lật dọc (`flip 0 1`) thứ tự Bayer vẫn là RGGB, như driver Linux: đo trên bo lần 1 (cảnh thật
và sọc màu đúng với RGGB; GBRG, phỏng đoán cũ của driver, cho ảnh tím, mean RGB 140/9/149; BGGR
đổi R và B), và `imx274_bayer()` của firmware cuối trả RGGB với cả hai (mô phỏng `camera274`: ISP
`BAYER` 0 và sọc màu đúng sau `flip 0 1`). Lần 2 (1080p30, AE và AWB tắt để so: exp 5992, gain
1442, WB r 413 b 446): `rd 40006028` = `00000000` sau `flip 0 1` và sau `flip 0 0`; mean RGB của
ảnh lật 96,9/96,3/96,1, ảnh không lật 96,7/97,7/96,0; lật lại ảnh lật rồi so với ảnh không lật:
sai khác trung bình 2,2 mức (không lật lại: 61,5; đổi R và B: 7,0; lần 1: 4,6); `tp 11` khi lật: 8
sọc đúng thứ tự (trắng hơi hồng, 255,245,255, vì WB giữ ở 413/446); `csi` sau lệnh: `link ok`, 0
lỗi. Lúc đổi flip có một chu kỳ frame 66666 µs, không lỗi (lần 1). Ma trận màu và cân bằng trắng
ban đầu lấy của IMX219; trên cảnh văn phòng màu đã tự nhiên (AWB lần 2: r 387–426, b 429–465;
lần 1: r 425..437, b 454..463).

### 6.5 Video H.264 (`video`)

App `video` đặt dòng của IMX274 dài cho bộ mã H.264 (392 chu kỳ mỗi macroblock ở 200 MHz): tải
~78 % như IMX219 trên KV260 ([video_kv260.md](video_kv260.md) mục 4). Mặc định 720p30 (HMAX
448 / VMAX 5357); `mode 1080p` → HMAX 672 / VMAX 3571.

```bash
python3 tools/bow32_flash.py -p $PORT --no-break flash build/sw/video/video.bin   # sau wr ... RST! (mục 6.1)
python3 tools/bow32_video.py -p $PORT --fast 921600 rec -n 45 --skip 1 -o video.mp4   # 720p30 (mặc định)
python3 tools/bow32_video.py -p $PORT -b 921600 rec --mode 1080p -n 30 --skip 1 -o video1080.mp4
```

Lần 2, `rec --mode 1080p -n 30` (lệnh đầu sau khi nạp `video`, với `--fast 921600`; `cam` đầu của
app chạy trong lệnh này):

```
mode 1920x1080 @30 fps (HMAX 672 VMAX 3571)
csi2rx: calibrated taps 296/184/264/224 eye 352/352/352/336
csi2rx: margin ok +-88/+-88/+-88/+-84 taps: 0 errors in 9 x 8 frames, BER < 7.3e-8
streaming 1920x1080 @30 fps
waiting 4 s for exposure / white balance
recording 30 frames (skip 1)
  rec: 30 frames 1920x1080, 30/2 fps, QP 37 (auto), 34669 bytes per frame
  frame 1: 37600 bytes, QP 37, 20473 us
  frame 2: 32792 bytes, QP 38, 20473 us
  ...                     # QP 37 hoặc 38: ~37,5 KB ở QP 37, ~32,8 KB ở QP 38
  frame 30: 37512 bytes, QP 37, 20473 us
  rec: 30 frames, 1041376 bytes (QP 37..38, largest 37736)
.../video1080.mp4: 30 frames 1920x1080 @ 15.00 fps, 1041376 bytes (13.0 s transfer), also .../video1080.h264
```

Không có `video RAM full`, không có `warning: the encoder dropped pixels`; `stat`: `h264 ... status
06 size 1920x1080 qp 37 frames 30 ... total 1041336` (`STATUS` = FRAME_DONE + DONE, không
`ERR_OVF` / `ERR_INPUT`), `dma ... packets 30`. ffprobe: H.264 Constrained Baseline, level 4.1,
1920×1080, 15 fps, 30 frame; `ffmpeg -xerror` giải mã cả `.mp4` lẫn `.h264` không lỗi, ảnh đúng màu,
không vỡ macroblock (QP 37: hơi mềm, khối nhẹ ở vùng phẳng như tường, trần). Chuyển về PC 90,3
KiB/s ở 921600 baud. Lần 1 (firmware cũ, tap giữ từ `csi2_test`: `csi2rx: link ok with the delays
in use 300/184/264/228 (kept)`; rate control cũ): `rec: 30 frames 1920x1080, 30/2 fps, QP 30, 34951
bytes per frame`, frame 1 77112 byte, tới frame 8 mới lên QP 37, `rec: 20 frames, 901908 bytes (QP
30..37, largest 77112), video RAM full`; encoder không lỗi (`status 02`: FRAME_DONE), bộ thu đo
dòng 18660 ns, frame 33329 µs, 0 lỗi; 20 frame giải mã không lỗi.

720p30 (lần 2, `rec --mode 720p -n 45 --skip 1`, tap giữ từ `cam` đầu): `mode 1280x720 @30 fps
(HMAX 448 VMAX 5357)`, `rec: 45 frames 1280x720, 30/2 fps, QP 33 (auto), 23145 bytes per frame`;
frame 1 33600 byte ở QP 33 (+45 % so với đích), frame 2 24424 byte ở QP 36, từ frame 3 ~22,9 KB ở
QP 37 (frame 43: 20040 byte ở QP 38), 9093 µs mỗi frame; `rec: 45 frames, 1042620 bytes (QP 33..38,
largest 33600)`, còn 5956 byte của 1 MiB. `stat`: `status 06`, `frames 45`; ffprobe 45 frame
1280×720, giải mã không lỗi. QP đầu tự chọn ở 720p thấp hơn ~4 bước: mô hình QP đầu tính theo số
pixel, mà mode 720p của IMX274 phủ cùng góc nhìn với 1080p (ảnh cảnh thật của hai mode như nhau),
nên nhiều chi tiết hơn mỗi pixel: ở QP 37 frame 1080p 37,5 KB, frame 720p 23,0 KB, tỉ lệ 1,63 thay
cho 2,25 của số pixel, tức kích thước tăng theo (số pixel)^0,6. Firmware sau lần 2 chọn QP đầu theo
mô hình đó (`bow_h264_rc_init()`, đoạn dưới): 37 cho 45 frame 720p (~23,0 KB, đích 23145), 38 cho
30 frame 1080p (~32,8 KB, đích 34669); trên bo ở lần 3 (đoạn dưới). Bộ thu đo dòng 12460 ns, frame
33332 µs ở HMAX 448.

Lần 3 (firmware `5c68b53`, cùng PDI; `rec --mode 720p -n 45 --skip 1` với `--fast 921600`, rồi
`rec --mode 1080p -n 30 --skip 1`): QP đầu đúng như mô hình:

```
  rec: 45 frames 1280x720, 30/2 fps, QP 37 (auto), 23145 bytes per frame
  frame 1: 11288 bytes, QP 37, 9093 us
  frame 2: 20820 bytes, QP 31, 9093 us
  ...                     # QP 30 (~23,0 KB), đôi khi 29 (~25,4 KB)
  rec: 45 frames, 1042428 bytes (QP 29..37, largest 25540)
  ...
  rec: 30 frames 1920x1080, 30/2 fps, QP 38 (auto), 34669 bytes per frame
  frame 1: 16400 bytes, QP 38, 20473 us
  frame 2: 37600 bytes, QP 31, 20473 us
  ...                     # QP 31 / 32 xen kẽ (~37,5 / ~31,5 KB)
  rec: 30 frames, 1042128 bytes (QP 31..38, largest 38216)
```

`stat`: `status 06` (không `ERR_OVF`), `frames 45` và `frames 30`; ffprobe H.264 Constrained
Baseline, level 4.1, 45 và 30 frame; `ffmpeg -xerror` giải mã cả `.mp4` lẫn `.h264` không lỗi,
không vỡ macroblock. Cảnh lần này tối (văn phòng tắt đèn giờ nghỉ trưa: AE exp 3563 gain 1792, Y
trung bình ~50) và ít chi tiết hơn cảnh tham chiếu của mô hình, nên frame đầu chỉ bằng 49 % đích
(720p) và 47 % (1080p); rate control hạ QP ngay ở frame 2 và mọi frame vừa 1 MiB. QP đầu của mô
hình chỉ đúng với cảnh giống cảnh tham chiếu (văn phòng sáng đèn); cảnh khác thì frame đầu lệch,
rate control sửa trong 1–2 frame.

`rec` chỉ gửi `mode` khi có `--mode`: không có thì board giữ mode đang dùng. `cam` đầu của `video`
luôn hiệu chỉnh như app `camera` (khối trên: `calibrated taps`, `margin ok`, không có dòng `kept`
của lần 1).

Rate control của `rec` ([video_kv260.md](video_kv260.md) mục 3): mỗi frame nhắm phần chỗ trống
còn lại chia cho số frame còn lại, QP của frame sau = QP vừa dùng + 6 · log2(kích thước / đích)
(tối đa ±12), QP đầu tự chọn theo kích thước frame (`qp auto`, mặc định của app và của
`bow32_video.py`; `--qp n` để cố định), và `rec` in QP của từng frame (`frame k: n bytes, QP q, t
us`). Lần 1 (rate control cũ: QP đầu 30, mỗi frame ±1) bắt đầu bằng frame 77 KB so với đích 35 KB,
tới frame 8 mới lên QP 37 và video RAM đầy sau 20 trong 30 frame. Rate control mới chọn QP đầu 37
ở 1080p, 30 frame, như test host `tools/tests/test_h264_model.py` (với kích thước frame của lần 1
và frame của mô hình H.264) dự đoán, và ở lần 2 ghi đủ 30 / 30 frame trong 1 MiB (khối trên; test
hệ thống `h264` có một bản quay rate control). Sau lần 2, QP đầu = 37 + 6 · log2(S / đích), S =
37,5 KB · (W · H / (1920 · 1080))^0,6 là kích thước một frame của cảnh văn phòng ở QP 37: 1080p,
30 frame: 38; 720p, 45 frame: 37; 720p, 30 frame: 33. Test host có kích thước và QP của từng frame
của lần 2 ở cả hai mode (`test_board_run2`): đưa kích thước đo được theo thứ tự vào rate control
(build cho host) thì ra đúng QP của mọi frame trên bo (720p: 33, 36, rồi 37, frame 43 ở 38); với QP
đầu mới, frame của cảnh đó nằm trong 10 % dưới đích ở cả hai mode (chỉ với cảnh đó: cảnh tối của
lần 3 cho frame đầu 47–49 % đích, đoạn trên). Ở 1080p50 / 1080p60 (`mode
1920 1080 60`) frame rate không còn chỗ cho dòng dài: app in `note: H.264 load 97 % (HMAX 542):
detailed scenes at a low QP may drop pixels, a lower frame rate gives longer lines`. Khi encoder
bỏ pixel, `rec` in `warning: the encoder dropped pixels (H.264 load 78 %: raise qp or give rec
fewer kbytes per frame)` (trên 80 % thêm `lower the frame rate for longer lines, `).

### 6.6 Chế độ của cảm biến

ISP 1 pixel/clock ở 200 MHz; IMX274 gửi một dòng CSI-2 mỗi 2 chu kỳ HMAX của 72 MHz (INCK
24 MHz); FIFO của bộ thu 512 nhóm = 2048 pixel (một dòng 1080p để lại ~313 nhóm, 720p ~209).

| Chế độ | Cửa sổ của cảm biến | HMAX Bow32 dùng (cảm biến: tối thiểu 260) | Ví dụ (HMAX / VMAX) |
|--------|---------------------|-------------------------------------------|---------------------|
| 720p, chỉ ISP (`camera`, `csi2_test`) | mode 5 + crop → 1280×720, 4 dòng OB | 300 (dòng 8,33 µs) | 60 fps: 300 / 4000; 30 fps: 300 / 8000 |
| 720p, có H.264 (`video`) | như trên | 448 (0,35 · W, tải 78 %) | 30 fps: 448 / 5357; 60 fps: 448 / 2678 |
| 1080p, chỉ ISP | mode 3 + crop → 1920×1080, 8 dòng OB | 400 (dòng 11,11 µs) | 30 fps: 400 / 6000; 60 fps: 400 / 3000 |
| 1080p, có H.264 | như trên | 672 (tải 78 %), ngắn hơn khi fps cao | 30 fps: 672 / 3571 (dòng 18,67 µs); 25 fps: 672 / 4285; 50 fps: 651 / 2211 (81 %); 60 fps: 542 / 2214 (97 %) |
| 4K (chỉ `csi2_test`) | mode 1 → 3840×2160 | 800 | bị từ chối trên bản này: một dòng để lại ~627 nhóm (cần FIFO 1024 nhóm, `csi2_test`), ISP tối đa 2048 pixel (`camera`, `video`) |

VMAX = 72 MHz / (HMAX · fps) làm tròn xuống, ít nhất VMAX_min + 20 với VMAX_min = 2 · (1 + H +
số dòng OB) + 13 (1080p: 2191, 720p: 1463); fps 0 (`camera`, `csi2_test`): frame ngắn nhất. Có
H.264: tải = 27,5625 · W / HMAX %, HMAX = max(HMAX_min, ⌈0,276 · W⌉, min(⌈0,35 · W⌉,
⌊72 MHz / (fps · (VMAX_min + 20))⌋)) (`imx274_set_mode()`, `sw/common/src/imx274.c`).

Đo trên bo (`stat` / `csi`; `LINE_TIME` đếm chu kỳ CPU 20 ns), lần 1 và lần 2 như nhau: 1080p30
HMAX 400 dòng 11100–11120 ns, frame 33333 µs; 720p60 HMAX 300 dòng 8320–8340 ns, frame 16666 µs.
`video`: 1080p30 HMAX 672 dòng 18660 ns, frame 33329 µs (lần 1); 720p30 HMAX 448 dòng 12460 ns,
frame 33332 µs (lần 2). Lane clock ở HS suốt frame (`clk` 1 mỗi frame), LP-11 giữa các frame; mỗi
burst một packet: 1091 burst mỗi frame ở 1080p (FS, 1 dòng embedded, 8 dòng OB, 1080 dòng, FE; lần
2: `csi` sau frame đầu của `cam` in `bursts 1091/1091/1091/1091 clk 1`), 727 ở 720p (lần 1).

## 7. Danh sách kiểm khi bring-up trên bo

Theo thứ tự. Mục nào lệch với "mong đợi" thì dừng và ghi lại trước khi đi tiếp. Cột cuối là kết
quả của lần chạy bo 2 (2026-11-11, PDI và firmware `cd289e3`), rồi của lần 1 (2026-11-10,
`aaf7ed4`) ở nơi lần 2 không làm lại; lần 3 (2026-11-11, cùng PDI, firmware `5c68b53`) có ghi ở
các mục nó đo lại. **Chưa đo** / **chưa xem** là các kiểm tra vật lý cần người hoặc que đo / scope
ở bo: cả ba lần không có ai ở bo, nên chúng vẫn còn mở. Mục 21 và 22 là kiểm tra của firmware cuối
(PR #17).

| # | Khi nào | Làm / đo | Mong đợi, ghi lại | Kết quả: lần 3, lần 2 (2026-11-11), lần 1 (2026-11-10) |
|---|---------|----------|-------------------|---------------------------------------------------------|
| 1 | bo bật, chưa cắm module | LED cạnh SW192, TP29; PG_C2M của FMC+01 (chân D1 của FMC) trên bo chuyển | chỉ "1.2", TP29 ≈ 1,2 V. Netlist có chỗ cho điện trở kéo PG_C2M lên 3,3 V và 5 V (không rõ lắp cái nào): ghi mức đo được, 5 V thì hỏi lại trước khi cắm module | **chưa đo** (không có người ở bo, cả hai lần); người dùng báo SW192 ở 1,2 V trước lần 1. Lần 2 không xác nhận lại bench; gián tiếp: link 4 lane ở 1,2 V sạch, I2C trả lời |
| 2 | module cắm, FPGA chưa cấu hình | mức nghỉ của SCL / SDA (LA26), XCLR (LA22_N), XVS / XHS (LA29) | ≤ ~1,2 V (bank ở VCCO 1,2 V; rail kéo lên trên module chưa rõ): dừng nếu dây nào cao hẳn hơn. XCLR có thể nổi lên cao trước khi cấu hình: ghi lại | **chưa đo** (cần que đo) |
| 3 | sau `make jtag` | LED12, LED7, LED10, LED11, LED8 | LED12 và LED7 sáng đều (clock 200 MHz qua 3 SLR); LED10 sáng ngay (≤ 1,3 ms); LED11 sáng; LED8 tắt tới khi ứng dụng bật PA7. LED7 sáng, LED10 tắt: BISC (mục 6.3) | LED **chưa xem**. Gián tiếp, như nhau ở hai lần: boot ROM in `clk 50000000 Hz` (MMCM khoá), `STATUS.PHY_RDY` = 1 ngay (XPLL khoá, BISC xong), PB6 = PB7 = 1, PB5 = 0 (có module; lần 2: `rd 40005000` = `000000c3`) |
| 4 | sau `make jtag`, bo RAM ở FMC+10 | OE# của bo RAM (FMC+10 LA10_P, LA08_N) | ≥ 1,26 V (VIH của TXV0108 ở VCCA 1,8 V): level shifter cô lập | **chưa đo** |
| 5 | bật nguồn, nạp PDI | cuộn lọc hồng ngoại (LA28 thả nổi), FMC_FLASH (LA16_N = 1) | không nghe / thấy bộ lọc hồng ngoại bật tắt; FMC_FLASH làm sáng gì, dòng tiêu thụ đổi bao nhiêu | **chưa xem** |
| 6 | `csi2_test` khởi động | I2C ở 0x1A: ACK, thời gian sườn lên ở 100 kHz | `camera: IMX274 found`; sườn lên ≤ 1 µs (I2C chuẩn); chậm hơn: hạ tốc độ hoặc thêm pull-up về VADJ | Lần 2: firmware cuối không sửa tìm thấy cảm biến ở cả ba ứng dụng (`camera: IMX274 found (id 0274)`), `sr 30f8` … `sr 30fa` = `06 09 00` (VMAX 0x000906 sau reset). Lần 1: ACK ở 100 kHz; đọc burst và từng byte như nhau; MDSEL1..4 03 31 00 09, HMAX 0x0104, **VMAX 0x000906** (datasheet 0x905: firmware của lần 1 từ chối cảm biến, mục 6.2); BLKLEVEL ghi / đọc lại 0x33 đúng; XCLR reset được cảm biến. Sườn lên **chưa đo** (không có scope) |
| 7 | `phy`, `phy reinit` | trễ BISC của 4 lane, `AFE_STATUS` (trước bước 4: PB6 / PB7), thời gian tới `READY` (`PHY_RDY`) | trễ của các lane gần nhau (lane nhận strobe chuyển tiếp có thể lệch hơn); `PHY_RDY` sau ~40 µs (mô phỏng) tới 1,3 ms (AM010) | Lần 2: 123/76/119/129 sau khi nạp PDI và sau hai lần `phy reinit`, 122/76/118/129 sau lần thứ ba; PB6 = PB7 = 1; `PHY_RDY` 75–76 µs sau xung PA4. Lần 1: 122/75/118/130 sau khi nạp, 122/75/118/130 hoặc 123/76/120/129 sau `phy reinit`, như nhau khi lane clock chạy. Lần 3: 124/76/120/129 và 123/76/120/129 sau hai lần nạp, 122–123/75–76/118–120/129–130 sau mỗi `phy reinit`, như nhau khi đang stream; `PHY_RDY` 75–112 µs. Trễ BISC ở mép sớm của eye, thấp hơn tâm 0,26–0,48 UI (mục 9) |
| 8 | `stat` trước `start`, sau `stop` | trạng thái LP của lane ở standby | LP-00 (datasheet) hay LP-11; lỗi LP (`misc`) ở mỗi lần dừng / chạy là bình thường với LP-00 | Cả hai lần: LP-00 trên cả 5 lane trước stream đầu (sau khi nạp PDI; lần 2 cả trong `camera` trước `cam`), LP-11 trên cả 5 lane sau `stop` (`STATUS` 0x000f403f, cũng là trạng thái cuối của lần 2); `misc` 0. Bộ thu tắt: lần 2 liệt kê đủ 4 lane (firmware của lần 1: 2 lane) |
| 9 | `raw` sau `start` | byte sync của từng lane | `b8` ngay sau HS-zero, `sync byte at bit ...` trên mọi lane. Thấy `1d` mà không có sync: thứ tự bit ngược (`BitRev` = 1 của `bow_dphy_io_versal`, build lại) | Lần 2: `b8` ngay sau HS-zero; lane 1 ở bit 104 (word 13 + 0), lane 0 / 2 / 3 ở bit 105 (word 13 + 1), như lần 1 (lane 1 ở bit 8k + 0, các lane khác trễ 1 bit trong cùng word); không có `1d`: thứ tự bit đúng |
| 10 | `raw` lặp lại nhiều phút | vị trí sync của từng lane | không đổi theo thời gian; lệch giữa các lane ≤ 6 byte clock (từ 7 trở lên bộ thu báo SKEW) | Lần 1: 7 lần trong 2 phút: lệch giữa các lane không đổi (lane 1 +0, các lane khác +1 bit), word 13 hoặc 15 như nhau trên mọi lane; 8209 frame không lỗi. Lần 2: một lần `raw`, cùng lệch |
| 11 | `log fs`; `wr 40008020 1`, vài frame sau `rd 40008024` (`CNT_FRAME`) và `rd 40008028` (`CNT_PKT`) | packet mỗi frame | FS, EMB (0x12), OB (0x37) × 8 (720p: 4), dòng 0x2B, FE, mỗi packet một burst: 1091 packet / frame ở 1080p, 727 ở 720p. Ghi WC của EMB và OB. Thiếu dòng mà không lỗi, hoặc `no lines`: cảm biến gửi nhiều packet trong một burst | Lần 2: `log fs` = FS, EMB (dt 12, WC 175), 8 dòng OB (dt 37, WC 2400), rồi dòng RAW10 `accepted`; `csi` sau frame đầu của `cam`: 1091 burst. Lần 1: đúng như mong đợi: EMB WC 175, OB WC 2400 × 8 (720p: 1600 × 4), 1080 dòng WC 2400 (720p: 720 × 1600); 1091 burst mỗi frame (40367 trong 37 frame), 727 ở 720p: mỗi burst một packet |
| 12 | `stat` | `clk` (số lần lane clock vào HS) theo số frame; byte clock | 1 mỗi frame: lane clock liên tục trong frame; 1 mỗi burst: tắt sau mỗi dòng (đồng hồ đo byte clock khi đó đọc thấp). 180 MHz = INCK 24 MHz (202,5 MHz: dao động 27 MHz) | Cả hai lần: `clk` 1 mỗi frame (HS suốt frame, LP-11 giữa các frame); byte clock 180078 kHz (INCK 24 MHz) |
| 13 | `test`, `stat` | `trunc`, `ovf`, `line`, `frame` | `trunc` 0 và `ovf` 0 ở 1080p và 720p; line = 2 · HMAX / 72 MHz (11111 ns ở HMAX 400), frame = HMAX · VMAX / 72 MHz | Cả hai lần: `trunc` 0, `ovf` 0 ở 1080p và 720p; dòng 11100–11120 ns ở HMAX 400 (`LINE_TIME` đếm chu kỳ CPU 20 ns), frame 33333 µs; 720p60: 8320–8340 ns, 16666 µs |
| 14 | `test` | dòng integrity và isp | tổng và mean của 555h / AAAh (có cộng BLKLEVEL không), `tp 11` ra sọc dọc (không thì thử `tp 12`), màu và thứ tự sọc, mức xám | Lần 2 như lần 1, đúng từng bit: 555h `2a257400`, mean 341; AAAh `544ae800`, mean 682 (đúng 0x155 / 0x2AA × 2 073 600: không cộng BLKLEVEL); 720p `12bb5000` / `2576a000`; `isp colour bars` 6 màu, 555h qua ISP: xám 145. `tp 11`: 8 sọc dọc đúng thứ tự ở 1080p, 6 sọc ở 720p |
| 15 | ≥ 10⁴ burst mỗi cách | `BurstRxRst`: 1 (mặc định: `DES_RST_DIS` = 0 từ bước 4, PA5 = 1 trước đó) so với `phy burstrst 0` (mục 6.3) | PA5 = 1 sạch | Lần 1: PA5 = 1: 0 lỗi, hơn 3,2 triệu burst. PA5 = 0 hỏng hẳn sau lần bật lại bộ thu đầu tiên (lane 0 SOT / ECC / CRC, SKEW, FRAME; `misc` 255 mỗi giây) tới khi PA5 = 1 lại. Firmware giữ PA5 = 1 (lần 2: `phy` sau `start` in `burstrst 1`); PA5 = 0 không thử lại |
| 16 | cảm biến đang stream | quét `SETTLE` theo mục 6.3 (giữ `BurstRxRst` = 1) | lỗi SOT, ECC, CRC, misc mỗi giá trị → cửa sổ thật | Lần 2 (RTL gộp main, ~180 frame 720p60 mỗi giá trị): sạch 13…34 chu kỳ (65…170 ns); 12: `misc 31`; 35: `sot 0/0/0/1`, `misc 2`: đúng cửa sổ của lần 1 (lần 1 thêm: 8–12 misc, từ 36 không còn frame). 95 ns của driver cách mép dưới 30 ns |
| 17 | `camera`: `flip 0 1` trên cảnh thật | thứ tự Bayer khi lật dọc, frame ngay sau lệnh | RGGB: màu đúng ngay sau lệnh | Lần 2: firmware cuối cho màu đúng không cần ép: ISP `BAYER` 0 sau `flip 0 1`, mean RGB 96,9/96,3/96,1, lật lại khớp ảnh không lật (sai khác 2,2), sọc màu đúng thứ tự. Lần 1: GBRG của driver cho ảnh tím (mean RGB 140/9/149); ép ISP `BAYER` = RGGB thì màu đúng (99/99,5/99,3) |
| 18 | `camera`: `cam` đầu tiên | frame đầu sau khi thoát standby | có frame, frame đầu không hỏng; nếu không: thử thêm 10 ms sau các lệnh ghi của bước 1 (firmware) | Lần 2: `cam` đầu ở trễ BISC mới (122/76/118/129) tự hiệu chỉnh: 296/184/264/224, eye 352/352/352/336, `margin ok +-88/+-88/+-88/+-84` (9 × 8 frame); không có `kept`; frame đầu tốt (1 frame, 1091 burst, 0 lỗi); `video` cũng vậy. Lần 1: frame đầu tốt; link check thấy lỗi và app hiệu chỉnh (cùng tap), 64 frame không lỗi |
| 19 | sau `cal`, bo nóng / nguội hoặc chạy lâu | lỗi ECC / CRC trong `csi` | lane đã nạp tap thôi theo dõi VT: so với trễ BISC (sau `phy reinit`, VT bật lại) | Lần 3: 30 phút 1080p30, `csi2_test` trên cảnh thật (mục 6.4): 53 999 frame, mọi bộ đếm lỗi 0 ở cả 7 mẫu, tap giữ 296/184/264/224, `margin` cuối ±86/±90/±86/±86 tap 0 lỗi, `cal 8` cuối chỉ dời mép trên của lane 0 một bước 8 tap. Lần 2: 5 phút 1080p30 (AE/AWB bật) ngay sau `cam`: 9012 frame, mọi bộ đếm lỗi 0, tap giữ 296/184/264/224. Lần 1: 0 lỗi trong ~15 phút qua các ứng dụng (hơn 18 000 frame). Chưa thử nóng / nguội, chưa chạy lâu với app `camera` |
| 20 | `video`: `rec` 1080p30 và 720p30, cảnh nhiều chi tiết, QP 18–23 | `warning: the encoder dropped pixels` | không có (tải 78 %) | Lần 3 (cảnh văn phòng tối, QP đầu mới): 720p30 `QP 37 (auto)`, 45 / 45 frame, QP 29–37; 1080p30 `QP 38 (auto)`, 30 / 30 frame, QP 31–38; `STATUS` 06; giải mã không lỗi; không bỏ pixel. Lần 2 (cảnh văn phòng, `qp auto`): 1080p30 (HMAX 672) 30 / 30 frame, QP 37–38, H.264 `STATUS` 06 (không `ERR_OVF`), 20473 µs mỗi frame; 720p30 (HMAX 448) 45 / 45 frame, QP 33–38, 9093 µs mỗi frame; không bỏ pixel. Lần 1: 1080p30 không bỏ pixel, QP 30–37, 20 / 30 frame (rate control cũ). Cảnh nhiều chi tiết ở QP 18–23 **chưa thử** |
| 21 | `stat` khi stream | `extra`, `rd 40008048` (`CNT_EXT`), `rd 4000801c` (`ERR_STATUS`) | `extra 0`, cả hai thanh ghi 0: `CTRL.EXTRA` 192 của driver cao hơn trail sau packet. `extra` > 0: quét `CTRL.EXTRA` (mục 6.3) | Lần 3: 0 ở mọi `stat`, cả 30 phút 1080p30. Lần 2: 0 ở mọi `stat` / `csi` (720p60, 1080p30, 5 phút, `camera`, `video`); trail 49–52 byte trên 4 lane (52 sạch; 48 báo mọi burst và bỏ mọi frame) |
| 22 | sau `cal` | `margin` (mục 6.3, 6.4) | `margin ok`: 0 lỗi ở tâm và ở ±k (k = eye / 4) của cả 4 lane | Lần 3: `csi2_test` ±89/±88/±89/±88 sau `cal 4` và ±88/±90/±88/±88 trong `test`, 0 lỗi; quanh trễ BISC của PDI thử A ±88/±88/±90/±88, 0 lỗi (mục 9.1). Lần 2: `csi2_test` ±88/±90/±90/±88 tap, 0 lỗi trong 9 × 60 frame, BER < 1,0e-8 (720p60: < 2,2e-8); `camera` ±88/±88/±88/±84, BER < 1,0e-8; tap đặt bằng tay (lane 2 ở 240) giữ nguyên sau `margin` |

Nếu bộ thu của Bow32 không nhận gì trong khi cảm biến chắc chắn stream (LED5 sáng), một PDI thử
với IP MIPI D-PHY của AMD trên cùng các chân (không có trong repo) tách lỗi của bo / cảm biến
khỏi lỗi của PHY Bow32. KV260 (không phải bo này): `kv260_cam` với RTL đã gộp main đã build
(2026-11-10: WNS +0,074 ns, WHS +0,010 ns, bus skew 9/9) nhưng chưa nạp lên KV260: chạy
`csi2_test` `test` và `camera` ([camera_kv260.md](camera_kv260.md)); phy-idle in `STATUS 403f`.

### Việc còn mở (sau lần chạy bo 3)

Cần RTL và PDI mới (không chặn ứng dụng: ứng dụng luôn hiệu chỉnh, ảnh không bị ảnh hưởng):

- Trễ BISC thấp hơn tâm eye 0,26–0,48 UI, khác nhau giữa các lane (mục 9.1). Lần 3 loại được cách
  dùng slice N của Bow32 (PDI thử B: không đổi gì) và cho thấy phần chung là một thời gian cố định
  mà BISC không thấy (PDI thử A, `DELAY_VALUE` 250 ps: trễ BISC +132 tap, tâm eye không đổi). Còn
  hai giả thuyết: lệch giữa lane clock và lane dữ liệu ở ngoài FPGA (cảm biến, module, bo chuyển,
  bo mạch), hoặc một số hạng pha của silicon gắn với `PLL_CLK`; phép thử kế tiếp ở mục 9.1. PDI
  thử A không đạt tiêu chí "trễ BISC trong ±20 tap của tâm trên mọi lane" (+44/−24/+8/−34), nên các
  generic thử (`DataDlyPs`, `NSliceXphy`) chưa vào repo và mặc định không đổi. Đặt `DELAY_VALUE`
  ≈ 250 ps làm mặc định cho top camera Huins (link sạch ở trễ BISC trên bo này, lề ±88 tap) là
  việc cho sau: cần CI đầy đủ, PDI mới và kiểm lại trên bo; ứng dụng vẫn phải hiệu chỉnh từng lane.

Phần mềm và công cụ, còn mở:

- `stat` / `csi` ngay sau khi xoá bộ đếm, trước khi frame đầu kết thúc, in `csi2rx: link errors`
  dù mọi bộ đếm lỗi là 0 (`bow_csi2rx_print_status()`: có packet mà chưa có frame thì rơi vào
  nhánh lỗi; lần 3: mẫu t = 0 của lần chạy 30 phút, mục 6.4). Chỉ là chữ in ra: chờ một frame rồi
  xem lại.
- QP đầu của `rec` khớp cảnh tham chiếu (văn phòng sáng đèn); cảnh tối của lần 3 cho frame đầu
  47–49 % đích (rate control sửa trong 1–2 frame, mọi frame vừa). Không cần sửa.
- Gợi ý của `make jtag` với `HW_SERVER` ở máy khác chưa thử (lần 3 chỉ gặp hw_server cục bộ).

Đã sửa sau lần 2 (chỉ chữ in ra và chú thích): khi điểm tâm có lỗi, `margin` in `errors at the
taps in use` thay cho `errors at the calibrated taps` (tâm là tap đang dùng, có thể là trễ BISC hay
tap đặt bằng tay, mục 9); chú thích `CTRL.EXTRA` trong `bow_csi2rx.h` / `bow_csi2rx.c` ghi trail
đã đo.

Đã sửa sau lần 2 (phần mềm và công cụ), đã kiểm trên bo ở lần 3:

- `csi2_test` `start`: link check 64 packet (~6 % một frame 1080p) in `link check ok` ở trễ BISC dù
  sau đó có 0,2–1,5 dòng lỗi CRC mỗi frame (mục 6.3). Nay kiểm 16 frame nguyên
  (`bow_csi2rx_link_check_frames()`), khi lỗi do tap in `try cal` và, trên bản Versal, hai dòng gợi
  ý về trễ BISC; đầu ra trên KV260 giữ nguyên. Mô phỏng `csi2_274`: lỗi CRC ở frame 6 bị bắt, link
  check sạch chỉ in `ok` sau 16 frame. Lần 3: sau khi nạp PDI hay `phy reinit`, `start` in `link
  check failed (ERR_STATUS 008), try cal` và hai dòng gợi ý 7 / 7 lần; trên PDI thử A (trễ BISC gần
  tâm) `link check ok`.
- `video` `rec` ở 720p: QP đầu tự chọn là 33, thấp hơn ~4 bước (frame đầu 33600 byte so với đích
  23145; từ frame 3 QP 37, ~22,9 KB). Nay QP đầu theo (số pixel)^0,6 (mục 6.5): 37 ở 720p (45
  frame), 38 ở 1080p (30 frame); kích thước và QP từng frame của lần 2 nằm trong
  `tools/tests/test_h264_model.py`. Lần 3: `QP 37 (auto)` ở 720p, `QP 38 (auto)` ở 1080p, đủ 45 /
  30 frame.
- `tcl/jtag.tcl`: khi `connect_hw_server` lỗi vì hw_server cũ hơn Vivado (`Labtools 27-3366`), nay
  in gợi ý (mục 5): hw_server nào đang giữ cổng, `VIVADO=` cùng phiên bản hoặc `HW_SERVER=`, không
  dừng tiến trình của người khác. Lần 3: hiện đúng trước hw_server 2025.1 thật của đội khác, `make`
  lỗi, không nạp gì.

Trên bo, cần người ở bo: mục 1, 2, 4, 5, LED của mục 3 và sườn lên I2C của mục 6; nóng / nguội
(mục 19); `rec` ở QP 18–23 trên cảnh nhiều chi tiết (mục 20). Không cần người: chạy lâu với app
`camera` (ISP, AE/AWB; lần 3 chạy 30 phút bằng `csi2_test`). KV260: nạp `kv260_cam` của RTL đã gộp
main (đoạn trên).

## 8. Xử lý sự cố

| Triệu chứng | Kiểm tra |
|-------------|----------|
| `make pins CARD=cam`: `card cam is only verified on FMC+ site(s) 1` | `FMC_SITE` khác 1: camera chỉ chạy ở FMC+01 với bo chuyển (mục 3) |
| `make plan CARD=cam`: `ERROR: cam_plan: ...` rồi `the camera pins of ... do not fit the XPHY strobe rules` | các dòng `ERROR` nói cổng nào sai (khác bank với lane clock, P/N đảo, nibble strobe không tới): sai khe hoặc sai `pins.txt` |
| Vivado: `XPHY nibble plan ... not found`, `is older than`, `is incomplete` | `make plan CARD=cam` (`make pdi CARD=cam` tự chạy nó) |
| Vivado dừng ở `pre_opt_cam: the XPHY nibble plan of u_dphy does not fit the camera pins` | dòng `ERROR: cam_xphy:` ngay trên nói chân nào sai; generic `Dphy*` của top không lấy từ sơ đồ của `make plan`, hoặc `FMC_SITE` khác 1 |
| Vivado: `[Route 35-7]` ở dây `CLK_TO_*` / `CLK_FROM_OTHER_XPHY` | sơ đồ nibble không hợp lệ cho các chân (kiểm tra ở `cam_plan` / `pre_opt_cam` lẽ ra đã bắt) |
| Vivado: `[Place 30-728]` / `[Place 30-1960]` (luật clock của placer) | clock vào và XPLL khác SLR: xem log `pre_place_cam` (`CLOCK_DEDICATED_ROUTE` trên 3 net của `u_clk`) |
| Vivado: `CRITICAL WARNING` về bus skew | tên thanh ghi / cell trong `constr/huins_vp1902_cam.xdc` không còn khớp RTL (phải đủ 11) |
| Vivado: `CRITICAL WARNING: port ... (FMC+01 site VCCIO, SW192 = 1.2 V) has IOSTANDARD ...` | một cổng của bank 703..706 không phải `MIPI_DPHY` / `LVCMOS12`: sửa XDC |
| Vivado: `CRITICAL WARNING: CDC-<n> from ... to ... is not a reviewed crossing` | crossing mới giữa các miền clock: xem `cdc.rpt`, sửa RTL hoặc duyệt rồi thêm vào `tcl/timing_checks_cam.tcl`. |
| `make jtag`: `jtag: refused: ...` | bo / switch theo bảng ở mục 2; PDI không có `pdi_site.txt` (dựng trước khi có khoá) hoặc mới hơn nó (build không qua `make pdi`): build lại bằng `make pdi` hoặc `CONFIRM=1` sau khi kiểm |
| `make jtag`: `ERROR: [Labtools 27-3366] Cannot support older hw_server version ...` (sau lần 2 kèm các dòng `jtag: the hw_server at ... is of an older Vivado ...`) | hw_server ở `localhost:3121` của một Vivado cũ hơn, thường của người dùng khác; chưa nạp gì. Các dòng `jtag:` nói hw_server nào (người dùng, pid, phiên bản) và Vivado nào khớp. Chờ nó thoát, hoặc khi chủ bo xác nhận bo rảnh, nạp bằng Vivado cùng phiên bản với hw_server (`VIVADO=...`, mục 5), hoặc `HW_SERVER=<host:port>` của một hw_server cùng phiên bản với Vivado; không dừng tiến trình của người khác |
| LED12 tắt | không có clock 200 MHz: SW12 phải OFF |
| LED7 tắt (LED12 sáng) | XPLL của bank 705 không khoá: clock 200 MHz qua SLR, xem `clock_utilization.rpt` |
| LED7 sáng, LED10 tắt | BISC không xong: VCCIO của FMC+01 (SW192 phải 1,2 V, LED "1.2", TP29); thử lại BISC với lane clock chạy (`sensor on`, `phy reinit`, mục 6.3) |
| `phy reinit`: `error: AFE_STATUS.READY stayed 1 after CMD.REINIT ...` (trước bước 4: `error: PHY_RDY stayed 1 during the reinit pulse ...`) | PHY không khởi động lại: PDI không phải bản camera Versal của cùng commit: build lại |
| `csi2rx: bitstream before the D-PHY split, rebuild it` | PDI trước bước 4 với firmware mới (không có alias, mục 6.2): build PDI cùng commit |
| LED11 tắt | module/bo chuyển chưa cắm vào FMC+01 |
| I2C không có ACK ở 0x1A | PA7 (XCLR) phải là output 1 (LED8); SW192 = 1,2 V; module cắm chặt trên bo chuyển |
| LED5 không bao giờ sáng | cảm biến chưa stream (lane clock không vào HS) |
| lỗi ECC/CRC/SoT | `cal` (trễ BISC nằm ở mép sớm của eye: `cam` đầu luôn hiệu chỉnh, `csi2_test` cần `cal` sau `start`); `BurstRxRst` phải là 1 (`phy`: `DES_RST_DIS 0`; trước bước 4 `burstrst 1`), `SETTLE` (mục 6.3); SW192; bo chuyển |
| `csi2_test`: `start` in `link check failed (ERR_STATUS 008), try cal` (bản Versal: thêm `errors in frame k of 16 at the delays in use ...`); firmware của lần 2: `link check ok` nhưng `stat` sau đó có `crc` > 0 | bình thường ở trễ BISC (sau khi nạp PDI hay `phy reinit`; lần 3: mọi lần); link check của firmware lần 2 chỉ 64 packet, nay 16 frame; `cal 8` (mục 6.3) |
| `stat` / `csi`: `csi2rx: link errors` mà `frames 0` và mọi bộ đếm lỗi là 0, ngay sau `wr 40008020 1` | chưa có frame nào kết thúc sau khi xoá bộ đếm: firmware in nhầm (việc còn mở, mục 7); chờ một frame rồi xem lại |
| `stat`: `extra` rất lớn, `frame errors c00`, `sum 00000000`, `no LP-11 between packets?` | `CTRL.EXTRA` thấp hơn trail (49–52 byte trên 4 lane): mọi frame bị bỏ; `start` ghi lại 192 của driver (mục 6.3) |
| `csi`: `dropped by DT/VC` tăng 9 mỗi frame (720p: 5) | bình thường: dòng embedded và optical black bị bộ lọc DT bỏ (bộ đếm dừng ở 65535) |
| `video`: `warning: the encoder dropped pixels (H.264 load ...)` | tăng `qp` hoặc giảm kbytes của `rec`; trên 80 % hạ frame rate (dòng dài hơn) |

## 9. Bên trong: D-PHY trên Versal

`hw/fpga/common/rtl/bow_dphy_io_versal.sv` là bản Versal của `bow_dphy_io_xusp` (KV260), cùng
các cổng LP / HS enable / byte clock với bộ thu:

- **IBUFDS_DPHY** cho cả 5 cặp (`MIPI_DPHY`, `DIFF_TERM_ADV TERM_100`, `EQ_LEVEL5`): đầu ra HS
  chỉ được vào XPHY, đầu ra LP về máy trạng thái LP của bộ thu (đồng bộ ở `clk_vid`).
- **XPHY** chế độ native strobe, 1:8, FIFO `ASYNC` 8 word: lane clock vào slice 0 của nibble
  strobe; các nibble khác nhận strobe qua dây inter-nibble (nibble cùng cặp) hoặc inter-byte
  (nibble ±2), chỉ trong một bank. Sơ đồ (nibble và slice của từng cặp, đường strobe) là tham số
  của module (`NumNib`, `NibPhys`, `NibRole`, `NibSrc`, `LaneNib`, `LaneSlice`), được kiểm lúc
  elaboration (`$error`). Mặc định là một sơ đồ tổng hợp cho mô phỏng và lint; bản camera Huins
  suy ra sơ đồ thật lúc build (`make plan CARD=cam`, `tcl/cam_plan.tcl`, mục 4) và đưa vào top
  thành generic `Dphy*`; `tcl/pre_opt_cam.tcl` / `tcl/cam_xphy.tcl` kiểm lại netlist với chân.
- **BISC** của XPHY tự căn strobe và dữ liệu (gồm cả lệch của dây chuyển strobe) sau reset;
  trễ đọc được ngay (`DLYn[24:16]`, `phy` / `stat` in nó). Phần mềm chỉ nạp tap khi ghi `DLYn`:
  lần đầu của mỗi lane tắt theo dõi VT của slice đó (`RX_EN_VTC = 0`) rồi nạp. Một tap trên bo là
  ~1,86–1,89 ps (lần 3: quét từng lane qua tap 0..511 cho hai vùng chuyển bit cách nhau 372–376
  tap = 1 UI; `DELAY_VALUE` 250 ps của PDI thử A dời trễ BISC +132 tap), nên 512 tap ≈ 0,96 ns ≈
  1,4 UI (1 UI = 694 ps; AM010 chỉ hứa 512 tap ≥ 625 ps; model XPHY của mô phỏng: 2,02 ps mỗi tap).
  Trên bo trễ BISC nằm ở **mép sớm** (tap thấp) của eye trên cả 4 lane, như nhau ở cả ba lần (±4
  tap): lần 3, PDI mặc định 122/76/119/129 (trung vị) so với tâm 300/184/260/228 của `cal 8` (eye
  rộng 352–360 tap), tức tâm cao hơn trễ BISC +178/+108/+141/+99 tap = 0,48/0,29/0,38/0,26 UI ≈
  185–330 ps (tài liệu trước ước 1/4 UI khi chưa đo tap). Về thời
  gian: ở trễ BISC cạnh của lane clock rơi muộn trong bit, 0,76–0,98 UI sau đầu bit, tức BISC đặt
  trễ dữ liệu thấp hơn mức cần. Lane 0 nằm sát chỗ chuyển bit (vùng chuyển bit phía tap thấp của
  nó ở tap 112–120, trễ BISC 122–124), nên lỗi CRC ở trễ BISC tuỳ từng tap của lần khởi động: lần
  3 1,33 dòng mỗi frame 1080p ở 123/76/119/130, 48,6 ở 122/75/118/130; lần 2 0,2–1,5; lần 1 ~11 %
  dòng. `margin 0 2` quanh trễ BISC (lần 2, sau `phy reinit`, rồi `start`): lỗi ở tâm và ở 6 trong
  8 điểm (`csi2rx: margin low ...`); `cal 8` ngay sau đó lại cho 300/184/264/228. Vì vậy app
  `camera` / `video` luôn hiệu chỉnh ở `cam` đầu, `csi2_test` cần `cal`. `phy reinit` (`CMD.REINIT`; trước bước 4 PA4) đưa mọi
  lane về trễ BISC mới và bật lại theo dõi VT; BISC lúc lane clock đang stream cho cùng trễ như lúc
  nghỉ.
- **Câu hỏi mở: vì sao BISC không căn giữa** (mục 9.1). Ứng dụng luôn hiệu chỉnh từng lane nên
  ảnh không bị ảnh hưởng.
- **Núm lúc chạy** (mức bất đồng bộ, đồng bộ vào `ctrl_clk_i`; 0 = như PHY của AMD):
  `reinit_i` giữ PHY ở reset khởi động như khi mất khoá XPLL, nhả ra thì XPLL, BISC, VT chạy lại;
  `burst_rst_en_i` = 1: `RX_RST` của các slice dùng khi cổng byte clock đóng, FIFO bắt đầu lại mỗi
  burst. Từ bước 4 cả hai đến từ thanh ghi của D-PHY: `reinit_o` (xung 32 chu kỳ bus khi ghi
  `CMD.REINIT`; xsim `reinit_pulse` kiểm xung 640 ns đó) và `burst_rst_en_o` (¬`CTRL.DES_RST_DIS`,
  1 từ reset); trạng thái {PHY_RDY, DLY_RDY của mọi nibble, LOCKED_FB, LOCKED} vào `AFE_STATUS[15:8]`
  của D-PHY. Trước bước 4: PA4, PA5 và PB6 / PB7. Từ bước 5 module là adapter của giao diện AFE
  ([ip/mipi_rx_arch.md](ip/mipi_rx_arch.md) mục 3.7): `pd_i` (`AFE_CTRL.PD`, mức) và `cal_start_i`
  (xung `CMD.REINIT`) thay `reinit_i`, `des_rst_i` (flop miền lp của D-PHY = ¬cổng, 0 khi
  `DES_RST_DIS` = 1) thay `burst_rst_en_i` (`RX_RST` = `ready` ∧ `des_rst`, cùng chu kỳ như trước);
  logic nạp delay (`RX_EN_VTC`, chờ, `LD`) nằm trong `bow_dphy_dly_xphy` (`u_dly`), nạp khi OWN của
  `DLYn` lên hoặc mã đổi.
- **XPLL** 1500 MHz cho BISC/VT; **byte clock** = `FIFO_WR_CLK` của nibble strobe qua BUFGCE,
  dừng giữa các burst như byte clock của KV260. Dữ liệu ra có `hs_valid` (`rx_valid` tới bước 4)
  theo từng lane.
- Ràng buộc: [constr/huins_vp1902_cam.xdc](../hw/fpga/huins_vp1902/constr/huins_vp1902_cam.xdc),
  [constr/cam_pads.xdc](../hw/fpga/huins_vp1902/constr/cam_pads.xdc); chú thích trong từng file.
- Mô phỏng: `hw/fpga/common/dv/tb_bow_dphy_io_versal.sv` với model XPHY của AMD (secureip,
  cần Vivado, không chạy trong CI), 3 sơ đồ tổng hợp, 25 cấu hình: nạp tap (cùng mã không nạp,
  OWN xuống rồi lên nạp lại), quét tap, lệch lane, glitch của lane clock, lane clock liên tục,
  `des_rst_i` bật giữa burst, `pd_i` khi lane clock nghỉ, đang chạy HS hoặc liên tục (BISC với
  strobe chạy), xung `cal_start_i` 640 ns, tùy chọn `RdenReg` /
  `EnVtcEarly`. `make -C hw/fpga/common/dv test-dphy-versal` (cũng trong `make test-fpga-dv`,
  ~16 phút), một cấu hình: `make -C hw/fpga/common/dv run-dphy-versal DPHYV_CFG=reinit_idle
  WAVES=1`. `make lint` lint module (3 sơ đồ, và một sơ đồ phải bị từ chối) và top camera với
  stub chỉ có cổng của primitive AMD (`hw/lint/xilinx_versal_stubs.sv`); `make -C
  hw/fpga/huins_vp1902 test-plan` kiểm luật của `tcl/cam_plan.tcl`.

### 9.1 Độ lệch của BISC: lần chạy bo 3 và phần tìm hiểu (2026-11-11)

Ở lần 1–2, giả thuyết là BISC căn trễ cho một strobe căn theo mép dữ liệu (như DQS của bộ nhớ khi
đọc) trong khi lane clock của D-PHY căn giữa dữ liệu. Lần 3 và phần tìm hiểu đi kèm loại giả thuyết
đó và thu hẹp câu hỏi.

**So với IP MIPI D-PHY RX của AMD** (một bản build thử cho cùng các chân FMC+01, không có trong
repo): netlist đã route của PDI mặc định có mọi thuộc tính XPHY như nhau: `RX_CLK_PHASE_P/N`
`SHIFT_0` (lane clock căn giữa dữ liệu), `DQS_MODE` `DDR4_1TCK`, `SELF_CALIBRATE` `ENABLE`,
`REFCLK_FREQUENCY` 1500, `DELAY_VALUE` 0, `CRSE_DLY_EN` / `INV_RXCLK` `FALSE`, cùng `DQS_SRC`, gating
và độ rộng dữ liệu; XPLL như nhau (×15, /2 = 1500 MHz); cách dùng cổng như nhau (IP của AMD không
nạp tap ở ≤ 1,5 Gbit/s; thiết kế tham chiếu của AMD trên VCK190 nhận chính module này ở 1440
Mbit/s chỉ với BISC). Khác duy nhất: slice N của mỗi cặp dùng (của AMD: chế độ XPHY, FIFO `ASYNC`, có reset, Q được đọc; của
Bow32: `BYPASS`). Wrapper đã đặt lane clock căn giữa như AMD, nên giả thuyết "strobe căn mép"
không đúng.

**Model XPHY** (xsim, secureip) với các thuộc tính của bo đặt điểm lấy mẫu đúng giữa bit. Chỉ hai
núm dời điểm lấy mẫu so với dữ liệu: `SHIFT_90` (clock muộn thêm nửa chu kỳ `PLL_CLK`, ~0,48 UI ở
1500 MHz: trên bo chỉ làm lỗi đổi chiều) và `DELAY_VALUE` (dữ liệu muộn hơn; BISC cộng nó vào trễ
của lane). Slice N, `PLL_CLK` 3000 MHz với `SHIFT_0`, `DQS_MODE` `DDR4_2TCK`, `CRSE_DLY_EN`,
`INV_RXCLK` không dời. BISC bù được độ trễ của dây chuyển strobe (model và bo đều thấy): phần chênh
của trễ BISC giữa các lane chủ yếu là phần bù đó.

**Hai PDI thử trên bo** (lần 3; mỗi PDI một generic thêm tạm vào `bow_dphy_io_versal`, mặc định
giữ netlist như cũ, chưa vào repo; timing ở đầu tài liệu). Tâm là của `cal 8` (eye 352/360/352/352
trên cả ba PDI), UI theo lần quét tap (372–376 tap):

| PDI | Trễ BISC | Tâm | Tâm − BISC (tap) | Tâm − BISC (UI) | CRC ở trễ BISC, 601 frame | `start` |
|-----|----------|-----|------------------|-----------------|---------------------------|---------|
| mặc định | 122/76/119/129 | 300/184/260/228 | +178/+108/+141/+99 | 0,48/0,29/0,38/0,26 | 799 | `link check failed` |
| B: slice N như AMD (`NSliceXphy` = 1) | 123/76/120/130 | 300/184/260/228 | +177/+108/+140/+98 | 0,47/0,29/0,38/0,26 | 2632 | `link check failed` |
| A: `DELAY_VALUE` 250 ps trên slice P của các lane dữ liệu (`DataDlyPs` = 250) | 256/208/252/262 | 300/184/260/228 | +44/−24/+8/−34 | 0,12/−0,06/0,02/−0,09 | 0 | `link check ok` |

Cả ba `test` PASS 17/17; trễ BISC lúc đang stream như lúc nghỉ trên cả ba (A: theo dõi VT dời 1–4
tap). B như PDI mặc định trong 1 tap: cách dùng slice N của Bow32 không phải nguyên nhân (B còn khác
IP của AMD một điểm: Vivado nối DATAIN của slice N về 0, flow IP của AMD để hở). A dời mọi trễ BISC
+132 tap (250 ps, ~1,89 ps mỗi tap) mà tâm không đổi; ở trễ BISC của A, `margin` ±88/±88/±90/±88
tap 0 lỗi (9 × 60 frame). Vậy phần chung (trung bình ~131 tap ≈ 0,35 UI ≈ 245 ps) là một thời gian
cố định nằm ngoài những gì BISC đo, và `DELAY_VALUE` bù được nó; phần riêng từng lane (78 tap giữa
lane lệch nhiều nhất và ít nhất, ~0,21 UI) vẫn còn. A đạt hai phần của tiêu chí sửa (link sạch ở
trễ BISC không cần hiệu chỉnh, `test` PASS) nhưng không đạt phần "trễ BISC trong ±20 tap của tâm
trên mọi lane" (lane 0, 1, 3), nên RTL và mặc định không đổi. Đặt `DELAY_VALUE` ≈ 250 ps làm mặc
định cho top camera Huins là việc cho sau (CI đầy đủ, PDI mới, kiểm lại trên bo), và ứng dụng vẫn
phải hiệu chỉnh.

**Phần riêng từng lane** không theo số chặng chuyển strobe, và package của FPGA (lệch giữa dữ liệu
và clock) chỉ giải thích tối đa ~40 ps: ít nhất ~0,2 UI lệch giữa các lane đến từ cảm biến, module,
bo chuyển và bo mạch, nơi BISC không thấy. Dù nguyên nhân chung là gì, vẫn cần hiệu chỉnh từng lane
(hay một giá trị riêng cho từng bo).

**Còn hai giả thuyết cho phần chung:**

- lane clock đến muộn hơn các lane dữ liệu ~250 ps (~37 mm) trên đường ngoài FPGA (cảm biến,
  module, bo chuyển, bo mạch);
- một số hạng pha của silicon gắn với `PLL_CLK` (nửa chu kỳ = 333 ps khớp lane 0 nhưng không khớp
  trung bình; IP của AMD dùng cùng `PLL_CLK` và thuộc tính): ít khả năng hơn.

Phép thử kế tiếp (chưa build): PDI với `PLL_CLK` 3000 MHz (nếu là nửa chu kỳ PLL thì độ lệch giảm
~87 tap); một cửa sổ AXI4-Lite tới RIU của XPHY trên cổng AXI4-Lite còn trống của top camera, để
`rd` / `wr` của `csi2_test` đọc các thanh ghi căn chỉnh của BISC sau BISC và dời chúng lúc chạy; IP
CSI-2 RX của AMD trên cùng các chân làm chuẩn so sánh (nếu nó cũng lỗi ở trễ BISC trên bo này thì
nguyên nhân không ở thiết kế của Bow32). Chưa giải thích: trong lần quét tap của lần 3, vùng chuyển
bit phía tap cao của mỗi lane (24–32 tap) rộng gấp 2–3 lần vùng phía tap thấp (8–20 tap).

Cho tài liệu kiến trúc của bộ thu MIPI (`docs/ip/mipi_rx_arch.md`, chưa vào main): khi gộp, mục 7
của nó cần các kết quả trên: thay "1/4 UI" bằng 0,26–0,48 UI (tap ~1,86–1,89 ps), bỏ giả thuyết
strobe căn mép và giả thuyết slice N, giữ hai giả thuyết còn lại và `DELAY_VALUE` như một núm tuỳ
chọn theo bo.
