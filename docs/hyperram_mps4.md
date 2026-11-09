# HyperRAM trên Arm MPS4: chạy thử `bow_hyperram`

Hướng dẫn build bitstream Bow32 có bộ điều khiển HyperRAM ([ip/hyperram.md](ip/hyperram.md))
cho bo Arm MPS4 (HBI0376B, Virtex UltraScale+ XCVU13P), nạp qua thẻ microSD của bộ điều khiển
bo (MCC), chạy ứng dụng `sw/apps/hyperram` và đối chiếu với mô hình trên PC. Cách nạp bitstream
và các cổng serial giống hệt bản DDR: [ddr_mps4.md](ddr_mps4.md) mục 2 và 3. Cùng một bitstream
có cả DDR và HyperRAM: đổi ứng dụng bằng `bow32_flash.py flash`, không cần build lại.

```
 PC: tools/bow32_hyperram.py ──USB-C, cổng serial 1──► Ibex (sw/apps/hyperram) ──bus──► bow_hyperram
     (seed, đọc lại bằng dump,                          sw/common/src/bow_hyperram.c   0x4000_F000 thanh ghi
      so với mô hình Python)                            (khởi tạo, hiệu chỉnh, BIST)   0x6000_0000 cửa sổ
                                                         controller + PHY (hr_clk 100 MHz) ──► ODDRE1 / IDDRE1
                                                         13 chân bank 65 không nối gì ◄──┘  MMCM_H / MMCM_R
                                                                   │ IOB, IDDR đọc lại chính chân của FPGA
                                                         bow_hyperram_dev: HyperRAM giả lập 1 MiB (UltraRAM),
                                                         kiểm tra giao thức (thanh ghi DBG)
```

**Đã chạy trên bo ngày 2026-11-07** (bản loopback): `test` 19/19 (ba lần: sau khi nạp, sau
`RESET` của MCC, sau khi nạp lại firmware), `verify` 40/40 và 200/200, BIST trên toàn 1 MiB 0
lỗi ở 184,4 MB/s (đỉnh 200 MB/s), DDR 18/18 trên cùng bitstream (chi tiết ở mục 3.6).
**Trên chip thật ngày 2026-11-09** (bo RAM ở khe FMC+ J11, qua level shifter TXV0108): `test`
19/19, `verify` 40/40, BIST (PRBS hai seed và dữ liệu đếm) và `memtest` của CPU trên toàn
32 MiB đều 0 lỗi, BIST 184,1 MB/s (chi tiết ở mục 5.3).

Chip HyperRAM (S80KS2562) nằm trên bo RAM mở rộng (`docs/fpga/ram_extension`). Bản build
mặc định là **loopback**, không cần bo RAM: PHY lái chân thật của FPGA (ODDR, IOB, IDDR,
hai MMCM dịch pha chạy như với chip thật), còn một HyperRAM giả lập trong FPGA
(`bow_hyperram_dev`) trả lời qua đường loopback của wrapper chân. Bản này không dùng khe FMC
nên không cần đổi `FMC_FORCE`. Bản bo RAM (chip thật) ở mục 5.

## 1. Build

```bash
make sw                                   # build/sw/hyperram/hyperram.bin + boot ROM
make fpga BOARD=mps4 FLASH_VMEM=$PWD/build/sw/hyperram/hyperram.vmem
```

Kết quả ở `build/fpga/mps4/` như bản DDR (`bow32_mps4.bit`, báo cáo, `sdcard/`), thêm
`hr_write_paths.rpt` (đường thanh ghi PHY → ODDR của DQ/RWDS, `hr_clk` → `hr_wclk`).
`HR_LOOPBACK` mặc định theo `DDR_LOOPBACK` (1).

