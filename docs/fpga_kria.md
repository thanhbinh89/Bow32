# Chạy Bow32 trên AMD Kria KV260

> **Trạng thái:** flow Vivado và overlay đã được viết theo tài liệu Kria nhưng
> **chưa được chạy thử trên board/Vivado thật** trong lần tạo dự án này. Hãy
> kiểm tra kỹ phần chân PMOD trước khi nối dây, và báo lại lỗi (nếu có) để
> sửa script.

## Tổng quan

```
   Zynq UltraScale+ PS (Linux)              PL (FPGA)
  ┌──────────────────────────┐   pl_clk0  ┌───────────────────────────────┐
  │  Kria Ubuntu / PetaLinux │──100 MHz──>│ BUFGCE_DIV /2 ─> 50 MHz        │
  │  xmutil / fpga manager   │ pl_resetn0 │                                │
  │                          │──────────> │  bow32_top                     │
  └──────────────────────────┘            │   UART0 ─┐   UART1 ─┐          │
                                          └──────────┼──────────┼──────────┘
                                                PMOD J2 (3.3 V)
                                                     │          │
                                             USB-UART #1   USB-UART #2 (tuỳ chọn)
```

* PS chỉ dùng làm nguồn clock (`pl_clk0` = 100 MHz) và reset (`pl_resetn0`);
  không có giao tiếp AXI. Block design `bow32_ps` được tạo bằng `tcl/ps_bd.tcl`.
* SoC chạy 50 MHz (`BUFGCE_DIV`), register file của Ibex dùng LUTRAM
  (`RegFileFPGA`).
* Board top: `hw/fpga/kv260/rtl/bow32_kv260_top.sv`, ràng buộc chân:
  `hw/fpga/kv260/constr/kv260.xdc`.
* Chân quạt SOM (`fan_en_b`, A12) được kéo thấp → quạt chạy tối đa.

Dùng KR260 hoặc carrier khác: copy `hw/fpga/kv260/` thành thư mục board mới,
sửa XDC theo user guide của carrier (KR260: UG1092) và gọi `make fpga BOARD=<tên>`.

## 1. Phần cứng cần có

* Kria KV260 + thẻ SD Kria Ubuntu 22.04 (hoặc PetaLinux) đã boot được.
* 1–2 adapter USB-UART **3.3 V** (CP2102, FT232, CH340...).
* Dây jumper.

### Nối dây PMOD J2

| Tín hiệu Bow32 | Chân FPGA | `PMOD_tri_io` | Nối tới adapter |
|----------------|-----------|---------------|-----------------|
| `uart0_tx_o` | H12 | [0] | RX |
| `uart0_rx_i` | E10 | [1] | TX |
| `uart1_tx_o` | D10 | [2] | RX (adapter 2) |
| `uart1_rx_i` | C11 | [3] | TX (adapter 2) |
| GND | — | — | GND |

Các chân package lấy theo `PMOD_tri_io[0..3]` trong thiết kế tham chiếu của
AMD cho KV260. **Trước khi nối**, đối chiếu số chân vật lý trên J2 với bảng
PMOD trong *Kria KV260 Vision AI Starter Kit User Guide (UG1089)* hoặc schematic
carrier. Không nối chân VCC của adapter. Đầu ra TX được đặt `DRIVE 4`,
`SLEW SLOW` để hạn dòng nếu lỡ nối nhầm.

## 2. Build bitstream (máy tính có Vivado)

Yêu cầu: Vivado 2022.2 trở lên (có device K26), `bootgen` trong PATH (đi kèm
Vivado/Vitis), `dtc` (tuỳ chọn). Board files KV260 (XHub Stores) giúp cấu hình
PS theo preset nhưng không bắt buộc.

```bash
source /tools/Xilinx/Vivado/2023.2/settings64.sh
make sw
make fpga                 # = make -C hw/fpga/kv260 all
# Nạp sẵn ứng dụng vào flash trong bitstream (không cần UART loader):
make fpga FLASH_VMEM=$PWD/build/sw/hello/hello.vmem
```

Kết quả trong `build/fpga/kv260/`:

| File | Nội dung |
|------|----------|
| `bow32_kv260.bit` | bitstream |
| `timing_summary.rpt`, `utilization.rpt` | báo cáo (kiểm tra WNS ≥ 0) |
| `vivado/bow32_kv260.xpr` | project Vivado, mở bằng GUI để xem/debug |
| `firmware/bow32/` | `bow32.bit.bin`, `bow32.dtbo` (hoặc `pl.dtsi`), `shell.json` |

## 3. Nạp lên Kria bằng `xmutil` (khuyên dùng)

```bash
# Trên PC
scp -r build/fpga/kv260/firmware/bow32 ubuntu@<kria-ip>:/tmp/

# Trên Kria
sudo mkdir -p /lib/firmware/xilinx/bow32
sudo cp /tmp/bow32/* /lib/firmware/xilinx/bow32/
# nếu chưa có dtc trên PC: sudo apt install device-tree-compiler
#   cd /lib/firmware/xilinx/bow32 && sudo dtc -@ -O dtb -o bow32.dtbo pl.dtsi
sudo xmutil listapps
sudo xmutil unloadapp
sudo xmutil loadapp bow32
```

Overlay (`overlay/pl.dtsi`) nạp `bow32.bit.bin` vào PL và bật `pl_clk0` ở
100 MHz. Mỗi lần `loadapp`, PL được cấu hình lại → flash Bow32 (BRAM) trở về
nội dung trong bitstream.

Cách khác: Vivado Hardware Manager qua JTAG (cáp micro-USB của KV260) khi Linux
đã boot — PS phải đang cấp `pl_clk0`.

## 4. Kiểm tra

```bash
# Trên PC, adapter UART0 ở /dev/ttyUSB0
python3 tools/bow32_flash.py -p /dev/ttyUSB0 monitor
```

Ngay sau khi `loadapp` bạn sẽ thấy banner ROM (flash trống → loader):

```
Bow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1
boot: flash image invalid (no image)
boot: UART loader ready
```

Nạp và chạy ứng dụng:

```bash
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/hello/hello.bin
python3 tools/bow32_flash.py -p /dev/ttyUSB0 monitor
```

Muốn nạp lại: chỉ cần chạy lại lệnh `flash` — tool gửi BREAK để reset Bow32 vào
loader.

## Xử lý sự cố

| Triệu chứng | Kiểm tra |
|-------------|----------|
| Không thấy gì trên UART | TX/RX bị đảo? GND? đúng 3.3 V? đúng chân PMOD? baud 115200? `pl_clk0` có chạy (overlay đã nạp)? |
| Ký tự rác | sai baud ⇒ tần số `pl_clk0` khác 100 MHz (kiểm tra `assigned-clock-rates` trong overlay) |
| `cannot reach the boot ROM loader` | adapter không hỗ trợ BREAK → dùng `--no-break` rồi `xmutil unloadapp && xmutil loadapp bow32` trong lúc tool đang chờ |
| Timing không đạt | xem `timing_summary.rpt`; giảm clock (sửa `PlClkHz`/BUFGCE_DIVIDE) |
| Synthesis báo thiếu `bow32_ps_wrapper` | block design chưa được tạo — xem log `ps_bd.tcl` trong `vivado.log` |

## Hướng phát triển trên Kria

* Nối UART của Bow32 vào PS (AXI UART Lite hoặc EMIO UART) để điều khiển từ Linux, không cần adapter.
* ILA để quan sát bus Bow32 trong Vivado Hardware Manager.
* Lưu flash không bay hơi qua PS (DDR/QSPI) — xem [roadmap.md](roadmap.md).
