# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/), đánh số theo
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Bộ thu MIPI CSI-2** `bow_csi2rx` (`hw/ip/csi2rx`), thay MIPI CSI-2 RX
  Subsystem của AMD: phần số của D-PHY (máy trạng thái LP bật bộ thu HS và
  termination, cổng byte clock, phát hiện mất clock, tìm sync 0xB8 và căn byte
  mỗi lane), ghép 1–2 lane, lớp packet (ECC header sửa 1 bit, CRC-16, lọc
  VC/DT, FS/FE), unpack RAW10/RAW8, FIFO 2 clock, đầu ra AXI4-Stream RAW10
  1 pixel/clock cho ISP. Bộ đếm lỗi, log 64 packet, 64 word thô mỗi lane, đo
  `FRAME_TIME`/`LINE_TIME`/`BYTECLK`. Thanh ghi `CSI2RX` ở `0x4000_8000`, ngắt
  `irq_fast[7]` ([docs/ip/csi2rx.md](docs/ip/csi2rx.md)).
- `bow_fifo_async` (FIFO 2 clock, con trỏ gray) trong `hw/ip/common`.
- D-PHY I/O cho UltraScale+ `hw/fpga/common/rtl/bow_dphy_io_xusp.sv`
  (`IBUFDS_DPHY`, `IDELAYE3` COUNT, `ISERDESE3` 1:8, 2 × `BUFGCE_DIV`) và test
  mức chân với unisim `make -C hw/fpga/common/dv test` (xsim, cần Vivado).
- Driver `bow_csi2rx.h/.c`: start/stop quanh stream, bộ đếm, link check, hiệu
  chỉnh eye của tap IDELAY lúc chạy, log packet, word thô, in trạng thái.
- Ứng dụng `csi2_test`: shell bring-up (`stat`, `cal`, `log`, `raw`, `delay`,
  `mode`, `tp`, `fmt`, `irq`, `rd`/`wr`) và `test [quick]` (11 check; trên
  board 16: 1080p30 và 720p60).
- Ứng dụng `camera`: lệnh `cal [step]`, `csilog [fs|fe]`, `csi` theo bộ thu mới;
  hiệu chỉnh eye ở `cam` đầu tiên.
- Mô hình Python `tools/csi2/csi2_model.py` (viết từ đặc tả, không từ RTL) +
  19 unit test; testbench IP `hw/ip/csi2rx/dv` với mô hình máy phát D-PHY
  `csi2_tx_model.sv` (30 case mặc định, 210/210 với 40 seed); `make test-ip`;
  CI chạy test IP của bộ thu.
- Test mô phỏng `csi2`: `csi2_test test quick` rồi cài lỗi (ECC, CRC, SoT/skew)
  và kiểm tra đúng số đếm.
- Kết quả trên KV260 + camera v2: `csi2_test: PASS (16/16)`, 2 lane ×
  912 Mbit/s, byte clock 114,06 MHz, frame 33326 µs (1080p30) / 16653 µs
  (720p60), không lỗi ECC/CRC/SoT trong nhiều phút, eye ~260 tap (~0,94 ns) mỗi
  lane; Vivado 2025.2: WNS +1,023 ns, bus skew 7/7 đạt, 0 lỗi DRC.
- **ISP** `bow_isp` (`hw/ip/isp`): RAW10 Bayer → RGB888 / YUV444, 1 pixel/clock,
  hai miền clock (CPU / video). Pipeline BLC, DPC (5×5), white balance,
  demosaic bilinear (3×3), CCM, gamma (3 LUT), CSC; thống kê (tổng RGB, luma,
  histogram 64 bin, AF, DPC); capture có lọc hộp 1/2/4/8 vào buffer 32K × 24 bit
  (`0x3000_0000`); test pattern generator; cấu hình staging + `UPDATE` giữa hai
  frame. Thanh ghi ở `0x4000_6000`, ngắt `irq_fast[5]`.
- Mô hình ISP bit-exact `tools/isp/isp_model.py` và testbench `hw/ip/isp/dv`
  (`make -C hw/ip/isp/dv test`).
- I2C master `bow_i2c` (`0x4000_7000`, `irq_fast[6]`), driver `bow_i2c.h`.
- Cầu Bow32 bus → AXI4-Lite `bow_axil_bridge` (cửa sổ `0x5000_0000`, timeout
  → bus error); `bow_probe_read32/write32` đọc/ghi không gây exception.
- Ứng dụng `camera`: driver IMX219 (1080p30, 720p60, mode tuỳ ý, test pattern,
  flip, exposure, gain), driver MIPI CSI-2 RX của AMD, AE, AWB gray world,
  capture và gửi ảnh qua UART.
- `tools/bow32_cam.py`: chụp ảnh về PNG, xem trực tiếp, chạy lệnh shell; unit test.
- Bitstream camera `hw/fpga/kv260_cam` (`make fpga BOARD=kv260_cam`): block design
  PS + clk_wiz + MIPI CSI-2 RX Subsystem (2 lane, 912 Mbit/s, RAW10), ISP 200 MHz.
- KV260 (cả hai bản): PA7 = RPI_ENABLE (F11), I2C0 = switch I2C TCA9546A của
  camera (G11/F10).
- Test mô phỏng `camera`: mô hình TCA9546A + IMX219 (I2C), luồng CSI-2, thanh
  ghi CSI-2 RX (AXI4-Lite), kiểm tra ảnh sọc màu RGB/YUV, AE/AWB.
