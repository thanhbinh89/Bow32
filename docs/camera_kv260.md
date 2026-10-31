# Camera trên Kria KV260: Raspberry Pi camera v2 → ISP của Bow32

Hướng dẫn chạy ISP của Bow32 với camera thật trên KV260: dựng bitstream có bộ
thu MIPI CSI-2 **của Bow32** (không dùng IP của AMD), nạp ứng dụng mẫu `camera`,
chụp ảnh về PC thành file PNG, và kiểm tra bộ thu bằng ứng dụng `csi2_test`.
Trước khi đọc, hãy chạy được Bow32 cơ bản theo [fpga_kria.md](fpga_kria.md)
(UART0 trên PMOD J2, nạp chương trình bằng `bow32_flash.py`). Chi tiết bộ thu:
[ip/csi2rx.md](ip/csi2rx.md).

> **Trạng thái (2026-10-30):** bitstream `kv260_cam` build bằng Vivado 2025.2
> (WNS +1,023 ns ở clock video 200 MHz, bus skew 7/7 đạt, 0 lỗi DRC) và chạy
> trên KV260, nạp qua JTAG. Với camera v2 thật: `csi2_test` → `test` PASS 16/16
> (1080p30 và 720p60), link 2 lane × 912 Mbit/s không có lỗi ECC/CRC/SoT trong
> nhiều phút, eye ~260 tap mỗi lane; ứng dụng `camera` hiệu chỉnh eye ở `cam`
> đầu tiên, AE/AWB khoá, ảnh PNG 1080p30 và 720p60 đúng. Bitstream cơ bản
> `kv260` giờ có thêm khối CSI2RX không có D-PHY (WNS +5,985 ns ở 50 MHz);
> trên board `csi2_test` báo `csi2rx: Bow32 receiver, no D-PHY in this
> bitstream`, `INFO` = `0x01003202`.

```
 Pi camera v2 ──D-PHY──► bow_dphy_io_xusp ──► bow_csi2rx ──RAW10──► ISP Bow32 ──► capture ──► CPU ──UART0──► PC
 (IMX219, J9)   2 lane   (IBUFDS_DPHY,        CSI2RX       AXI4-S    (200 MHz)    buffer      (sw/apps/  (PNG,
      ▲         912 Mb/s  IDELAY, ISERDES)    0x4000_8000                                      camera)    bow32_cam.py)
      │                                           ▲ thanh ghi (peripheral bus)
      └── I2C0 (TCA9546A) ◄── Ibex ───────────────┘
          PA7 = RPI_ENABLE
```

## 1. Phần cứng

| Thứ | Ghi chú |
|-----|---------|
| Kria KV260 + nguồn, thẻ SD Kria Ubuntu (hoặc chỉ cần JTAG) | như [fpga_kria.md](fpga_kria.md) |
| **Raspberry Pi camera module v2** (Sony IMX219, 8 MP) | camera "có sẵn cho KV260": AMD dùng nó trong các ứng dụng mẫu. Camera v1.3 (OV5647), v3 (IMX708), HQ (IMX477) **không** dùng được với driver này |
| Cáp camera 15 chân | cắm vào **J9** (RPi camera) của KV260, mặt tiếp xúc đúng chiều, khi board đã tắt nguồn. J7/J8 là connector IAS 34 chân, không dùng cho camera Pi |
| Adapter USB-UART 3,3 V trên PMOD J2 | UART0, như bản cơ bản; nên dùng loại chạy được 921600 baud (FT232, CP2102...) |

Chân FPGA dùng thêm: PA7 và I2C0 trong `hw/fpga/kv260/constr/kv260.xdc` (dùng
cho cả hai bitstream), chân D-PHY trong `hw/fpga/kv260_cam/constr/kv260_cam.xdc`
(bank 66, IOSTANDARD `MIPI_DPHY_DCI`):

