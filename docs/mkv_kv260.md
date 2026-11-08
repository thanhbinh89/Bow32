# Mã khối MKV trên board: kiểm chứng IP `bow_mkv` (Arm MPS4, Kria KV260)

Hướng dẫn nạp bitstream có khối mật mã MKV ([ip/mkv.md](ip/mkv.md)), chạy ứng
dụng kiểm thử `sw/apps/mkv` và đối chiếu kết quả của phần cứng với TCVN
14263:2024 (Phụ lục A) và với mô hình Python trên PC. Hai board dùng cùng ứng
dụng và cùng công cụ, chỉ khác cách build và nạp (mục 1–3): Arm MPS4 (thẻ microSD
của bộ điều khiển bo, console trên cổng USB-C) và Kria KV260 (JTAG, UART0 trên
PMOD).

```
 PC: tools/bow32_mkv.py ──UART0──► Ibex (sw/apps/mkv) ──bus──► MKV IP 0x4000_B000
     + tools/mkv/mkv_model.py      │  mkv_sw.c: MKV phần mềm        KEY / ENC / DEC
       (so sánh)                   │  mkv_vectors.h: Phụ lục A      irq_fast[10]
                                   └─► "mkv: PASS (19/19)", "out <hex>"
```

> **Kết quả trên Arm MPS4 (2026-11-08), bản sau [đánh giá bảo
> mật](mkv_security_review.md) (mục 8):** bitstream `mps4` (Vivado 2025.2, bản
> loopback của DDR, ứng dụng `mkv` nạp sẵn trong flash) đạt timing: setup WNS
> +0,240 ns (ở clock DDR 133 MHz), hold WHS +0,010 ns; ở clock SoC 50 MHz đường
> xấu nhất là đường bus từ CPU vào MKV, còn +2,625 ns. MKV 13 138 LUT (180 LUTRAM),
> 2 785 FF (khối thanh ghi 222 LUT / 916 FF, engine 12 916 LUT / 1 869 FF); toàn bản
> 41 582 LUT. Trên board: tự kiểm tra lúc khởi động của driver PASS, `test`
> **PASS (19/19)** với seed 1 và 7 (20 khoá ngẫu nhiên mỗi phiên bản; 3 lệnh `TEST`
> cho `FAULT` mà không bị đếm, `FAULTS` vẫn 0), `kat` 6/6 bản mã trùng Phụ lục A,
> `verify` **360/360 khối** (seed 2026) và 1 800/1 800 khối (600 khoá, seed 8) trùng
> mô hình Python. Bitstream KV260 của bản này cũng build đạt timing (`kv260_cam`:
> WNS +0,155 ns ở clock video 200 MHz, MKV 12 100 LUT, 2 792 FF; `kv260`: WNS
> +3,750 ns) nhưng chưa chạy trên KV260.

> **Bản trước, trên KV260 (2026-11-05), MKV theo TCVN 14263:2024, trước các sửa
> của [đánh giá bảo mật](mkv_security_review.md):** bitstream
> `kv260_cam` (Vivado 2025.2) đạt timing (setup WNS +0,151 ns ở clock video 200 MHz,
> hold +0,010 ns; mọi đường qua MKV ở 50 MHz còn ≥ +1,27 ns); MKV có phát hiện lỗi
> 9 524 LUT (168 LUTRAM), 2 282 FF, bằng bản theo dự thảo (`main` build lại cùng
> flow: 9 526 LUT, 2 278 FF); toàn bản 35 321 LUT (30 %). Bản `kv260` cũng đạt: WNS
> +3,842 ns (đường bus vào MKV), 34 548 LUT. Trên board: `test` **PASS (13/13)**
> (20 khoá ngẫu nhiên mỗi phiên bản, không `FAULT` nào), `kat` 6/6 bản mã trùng
> Phụ lục A của chuẩn, `verify` 120 khoá ngẫu nhiên / **360/360 khối** trùng mô hình
> Python; IP nhanh hơn MKV phần mềm trên Ibex 140…360 lần mỗi khối.

## 1. Build

```bash
make sw                           # build/sw/mkv/mkv.bin, mkv.vmem (+ boot ROM, các app khác)
make fpga BOARD=mps4 FLASH_VMEM=$PWD/build/sw/mkv/mkv.vmem   # Arm MPS4, nạp sẵn ứng dụng mkv
make fpga BOARD=kv260_cam         # hoặc BOARD=kv260 (không camera)
```