- Thư viện chung: `bow_cdc_pulse`, `bow_rst_sync`, `bow_ram_sdp` (RAM 2 clock).
- IP GPIO / IOPAD `bow_gpio`: GPIOA, GPIOB (2 × 8 chân) ở `0x4000_4000` /
  `0x4000_5000`, ngắt `irq_fast[3]` / `irq_fast[4]`; hướng, push-pull/open-drain,
  set/clear/toggle nguyên tử, ngắt theo cạnh, chức năng thay thế (pinmux).
- Driver `bow_gpio.h`, ứng dụng `gpio_demo` (shell lệnh trên UART0), test mô
  phỏng `gpio`.
- KV260: PA0..PA3 ra PMOD J2 chân 2/4/6/8 (`IOBUF`, pull-up).
- `make fpga-jtag`: nạp bitstream qua JTAG bằng xsdb (nhả PROG_B, gỡ cách ly
  PS-PL, nhả `pl_resetn0`).
- `bow32_flash.py monitor` là terminal tương tác; báo lỗi rõ khi adapter không
  gửi được BREAK.

### Changed
- `kv260_cam`: chân D-PHY J9 vào `bow_dphy_io_xusp` + `bow_csi2rx`; block design
  `bow32_cam` chỉ còn PS + `clk_wiz` + 2 `proc_sys_reset` (không cần IP hay
  license MIPI); XDC mới (HS clock 2,193 ns, nhóm clock bất đồng bộ, false path
  cho data và CE, `CLOCK_DELAY_GROUP`, 7 `set_bus_skew`); `build.tcl` ghi thêm
  báo cáo clocks / clock_interaction / check_timing / methodology / drc /
  bus_skew + `clockInfo.txt` và cảnh báo khi bus skew hoặc clock delay group sai.
- `bow32_top`: bỏ port `cam_t*`, thêm port `dphy_*` và tham số `CsiLanes`,
  `CsiPhy`, `VidClkHz`; peripheral bus 9 slot. Bản `kv260` cơ bản có CSI2RX
  không có D-PHY (`CsiPhy = 0`, mọi lane LP-11).
- Driver IMX219 chuyển từ `sw/apps/camera` sang `sw/common` (`imx219.h/.c`):
  probe stream 100 µs để lane vào LP-11, format RAW8/RAW10, màu cho test
  pattern màu đơn, pattern 0–4.
- Test `camera`: luồng D-PHY qua `csi2_tx_model.sv` + mô hình IMX219 (LP-00 sau
  khi bật nguồn; FS, 2 dòng embedded, các dòng, FE; mỗi packet một burst),
  clock video 107,5 MHz.
- Cửa sổ AXI4-Lite `0x5000_0000`: không còn thiết bị trong `kv260_cam` (truy cập
  timeout → bus error).
- `bow32_top`: thêm port I2C0, miền clock video + luồng camera/ISP, master
  AXI4-Lite; main crossbar 2×6, peripheral bus 8 slot.
- `bow_rr_arbiter` khoá grant cho tới khi device nhận request.
- UART1 là chức năng thay thế của PB0 (TX) / PB1 (RX), bật sau reset:
  `bow32_top` bỏ port `uart1_rx_i/uart1_tx_o`, thêm `gpioa_*` / `gpiob_*`. Trên
  KV260 UART1 vẫn ở J2 chân 5/7.

### Removed
- MIPI CSI-2 RX Subsystem của AMD trong block design `bow32_cam` và driver của
  nó (`sw/apps/camera/csi2rx.c/.h`).

### Fixed
- `kv260_cam` build được với Vivado 2025.2 (`tcl/cam_bd.tcl`):
  `make_bd_pins_external` bỏ qua pin đã nối nên port `sys_clk`/`vid_clk`/
  `*_resetn` được tạo bằng `create_bd_port`; `C_EN_CSI_V2_0` đưa
  `CMN_PXL_FORMAT` của CSI-2 RX về RAW8 nên tham số chính được đặt lại sau và
  kiểm tra lại (cả vị trí chân D-PHY); `clk_wiz` lấy tần số vào từ `pl_clk0`
  (99,999 MHz) thay vì 100 MHz cố định (lỗi `validate_bd_design`).
- ISP: frame bị huỷ giữa một dòng (tắt ISP khi đang stream, lỗi hình học) làm
  đầu ra `isp_*` có SOF giữa dòng; giờ dòng đó được điền nốt bằng pixel 0
  (test `camera` hỏng khi đổi từ camera sang `tpg`).
- `bow32_cam.py --fast`: chờ câu trả lời của lệnh `baud` ở tốc độ mới trước khi
  đồng bộ, prompt thừa không còn làm lệnh kế tiếp báo lỗi.

## [0.1.0] - 2026-10-20

### Added
- SoC `bow32_top`: Ibex RV32IMC (cấu hình "small", commit `1b29dae8`), main
  crossbar 2×4 và peripheral bus.
- IP: SRAM 16 KiB, boot ROM 8 KiB, flash nội 128 KiB (ngữ nghĩa NOR, page 1 KiB),
  2 × UART (FIFO 16 byte, ngắt), SYSCTRL + reset manager (soft reset, UART BREAK reset).
- Memory map một nguồn (`hw/top/data/bow32_memmap.yaml`) + `tools/gen_memmap.py`.
- Boot ROM: kiểm tra header/CRC32 ảnh flash, UART loader (INFO/ERASE/WRITE/READ/CRC/BOOT/RESET).
- Firmware: HAL, crt0, linker script, ứng dụng `hello`, `uart_irq`, `flash_demo`.
- Host tools: `bow32_flash.py`, `bow32_image.py`, unit test.
- Mô phỏng Verilator: test `boot`, `load`, `break`, `flash`, `irq`.
- Flow Vivado cho Kria KV260 + overlay `xmutil` (chưa chạy thử trên board).
- CI GitHub Actions.
