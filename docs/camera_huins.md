# Camera trên Huins MFP-VP1902: IMX274 (LI-IMX274MIPI-FMC) → ISP của Bow32

Hướng dẫn chạy bộ thu MIPI CSI-2 và ISP của Bow32 với camera Sony IMX274 (module Leopard
LI-IMX274MIPI-FMC, 4 lane × 1440 Mbit/s) trên bo Huins MFP-VP1902-S (AMD Versal Premium
`xcvp1902-vsva6865-2MP-e-S`): build device image (PDI) có D-PHY **của Bow32** trên XPIO của
Versal (không dùng IP MIPI/D-PHY của AMD), nạp qua USB JTAG, nạp ứng dụng qua UART, stream,
chụp ảnh PNG về PC, quay video H.264 và kiểm tra bộ thu bằng `csi2_test`, giống luồng IMX219
trên KV260 ([camera_kv260.md](camera_kv260.md), [video_kv260.md](video_kv260.md)). Trước khi
đọc, hãy chạy được Bow32 trên bo này theo [ddr_huins.md](ddr_huins.md) (JTAG, console
"UART0"). Chi tiết bộ thu: [ip/csi2rx.md](ip/csi2rx.md).

> **Trạng thái (2026-11-10): chạy trên bo lần 1 xong**, với commit trước khi gộp main
> (`aaf7ed4`): camera chạy, 4 lane × 1440 Mbit/s (byte clock 180,078 MHz), `csi2_test` PASS
> 15/15 sau `cal`, 1080p30 và 720p60 không lỗi (hơn 15 000 frame, ~15 phút), sọc màu đúng thứ
> tự, cảnh thật màu tự nhiên, video H.264 1080p giải mã không lỗi. Các phát hiện của lần chạy
> này đã sửa trong firmware (chưa chạy lại trên bo): VMAX sau reset là 0x906 chứ không phải
> 0x905 (mục 6.2), thứ tự Bayer vẫn RGGB khi lật dọc (mục 6.4), trễ BISC nằm ở mép sớm của eye
> nên app luôn hiệu chỉnh ở `cam` đầu (mục 6.4, 9), PA5 = 0 không dùng được (mục 6.3), `stat`
> liệt kê 4 lane cả khi bộ thu tắt, AE/AWB dừng khi test pattern bật, `rec` 1080p ghi đủ 30
> frame (mục 6.5). Lần chạy bo 2 (bản gộp main PR #17 cùng các sửa này) chưa làm.
>
> PDI của lần 1 (trước khi gộp main): có mọi sửa sau review (núm của D-PHY trên PA4/PA5 và
> trạng thái trên PB6/PB7, sơ đồ nibble suy ra lúc build, ràng buộc bus skew thứ 11, kiểm tra
> VCCIO của khe, danh sách CDC đã duyệt, `pdi_site.txt`), build ngày 2026-11-10 trên
> hw-station-1 (Vivado 2025.2, `JOBS=8`, 25 phút) bằng lệnh của mục 4: timing đạt, WNS +0,180 ns
> (`clk_vid`), WHS +0,018 ns (`clk_vid`), byte clock 180 MHz +1,623 ns / +0,026 ns, `clk_sys`
> +3,484 ns / +0,037 ns; bus skew 11/11 đạt (slack nhỏ nhất +3,781 ns: đọc lại tap `DLYn` từ
> XPHY); không có `CRITICAL WARNING`; DRC chỉ có warning và advisory; `methodology.rpt` 45 mục,
> 1 mục có waiver; sơ đồ nibble và kiểm tra `pre_opt_cam` đạt; 16 cổng trên VCCIO của FMC+01; SoC
> ở SLR0. RTL đã gộp main chưa build thành PDI. Firmware: mỗi lần khởi động bộ thu đặt PA5 = 1
> (`BurstRxRst`) với `SETTLE` 95 ns (mục 6.3). Mô phỏng: D-PHY Versal với model XPHY của AMD,
> 24/24 cấu hình (`make -C hw/fpga/common/dv test-dphy-versal`, mục 9); hệ thống với firmware thật
> (`camera274`, `csi2_274`, `video274`, [simulation.md](simulation.md)). Đầu ra ở mục 6 lấy từ lần
> chạy bo 1 khi có số đo, còn lại theo mã nguồn và mô phỏng.

```
 LI-IMX274MIPI-FMC ─adapter Huins─► FMC+01 ──► bow_dphy_io_versal ──► bow_csi2rx ──RAW10──► ISP Bow32 ──► capture / H.264 ──► CPU ──UART0──► PC
 (IMX274)       4 lane × 1440 Mb/s  bank 705   (IBUFDS_DPHY, XPHY,     CSI2RX         AXI4-S    (200 MHz)                      (sw/apps)  (PNG,
      ▲         RAW10                          XPLL, BUFGCE)           0x4000_8000                                                        bow32_cam.py)
      │                                                                     ▲ thanh ghi (peripheral bus)
      └── I2C0 (IMX274 ở 0x1A, không có switch) ◄── Ibex ───────────────────┘
          PA7 = XCLR (1 = cảm biến chạy), PA4/PA5 = núm của D-PHY
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
| bus skew | `bus_skew.rpt` | 11 ràng buộc `set_bus_skew` (FIFO pixel 2, đồng hồ đo byte clock, yêu cầu / trả lời LOG và RAW 4, yêu cầu nạp tap `DLYn` + tap, đọc lại tap `DLYn` từ XPHY, FIFO ra của H.264 2), cả 11 `Slack (MET)`. PDI 2026-11-10 (sau review): 11/11, slack +3,781 … +5,016 ns |
| sơ đồ nibble | `vivado.log` | `INFO: XPHY nibble plan pins_fmc1_xphy_plan.txt: bank 705, 4 XPHY nibbles (generics of bow32_huins_vp1902_cam_top)` |
| XPHY | `io_sites.rpt`, log | trước place: `INFO: pre_opt_cam: 4 XPHYs placed at their pins, nibble plan fits bank 705`; sau route: 4 XPHY đúng các nibble của sơ đồ, lane clock ở slice 0 của XPHY strobe, luật chuyển strobe của AM010 đúng (`tcl/cam_xphy.tcl`) |
| chân | `io_sites.rpt` | 4 `ODDRE1` của I2C (I và T, DRC PDCN-2749) trong `XPIOLOGIC`; 40 flop bắt dữ liệu có `BLI` trong site BLI |
| VCCIO của khe | `io_sites.rpt`, log | 16 cổng ở bank 703..706 (cùng nguồn SW192): 10 chân `MIPI_DPHY` và 5 chân `LVCMOS12` ở bank 705, `PRSNT_M2C_L` ở bank 703, không cổng nào dùng chuẩn khác; `INFO: I/O banks used: ... (16 ports on the FMC+01 site VCCIO, 1.2 V)`. Chỉ kiểm ràng buộc: **không thấy SW192**, switch chỉ kiểm được bằng LED "1.2" và TP29 (mục 2) |
| CDC | `cdc.rpt`, log | mọi mục nghiêm trọng của `report_cdc` (CDC-1, -4, -7, -10 … -14) thuộc các loại đã duyệt ở lần build đầy đủ đầu tiên (`bow32_huins_cam_cdc_known` trong `tcl/timing_checks_cam.tcl`: cấu hình ISP / H.264 gần tĩnh, chân CLR của bộ đồng bộ reset, enable lane của bộ thu, cổng byte clock); mục khác là crossing mới phải xem lại; số mục mỗi loại in ở dòng `INFO: report_cdc ...` |

Trước place, `tcl/pre_opt_cam.tcl` gán LOC cho từng XPHY theo chân của nó (Vivado không tự đặt
XPHY ngoài IP của AMD: DRC AVAL-314) và kiểm lại, độc lập, sơ đồ của netlist với chân thật,
dừng build nếu không khớp; `tcl/pre_place_cam.tcl` đặt MMCM và toàn bộ SoC vào SLR của camera
(SLR0) và cho phép clock 200 MHz (bank 718, SLR3) đi qua các SLR (`CLOCK_DEDICATED_ROUTE`).

Cảnh báo bình thường (`methodology.rpt` của PDI 2026-11-10, trước và sau các sửa review: 45 mục,
1 mục có waiver):

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
~40 µs, AM010: tới 1,3 ms). PA4 khởi động lại riêng D-PHY (mục 5). Trên bản này
`INFO.DLY_VID` = 1, nên `bow_csi2rx_start()` chờ `STATUS.PHY_RDY` tối đa 10 ms rồi mới bật bộ
thu (với `DLY_VID` = 0, như trên KV260, nó không chờ).

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
```

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
| U_LED10 | D-PHY sẵn sàng (XPLL khoá, BISC xong: `CSI2RX.STATUS.PHY_RDY`) |
| U_LED11 | có một bo trên FMC+01 (`PRSNT_M2C_L` = 0; không phân biệt bo camera với bo RAM) |
| U_LED12 | MMCM khoá (clock SoC và video) |

GPIO (sau reset mọi chân PA là input, nên cả hai núm của D-PHY = 0):

| Chân | Việc |
|------|------|
| PA0..PA3 | LED U_LED1..4 |
| **PA4** | khởi động lại D-PHY: output 1 giữ PHY ở reset khởi động (`STATUS.PHY_RDY` = 0, tap đã nạp bị bỏ); về 0 hoặc input: XPLL khoá, BISC, theo dõi VT chạy lại. Giữ ≥ 10 µs (`csi2_test`: `phy reinit`) |
| **PA5** | `BurstRxRst`: output 1 = reset FIFO RX của XPHY mỗi khi cổng byte clock đóng (mỗi burst bắt đầu lại); 0 hoặc input = không reset (như PHY của AMD). Firmware đặt PA5 = 1 khi khởi động bộ thu trên bản Versal (`INFO.DLY_VID` = 1); `csi2_test`: `phy burstrst 0\|1` |
| PA6 | không ra chân |
| **PA7** | XCLR: output 1 = cảm biến chạy; sau reset PA7 là input nên cảm biến bị giữ reset (giống "PA7 = 1 → bật camera" của KV260) |
| PB0 / PB1 | UART1 |
| PB2..PB4 | nút U_PB SW01..03 (1 khi nhấn) |
| **PB5** | `PRSNT_M2C_L` của FMC+01, 0 = có module (khác bản bo RAM, nơi PB5 = 1 nghĩa là có bo) |
| **PB6** | `PHY_RDY` của mọi nibble XPHY: trạng thái thô của XPHY (không qua bộ tuần tự khởi động như `STATUS.PHY_RDY`, vốn cần thêm XPLL khoá) |
| **PB7** | `DLY_RDY` của mọi nibble (hiệu chỉnh trễ của BISC xong; PB7 = 1 mà PB6 = 0: hiệu chỉnh xong, `PHY_RDY` không lên) |

PB6 / PB7 đi qua bộ đồng bộ đầu vào của GPIO (`rd 40005000`: bit 6, 7). I2C0 nối thẳng cảm
biến (IMX274 ở địa chỉ 7 bit 0x1A, không có switch I2C; pull-up trong FPGA, chạy ở 100 kHz).

## 6. Nạp và chạy ứng dụng

> Đầu ra trong mục này: số đo của lần chạy bo 1 (2026-11-10, firmware trước khi gộp main) khi
> có ghi, còn lại theo mã nguồn và mô phỏng (`camera274`, `csi2_274`, `video274`). `a/b/c/d` là
> giá trị của 4 lane.

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

| Thông báo | Nghĩa, việc cần làm |
|-----------|---------------------|
| `camera: no IMX219 on I2C (error -1)`, `camera: no IMX274 on I2C (error -1)` rồi `camera: FMC+01 PRSNT_M2C_L (PB5) = 1: no module on the site` | không có gì trả lời ở 0x1A, không có bo trên FMC+01 |
| như trên nhưng `PB5 = 0: a module is plugged in` | có bo nhưng cảm biến không trả lời: SW192 (LED "1.2"), XCLR (LED8 phải sáng sau probe), I2C (mục 8) |
| `camera: unknown sensor at 0x1a: MDSEL1..4 .. .. .. .., HMAX ...., VMAX ...... (IMX274 after reset: 03 31 00 09, 0104, 000905 or 000906, BLKLEVEL reads back)` | có thiết bị trả lời ở 0x1A nhưng không có giá trị sau reset của IMX274: dòng in đúng các giá trị đã đọc (thêm `BLKLEVEL 33 read back as ..` khi chỉ phép ghi / đọc lại sai). So với giá trị trong ngoặc: một giá trị lệch ít (như VMAX 0x906 của lần chạy đầu, khi driver chỉ nhận 0x905) là biến thể của cảm biến; mọi giá trị khác hẳn: XCLR (LA22_N, PA7) không reset được cảm biến, hoặc một thiết bị khác ở 0x1A |
| `error: D-PHY not ready (CSI2RX STATUS.PHY_RDY = 0)` (sau `start` / `cam`, sau 10 ms) | XPLL + BISC chưa xong: LED7 / LED10, `phy` của `csi2_test`, thử lại BISC (mục 6.3) |
| `csi2rx: Bow32 receiver, no D-PHY in this bitstream - ISP test pattern only` | đang chạy PDI bo RAM → nạp PDI camera |

### 6.3 Bring-up bằng `csi2_test`

`csi2_test` mặc định 1080p30 (HMAX 400 / VMAX 6000) và test pattern `tp 3` (màu đơn 555h).
Trên bản Versal (`INFO.DLY_VID` = 1) có thêm `phy`, `phy reinit`, `phy burstrst 0|1` và
`sensor on|off` (trên KV260 các lệnh này là `unknown command`):

```
> phy                     # trước khi stream: PHY_RDY, trạng thái thô PB6/PB7, hai núm, trễ BISC
phy: STATUS.PHY_RDY 1, every nibble PHY_RDY 1 DLY_RDY 1 (PB6 PB7), reinit 0 burstrst 0 (PA4 PA5)
     delays in use a/b/c/d                      (lần 1: 122/75/118/130)
> stat                    # cảm biến ở standby: LP-00 trước stream đầu, LP-11 sau `stop` (lần 1)
csi2rx: no data
  ...
  phy: lp clk 00 d0 00 d1 00 d2 00 d3 00, bursts 0/0/0/0 clk 0, delay a/b/c/d
> start                   # bộ thu (firmware đặt PA5 = 1, SETTLE 95 ns) rồi cảm biến; không hiệu chỉnh
streaming 1920x1080 RAW10, link check failed (ERR_STATUS 008), try cal
> cal 8                   # bản đồ eye từng lane, bắt đầu từ trễ BISC; nạp tap
csi2rx: calibrated taps a/b/c/d eye a/b/c/d     (lần 1: 300/184/264/228 eye 352/360/360/352)
> stat
csi2rx: link ok
  frames 31 lines/frame 1080 wc 2400 dt 2b sum ........ frame errors 000
  errors: ecc 0/0 crc 0 trunc 0 sot 0/0/0/0 ovf 0 misc 0 extra 0 (dropped by DT/VC 279)
  timing: frame 33333 us, line 11120 ns, byte clock 180078 kHz
  phy: lp clk .. d0 .. d1 .. d2 .. d3 .., bursts n/n/n/n clk n, delay a/b/c/d
> log fs                  # 64 packet từ FS: FS, EMB (dt 12, wc 175), 8 x OB (dt 37), RAW10 (dt 2b, wc 2400)
> raw                     # 64 word thô mỗi lane từ burst kế tiếp: b8 sau HS-zero, "sync byte at bit ..."
> delay 2 150             # đặt tap 0..511 của một lane bằng tay
lane 2 tap 150: in use
> margin 0 60             # lề quanh tap đang dùng của cả 4 lane (k = eye / 4 của lần cal cuối)
> tp 11                   # sọc màu của cảm biến; tp 0: cảnh thật
> test                    # mọi check: 1080p30 rồi 720p60 (HMAX 300 / VMAX 4000)
...
csi2_test: PASS (17/17)
```

Ở trễ BISC, `start` in `link check failed (ERR_STATUS 008), try cal`: trên bo lần 1 lỗi CRC ở
~11 % số dòng (119–148 dòng mỗi frame 1080p), vì trễ BISC nằm ở mép sớm của eye trên mọi lane
(mục 9). Luôn `cal 8` sau `start` đầu, rồi `stat` (lần 1: 0 lỗi sau `cal`, hơn 15 000 frame).
Trong `stat`, số packet `dropped by DT/VC` tăng 9 mỗi frame ở 1080p (1 dòng embedded + 8 dòng
optical black bị bộ lọc DT bỏ), 5 ở 720p (1 + 4): bình thường. Khi bộ thu tắt (`stop`, `sensor
on`) `stat` vẫn liệt kê cả 4 lane của bản build. `margin` đo quanh trễ **đang dùng** của mọi
lane (sau `delay`, hay trễ BISC sau `phy reinit`), k theo eye của lần `cal` cuối. `test` chạy
phy-idle; link-up, calibrate, margin (AAAh: IMX274 không có PN9), integrity (555h rồi AAAh),
packets, timing ở 1080p30 rồi 720p60; isp, filter, restart, irq (17 check: IMX274 không có
RAW8; firmware của lần 1, trước khi gộp main, chưa có `margin`: 15/15). `mode 1080p`, `mode
720p`, `mode <w> <h> [fps]` đổi kích thước; `mode 4k` bị từ chối (`error: a 3840 pixel line
leaves ~630 groups in the receiver FIFO, it has 512 (4K: 1024 needed)`). Ghi lại: trễ BISC của
từng lane, trạng thái lane ở standby, các dòng `[PASS]` (tổng và mean của 555h / AAAh, màu của
sọc, mức xám), tap và độ rộng eye của `cal 8`.

**Khi BISC không xong** (`start` → `error: D-PHY not ready ...` và gợi ý `phy: nibble status;
sensor on + phy reinit: BISC with a running clock`; LED7 sáng, LED10 tắt). Lúc PDI nạp, cảm
biến còn bị reset và các lane ở LP-00; nếu BISC cần strobe đang chạy, cho cảm biến stream mà
chưa bật bộ thu rồi khởi động lại PHY:

```
> phy                     # PB7 = 1, PB6 = 0: hiệu chỉnh xong, PHY_RDY không lên; cả hai 0: BISC chưa xong
> sensor on               # cảm biến stream, bộ thu tắt: lane clock chạy
sensor: streaming 1920x1080, receiver off (PHY_RDY 0)
> phy reinit              # xung PA4 10 us: XPLL khoá + BISC lại, lần này có strobe
phy: PHY_RDY n us after the reinit pulse
phy: STATUS.PHY_RDY 1, every nibble PHY_RDY 1 DLY_RDY 1 (PB6 PB7), ...
     delays in use a/b/c/d
> start                   # dừng cảm biến, bật bộ thu, chạy lại cảm biến
```

`phy reinit` cũng dùng được lúc đang stream (in thêm `phy: the receiver ran through it:
start`: gõ `start`); nó bỏ mọi tap đã nạp (lane về trễ BISC mới, theo dõi VT bật lại).
`phy: PHY_RDY still 0 10 ms after the reinit pulse`: xem VCCIO (SW192), LED7. `error: PHY_RDY
stayed 1 during the reinit pulse (no PA4 knob in this bitstream?)`: PDI có trước núm PA4 →
build lại. `sensor off` đưa cảm biến về standby. Sau `sensor on` bộ thu tắt: `cal`, `log` và
`raw` báo `error: receiver off (sensor on): start`.

**`BurstRxRst` và SETTLE.** Firmware bật PA5 = 1 (FIFO RX của XPHY bắt đầu lại mỗi burst) khi
khởi động bộ thu và giữ `SETTLE` 95 ns. Đo trên bo lần 1 (720p60, tap đã hiệu chỉnh): với PA5 =
1, `SETTLE` 95 ns chạy 4462 frame (hơn 3,2 triệu burst) không lỗi, và mọi `SETTLE` từ 13 tới 34
chu kỳ (65–170 ns) đều sạch; 8–12 chu kỳ có lỗi misc (SKEW / FRAME), 35 chu kỳ có lỗi SOT, từ 36
chu kỳ không còn frame. 95 ns cách mép dưới 30 ns (tâm cửa sổ ~118 ns). Với PA5 = 0 (`phy
burstrst 0`) link chỉ sạch tới lần bật lại bộ thu đầu tiên trong lúc stream; sau đó lane 0 hỏng
hẳn (`ERR_STATUS` 14b: SOT, ECC_CORR, CRC, SKEW, FRAME; `misc` 255 mỗi giây, mất frame) ở mọi
`SETTLE` đã thử (50–150 ns) và chỉ hết khi PA5 = 1 lại. **Không dùng PA5 = 0 trên bo.** Mô phỏng
trước đó dự đoán cửa sổ ~80–116 ns với PA5 = 1 và cho rằng PA5 = 0 chạy được với `SETTLE`
~115 ns: silicon khác ([ip/csi2rx.md](ip/csi2rx.md), mục *Bốn lane, PHY Versal và IMX274*).
`SETTLE` là `PHY_CFG[7:0]` (`0x4000_800C`, chu kỳ 5 ns), chỉ đổi được khi `PHY_EN` = 0, và
`start` / `mode` ghi lại giá trị của driver: quét lại theo các lệnh dưới đây (giữ PA5 = 1).

```
> start
> rd 40008008              # CTRL của driver: 00c02b87 (EXTRA 192, DT 0x2B, 4 lane, PHY_EN, RX_EN)
> rd 4000800c              # PHY_CFG của driver: 051e0213 (SETTLE 0x13 = 19 chu kỳ = 95 ns)
> wr 40008008 c02b84       # CTRL: tắt PHY_EN, RX_EN, giữ các trường khác
> wr 4000800c 051e0217     # SETTLE 0x17 = 23 chu kỳ = 115 ns, các trường khác như driver
> wr 40008008 c02b87       # bật lại PHY_EN, RX_EN
> wr 40008020 1            # CNT_CLR
> stat
```

Tuỳ chọn build `CAM_BURST_RST=0` cùng `SETTLE_VID_NS=115` (`sw/common/include/cam_sensor.h`,
`sw/common/src/bow_csi2rx.c`: mọi lần khởi động bộ thu đặt PA5 = 0) chỉ còn cho mô phỏng:
`make -C sim run TEST=csi2_274 FW=brst0` (cũng trong `make -C sim test-extra`) chạy sạch trên mô
hình PHY, bo thật thì không.

### 6.4 Ứng dụng `camera`

```
> cam                      # 1080p30 RGGB (HMAX 400 / VMAX 6000): ISP, bộ thu, cảm biến, hiệu chỉnh
csi2rx: calibrated taps a/b/c/d eye a/b/c/d     (lần 1: 296/184/264/224 eye 352/352/352/336)
csi2rx: margin ok +-k/+-k/+-k/+-k taps: 0 errors in 9 x 8 frames, BER < ...
streaming 1920x1080 RGGB
ok
> ae on                    # auto exposure (SHR, rồi gain)
> awb on                   # white balance gray world
> stat                     # thống kê frame kế tiếp
> csi                      # trạng thái bộ thu như stat của csi2_test
> mode 720p                # 1280x720 @60 fps
mode 1280x720 @60 fps (HMAX 300 VMAX 4000)
> mode 1080p
mode 1920x1080 @30 fps (HMAX 400 VMAX 6000)
> mode 4k                  # bị từ chối: ISP tối đa 2048 pixel
error: size must be even, 16..2048 x 8..2174
> info                     # ISP, mode (HMAX, VMAX, fps), cảm biến, AE/AWB, bộ thu
> tp 11                    # sọc màu của cảm biến (0 tắt, 1..4 màu đơn 000/FFF/555/AAA, 12 sọc ngang)
> exp 2000                 # exposure theo chu kỳ HMAX (tắt AE)
> gain 0                   # 0..1957, gain = 2048 / (2048 - code)
> flip 0 1                 # lật dọc, vẫn RGGB (IMX274 không có lật ngang: flip 1 0 bị từ chối)
> cal                      # hiệu chỉnh lại eye (bước 16)
> margin                   # lề quanh tap đang dùng, k = eye / 4, 60 frame mỗi điểm
```

`cam`: cấu hình ISP → `bow_csi2rx_start(4, RAW10, 1440 Mbit/s)` khi IMX274 còn ở standby
(LP-00; hàm chờ `PHY_RDY`) → bước 1 của chuỗi thoát standby qua I2C 100 kHz (~26 ms) → ISP →
stream (chờ 11 + 8 ms; frame đầu không được xuất) → hiệu chỉnh. `cam` **đầu tiên luôn hiệu
chỉnh**, trên bản Versal cũng vậy (`csi2rx: calibrated taps ...`, rồi kiểm tra lề `csi2rx:
margin ok +-k/... taps` 8 frame mỗi điểm): trên bo lần 1 trễ BISC nằm ở mép sớm của eye trên mọi
lane (tâm eye sau hiệu chỉnh cao hơn trễ BISC +98…+178 tap; lane 0 sát mép; ~11 % dòng lỗi CRC
ở 1080p), và 64 packet sạch của một link check có thể là may (firmware của lần 1 giữ trễ BISC
khi link check qua). Sau đó app giữ tap và chỉ hiệu chỉnh lại khi link check thấy lỗi lấy mẫu
(`CSI2RX_ERR_TAP`) hay không có dữ liệu; lỗi khác (EXTRA, FORMAT, FRAME, OVF) giữ tap (`taps
kept`). Mỗi tap nạp làm lane đó thôi theo dõi VT (mục 9), nên sau khi bo nóng lên hãy xem lại
`csi` (`cal` hiệu chỉnh lại). `margin [k] [frames]` đo quanh trễ đang dùng của mọi lane: sau
hiệu chỉnh là tap đã hiệu chỉnh (k = eye / 4); nếu lần hiệu chỉnh đầu thất bại thì quanh trễ
lane đang giữ, k = 40 (`csi2rx: not calibrated: margin around the delays in use ...`), không bao
giờ nạp tap 0. `stop`, `mode`, `tpg`: IMX274 vào standby là cắt ngang frame, nên app chờ hết
frame, tắt bộ thu rồi mới đưa cảm biến về standby. AE/AWB ghi cảm biến tối đa một lần mỗi frame
và **dừng khi test pattern của cảm biến bật** (`tp` khác 0): test pattern không đổi theo
exposure / gain / white balance, nên ở lần 1 AE đã đẩy exposure xuống 1 khi `tp 11` và các frame
đầu sau `tp 0` đen tới khi AE tăng lại (~1 s); nay AE/AWB đứng yên và chạy tiếp từ giá trị cũ.

Ảnh về PC (đóng `monitor` trước):

```bash
python3 tools/bow32_cam.py -p $PORT --fast 921600 cmd cam "ae on" "awb on"
python3 tools/bow32_cam.py -p $PORT -b 921600 snap -o frame.png                # 240x135 ở 1080p, 160x90 ở 720p
python3 tools/bow32_cam.py -p $PORT -b 921600 snap -o crop.png --center 240 135   # 1:1 giữa ảnh
```

Khi lật dọc (`flip 0 1`) thứ tự Bayer vẫn là RGGB: đo trên bo lần 1 (cảnh thật và sọc màu đúng
với RGGB; GBRG, phỏng đoán cũ của driver, cho ảnh tím, mean RGB 140/9/149; BGGR đổi R và B), như
driver Linux; `imx274_bayer()` trả RGGB với cả hai. Ma trận màu và cân bằng trắng ban đầu lấy của
IMX219; trên cảnh văn phòng của lần 1 màu đã tự nhiên (AWB r 425..437 b 454..463).

### 6.5 Video H.264 (`video`)

App `video` đặt dòng của IMX274 dài cho bộ mã H.264 (392 chu kỳ mỗi macroblock ở 200 MHz): tải
~78 % như IMX219 trên KV260 ([video_kv260.md](video_kv260.md) mục 4). Mặc định 720p30 (HMAX
448 / VMAX 5357); `mode 1080p` → HMAX 672 / VMAX 3571.

```bash
python3 tools/bow32_flash.py -p $PORT --no-break flash build/sw/video/video.bin   # sau wr ... RST! (mục 6.1)
python3 tools/bow32_video.py -p $PORT --fast 921600 rec -n 45 --skip 1 -o video.mp4   # 720p30 (mặc định)
python3 tools/bow32_video.py -p $PORT -b 921600 rec --mode 1080p -n 30 --skip 1 -o video1080.mp4
```

(`rec` chỉ gửi `mode` khi có `--mode`: không có thì board giữ mode đang dùng.) `cam` lần đầu
hiệu chỉnh như app `camera` (`csi2rx: calibrated taps ...`, `csi2rx: margin ok ...`) rồi in
`streaming 1280x720 @30 fps`, và `mode 1080p` in `mode 1920x1080 @30 fps (HMAX 672 VMAX 3571)`.

Rate control của `rec` ([video_kv260.md](video_kv260.md) mục 3): mỗi frame nhắm phần chỗ trống
còn lại chia cho số frame còn lại, QP của frame sau = QP vừa dùng + 6 · log2(kích thước / đích)
(tối đa ±12), QP đầu tự chọn theo kích thước frame (`qp auto`, mặc định của app và của
`bow32_video.py`; `--qp n` để cố định). Lần chạy bo 1 (QP đầu 30, mỗi frame ±1) bắt đầu bằng
frame 77 KB so với đích 35 KB, tới frame 8 mới lên QP 37 và video RAM đầy sau 20 trong 30 frame
1080p (`video RAM full`; không lỗi encoder). Với rate control mới, QP đầu ở 1080p, 30 frame là
37, và 30 frame vừa 1 MiB (mô phỏng với kích thước frame của lần 1: QP 37–39,
`tools/tests/test_h264_model.py`); `rec` in QP của từng frame (`frame k: n bytes, QP q, t us`).
Ở 1080p50 / 1080p60
(`mode 1920 1080 60`) frame rate không còn chỗ cho dòng
dài: app in `note: H.264 load 97 % (HMAX 542): detailed scenes at a low QP may drop pixels, a
lower frame rate gives longer lines`. Khi encoder bỏ pixel, `rec` in `warning: the encoder
dropped pixels (H.264 load 78 %: raise qp or give rec fewer kbytes per frame)` (trên 80 % thêm
`lower the frame rate for longer lines, `).

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

## 7. Danh sách kiểm khi bring-up trên bo

Theo thứ tự. Mục nào lệch với "mong đợi" thì dừng và ghi lại trước khi đi tiếp.

| # | Khi nào | Làm / đo | Mong đợi, ghi lại |
|---|---------|----------|-------------------|
| 1 | bo bật, chưa cắm module | LED cạnh SW192, TP29; PG_C2M của FMC+01 (chân D1 của FMC) trên bo chuyển | chỉ "1.2", TP29 ≈ 1,2 V. Netlist có chỗ cho điện trở kéo PG_C2M lên 3,3 V và 5 V (không rõ lắp cái nào): ghi mức đo được, 5 V thì hỏi lại trước khi cắm module |
| 2 | module cắm, FPGA chưa cấu hình | mức nghỉ của SCL / SDA (LA26), XCLR (LA22_N), XVS / XHS (LA29) | ≤ ~1,2 V (bank ở VCCO 1,2 V; rail kéo lên trên module chưa rõ): dừng nếu dây nào cao hẳn hơn. XCLR có thể nổi lên cao trước khi cấu hình: ghi lại |
| 3 | sau `make jtag` | LED12, LED7, LED10, LED11, LED8 | LED12 và LED7 sáng đều (clock 200 MHz qua 3 SLR); LED10 sáng ngay (≤ 1,3 ms); LED11 sáng; LED8 tắt tới khi ứng dụng bật PA7. LED7 sáng, LED10 tắt: BISC (mục 6.3) |
| 4 | sau `make jtag`, bo RAM ở FMC+10 | OE# của bo RAM (FMC+10 LA10_P, LA08_N) | ≥ 1,26 V (VIH của TXV0108 ở VCCA 1,8 V): level shifter cô lập |
| 5 | bật nguồn, nạp PDI | cuộn lọc hồng ngoại (LA28 thả nổi), FMC_FLASH (LA16_N = 1) | không nghe / thấy bộ lọc hồng ngoại bật tắt; FMC_FLASH làm sáng gì, dòng tiêu thụ đổi bao nhiêu |
| 6 | `csi2_test` khởi động | I2C ở 0x1A: ACK, thời gian sườn lên ở 100 kHz | `camera: IMX274 found`; sườn lên ≤ 1 µs (I2C chuẩn); chậm hơn: hạ tốc độ hoặc thêm pull-up về VADJ. Lần 1: ACK ở 100 kHz, giá trị sau reset đúng trừ VMAX 0x906 (datasheet 0x905; driver nay nhận cả hai, mục 6.2); sườn lên chưa đo |
| 7 | `phy`, `phy reinit` | trễ BISC của 4 lane, PB6 / PB7, thời gian tới `PHY_RDY` | trễ của các lane gần nhau (lane nhận strobe chuyển tiếp có thể lệch hơn); `PHY_RDY` sau ~40 µs (mô phỏng) tới 1,3 ms (AM010). Lần 1: 122/75/118/130 (lặp lại sau `phy reinit`, cả khi lane clock chạy), PB6 = PB7 = 1, `PHY_RDY` 75–76 µs sau xung PA4; trễ BISC ở mép sớm của eye (mục 9) |
| 8 | `stat` trước `start`, sau `stop` | trạng thái LP của lane ở standby | LP-00 (datasheet) hay LP-11; lỗi LP (`misc`) ở mỗi lần dừng / chạy là bình thường với LP-00 |
| 9 | `raw` sau `start` | byte sync của từng lane | `b8` ngay sau HS-zero, `sync byte at bit ...` trên mọi lane. Thấy `1d` mà không có sync: thứ tự bit ngược (`BitRev` = 1 của `bow_dphy_io_versal`, build lại) |
| 10 | `raw` lặp lại nhiều phút | vị trí sync của từng lane | không đổi theo thời gian; lệch giữa các lane ≤ 6 byte clock (từ 7 trở lên bộ thu báo SKEW) |
| 11 | `log fs`; `wr 40008020 1`, vài frame sau `rd 40008024` (`CNT_FRAME`) và `rd 40008028` (`CNT_PKT`) | packet mỗi frame | FS, EMB (0x12), OB (0x37) × 8 (720p: 4), dòng 0x2B, FE, mỗi packet một burst: 1091 packet / frame ở 1080p, 727 ở 720p. Ghi WC của EMB và OB. Thiếu dòng mà không lỗi, hoặc `no lines`: cảm biến gửi nhiều packet trong một burst |
| 12 | `stat` | `clk` (số lần lane clock vào HS) theo số frame; byte clock | 1 mỗi frame: lane clock liên tục trong frame; 1 mỗi burst: tắt sau mỗi dòng (đồng hồ đo byte clock khi đó đọc thấp). 180 MHz = INCK 24 MHz (202,5 MHz: dao động 27 MHz) |
| 13 | `test`, `stat` | `trunc`, `ovf`, `line`, `frame` | `trunc` 0 và `ovf` 0 ở 1080p và 720p; line = 2 · HMAX / 72 MHz (11111 ns ở HMAX 400), frame = HMAX · VMAX / 72 MHz |
| 14 | `test` | dòng integrity và isp | tổng và mean của 555h / AAAh (có cộng BLKLEVEL không), `tp 11` ra sọc dọc (không thì thử `tp 12`), màu và thứ tự sọc, mức xám |
| 15 | ≥ 10⁴ burst mỗi cách | `BurstRxRst`: PA5 = 1 (mặc định) so với `phy burstrst 0` (mục 6.3) | đã đo ở lần 1: PA5 = 1 sạch (hơn 3,2 triệu burst); PA5 = 0 hỏng hẳn sau lần bật lại bộ thu đầu tiên (lane 0 SOT / ECC / CRC, SKEW, FRAME): firmware giữ PA5 = 1, không cần đo lại |
| 16 | cảm biến đang stream | quét `SETTLE` theo mục 6.3 (giữ PA5 = 1) | đã đo ở lần 1: sạch 13…34 chu kỳ (65…170 ns), 95 ns của driver cách mép dưới 30 ns; lần 2: kiểm lại 95 ns với bản gộp main |
| 17 | `camera`: `flip 0 1` trên cảnh thật | thứ tự Bayer khi lật dọc, frame ngay sau lệnh | đã đo ở lần 1: RGGB (GBRG cho ảnh tím); lần 2: màu đúng ngay với firmware mới (`imx274_bayer()` trả RGGB) |
| 18 | `camera`: `cam` đầu tiên | frame đầu sau khi thoát standby | có frame, frame đầu không hỏng; nếu không: thử thêm 10 ms sau các lệnh ghi của bước 1 (firmware) |
| 19 | sau `cal`, bo nóng / nguội hoặc chạy lâu | lỗi ECC / CRC trong `csi` | lane đã nạp tap thôi theo dõi VT: so với trễ BISC (sau `phy reinit`, VT bật lại) |
| 20 | `video`: `rec` 1080p30 và 720p30, cảnh nhiều chi tiết, QP 18–23 | `warning: the encoder dropped pixels` | không có (tải 78 %). Lần 1: 1080p30 ở QP 30–37 không bỏ pixel, nhưng chỉ 20 / 30 frame vừa video RAM; lần 2: `rec --mode 1080p -n 30` phải ghi đủ 30 frame (rate control mới, mục 6.5) |

Nếu bộ thu của Bow32 không nhận gì trong khi cảm biến chắc chắn stream (LED5 sáng), một PDI thử
với IP MIPI D-PHY của AMD trên cùng các chân (không có trong repo) tách lỗi của bo / cảm biến
khỏi lỗi của PHY Bow32. KV260 (không phải bo này): build lại `kv260_cam` với RTL mới rồi chạy
`csi2_test` `test` và `camera` ([camera_kv260.md](camera_kv260.md)); phy-idle in `STATUS 403f`.

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
| Vivado: `CRITICAL WARNING: CDC-<n> from ... to ... is not a reviewed crossing` | crossing mới giữa các miền clock: xem `cdc.rpt`, sửa RTL hoặc duyệt rồi thêm vào `tcl/timing_checks_cam.tcl` |
| `make jtag`: `jtag: refused: ...` | bo / switch theo bảng ở mục 2; PDI không có `pdi_site.txt` (dựng trước khi có khoá) hoặc mới hơn nó (build không qua `make pdi`): build lại bằng `make pdi` hoặc `CONFIRM=1` sau khi kiểm |
| LED12 tắt | không có clock 200 MHz: SW12 phải OFF |
| LED7 tắt (LED12 sáng) | XPLL của bank 705 không khoá: clock 200 MHz qua SLR, xem `clock_utilization.rpt` |
| LED7 sáng, LED10 tắt | BISC không xong: VCCIO của FMC+01 (SW192 phải 1,2 V, LED "1.2", TP29); thử lại BISC với lane clock chạy (`sensor on`, `phy reinit`, mục 6.3) |
| `phy reinit`: `error: PHY_RDY stayed 1 during the reinit pulse ...` | PDI có trước núm PA4: build lại |
| LED11 tắt | module/bo chuyển chưa cắm vào FMC+01 |
| I2C không có ACK ở 0x1A | PA7 (XCLR) phải là output 1 (LED8); SW192 = 1,2 V; module cắm chặt trên bo chuyển |
| LED5 không bao giờ sáng | cảm biến chưa stream (lane clock không vào HS) |
| lỗi ECC/CRC/SoT | `cal` (trễ BISC nằm ở mép sớm của eye: `cam` đầu luôn hiệu chỉnh, `csi2_test` cần `cal` sau `start`); PA5 phải là 1 (`phy`: `burstrst 1`), `SETTLE` (mục 6.3); SW192; bo chuyển |
| `csi`: `dropped by DT/VC` tăng 9 mỗi frame (720p: 5) | bình thường: dòng embedded và optical black bị bộ lọc DT bỏ |
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
  lần đầu của mỗi lane tắt theo dõi VT của slice đó (`RX_EN_VTC = 0`) rồi nạp; 512 tap ≥ 625 ps
  (1 UI = 694 ps, kích thước tap thật chưa đo). Trên bo (lần 1) trễ BISC nằm ở **mép sớm** của
  eye trên cả 4 lane: 122/75/118/130 so với tâm 300/184/264/228 của `cal 8` (eye rộng 352–360
  tap), tức sớm hơn tâm 98–178 tap (ước chừng 1/4 UI; kích thước tap thật chưa đo); ở trễ BISC
  ~11 % dòng có lỗi CRC. Vì vậy app `camera` / `video` luôn hiệu chỉnh ở `cam` đầu, `csi2_test` cần `cal`.
  `phy reinit` (PA4) đưa mọi lane về trễ BISC mới và bật lại theo dõi VT.
- **Câu hỏi mở (RTL):** vì sao BISC ở chế độ native strobe đặt điểm lấy mẫu sớm khoảng 1/4 UI.
  Giả thuyết: BISC căn trễ cho một strobe căn theo mép dữ liệu (edge-aligned, như DQS của bộ
  nhớ khi đọc), còn lane clock của D-PHY căn giữa dữ liệu (centre-aligned, lệch 90°). Cần kiểm
  thuộc tính căn strobe / data của XPHY trong `bow_dphy_io_versal`, hoặc cộng một độ lệch cố
  định sau BISC (khi đó tap được nạp và theo dõi VT dừng, như hiệu chỉnh bằng phần mềm).
- **Núm lúc chạy** (mức bất đồng bộ, đồng bộ vào `ctrl_clk_i`; 0 = như PHY của AMD):
  `reinit_i` (PA4) giữ PHY ở reset khởi động như khi mất khoá XPLL, nhả ra thì XPLL, BISC, VT
  chạy lại; `burst_rst_en_i` (PA5) = 1: `RX_RST` của các slice dùng khi cổng byte clock đóng,
  FIFO bắt đầu lại mỗi burst. Trạng thái `{PHY_RDY, DLY_RDY}` của mọi nibble ra PB6 / PB7.
- **XPLL** 1500 MHz cho BISC/VT; **byte clock** = `FIFO_WR_CLK` của nibble strobe qua BUFGCE,
  dừng giữa các burst như byte clock của KV260. Dữ liệu ra có `rx_valid` theo từng lane.
- Ràng buộc: [constr/huins_vp1902_cam.xdc](../hw/fpga/huins_vp1902/constr/huins_vp1902_cam.xdc),
  [constr/cam_pads.xdc](../hw/fpga/huins_vp1902/constr/cam_pads.xdc); chú thích trong từng file.
- Mô phỏng: `hw/fpga/common/dv/tb_bow_dphy_io_versal.sv` với model XPHY của AMD (secureip,
  cần Vivado, không chạy trong CI), 3 sơ đồ tổng hợp, 24 cấu hình: nạp tap, quét tap, lệch lane,
  glitch của lane clock, lane clock liên tục, `burst_rst_en_i` bật giữa burst, `reinit_i` khi
  lane clock nghỉ, đang chạy HS hoặc liên tục (BISC với strobe chạy), tùy chọn `RdenReg` /
  `EnVtcEarly`. `make -C hw/fpga/common/dv test-dphy-versal` (cũng trong `make test-fpga-dv`,
  ~16 phút), một cấu hình: `make -C hw/fpga/common/dv run-dphy-versal DPHYV_CFG=reinit_idle
  WAVES=1`. `make lint` lint module (3 sơ đồ, và một sơ đồ phải bị từ chối) và top camera với
  stub chỉ có cổng của primitive AMD (`hw/lint/xilinx_versal_stubs.sv`); `make -C
  hw/fpga/huins_vp1902 test-plan` kiểm luật của `tcl/cam_plan.tcl`.