Kết quả build (Vivado 2025.2, 2026-11-07): đạt mọi ràng buộc timing, setup WNS +0,246 ns
(trong `ddr_clk`), hold WHS +0,010 ns; `hr_clk` → `hr_wclk` (thanh ghi PHY → ODDR của DQ/RWDS,
cả dải pha ghi ±3T/16) setup +0,329 ns / hold +1,410 ns; 8/8 ràng buộc bus skew đạt (FIFO đọc
của DDR, FIFO đọc / lệnh / trả lời của HyperRAM); `tcl/timing_checks.tcl` không báo gì (mỗi
cặp clock đúng loại ràng buộc; `report_cdc` chỉ có 8 CDC-10 ở chân CLR của bộ đồng bộ reset,
như dự kiến). Toàn thiết kế (DDR + HyperRAM): 46 395 LUT (2,7 %), 35 328 FF, 67 BRAM, 199
URAM (32 cho HyperRAM giả lập, 128 cho DRAM giả lập).

Ba điểm timing gặp khi build (đã sửa, ghi lại để khỏi lặp):

* Vivado coi pha tĩnh 270° của `hr_clk` là độ trễ clock, không nằm trong dạng sóng, nên cặp
  cạnh mặc định của `hr_clk` → `hr_wclk` sai một chu kỳ (WNS −10 ns):
  `set_multicycle_path -setup 2` (không `-hold 1`, xem [ip/hyperram.md](ip/hyperram.md) 2.4).
* Ở pha ghi +T/4 cạnh bắt trước đó của ODDR trùng lúc phóng dữ liệu (biên hold bằng 0): dải pha
  ghi là ±3T/16 và STA kiểm cả dải.
* HyperRAM giả lập 4 MiB (128 URAM) đẩy logic DRAM giả lập ra xa chân của nó (gốc clock
  `ddr_clk` từ X3Y5 sang X5Y2, đường DQS −0,7 ns): bản loopback dùng 1 MiB, và đầu ra của
  emulator đi từ một flop fabric chứ không từ chuỗi URAM.

### Clock

`OSCCLKA[2]` = 100 MHz qua một IBUF tới hai cây clock:

| Cây | MMCM | Đầu ra |
|-----|------|--------|
| DDR (`bow_ddr_clk_xusp`, BUFGCE riêng) | `MMCM_A`, `MMCM_B`, `MMCM_W` | `clk_sys` 50 MHz và các clock DDR ([ddr_mps4.md](ddr_mps4.md)) |
| HyperRAM (`bow_hyperram_clk_xusp`, BUFGCE riêng) | `MMCM_H` (VCO 1200 MHz) | `hr_clk` 100 MHz pha 270° (controller, CK), `hr_wclk` = `hr_clk` + T/4, dịch được ±3T/16 (ODDR của DQ/RWDS, `WPS_GO`) |
| | `MMCM_R` | `hr_rd_clk` 100 MHz, dịch được cả chu kỳ (IDDR, `PS_GO`, 672 bước mỗi CK) |

Một BUFGCE nối từ chân clock chỉ tới được tối đa ba MMCM ở vùng clock của chân và hai vùng
kề; ba vùng đó đã thuộc về DDR (`MMCM_B`, `MMCM_A`, và `MMCM_W` kề `MMCM_A`), nên net của
BUFGCE HyperRAM được phép đi dọc cột CMT (`CLOCK_DEDICATED_ROUTE SAME_CMT_COLUMN` trong
`constr/mps4.xdc`). `hr_clk` bất đồng bộ với `clk_sys` (mọi đường qua CDC của IP), pha đọc
được hiệu chỉnh, nên độ trễ thêm của đường này không ảnh hưởng gì.

LED: đèn trong nút **PB2** (`USER_nLED[9]`) sáng khi mọi MMCM (DDR và HyperRAM) đã lock.

## 2. Nạp bitstream và kết nối

Như [ddr_mps4.md](ddr_mps4.md) mục 2–3 (thẻ dùng chung: chỉ đổi dòng `APPFILE`, **không sửa
`config.txt`**, trả lại sau khi thử):

```bash
python3 tools/bow32_mps4.py deploy        # chép build lên thẻ, REBOOT bo, in console Bow32
PORT=/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_<số serial>-if01-port0
...
python3 tools/bow32_mps4.py restore       # trả APPFILE về thiết kế của nhóm kia
```

Bo đang tắt (`SHUTDOWN` của MCC) thì thẻ không hiện trên USB: `python3 tools/bow32_mps4.py
reboot` bật bo trước (nạp thiết kế mà thẻ đang chọn), rồi `deploy`.

Console sau khi bật:

```
Bow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1
boot: waiting 300 ms for host
boot: starting image @08000020 (... bytes)

Bow32 HyperRAM test (sw/apps/hyperram), type h for help
hyperram: Bow32 HyperRAM 32 MiB x8, PHY loopback, 100 MHz (100000000 Hz), 672 phase steps, emulator 1024 KiB
>
```

## 3. Kiểm chứng

### 3.1 Self-test

```bash
python3 tools/bow32_hyperram.py -p $PORT test        # --quick: bản rút gọn (mô phỏng chạy bản này)
```

19 mục: IP có mặt; lệnh bị từ chối đúng luật; khởi tạo (RESET#, mắt ID0, CR0/CR1, mắt của
mẫu, mở cửa sổ); thanh ghi thiết bị; dữ liệu qua cửa sổ (bit dữ liệu, đường địa chỉ, địa chỉ
trong địa chỉ, ghi byte/halfword bằng mặt nạ RWDS, xorshift với ghi posted và không posted);
read buffer (word cần trước, trúng, ghi xuyên); lỗi ngoài dung lượng; BIST (PRBS và đếm, đọc
lại qua cửa sổ = bản C); latency biến đổi (trùng refresh 2× được đếm); hybrid sleep; deep
power down; giới hạn bước pha; ngắt `irq_fast[12]`; và cuối cùng không có cờ lỗi nào, emulator
không báo vi phạm (`DBG`).

### 3.2 Hiệu chỉnh và mắt đọc

```bash
python3 tools/bow32_hyperram.py -p $PORT cal --step 2     # init nếu cần, quét pha đọc
python3 tools/bow32_hyperram.py -p $PORT eye --step 1     # chỉ in mắt (pha, RD_DLY, 32 byte đầu được trả lại, kiểm lại)
```

Mỗi ký tự của dòng `eye` là một pha của `hr_rd_clk` trong một chu kỳ CK: `#` = đọc đúng (ID0
= 0x0E86, rồi mẫu 32 byte trong bộ nhớ), `.` = sai hoặc lỗi giao dịch. Phần mềm chọn giữa dải
dài nhất rồi đo `RD_DLY` từ chụp thô (vị trí byte A đầu tiên trong luồng mẫu).

### 3.3 Ngẫu nhiên, so với mô hình trên PC

```bash
python3 tools/bow32_hyperram.py -p $PORT verify -n 40 --seed 2026
```

Mỗi case là một lượt ghi của BIST phần cứng (`bist ... w BURST SEED`, dữ liệu PRBS hay đếm)
hoặc một lượt ghi của CPU qua cửa sổ (`fill`, ghi posted), với seed sinh trên PC; rồi `dump`
đọc lại qua cửa sổ và từng byte được so với giá trị tính bằng Python (bản Python của bộ sinh
dữ liệu BIST và của xorshift): kiểm tra này không dựa vào phần mềm chạy trên bo.

### 3.4 Băng thông

```bash
python3 tools/bow32_hyperram.py -p $PORT bench
```