| Tín hiệu | Chân | Nối tới |
|----------|------|---------|
| `cam_en_io` (PA7) | F11 (HDA09) | RPI_ENABLE: bật nguồn/enable module camera |
| `i2c_scl_io` / `i2c_sda_io` | G11 (HDA00_CC) / F10 (HDA01) | switch I2C TCA9546A (0x74), kênh 2 = J9 |
| `mipi_phy_if_raspi_clk_p/n` | D7 / D6 | lane clock, bank 66 |
| `mipi_phy_if_raspi_data_p/n[0]` | E5 / D5 | lane 0 |
| `mipi_phy_if_raspi_data_p/n[1]` | G6 / F6 | lane 1 |

## 2. Hai bitstream

| | `make fpga` (`hw/fpga/kv260`) | `make fpga BOARD=kv260_cam` (`hw/fpga/kv260_cam`) |
|---|---|---|
| ISP | có, chạy ở clock SoC 50 MHz | có, clock video 200 MHz |
| Bộ thu CSI-2 (`CSI2RX`, `0x4000_8000`) | có, nhưng không có D-PHY: `INFO.PHY = 0`, mọi lane LP-11 | có, D-PHY trên chân J9 (`bow_dphy_io_xusp`) |
| Nguồn ảnh | chỉ TPG của ISP | camera (và TPG) |
| I2C0, PA7 | có: dò được cảm biến | có |
| Block design | `bow32_ps`: PS | `bow32_cam`: PS + `clk_wiz` + 2 `proc_sys_reset`, không có IP MIPI |
| Cửa sổ AXI4-Lite `0x5000_0000` | không có thiết bị (timeout → bus error) | như bên trái |

Ứng dụng `camera` và `csi2_test` tự nhận ra mình đang chạy trên bitstream nào
(`CSI2RX.INFO`).

## 3. Build

```bash
make sw                                    # build/sw/camera/, build/sw/csi2_test/ ...
make fpga BOARD=kv260_cam                  # -> build/fpga/kv260_cam/firmware/bow32_cam/
# hoặc nạp sẵn ứng dụng camera vào flash trong bitstream:
make fpga BOARD=kv260_cam FLASH_VMEM=$PWD/build/sw/camera/camera.vmem
```

Cần Vivado 2022.2 trở lên có device K26 (đã thử với 2025.2). **Không** cần IP
MIPI CSI-2 hay license của AMD: D-PHY là các primitive I/O của UltraScale+
(`IBUFDS_DPHY`, `IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`) trong
`hw/fpga/common/rtl/bow_dphy_io_xusp.sv`. Block design (`tcl/cam_bd.tcl`) chỉ
còn PS (lấy `pl_clk0`/`pl_resetn0`), `clk_wiz` (200 MHz + 50 MHz; `pl_clk0` thật
là 99,999 MHz nên ra 199,998 / 49,9995 MHz) và 2 `proc_sys_reset`. Ràng buộc
(`constr/kv260_cam.xdc`, mỗi dòng có chú thích) được giải thích trong
[ip/csi2rx.md](ip/csi2rx.md). Sau khi build, kiểm tra trong `build/fpga/kv260_cam/`:

| File | Phải thấy |
|------|-----------|
| `timing_summary.rpt` | WNS ≥ 0 và WHS ≥ 0 (bản hiện tại: +1,023 ns / +0,010 ns) |
| `bus_skew.rpt` | 7 ràng buộc `set_bus_skew`, cả 7 `Slack (MET)` |
| `clockInfo.txt` | `The following 2 clock nets belong to CLOCK_DELAY_GROUP bow_dphy_rx_clk`: `u_dphy/dphy_byte_clk`, `u_dphy/hs_clk` |
| `drc.rpt` | không có lỗi (nhất là REQP-1742: `CLK` của IDELAYE3 phải là `CLKDIV` của ISERDESE3) |
| `clocks.rpt`, `clock_interaction.rpt` | `dphy_hs_clk` 2,193 ns; `dphy_byte_clk` và `dphy_hs_clk_DIV4_INV` 8,772 ns; các cặp clock khác miền là *Asynchronous Groups* |
| `bd_ports.txt` | chỉ `sys_clk`, `sys_resetn`, `vid_clk`, `vid_resetn` |

