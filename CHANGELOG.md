# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/), đánh số theo
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