BIST đo băng thông thật của HyperBus (đỉnh 200 MB/s ở CK 100 MHz, trừ CA, latency 2 × 4 chu
kỳ và CS# cao giữa các burst); CPU đọc/ghi qua cửa sổ chậm hơn nhiều vì mỗi truy cập là một
giao dịch 32 bit qua hai miền clock, nhưng đọc trúng read buffer nhanh như SRAM.

### 3.5 Gõ lệnh trực tiếp

```
> info
> init
> bist 0 65536 prbs          offset 0, 64 KiB, ghi rồi đọc, dữ liệu PRBS
> memtest 0 65536 3
> wr 60001234 cafef00d
> rd 60001234
> reg CR0                    đọc thanh ghi của thiết bị
> cap ID0                    một lần đọc ID0 + chụp thô 64 chu kỳ
> sleep / wake / dpd         hybrid sleep, WAKE, deep power down
> stat
```

`h` in danh sách lệnh đầy đủ; mọi định dạng đầu ra nằm ở đầu `sw/apps/hyperram/main.c`.

Số trong lệnh: địa chỉ (`ADDR` của `bist` / `memtest` / `fill`, địa chỉ của `rd` / `wr` /
`dump`) là hex, có hay không có `0x`; còn `LEN`, `BURST`, `SEED` là **thập phân** nếu không viết
`0x`. `bist 60000000 2000000` chỉ thử 2 000 000 byte (~1,9 MiB); toàn bộ 32 MiB là
`bist 0x60000000 0x2000000` (dòng kết quả in `words 16777216`).

### 3.6 Kết quả trên bo (2026-11-07, bản loopback)

| | Kết quả |
|---|---|
| Self-test | 19/19 (bản đầy đủ), rồi 19/19 (bản rút gọn) sau `RESET` của MCC và sau khi nạp lại firmware |
| Mắt đọc (bước / 672, quét bước 1; 1 bước = 14,9 ps) | ID0: 653 điểm tốt (19 xấu: hai vùng ~9–10 điểm), mẫu: 646 (26 xấu: hai vùng ~13 điểm); mỗi vùng ~0,14–0,19 ns, ở hai lần chuyển dữ liệu mỗi chu kỳ; dải liên tục dài nhất 322–324 bước, `RD_DLY` 12 (byte A đầu tiên ở nửa chu kỳ 46) |
| `verify` | 40/40 (seed 2026), 200/200 (seed 7); bitstream cuối: 40/40, 60/60 (seed 99) |
| `init` (bitstream cuối, firmware có hiệu chỉnh gập T/2) | 24/24 từ 24 pha xuất phát rải trên nửa chu kỳ; tâm 5253–5257 (hoặc tương đương +336), `RD_DLY` 12 / 11 |
| BIST (toàn 1 MiB, 524 288 word, ghi + đọc) | PRBS và đếm: 0 lỗi, 184,4 MB/s (burst 255); burst 64: ghi 160,0 / đọc 140,7 MB/s |
| CPU qua cửa sổ (`bench`, 4 KiB) | ghi 8,3 MB/s, ghi posted 24,7 MB/s, đọc trúng read buffer 20,8 MB/s, đọc không buffer 7,1 MB/s |
| Nguồn | hybrid sleep: cửa sổ trả lỗi bus, WAKE, dữ liệu còn; deep power down: WAKE, `init` lại, đọc được |
| Reset SoC (`RESET` của MCC) | pha đọc và CR0 giữ nguyên (miền reset của bo), `INIT_DONE` về 0, `init`/self-test chạy lại được |
| DDR trên cùng bitstream | `bow32_ddr.py test`: 18/18 (cây clock DDR không đổi vị trí) |

Mắt đọc ở bản loopback gần như trọn chu kỳ vì bộ căn tìm byte A theo RWDS: chỉ những pha rơi
đúng lúc dữ liệu đổi (hai lần mỗi chu kỳ, DDR) là xấu, và hai vùng xấu cách nhau đúng T/2 (336
bước). Phần mềm gập bản đồ theo T/2 rồi chọn giữa mắt đã gập ([ip/hyperram.md](ip/hyperram.md)
mục 4): bản đầu chọn giữa dải dài nhất và hỏng `init` khi bước quét thô (8) lọt qua một vùng xấu
hẹp — gặp một lần trên bo (82/84 điểm tốt), đã sửa và kiểm lại: 24/24 lần `init` từ 24 pha xuất
phát, rồi self-test 19/19 bốn lần, `verify` 60/60. Với chip thật qua level shifter, mắt sẽ hẹp
hơn và phụ thuộc trễ của bo.

Lượt 2026-11-08, bitstream dựng lại sau hai vòng sửa của review PR #6 (setup WNS +0,488 ns, hold
WHS +0,010 ns): self-test 19/19 (bản đầy đủ), 19/19 (rút gọn) sau `RESET` của MCC và sau khi nạp
lại firmware; `verify` 40/40 (seed 2026) và 20/20 (seed 99); `cal` pha −114, `RD_DLY` 12; `eye`
bước 1: ID0 651 / 672, mẫu 645 / 672, pha và `RD_DLY` được trả lại; `bench`: ghi 7,99, ghi posted
28,22, đọc read buffer 20,77, đọc không buffer 7,14 MB/s, BIST 64 KiB ghi 188,1 / đọc 180,7 MB/s;
WAKE khi đang thức không làm gì (`DBG` = 0), hybrid sleep / deep power down như trên; `cap` trước
`init` bị từ chối gọn (`ERR_CODE` 5); DDR 18/18 trên cùng bitstream.