`tcl/build.tcl` in `CRITICAL WARNING` khi WNS < 0, khi bus skew vi phạm hay
không đủ 7 ràng buộc, hoặc khi `CLOCK_DELAY_GROUP` không đủ 2 net (thường do
đổi tên instance trong RTL mà XDC còn dùng tên cũ). Cảnh báo bình thường:

- 12 × `[Constraints 18-5254]`: Vivado đổi `DIFF_TERM` mặc định của
  `IBUFDS_DPHY` thành `DIFF_TERM_ADV TERM_100`, giống XDC.
- `methodology.rpt`: LUTAR-1 (3 từ reset của bộ thu: `u_brst`, `u_drst`,
  `u_iserdes_rst`; 1 từ ISP), SYNTH-6 (RAM khối không có thanh ghi ra, gồm FIFO
  pixel của bộ thu).
- `check_timing.rpt`: `mipi_phy_if_raspi_data_p[*]` nằm trong danh sách
  "no input delay but user has a false path constraint" (cố ý: eye hiệu chỉnh
  lúc chạy).

## 4. Nạp bitstream

```bash
# Trên PC
scp -r build/fpga/kv260_cam/firmware/bow32_cam ubuntu@<kria>:/tmp/
# Trên Kria
sudo mkdir -p /lib/firmware/xilinx && sudo cp -r /tmp/bow32_cam /lib/firmware/xilinx/
sudo xmutil unloadapp
sudo xmutil loadapp bow32_cam
```

Hoặc qua JTAG, không cần Linux: `make fpga-jtag BOARD=kv260_cam`.

## 5. Nạp và chạy ứng dụng `camera`

```bash
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/camera/camera.bin
python3 tools/bow32_flash.py -p /dev/ttyUSB0 monitor
```

Khi khởi động:

```
Bow32 camera demo (ISP + IMX219), type h for help
camera: IMX219 found (id 0219)
csi2rx: Bow32 receiver, 2 lanes, PHY clock 200 MHz
>
```

Một phiên làm việc điển hình:

```
> cam                      # 1080p30 RGGB: bộ thu + cảm biến + ISP, lần đầu hiệu chỉnh eye
csi2rx: calibrated taps 208/200 eye 272/256
streaming 1920x1080 RGGB
ok
> stat                     # thống kê frame kế tiếp
frame 12 in 1920x1080  mean R/G/B 210/388/301 (2073600 px)  Y 330  af 812345  dpc 17
hist (Y/64, 0..1023): 3 9 15 18 ...
ok
> ae on                    # auto exposure: mean luma tuyến tính -> 180
> awb on                   # white balance gray world
ae: locked exp=1210 gain=0 mean=181
awb: locked r=402 b=355
> csi                      # trạng thái bộ thu (bên dưới)
> cal                      # hiệu chỉnh lại eye (bước 16), in bản đồ eye
> csilog fs                # 64 packet từ FS kế tiếp (csilog fe: tới FE, csilog: ngay)
> mode 720p                # 1280x720 @60 fps
> tp 2                     # sọc màu của cảm biến: kiểm tra đường dữ liệu và thứ tự Bayer
> tp 0
> fmt yuv                  # đầu ra YUV 4:4:4 (BT.709)
```

`cam` làm theo thứ tự: cấu hình ISP → `bow_csi2rx_start(2, RAW10, 912 Mbit/s)` khi cảm biến
còn ở LP-11 → cấu hình cảm biến (exposure ≤ FLL − 4) → bật ISP → stream on →
lần đầu, hoặc khi 64 packet đầu có lỗi (`bow_csi2rx_link_check`): hiệu chỉnh
eye. Tap được giữ cho các lần `cam` sau. `stop`, `mode`, `tpg` tắt stream rồi
chờ cảm biến gửi nốt frame (`bow_csi2rx_stop`) trước khi tắt bộ thu.

`csi` in (đo trên board, 1080p30, cảnh thật, ~3 s sau `cam`):

