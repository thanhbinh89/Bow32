# Camera trên Kria KV260: Raspberry Pi camera v2 → ISP của Bow32

Hướng dẫn chạy thử ISP của Bow32 với camera thật trên KV260: dựng bitstream có
bộ thu MIPI CSI-2, nạp ứng dụng mẫu `camera`, chụp ảnh về PC thành file PNG.
Trước khi đọc, hãy chạy được Bow32 cơ bản theo [fpga_kria.md](fpga_kria.md)
(UART0 trên PMOD J2, nạp chương trình bằng `bow32_flash.py`).

> **Trạng thái (2026-10-30):** cả hai bitstream build bằng Vivado 2025.2
> (`kv260_cam`: WNS +0,7 ns ở clock video 200 MHz) và chạy trên KV260, nạp qua
> JTAG. Với test pattern của ISP (160×120 tới 1080p, RGB và YUV), ảnh capture
> và thống kê khớp bit-exact với `tools/isp/isp_model.py`. Với camera v2 thật:
> IMX219 được nhận qua TCA9546A, CSI-2 RX nhận RAW10 không lỗi, 1080p chạy
> 30,1 fps và 720p 60,1 fps, sọc màu `tp 2` đúng thứ tự, AE/AWB khoá.

```
 Pi camera v2 ──MIPI CSI-2──► MIPI CSI-2 RX   ──RAW10──► ISP Bow32 ──► capture buffer ──► CPU ──UART0──► PC (PNG)
 (IMX219, J9)   2 lane        Subsystem (AMD)  AXI4-S    (200 MHz)                       (sw/apps/camera)
      ▲                         ▲ AXI4-Lite                                                tools/bow32_cam.py
      └── I2C0 (TCA9546A) ──────┴── cửa sổ AXI4-Lite 0x5000_0000 ◄── Ibex
          PA7 = RPI_ENABLE
```

## 1. Phần cứng

| Thứ | Ghi chú |
|-----|---------|
| Kria KV260 + nguồn, thẻ SD Kria Ubuntu (hoặc chỉ cần JTAG) | như [fpga_kria.md](fpga_kria.md) |
| **Raspberry Pi camera module v2** (Sony IMX219, 8 MP) | camera "có sẵn cho KV260": AMD dùng nó trong các ứng dụng mẫu. Camera v1.3 (OV5647), v3 (IMX708), HQ (IMX477) **không** dùng được với driver này |
| Cáp camera 15 chân | cắm vào **J9** (RPi camera) của KV260, mặt tiếp xúc đúng chiều, khi board đã tắt nguồn. J7/J8 là connector IAS 34 chân, không dùng cho camera Pi |
| Adapter USB-UART 3,3 V trên PMOD J2 | UART0, như bản cơ bản; nên dùng loại chạy được 921600 baud (FT232, CP2102...) |

Chân FPGA dùng thêm (đều có trong `hw/fpga/kv260/constr/kv260.xdc` và
`hw/fpga/kv260_cam/constr/kv260_cam.xdc`):

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
| Nguồn ảnh | chỉ TPG của ISP | camera (và TPG) |
| I2C0, PA7 | có: dò được cảm biến | có |
| MIPI CSI-2 RX | không (cửa sổ AXI4-Lite trả bus error) | IP AMD trong block design `bow32_cam` |

Ứng dụng `camera` tự nhận ra mình đang chạy trên bitstream nào.

## 3. Build

```bash
make sw                                    # build/sw/camera/camera.{bin,vmem}
make fpga BOARD=kv260_cam                  # -> build/fpga/kv260_cam/firmware/bow32_cam/
# hoặc nạp sẵn ứng dụng camera vào flash trong bitstream:
make fpga BOARD=kv260_cam FLASH_VMEM=$PWD/build/sw/camera/camera.vmem
```

Cần Vivado 2022.2 trở lên có IP **MIPI CSI-2 Receiver Subsystem**
(`mipi_csi2_rx_subsystem`). Nếu Vivado báo thiếu license cho IP này thì cần
lấy license trên trang AMD. Block design (`tcl/cam_bd.tcl`) gồm PS (chỉ lấy
`pl_clk0`/`pl_resetn0`), `clk_wiz` (200 MHz + 50 MHz; `pl_clk0` thật là
99,999 MHz nên ra 199,998 / 49,9995 MHz), 2 `proc_sys_reset` và
CSI-2 RX: 2 lane, 912 Mbit/s mỗi lane, RAW10, 1 pixel/clock, đầu ra VFB
(AXI4-Stream video). Sau khi build, kiểm tra:

- `build/fpga/kv260_cam/timing_summary.rpt`: WNS ≥ 0 (ISP chạy 200 MHz).
- `build/fpga/kv260_cam/bd_ports.txt`: danh sách port của block design. Nếu
  synthesis báo port không tồn tại (tên port của IP đổi theo phiên bản Vivado),
  so với `rtl/bow32_kv260_cam_top.sv` và sửa tên cho khớp.