Sau khi thử: `bow32_mps4.py restore` (dòng `APPFILE` về `CA5DS\ca5ds.txt`, `board.txt` trùng
từng byte bản giữ); FPGA vẫn chạy Bow32 tới lần `REBOOT` hay tắt nguồn kế tiếp.

## 4. Mô phỏng trước khi lên bo

```bash
make run TEST=hyperram            # SoC + mô hình clock/pad + HyperRAM giả lập, ~1 phút
make -C hw/ip/hyperram/dv test    # testbench IP: mô hình S80KS2562, bo RAM (TXV0108), stub
```

`make run TEST=hyperram` dựng đúng cấu hình của bản loopback (100 MHz, 672 bước pha) với
HyperRAM giả lập 1 MiB, chạy `test quick` và kiểm tra `DBG` của emulator.

## 5. Bo RAM thật (chip S80KS2562 qua TXV0108)

### 5.1 Build và chuẩn bị

* Build: `make fpga BOARD=mps4 DDR_LOOPBACK=0 FLASH_VMEM=...` (cả DDR2 và HyperRAM trên khe
  FMC+, LVCMOS15; chân HyperRAM ở `constr/hyperram_card.xdc`; `HR_LOOPBACK=1` giữ HyperRAM ở
  loopback).
* `config.txt`: `FMC_FORCE: 1V5` (VADJ của khe FMC+ = 1,5 V cho TXV0108). Thẻ để `1V2` cho
  thiết kế của nhóm khác: hỏi trước khi đổi, giữ một bản `config.txt` trước khi sửa (sửa tay:
  `bow32_mps4.py` chỉ đổi dòng `APPFILE`). Bo RAM chỉ cắm / rút khi đã rút jack 12 V (J71);
  các luật khi bo RAM đang cắm ở mục 5.4.
* Đọc [ip/hyperram.md](ip/hyperram.md) mục 2.5 (level shifter) và
  [ddr_board_review.md](ddr_board_review.md) trước khi đặt mạch: ngưỡng DIR/OE của TXV0108
  (lái 1,5 V, tham chiếu 1,8 V), méo duty của CK qua level shifter.
* Hiệu chỉnh cả pha ghi: `bow32_hyperram.py cal --write`.

Kết quả build bản bo RAM (2026-11-08, sau hai vòng sửa của review): đạt mọi ràng buộc, setup
WNS +0,098 ns, hold WHS +0,001 ns, 8/8 bus skew; `hr_clk` → `hr_wclk` hold +0,714 ns (bản
2026-11-07: WNS +0,103 ns, `hr_clk` → `hr_wclk` +3,357 / +0,428 ns). Bản chạy trên bo ngày
2026-11-09 dựng lại từ main `ed949e1` (thêm các bản sửa của DDR và MKV): WNS +0,102 ns, WHS
+0,012 ns. Ba điểm riêng của bản này:

* DQ/RWDS có pull-down yếu của chân FPGA (`PULLTYPE PULLDOWN` trong `constr/hyperram_card.xdc`):
  mạch vào của TXV0108 luôn hoạt động, kể cả khi OE# = 1, mà FPGA thả các chân này trong reset kênh
  (để không chồng lái với một lần đọc bị cắt) và từ lúc nạp cấu hình tới chu kỳ PHY đầu tiên.
* Chân dữ liệu của DDR2 và HyperRAM trên bo RAM đều ở bank 71 (vùng clock X4Y11), cách các MMCM
  của DDR sáu vùng. Đường DQS của DDR (flop PHY → ODDR, nửa chu kỳ trừ độ bất định T/4) hụt
  −0,07 ns với gốc clock Vivado tự chọn; `constr/ddr_card.xdc` đặt gốc của `ddr_wclk` ở X4Y6 (vùng
  của MMCM_W): +0,10 ns. Sáu cách đặt gốc khác đều tệ hơn (gốc gần chân làm lệch clock tăng).
