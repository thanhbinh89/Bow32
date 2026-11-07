# DDR2/DDR3 trên Arm MPS4: chạy thử `bow_ddr` (LiteDRAM + PHY Bow32)

Hướng dẫn build bitstream Bow32 có DDR ([ip/ddr.md](ip/ddr.md): controller LiteDRAM trên PHY
của Bow32) cho bo Arm MPS4 (HBI0376B, Virtex UltraScale+ XCVU13P), nạp qua thẻ microSD của
bộ điều khiển bo (MCC), chạy ứng dụng `sw/apps/ddr` và đối chiếu với mô hình trên PC. Vì sao
chọn MPS4 và bo RAM mở rộng hợp với bo nào: [ddr_board_review.md](ddr_board_review.md).

```
 PC: tools/bow32_ddr.py ──USB-C, cổng serial 1──► Ibex (sw/apps/ddr) ──bus──► bow_ddr
     (seed, đọc lại bằng dump,                     sw/common/litedram     0x4000_C000 CSR LiteDRAM
      so với mô hình Python)                       (DFII, hiệu chỉnh)     0x4000_E000 thanh ghi PHY
                                                                          0x8000_0000 cửa sổ
                                                       LiteDRAM (CK/4) ──DFI──► PHY: ODDRE1 / IDDRE1
                                                     30 chân bank 64/65 ◄──────┘ MMCM dịch pha
                                                     không nối gì (loopback)
                                                              │ IOB, IDDR đọc lại chính chân của FPGA
                                                     bow_ddr_lb: DRAM giả lập 4 MiB (UltraRAM),
                                                     kiểm tra mọi luật JEDEC (thanh ghi DBG)
```

Bo RAM mở rộng (`docs/fpga/ram_extension`) chưa sản xuất xong, nên bản build mặc định là
**loopback**: PHY lái chân thật của FPGA (ODDR, IOB, IDDR, MMCM dịch pha chạy như với DRAM
thật), còn một DRAM giả lập trong FPGA (`bow_ddr_lb`) trả lời lệnh qua đường loopback của
wrapper chân. Bản này không dùng khe FMC nên không cần đổi `FMC_FORCE`.

**Đã chạy trên bo ngày 2026-11-05** (bản cuối, sau review và ba vòng kiểm chứng): `test`
18/18, BIST của LiteDRAM ghi 233,7 MB/s, đọc 226,9 MB/s (đỉnh 266,7 MB/s), `verify` 30/30,
`eye` giữ dữ liệu, pha đọc/ghi giữ đúng qua `RESET` của MCC (chi tiết ở mục 4.6).

## 1. Build

```bash
make sw                                   # build/sw/ddr/ddr.bin + boot ROM
make fpga BOARD=mps4 FLASH_VMEM=$PWD/build/sw/ddr/ddr.vmem
```

`FLASH_VMEM` nạp sẵn ứng dụng `ddr` vào flash của bitstream: bật bo là boot ROM chạy luôn
ứng dụng. Kết quả ở `build/fpga/mps4/`: `bow32_mps4.bit`, các báo cáo và thư mục `sdcard/`
cho `tools/bow32_mps4.py` (mục 2; `sdcard/MB/HBI0376B/board.txt` chỉ dành cho thẻ riêng của
Bow32, không chép đè lên `board.txt` của thẻ dùng chung). Build mất 15–20 phút.

Kết quả build (Vivado 2025.2, 2026-11-05, bản cuối): đạt mọi ràng buộc timing, setup WNS
+0,537 ns, hold WHS +0,011 ns, 2/2 ràng buộc bus skew của FIFO đọc đạt, `tcl/timing_checks.tcl`
không báo gì (mỗi cặp clock có đúng loại ràng buộc: DFI giữa `ddr_sys` và `ddr_clk` được phân
tích đồng bộ, các cặp với `clk_sys` là `set_max_delay -datapath_only`; trong `report_cdc` chỉ
có 5 CDC-10 ở chân CLR của các bộ đồng bộ reset, như dự kiến). Các báo cáo riêng:
`ddr_dfi_paths.rpt`, `ddr_cdc_paths.rpt`, `cdc.rpt`, `ddr_write_paths.rpt`. Toàn bộ thiết kế:
39 712 LUT (2,3 %), 28 571 FF, 71 BRAM, 167 URAM (128 cho DRAM giả lập).

Bản cho bo RAM thật: `make fpga BOARD=mps4 DDR_LOOPBACK=0 FLASH_VMEM=...` (chân trên khe
FMC+, LVCMOS15, xem mục 6).