```
csi2rx: link ok
  frames 91 lines/frame 1080 wc 2400 dt 2b sum 19156a6b
  errors: ecc 0/0 crc 0 trunc 0 sot 0/0 drop 182 ovf 0 misc 0
  timing: frame 33326 us, line 18860 ns, byte clock 114062 kHz
  phy: lp clk 11 d0 11 d1 11, bursts 65535/65535 clk 91, delay 208/192
```

| Dòng | Nội dung |
|------|----------|
| 1 | `link ok` (có frame, không lỗi link), `link errors`, `no data` (chưa có packet nào), hoặc `no lines` (có frame nhưng không dòng nào được nhận: `CTRL.DT`/`VC` không khớp, hoặc cảm biến gửi nhiều packet trong một burst) |
| `frames` | số FS từ lần xoá bộ đếm; số dòng của frame cuối, WC và DT của dòng cuối, `FRAME_SUM` |
| `errors` | ECC đã sửa/không sửa được, CRC, packet bị cắt, SoT lane 0/1, `drop` (bộ lọc VC/DT: IMX219 gửi 2 dòng embedded mỗi frame, nên tăng 2 mỗi frame là bình thường), tràn FIFO, misc (skew + format + frame) |
| `timing` | `FRAME_TIME`, `LINE_TIME`, `BYTECLK` (912 Mbit/s / 8 = 114 MHz) |
| `phy` | trạng thái LP của từng lane (`11`, `01`, `00`) hoặc `HS`, số lần vào HS của lane 0/1 (16 bit, bão hoà ở 65535) và lane clock (IMX219: 1 lần mỗi frame), tap IDELAY |

`h` liệt kê tất cả lệnh. Trên bitstream cơ bản dùng `tpg 0` (sọc màu của ISP),
`tpg 1` (ramp), `tpg 2` (bàn cờ) thay cho `cam`.

## 6. Ứng dụng kiểm tra `csi2_test`

`sw/apps/csi2_test` kiểm tra bộ thu với các test pattern của IMX219 (màu đơn,
sọc màu) và cho các lệnh bring-up bằng tay:

```bash
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/csi2_test/csi2_test.bin
python3 tools/bow32_flash.py -p /dev/ttyUSB0 monitor
```

```
csi2_test: Bow32 MIPI CSI-2 receiver test
camera: IMX219 found (id 0219)
csi2rx: Bow32 receiver, 2 lanes, PHY clock 200 MHz
type h for help
> test
csi2_test: 1920x1080, frame 33326 us, 60 frames per check, calibration step 8
[PASS] phy-idle all lanes LP-11, no HS (STATUS 003f)
[PASS] link-up bursts 3/3, clock lane 1
lanes |###......################################......#################| tap 196 width 256
lane0 |####.....##################################....#################| tap 204 width 272 (other lane at 196)
lane1 |###.....#################################....###################| tap 192 width 264 (other lane at 196)
[PASS] calibrate taps 204/192 eye 272/264
[PASS] integrity 60 frames 1920x1080 RAW10: wc 2400, sum 3d2e1c00
[PASS] packets FS, embedded data, lines, FE: headers and CRC ok; frame numbers 70, 71
[PASS] timing frame 33326 us, line 18860 ns, byte clock 114062 kHz
csi2_test: 1280x720, frame 16653 us, 60 frames per check, calibration step 8
[PASS] link-up bursts 3/3, clock lane 1
...                                         (bản đồ eye như trên)
[PASS] calibrate taps 204/192 eye 272/264
[PASS] integrity 60 frames 1280x720 RAW10: wc 1600, sum 1b30f000
[PASS] packets FS, embedded data, lines, FE: headers and CRC ok; frame numbers 74, 75
[PASS] timing frame 16653 us, line 18940 ns, byte clock 114062 kHz
[PASS] isp 8 colour bars ok, capture 160x90 (scale 3)
[PASS] raw8 60 frames RAW8: wc 1280, sum 1c200000; back to RAW10
[PASS] filter VC 1: no line, 43320 packets dropped in 60 frame periods; VC 0: frames resume
[PASS] restart 3 x stop/start at random phases, frames resume without errors
[PASS] irq 59 FS interrupts in 60 frames
csi2_test: PASS (16/16)
ok
```

