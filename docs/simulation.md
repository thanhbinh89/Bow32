# Mô phỏng

Testbench hệ thống: `sim/tb/tb_bow32.sv` (SystemVerilog thuần, Verilator ≥ 5.0
với `--binary --timing`). Testbench đóng vai máy tính host: theo dõi cả hai
đường UART TX, gõ phím vào RX, và hiện thực giao thức UART loader giống hệt
`bow32_flash.py`.

```bash
make sw            # firmware: build/sw/
make test          # build mô hình + chạy mọi test
make run TEST=load # chạy một test, log ở build/sim/load.log
make run TEST=load WAVES=1   # + build/sim/waves.fst  (gtkwave build/sim/waves.fst)
```

Để mô phỏng nhanh, testbench đặt `BootBaud = 1 Mbaud`, `BootWaitMs = 1` và
`BreakCycles = 2000`; ROM và ứng dụng đọc các giá trị này từ SYSCTRL nên
**cùng một binary** chạy được cả trong mô phỏng lẫn trên board.

## Các test

| Test | Firmware | Kiểm tra |
|------|----------|----------|
| `boot` | ROM + `hello` nạp sẵn vào flash | ROM kiểm tra CRC, chờ host, nhảy vào app; in trên UART0/UART1; echo |
| `load` | ROM, flash trống, tải `hello` qua UART | INFO, ERASE, WRITE ×10, CRC verify, BOOT, app chạy |
| `break` | ROM + `hello` | BREAK trên UART0 reset SoC, `RST_CAUSE = BREAK`, loader trả lời |
| `flash` | ROM + `flash_demo` | program/erase từ ứng dụng, lỗi khi lập trình bit 0→1, soft reset, dữ liệu còn sau reset |
| `irq` | ROM + `uart_irq` | ngắt nhanh UART1, WFI, ISR |
| `gpio` | ROM + `gpio_demo` | gửi lệnh qua UART0 rồi kiểm tra pad: xuất, set/clear/toggle, đọc `IN`, ngắt cạnh xuống, open-drain, tắt/bật chức năng thay thế PB0/PB1 (UART1) |

Một test PASS khi in `TEST PASSED`; lỗi dùng `$fatal` (mã thoát ≠ 0). Có
watchdog `+TIMEOUT=<cycles>` (mặc định 20 M chu kỳ).

## Plusargs

| Plusarg | Ý nghĩa |
|---------|---------|
| `+TEST=<tên>` | chọn kịch bản |
| `+ROM=<vmem>` | ảnh boot ROM (bắt buộc) |
| `+FLASH=<vmem>` | nạp sẵn flash (backdoor) |
| `+IMAGE=<vmem>` | ảnh tải qua UART trong test `load` |
| `+TIMEOUT=<n>` | giới hạn chu kỳ |
| `+WAVES` | ghi waveform (cần build với `WAVES=1`) |

## Thêm test

1. Viết firmware trong `sw/apps/<tên>/` (copy `hello`).
2. Thêm một nhánh trong `run_test()` của testbench: dùng `expect_text(port, "...")`,
   `uart_send(port, byte)`, `uart_send_str(port, "...")`, `uart0_break(cycles)`,
   `boot_cmd(cmd, payload, rsp)`. Chân GPIO: đọc `pad_a`/`pad_b`, `gpioa_oe`/`gpiob_oe`;
   lái từ bên ngoài bằng `ext_a_en`/`ext_a_val` (pad có pull-up, testbench báo lỗi nếu
   chip và testbench cùng lái một chân).
3. Thêm tên test vào `TESTS` và biến `FLASH_<test>` trong `sim/Makefile`.

## Lưu ý khi viết testbench cho Verilator

* Task có delay bị inline tại mọi chỗ gọi → giữ timing trong vài process
  (`uart_driver`, `uart_monitor`) và để phần còn lại là function.
* Khởi tạo lại biến/queue cục bộ một cách tường minh ở đầu function.
* Verilator là mô phỏng 2-state: reset bất đồng bộ cần có cạnh thật. Testbench
  kéo `rst_n` 1→0 sau thời điểm 0, và `bow_rstmgr` khởi động với reset nhả
  (chỉ trong `ifdef VERILATOR`).

## Lint

```bash
make lint     # verilator --lint-only -Wall trên toàn SoC (Ibex được miễn trừ)
```