### Clock

`OSCCLKA[2]` = 100 MHz (bộ dao động OSC2 do MCC lập trình theo `sdcard/bow32.txt`) vào
`bow_ddr_clk_xusp`:

| MMCM | Đầu ra | Dùng cho |
|------|--------|----------|
| `MMCM_A` (VCO 1200 MHz) | `clk_sys` 50 MHz, `ddr_clk` 133,33 MHz, `ddr_sys_clk` 33,33 MHz, nguồn pha ghi (CLKOUT2, dịch pha ghi `WPS_GO`) | SoC; PHY, CK, lệnh; controller LiteDRAM (cạnh trùng cạnh của `ddr_clk`) |
| `MMCM_W` | `ddr_wclk` 0°, `ddr_wclk90` +90° (bám theo CLKOUT2 của `MMCM_A`) | DQS / DQ khi ghi |
| `MMCM_B` | `ddr_rd_clk` 133,33 MHz | IDDR đọc (dịch pha đọc `PS_GO`, 504 bước mỗi CK) |

Một MMCM mất lock thì `bow_ddr_clk_xusp` reset cả ba (pha đọc/ghi về 0, như bộ đếm pha của
IP). Vì `MMCM_A` cũng tạo `clk_sys`, trên MPS4 việc này reset luôn cả SoC (reset của SoC gồm
`locked_sys`): mất lock của MMCM DDR là lỗi phần cứng, sau đó firmware khởi động lại từ đầu.

LED: đèn trong nút **PB1** (`USER_nLED[8]`) nhấp nháy khi SoC chạy, đèn trong nút **PB2**
(`USER_nLED[9]`) sáng khi mọi MMCM đã lock (ba của DDR và hai của HyperRAM); 8 LED người dùng
là GPIO PA0..PA7.

Cùng bitstream có bộ điều khiển HyperRAM với cây clock riêng (BUFGCE riêng từ cùng IBUF của
`OSCCLKA[2]`, hai MMCM): [hyperram_mps4.md](hyperram_mps4.md). Cây clock DDR ở trên giữ
nguyên vị trí (`MMCM_B`, `MMCM_A`, `MMCM_W` ở vùng clock của chân và hai vùng phía trên).

## 2. Nạp bitstream qua thẻ microSD

MPS4 không có JTAG của Xilinx trên cáp USB: MCC nạp FPGA từ thẻ microSD lúc khởi động. Thẻ
hiện ra trên PC như một ổ USB (nhãn `M1SDP`) qua cổng USB-C của bo; console của MCC là cổng
serial 0 (115200 baud).

> Thẻ đang dùng chung với nhóm khác (ứng dụng `CA5DS\ca5ds.txt` → `fu3.bit`): chỉ đổi dòng
> `APPFILE` trong `MB/HBI0376B/board.txt`, giữ bản sao file gốc và trả lại sau khi thử.
> **Không sửa `config.txt`** (`UARTMODE: 0`, `FMC_FORCE: 1V2` là của họ; bản loopback chạy
> được với cấu hình đó).

Một lần (root): cho phép người dùng mount thẻ. `uid`/`gid` là của người dùng sẽ mount (`id`).

```bash
sudo mkdir -p /mnt/mps4
echo 'LABEL=M1SDP /mnt/mps4 vfat noauto,user,uid=1017,gid=1019,umask=022 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
```

### 2.1 Bằng `tools/bow32_mps4.py`

```bash
python3 tools/bow32_mps4.py deploy        # chép build lên thẻ, REBOOT bo, in console Bow32
python3 tools/bow32_mps4.py restore       # trả APPFILE về thiết kế của nhóm kia (sau khi thử xong)
```

| Lệnh | Việc làm |
|------|----------|
| `install [SDCARD]` | mount thẻ, chép `bow32.bit` + `bow32.txt` vào `MB/HBI0376B/BOW32/`, đổi `APPFILE` thành `BOW32\bow32.txt` (giữ chú thích và CRLF), umount |
| `deploy [SDCARD]` | `install` rồi `reboot` |
| `reboot` | `REBOOT` trên console MCC: MCC tắt bật nguồn, nạp FPGA từ thẻ (khoảng 60 giây), chờ `Releasing CB_nRST` rồi in console Bow32 (cổng 1) |
| `reset` | `RESET` trên console MCC: chỉ khởi động lại Bow32 qua `CB_nRST` (khoảng 1 giây), không nạp lại FPGA |
| `restore [--appfile X]` | trả thẻ về thiết kế đã chọn trước `install`: đặt lại dòng `APPFILE` theo bản đã giữ (hoặc chỉ đặt `APPFILE` = X) |
| `show` | mọi file trong `MB/` (cả thư mục của nhóm kia), toàn bộ `board.txt` và `config.txt` |

