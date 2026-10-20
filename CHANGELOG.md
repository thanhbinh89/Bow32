# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/), đánh số theo
[Semantic Versioning](https://semver.org/).

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