* Chân inout không có `set_input_delay` (dữ liệu đọc được hiệu chỉnh lúc chạy) nên `report_cdc`
  báo CDC-13 cho mỗi đường chân → D của IDDRE1 (9 của DDR, 9 của HyperRAM); `timing_checks.tcl`
  coi đúng các đường này là dự kiến, mọi CDC-13 khác vẫn là lỗi.

### 5.2 Chạy

Bo RAM đã cắm (lúc rút 12 V), `FMC_FORCE: 1V5` đã được nhóm dùng chung đồng ý; build bản bo
RAM ở trên, `PORT` như mục 2:

```bash
python3 tools/bow32_mps4.py show            # dừng nếu config.txt chưa có FMC_FORCE: 1V5
python3 tools/bow32_mps4.py deploy
H="python3 tools/bow32_hyperram.py -p $PORT"
$H cmd info stat
$H cmd init "reg ID0" "reg ID1" "reg CR0" "reg CR1" "cap ID0" stat   # RESET#, mắt ID0, thanh ghi
$H eye --step 2                             # mắt đọc qua level shifter
$H cal --write --step 2                     # pha ghi
$H test
$H verify -n 40 --seed 2026
$H cmd "bist 0x60000000 0x2000000" "bist 0x60000000 0x2000000 count" stat   # BIST toàn 32 MiB
$H cmd "memtest 0x60000000 0x2000000 7"     # CPU qua cửa sổ, toàn 32 MiB (~1 phút)
$H bench
$H cmd sleep "rd 60000000" wake "rd 60000000" stat   # hybrid sleep: lỗi bus (mã thoát 1) rồi đọc được
python3 tools/bow32_flash.py -p $PORT flash build/sw/ddr/ddr.bin       # DDR2 trên cùng bo
python3 tools/bow32_ddr.py -p $PORT test
python3 tools/bow32_ddr.py -p $PORT cal --write --step 2
```

`LEN` của `bist` / `memtest` phải có `0x` (mục 3.5). Sau khi thử, trả bo đúng thứ tự ở mục
5.4: **không** `restore` hay đổi `FMC_FORCE` trước khi bo RAM đã được tháo ra.

### 5.3 Kết quả trên bo (2026-11-09)

Bo RAM ở khe FMC+ J11, `FMC_FORCE: 1V5`, bitstream bản bo RAM từ main `ed949e1`. Console của MCC
khi bật: `FMC board detected`, `FMC VADG: 1500mV` và `WARNING: PSU VIO_HB  : 1.49V` (đó là
VIO_B_M2C do bo RAM cấp từ +1V5 của nó, đúng như thiết kế).

| | Kết quả |
|---|---|
| Thiết bị | ID0 `0e86`, ID1 `0001`; CR0 `8fff` (latency 4 cố định: level shifter không cho latency biến đổi, self-test [14] kiểm việc từ chối), CR1 `ffc1`, TCSM 395 chu kỳ |
| Mắt đọc (`eye --step 2`, 336 điểm mỗi CK) | ID0 310 / 336 điểm tốt, mẫu 287 / 336; pha 154–156, `RD_DLY` 13, byte A đầu tiên ở nửa chu kỳ 48 (bản loopback: 46, `RD_DLY` 12) |
| Mắt ghi (`cal --write --step 2`) | tốt ở mọi điểm quét (32 / 32, độ rộng 256 bước), pha ghi 2 |
| Self-test | 19/19 (firmware của main), 19/19 (firmware có bản sửa `(null)` của self-test) |
| `verify` | 40/40 (seed 2026) |
| BIST toàn 32 MiB (16 777 216 word, burst 255, ghi rồi đọc) | PRBS seed `c0ffee`, PRBS seed `5a5a1234`, dữ liệu đếm: 0 lỗi, 184,11 MB/s (36 449 375 chu kỳ CK cho 2 × 32 MiB) |
| `memtest` toàn 32 MiB (CPU qua cửa sổ, seed 7) | địa chỉ trong địa chỉ, đảo, rồi xorshift: 25 165 824 word đã kiểm, 0 lỗi |
| `bench` | CPU ghi 7,99, ghi posted 28,22, đọc read buffer 20,77, đọc không buffer 7,14 MB/s; BIST 64 KiB ghi 188,11 / đọc 180,10 MB/s |
| Nguồn | hybrid sleep: cửa sổ trả lỗi bus, WAKE, đọc được; deep power down, WAKE, `init` lại, đọc được |