| Check | Nội dung |
|-------|----------|
| `phy-idle` | cảm biến standby, PHY bật: mọi lane LP-11, không có HS |
| `link-up` | stream màu đơn: số lần vào HS của hai data lane và lane clock tăng |
| `calibrate` | có eye trên mọi lane (bước 8), tap đã nạp (`DLYn` đọc lại), rồi 64 packet không lỗi |
| `integrity` | 60 frame RAW10: không lỗi link, `FRAME_INFO` = H dòng, `LINE_INFO` WC = W·5/4 và DT 0x2B, `FRAME_SUM` = (W/2)(H/2)(R + Gr + B + Gb) |
| `packets` | LOG từ FS: FS, embedded (0x12), dòng 0x2B, ECC và CRC đúng; LOG tới FE: dòng rồi FE; số frame tăng 1 |
| `timing` | chu kỳ frame ±2 % so với mode, line time 3448 / 182,4 MHz ±2 %, byte clock 114 MHz ±3 % |
| `isp` | sọc màu của cảm biến qua ISP, capture: tâm mỗi sọc đúng thành phần R/G/B |
| `raw8` | RAW8 (DT 0x2A): WC = W, `FRAME_SUM` với màu có 2 bit thấp bằng 0; rồi về RAW10 |
| `filter` | VC = 1: không dòng nào được nhận, `CNT_DROP` tăng ≥ H mỗi frame; VC 0: frame chạy lại |
| `restart` | 3 lần stop/start stream ở pha ngẫu nhiên: frame chạy lại không lỗi |
| `irq` | `IRQ_EN.FS`: ISR đếm `irq_fast[7]` (mcause `0x80000017`) |

Bản đầy đủ chạy `link-up` … `timing` ở 1080p30 rồi lại ở 720p60 (16 check).
`test quick` (11 check, frame 64×48, bước 32, 4 frame mỗi check) dành cho mô
phỏng. Sau `test` stream vẫn chạy, bộ đếm vừa được xoá (để `stat` chỉ thấy sự
kiện mới). Lệnh khác:

| Lệnh | Việc |
|------|------|
| `start`, `stop` | stream (kèm kiểm tra 64 packet, không tự hiệu chỉnh) / dừng stream |
| `stat` | như `csi` của ứng dụng `camera` |
| `cal [step]` | hiệu chỉnh eye (mặc định bước 16), in bản đồ |
| `delay <lane> <tap>` | đặt tap 0…511 của một lane |
| `log [fs] [fe]` | LOG 64 packet: ngay, từ FS kế tiếp, tới FE (cả hai: từ FS tới FE) |
| `raw [now]` | 64 word thô mỗi lane từ burst kế tiếp (hoặc ngay), tìm byte sync |
| `irq` | đếm ngắt FS trong 4 frame |
| `mode <w> <h> [fps]`, `mode 1080p`, `mode 720p` | kích thước frame (fps 0: frame ngắn nhất) |
| `tp <n> [r gr b gb]` | test pattern 0 tắt, 1 màu đơn, 2 sọc, 3 fade, 4 PN9; màu 10 bit của mẫu màu đơn |
| `fmt raw8\|raw10` | format của cảm biến (dừng stream, đổi, stream lại) |
| `rd <addr>`, `wr <addr> <val>` | đọc/ghi bus (hex) |

## 7. Lấy ảnh về PC

Đóng `monitor` (cổng serial chỉ một chương trình dùng được), rồi:

```bash
# cả khung, thu nhỏ cho vừa buffer 32K pixel (1080p -> 240x135)
python3 tools/bow32_cam.py -p /dev/ttyUSB0 --fast 921600 snap -o frame.png
# crop 1:1 ở giữa ảnh, để lấy nét
python3 tools/bow32_cam.py -p /dev/ttyUSB0 -b 921600 snap -o crop.png --cap "cap 880 480 160 120 0"
# chạy lệnh shell
python3 tools/bow32_cam.py -p /dev/ttyUSB0 -b 921600 cmd "mode 720p" cam "ae on" "awb on"
# xem liên tục (cần tkinter)
python3 tools/bow32_cam.py -p /dev/ttyUSB0 -b 921600 view
```