MKV nằm trong `bow32_top` nên có trong mọi bitstream; MKV không cần camera hay
DDR. Bản MPS4 là bản loopback của DDR ([ddr_mps4.md](ddr_mps4.md)): không dùng khe
FMC, chạy với `config.txt` của thẻ như hiện có. `FLASH_VMEM` nạp sẵn ứng dụng
`mkv` vào flash của bitstream, bật bo là ứng dụng chạy luôn. Trên máy build hiện
tại bản MPS4 mất ~11 phút (`JOBS=8`), mỗi bản KV260 ~7 phút. Lưu ý: `make -C sw/apps/mkv`
chỉ build `.elf`; dùng `make sw` hoặc `make -C sw/apps/mkv all` để có `.bin` và
`.vmem`.

## 2. Nạp bitstream

### 2.1 Arm MPS4

MCC (bộ điều khiển bo) nạp FPGA từ thẻ microSD lúc khởi động; thẻ hiện ra trên PC
như một ổ USB (nhãn `M1SDP`). Thẻ dùng chung với nhóm khác: chỉ đổi dòng
`APPFILE` của `board.txt`, không bao giờ sửa `config.txt`, trả lại sau khi thử
(quy tắc, quyền mount và công cụ: [ddr_mps4.md](ddr_mps4.md), mục 2).

```bash
python3 tools/bow32_mps4.py deploy        # chép build/fpga/mps4/sdcard lên thẻ, REBOOT, in console Bow32
# ... mục 4 ...
python3 tools/bow32_mps4.py restore       # trả APPFILE về thiết kế của nhóm kia
```

```
MCC: Reading Board File \MB\HBI0376B\BOW32\bow32.txt
MCC: Configuring FPGA from file \MB\HBI0376B\BOW32\bow32.bit
MCC: (127 x 256 KiB programmed)
MCC: FPGA configuration complete.
...
MCC: Releasing CB_nRST
--- Bow32 console (/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_<số serial>-if01-port0)
Bow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1
boot: waiting 300 ms for host
boot: starting image @08000020 (21396 bytes)

Bow32 MKV block cipher demo (TCVN 14263:2024), type h for help
mkv: Bow32 MKV IP, MKV-128 + MKV-256, 4 cycles per round with fault detection, 50 MHz
mkv: power-on self-test PASS
>
```

Ứng dụng chạy tự kiểm tra của driver (`bow_mkv_selftest()`: 6 véc tơ của Phụ lục A
cả hai chiều, 3 lệnh `TEST`) trước khi nhận lệnh; chưa qua thì `key` bị từ chối.

Console của Bow32 (UART0) là cổng 1 của FT4232H trên cổng USB-C
(`/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_<số serial>-if01-port0`),
115200 baud; cổng 0 là console của MCC. Bitstream đã có ứng dụng `mkv` trong flash
nên không cần mục 3; nạp bản build khác của ứng dụng thì không cần build lại
bitstream: `python3 tools/bow32_flash.py -p $PORT flash build/sw/mkv/mkv.bin`
(FT4232H gửi được BREAK, không cần `--no-break`; flash của FPGA về bản trong
bitstream sau mỗi `REBOOT`).

