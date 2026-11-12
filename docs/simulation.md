# Mô phỏng

Testbench hệ thống: `sim/tb/tb_bow32.sv` (SystemVerilog thuần, Verilator ≥ 5.0
với `--binary --timing`). Testbench đóng vai máy tính host: theo dõi cả hai
đường UART TX, gõ phím vào RX, và hiện thực giao thức UART loader giống hệt
`bow32_flash.py`. Nó cũng mô hình phía camera của KV260: switch I2C TCA9546A +
thanh ghi IMX219 trên bus I2C, luồng MIPI CSI-2 của IMX219 trên các cổng D-PHY
của bộ thu (`hw/ip/csi2rx/dv/csi2_tx_model.sv` thay cho cảm biến và I/O của
board; clock video riêng ~107,5 MHz, không đồng bộ với CPU) và một thiết bị trên
cổng AXI4-Lite. DDR được bật (`DdrEn = 1`, lõi LiteDRAM DDR2) và nối như bản loopback
của Arm MPS4: mô hình clock (`hw/ip/ddr/dv/ddr_clk_model.sv`: CK, CK/4 cho LiteDRAM, clock
đọc và hai clock ghi, hai cổng dịch pha như 3 MMCM của board), mô hình chân (`bow_ddr_io_sim.sv`, loopback) và DRAM giả lập `bow_ddr_lb`
4 MiB; clock DDR chỉ chạy trong test `ddr`, từ lúc boot ROM khởi động ứng dụng. HyperRAM
cũng được bật (`HrEn = 1`) như bản loopback của MPS4: mô hình clock
(`hw/ip/hyperram/dv/hyperram_clk_model.sv`: CK 100 MHz, clock ghi CK + T/4 và clock đọc,
hai cổng dịch pha như 2 MMCM, 672 bước mỗi CK), mô hình chân (`bow_hyperram_io_sim.sv`,
loopback) và HyperRAM giả lập `bow_hyperram_dev` 1 MiB; clock HyperRAM chỉ chạy trong test
`hyperram`.

Testbench có **hai bản dựng** (tham số `Imx274` của `tb_bow32`; `sim/Makefile` chọn bản theo
tên test): bản mặc định (`build/sim/obj`) là camera KV260 ở trên; bản `Imx274 = 1`
(`build/sim/obj-imx274`) là camera của Huins MFP-VP1902 — module Leopard LI-IMX274MIPI-FMC
qua Huins Camera Adaptor trên FMC+01 ([camera_huins.md](camera_huins.md)). Ở bản này bộ thu giống bản dựng camera Huins
(`CsiLanes = 4`, `CsiFifoDepth = 512`, `CsiDlyVid = 1`, clock video 200 MHz),
`csi2_tx_model` chạy 4 lane ở chế độ PHY Versal (byte clock 180 MHz = 1440 Mbit/s mỗi lane,
`PHY_RDY`, trễ BISC, FIFO RX với `rx_valid`), một mô hình IMX274 thay cho TCA9546A + IMX219
(mục "Mô hình IMX274 và PHY Versal" bên dưới) và PB5 (PRSNT_M2C_L) đọc 0. Hai núm run-time
của PHY trong top camera đi vào mô hình PHY: PA4 (OUT & DIR) = `reinit_i`, PA5 =
`burst_rst_en_i` (`BurstRxRst`), cả hai 0 sau reset (firmware đặt PA5 = 1 mỗi lần khởi động bộ
thu); PB6 / PB7 (PHY_RDY / DLY_RDY của mọi
nibble) đọc `PHY_RDY` của mô hình. Test `camera274`, `csi2_274`, `video274` (và `geo274` của
`test-extra`) chạy trên bản này, các test khác trên bản mặc định (chạy nhầm bản thì
testbench báo lỗi ngay).

