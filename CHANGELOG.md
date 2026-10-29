# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/), đánh số theo
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
- `bow32_top`: thêm port I2C0, miền clock video + luồng camera/ISP, master
  AXI4-Lite; main crossbar 2×6, peripheral bus 8 slot.
- `bow_rr_arbiter` khoá grant cho tới khi device nhận request.
- UART1 là chức năng thay thế của PB0 (TX) / PB1 (RX), bật sau reset:
  `bow32_top` bỏ port `uart1_rx_i/uart1_tx_o`, thêm `gpioa_*` / `gpiob_*`. Trên
  KV260 UART1 vẫn ở J2 chân 5/7.

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
