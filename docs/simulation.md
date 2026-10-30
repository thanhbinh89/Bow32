# Mô phỏng

Testbench hệ thống: `sim/tb/tb_bow32.sv` (SystemVerilog thuần, Verilator ≥ 5.0
với `--binary --timing`). Testbench đóng vai máy tính host: theo dõi cả hai
đường UART TX, gõ phím vào RX, và hiện thực giao thức UART loader giống hệt
`bow32_flash.py`. Nó cũng mô hình phía camera của KV260: switch I2C TCA9546A +
thanh ghi IMX219 trên bus I2C, luồng MIPI CSI-2 của IMX219 trên các cổng D-PHY
của bộ thu (`hw/ip/csi2rx/dv/csi2_tx_model.sv` thay cho cảm biến và I/O của
board; clock video riêng ~107,5 MHz, không đồng bộ với CPU) và một thiết bị trên
cổng AXI4-Lite.

```bash
make sw            # firmware: build/sw/
make test          # build mô hình + chạy mọi test
make run TEST=load # chạy một test, log ở build/sim/load.log
make run TEST=load WAVES=1   # + build/sim/waves.fst  (gtkwave build/sim/waves.fst)
make test-ip       # test riêng của ISP và bộ thu CSI-2 (bên dưới)
make test-tools    # unit test của công cụ Python (gồm mô hình CSI-2)
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
| `camera` | ROM + `camera` | dò IMX219 qua I2C (PA7, TCA9546A, clock stretching); cửa sổ AXI4-Lite (đọc/ghi qua cầu, bus error khi `SLVERR`/timeout); mode 64×48, `cam` hiệu chỉnh eye (mọi tap tốt: `taps 248/248 eye 512/512`), `csi` → `csi2rx: link ok`, 48 dòng, WC 80; sọc màu của cảm biến → bộ thu CSI-2 → ISP → capture → ảnh RGB qua UART (CRC + kiểm tra màu từng sọc), AE và AWB hội tụ, flip (BGGR), TPG của ISP ở YUV |
| `csi2` | ROM + `csi2_test` | `test quick` → `csi2_test: PASS (11/11)` (eye mô hình: lane 0 tap 100…300, lane 1 180…400, tap reset 0 xấu; hiệu chỉnh phải ra ~208/288); rồi cài lỗi vào một frame đang chạy (lật 1 bit header → ECC sửa, lật 1 bit payload → CRC, byte sync sai trên lane 1 → SOT + skew) và `stat` phải in đúng `ecc 1/0 crc 1 trunc 0 sot 0/1 ovf 0`, `misc ≥ 1`; một dòng `[FAIL]` dừng mô phỏng ngay |

Một test PASS khi in `TEST PASSED`; lỗi dùng `$fatal` (mã thoát ≠ 0). Có
watchdog `+TIMEOUT=<cycles>` (mặc định 20 M chu kỳ; `csi2` cần ~3,7 M).
`camera` và `csi2` kết thúc bằng một kiểm tra PHY: cổng byte clock chỉ mở và
đóng khi lane clock đứng yên ở HS-0, không có xung runt.

### Mô hình IMX219 và D-PHY

`csi2_tx_model.sv` (dùng chung với test IP) đóng vai cảm biến và I/O D-PHY của
board: byte clock chỉ chạy khi lane clock chạy và `byte_ce = 1`, word ISERDES ở
pha bit ngẫu nhiên mỗi burst, IDELAY có mô hình eye (tap ngoài
`[eye_lo, eye_hi]` thì mỗi bit lật với xác suất 1/4). Cảm biến trong testbench:

- mọi lane ở LP-00 sau khi bật nguồn tới lần stream đầu tiên (`0x0100 = 1`),
  sau đó LP-11 khi không stream; stream-on lúc kích thước còn 0 (probe của
  firmware) không gửi frame;
- lấy format (`0x018C`) và kích thước khi stream-on; test pattern, màu,
  exposure, gain, orientation ở mỗi frame; kiểm tra cấu hình firmware đã ghi
  (crop khớp kích thước, RAW8/RAW10 ở `0x018C/0x018D/0x0309`, 2 lane + PLL,
  exposure ≤ FLL − 4);
- mỗi frame: FS (số frame 1…4), 2 dòng embedded (DT 0x12), H dòng RAW10/RAW8,
  FE; mỗi packet một burst, lane clock ở HS suốt frame như IMX219 thật;
  stream-off thì gửi nốt frame đang dở;
- thời gian nén: burst sát nhau, vertical blanking 20 µs, không theo FLL/LLP.

Clock video 9,3 ns (`VidClkHz = 107_526_882`): `INFO` báo 108 MHz, nên driver
đặt `PHY_CFG` = 8/16/4 chu kỳ (SETTLE/CLK_SETTLE/CLK_MISS).

## Plusargs

| Plusarg | Ý nghĩa |
|---------|---------|
| `+TEST=<tên>` | chọn kịch bản |
| `+ROM=<vmem>` | ảnh boot ROM (bắt buộc) |
| `+FLASH=<vmem>` | nạp sẵn flash (backdoor) |
| `+IMAGE=<vmem>` | ảnh tải qua UART trong test `load` |
| `+TIMEOUT=<n>` | giới hạn chu kỳ |
| `+WAVES` | ghi waveform (cần build với `WAVES=1`) |

## Test riêng của IP

`make test-ip` chạy cả hai test dưới đây (CI cũng vậy).

### ISP

`hw/ip/isp/dv/` so ISP với mô hình Python bit-exact (`tools/isp/isp_model.py`):
cấu hình và ảnh ngẫu nhiên theo seed, cả luồng camera và TPG, hai clock không
đồng bộ, đầu vào có khoảng trống ngẫu nhiên. So sánh từng pixel đầu ra, thống
kê, histogram và buffer capture.

```bash
make -C hw/ip/isp/dv test                       # seed 1..6, camera + TPG
make -C hw/ip/isp/dv run SEED=7 TPG=1 WIDTH=160 HEIGHT=90
```

### Bộ thu CSI-2

`hw/ip/csi2rx/dv/` so bộ thu với mô hình Python `tools/csi2/csi2_model.py`, được
viết từ đặc tả và quy tắc MIPI chứ không từ RTL. Mô hình sinh cấu hình và kích
thích (`cfg.txt`, `stim.txt`); `tb_bow_csi2rx.sv` chơi chúng qua
`csi2_tx_model.sv` với `tready` ngẫu nhiên, ghi pixel (`out.txt`) và thanh ghi
(`regs.txt`); mô hình so sánh pixel (`tuser`/`tlast`), bộ đếm, FRAME/LINE_INFO,
FRAME_SUM, FRAME/LINE_TIME, LOG và các bất biến PHY.

```bash
make -C hw/ip/csi2rx/dv test                          # 30 case (~5 s)
make -C hw/ip/csi2rx/dv test SEEDS="1 2 3 4 5 6 7 8"
make -C hw/ip/csi2rx/dv run SEED=7 LANES=1 ERRORS=1   # thêm DUT_LANES=1|2 RAW8=1 CONTCLK=1
make -C hw/ip/csi2rx/dv run TEST=clk                  # một test directed
```

- Random, mỗi seed 5 cấu hình: 2 lane có/không lỗi, 1 lane (`Lanes = 1`) có
  lỗi, 1 lane trên bộ thu 2 lane có/không lỗi; RAW8 và clock liên tục xen kẽ.
  Lỗi: lật bit header (1 và 2 bit), lật bit payload, sync sai, lệch lane, cắt
  packet.
- Directed: `lp` (escape, LP-00 từ Stop, độ trễ LP-00 → `hs_en`), `watchdog`,
  `clk` (CE chỉ đổi ở HS-0, mất clock), `cmd` (lệnh LOG/RAW khi byte clock
  dừng), `ovf` (tràn FIFO), `stop` (dừng giữa burst rồi chạy lại), `byteclk`,
  `eye` (nạp và đọc lại tap, mô hình eye); `cmd` và `stop` chạy thêm với 1 lane.
- Mỗi case giữ file trong `build/csi2rx_dv/<case>/` (`sim.log` cho CI); một
  binary Verilator cho mỗi giá trị `Lanes` (`build/csi2rx_dv/obj_l1`, `obj_l2`).
- `make test-tools` chạy 19 unit test của mô hình (`tools/tests/test_csi2_model.py`).

### D-PHY I/O trên FPGA (xsim)

`hw/fpga/common/dv/` mô phỏng `bow_dphy_io_xusp` + `bow_csi2rx` với model
unisim của Vivado (`IBUFDS_DPHY`, `IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`). Máy
phát trong testbench lái chân P/N từng bit ở 912 Mbit/s: clock không liên tục,
HS-ZERO dài ngẫu nhiên (pha bit của byte sync), lệch nhỏ giữa hai lane; mức LP
lái mạnh, mức HS lái yếu (model `IBUFDS_DPHY` dựa vào đó để phân biệt LP và HS).

```bash
source <Vivado>/settings64.sh
make test-fpga-dv                              # = make -C hw/fpga/common/dv test (seed 1 2 3)
make -C hw/fpga/common/dv run SEED=5 WAVES=1   # waveform trong build/fpga_dv/seed5
```

Kiểm tra: word ISERDES chứa HS-zero + sync + đúng các byte đã gửi, clock /1 và
/4 không có xung runt và thẳng pha qua các lần gate, CE chỉ đổi khi lane clock ở
HS-0, `RST` của ISERDES nhả mỗi burst ≥ 20 byte clock trước sync, ghi `DLY` →
CNTVALUEOUT ở burst sau, pixel và thanh ghi của bộ thu. Cần Vivado nên không
chạy trong CI; pass/fail lấy từ dòng `tb_bow_dphy_io_xusp: PASS` (mã thoát của
xsim không phản ánh kết quả). Eye không mô phỏng được: unisim không có lệch
clock/data.

## Thêm test

1. Viết firmware trong `sw/apps/<tên>/` (copy `hello`).
2. Thêm một nhánh trong `run_test()` của testbench: dùng `expect_text(port, "...")`,
   `uart_send(port, byte)`, `uart_send_str(port, "...")`, `uart0_break(cycles)`,
   `boot_cmd(cmd, payload, rsp)`. Chân GPIO: đọc `pad_a`/`pad_b`, `gpioa_oe`/`gpiob_oe`;
   lái từ bên ngoài bằng `ext_a_en`/`ext_a_val` (pad có pull-up, testbench báo lỗi nếu
   chip và testbench cùng lái một chân). Camera: thanh ghi cảm biến `imx_reg[]`,
   `cam_frames`, kích thước frame ra của ISP `out_w`/`out_h`, nhận ảnh của lệnh
   `dump` bằng `receive_image()`; máy phát D-PHY `u_csi` (`push_short`,
   `push_long`, `idle`, `eye_lo`/`eye_hi`, cờ lỗi trong `csi2_flags()`, xem
   header của `csi2_tx_model.sv`).
3. Thêm tên test vào `TESTS` và biến `FLASH_<test>` trong `sim/Makefile`.

## Lưu ý khi viết testbench cho Verilator

* Task có delay bị inline tại mọi chỗ gọi → giữ timing trong vài process
  (`uart_driver`, `uart_monitor`, process phát của `csi2_tx_model`) và để phần
  còn lại là function (API của `csi2_tx_model` chỉ xếp hàng đợi).
* Khởi tạo lại biến/queue cục bộ một cách tường minh ở đầu function.
* Verilator là mô phỏng 2-state: reset bất đồng bộ cần có cạnh thật. Testbench
  kéo `rst_n` 1→0 sau thời điểm 0, và `bow_rstmgr` khởi động với reset nhả
  (chỉ trong `ifdef VERILATOR`). Bộ thu CSI-2 làm tương tự: `rx_on` khởi động
  ở 1 và cổng lane clock mở cho tới xung reset, để các bộ đồng bộ reset của
  datapath và của ISERDES thấy một cạnh xuống.
* Verilator 5.022: delay `#0`, hoặc delay biến có giá trị 0, làm hỏng bộ lập
  lịch timing (crash hoặc sai lặng lẽ): chặn mọi delay biến bằng 0.
* Queue trong biến automatic giữ qua delay trong process `fork` bị hỏng: dùng
  buffer static.
* `$realtime` dùng bên trong một biểu thức bị cắt về đơn vị thời gian (ví dụ
  `longint'($realtime * 1000.0)` cho 8000 ở 8,772 ns): gán vào biến trước, hoặc
  dùng `csi2_now()` của `csi2_tx_pkg` (package có đơn vị 1 ps).
* Mô hình bit theo thời gian: tính bằng ps nguyên (`floor()` số thực ở biên bit
  làm lặp hoặc mất bit; `$rtoi(ns * 1000)` tràn 32 bit sau 2,1 ms).
* CI dùng Verilator 5.020 của Ubuntu 24.04; các test bộ thu CSI-2 được phát
  triển với 5.022.

## Lint

```bash
make lint     # verilator --lint-only -Wall trên toàn SoC (Ibex được miễn trừ)
```