`--fast` chuyển UART0 lên tốc độ cao (lệnh `baud`); board giữ tốc độ đó tới
khi reset, các lần sau dùng `-b 921600`. Ảnh 240×135 (97 KB) mất ~1 s ở
921600 baud, ~9 s ở 115200 baud.

Ống kính camera v2 xoay được để lấy nét: lệnh `focus` in độ sắc nét (`ST_AF`)
mỗi frame, xoay tới khi số lớn nhất.

## 8. Xử lý sự cố

| Triệu chứng | Kiểm tra |
|-------------|----------|
| `camera: no IMX219 on I2C (error -1)` | cáp J9 đúng chiều, camera đúng loại (v2/IMX219); `rd 40004000` xem PA7 (bit 7 = 1); thử `sr 0000` |
| `csi2rx: Bow32 receiver, no D-PHY in this bitstream` | đang chạy bitstream cơ bản → nạp `bow32_cam` |
| `csi2rx: not present` | bitstream cũ, chưa có bộ thu của Bow32 (`0x4000_8000` trả bus error) → build lại |
| `csi` → `no data` | dòng `phy`: lane ở `11` mãi = cảm biến không stream (`sr 0100` phải là 01); ở `00` mãi = IMX219 chưa ra LP-11 (sau khi bật nguồn nó chỉ vào LP-11 khi đã stream một lần: khởi động lại ứng dụng để `imx219_probe()` làm việc đó); không bao giờ `HS` = cáp, PA7 |
| `csi` → `link errors` (ecc/crc/sot tăng) | `cal` để hiệu chỉnh lại và xem bản đồ: eye hẹp hoặc không có → cáp, đầu nối J9; `csilog` xem packet nào lỗi |
| `calibration failed`, `tap not applied: no byte clock` | không có burst khi hiệu chỉnh: cảm biến có đang stream không? |
| `stat` → `error: no frame (STATUS .., input 0x0)` | `csi`: có frame không, `lines/frame`, `wc` đúng chưa, lỗi gì |
| đổi RAW8/RAW10 bằng `sr 018c ..` khi đang stream → `ovf` tăng, pixel sai | IMX219 chỉ nhận format (0x018C/0x018D, 0x0309) ở standby: dừng stream, đổi, rồi stream lại (lệnh `fmt` của `csi2_test` làm vậy) |
| frame dài hơn mode (720p: 18979 µs thay vì 16653 µs) | exposure > FLL − 4 kéo dài frame (exposure lúc bật nguồn là 1000 dòng); ứng dụng `camera` tự giới hạn, `csi2_test` đặt exposure = FLL − 4 |
| `input 1920x1080` nhưng vẫn lỗi, cờ ERR_INPUT (`STATUS` bit 4) | `SIZE` của ISP khác kích thước luồng; `info` so `size` và `input` |
| Màu sai (xanh lá/tím) | thứ tự Bayer: `tp 2` phải ra trắng, vàng, cyan, xanh lá, tím, đỏ, xanh dương, đen; thử `flip 1 1` / `flip 0 0`, hoặc ghi thẳng `wr 40006028 <0..3>` rồi `wr 40006008 1` |
| Ảnh quá tối / sáng | `ae on`, hoặc chỉnh tay `exp <dòng>` và `gain <0..232>` |
| `image CRC mismatch` | giảm baud (`--fast 460800`) hoặc kiểm tra dây GND |
| Vivado: timing không đạt | xem đường trễ xấu nhất trong `timing_summary.rpt`; hạ clock video (`CLKOUT1_REQUESTED_OUT_FREQ` trong `cam_bd.tcl`) thì sửa cả `VidClkHz` trong `rtl/bow32_kv260_cam_top.sv` (driver tính SETTLE/CLK_SETTLE/CLK_MISS từ `INFO`) |
| Vivado: `CRITICAL WARNING` về bus skew hoặc `CLOCK_DELAY_GROUP` | tên instance/thanh ghi trong XDC không còn khớp RTL |

