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
- [ ] **SPI master** (cảm biến / màn hình qua PMOD).
- [x] **I2C master** ([ip/i2c.md](ip/i2c.md)): điều khiển cảm biến camera.
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
- [x] Cầu **Bow32 bus → AXI4-Lite** ([ip/axil_bridge.md](ip/axil_bridge.md)): Bow32 điều khiển IP AXI
      của Xilinx (đã dùng cho CSI-2 RX của AMD; nay cửa sổ để trống cho IP khác).
- [ ] AXI4 master (DMA) để Bow32 ghi ảnh / dữ liệu vào DDR của PS.
- [ ] Flash không bay hơi: backing store trên QSPI/eMMC thông qua PS.
- [ ] Bus TL-UL (OpenTitan) hoặc AXI làm interconnect chính, so sánh độ phức tạp.

## Mức 5 — xử lý ảnh / camera

- [x] **ISP** RAW10 → RGB/YUV 1 pixel/clock, thống kê AE/AWB/AF, capture
      ([ip/isp.md](ip/isp.md)); camera IMX219 1080p30 / 720p60 trên KV260
      ([camera_kv260.md](camera_kv260.md)).
- [x] **Bộ thu MIPI CSI-2 của Bow32** thay IP AMD ([ip/csi2rx.md](ip/csi2rx.md)):
      D-PHY RX trên `IBUFDS_DPHY`/`IDELAYE3`/`ISERDESE3`/`BUFGCE_DIV`, máy trạng
      thái LP, phát hiện SoT, căn byte, ghép lane, lớp packet (header, ECC,
      CRC-16), unpack RAW10/RAW8, eye hiệu chỉnh bằng phần mềm; `csi2_test`
      PASS 16/16 trên KV260.
- [ ] Bộ thu CSI-2 nâng cao: 4 lane (2 pixel/clock), RAW12, nhiều packet trong
      một burst, tự hiệu chỉnh lại eye khi có lỗi, deskew, ULPS.
- [ ] Hiển thị: đưa `isp_*` ra DisplayPort (live video của PS) hoặc HDMI.
- [ ] ISP nâng cao: demosaic thích nghi theo cạnh, khử nhiễu, sharpen, lens
      shading, thống kê theo lưới, 2 pixel/clock.

## Chất lượng / quy trình

- [ ] Testbench riêng cho từng IP (`hw/ip/<ip>/dv/`), coverage (đã có cho ISP và bộ thu CSI-2: so với mô hình Python).
- [ ] Mô tả thanh ghi bằng file dữ liệu (hjson/YAML) và sinh RTL + header (giống `reggen` của OpenTitan).
- [ ] Formal (SymbiYosys) cho crossbar và FIFO (cả FIFO 2 clock `bow_fifo_async`).
- [ ] Đồng mô phỏng UART ↔ PTY để chạy `bow32_flash.py` thật với mô hình Verilator.