Trên MPS4, reset của bo (`CB_nPOR`, `CB_nRST`, cả lệnh `RESET` của MCC qua
`tools/bow32_mps4.py reset`) là power-on reset của SoC: nó xoá bộ đếm lỗi và gỡ
`LOCKED` của MKV. Reset bằng phần mềm (`RST_CTRL`) và BREAK trên UART thì không
([ip/mkv.md](ip/mkv.md#kiến-trúc-rtl), đoạn "Giới hạn số lần thử"). Trên một sản phẩm, chân reset này
phải là reset lúc bật nguồn thật, không phải nút hay lệnh mà ai cũng dùng được.

### 2.2 Kria KV260

Board đang chạy (Linux trên PS hay chỉ U-Boot đều được), cáp USB JTAG/UART của
KV260 cắm vào PC:

```bash
make fpga-jtag BOARD=kv260_cam JTAG_SERIAL=XFL1IFQTM5QXA
```

```
INFO: Kria K26 on JTAG cable XFL1IFQTM5QXA
INFO: pl_clk0 = 100.0 MHz
INFO: FPGA is configured
INFO: Bow32 is out of reset
```

`JTAG_SERIAL` chỉ cần khi hw_server thấy nhiều board (ở bench này có cả VEK280).
Cách khác: chép `build/fpga/kv260_cam/firmware/bow32_cam` vào
`/lib/firmware/xilinx/` trên Kria và `sudo xmutil loadapp bow32_cam`
([fpga_kria.md](fpga_kria.md)).

Bitstream mới có flash trống, boot ROM vào UART loader (UART0, 115200 baud, PMOD
J2 — ở bench này là `/dev/ttyACM0`):

```
Bow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1
boot: flash image invalid (no image)
boot: UART loader ready
```

## 3. Nạp ứng dụng `mkv` (KV260)

```bash
python3 tools/bow32_flash.py -p /dev/ttyACM0 --no-break flash build/sw/mkv/mkv.bin
```

```
image: 16788 bytes payload, entry 0x08000020, crc 0x30403ffe
erasing 0x08000000 .. 0x080041b3
writing
verify OK
booting
```

`--no-break` vì adapter CH9102 của UART0 không gửi được BREAK. Khi một ứng dụng
khác của Bow32 đang chạy (có lệnh `wr`), đưa nó về loader trước:
`wr 40000010 4c4f4144` (BOOT_FLAG "LOAD") rồi `wr 4000000c 52535421` (soft
reset), sau đó chạy lại lệnh flash ở trên. Hoặc nạp lại bitstream (flash về
trống).

## 4. Kiểm chứng

Các lệnh dưới đây dùng cổng UART0 của Bow32:

```bash
PORT=/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_<số serial>-if01-port0   # MPS4
PORT=/dev/ttyACM0                                                               # KV260 (bench này)
```

### 4.1 Self-test trên board

```bash
python3 tools/bow32_mkv.py -p $PORT test          # --quick: 1 khoá / phiên bản
```

```
> test 1
mkv: self-test (full, seed 1)
  [ 1] IP present (ID, INFO)                                      ok
  [ 2] software MKV vs Annex A (round keys, ct, decryption)       ok
  [ 3] IP vs Annex A: encryption (6 versions), STATUS, CYCLES     ok
  [ 4] IP vs Annex A: decryption (6 versions)                     ok
  [ 5] IP vs software: 20 random keys per version, E/D/D(E)       ok
  [ 6] ECB: next DIN during the block, unaligned, in place        ok
  [ 7] errors: ENC without key, KLEN 3, two commands              ok
  [ 8] KEY_VALID: KEY write, CTRL change                          ok
  [ 9] CLEAR: key schedule, DOUT zeroed, rows read back           ok
  [10] interrupt DONE / ERR on irq_fast[10]                       ok
  [11] bus stall: CMD during KEY, DOUT during ENC                 ok
  [12] wipe: KEY needs a whole new key, DOUT zeroed               ok
  [13] bus errors: CMD / KEY / DIN read, ID / DOUT write, holes   ok
  [14] NOSTALL: CMD dropped, DOUT 0 while busy; driver polls      ok
  [15] use policy: NO_ENC / NO_DEC                                ok
  [16] TEST: corrupted check of KEY / ENC / DEC gives FAULT       ok
  [17] DMA blocked from the MKV registers (bus firewall)          ok
  [18] power-on self-test (driver): 6 known answers, 3 TESTs      ok
  [19] fault detection on (INFO), no fault, FAULTS unchanged      ok
mkv: PASS (19/19)
```

(Kết quả trên MPS4, 2026-11-08; cả lượt chạy mất ~2 giây.) Mục [1] cần `ID` =
`0x4D4B5602` (MKV theo TCVN 14263:2024) và `INFO` báo đủ các phần phát hiện lỗi
(`0x000404FF`). Mục [2] kiểm tra MKV
phần mềm (`sw/apps/mkv/mkv_sw.c`) với **khoá vòng và bản mã in trong Phụ lục A**; [3], [4] chạy 6 véc tơ trên IP (cả `STATUS.ROUNDS`,
`CYCLES` = 4R + 4); [5] so IP với phần mềm trên khoá/khối ngẫu nhiên. Ý nghĩa
từng mục: [ip/mkv.md](ip/mkv.md#kiểm-chứng). Đổi seed: `test --seed 7`. Lỗi thật
thì phần mềm không tự tạo được: [16] dùng lệnh `TEST` (làm lệch lượt kiểm tra) để
chứng tỏ phần phát hiện lỗi còn chạy, [19] chứng tỏ cả lượt không có lỗi nào bị
báo nhầm. Phần khoá sau `FaultLimit` lỗi chỉ kiểm được bằng tiêm lỗi trong mô
phỏng (`make -C hw/ip/mkv/dv test`).

### 4.2 Véc tơ của chuẩn

```bash
python3 tools/bow32_mkv.py -p $PORT kat
```

```
A.1.1 MKV-128/128 R=7
  key 000102030405060708090a0b0c0d0e0f
  pt  ffeeddccbbaa99887766554433221100
  ct  f2795ecba8f4d887f539ee8d8df1141d  ok
...
A.2.3 MKV-256/512 R=9
  key 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021...
  pt  ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100
  ct  3dad4f9b1330c6111ced631dddf6e3eea0678d10dd7b75a06b5ba602fcca28ab  ok
kat: PASS (6 versions, ciphertexts equal Annex A)
```

Tool so bản mã của board với giá trị của chuẩn (`tools/mkv/tcvn14263_vectors.json`).

### 4.3 Ngẫu nhiên, so với mô hình trên PC

```bash
python3 tools/bow32_mkv.py -p $PORT verify -n 120 --seed 2026
```

```
verify: 120 cases, seed 2026
  MKV-128/128: 20 keys, 60 blocks
  ...
  MKV-256/512: 20 keys, 60 blocks
verify: PASS (360/360 blocks equal the model)
```

Mỗi case: khoá ngẫu nhiên (`key`), mã hoá một khối ngẫu nhiên (`enc`), giải mã
ngược lại (`dec`), giải mã một khối ngẫu nhiên khác. Khoá và khối sinh trên PC,
kết quả so với `tools/mkv/mkv_model.py`: kiểm tra này **không dựa vào phần mềm
chạy trên board**. Một khối tuỳ ý:

```bash
python3 tools/bow32_mkv.py -p $PORT enc 128 000102030405060708090a0b0c0d0e0f 00112233445566778899aabbccddeeff
board c098d0b88df6c0f81a906eef34e0c43a
model c098d0b88df6c0f81a906eef34e0c43a  ok
```

### 4.4 Tốc độ

```bash
python3 tools/bow32_mkv.py -p $PORT bench
```

```
version       key schedule (cycles)    one block (cycles)   ECB, 64 blocks
                   IP         SW         IP         SW     cycles/block    KB/s
MKV-128/128       390     147416        253      33827              135    5925
MKV-128/192       482     168383        257      38553              135    5925
MKV-128/256       568     189366        261      43279              135    5925
MKV-256/256       506     427520        365     101055              247    6477
MKV-256/384       656     488931        369     115417              247    6477
MKV-256/512       800     550062        373     129611              247    6477
```

Chu kỳ CPU ở 50 MHz (MPS4, 2026-11-08), gồm cả driver. Lõi IP cần 16R + 2 chu kỳ
cho lược đồ khoá và 4R + 4 cho một khối (`CYCLES`, đã gồm lượt kiểm tra); phần
còn lại là CPU ghi `KEY`/`DIN`, đọc `DOUT` qua bus và các kiểm tra của driver. ECB
không phụ thuộc R (cùng 135 / 247 chu kỳ mỗi khối cho ba độ dài khoá): CPU nạp
khối sau và đọc khối trước còn lâu hơn lõi (32…40 chu kỳ).

So với bản trước (KV260, 2026-11-05: lược đồ khoá 296…673, một khối 237…357,
ECB 127 / 239 chu kỳ), lõi và bus không chậm đi: firmware của bản trước chạy trên
bitstream mới đo đúng các số cũ. Phần thêm nằm ở driver mới: lược đồ khoá +94…127
chu kỳ (kiểm tự kiểm tra đã qua, đổi phiên bản bằng đọc–sửa–ghi `CTRL`, chờ có
giới hạn, kiểm `ERR`/`FAULT`/`LOCKED`), một khối +16 chu kỳ (đọc `STATUS` và `CTRL`
trước lệnh, xoá `DONE`/`ERR`, kiểm `STATUS` sau lệnh), ECB +8 chu kỳ mỗi khối (hai
lần xét `NOSTALL` trong vòng lặp). Hai hàm đổi byte của driver phải được inline:
gọi như hàm thường, chúng làm `write_block`/`read_block` lưu thanh ghi mỗi khối,
ECB mất thêm 17…21 chu kỳ mỗi khối (đo được 156 / 264). Số đo bằng CPU lệch vài chu kỳ
giữa các bản build của ứng dụng (vị trí code của driver trong flash: bản theo
dự thảo đo 124 / 228 với cùng vòng lặp đặt ở địa chỉ khác), `CYCLES` của lõi
thì cố định. MKV phần mềm chậm hơn khi còn theo bản dự thảo 26…40 % mỗi khối
(thêm một vòng, phép xoay cột tính chỉ số từng byte).

### 4.5 Gõ lệnh trực tiếp

```bash
python3 tools/bow32_flash.py -p $PORT monitor     # hoặc picocom -b 115200 $PORT
```

```
> key 256 0102030405060708090a0b0c0d0e0f1112131415161718191a1b1c1d1e1f2223
key MKV-256/256 R=7 (114 cycles)
ok
> enc 112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00
out 772c1fe62ff01af708c935f974d84889f053f2c3d7e09d9dfdbefdabc94bf9a1
ok
> info
MKV ID 4d4b5602 INFO 000404ff CTRL 00000001 STATUS 00000716 (busy 0 key 1 done 1 err 0 fault 0, R 7, MKV-256)
    faults since power-on 0 (lock at 4), locked 0, alert 0
ok
> post
mkv: power-on self-test PASS
ok
```

`h` liệt kê lệnh: `test [quick] [seed]`, `kat`, `key <l> <hex>`, `enc <hex>`,
`dec <hex>`, `bench`, `clear`, `post`, `info`, `rd`/`wr`, `baud`. Dòng thứ hai của
`info` là bộ đếm lỗi từ lúc bật nguồn (`STATUS.FAULTS`), ngưỡng khoá
(`INFO[19:16]`), `LOCKED` và `ALERT`.

## 5. Khi có lỗi

| Hiện tượng | Nguyên nhân / cách xử lý |
|------------|--------------------------|
| `cannot reach the boot ROM loader` | board đang chạy ứng dụng: `wr 40000010 4c4f4144`, `wr 4000000c 52535421` (mục 3), hoặc nạp lại bitstream |
| `mkv: IP not found (ID 00000000)` | bitstream cũ (trước MKV): build lại `make fpga` từ nhánh này |
| `mkv: IP not found (ID 4d4b5601)` | bitstream có MKV phiên bản 1 (mã của bản dự thảo, R = 6 / 7 / 8): build và nạp lại bitstream |
| `timeout` của `bow32_mkv.py` | sai cổng / baud (ứng dụng khác để UART0 ở 921600: thêm `-b 921600`), hoặc adapter đã đổi tên (`ls /dev/ttyACM*`) |
| `error: fault detected, no result`, `info` báo `fault 1` | IP phát hiện lỗi trong lúc tính (mỗi lệnh làm hai lần không khớp): kết quả đã bị huỷ, khoá đã bị xoá, lỗi được đếm (`faults since power-on`). Gõ `clear` rồi `key` lại. Lặp lại thường xuyên: kiểm tra nguồn, clock, bitstream |
| `[nmi] fatal alert: MKV locked itself after 4 faults`, `info` báo `locked 1` | đủ `FaultLimit` lỗi từ lúc bật nguồn (hoặc bộ đếm bị sửa, hoặc một `TEST` không gây `FAULT`): IP tự khoá, chỉ `CLEAR` còn chạy. Chỉ power-on reset gỡ được: MPS4 `tools/bow32_mps4.py reset` (hay `reboot`), KV260 nạp lại bitstream. Reset phần mềm và BREAK không gỡ |
| `mkv: power-on self-test FAIL: ...` | KAT hay `TEST` của `bow_mkv_selftest()` không qua: không nạp được khoá (`error: KEY failed: self-test not passed`). Bitstream hay IP hỏng; chạy `test` để biết mục nào sai |
| một mục `FAIL` / `verify: FAIL` | lỗi thật của IP hay driver: chạy `make -C hw/ip/mkv/dv test` và `make run TEST=mkv` để so lại trong mô phỏng |