BIST là máy phần cứng trong controller: burst 255 word liền nhau, mỗi burst chỉ tốn CA, latency
và CS# cao, nên đạt ~92 % đỉnh 200 MB/s. CPU mỗi lần chỉ có một truy cập 32 bit qua hai miền
clock, nên chậm hơn nhiều (mục 3.4); muốn nhanh hơn cần burst dài (DMA).

### 5.4 Bo dùng chung khi bo RAM đang cắm

MPS4 dùng chung với các nhóm khác (thiết kế của họ trên cùng thẻ microSD). Khi bo RAM nằm ở
J11:

* **Không bật bo với `FMC_FORCE` dưới `1V5`.** DIR / OE# của TXV0108 tham chiếu VCCA = 1,8 V
  (ngưỡng mức 1 ~1,26 V): FPGA lái 1,2 V thì hướng của level shifter không xác định, hai phía có
  thể cùng lái ([ip/hyperram.md](ip/hyperram.md) mục 2.5).
* **Không nạp thiết kế của nhóm khác** khi chưa chắc thiết kế đó không đặt chân nào ở bank 69 /
  70 / 71 (53 chân nối với bo RAM): xem XDC hay `report_io` của họ. Thiết kế không có chân nào ở
  các bank này (nhóm FU3 cho biết không dùng FMC) thì `FMC_FORCE: 1V5` không ảnh hưởng tới nó.
* **Tắt nguồn** là rút jack 12 V (J71), không phải `SHUTDOWN` của MCC, trước khi cắm hay rút
  bất kỳ card nào.

Trả bo cho nhóm khác theo đúng thứ tự này. `restore` chỉ sửa thẻ, không tự khởi động lại; nhưng
nếu `APPFILE` / `FMC_FORCE` đã đổi khi bo RAM còn cắm thì lần bật hay `REBOOT` kế tiếp nạp thiết
kế khác, hay cấp 1,2 V, trong lúc bo RAM vẫn trên khe:

1. Rút 12 V (J71), tháo bo RAM khỏi J11.
2. Cắm lại 12 V: bo lên với J11 trống (`FMC_FORCE: 1V5` và Bow32 không hại gì khi khe trống).
3. `python3 tools/bow32_mps4.py restore` (dòng `APPFILE`); trả `config.txt` về bản đã giữ
   (`FMC_FORCE: 1V2`); so từng byte `config.txt` và `board.txt` với bản giữ.
4. `python3 tools/bow32_mps4.py reboot` và xem console của MCC. Card của nhóm khác cũng chỉ cắm
   khi đã rút 12 V.

## 6. Sự cố

| Hiện tượng | Nguyên nhân thường gặp |
|------------|------------------------|
| `hyperram: IP not found (stub ...)` | bitstream của bo khác (`HrEn = 0`) |
| `hyperram: HyperRAM clock not running` | MMCM chưa lock (đèn PB2 tắt) |
| `hyperram: init: no ID0 eye (0 of N points)` | không đọc được ID0 ở pha nào: chân / loopback / level shifter (bo RAM: `FMC_FORCE`, OE#) |
| cửa sổ trả lỗi bus | chưa `init` (`STATUS.READY` = 0), thiết bị đang ngủ, hoặc cửa sổ đã chết (`BROKEN`): `CORE_RST` rồi `init` lại |
| `RWDS` / `RD_TMO` trong `ERR_CODE` | pha đọc hoặc `RD_DLY` lệch sau khi đổi điều kiện: `cal` lại |
| `TCSM_ERR` | burst dài hơn `TIM0.TCSM` cho phép: giảm `BURST` của BIST |
| `bist` / `memtest` thử ít hơn mong đợi (`words` nhỏ) | `LEN` không có `0x` là số thập phân (mục 3.5) |
| `DBG` báo lỗi | HyperRAM giả lập thấy vi phạm giao thức: mã lỗi trong [ip/hyperram.md](ip/hyperram.md) mục 6 |
