# Chạy Bow32 trên AMD Kria KV260

> **Trạng thái:** flow Vivado và overlay đã được viết theo tài liệu Kria nhưng
> **chưa được chạy thử trên board/Vivado thật** trong lần tạo dự án này. Chân
> PMOD đã được đối chiếu với schematic carrier KV260 (xem mục nối dây J2); hãy
> báo lại lỗi (nếu có) để sửa script.

## Tổng quan

```
   Zynq UltraScale+ PS (Linux)              PL (FPGA)
  ┌──────────────────────────┐   pl_clk0  ┌───────────────────────────────┐
  │  Kria Ubuntu / PetaLinux │──100 MHz──>│ BUFGCE_DIV /2 ─> 50 MHz        │
  │  xmutil / fpga manager   │ pl_resetn0 │                                │
  │                          │──────────> │  bow32_top                     │
  └──────────────────────────┘            │   UART0 ─┐   GPIO ─┐ PA0..PA3  │
                                          └──────────┼─────────┼ PB0/PB1 ──┘
                                                PMOD J2 (3.3 V)│ (= UART1)
                                                     │         │
                                             USB-UART #1   LED, nút nhấn, USB-UART #2
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
* Dây jumper; để thử GPIO (tuỳ chọn): LED + điện trở 330 Ω, nút nhấn.

### Nối dây PMOD J2

J2 là header cái 2 × 6 chân (góc vuông) ở mép board, cạnh cổng micro-USB.
Hàng chân lẻ: UART0 và PB0/PB1 (sau reset là UART1). Hàng chân chẵn: PA0..PA3.

```
   J2 nhìn thẳng từ ngoài mép board (mặt linh kiện hướng lên)

             ┌───────┬───────┬───────┬───────┬───────┬───────┐
   hàng trên │   1   │   3   │   5   │   7   │   9   │  11   │
   chân lẻ   │ U0 TX │ U0 RX │  PB0  │  PB1  │  GND  │  3V3  │
             ├───────┼───────┼───────┼───────┼───────┼───────┤
   hàng dưới │   2   │   4   │   6   │   8   │  10   │  12   │
   chân chẵn │  PA0  │  PA1  │  PA2  │  PA3  │  GND  │  3V3  │
             └───────┴───────┴───────┴───────┴───────┴───────┘
             ══════════════════════ PCB ══════════════════════
             PB0 / PB1 = UART1 TX / RX sau reset (GPIOB.AF)