* `SDCARD` mặc định là `build/fpga/mps4/sdcard` (do `make fpga BOARD=mps4` tạo).
* Bản giữ: mỗi lần `install` thấy thẻ đang chọn thiết kế khác (`APPFILE` không phải
  `BOW32\bow32.txt`), nó chép `board.txt` lúc đó thành `MB/HBI0376B/BOW32/board.txt.orig`
  (ngay trên thẻ) và `~/.local/state/bow32/mps4/board.txt.orig`, nên bản giữ luôn theo cấu
  hình mới nhất của nhóm kia. Thẻ đã chọn `BOW32` thì giữ nguyên bản giữ cũ (thẻ không có bản
  nào thì cảnh báo; không có cả bản trên PC thì `restore` sẽ cần `--appfile`).
* `restore` dùng bản giữ trên thẻ, không có thì bản trên PC:
  * thẻ đang chọn `BOW32`: chỉ đổi dòng `APPFILE` về giá trị của bản giữ, các dòng khác để
    nguyên như hiện tại (nhóm kia sửa gì trong lúc đó vẫn còn);
  * thẻ đang chọn thiết kế khác: không ghi gì, báo `nothing to restore` (mã thoát 0);
  * `board.txt` hỏng (rỗng, không có dòng `APPFILE`, hoặc nhiều dòng trong đó có `BOW32`): lưu
    file hỏng thành `MB/HBI0376B/BOW32/board.txt.damaged`, rồi chép cả bản giữ **trên thẻ** đè
    lên (không dùng bản trên PC cho việc này: có thể là của phiên khác); nhiều dòng `APPFILE`
    mà không dòng nào là `BOW32`: không phải do công cụ, không ghi gì;
  * `--appfile X`: chỉ đặt dòng `APPFILE` = X (`board.txt` hỏng thì báo lỗi, không ghi gì).
* Giá trị `APPFILE` kết thúc ở khoảng trắng hoặc `;` (MCC coi `;` là bắt đầu chú thích, kể cả
  khi dính liền giá trị). File chỉ-đọc (`board.txt` bị đặt read-only) không bị thay: công cụ
  báo lỗi.
* Ghi an toàn: mỗi file được ghi ra `<tên>.new` cùng thư mục, `fsync`, rồi mới đổi tên đè lên
  file cũ; `bow32.bit` và `bow32.txt` được đọc lại so sánh trước khi thay, `board.txt` được sửa
  sau cùng. Lỗi giữa chừng (thẻ đầy, rút thẻ, Ctrl-C) để lại file cũ nguyên vẹn, thẻ vẫn khởi
  động thiết kế như trước (riêng lỗi rơi đúng giữa hai lần đổi tên `bow32.bit` / `bow32.txt`,
  rất hiếm, để lại bitstream mới với `bow32.txt` cũ: chạy `install` lại). Khi đó công cụ in `error: ...`, rồi một dòng trạng thái thẻ như
  `card: board.txt not changed, APPFILE CA5DS\ca5ds.txt`; không in traceback, mã thoát 1.
* Công cụ tự mount thẻ mà không thấy `MB/HBI0376B/board.txt` (không phải thẻ MPS4) thì umount
  lại trước khi báo lỗi. `umount` lỗi (ví dụ `target is busy`) trong lúc đang báo một lỗi khác
  chỉ là cảnh báo: lỗi gốc vẫn được in.
* Công cụ không bao giờ ghi `config.txt`.
* Cổng serial tự tìm trong `/dev/serial/by-id` (FT4232H, cổng 0 = MCC, cổng 1 = UART0 của
  Bow32); có nhiều bo thì chỉ rõ bằng `--mcc PORT --console PORT`. Thẻ đã mount sẵn ở chỗ khác:
  `--no-mount --mnt DIR`. `reboot`, `reset`, `deploy` cần `pyserial`.
* FPGA vẫn chạy Bow32 sau `restore`, tới lần `REBOOT` hay tắt bo kế tiếp.

### 2.2 Làm tay (cùng mô hình với công cụ)

