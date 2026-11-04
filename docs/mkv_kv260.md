# Mã khối MKV trên Kria KV260: kiểm chứng IP `bow_mkv`

Hướng dẫn nạp bitstream có khối mật mã MKV ([ip/mkv.md](ip/mkv.md)), chạy ứng
dụng kiểm thử `sw/apps/mkv` và đối chiếu kết quả của phần cứng với dự thảo
TCVN XXXX:2024 (Phụ lục A) và với mô hình Python trên PC:

```
 PC: tools/bow32_mkv.py ──UART0──► Ibex (sw/apps/mkv) ──bus──► MKV IP 0x4000_B000
     + tools/mkv/mkv_model.py      │  mkv_sw.c: MKV phần mềm        KEY / ENC / DEC
       (so sánh)                   │  mkv_vectors.h: Phụ lục A      irq_fast[10]
                                   └─► "mkv: PASS (11/11)", "out <hex>"
```

> **Kết quả trên KV260 (2026-11-04):** bitstream `kv260_cam` (Vivado 2025.2) đạt
> timing (setup WNS +0,032 ns ở clock video 200 MHz, hold +0,010 ns; mọi đường
> qua MKV ở 50 MHz còn ≥ +4,7 ns); MKV 7 533 LUT (148 LUTRAM), 1 956 FF; toàn bản
> 33 300 LUT (28 %). Bản `kv260` cũng đạt: WNS +6,005 ns, 31 300 LUT. Trên board:
> `test` **PASS (11/11)** (20 khoá ngẫu nhiên mỗi phiên bản), `kat` 6/6 bản mã
> trùng Phụ lục A, `verify` 120 khoá ngẫu nhiên / **360/360 khối** trùng mô hình
> Python; IP nhanh hơn MKV phần mềm trên Ibex 110…330 lần mỗi khối.

## 1. Build

```bash
make sw                           # build/sw/mkv/mkv.bin (+ boot ROM, các app khác)
make fpga BOARD=kv260_cam         # hoặc BOARD=kv260 (không camera): cả hai đều có MKV
```

MKV nằm trong `bow32_top` nên có trong cả hai bitstream; MKV không cần camera.
Trên máy build hiện tại mỗi bitstream mất ~7 phút. Lưu ý: `make -C sw/apps/mkv`
chỉ build `.elf`; dùng `make sw` hoặc `make -C sw/apps/mkv all` để có `.bin`.

## 2. Nạp bitstream

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

## 3. Nạp ứng dụng `mkv`

```bash
python3 tools/bow32_flash.py -p /dev/ttyACM0 --no-break flash build/sw/mkv/mkv.bin
```

```
image: 15284 bytes payload, entry 0x08000020, crc 0x01188d48
erasing 0x08000000 .. 0x08003bd3
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

### 4.1 Self-test trên board

```bash
python3 tools/bow32_mkv.py -p /dev/ttyACM0 test          # --quick: 1 khoá / phiên bản
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
  [ 9] CLEAR: key schedule, DIN, DOUT zeroed                      ok
  [10] interrupt DONE / ERR on irq_fast[10]                       ok
  [11] bus stall: CMD during KEY, DOUT during ENC                 ok
mkv: PASS (11/11)
```

Mục [2] kiểm tra MKV phần mềm (`sw/apps/mkv/mkv_sw.c`) với **khoá vòng và bản mã
in trong Phụ lục A**; [3], [4] chạy 6 véc tơ trên IP (cả `STATUS.ROUNDS`,
`CYCLES` = 2R + 2); [5] so IP với phần mềm trên khoá/khối ngẫu nhiên. Ý nghĩa
từng mục: [ip/mkv.md](ip/mkv.md#kiểm-chứng). Đổi seed: `test --seed 7`.

### 4.2 Véc tơ của chuẩn

```bash
python3 tools/bow32_mkv.py -p /dev/ttyACM0 kat
```

```
A.1.1 MKV-128/128 R=6
  key 0102030405060708090a0b0c0d0e0f11
  pt  112233445566778899aabbccddeeff00
  ct  b331228334c3f81a37206591498756a1  ok