```

| Tín hiệu Bow32 | Chân J2 | Net carrier | SOM240_1 | Chân FPGA | Nối tới |
|----------------|---------|-------------|----------|-----------|---------|
| `uart0_tx_o` | 1 | HDA11 | A17 | H12 | RX adapter |
| `uart0_rx_i` | 3 | HDA12 | D20 | E10 | TX adapter |
| PB0 = UART1 TX | 5 | HDA13 | D21 | D10 | RX adapter 2 (tuỳ chọn) |
| PB1 = UART1 RX | 7 | HDA14 | D22 | C11 | TX adapter 2 (tuỳ chọn) |
| PA0 | 2 | HDA15 | B20 | B10 | LED / nút / dây nối (mục 5) |
| PA1 | 4 | HDA16_CC | B21 | E12 | |
| PA2 | 6 | HDA17 | B22 | D11 | |
| PA3 | 8 | HDA18 | C22 | B11 | |
| GND | 9 hoặc 10 | GND | — | — | GND |
| 3,3 V | 11, 12 | PMOD_3V3 | — | — | **không nối VCC của adapter** |

* Nguồn đối chiếu: schematic carrier KV260 (AMD XTP682; bản đầu `038-05058-01`
  rev B05 và KV260_v2 `038-05058-03` rev A1 giống nhau ở phần này), trang 17
  (J2 → `PMOD_HDAxx` → điện trở 0 Ω → `HDAxx`) và trang 6 (`HDAxx` → chân
  SOM240_1). Chân FPGA lấy từ board file K26 của Vivado
  (`data/xhub/boards/XilinxBoardStore/boards/Xilinx/k26c/1.4/part0_pins.xml`).
* Số chân J2 theo schematic: chân lẻ một hàng, chân chẵn một hàng. Theo chuẩn
  Pmod, hàng chân lẻ là hàng trên (Pmod pin 1–6), hàng chân chẵn là hàng dưới
  (Pmod pin 7–12). Trái/phải trong hình tuỳ hướng nhìn, nên hãy định vị bằng
  cột nguồn: 3V3 (11, 12) sát một đầu, GND (9, 10) ngay cạnh, chân 1 và 2 ở đầu
  kia.
* `PMOD_3V3` lấy từ `PL_3V3` qua load switch U42, luôn bật khi PL có nguồn.
  Không nối chân VCC của adapter. UART0 TX được đặt `DRIVE 4`, `SLEW SLOW` để
  hạn dòng nếu lỡ nối nhầm.
* 6 chân GPIO là pad hai chiều (`IOBUF`) có pull-up, `DRIVE 8`, `SLEW SLOW`. Sau
  reset PA0..PA3 là chân vào, PB0/PB1 là UART1.
* Chân 1 và 2 có sẵn RC 20 Ω + 33 pF xuống GND (R274/C370, R275/C371), không
  ảnh hưởng ở 115200 baud hay khi dùng làm GPIO.

Kiểm tra bằng đồng hồ trước khi nối adapter (board đã nạp bitstream, xem mục 3):

1. Tìm cột nguồn: ở một đầu J2, cột ngoài cùng (chân 11, 12) đo được +3,3 V so
   với cột kế bên (chân 9, 10 = GND).
2. Sau reset, cả 8 chân tín hiệu đều ≈ 3,3 V: TX nghỉ ở mức cao, các chân vào có
   pull-up. UART0 nằm ở hàng chân lẻ (chân 1 và 3). Theo chuẩn Pmod, đó là hàng
   trên. Khi đã thấy banner, có thể xác nhận hàng chân chẵn bằng `gpio_demo`
   (mục 5): `d a 0f` đưa PA0..PA3 về 0 V.

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

### Cách khác: nạp qua JTAG (`make fpga-jtag`)

Không cần Linux (board boot tới U-Boot là đủ), chỉ cần cáp micro-USB của KV260
và `xsdb` (đi kèm Vitis):

```bash
make fpga-jtag                          # hw/fpga/kv260/tcl/jtag_load.tcl
make fpga-jtag JTAG_SERIAL=<serial>     # nhiều board chung một hw_server
```

Đừng nạp bằng *Program Device* của Vivado. Khi nạp qua PCAP (`xmutil`), PMU
firmware còn nhả PROG_B của PL, bật nguồn/gỡ cách ly PS-PL và nhả `pl_resetn0`;
nạp JTAG trần thì không. Nếu từ lúc boot PL chưa được nạp qua PCAP lần nào, CSU
giữ PROG_B thấp (PL không giữ được cấu hình) và `pl_resetn0` thấp (Bow32 nằm im
trong reset), nên UART không ra gì. Script làm đủ các bước đó quanh lần nạp
JTAG và kiểm tra `pl_clk0` = 100 MHz.

Mở monitor UART **trước** khi nạp: banner chỉ in một lần, ngay khi Bow32 ra khỏi
reset.

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
loader. `monitor` là terminal tương tác (phím gõ được gửi xuống board), Ctrl-C để
thoát.

### Xoá ứng dụng, quay về bootloader

```bash
T=tools/bow32_flash.py
python3 $T -p /dev/ttyUSB0 erase --all     # BREAK -> loader, xoá toàn bộ flash
python3 $T -p /dev/ttyUSB0 reset           # khởi động lại: "flash image invalid" -> loader
```

Adapter không gửi được BREAK (ví dụ CH343/CH9102 dạng `/dev/ttyACM*`, tool báo
`the adapter cannot send a BREAK` hoặc `cannot reach the boot ROM loader`): vào
loader bằng cách khác rồi thêm `--no-break`:

1. Trong `monitor` gõ `B` (ứng dụng `hello`) → `boot: loader requested by firmware`,
   thoát monitor bằng Ctrl-C.
2. `python3 $T -p /dev/ttyACM0 --no-break erase --all`, rồi
   `python3 $T -p /dev/ttyACM0 --no-break reset`.

Ứng dụng không có phím `B` thì chạy lệnh `--no-break` trước, rồi nạp lại PL
(`make fpga-jtag` hoặc `xmutil loadapp`) trong lúc tool đang chờ (~10 s): ROM chờ
host 300 ms sau reset.

Flash của Bow32 là BRAM: nạp lại PL thì flash trở về nội dung trong bitstream
(ảnh `FLASH_VMEM` nếu build với tuỳ chọn này). Muốn mỗi lần nạp PL đều vào thẳng
bootloader, build lại không có `FLASH_VMEM` (`make fpga`).

## 5. Chạy thử GPIO

Firmware `sw/apps/gpio_demo/` là một shell lệnh trên UART0 để đọc/ghi mọi thanh
ghi GPIO ([docs/ip/gpio.md](ip/gpio.md)). Nạp theo một trong hai cách:

```bash
make sw
# a) nạp sẵn vào flash trong bitstream
make fpga FLASH_VMEM=$PWD/build/sw/gpio_demo/gpio_demo.vmem && make fpga-jtag
# b) bitstream có GPIO đang chạy + UART loader
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/gpio_demo/gpio_demo.bin
```

Mở `monitor` (banner `gpio_demo: GPIOA/GPIOB (IOPAD), type h for help`), gõ lệnh
rồi Enter. `<p>` là `a`/`b`, số là mặt nạ chân dạng hex:

| Thử | Nối dây | Lệnh | Kết quả |
|-----|---------|------|---------|
| Đọc chân | không cần | `r` | `A: in=0f ...` (PA0..PA3 có pull-up; PA4..PA7 không có chân = 0), `B: in=03 ...` |
| LED | PA0 (chân 2) → 330 Ω → LED → GND (chân 10) | `d a 01`, `s a 01`, `c a 01`, `b a 01` | sáng, tắt, nhấp nháy 2 Hz (`b` để dừng) |
| Nút nhấn | nút giữa PA2 (chân 6) và GND | `i a 04 f` | mỗi lần nhấn in `irq A: pins=04 ...` (phím dội có thể báo vài lần) |
| Ra → vào, không cần linh kiện | dây nối PA1 (chân 4) ↔ PA3 (chân 8) | `d a 02`, `i a 08`, `t a 02` | `irq A: pins=08 in=0a`; `r` thấy bit 3 theo bit 1 |
| Open-drain | giữ dây PA1 ↔ PA3 | `m a 02`, `s a 02`, `r`, `c a 02`, `r` | PA1 thả nổi → pull-up kéo lên 1; `c` kéo xuống 0 |
| PB0/PB1 làm GPIO | **tháo adapter UART1** (nếu có) | `f b 0`, `d b 3`, `t b 3` | chân 5 và 7 đổi mức; `f b 3` trả lại UART1 |

* LED nối kiểu trên có thể sáng mờ khi PA0 đang là chân vào (dòng qua pull-up).
  Nối LED từ 3V3 (chân 11) → điện trở → LED → PA0 thì không bị: chân xuống 0 =
  LED sáng.
* Không cho một chân xuất khi bên ngoài cũng đang lái nó (adapter TX, chân xuất
  khác): tranh chấp mức. Dùng open-drain nếu cần nối chung một dây.

## Xử lý sự cố

| Triệu chứng | Kiểm tra |
|-------------|----------|
| Không thấy gì trên UART | TX/RX bị đảo? GND? đúng 3.3 V? đúng chân PMOD? baud 115200? `pl_clk0` có chạy (overlay đã nạp)? |
| Nạp bằng *Program Device* của Vivado, UART im lặng | PL bị PS giữ reset → dùng `make fpga-jtag` hoặc `xmutil` (mục 3) |
| Mở monitor sau khi nạp, không thấy banner | banner chỉ in một lần → mở monitor trước khi nạp, hoặc gõ phím: `hello` echo lại, `B` khởi động lại vào loader |
| `Permission denied` khi mở `/dev/ttyUSB*`, `/dev/ttyACM*` | user chưa ở nhóm `dialout`: `sudo usermod -aG dialout $USER` rồi đăng nhập lại |
| Ký tự rác | sai baud ⇒ tần số `pl_clk0` khác 100 MHz (kiểm tra `assigned-clock-rates` trong overlay) |
| Chân GPIO không đổi mức | `DIR` chưa đặt bit (chân vẫn là chân vào)? PB0/PB1 còn là UART1 (`AF`)? PA4..PA7, PB2..PB7 không có chân trên KV260 |
| Không thấy UART1 trên chân 5/7 | phần mềm đã tắt `GPIOB.AF` (PB0/PB1 đang là GPIO) |
| `cannot reach the boot ROM loader`, `cannot send a BREAK` | adapter không hỗ trợ BREAK → xem "Xoá ứng dụng, quay về bootloader" (mục 4) |
| Timing không đạt | xem `timing_summary.rpt`; giảm clock (sửa `PlClkHz`/BUFGCE_DIVIDE) |
| Synthesis báo thiếu `bow32_ps_wrapper` | block design chưa được tạo — xem log `ps_bd.tcl` trong `vivado.log` |

## Hướng phát triển trên Kria

* Nối UART của Bow32 vào PS (AXI UART Lite hoặc EMIO UART) để điều khiển từ Linux, không cần adapter.
* ILA để quan sát bus Bow32 trong Vivado Hardware Manager.
* Lưu flash không bay hơi qua PS (DDR/QSPI) — xem [roadmap.md](roadmap.md).