```bash
make sw            # firmware: build/sw/
make test          # build mô hình + chạy mọi test, tổng kết ở cuối (hỏng nếu có test hỏng)
make run TEST=load # chạy một test, log ở build/sim/load.log
make run TEST=load WAVES=1   # + build/sim/waves.fst  (gtkwave build/sim/waves.fst)
make run TEST=camera274      # bản IMX274 (build/sim/obj-imx274), log ở build/sim/camera274.log
make run TEST=csi2_274 PLUSARGS="+DPHY_CORNER=2" RUN_LOG=csi2_274_c2   # thêm plusarg, log riêng
make -C sim run TEST=csi2_274 FW=brst0   # csi2_test build cho BurstRxRst = 0 + SETTLE 115 ns (chỉ mô hình, bên dưới)
make -C sim test-extra       # biến thể của test IMX274 không có trong make test / CI (bên dưới)
make -C sim build JOBS=8     # dựng cả hai bản, tối đa 8 job C++ (mặc định 0: mọi core)
make test-ip       # test riêng của ISP, bộ thu CSI-2, H.264, MKV, DDR, HyperRAM (bên dưới)
make test-tools    # unit test của công cụ Python (gồm mô hình CSI-2, MKV, tool DDR, HyperRAM)
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
| `camera` | ROM + `camera` | dò IMX219 qua I2C (PA7, TCA9546A, clock stretching); cửa sổ AXI4-Lite (đọc/ghi qua cầu, bus error khi `SLVERR`/timeout); mode 64×48, `cam` hiệu chỉnh eye (mọi tap tốt: `taps 248/248 eye 512/512`) rồi kiểm tra lề (`csi2rx: margin ok +-128/+-128 taps: 0 errors in 5 x 8 frames`), `csi` → `csi2rx: link ok`, 48 dòng, WC 80, `margin 0 2`; `cam` lại với tap đã hiệu chỉnh (link tốt: không hiệu chỉnh lại), rồi với một FE không có FS sau mỗi frame (lỗi FRAME: `link errors (ERR_STATUS 100), not a sampling problem: taps kept`); sọc màu của cảm biến → bộ thu CSI-2 → ISP → capture → ảnh RGB qua UART (CRC + kiểm tra màu từng sọc), AE và AWB hội tụ, flip (BGGR), TPG của ISP ở YUV; cuối cùng cảm biến nhận thanh ghi nhưng không gửi gì: `cam` → `no link error: calibrating`, `calibration failed`, `error`, rồi `cam` chạy lại bình thường |
| `h264` | ROM + `video` | `dmatest` (DMA kênh 1: SRAM → VRAM → SRAM, lỗi bus ở địa chỉ không ánh xạ); mode 64×48, TPG sọc màu → ISP (YUV) → bộ mã hoá H.264 → DMA kênh 0 → VRAM; `rec 3` rồi `send`: stream qua UART (CRC), lưu `build/sim/h264.hex`; rồi rate control (`bow_h264_rc_*`): TPG ô bàn cờ, `qp auto` (QP đầu theo kích thước frame: 34, mô hình (số pixel)^0,6 của `bow_h264_rc_init()`), `rec 8 3 1` (8 frame, 1 KiB mỗi frame, bỏ 3 frame giữa hai frame mã hoá vì TPG chạy ~4000 fps): đủ 8 dòng `frame k: n bytes, QP q`, QP đổi theo hướng của sai số kích thước, nửa sau trong −50…+25 % đích, `send` → `build/sim/h264_rc.hex` (sau mô phỏng giải mã đủ 8 frame, in QP của từng frame: so được với dòng `frame k` của firmware); sau mô phỏng `h264_model.py decode --bars` giải mã ra 3 frame 64×48 có đủ 8 sọc màu |
| `mkv` | ROM + `mkv` | tự kiểm tra lúc khởi động của driver (`mkv: power-on self-test PASS`: KAT 6 phiên bản, 3 lệnh `TEST`), rồi `test quick` → `mkv: PASS (19/19)`: MKV phần mềm và IP (mỗi lệnh làm hai lần và đối chiếu) khớp 6 véc tơ của Phụ lục A (cả khoá vòng), IP ↔ phần mềm trên khoá/khối ngẫu nhiên, ECB (ghi `DIN` khi IP đang chạy), lệnh lỗi, `KEY_VALID`, `CLEAR`, ngắt `irq_fast[10]` (`mip`), stall bus, xoá khoá / `DOUT`, lỗi bus, `NOSTALL`, chính sách `NO_ENC`/`NO_DEC`, `TEST` cho `FAULT`, DMA không tới được thanh ghi MKV, không `FAULT` nào ngoài các `TEST`; rồi `key`/`enc`/`dec` qua shell phải ra đúng giá trị của `mkv_model.py`; một dòng `FAIL`/`error` dừng mô phỏng ngay (~13,9 M chu kỳ) |
| `ddr` | ROM + `ddr` | `test quick` → `ddr: PASS (18/18)`: khởi tạo JEDEC DDR2 bằng chuỗi sinh từ LiteDRAM (qua DFII), hiệu chỉnh đọc (quét pha của mô hình MMCM, chụp thô, mắt, `RD_DLY`/`RD_SLIP`), bàn giao cho controller, cửa sổ CPU (walking 1/0, đường địa chỉ, đọc-sửa-ghi byte/halfword, xorshift), BIST của LiteDRAM và dữ liệu đọc qua cửa sổ = bản C của bộ sinh dữ liệu, refresh, giới hạn pha, ngắt `irq_fast[11]`; rồi `wr`/`rd` qua shell ở đầu và cuối 4 MiB; cuối cùng DRAM giả lập không được thấy vi phạm JEDEC nào (`DBG`). Một dòng `FAIL`/`error`/`[trap]` dừng mô phỏng ngay (~4,9 M chu kỳ, ~1 phút) |
| `hyperram` | ROM + `hyperram` | `test quick` → `hyperram: PASS (19/19)`: IP có mặt, lệnh bị từ chối đúng luật, khởi tạo (RESET#, quét pha đọc của mô hình MMCM với chụp thô ID0, `RD_DLY`, CR0/CR1, mắt của mẫu, mở cửa sổ), thanh ghi thiết bị, cửa sổ CPU (walking 1/0, đường địa chỉ, ghi byte/halfword bằng mặt nạ RWDS, xorshift với ghi posted và không posted), read buffer (word cần trước, trúng, ghi xuyên), `RANGE`, BIST PRBS/đếm và dữ liệu đọc qua cửa sổ = bản C, latency biến đổi (trùng refresh 2×), hybrid sleep, deep power down, giới hạn pha, ngắt `irq_fast[12]`; rồi `wr`/`rd` qua shell ở đầu và cuối 1 MiB; cuối cùng HyperRAM giả lập không được thấy vi phạm giao thức nào (`DBG`) (~7,4 M chu kỳ) |
| `csi2` | ROM + `csi2_test` | `test quick` → `csi2_test: PASS (12/12)` (eye mô hình: lane 0 tap 100…300, lane 1 180…400, tap reset 0 xấu; hiệu chỉnh phải ra ~208/288, kiểm tra lề `+-48/+-56 taps: 0 errors in 5`); rồi cài lỗi vào một frame đang chạy (lật 1 bit header → ECC sửa, lật 1 bit payload → CRC, byte sync sai trên lane 1 → SOT + skew) và `stat` phải in đúng `ecc 1/0 crc 1 trunc 0 sot 0/1 ovf 0`, `misc ≥ 1`, `extra 0`; rồi eye lane 0 thu về 100…240: `margin 0 4` phải báo `low` đúng ở điểm lane 0 +48 (tap 256), 4 điểm kia sạch, tap vẫn 208/288; rồi cùng việc đó với thời gian frame như cảm biến thật (LP-11 47,5 µs sau mỗi dòng, vertical blanking 555 µs: frame ~3 ms so với thời gian chờ một tap 4 ms, như 1080p30 so với 42 ms) và eye lane 0 bắt đầu ở 170: điểm thứ hai lane 0 −48 (tap 160) lỗi và có thể làm mất FS của frame đang chạy, các điểm sau vẫn phải đo đủ 4 frame; eye trả lại: `margin` ok, `stat` → `link ok`. Một dòng `[FAIL]` (hay `error`, trừ lần `margin` được chờ thất bại) dừng mô phỏng ngay (~9,3 M chu kỳ) |
| `camera274` | ROM + `camera`, bản IMX274 | dò IMX274 (reset bằng XCLR = PA7, chữ ký giá trị mặc định với VMAX 0x906 như cảm biến trên bo, I2C 100 kHz); `simfast on`; `sr 3004` → `03`; `mode 64 48 0` → ghi chú "simulation only" và `(HMAX 260 VMAX 139)`, 1992 fps; `tp 11`, rồi `wb 280 230`, `ae 1000`, `awb on` (AE với đích mà sọc màu không đạt được); PHY chưa sẵn sàng: `csi` → `PHY not ready` (cả 4 lane được liệt kê dù bộ thu tắt), `cam` → `error: D-PHY not ready` sau 10 ms; `PHY_RDY` lên 1 ms sau lệnh `cam` kế tiếp; `cam` đầu luôn hiệu chỉnh (trên bo trễ BISC ở mép sớm của eye), ở đây lane 0 tạm không có eye: `calibration failed`, `error`, các lane nạp lại trễ BISC; eye trở lại, `margin 0 2` khi chưa hiệu chỉnh đo quanh trễ đang dùng (`csi2rx: not calibrated: margin around the delays in use 97/112/88/120 ...`, `margin centre taps 97/112/88/120`, k = 40, không bao giờ tap 0); `cam` lại thì hiệu chỉnh (đi từng lane từ trễ đang dùng: `taps 112/128/88/144 eye 144/144/128/144`, `csi2rx: margin ok +-40/+-40/+-40/+-40 taps: 0 errors in 9 x 8 frames`), `streaming 64x48 RGGB`; `cal` cho cùng kết quả; `stat` (ISP ra 64×48), `csi` → `link ok`, 48 dòng, WC 80, không lỗi; sọc màu của cảm biến → bộ thu → ISP → ảnh 64×4 qua UART (kiểm từng sọc), RGGB cả sau `flip 0 1` (mô hình giữ pha màu khi lật, như cảm biến trên bo; ISP `BAYER` vẫn 0; ghi dưới REGHOLD: không frame nào lẫn nửa cũ nửa mới); `flip 1 0` bị từ chối; trong suốt lúc test pattern bật AE/AWB không chạy: không lần ghi SHR / PGC nào khi stream test pattern, `info` vẫn `ae on (target 1000)  awb on (r 280 b 230)`; `tp 0`, `ae 180`, `awb on`: AE (SHR) và AWB khoá trên cảnh; cửa sổ 1920×8 (mode 3, HMAX 384: burst 2400 byte ở 720 MB/s vào FIFO bộ thu, ISP 1 pixel/clock) → ISP ra 1920×8, `csi` không lỗi, không tràn; `tpg 0` dừng đúng thứ tự (bộ thu tắt trước khi cảm biến vào standby). Lane clock ở HS suốt frame, timing điển hình; `cam` đặt PA5 = 1 (`BurstRxRst`): FIFO của PHY tối đa 3 word, không quay vòng (biến thể `camera274 brst0` của `test-extra`: mô hình ép 0, trôi tới 8 word, quay vòng 5 lần mỗi lane). ~20,7 M chu kỳ, ~8 phút |
| `video274` | ROM + `video`, bản IMX274 | dò IMX274 (mô hình với VMAX sau reset 0x905 của datasheet: driver nhận cả 0x905 và 0x906), encoder và DMA; AE/AWB để bật (mặc định), `ae 1000` (đích mà sọc màu không đạt được), `tp 11`, `qp 26`: khi test pattern bật AE/AWB không chạy, không lần ghi SHR / PGC nào (nếu chạy, cứ 3 frame AE ghi cảm biến ở I2C 100 kHz, đủ lâu để mất byte của lệnh gõ vào FIFO UART 16 byte); `mode 64 48 2000` → `(HMAX 260 VMAX 139)`, `cam` với chuỗi thoát standby thật (app `video` không có `simfast`: chờ 11 + 8 ms) và hiệu chỉnh ở lần đầu (mọi lane được nạp tap), `rec 3`, `send` → stream qua UART (CRC) → `build/sim/h264_274a.hex`; rồi `mode 1920 32 900` (stream chạy lại) → `(HMAX 672 VMAX 119)`: dòng dài mà app đặt cho bộ mã (0,35 · W), `rec 3`, `send` → `h264_274b.hex`; mỗi lần mô hình IMX274 phải chốt đúng kích thước, HMAX, VMAX app báo, `stat` phải có `record 3 frames`, và tải bộ mã tính từ chu kỳ engine đo được (392 chu kỳ mỗi macroblock) ≤ 100 % (6 % rồi 78 %); không có dòng `warning` (bộ mã bỏ pixel) hay `error`; `stop` (bộ thu tắt trước khi cảm biến vào standby). Sau mô phỏng `h264_model.py decode --bars` giải mã cả hai stream ra 3 frame có đủ 8 sọc màu. Lane clock ở HS suốt frame, timing D-PHY corner 2, `BurstRxRst` = 1 (PA5 của firmware): FIFO của PHY tối đa 3 word, không quay vòng. ~13,9 M chu kỳ, ~5 phút |
| `csi2_274` | ROM + `csi2_test`, bản IMX274 | `simfast on`; núm của PHY: `phy` (PHY_RDY, PB6/PB7 = 1, knob 0, trễ BISC 97/112/88/120), `phy reinit` (một xung PA4: `PHY_RDY` về 0 rồi lên lại ~40 µs sau, trễ BISC trở lại); `test quick` → `csi2_test: PASS (11/11)` (phy-idle phải thấy LP-00: IMX274 ở standby; trễ BISC của lane 2 nằm ngoài eye nên firmware quét chung trước rồi đi từng lane, hiệu chỉnh phải ra ~192/224/272/256 eye 288/288/256/288; `margin` trên 4 lane với mẫu AAAh: `+-72/+-72/+-64/+-72 taps: 0 errors in 9`; integrity với 555h/AAAh; packets FS, 1 dòng embedded, 4 dòng OB, 48 dòng, FE; 3 lần dừng/chạy lại với chuỗi thoát standby); sau đó PA5 = 1 và `rd 4000800c` → `051e0213` (SETTLE 95 ns): firmware đặt cả hai mỗi lần khởi động bộ thu (`FW=brst0`: PA5 = 0, `051e0217` = 115 ns); `delay 2 240` rồi `margin 32 1`: tâm là tap đang dùng của cả 4 lane (lane 2 ở 240, điểm 208 / 272), lane 2 không bị đặt lại về tap đã hiệu chỉnh (`stat`: `delay …/…/240/…`); rồi cài lỗi như `csi2` (byte sync sai trên lane 1 trong 4 lane) và `stat` phải in `ecc 1/0 crc 1 trunc 0 sot 0/1/0/0 ovf 0`, `misc ≥ 1`, `extra 0`; `raw` 4 lane; `mode 1920 8 0` (stream chạy lại), `stop`, `stat` khi bộ thu tắt vẫn có 4 lane (`sot 0/0/0/0`, `d3`, 4 trễ); link check của `start` qua 16 frame nguyên: một lỗi CRC ở frame 6 (`s274_crc_frame`, sau 64 packet đầu: 19 packet mỗi frame 1920×8) → `link check failed (ERR_STATUS 008), try cal` và hai dòng gợi ý (`errors in frame k of 16 at the delays in use …`; k = 5 hoặc 6: với frame 357 µs frame đầu có thể bắt đầu trước khi link check xoá bộ đếm, trong lúc ghi I2C sau master start), rồi `start` sạch → `link check ok` chỉ sau ≥ 16 frame; `irq`, `stat` không lỗi. Lane clock vào HS ở mỗi burst, timing D-PHY ở biên của chuẩn với HS-PREPARE dài nhất (corner 1), `BurstRxRst` = 1 (PA5 của firmware): FIFO của PHY bắt đầu lại mỗi burst, ~2000 byte clock không có word (tối đa một mỗi burst, `v_gap_pm` 2). ~23,3 M chu kỳ, ~7,5 phút |

Một test PASS khi in `TEST PASSED` (`h264`, `video274`: và stream H.264 giải mã đúng sau
mô phỏng); lỗi dùng `$fatal` (mã thoát ≠ 0). Có watchdog `+TIMEOUT=<cycles>` (mặc định
20 M chu kỳ, `camera` 30 M, 40 M ở bản IMX274; `csi2` cần ~9,4 M, `camera` ~15,5 M vì
link check không có dữ liệu chờ 2,4 frame của cấu hình cảm biến, `h264` ~8,2 M, `camera274`
~20,7 M, `csi2_274` ~23,3 M, `video274` ~13,9 M).
`camera`, `csi2`, `camera274`, `csi2_274` và `video274` kết thúc bằng một kiểm tra
PHY: cổng byte clock chỉ mở và đóng khi lane clock đứng yên ở HS-0, không có xung runt.
`make test` chạy mọi test kể cả sau một test hỏng, in `PASS`/`FAIL` và thời gian của mỗi
test, cuối cùng một dòng tổng kết (`make test: FAILED: ...` và mã thoát 1 nếu có test
hỏng); cả 15 test ~34 phút (2043 s, chưa tính dựng hai mô hình; 2026-11-10, sau khi gộp
PR #17).

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

### Mô hình IMX274 và PHY Versal (bản `Imx274 = 1`)

Cảm biến IMX274 (`s274_*`, `f274_*` trong testbench), theo bảng thanh ghi của datasheet
(thanh ghi nhiều byte: LSB ở địa chỉ thấp):

- I2C 7 bit 0x1A, chỉ số 16 bit (MSB trước), dữ liệu tự tăng địa chỉ khi ghi và đọc; chỉ trả
  lời khi XCLR (PA7 lái 1) đã lên ≥ 20 µs (truy cập sớm hơn là lỗi). XCLR = 0 đưa mọi thanh
  ghi về mặc định, trong đó có chữ ký mà driver dò: MDSEL1..4 = 03 31 00 09, HMAX 0x0104,
  VMAX 0x00906 (giá trị đọc được trên bo Huins; `video274` dùng 0x00905 của datasheet,
  `+S274_VMAX_RST=<hex>`), BLKLEVEL 0x32 (đọc/ghi được).
- Chuỗi thoát standby được kiểm tra: bước 1 `0x3000 = 0x12`, PLRD1..5, `0x310B = 0` (PLL
  chạy); bước 2 `0x3000 = 0` ≥ 10 ms sau khi PLL chạy; bước 3 `0x30F4 = 0` (XMSTA) ≥ 7 ms sau
  bước 2 thì bắt đầu stream, lúc đó PLRD phải là bộ INCK 24 MHz và `SYS_MODE (0x303E) = 2`.
  `simfast on` làm driver chia các khoảng chờ cho 64, testbench chia ngưỡng tương ứng (testbench
  gửi lệnh này nên biết). `0x3000` bit 0 = 1 (STANDBY) dừng stream ngay (frame đang dở bị cắt,
  không có FE); lần chạy sau phải lặp lại bước 1. Dừng stream (standby hoặc reset) khi bộ thu
  CSI-2 còn bật là lỗi: lane rơi xuống LP-00, bộ thu tính là lỗi LP — driver tắt bộ thu trước.
- Lane: LP-00 khi reset và standby (cả trong bước 1), LP-11 từ bước 2 và giữa các burst.
- Mỗi đầu frame cảm biến chốt định dạng và kiểm: mode đọc 1/3/5 (MDSEL1..3, kèm VCUTMODE,
  MDSEL5, MDPLS17, PSMOVEN và MDSEL4 có/không cắt dọc), HTRIMMING (bội của bước 12 hoặc 24,
  END ≤ 3864, rộng ≥ 144, chia hết cho hệ số binning; chiều rộng = (END − START) / binning, bội
  của 4), cắt dọc VWIDCUT/VWINPOS (bù hai, âm khi lật dọc, nằm trong số dòng hiệu dụng của mode),
  WRITE_VSIZE = Y_OUT_SIZE + số dòng OB (4 ở mode 5, 8 ở mode 1 và 3), HMAX ≥ mức tối thiểu,
  VMAX ≥ 2 × (1 + WRITE_VSIZE) + 13, SHR trong [SHR_min, VMAX − 4], SVR = 0, PGC ≤ 1957,
  DGAIN ≤ 6, thanh ghi test pattern. Sai lúc bắt đầu stream là lỗi. Trong lúc stream, đầu
  frame rơi giữa hai lần ghi I2C của driver (ví dụ VWINPOS đã đổi dấu mà MDVREV chưa) thì
  frame đó không được xuất (in ra và đếm), và chỉ được phép trong một cửa sổ quanh lệnh
  `mode` của test (lúc chờ câu trả lời và 2 đầu frame sau); ngoài cửa sổ đó là lỗi. Driver
  dựng lại stream cho mode mới và ghi lật dưới REGHOLD, nên không frame nào như vậy được
  chờ đợi, và lệnh lật không có cửa sổ. REGHOLD = 1 ở đầu frame giữ định dạng cũ (các thanh
  ghi đã ghi có hiệu lực cùng lúc ở đầu frame sau khi xoá REGHOLD); SHR có hiệu lực chậm hơn
  các thanh ghi khác một frame. Đổi mode đọc, cắt dọc hoặc lật là chuyển mode: một frame
  không xuất; frame đầu tiên sau khi bắt đầu cũng không xuất.
- Thời gian thật theo HMAX/VMAX (72 MHz): mỗi packet một HS burst, VC 0; FS (số frame 1, 2,
  …), rồi mỗi dòng CSI-2 một khe 2 HMAX, khe đầu bắt đầu 1 HMAX sau FS: 1 dòng embedded (DT
  0x12, dài như dòng ảnh, đóng gói kiểu RAW10), các dòng OB (DT 0x37, giá trị BLKLEVEL), Y_OUT_SIZE
  dòng RAW10 (DT 0x2B); FE ngay sau dòng cuối; FS sau cách FS trước HMAX × VMAX. Lane clock ở
  HS từ FS tới FE (`camera274`, `video274`, như IMX219) hoặc vào HS ở mỗi burst (`csi2_274`).
- Pixel: Bayer RGGB; lật dọc đảo thứ tự các cặp dòng và giữ pha màu (vẫn RGGB, như cảm biến
  trên bo Huins ngày 2026-11-10; trước đó mô hình đảo từng dòng, ra GBRG như driver đoán sai).
  Test pattern (`0x303C = 0x11`, mẫu = `0x303D` + 1 theo menu của driver Linux, giá trị 12 bit
  dịch phải 2, không cộng BLKLEVEL): 1..4 đặc 000h/FFFh/555h/AAAh, 5..10 sọc 2 cột, 11 tám sọc
  màu dọc (trắng vàng lục lam lục đỏ tươi đỏ lam đen, như mô hình IMX219), 12 tám sọc ngang;
  tắt: cảnh mịn theo exposure (VMAX − SHR) × PGC × DGAIN, ám màu (R 5/8, B 13/16), cộng BLKLEVEL.
  Giá trị thật của các mẫu trên IMX274 chưa ai đo: mô hình chỉ cần khớp với cách firmware kiểm
  (`csi2_test` đo tổng pixel của 555h/AAAh, đếm màu của sọc).

PHY Versal (`csi2_tx_model`, `versal = 1`): `PHY_RDY` lên 40 µs sau lúc bắt đầu (`camera274`:
khi test cho phép) và 40 µs sau một lần khởi động lại (PA4), trễ BISC 97/112/88/120, nạp tap ở
clock video, FIFO RX 8 word mỗi lane với `rx_valid` như XPHY: ghi mỗi cạnh strobe khi bộ thu HS
của lane clock bật, đọc khi FIFO có hơn `vlat` word (0–2, chung cho mọi lane), nên word cũ của
burst trước ra trước ở burst sau và trễ không bao giờ giảm. `BurstRxRst` theo PA5 (0 sau reset
như bản camera, 1 từ lần đầu firmware khởi động bộ thu): với 0, 20 % lần mở cổng byte clock thêm một word glitch vào mọi FIFO
(`+S274_GLITCH`), trễ trôi lên tới 8 word rồi FIFO quay vòng (bộ đọc nhảy qua 8 word cũ); với 1,
FIFO bị giữ reset khi cổng đóng và mỗi burst bắt đầu lại. Chu kỳ không đọc (`csi2_274`) chỉ khi
mọi FIFO ở trễ tối thiểu. Eye của 4 lane theo test (mục "IMX274 tests" trong testbench). Cuối
mỗi test IMX274 testbench kiểm: frame được gửi đúng khe, hợp đồng nạp tap (xung 1 chu kỳ, tap ổn
định quanh lần nạp, không nạp khi lần trước còn chờ, lane nào cũng được nạp khi test hiệu chỉnh),
cổng byte clock; nó in số word glitch, lần quay vòng và trễ lớn nhất của FIFO (mất dữ liệu thật
sẽ hiện ra ở bộ đếm lỗi). Clock video 5 ns: `INFO` báo 200 MHz, driver đặt `PHY_CFG` = 19/30/5 chu
kỳ (SETTLE 95 ns vì `INFO.DLY_VID = 1`, CLK_SETTLE, CLK_MISS).

Timing D-PHY: `camera274` dùng giá trị điển hình của `csi2_tx_model` (HS-PREPARE 60 ns,
HS-ZERO ≥ 150 ns…), `csi2_274` biên của chuẩn với HS-PREPARE dài nhất (`+DPHY_CORNER=1`),
`video274` với HS-PREPARE ngắn nhất và byte sync sớm nhất (`+DPHY_CORNER=2`). Mô phỏng này đã cho
thấy `SETTLE` 70 ns không đủ cho PHY Versal: cửa sổ dò sync, lùi theo trễ FIFO, bắt đầu trong
HS-PREPARE dài và thỉnh thoảng khớp sync giả (lỗi giả làm lệch kết quả hiệu chỉnh); driver dùng
95 ns khi `INFO.DLY_VID = 1` (docs/ip/csi2rx.md). 95 ns giả định trễ FIFO tới ~4 word: với FIFO
trôi tới 8 word (`BurstRxRst` = 0 có glitch) cửa sổ lại vào HS-PREPARE dài nhất, `csi2_274` mất
dòng (integrity) và hiệu chỉnh lệch. Vì vậy trên bản Versal (`INFO.DLY_VID` = 1) firmware đặt PA5
= 1 (`BurstRxRst`) mỗi lần khởi động bộ thu và giữ `SETTLE` 95 ns (`cam_rx_start()`,
`sw/common/src/cam_sensor.c`); `csi2_274` kiểm cả hai sau `test quick` (`+S274_BURSTRST=0` ép mô
hình về 0 để thấy lỗi ở corner 1). Cấu hình kia, `BurstRxRst` = 0 với `SETTLE` 115 ns, là bản
firmware `FW=brst0`: `csi2_test` build với `-DCAM_BURST_RST=0 -DSETTLE_VID_NS=115` vào
`build/sim/sw-brst0/` (`make -C sim run TEST=csi2_274 FW=brst0`, cũng trong `test-extra`;
testbench kiểm PA5 = 0 và SETTLE 115 ns). **Chỉ mô hình**: trên bo Huins (2026-11-10) PA5 = 0
hỏng hẳn sau lần bật lại bộ thu đầu tiên ở mọi `SETTLE`, còn PA5 = 1 sạch với `SETTLE` 65–170 ns
(rộng hơn ~80–116 ns mô phỏng dự đoán; [camera_huins.md](camera_huins.md) mục 6.3). Với `BurstRxRst` = 0, FIFO trôi và 95 ns,
`camera274` ở corner 0 vẫn sạch (biến thể `camera274 brst0`), `csi2_274` không glitch cũng vậy
(`csi2_274 noglitch`).

Lane clock vào HS ở mỗi burst (`csi2_274`): `BYTECLK` chỉ đo đúng burst dài hơn ~2 × 256 chu kỳ
CPU nên đọc thấp (~20–45 MHz với dòng 64 pixel, ~154 MHz với dòng 1920 pixel, thay vì
180 MHz). Nếu IMX274 thật cũng vậy, kiểm tra `timing` của `csi2_test` bản đầy đủ (180 MHz
± 3 %) sẽ báo lỗi giả; vì thế nó coi số đo là cận dưới khi lane clock vào HS hơn 2 lần mỗi
frame (`[PASS] timing ... (lower bound: clock lane gated per packet)`).

## Plusargs

| Plusarg | Ý nghĩa |
|---------|---------|
| `+TEST=<tên>` | chọn kịch bản (`camera274`, `csi2_274`, `video274`, `geo274`: chỉ bản IMX274) |
| `+ROM=<vmem>` | ảnh boot ROM (bắt buộc) |
| `+FLASH=<vmem>` | nạp sẵn flash (backdoor) |
| `+IMAGE=<vmem>` | ảnh tải qua UART trong test `load` |
| `+TIMEOUT=<n>` | giới hạn chu kỳ |
| `+S274_CONTCLK=<0\|1>` | bản IMX274: lane clock ở HS từ FS tới FE (1) hay vào HS ở mỗi burst (0); mặc định 1 trong `camera274` và `video274`, 0 trong `csi2_274` |
| `+DPHY_CORNER=<n>` | bản IMX274: timing D-PHY ở biên của chuẩn: 1 = HS-PREPARE dài nhất 88,9 ns, 2 = ngắn nhất 44,4 ns, cả hai với HS-PREPARE + HS-ZERO ngắn nhất 155,6 ns, T_LPX, HS-TRAIL, HS-EXIT, CLK-POST, CLK-TRAIL ngắn nhất, CLK-PREPARE dài nhất với CLK-PREPARE + CLK-ZERO = 300 ns; 0 = điển hình. Mặc định 1 trong `csi2_274`, 2 trong `video274`, 0 trong `camera274` |
| `+S274_BURSTRST=<0\|1>` | bản IMX274: `BurstRxRst` của mô hình PHY là 0 / 1 bất kể PA5 (mặc định: theo PA5, 0 sau reset, 1 từ lần đầu firmware khởi động bộ thu) |
| `+S274_PA5=<0\|1>`, `+S274_SETTLE=<ns>` | `csi2_274`: PA5 và `SETTLE` mà firmware phải đặt khi khởi động bộ thu (mặc định 1 và 95 ns; `FW=brst0`, chỉ mô hình, tự thêm 0 và 115) |
| `+S274_VMAX_RST=<hex>` | bản IMX274: VMAX sau reset của mô hình (mặc định `906`, giá trị của bo; `video274`: `905` của datasheet) |
| `+S274_GLITCH=<pct>` | bản IMX274: % lần mở cổng byte clock thêm một word glitch vào FIFO RX của mô hình PHY (mặc định 20) |
| `+S274_GEO=<mode>` | `geo274`: mode của `csi2_test` để bắt đầu stream (mặc định `1080p`) |
| `+WAVES` | ghi waveform (cần build với `WAVES=1`) |

`make run ... PLUSARGS="..."` thêm plusarg vào dòng lệnh (biến cũng đi qua `make` ở thư mục
gốc). `make -C sim test-extra` chạy các biến thể không có trong `make test` / CI, mỗi biến thể
log riêng `build/sim/<test>_<tên>.log`: `csi2_274` với corner 2, với lane clock liên tục, với
firmware `FW=brst0` (`BurstRxRst` = 0, `SETTLE` 115 ns, corner 1; chỉ mô hình, hỏng trên bo), với mô hình PHY ép
`BurstRxRst` = 0 mà không có word glitch; `camera274` với corner 1 và lane clock theo burst, và
với mô hình PHY ép `BurstRxRst` = 0 (FIFO trôi, corner 0); `video274` với corner 0 và lane clock
theo burst; `geo274` với `1080p` và `720p` (driver bắt đầu stream ở mode đầy đủ, mô hình IMX274
kiểm bộ thanh ghi lúc bắt đầu).

## Test riêng của IP

`make test-ip` chạy các test dưới đây (CI cũng vậy).

### ISP

`hw/ip/isp/dv/` so ISP với mô hình Python bit-exact (`tools/isp/isp_model.py`):
cấu hình và ảnh ngẫu nhiên theo seed, cả luồng camera và TPG, hai clock không
đồng bộ, đầu vào có khoảng trống ngẫu nhiên. So sánh từng pixel đầu ra, thống
kê, histogram và buffer capture.

```bash
make -C hw/ip/isp/dv test                       # seed 1..6, camera + TPG
make -C hw/ip/isp/dv run SEED=7 TPG=1 WIDTH=160 HEIGHT=90
```

### Bộ mã hoá H.264

`hw/ip/h264/dv/` so bộ mã hoá với mô hình bit-exact `tools/h264/h264_model.py`
(mô hình đã được đối chiếu với FFmpeg: giải mã stream của nó trùng từng pixel với
ảnh tái tạo). `h264_model.py gen` sinh case: kích thước (cả chiều cao không chia
hết 16), nhiều frame với QP từ 10 tới 51, SKIP, deblocking, ảnh cảnh / nhiễu /
gradient / phẳng (seed chia hết cho 3: frame đầu nhiễu ở QP 10 — nhiều hệ số,
level lớn, mã escape). `tb_bow_h264.sv` lập trình thanh ghi, phát các frame với
khoảng trống ngẫu nhiên trong dòng, đọc đầu ra với back-pressure ngẫu nhiên (2
clock lệch), ghi `out.hex` + `rec.txt` (các hàng tái tạo); `h264_model.py check`
so từng byte.

```bash
make -C hw/ip/h264/dv test                               # seed 1..8
make -C hw/ip/h264/dv run SEED=40 WIDTH=176 HEIGHT=136 FRAMES=2
```

Testbench in `MB_CYCLES` (số chu kỳ engine cho mỗi macroblock, hiện 392).

### Mã khối MKV

`hw/ip/mkv/dv/` so khối MKV với mô hình `tools/mkv/mkv_model.py`; bản thân mô
hình được kiểm tra với Phụ lục A của TCVN 14263:2024 (`mkv_model.py selftest`,
véc tơ chép từ bản chuẩn vào `tools/mkv/tcvn14263_vectors.json`) và, ở phiên bản
`DRAFT`, với mọi giá trị của Phụ lục A bản dự thảo (trích từ PDF bằng
`tools/mkv/extract_vectors.py`).
`mkv_model.py gen` sinh 6 véc tơ của chuẩn (mã hoá + giải mã) rồi khoá/khối ngẫu
nhiên cho cả 6 phiên bản. `tb_bow_mkv.sv` chạy chúng qua bus thanh ghi (ghi byte
enable, ghi `DIN` khi IP đang chạy, đọc `DOUT` bị giữ hay sau hỏi vòng) và ghi
`out.txt`, **trạng thái sau mỗi nửa vòng** (`trace.txt`) và **RAM khoá vòng**
sau mỗi lược đồ khoá (`rk.txt`); `mkv_model.py check` so tất cả. Cuối test là các
kiểm tra có hướng: `ERR`, `KEY_VALID`, `CLEAR`, ngắt, `CYCLES`, stall bus.

```bash
make -C hw/ip/mkv/dv test                    # seed 1..4 (514 phép toán, ~8 700 trạng thái)
make -C hw/ip/mkv/dv run SEED=99 COUNT=600   # 1 231 phép toán
```

### DDR2/DDR3

`hw/ip/ddr/dv/` mô phỏng toàn bộ `bow_ddr` (lõi LiteDRAM đã sinh, bộ chuyển DFI, PHY, hai
cầu bus, thanh ghi) với mô hình clock (CK, CK/4, 3 MMCM dịch pha), chân, level shifter và
DRAM. `tb_bow_ddr.sv` tự kiểm tra và chạy đúng luồng của firmware qua ba cổng bus: lên
link, truy cập cửa sổ khi chưa sẵn sàng (lỗi bus, ngắt), khởi tạo JEDEC từ
`hw/ip/ddr/litedram/generated/<lõi>/init.csv` qua cổng CSR, hiệu chỉnh đọc bằng chụp thô,
bàn giao, truy cập cửa sổ (kể cả đọc-sửa-ghi byte/halfword, ghi có mặt nạ với DDR3) so với
mô hình byte, BIST của LiteDRAM (0 lỗi, và phải báo lỗi khi so sai), ngân sách đọc (32 kịp,
33 → `RD_LATE`), `RANGE`, `CORE_RST` và bàn giao lại, timeout của hai cầu; cuối cùng DRAM
không được thấy vi phạm JEDEC nào.

BIST có bốn lượt: dữ liệu đếm, dữ liệu ngẫu nhiên, checker với dữ liệu khác (phải báo lỗi),
và dữ liệu cùng địa chỉ ngẫu nhiên (xung đột hàng trong bank machine); một bộ giám sát DFI báo
lỗi mọi RD/WR có A10 = 1 (lõi được sinh không có auto-precharge).

`tb_bow_ddr_rst.sv` (`make -C hw/ip/ddr/dv rst`, nằm trong `test`) kiểm các góc reset và
miền clock: xung `CORE_RST` ngắn rồi truy cập ngay, kể cả đọc CSR ngay trong chu kỳ nhả (phải
bị từ chối tức thì, không chờ timeout); `CORE_RST` giữa lúc ghi byte qua cửa sổ (mọi burst
ghi tới PHY phải là word đã ghép, không bao giờ là 0); reset SoC giữa lúc bước pha ghi
(`PS_NOW`/`WPS_NOW` phải bằng pha thật của mô hình MMCM, giới hạn ±T/4 vẫn tính từ pha 0
thật); xoá `init_done` khi đang có truy cập cửa sổ (truy cập phải xong hoặc bị từ chối);
clock DDR ngừng khi MMCM vẫn lock (biến `freeze` của `ddr_clk_model`) → lỗi bus,
`BUS_TIMEOUT`, `BROKEN`.

```bash
make -C hw/ip/ddr/dv test                    # 4 cấu hình + rst, ~4 phút
make -C hw/ip/ddr/dv seeds CFG=card SEEDS="1 2 3"
make -C hw/ip/ddr/dv run CFG=lb SEED=3 WAVES=1
```

| Cấu hình | Nội dung |
|----------|----------|
| `lb` | bản loopback của MPS4: `bow_ddr_lb` 4 MiB sau loopback của wrapper chân, DDR2 x8, 133,33 MHz |
| `card` | bo RAM: DDR2 x8 sau level shifter TXV0108 (`ddr_board_model` + `ddr_mem_model`, kiểm tra JEDEC và thời gian ở chân); trễ của bo rút theo seed |
| `ddr3` | DDR3 x16 DLL-off nối thẳng (lõi `litedram_ddr3`, DM, RESET#), 125 MHz |
| `stub` | `bow_ddr_stub` (`DdrEn = 0`) |

### HyperRAM

`hw/ip/hyperram/dv/` mô phỏng toàn bộ `bow_hyperram` (cửa sổ, thanh ghi, controller, BIST, PHY)
với các mô hình **độc lập với RTL**: `hyperram_model.sv` (S80KS2562 mức chân viết từ datasheet:
CA, latency 1×/2×, mọi kiểu burst của bảng 11, mặt nạ RWDS, thanh ghi, DPD / hybrid sleep /
RESET#, thời gian đầu ra tCKD/tDSV/tOZ… rút theo seed và tự kiểm tra từng cạnh, 21 bộ đếm vi
phạm: tCSM, preamble, tranh chấp, tCSS, tIS/tIH, tRWR…), `hyperram_board_model.sv` (nối thẳng
hoặc bo RAM với ba TXV0108: trễ, lệch kênh, bật/tắt theo seed; đếm tranh chấp và đầu vào thả
nổi), `hyperram_clk_model.sv` và `bow_hyperram_io_sim.sv`. `tb_bow_hyperram.sv` lái IP qua cổng
thanh ghi và cửa sổ đúng như `bow_hyperram.c` (bật, RESET#, hiệu chỉnh đọc bằng chụp thô, CR0 /
CR1, mắt của mẫu, quét pha ghi trên bo RAM), rồi: truy cập cửa sổ ngẫu nhiên byte / halfword /
word với read buffer, line fill wrapped, ghi posted bật / tắt, so với mô hình byte **và** với bộ
nhớ của mô hình chip (byte 2n = byte A); BIST PRBS / đếm so với bản SV của bộ sinh; thanh ghi
thiết bị và bản sao CR0/CR1; hybrid sleep, deep power down; `RANGE`, `NOT_READY`, BIST bị từ chối
vì tCSM, lệnh hai bit; `FLUSH` rồi `WIN_IDLE` phải nghĩa là dữ liệu đã ở trong chip (24 lần thử
mỗi lượt). Cuối cùng mô hình chip không được thấy vi phạm nào, bo không có tranh chấp, `STATUS`
không có cờ lỗi.

```bash
make -C hw/ip/hyperram/dv test                    # lb card direct stub ozf, ~1,5 phút
make -C hw/ip/hyperram/dv seeds CFG=card SEEDS="1 2 3"
make -C hw/ip/hyperram/dv run CFG=card SEED=3 WAVES=1
make -C hw/ip/hyperram/dv rdhold SEEDS="1 8 13"   # RD_HOLD 1 / 0 cạnh nhau
make -C hw/ip/hyperram/dv model                   # tự kiểm tra các mô hình (không có RTL)
```

| Cấu hình | Nội dung |
|----------|----------|
| `lb` | bản loopback của MPS4: pad twin ở chế độ loopback + `bow_hyperram_dev` 1 MiB, 100 MHz, 672 bước pha; cả latency biến đổi (emulator cho 2× ở 3 trong mỗi 15 giao dịch) |
| `card` | bo RAM (TXV0108) + mô hình S80KS2562, 100 MHz, latency cố định 4, quét pha ghi |
| `direct` | nối thẳng + mô hình chip, 166,67 MHz, latency 6, cả latency biến đổi (trùng refresh) |
| `stub` | `bow_hyperram_stub` (`HrEn = 0`) |
| `ozf` | như `direct` nhưng chip có thể tắt DQ trước khi byte cuối ra (tOZ không có min): `RD_HOLD` = 1 phải giữ đọc đúng; `make rdhold` cho thấy với `RD_HOLD` = 0 hai seed (8, 13) mất hẳn mắt ID0, nên `make test` chạy `ozf` với seed 8 (`SEED_ozf`) bất kể `SEED`: `RD_HOLD` hỏng là ca này hỏng |

Testbench này đã tìm ra ba lỗi RTL (đã sửa): một burst BIST bị từ chối làm lượt chạy treo
`BIST_BUSY`; `WIN_IDLE` lên 1 khi khối ghi posted còn trong FIFO lệnh (nay controller trả lời
mọi khối và cửa sổ đếm chúng); `unique case` của thanh ghi lệnh vi phạm với mọi lần ghi nhiều
bit (chặn mô phỏng có assertion, `make run ... ASSERT=1`). Chạy được với Verilator 5.020 (bản
của CI) và xsim (`make xsim CFG=card`).

Mục 9b của testbench là các kiểm tra hồi quy cho từng bản sửa của hai vòng review PR #6: khối
ghi posted đang staged khi một REG_RD chờ sau nó (56 lần, ba cách khối rời bộ đệm), INVAL sau
BIST khi một line đang nạp, khối posted bị controller từ chối (`WR_ERR`, line bị bỏ), `CORE_RST`
khi một lần đọc đang chờ (`NOT_READY`), CMD trong reset kênh và ở chu kỳ đầu sau khi nhả (đúng
một trong `CMD_DONE` / `CMD_ERR`, `ERR_CODE` 5 giữ qua reset), `CORE_RST` giữa lúc hồi phục WAKE
(POWER vẫn về hoạt động, chip dùng được), `CMD_DONE` của WAKE chỉ sau hồi phục, `BIST_FADDR`,
`ERR_CODE` 7 của bước pha và `BIST_GO`, bản sao CR1 sau HW_RESET / DPD, và (chân) `CORE_RST` ở 40
điểm của một line fill không gây chồng lái DQ/RWDS. Mô hình chip đếm các pha CA bị cắt có chủ
đích ở đây (`ca_abort_ok`) thay vì báo lỗi; emulator không có móc đó nên lỗi 0E của nó chỉ được
miễn đúng số lần cắt trong các kiểm tra này. `make -C hw/ip/hyperram/dv mutants` (không nằm
trong `make test`, 18 bản dựng) gỡ từng bản sửa trong một bản sao RTL và chạy cấu hình liên
quan: cả 18 phải FAIL.

### Bộ thu CSI-2

`hw/ip/csi2rx/dv/` so bộ thu (`bow_mipi_rx`: `bow_dphy_rx` và controller `bow_csi2rx` nối
bằng PPI) với mô hình Python `tools/csi2/csi2_model.py`, được
viết từ đặc tả và quy tắc MIPI chứ không từ RTL. Mô hình sinh cấu hình và kích
thích (`cfg.txt`, `stim.txt`); `tb_bow_csi2rx.sv` chơi chúng qua
`csi2_tx_model.sv` với `tready` ngẫu nhiên, ghi pixel (`out.txt`) và thanh ghi
(`regs.txt`, mỗi FE một dòng `fe FRAME_INFO FRAME_SUM FRAME_ERR`); mô hình so
sánh pixel (`tuser[0]`/`tlast`/`tuser[1]`, cả khi FIFO tràn), bộ đếm,
FRAME/LINE_INFO, FRAME_SUM, `FRAME_ERR`, FRAME/LINE_TIME, LOG và các bất biến PHY.
`stim.txt` có thêm lệnh `wrbe A D BE` (ghi theo byte enable). Bench thứ hai (bước 3 của
[ip/mipi_rx_arch.md](ip/mipi_rx_arch.md) mục 10) chạy controller một mình ở PPI, cùng mô hình
(dưới).

```bash
make -C hw/ip/csi2rx/dv test                          # test-rx rồi test-ppi
make -C hw/ip/csi2rx/dv test-rx                       # cả bộ thu: 105 case, 1/2/4 lane, song song
make -C hw/ip/csi2rx/dv align                         # chỉ unit test của aligner
make -C hw/ip/csi2rx/dv test-rx SEEDS="1 2 3 4 5 6 7 8"
make -C hw/ip/csi2rx/dv run SEED=7 LANES=1 ERRORS=1   # thêm DUT_LANES=1|2|4 RAW8=1 CONTCLK=1
make -C hw/ip/csi2rx/dv run SEED=3 LANES=4 ERRORS=1 BURSTRST=1   # PHY Versal với BurstRxRst = 1
make -C hw/ip/csi2rx/dv run TEST=clk                  # một test directed
make -C hw/ip/csi2rx/dv test-ppi                      # controller ở PPI: 167 case, hai chế độ, song song
make -C hw/ip/csi2rx/dv test-ppi SEEDS="$(seq -s ' ' 1 40)" PJOBS=8
make -C hw/ip/csi2rx/dv run-ppi MODE=std TEST=loss LANES=4   # một case (MODE bow|std)
make -C hw/ip/csi2rx/dv mutants-ppi                   # 20 mutant phải làm bench PPI hỏng
```

- Unit test aligner (`tb_dphy_align.sv`, chạy đầu tiên trong `test`): word
  ISERDES của một burst đặt cửa sổ dò ở các mép mà test mức D-PHY không chạm
  tới: sync và deskew `FFFFh` ở mọi pha bit, 8 và 15 bit 1, sync hỏng
  `0xFC`/`0xFE`/`0xFF` + DI `0x2B`, `0xB9` + `00 FF FF`, 1–3 word nhiễu
  HS-PREPARE, cửa sổ ở word 0 cuối hay sau HS-zero; mỗi case đúng một kết quả
  (khoá, deskew, lỗi sync). Mọi case chạy 4 lượt: word mỗi chu kỳ, rồi có chu
  kỳ `rx_valid` = 0 (PHY có FIFO như XPHY của Versal: 1–2 chu kỳ trước 40 %
  word, lượt sau cả lúc `arm` lên, lượt cuối trước mọi word) với word rác `00`,
  `FF`, `B8` hay ngẫu nhiên: kết quả không được đổi (301 case).
- Bản build DV định nghĩa `BOW_CDC_JITTER`: mỗi `bow_cdc_pulse` ngẫu nhiên nhận
  toggle muộn một chu kỳ (như flop metastable), seed Verilator = seed của case.
- Random, mỗi seed 11 cấu hình: 2 lane có/không lỗi, 1 lane (`Lanes = 1`) có
  lỗi, 1 lane trên bộ thu 2 lane có/không lỗi; trên bộ thu 4 lane (PHY Versal):
  4 lane có/không lỗi với `BurstRxRst` = 0 và có lỗi với `BurstRxRst` = 1, 2 trên 4
  có/không lỗi, 1 trên 4 có lỗi; RAW8 và clock liên tục xen kẽ. Lỗi: lật bit header
  (1 và 2 bit), lật bit payload, sync sai, lệch lane, cắt packet.
- Directed: `lp` (escape, LP-00 từ Stop, độ trễ LP-00 → `hs_en`), `watchdog`,
  `clk` (CE chỉ đổi ở HS-0, mất clock), `cmd` (lệnh LOG/RAW khi byte clock
  dừng), `ovf` (tràn FIFO khi `tready` thấp: dòng Cut có `tlast` + `tuser[1]`,
  dòng Lost, frame có nhóm `sof` không ghi được bị bỏ, so từng pixel), `ovf2`
  (nhả `tready` giữa frame sau dòng Lost, dòng 1 nhóm gặp FIFO đầy, đuôi frame
  mất: `FRAME_ERR`), `ovf8` (RAW8, nhóm đầu 1 pixel: đầu ra giữ 3 nhóm), `stop`
  (dừng giữa burst rồi chạy lại), `byteclk`, `eye` (nạp và đọc lại tap, mô hình
  eye), `deskew` (burst skew calibration thật: burst thô `FFFFh` + `0101…`, không
  phải lỗi SOT, đếm ở `CNT_EXT[31:16]`, cả giữa các dòng; deskew chỉ trên một
  số lane là SKEW, liền nhau rồi riêng từng burst với `CNT_EXT` đọc sau nó; sync
  hỏng với `00 FF` trong pixel hay trail, `0xFC`/`0xFE`/`0xFF`
  trước DI, bit sync ngay trước cuối HS-zero vẫn là SOT), `extra` (byte sau packet trong cùng burst vượt
  `CTRL.EXTRA` → `ERR_STATUS.EXTRA`, `CNT_EXT[15:0]`: dòng + dòng, EMB + dòng,
  VC khác + dòng, FS + dòng thì frame bị bỏ, long packet nhỏ dưới ngưỡng,
  EXTRA = 0 tắt, 255 cần bão hoà 256), `loss` (burst mất trước unpack: dòng sau
  có `tuser[1]`, mất ở dòng đầu thì frame bị bỏ, mất ở dòng cuối chỉ thấy ở
  `FRAME_ERR`, mất giữa hai frame tính cho frame sau; dòng đầu không có nhóm
  pixel thì frame bị bỏ, dòng không có nhóm giữa frame đánh dấu dòng sau, ngoài
  frame thì không; vào HS bị từ chối ở mức LP trên data lane hay lane clock,
  với `CLK_FORCE` thì lane clock không tính, còn treo qua một burst deskew tới
  dòng sau; packet bị cắt không phải dòng; ECC_CORR của header FE thuộc frame nó
  kết thúc; lỗi CRC ở dòng mà word cuối có byte payload, 4 lane), `be` (ghi theo byte enable
  trên mọi thanh ghi). `cmd`, `stop`, `deskew`, `extra`, `ovf`, `ovf2`, `loss`,
  `be`, `eye` chạy thêm với 1 lane; `deskew`, `extra`, `ovf`, `ovf2`, `loss`,
  `eye` với 1 trên 2 lane; `be`, `eye`, `loss` với clock liên tục (2 và 4 lane).
  Trên bộ thu 4 lane mọi test directed đó, thêm `dly` (tap miền video, khởi động
  lại PHY) và `skew` (lệch lane ở biên của ghép lane: 6 byte clock nhận, 7 trở
  lên SKEW và không ra gì; cũng trên 2 lane); `cmd`, `stop`, `skew`, `dly`,
  `deskew`, `extra`, `ovf2`, `loss` với 2 trên 4. Số dòng của `ovf`, `ovf2`,
  `ovf8` theo `FifoDepth`; `extra` trên 4 lane đặt `CTRL.EXTRA` 196 (trail tới
  180 byte) như phần mềm.
- PHY Versal của bộ thu 4 lane: FIFO RX như XPHY, `BurstRxRst` = 0 (trễ trôi theo word
  glitch rồi quay vòng, như bản camera lúc khởi động) hoặc 1; xem [ip/csi2rx.md](ip/csi2rx.md)
  mục *Kiểm chứng*.
- Mỗi case giữ file trong `build/csi2rx_dv/<case>/` (`sim.log` cho CI, có dòng thống kê FIFO
  của PHY Versal); một binary Verilator cho mỗi giá trị `Lanes` (`build/csi2rx_dv/obj_l1`,
  `obj_l2`, `obj_l4`) và một cho aligner (`obj_align`). Sau unit test aligner, các case chạy song
  song `PJOBS` case (mặc định số CPU; `PJOBS=1`: lần lượt), mỗi case in dòng kết quả của nó: ~3 s
  với 24 job, ~26 s tuần tự. Mỗi bản build model chạy lại Verilator một lần nếu nó hỏng (Verilator
  5.020 đôi khi abort lúc thoát sau một bản build tốt) và `touch` binary.
- `make test-tools` chạy 41 unit test của mô hình (`tools/tests/test_csi2_model.py`).
- **Bench PPI** (`tb_csi2rx_ppi.sv`, `bow_ppi_bfm.sv`; `test-ppi`, bước CI riêng): controller
  `bow_csi2rx` một mình, PHY là BFM chơi phần dựng PPI của `csi2_model.py gen --ppi bow|std` (mỗi
  item TX của test case kèm byte mỗi lane mỗi burst với chu kỳ, `RxActiveHS`, `RxSyncHS`, khe,
  lỗi, lần chạy byte clock, xung lp; kỳ vọng vẫn từ item TX). Chế độ `bow`: thời gian của D-PHY
  Bow32 (`RxActiveHS` từ cuối SETTLE, khe như XPHY, `ErrSotSyncHS` cuối burst, lỗi lp và HS entry
  là xung `vid_clk_i`, dải phụ do BFM lái: `band_lane_en_lp` = `Enable` qua 2 flop); chế độ
  `std`: PHY chuẩn qua wrapper cổng phẳng `bow_csi2rx_ppi_flat` (`RxActiveHS` cùng `RxSyncHS`,
  không khe, `ErrSotSyncHS` sớm, lỗi dạng xung ở clock lp của PHY, không `PhyReady`). Một model
  Verilator cho mỗi `Lanes` (`build/csi2rx_dv/obj_ppi_l1`, `obj_ppi_l2`, `obj_ppi_l4`) chứa cả hai
  DUT, DUT không dùng không có clock. Các test của controller (random, `cmd`, `ovf`, `stop`,
  `skew`, `deskew`, `extra`, `loss`, `ovf2`, `ovf8`, `be`) cộng `clkstop` (byte clock dừng 4 cạnh
  sau khi `RxActiveHS` xuống, hay sớm hơn), `lpmask` (lỗi LP của lane đã tắt chỉ đếm, của lane
  đang bật đánh dấu burst mất; cạnh mặt nạ chỉ ở `bow`), `gaps` (chỉ `bow`, cả RAW có khe); case
  chạy song song như `test-rx` (`PJOBS`), mỗi case giữ file trong
  `build/csi2rx_dv/ppi_<MODE>_<case>/`, `sim.log` có dòng phủ của BFM (số burst theo số cạnh byte
  clock sau khi `RxActiveHS` xuống, khe, `ErrSotSyncHS` cuối / sớm, xung lp, cạnh mặt nạ, chu kỳ
  không có word RAW...). Bench PPI không nhanh hơn bench cả bộ thu trên cùng case (thời gian nằm
  ở mô hình Python). Chi tiết: [ip/csi2rx.md](ip/csi2rx.md) mục *Kiểm chứng*,
  [ip/mipi_rx_arch.md](ip/mipi_rx_arch.md) mục 5.5.

### D-PHY I/O trên FPGA (xsim)

`hw/fpga/common/dv/` mô phỏng `bow_dphy_io_xusp` + `bow_mipi_rx` với model
unisim của Vivado (`IBUFDS_DPHY`, `IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`). Máy
phát trong testbench lái chân P/N từng bit ở 912 Mbit/s: clock không liên tục,
HS-ZERO dài ngẫu nhiên (pha bit của byte sync), lệch nhỏ giữa hai lane (trừ frame
4/5, xem dưới); mức LP
lái mạnh, mức HS lái yếu (model `IBUFDS_DPHY` dựa vào đó để phân biệt LP và HS).

```bash
source <Vivado>/settings64.sh
make test-fpga-dv                              # = make -C hw/fpga/common/dv test (seed 1 2 3)
make -C hw/fpga/common/dv run SEED=5 WAVES=1   # waveform trong build/fpga_dv/seed5
```

Kiểm tra: word ISERDES chứa HS-zero + sync + đúng các byte đã gửi, clock /1 và
/4 không có xung runt và thẳng pha qua các lần gate, CE chỉ đổi khi lane clock ở
HS-0, `RST` của ISERDES nhả mỗi burst ≥ 20 byte clock trước sync, ghi `DLY` →
CNTVALUEOUT ở burst sau, pixel và thanh ghi của bộ thu với `PHY_CFG`/`CTRL.EXTRA`
của driver; một burst skew calibration (HS-zero, `FFFFh`, `0101…`) là deskew,
không phải lỗi SOT; frame với T_HS-TRAIL = T_EOT max (không EXTRA), với
T_HS-PREPARE min, và max (nhiễu tới 85 ns + 6 UI, kết thúc bằng `00 B8` giả),
cả hai với T_HS-PREPARE + T_HS-ZERO đúng tối thiểu trên mọi lane (pha bit ngẫu
nhiên qua T_CLK-PRE): bộ thu bỏ qua nhiễu và vẫn thấy mọi sync. White box: ở chu
kỳ đầu của mỗi lần dò, word cũ nhất của cửa sổ aligner phải là HS-zero (cửa sổ
bắt đầu sau nhiễu và trước sync); `00 B8` giả một mình chỉ thấy cửa sổ lấn ≥ 16
UI vào nhiễu. Probe này (`tb_dphy_align_probe`) được gắn vào mọi `bow_dphy_align`
bằng `bind`, nên không phụ thuộc chỗ đặt aligner trong phân cấp (hôm nay
`u_rx.u_dphy_rx.g_align[l].u_align`); test kiểm có đúng một probe mỗi lane và mỗi
probe thấy một lần dò mỗi burst. `+SETTLE=<n>` thay SETTLE của driver để quét: 20…28 đạt ở mọi seed,
19 ở một nửa, ≤ 18 cửa sổ bắt đầu trong nhiễu (≤ 15 còn khoá vào sync giả), ≥ 29
lỡ sync thật; driver dùng 22 (mô hình không có trễ ~8 ns của bộ thu LP, trên
thiết bị cửa sổ muộn hơn ~1,6 chu kỳ). Hai lần chạy xsim song song không được
dùng chung một snapshot (`xsim.dir`): plusarg và seed lẫn nhau. Cần Vivado nên không
chạy trong CI; pass/fail lấy từ dòng `tb_bow_dphy_io_xusp: PASS` (mã thoát của
xsim không phản ánh kết quả). Eye không mô phỏng được: unisim không có lệch
clock/data.

Bản Versal (`bow_dphy_io_versal`, XPHY với model secureip của AMD) có testbench riêng
`tb_bow_dphy_io_versal.sv`: 24 cấu hình trên 3 sơ đồ nibble tổng hợp, gồm cả hai núm lúc chạy
(`burst_rst_en_i`, `reinit_i`), trong `make test-fpga-dv`; một mình:
`make -C hw/fpga/common/dv test-dphy-versal`, một cấu hình:
`make -C hw/fpga/common/dv run-dphy-versal DPHYV_CFG=reinit_idle WAVES=1`. Mô tả:
[camera_huins.md](camera_huins.md) mục 9 và đầu `hw/fpga/common/dv/Makefile`.

### Chân và clock HyperRAM trên FPGA (xsim)

`tb_bow_hyperram_io_xilinx.sv` (cũng trong `hw/fpga/common/dv/`, nằm trong `make test`)
chạy `bow_hyperram_clk_xusp` (hai MMCME4_ADV với dịch pha tinh) và `bow_hyperram_io_xilinx`
(`ODDRE1`, `IDDRE1`, `IOBUF`, flop T) bằng model unisim, T = 10 ns, cấu hình `card` (chân
level shifter), `direct` và `lb` (loopback của bản MPS4), mỗi cấu hình seed 1 2 3. Thanh ghi
PHY ngẫu nhiên mỗi chu kỳ (trễ tới ODDR rút trong [T/4, T/2]); kiểm tra: mọi chân ra ở đầu,
giữa, cuối cửa sổ của hợp đồng chân (`bow_hyperram_pkg`) và pha của mọi cạnh (CK_N luôn là bù
của CK_P; CS#, RESET#, OE#/DIR = giá trị của chu kỳ PHY j trong chu kỳ chân j + 1; byte A/B
của DQ/RWDS và trạng thái lái), mức nghỉ trước clock, trong GSR và trước lock (SRVAL), bắt
mẫu đọc khi testbench lái DQ/RWDS và pha đọc đang dịch, dữ liệu tự lái đọc lại qua IOBUF/IDDR,
pha ghi +T/4, −T/4, +17 bước rồi về 0 (DQ/RWDS dịch, CK/CS# không), `hr_wclk` = `hr_clk` +
T/4 lúc lock, PSDONE, độ rộng xung khi dịch pha, reset và mất lock của từng MMCM đưa cả hai
pha về 0. `make -C hw/fpga/common/dv mutants` chạy thêm các bản hỏng có chủ đích của các wrapper
chân và clock DDR / HyperRAM (đảo ODDR, đổi byte, cực tính T, SRVAL, thứ tự chân level shifter,
mux loopback, chế độ IDDR, pha 270°, cổng PS, logic mất lock, ODDR lái T của Versal…): cả 117
(27 của DDR, 47 của HyperRAM, 43 của hai wrapper clock Versal) phải FAIL (mỗi bản dựng trong
thư mục sạch; một bản không dựng được tính là lỗi của chính `mutants.py`, không phải "bị bắt").

Versal (bo Huins VP1902, `TFromOddr = 1`: T của chân hai chiều lấy từ một ODDRE1 trong site của
chân, model unisim `SIM_DEVICE "VERSAL_PREMIUM"`): cấu hình `vcard`, `vx16`, `vlb` của
`tb_bow_ddr_io_xilinx` và `vcard`, `vdirect`, `vlb` của `tb_bow_hyperram_io_xilinx` kiểm trạng
thái lái của DQ / DM / RWDS ở [(j+1,25)T, (j+2,25)T) + pha ghi, của DQS P và N (từng lane) ở
[(j+1)T, (j+2)T) + pha ghi, và pha của mọi cạnh bật/tắt driver; ở mọi cấu hình DQS_N được lái
đúng khi DQS_P được lái. `test-vclk` (trong `make test`) chạy `tb_bow_ddr_clk_versal` và
`tb_bow_hyperram_clk_versal` với model MMCME5, cấu hình `ddr200`, `ddr100`, `ddr200se`, `hr200`,
`hr100`: tần số và pha của mọi đầu ra (`wclk90` = `wclk` + T/4, `hr_wclk` = `hr_clk` + T/4, cạnh
lên của `ddr_sys_clk` trùng cạnh lên của `ddr_clk`), 768 / 1024 bước mỗi chu kỳ và quay vòng,
PSDONE 12–13 chu kỳ sau PSEN và xung PSDONE lặp lại mỗi 32 chu kỳ của model, `bow_mmcm_ps` bắt
đầu ở cả 32 độ lệch so với xung lặp, PSEN trước lock bị bỏ qua, reset và mất lock của từng MMCM
đưa hai pha về 0. Model MMCME5 bỏ một chu kỳ của clock bị dịch khi bộ đếm pha đi từ 0 xuống −1
(chỉ trong mô phỏng); testbench chấp nhận đúng xung đó.

```bash
make -C hw/fpga/common/dv test-hr-io                        # 6 cấu hình x seed 1 2 3
make -C hw/fpga/common/dv run-hr-io HR_IO_CFG=lb SEED=2 WAVES=1
make -C hw/fpga/common/dv run-ddr-io IO_CFG=vcard SEED=1    # bản Huins của chân DDR
```

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
   header của `csi2_tx_model.sv`). Bản IMX274: thanh ghi `s274_reg[]`, trạng thái
   `s274_run`/`s274_starts`/`s274_stops`, định dạng frame đang gửi `f274_*`, `s274_frames`;
   lệnh shell `send_cmd()` (trả về vị trí log để tìm câu trả lời), `check_cal274()`,
   `check_counters274()`, `check_s274_end()`.
3. Thêm tên test vào `TESTS` và biến `FLASH_<test>` trong `sim/Makefile` (test của bản
   IMX274: thêm cả vào `TESTS_IMX274`, và vào phép kiểm bản dựng ở đầu `initial` chính;
   stream H.264 cần giải mã sau mô phỏng: `H264_<test>`).

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
* Verilator 5.020, struct packed rộng hơn 64 bit: `if (q.size() != 0) s =
  q.pop_front(); else s = ...;` bị gộp thành biểu thức điều kiện và
  `pop_front()` chạy trước phép thử `size()` (phần tử cuối thành nhánh else).
  Tính điều kiện vào một biến trước (`csi2_tx_model`, process phát).
* Queue trong biến automatic giữ qua delay trong process `fork` bị hỏng: dùng
  buffer static.
* `$realtime` dùng bên trong một biểu thức bị cắt về đơn vị thời gian (ví dụ
  `longint'($realtime * 1000.0)` cho 8000 ở 8,772 ns): gán vào biến trước, hoặc
  dùng `csi2_now()` của `csi2_tx_pkg` (package có đơn vị 1 ps).
* Mô hình bit theo thời gian: tính bằng ps nguyên (`floor()` số thực ở biên bit
  làm lặp hoặc mất bit; `$rtoi(ns * 1000)` tràn 32 bit sau 2,1 ms).
* CI dùng Verilator 5.020 của Ubuntu 24.04; các test bộ thu CSI-2 được phát
  triển với 5.022.
* Verilator trước 5.022 (lỗi verilator/verilator#4806): delay `#` của một module
  bị inline tính theo đơn vị thời gian của module cha, còn `$realtime` vẫn theo
  đơn vị của chính nó. Mô hình có delay mà `timescale` khác testbench chứa nó cần
  `/* verilator no_inline_module */`. Ví dụ `ddr_clk_model` (1 ps) nằm dưới
  `tb_bow32` (1 ns): khi bị inline, clock DDR chạy giật cục, `CLK_OK` rớt và test
  `ddr` hỏng trong CI. Mô hình này còn tự kiểm tra thời điểm của mỗi cạnh CK.

## Lint

```bash
make lint     # verilator --lint-only -Wall trên toàn SoC (Ibex được miễn trừ)
```
