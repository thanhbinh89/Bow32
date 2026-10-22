# Lộ trình học và mở rộng

Các bước gợi ý theo độ khó tăng dần. Mỗi bước là một IP/tính năng có thể thêm
theo [adding_an_ip.md](adding_an_ip.md) và kiểm chứng bằng test mô phỏng.

## Mức 1 — ngoại vi cơ bản

- [ ] **Timer / CLINT** (`mtime`, `mtimecmp`) → nối `irq_timer_i`; viết `delay`
      bằng ngắt và một scheduler nhỏ.
- [x] **GPIO / IOPAD**: 2 port × 8 chân, ngắt theo cạnh, open-drain, chức năng thay thế;
      6 chân ra PMOD ([ip/gpio.md](ip/gpio.md)).
- [ ] **Watchdog** reset SoC qua `bow_rstmgr` (thêm `RST_CAUSE.WDOG`).
- [ ] UART: parity, oversampling 16×, ngắt theo mức FIFO.

## Mức 2 — hệ thống

- [ ] **PLIC** đơn giản → `irq_external_i`, nhiều nguồn ngắt có ưu tiên.
- [ ] **SPI master** + **I2C master** (cảm biến qua PMOD).
- [ ] **DMA** (host thứ 3 trên crossbar: tăng `NumHosts`).
- [ ] Flash: wait-state đọc + prefetch buffer; bật `ICache` của Ibex để thấy hiệu quả.
- [ ] Bộ đếm hiệu năng (`MHPMCounterNum`) và đo CoreMark.

## Mức 3 — debug và phần mềm

- [ ] **Debug module** RISC-V ([pulp riscv-dbg](https://github.com/pulp-platform/riscv-dbg))
      + JTAG → debug bằng OpenOCD/GDB (`debug_req_i` của Ibex).
- [ ] Port **FreeRTOS** (cần timer + ngắt).
- [ ] Bootloader thứ 2 trong flash, cập nhật firmware an toàn (A/B, rollback).
- [ ] Bật **PMP**, tách chế độ M/U.

## Mức 4 — tích hợp với Kria

- [ ] UART của Bow32 ↔ PS qua AXI UART Lite: điều khiển từ Linux, không cần adapter.
- [ ] Cầu **Bow32 bus → AXI4-Lite** để Bow32 truy cập DDR / IP AXI của Xilinx.
- [ ] Flash không bay hơi: backing store trên QSPI/eMMC thông qua PS.
- [ ] Bus TL-UL (OpenTitan) hoặc AXI làm interconnect chính, so sánh độ phức tạp.

## Chất lượng / quy trình

- [ ] Testbench riêng cho từng IP (`hw/ip/<ip>/dv/`), coverage.
- [ ] Mô tả thanh ghi bằng file dữ liệu (hjson/YAML) và sinh RTL + header (giống `reggen` của OpenTitan).
- [ ] Formal (SymbiYosys) cho crossbar và FIFO.
- [ ] Đồng mô phỏng UART ↔ PTY để chạy `bow32_flash.py` thật với mô hình Verilator.