...
A.2.3 MKV-256/512 R=8
  key 0102030405060708090a0b0c0d0e0f1112131415161718191a1b1c1d1e1f2223...
  pt  112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00
  ct  93b442fb88d257fbe71256be511aab9b1f71a4dd524635a61019a12acb262c85  ok
kat: PASS (6 versions, ciphertexts equal Annex A)
```

Tool so bản mã của board với giá trị trích từ PDF (`tools/mkv/tcvn_mkv_vectors.json`).

### 4.3 Ngẫu nhiên, so với mô hình trên PC

```bash
python3 tools/bow32_mkv.py -p /dev/ttyACM0 verify -n 120 --seed 2026
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
python3 tools/bow32_mkv.py -p /dev/ttyACM0 enc 128 000102030405060708090a0b0c0d0e0f 00112233445566778899aabbccddeeff
board 77ee73e973cbf02fe33809d88d852da6
model 77ee73e973cbf02fe33809d88d852da6  ok
```

### 4.4 Tốc độ

```bash
python3 tools/bow32_mkv.py -p /dev/ttyACM0 bench
```

```
version       key schedule (cycles)    one block (cycles)   ECB, 64 blocks
                   IP         SW         IP         SW     cycles/block    KB/s
MKV-128/128       234     104922        207      23578              124    6451
MKV-128/192       311     122271        209      27416              124    6451
MKV-128/256       378     139666        211      31226              124    6451
MKV-256/256       350     332910        311      78902              228    7017
MKV-256/384       485     388307        313      91816              228    7017
MKV-256/512       610     443370        315     104450              228    7017
```

Chu kỳ CPU ở 50 MHz, gồm cả driver. Lõi IP chỉ cần 8R + 1 chu kỳ cho lược đồ
khoá và 2R + 2 cho một khối (`CYCLES`); phần còn lại là CPU ghi `KEY`/`DIN` và
đọc `DOUT` qua bus.

### 4.5 Gõ lệnh trực tiếp

```bash
python3 tools/bow32_flash.py -p /dev/ttyACM0 monitor     # hoặc picocom -b 115200 /dev/ttyACM0
```

```
> key 256 0102030405060708090a0b0c0d0e0f1112131415161718191a1b1c1d1e1f2223
key MKV-256/256 R=6 (49 cycles)
ok
> enc 112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00
out cf2f2c1008186a578fe5b45dbd154473940c2bec5682cdf83a3564a72db0161b
ok
> info
MKV ID 4d4b5601 INFO 00000203 CTRL 00000001 STATUS 00000616 (busy 0 key 1 done 1 err 0, R 6, MKV-256)
ok
```

`h` liệt kê lệnh: `test [quick] [seed]`, `kat`, `key <l> <hex>`, `enc <hex>`,
`dec <hex>`, `bench`, `clear`, `info`, `rd`/`wr`, `baud`.

## 5. Khi có lỗi

| Hiện tượng | Nguyên nhân / cách xử lý |
|------------|--------------------------|
| `cannot reach the boot ROM loader` | board đang chạy ứng dụng: `wr 40000010 4c4f4144`, `wr 4000000c 52535421` (mục 3), hoặc nạp lại bitstream |
| `mkv: IP not found (ID 00000000)` | bitstream cũ (trước MKV): build lại `make fpga` từ nhánh này |
| `timeout` của `bow32_mkv.py` | sai cổng / baud (ứng dụng khác để UART0 ở 921600: thêm `-b 921600`), hoặc adapter đã đổi tên (`ls /dev/ttyACM*`) |
| một mục `FAIL` / `verify: FAIL` | lỗi thật của IP hay driver: chạy `make -C hw/ip/mkv/dv test` và `make run TEST=mkv` để so lại trong mô phỏng |