```bash
mount /mnt/mps4
cd /mnt/mps4/MB/HBI0376B
grep '^APPFILE' board.txt                          # ghi lại giá trị của nhóm kia, vd. CA5DS\ca5ds.txt
mkdir -p BOW32 && cp board.txt BOW32/board.txt.orig  # bản giữ như công cụ (khi thẻ chưa chọn BOW32)
cp ~/Bow32/build/fpga/mps4/sdcard/MB/HBI0376B/BOW32/bow32.* BOW32/
# chỉ đổi dòng APPFILE (giữ CRLF và chú thích)
sed -i 's/^APPFILE:[ \t]*[^ \t;\r]*/APPFILE: BOW32\\bow32.txt/' board.txt
cd / && umount /mnt/mps4

picocom -b 115200 /dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_<số serial>-if00-port0
Cmd> REBOOT
```

MCC đọc `bow32.txt`, đặt OSC2 = 100 MHz, nạp `bow32.bit` rồi nhả reset (`Releasing CB_nRST`).
Trả lại: chỉ đặt lại dòng `APPFILE` về giá trị đã ghi (không chép cả file cũ đè lên: nhóm kia
có thể đã sửa các dòng khác trong lúc đó):

```bash
sed -i 's/^APPFILE:[ \t]*[^ \t;\r]*/APPFILE: CA5DS\\ca5ds.txt/' /mnt/mps4/MB/HBI0376B/board.txt
```

## 3. Kết nối

Bốn cổng serial của FT4232H trên cổng USB-C (Linux: `/dev/serial/by-id/...-if0N-port0`).
Với `UARTMODE: 0` (mặc định của Arm), MCC nối như sau, **đo trên bo** bằng một bitstream dò
chân (tên chân `_F` nhìn từ FPGA):

| Cổng | Nối với | Chân FPGA (TX / RX) |
|------|---------|---------------------|
| 0 (`if00`) | console MCC | — |
| 1 (`if01`) | **UART0 của Bow32** (boot ROM, ứng dụng), 115200 baud | `UART_TX_F<0>` AW7 / `UART_RX_F<0>` AV8 |
| 2 (`if02`) | UART1 của Bow32 (PB0/PB1) | AY7 / BB7 (`F<2>`) |
| 3 (`if03`) | không dùng | AY8 / BA7 (`F<3>`) |

