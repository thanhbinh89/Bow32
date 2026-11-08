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

```bash
make sw            # firmware: build/sw/
make test          # build mô hình + chạy mọi test
make run TEST=load # chạy một test, log ở build/sim/load.log
make run TEST=load WAVES=1   # + build/sim/waves.fst  (gtkwave build/sim/waves.fst)
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
| `camera` | ROM + `camera` | dò IMX219 qua I2C (PA7, TCA9546A, clock stretching); cửa sổ AXI4-Lite (đọc/ghi qua cầu, bus error khi `SLVERR`/timeout); mode 64×48, `cam` hiệu chỉnh eye (mọi tap tốt: `taps 248/248 eye 512/512`), `csi` → `csi2rx: link ok`, 48 dòng, WC 80; sọc màu của cảm biến → bộ thu CSI-2 → ISP → capture → ảnh RGB qua UART (CRC + kiểm tra màu từng sọc), AE và AWB hội tụ, flip (BGGR), TPG của ISP ở YUV |
| `h264` | ROM + `video` | `dmatest` (DMA kênh 1: SRAM → VRAM → SRAM, lỗi bus ở địa chỉ không ánh xạ); mode 64×48, TPG sọc màu → ISP (YUV) → bộ mã hoá H.264 → DMA kênh 0 → VRAM; `rec 3` rồi `send`: stream qua UART (CRC), lưu `build/sim/h264.hex`; sau mô phỏng `h264_model.py decode --bars` giải mã ra 3 frame 64×48 có đủ 8 sọc màu |
| `mkv` | ROM + `mkv` | tự kiểm tra lúc khởi động của driver (`mkv: power-on self-test PASS`: KAT 6 phiên bản, 3 lệnh `TEST`), rồi `test quick` → `mkv: PASS (19/19)`: MKV phần mềm và IP (mỗi lệnh làm hai lần và đối chiếu) khớp 6 véc tơ của Phụ lục A (cả khoá vòng), IP ↔ phần mềm trên khoá/khối ngẫu nhiên, ECB (ghi `DIN` khi IP đang chạy), lệnh lỗi, `KEY_VALID`, `CLEAR`, ngắt `irq_fast[10]` (`mip`), stall bus, xoá khoá / `DOUT`, lỗi bus, `NOSTALL`, chính sách `NO_ENC`/`NO_DEC`, `TEST` cho `FAULT`, DMA không tới được thanh ghi MKV, không `FAULT` nào ngoài các `TEST`; rồi `key`/`enc`/`dec` qua shell phải ra đúng giá trị của `mkv_model.py`; một dòng `FAIL`/`error` dừng mô phỏng ngay (~13,9 M chu kỳ) |
| `ddr` | ROM + `ddr` | `test quick` → `ddr: PASS (18/18)`: khởi tạo JEDEC DDR2 bằng chuỗi sinh từ LiteDRAM (qua DFII), hiệu chỉnh đọc (quét pha của mô hình MMCM, chụp thô, mắt, `RD_DLY`/`RD_SLIP`), bàn giao cho controller, cửa sổ CPU (walking 1/0, đường địa chỉ, đọc-sửa-ghi byte/halfword, xorshift), BIST của LiteDRAM và dữ liệu đọc qua cửa sổ = bản C của bộ sinh dữ liệu, refresh, giới hạn pha, ngắt `irq_fast[11]`; rồi `wr`/`rd` qua shell ở đầu và cuối 4 MiB; cuối cùng DRAM giả lập không được thấy vi phạm JEDEC nào (`DBG`). Một dòng `FAIL`/`error`/`[trap]` dừng mô phỏng ngay (~4,9 M chu kỳ, ~1 phút) |
| `hyperram` | ROM + `hyperram` | `test quick` → `hyperram: PASS (19/19)`: IP có mặt, lệnh bị từ chối đúng luật, khởi tạo (RESET#, quét pha đọc của mô hình MMCM với chụp thô ID0, `RD_DLY`, CR0/CR1, mắt của mẫu, mở cửa sổ), thanh ghi thiết bị, cửa sổ CPU (walking 1/0, đường địa chỉ, ghi byte/halfword bằng mặt nạ RWDS, xorshift với ghi posted và không posted), read buffer (word cần trước, trúng, ghi xuyên), `RANGE`, BIST PRBS/đếm và dữ liệu đọc qua cửa sổ = bản C, latency biến đổi (trùng refresh 2×), hybrid sleep, deep power down, giới hạn pha, ngắt `irq_fast[12]`; rồi `wr`/`rd` qua shell ở đầu và cuối 1 MiB; cuối cùng HyperRAM giả lập không được thấy vi phạm giao thức nào (`DBG`) (~7,4 M chu kỳ) |
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
pha về 0. `make -C hw/fpga/common/dv mutants` chạy thêm 42 bản hỏng có chủ đích của hai wrapper (đảo ODDR, đổi
byte, cực tính T, SRVAL, thứ tự chân level shifter, mux loopback, chế độ IDDR, pha 270°, cổng
PS, logic mất lock…): cả 42 phải FAIL (mỗi bản dựng trong thư mục sạch; một bản không dựng được
tính là lỗi của chính `mutants.py`, không phải "bị bắt").

```bash
make -C hw/fpga/common/dv test-hr-io                        # 3 cấu hình x seed 1 2 3, ~1 phút
make -C hw/fpga/common/dv run-hr-io HR_IO_CFG=lb SEED=2 WAVES=1
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