`error -1` là thiết bị không trả ACK. Để biết switch hay cảm biến không trả
lời, gửi tay START + địa chỉ qua thanh ghi `CMD` của I2C0 rồi đọc `STATUS`
(bit 1 = NACK) và kết thúc bằng STOP:

```
> wr 40007004 5e8          # START + 0x74 (TCA9546A), ghi
> rd 40007008              # 00000004: có ACK, 00000006: NACK
> wr 40007004 200          # STOP
> wr 40007004 520          # START + 0x10 (IMX219), kênh 2 đã được chọn lúc khởi động
> rd 40007008
> wr 40007004 200
```

Switch trả lời mà IMX219 thì không: camera chưa cắm, cắm ngược mặt, lỏng cáp
hoặc không phải camera v2.

Adapter không gửi được BREAK (ví dụ `/dev/ttyACM*`): đưa ứng dụng đang chạy về
loader bằng lệnh `wr` (cả `camera` lẫn `csi2_test` đều có), rồi nạp với
`--no-break`:

```
> wr 40000010 4c4f4144     # SYSCTRL.BOOT_FLAG = "LOAD"
> wr 4000000c 52535421     # SYSCTRL.RST_CTRL = "RST!": reset ngay (không có "ok"), ROM ở lại loader
```

```bash
python3 tools/bow32_flash.py -p /dev/ttyACM0 --no-break flash build/sw/csi2_test/csi2_test.bin
```

## 9. Bên trong ứng dụng

- `sw/common/src/imx219.c` (`imx219.h`, dùng chung cho `camera` và
  `csi2_test`, không nằm trong `bow32.h`): bật PA7, chọn kênh 2 của TCA9546A,
  đọc chip ID rồi stream 100 µs và về standby (sau khi bật nguồn IMX219 chỉ vào
  LP-11 khi đã stream một lần, giống probe của Linux); bảng thanh ghi (PLL
  912 Mbit/s, 2 lane, crop giữa, frame length theo fps), format RAW10/RAW8 được
  lưu và áp ở mỗi lần cấu hình, exposure, gain, flip, test pattern 0–4 và màu
  của mẫu màu đơn. Các thanh ghi liên tiếp được ghi một lần (cảm biến tự tăng
  địa chỉ).
- `sw/common/src/bow_csi2rx.c` (`bow_csi2rx.h`, có trong `bow32.h`): driver
  bộ thu: start/stop quanh stream, bộ đếm, link check, hiệu chỉnh eye, LOG, RAW,
  in trạng thái ([ip/csi2rx.md](ip/csi2rx.md)).
- `sw/apps/camera/main.c`: shell; start/stop + hiệu chỉnh; AE (exposure trước,
  gain sau, tối đa ×2 mỗi bước) và AWB gray world chạy mỗi 3 frame dựa trên
  thống kê của ISP; capture và giao thức gửi ảnh
  `IMG <w> <h> <fmt> <bytes> <crc32>` + dữ liệu thô + `END`.
- `sw/apps/csi2_test/`: `main.c` (shell, điều khiển stream, ISR của
  `irq_fast[7]`), `checks.c` (các check của `test`).

Test mô phỏng `make run TEST=camera` và `make run TEST=csi2` chạy đúng các ứng
dụng này với mô hình IMX219 + D-PHY (`csi2_tx_model.sv`) và TCA9546A trong
testbench ([simulation.md](simulation.md)).

## 10. Tiếp theo

- Hiển thị đầu ra `isp_*` lên màn hình (DisplayPort live video của PS).
- DMA ghi ảnh vào DDR qua PS để lấy ảnh độ phân giải đầy đủ.
- Bộ thu: tự hiệu chỉnh lại eye khi có lỗi, 4 lane, RAW12 (bài tập trong
  [ip/csi2rx.md](ip/csi2rx.md)).