UART1 của FPGA (`UART_x_F<1>`, AW8/AV9) không tới cổng nào ở chế độ này (câu "Serial Port 1
is connected to the FPGA UART1" trong TRM dễ gây hiểu nhầm).

```bash
python3 tools/bow32_flash.py -p /dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_<số serial>-if01-port0 monitor
```

```
Bow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1
boot: waiting 300 ms for host
boot: starting image @08000020 (35620 bytes)

Bow32 DDR2/DDR3 test (sw/apps/ddr, LiteDRAM controller), type h for help
ddr: Bow32 DDR2 x8 (LiteDRAM controller), PHY loopback, 133 MHz (133333333 Hz), 504 phase steps, emulator 4096 KiB
>
```

FT4232H gửi được BREAK nên `bow32_flash.py flash` nạp lại ứng dụng khác mà không cần build
lại bitstream (flash của FPGA mất khi tắt bo; bật lại là về ứng dụng `ddr` đã nạp sẵn).

## 4. Kiểm chứng

Các lệnh dưới đây dùng `PORT=/dev/serial/by-id/...-if01-port0`.

### 4.1 Self-test

```bash
python3 tools/bow32_ddr.py -p $PORT test            # --quick: bản rút gọn (mô phỏng chạy bản này)
```

Kết quả trên bo (2026-11-05, bản cuối):

```
ddr: self-test (full, seed 1)
  [ 1] IP present: ID, INFO, CLK_HZ, link, DDR clock, LiteDRAM CSRs   ok
  [ 2] refused: 2 CMD bits, window while not READY, CSRs in CORE_RST  ok
ddr: init DDR2 (LiteDRAM core: CL 3 CWL 2, controller 33333333 Hz), CK 133333333 Hz, CTRL 000008c1 LAT 22240083
ddr: init sequence: {CKE ODT RESET_N} PREA MR3=0000 MR2=0000 MR1=0000 MR0=0333 PREA REF REF
ddr:   MR0=0233 MR1=0380 MR1=0000
ddr: init done, LiteDRAM refresh on (DFII hardware control), not handed over
  [ 3] init: LiteDRAM JEDEC sequence over DFII, controller refresh    ok
ddr: eye |rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr.....qqqqqqqqq
          qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
          qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq.....ppppppppppp
          pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp| phase 230 width 242 p 26
ddr: read phase 230 width 242 p 26 RD_DLY 9 SLIP 0, BIST 0 errors
  [ 4] read calibration: eye, RD_DLY / RD_SLIP, verify, hand-over     ok
  [ 5] window: walking ones / zeros on the data bits                  ok
  [ 6] window: address lines (unique word at 0 and every 2^k)         ok
  [ 7] window: address in address, inverted                           ok
  [ 8] window: byte / halfword stores (read-modify-write), ST_RMW     ok
  [ 9] window: xorshift fill / check                                  ok
  [10] window: beyond the DRAM size: bus error, RANGE, ERR_ADDR       ok
  [11] BIST: LiteDRAM generator + checker, PRBS and counter data      ok
  [12] BIST data read through the window = C twin, neighbours kept    ok
  [13] BIST errors: PRBS check of counter data, one window store      ok
  [14] refresh: data kept while idle, ST_REF counts the REF commands  ok
  [15] eye sweep after the hand-over: phase, READY, data kept         ok
  [16] limits: PS_GO / WPS_GO beyond the limits refused               ok
  [17] interrupt: APPLIED on irq_fast[11]                             ok
  [18] no RFIFO / bus / PS / RD_LATE / CSR error, DBG model ok        ok
ddr: PASS (18/18)
```

### 4.2 Hiệu chỉnh và mắt đọc

```bash
python3 tools/bow32_ddr.py -p $PORT cal --step 2      # + --write: quét pha ghi bằng BIST (không cho loopback)
python3 tools/bow32_ddr.py -p $PORT eye --step 1
```

Mỗi ký tự của dòng `eye` là một pha của `rd_clk` (từ 0 tới 1 CK): cùng một chữ = mẫu P xuất
hiện ở cùng vị trí p trong luồng mẫu, `.` = không tìm thấy. Phần mềm chọn giữa dải dài nhất
rồi đặt `RD_DLY = p/2 - 4`, `RD_SLIP = p mod 2`. Ở bản loopback, dữ liệu đi qua IOB của
chính FPGA nên mắt rộng gần nửa chu kỳ CK (240–248 / 504 bước đo được); pha MMCM lúc bật nguồn
không cố định nên `phase` khác nhau giữa các lần bật.

### 4.3 Ngẫu nhiên, so với mô hình trên PC

```bash
python3 tools/bow32_ddr.py -p $PORT verify -n 40 --seed 2026
```

Mỗi case là một BIST của LiteDRAM (generator ghi, checker đọc) hoặc một memtest của CPU qua
cửa sổ, với seed sinh trên PC; sau đó `dump` đọc lại vùng nhớ và từng byte được so với giá trị
tính bằng Python (bản Python của bộ sinh dữ liệu BIST của LiteDRAM, đã đối chiếu với mô phỏng
Migen của chính LiteDRAM): kiểm tra này không dựa vào phần mềm chạy trên bo.

### 4.4 Băng thông

```bash
python3 tools/bow32_ddr.py -p $PORT bench
```

BIST đo băng thông của controller (đỉnh x8 ở CK 133,33 MHz: 266,7 MB/s); CPU đọc/ghi qua cửa
sổ chậm hơn nhiều vì mỗi truy cập là một giao dịch 32 bit qua hai miền clock và độ trễ đọc cố
định của LiteDRAM (12 chu kỳ controller = 360 ns).

### 4.5 Gõ lệnh trực tiếp

```
> info
> init
> cal
> bist 0 65536 prbs           offset 0, 64 KiB, dữ liệu PRBS
> memtest 0 65536 3
> wr 80001234 cafef00d
> rd 80001234
> cap                         một RD bằng DFII + chụp thô 32 chu kỳ
> stat
```

`h` in danh sách lệnh đầy đủ; mọi định dạng đầu ra nằm ở đầu `sw/apps/ddr/main.c`.

### 4.6 Kết quả trên bo (2026-11-05)

| | Bản LiteDRAM (hiện tại) | Bản v1 (controller tự viết), cùng PHY và bo |
|---|---|---|
| Self-test | 18/18 (hai lần, lần hai sau `RESET` của MCC) | 18/18 |
| Mắt đọc (bước / 504) | 240–248 | 244 |
| `RD_DLY` / `RD_SLIP` | 8 / 1, 9 / 0 hoặc 9 / 1 (tuỳ pha MMCM lúc bật) | 9 / 1 |
| BIST ghi / đọc | 233,7 / 226,9 MB/s, 0 lỗi | 263,5 / 263,5 MB/s, 0 lỗi |
| CPU đọc / ghi word qua cửa sổ | 5,0 / 3,6 MB/s | 12,1 / 11,3 MB/s (có buffer đọc 1 burst) |
| `verify` | 30/30 | 20/20 |

Hai kiểm tra thêm của bản cuối:

* `eye 8` sau khi ghi 16 byte ở đầu cửa sổ (`0x8000_0000`..`0x8000_000F`): đọc lại đúng cả
  16 byte, `STATUS.READY` vẫn 1.
* `wphase 100`, rồi `RESET` của MCC (reset SoC, MMCM vẫn chạy): sau khi Bow32 khởi động lại,
  `WPS_NOW` = 100 và `PS_NOW` = 478 như trước reset (đúng pha thật của MMCM), `STATUS` không
  có cờ lỗi (FIFO đọc được khởi động lại sau reset không báo `RFIFO_ERR`), `wphase 126` được
  nhận, `wphase 127` bị từ chối (giới hạn ±T/4 tính từ pha 0 thật), self-test lại 18/18.
* `restore`: `board.txt` của thẻ giống từng byte bản của nhóm kia trước `install`.

Hai bản dùng chung PHY, chân, clock và DRAM giả lập: mắt và `RD_DLY` như nhau. CPU qua cửa sổ
chậm hơn ở bản LiteDRAM vì controller chạy ở CK/4 với độ trễ đọc cố định và cầu bắt tay qua
miền clock của nó.

## 5. Mô phỏng trước khi lên bo

```bash
make run TEST=ddr                 # SoC + mô hình clock/pad + DRAM giả lập, ~1 phút
make -C hw/ip/ddr/dv test         # testbench IP: loopback, bo RAM (level shifter), DDR3, stub
make test-fpga-dv                 # xsim với UNISIM: wrapper chân, MMCM (cả ddr_sys_clk)
```

`make run TEST=ddr` dựng đúng cấu hình của bản loopback (x8, 133,33 MHz, 504 bước pha, DRAM
giả lập 4 MiB), chạy `test quick` và kiểm tra `DBG` của DRAM giả lập.

## 6. Bo RAM thật (khi đã sản xuất)

* Build: `make fpga BOARD=mps4 DDR_LOOPBACK=0 FLASH_VMEM=...` (chân `constr/ddr_card.xdc`).
* `config.txt`: `FMC_FORCE: 1V5` (VADJ của khe FMC+ = 1,5 V cho TXV0108). Thẻ đang để `1V2`
  cho thiết kế của nhóm khác: hỏi trước khi đổi.
* Sửa các điểm của [ddr_board_review.md](ddr_board_review.md) trước khi đặt mạch (đặc biệt
  ngưỡng DIR/OE của TXV0108 và DM nối GND).
* Hiệu chỉnh cả pha ghi: `bow32_ddr.py cal --write`.

## 7. Sự cố

| Hiện tượng | Nguyên nhân thường gặp |
|------------|------------------------|
| Cổng `if01` im lặng hoàn toàn | console không nằm ở `UART_TX_F<0>`/`UART_RX_F<0>`, hoặc `config.txt` không phải `UARTMODE: 0`; đèn PB1 nhấp nháy là SoC vẫn chạy |
| Boot ROM không in gì, `RESET` của MCC không giúp | SoC ra khỏi reset trước khi MCC bật UART: đường RX thấp bị hiểu là BREAK, ROM vào loader. Top MPS4 giữ reset theo `CB_nRST` để tránh |
| `ddr: DDR clock not running` | MMCM chưa lock (đèn PB2 tắt): OSC2 không phải 100 MHz trong `bow32.txt` |
| `ddr: IP not found (stub ...)` | bitstream của bo khác (`DdrEn = 0`) |
| `ddr: IP not found (ID 44445201...)` | bitstream bản v1, firmware này cần bản LiteDRAM |
| cửa sổ trả lỗi bus | chưa `init` / `cal` (`STATUS.READY` = 0), hoặc cầu đã chết (`BROKEN`): `CORE_RST` rồi bàn giao lại ([ip/ddr.md](ip/ddr.md)) |
| `calibration failed: RD_LATE` | `RD_DLY` vượt ngân sách đọc của bộ chuyển DFI |
| `DBG` báo lỗi | DRAM giả lập thấy vi phạm JEDEC: mã lỗi trong `bow_ddr_dev.sv` |