- `vivado.log`: với Vivado 2025.2 các cảnh báo `[BD 41-721] ... disabled
  parameter '..._IO_LOC_NAME'` và `[BD 41-176] The physical port 'dl*_...' ...
  not found` là bình thường. `WARNING: mipi_csi2_rx: parameter ... not set`
  chỉ báo tham số không có ở phiên bản Vivado đó (chân D-PHY luôn có trong
  XDC). Pixel format, số lane, line rate và chân D-PHY được đọc lại sau khi
  đặt: sai thì build dừng với `ERROR`.

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
csi2rx: found (2 lanes)
>
```

Một phiên làm việc điển hình:

```
> cam                      # 1080p30 RGGB: cảm biến + CSI-2 RX + ISP
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
> csi                      # trạng thái bộ thu: số packet, lỗi, số dòng/byte mỗi dòng
> mode 720p                # 1280x720 @60 fps
> tp 2                     # sọc màu của cảm biến: kiểm tra đường dữ liệu và thứ tự Bayer
> tp 0
> fmt yuv                  # đầu ra YUV 4:4:4 (BT.709)
```

`h` liệt kê tất cả lệnh. Trên bitstream cơ bản dùng `tpg 0` (sọc màu của ISP),
`tpg 1` (ramp), `tpg 2` (bàn cờ) thay cho `cam`.

## 6. Lấy ảnh về PC

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

## 7. Xử lý sự cố

| Triệu chứng | Kiểm tra |
|-------------|----------|
| `camera: no IMX219 on I2C (error -1)` | cáp J9 đúng chiều, camera đúng loại (v2/IMX219); `rd 40004000` xem PA7 (bit 7 = 1); thử `sr 0000` |
| `csi2rx: not present` | đang chạy bitstream cơ bản → nạp `bow32_cam` |
| `stat` → `error: no frame (STATUS .., input 0x0)` | `csi`: số packet tăng không? 0 → lỗi D-PHY/cáp; `sr 0100` = 01 (cảm biến đang stream); lỗi SoT/ECC/CRC trong `isr` |
| `input 1920x1080` nhưng vẫn lỗi, cờ ERR_INPUT (`STATUS` bit 4) | `SIZE` của ISP khác kích thước luồng; `info` so `size` và `input` |
| Màu sai (xanh lá/tím) | thứ tự Bayer: `tp 2` phải ra trắng, vàng, cyan, xanh lá, tím, đỏ, xanh dương, đen; thử `flip 1 1` / `flip 0 0`, hoặc ghi thẳng `wr 40006028 <0..3>` rồi `wr 40006008 1` |
| Ảnh quá tối / sáng | `ae on`, hoặc chỉnh tay `exp <dòng>` và `gain <0..232>` |
| `image CRC mismatch` | giảm baud (`--fast 460800`) hoặc kiểm tra dây GND |
| Vivado: timing không đạt | xem đường trễ xấu nhất trong `timing_summary.rpt`; có thể hạ clock video xuống 150 MHz (`CLKOUT1_REQUESTED_OUT_FREQ` trong `cam_bd.tcl`) cho 720p |

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

## 8. Bên trong ứng dụng

`sw/apps/camera`:

- `imx219.c`: bật PA7, chọn kênh 2 của TCA9546A, đọc chip ID, ghi bảng thanh ghi
  (PLL 912 Mbit/s, RAW10, 2 lane, crop giữa, frame length = fps), stream on/off,
  exposure, gain, flip, test pattern. Các thanh ghi liên tiếp được ghi một lần
  (cảm biến tự tăng địa chỉ).
- `csi2rx.c`: soft reset / enable CSI-2 RX, in trạng thái (PG232).
- `main.c`: shell; AE (exposure trước, gain sau, tối đa ×2 mỗi bước) và AWB
  gray world chạy mỗi 3 frame dựa trên thống kê của ISP; capture và giao thức
  gửi ảnh `IMG <w> <h> <fmt> <bytes> <crc32>` + dữ liệu thô + `END`.

Test mô phỏng `make run TEST=camera` chạy đúng chuỗi này với mô hình IMX219,
CSI-2 RX và TCA9546A trong testbench ([simulation.md](simulation.md)).

## 9. Tiếp theo

- **Bộ thu MIPI CSI-2 của Bow32** thay IP AMD (D-PHY dùng primitive của
  UltraScale+, giải mã packet, ECC/CRC, unpack RAW10) — xem
  [roadmap.md](roadmap.md).
- Hiển thị đầu ra `isp_*` lên màn hình (DisplayPort live video của PS).
- DMA ghi ảnh vào DDR qua PS để lấy ảnh độ phân giải đầy đủ.
