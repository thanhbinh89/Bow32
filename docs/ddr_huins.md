# DDR2 / HyperRAM trên Huins MFP-VP1902: chạy `bow_ddr` với bo RAM thật

Hướng dẫn build device image (PDI) Bow32 có DDR ([ip/ddr.md](ip/ddr.md)) và HyperRAM
([ip/hyperram.md](ip/hyperram.md)) cho bo Huins MFP-VP1902-S (AMD Versal Premium
`xcvp1902-vsva6865-2MP-e-S`), với bo mở rộng FMC+_DDR2_HyperRam ([fmc_ram_card_review.md](fmc_ram_card_review.md),
[ddr_board_review.md](ddr_board_review.md)) cắm ở khe **FMC+10**. Image nạp qua USB JTAG của
bo, chạy ứng dụng `sw/apps/ddr` / `sw/apps/hyperram` và đối chiếu với mô hình trên PC như trên
MPS4 ([ddr_mps4.md](ddr_mps4.md)).

```
 PC: tools/bow32_ddr.py ──USB-C "UART0" (CP2102N)──► Ibex (sw/apps/ddr) ──bus──► bow_ddr / bow_hyperram
     tools/bow32_flash.py                             clock 50 MHz               LiteDRAM (CK/4) ──DFI──► PHY
 PC: vivado (make jtag) ──USB-C "USB JTAG"──► PMC: nạp PDI                         ODDRE1 / IDDRE1 trong XPIO
                                                                                   bank 708/709/710 (SLR0)
 200 MHz cố định (bank 718, SLR3) ─IBUFDS─BUFG──► 4 MMCME5 ở SLR0 ──► 53 chân FMC+10 ──► TXV0108 ──► DDR2 x8
                                                                                        └──► HyperRAM
```

Tài liệu của Huins (user guide, schematic, netlist trong `docs/fpga/Huins_MFP-VP1902/`) ghi
là tài liệu mật: thư mục đó bị `.gitignore` và **repo không chứa số chân FPGA nào của Huins**.
`hw/fpga/huins_vp1902/constr/pins.txt` chỉ ghi cổng → tên net của bo; lúc build,
`tools/huins_pins.py` tra netlist trong bản sao cục bộ và sinh file XDC chân vào
`build/fpga/huins_vp1902/` (không bao giờ commit file này).

## 1. Chuẩn bị bo

**Không bao giờ cấp nguồn cho bo RAM khi VADJ của khe dưới 1,5 V.** DIR và OE# của các TXV0108
trên bo RAM tham chiếu phía bộ nhớ 1,8 V (VIH 1,26 V): ở VADJ 1,0 / 1,2 V FPGA không lái nổi các
chân này, hướng của level shifter không xác định và bộ nhớ có thể lái ngược với FPGA
([fmc_ram_card_review.md](fmc_ram_card_review.md) mục 1, #2). Vì vậy kiểm tra VADJ **trước** khi
cắm bo, trong hai lần bật nguồn:

**Lần 1, chưa cắm bo RAM:**

| Việc | Đặt | Vì sao |
|------|-----|--------|
| Slide switch **SW196** (VCCIO của khe FMC+10) | vị trí "2" = **1,5 V** (mặc định của Huins) | xem trên. Không dùng vị trí "1" (không có trong tài liệu) |
| DIP **SW1** của main board (boot mode) | cả 4 cần **OFF** (`0000` = JTAG) | PDI nạp qua JTAG; mode được đọc lúc bật nguồn |
| **SW12** của main board | **OFF** (dao động 200 MHz, không phải đầu U.FL) | clock vào của bản build (`CLK_SRC=ref200`) |
| Cáp | USB-C "USB JTAG" và USB-C **"UART0"** (mặt trước) vào máy build | console của Bow32 là bridge CP2102N của "UART0" |

Bật nguồn (công tắc ATX phía sau ON, rồi nút "PWR SW" phía trước). Kiểm tra: các LED power good
(user guide hình 10), LED **"F 10"** sáng, cạnh SW196 **chỉ** LED **"1.5"** sáng (có thể đo
VADJ ở test point TP959). Tắt nguồn (nút trước, rồi công tắc sau).

**Lần 2:** cắm bo RAM vào **FMC+10** khi bo tắt (kiểm tra cơ khí: bo dài ~84 mm, review N2),
bật nguồn lại, kiểm tra lại LED "F 10" / "1.5" và các LED nguồn của bo RAM.

Khe khác (`FMC_SITE`, mục 2) có slide switch riêng: FMC+01 SW192, FMC+10 SW196, FMC+02 SW193,
FMC+20 SW197, FMC+03 SW194, FMC+30 SW198, FMC+04 SW195, FMC+40 SW199 (FMC+20 còn cấp nguồn cho
bank của các DIP switch người dùng).

**Khi bo chuyển camera ở FMC+01** ([camera_huins.md](camera_huins.md) mục 2, bảng "Bo nào ở khe
nào"): SW192 ở 1,2 V và LED11 / PB5 không phân biệt bo camera với bo RAM.

* Không bao giờ nạp PDI bo RAM build với `FMC_SITE=1` khi bo chuyển camera đang cắm: bản đó lái
  9 đầu ra vào chân FMC+01 mà bo chuyển nối tới module camera (hai data lane MIPI, SCL, XCE, cuộn
  của bộ lọc hồng ngoại...). PDI bo RAM cho FMC+10 (mặc định) thì được.
* Chuyển bo RAM lên FMC+01: tháo bo chuyển camera, đặt SW192 về "2" (1,5 V), bật nguồn khi chưa
  cắm bo và kiểm tra chỉ LED "1.5" sáng, TP29 ≈ 1,5 V, tắt nguồn rồi mới cắm bo RAM (quy tắc
  VADJ ≥ 1,5 V ở trên). Không bao giờ nạp PDI camera khi bo RAM ở FMC+01.
* `make jtag` in khe mà PDI được build cho và từ chối PDI bo RAM cho FMC+01 trừ khi
  `CONFIRM=1` (mục 3).

Không cần đụng DIP của clock module (đội FPGA đang để 16 MHz, bản build không dùng nó),
SW209, SW3/SW4/SW5 (mode của các SLR phụ), SW30/SW208 (để ON).

## 2. Build

Cần: Vivado 2025.2 có part `xcvp1902` (license), MicroBlaze GCC của chính Vivado (Vivado tự
build PLM của image), RISC-V GCC (`riscv-none-elf-` / `riscv32-unknown-elf-`), Python 3 có
`openpyxl` (đọc netlist) và bản sao tài liệu Huins.

```bash
make sw                                                     # boot ROM + ứng dụng
make fpga BOARD=huins_vp1902                                # = make -C hw/fpga/huins_vp1902
# tài liệu Huins ở chỗ khác (ví dụ worktree khác):
make -C hw/fpga/huins_vp1902 HUINS_DOCS=$HOME/Bow32/docs/fpga/Huins_MFP-VP1902
```

| Biến | Mặc định | Ý nghĩa |
|------|----------|---------|
| `CLK_SRC` | `ref200` | `ref200`: dao động 200 MHz cố định của main board (C2_DDR4_SYS_CLK, bank 718; trên bo: tụ ghép AC, 100 Ω giữa P/N, bias 6,81k / 2k; trong FPGA: `DIFF_SSTL12` với ODT 40 Ω, đưa chế độ chung về ~0,53 V, gần Vref 0,6 V). `site` (clock PL của khe qua CDCUN1208) **bị build từ chối**: bo chỉ ghép AC, FPGA phải tự bias đầu vào `LVDS15` mà mã `DC_BIAS` đúng chưa được kiểm (`DC_BIAS_0` = không bias), và clock module đang để 16 MHz (mục 6) |
| `FMC_SITE` | `10` | số khe trong tên net của bo: 1, 10, 2, 20, 3, 30, 4, 40 (silk FMC+01, FMC+10, ...). FMC+01 cũng là khe của bo chuyển camera: mục 1 |
| `DDR_LOOPBACK` / `HR_LOOPBACK` | `0` | `1`: DRAM / HyperRAM giả lập trong FPGA trả lời qua cùng các chân, level shifter cô lập (OE# = 1): bản thử khi chưa muốn đụng bộ nhớ |
| `JOBS` | `2` | mỗi lần chạy Vivado trên xcvp1902 cần ~15 GB RAM |
| `FLASH_VMEM` | | nạp sẵn một ứng dụng vào flash |

Kết quả trong `build/fpga/huins_vp1902/`: `bow32_huins_vp1902.pdi`, các báo cáo
(`timing_summary.rpt`, `clock_interaction.rpt`, `cdc.rpt`, `io_sites.rpt`, ...). Build kiểm
tra: timing, ràng buộc của mọi cặp clock (`tcl/timing_checks.tcl`, như MPS4), bus skew của
các con trỏ gray, mọi `ODDRE1`/`IDDRE1` nằm trong `XPIOLOGIC` của chân và đủ 19 ODDR lái T.

Vivado tự thêm một `ps_wizard` (PMC mặc định) vào netlist chỉ có PL và build PLM bằng
MicroBlaze GCC kèm Vivado (Lopper); trên hw-station-1 bước này chạy được (trên hw-station-2
thì `mb-gcc` thiếu `libkrb5support.so.0`).

### Clock và reset

| Clock | Tần số | Nguồn |
|-------|--------|-------|
| `clk_sys` | 50 MHz | MMCM_A của `bow_ddr_clk_versal` (VCO 3200 MHz = 200 × 16) |
| `ddr_clk` | 133,333 MHz | MMCM_A (CK, lệnh, PHY) |
| `ddr_sys` | 33,333 MHz | MMCM_A (LiteDRAM, CK/4, cạnh lên trùng `ddr_clk`) |
| `ddr_wclk` / `ddr_wclk90` | 133,333 MHz | MMCM_A, dịch pha động (pha ghi), `wclk90` thêm 90° tĩnh |
| `ddr_rd_clk` | 133,333 MHz | MMCM_B, dịch pha động (pha đọc) |
| `hr_clk` / `hr_wclk` / `hr_rd_clk` | 100 MHz | `bow_hyperram_clk_versal`: MMCM_H (270° / pha ghi), MMCM_R (pha đọc) |

Cùng tần số với MPS4 nên mọi ràng buộc và hằng số firmware giữ nguyên. Khác MPS4:

* **MMCME5** thay MMCME4: bước dịch pha = 1/32 chu kỳ VCO (9,77 ps), **768 bước mỗi CK**
  của DDR, **1024** của HyperRAM (firmware đọc ở `PS_NOW[31:16]`, không phải sửa). MMCME5
  cho phép một đầu ra vừa có pha tĩnh vừa dịch pha động, nên DDR chỉ cần 2 MMCM (MPS4: 3,
  có tầng MMCM_W).
* **T trong site của chân** (XPIO, DRC PDCN-2749): mỗi chân hai chiều có thêm một `ODDRE1`
  lái T (`TFromOddr = 1` của `bow_ddr_io_xilinx` / `bow_hyperram_io_xilinx`), cùng clock với
  ODDR dữ liệu; driver DQ / RWDS bật/tắt ở (j+1,25)T + pha ghi, DQS ở (j+1)T + pha ghi. Với
  cửa sổ mặc định của firmware (`OE_PRE` 1, `OE_POST` 2, `RDIR_LEAD` 2, `RDIR_TAIL` 2) vẫn
  còn ≥ 3,75 ns trước khi DIR quay sang đọc và ≥ 15 ns sau khi DIR quay lại ghi.
* **Tầng nửa chu kỳ của DQS chạy trên cạnh xuống của `ddr_wclk`** (MPS4: của `ddr_clk`). Trên
  xcvp1902 clock tới flop fabric muộn hơn tới ODDR trong XPIO ~1 ns, nên đường flop → ODDR
  với độ bất định T/4 của pha ghi hụt 0,5–0,75 ns; bước qua miền clock giờ nằm giữa hai flop
  fabric (cây clock của `ddr_clk`, `ddr_sys`, `ddr_wclk`, `ddr_wclk90` cùng một
  `CLOCK_DELAY_GROUP`), còn tầng → ODDR là đường T/2 trong cùng `ddr_wclk`.
* **Bốn SLR**: clock 200 MHz vào ở SLR3, các chân của khe FMC+10 ở SLR0, UART/reset (bank 408)
  ở SLR3, LED (bank 812) ở SLR2. `tcl/pre_place.tcl` đặt 4 MMCM vào SLR của các chân bo RAM,
  clock vào đi qua mạng clock toàn cục sang SLR đó.

Reset SoC = `USER_RESET_N` (nút "H_RESET" mặt trước, qua TPS3808, ~130 ms) AND MMCM_A khoá.
Các MMCM tự khoá sau khi nạp image; mất khoá thì cả hai MMCM của mỗi khối được reset (pha về 0).

## 3. Nạp image qua JTAG

```bash
make fpga-jtag BOARD=huins_vp1902                          # = make -C hw/fpga/huins_vp1902 jtag
make -C hw/fpga/huins_vp1902 jtag JTAG_SERIAL=210357B8AC4E # khi có nhiều cáp
```

`tcl/jtag.tcl` mở hardware manager (hw_server cục bộ, cổng 3121), chọn target có
`xcvp1902`, nạp `bow32_huins_vp1902.pdi`. Chuỗi JTAG chỉ thấy khi bo đã bật (VREF của module
Digilent là 1,8 V của bo). Sau khi nạp: LED xanh "PS_DONE" sáng, LED đỏ "PS_ERR" tắt.
Image mất khi tắt bo.

`make pdi` ghi cạnh PDI file `pdi_site.txt` (`CARD`, `FMC_SITE`, `CLK_SRC`, `DDR_LOOPBACK`,
`HR_LOOPBACK`; xoá khi một lần build bắt đầu, ghi khi build xong). Trước khi nạp, `make jtag` in
file đó và bo phải cắm, ví dụ:

```
jtag: bow32_huins_vp1902.pdi was built with CARD=ram FMC_SITE=10 CLK_SRC=ref200 DDR_LOOPBACK=0 HR_LOOPBACK=0
jtag: fit: the FMC+_DDR2_HyperRam card on FMC+10 (site VCCIO 1.5 V);
jtag:      no camera adapter on FMC+10
```

Nó từ chối (`jtag: refused: ...`) PDI không có file này (khe không rõ, ví dụ PDI dựng trước khi
có khoá: build lại), PDI mới hơn file này (build bằng cách khác, ví dụ Makefile của nhánh khác
trong cùng thư mục build: file là của image trước), file của bản camera (`CARD=cam`), và PDI bo
RAM cho FMC+01 (lái chân mà bo chuyển camera nối tới module, mục 1). Kiểm bo và switch xong mới
vượt bằng
`make -C hw/fpga/huins_vp1902 jtag CONFIRM=1` (hoặc `make fpga-jtag BOARD=huins_vp1902
CONFIRM=1`).

## 4. Kết nối

Console: CP2102N của cổng "UART0", 115200 baud. BREAK của bridge này không đưa SoC về boot
loader (trên hw-station-1): đổi ứng dụng bằng thanh ghi rồi `bow32_flash.py --no-break flash`,
mục 6 "Nạp lại ứng dụng khi không gửi được BREAK".

```bash
PORT=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_<số serial>-if00-port0
python3 tools/bow32_flash.py -p $PORT monitor
```

| LED (mặt trước) | Nghĩa |
|-----------------|-------|
| U_LED1..8 | PA0..PA7 (GPIO, sáng khi chân là output 1) |
| U_LED9 | nhịp tim 1,5 Hz khi SoC đã ra khỏi reset |
| U_LED10 | cả 4 MMCM của DDR và HyperRAM khoá |
| U_LED11 | có bo ở khe FMC+ (`PRSNT_M2C_L` = 0) |
| U_LED12 | MMCM_A khoá (clock của SoC) |

GPIO: PB0/PB1 = UART1 (cổng "UART1"), PB2..PB4 = nút U_PB SW01..03 (1 khi nhấn), PB5 = có bo ở khe.

## 5. Kiểm chứng

Như MPS4 ([ddr_mps4.md](ddr_mps4.md) mục 4, [hyperram_mps4.md](hyperram_mps4.md)). Image không
có ứng dụng trong flash (trừ khi build với `FLASH_VMEM`, đường dẫn tuyệt đối: Vivado chạy trong
`build/fpga/huins_vp1902`): sau `make jtag` boot ROM in `boot: flash image invalid (no image)` và
chờ ở loader, nên lần nạp đầu không cần BREAK. Đổi ứng dụng sau đó: mục 6, "Nạp lại ứng dụng".

```bash
python3 tools/bow32_flash.py -p $PORT flash build/sw/ddr/ddr.bin   # loader đang chờ sau make jtag
python3 tools/bow32_ddr.py -p $PORT test                  # self-test 21 mục
python3 tools/bow32_ddr.py -p $PORT cal --step 2 --write  # hiệu chỉnh đọc + quét pha ghi
python3 tools/bow32_ddr.py -p $PORT eye --step 2
python3 tools/bow32_ddr.py -p $PORT verify -n 40 --seed 2026
python3 tools/bow32_ddr.py -p $PORT bench
# sang HyperRAM: về loader bằng thanh ghi (CP2102N không gửi được BREAK), rồi nạp
python3 tools/bow32_ddr.py -p $PORT cmd 'wr 40000010 4c4f4144' 'wr 4000000c 52535421'
python3 tools/bow32_flash.py -p $PORT --no-break flash build/sw/hyperram/hyperram.bin
python3 tools/bow32_hyperram.py -p $PORT test
```

(Lệnh `cmd` thứ hai reset SoC nên không có `ok`: công cụ chờ tới hết thời gian; có thể dừng
bằng Ctrl-C hoặc chạy với `timeout 20`.)

Khác bản loopback của MPS4: dữ liệu đi qua hai lần level shifter và DRAM thật, nên mắt đọc hẹp
hơn và pha ghi (`cal --write`) có ý nghĩa thật (lệch DQ/DQS giữa U5 và U9 của bo, review N1).

## 6. Kết quả trên bo

**2026-11-09, hw-station-1, bo RAM ở FMC+10, `CLK_SRC=ref200`** (build: WNS +0,579 ns, WHS
+0,021 ns; mọi kiểm tra clock / CDC / bus skew / vị trí XPIO đạt). Lần đầu IP DDR2 chạy với
chip DDR2 thật (trên MPS4 chỉ có bản loopback với bộ giả lập); HyperRAM đã chạy trên chip thật
ở khe FMC+ của MPS4 cùng ngày ([hyperram_mps4.md](hyperram_mps4.md) mục 5).

| | Kết quả |
|---|---|
| Nạp PDI qua JTAG | `xcvp1902_1`, DONE = 1, ~8 s; boot ROM in banner ở 115200 baud (clock SoC đúng 50 MHz từ dao động 200 MHz) |
| DDR2 `test` (đủ 21 mục) | **21/21**: JEDEC init qua DFII, mắt đọc **318 / 768 bước (41 % CK)**, pha 444–446, `RD_DLY` 11, `SLIP` 0 |
| DDR2 `cal --write` | mắt đọc 318 bước; cửa sổ ghi bằng BIST **392 / 768 bước (51 % CK)**: cả dải ±T/4 ghi đúng, pha ghi 0 |
| DDR2 `verify -n 40 --seed 2026` | **40/40** case bằng mô hình Python trên PC |
| DDR2 `bench` | BIST ghi 214,5 MB/s, đọc 214,2 MB/s (refresh 3,9 µs, đỉnh 266,7 MB/s), 0 lỗi; CPU qua cửa sổ: đọc 4,95 MB/s, ghi word (RMW) 3,61 MB/s |
| HyperRAM `test` | **19/19**: ID0 `0e86`, ID1 `0001`, CR0 `8fff`, latency 4 cố định (latency thay đổi bị từ chối vì có level shifter), mắt đọc **432 / 1024 bước**, `RD_DLY` 12, hybrid sleep, deep power down |
| HyperRAM `cal --write` | mắt đọc 434 / 1024 bước (pha 242); cửa sổ ghi 368 bước (dải ±3T/16), pha ghi 16 |
| HyperRAM `verify -n 40 --seed 2026` | **40/40** |
| HyperRAM `bench` | BIST ghi 188,1 MB/s, đọc 180,1 MB/s; CPU ghi posted 28,0 MB/s, đọc qua line buffer 20,6 MB/s |

Chưa thấy ảnh hưởng của lệch DQ/DQS giữa hai TXV0108 (review N1): ở CK 133 MHz cửa sổ ghi phủ
cả dải ±T/4 của pha ghi.

Image cuối (ODT 40 Ω của clock vào ghi rõ trong `constr/clk_ref200.xdc`, cùng cấu hình như
trên): WNS +0,579 ns, WHS +0,021 ns; nạp lại trên bo, DDR2 `test --quick` 21/21, mắt đọc 320 / 768
bước.

### Nạp lại ứng dụng khi không gửi được BREAK

Trên hw-station-1, `send_break` của bridge CP2102N (driver `cp210x`) không làm SoC reset vào
loader (`BRK_CTRL.EN` = 1, đường RX không xuống thấp). Từ ứng dụng đang chạy (`ddr`,
`hyperram` đều có `wr`), ghi `BOOT_FLAG` = "LOAD" rồi `RST_CTRL` = "RST!" (lệnh thứ hai
reset SoC nên không có `ok`), rồi nạp với `--no-break`:

```bash
python3 tools/bow32_ddr.py -p $PORT cmd 'wr 40000010 4c4f4144' 'wr 4000000c 52535421'
python3 tools/bow32_flash.py -p $PORT --no-break flash build/sw/hyperram/hyperram.bin
```

Hoặc nạp lại PDI (`make jtag`): boot ROM vào loader khi flash chưa có image.

### Clock của clock module

Theo đội FPGA, clock module của bo đang đặt **16 MHz** (CLK0..3, clock PL của các khe FMC+).
Bản build mặc định không dùng nó (`CLK_SRC=ref200`). Muốn dùng clock của khe ở 16 MHz thì
MMCM cần `ClkInPeriodNs` 62,5 và `VcoMult` 200 (VCO 3200 MHz, bộ so pha 16 MHz, trong dải của
MMCME5) và XDC `create_clock -period 62.500`; chưa có biến thể build này.

## 7. Sự cố

| Triệu chứng | Kiểm tra |
|-------------|----------|
| `make jtag`: không có target / không có xcvp1902 | bo chưa bật, cáp "USB JTAG", `hw_server` của người khác đang giữ cáp |
| `make jtag`: `jtag: refused: ...` | PDI không có `pdi_site.txt` hoặc mới hơn nó (build lại bằng `make pdi`), PDI của bản camera, hoặc PDI bo RAM cho FMC+01: kiểm bo / switch theo mục 1 rồi `CONFIRM=1` |
| không có gì trên console | cáp ở cổng "UART0" (không phải "UART1"), `PORT` đúng bridge, quyền nhóm `dialout`, LED9 nhấp nháy? |
| LED12 tắt | không có clock 200 MHz: SW12 phải OFF |
| LED10 tắt, LED12 sáng | MMCM của DDR/HyperRAM không khoá (clock qua SLR), xem `clock_utilization.rpt` |
| LED11 tắt | bo RAM chưa cắm hoặc cắm sai khe so với `FMC_SITE` |
| `ddr: init` lỗi / mắt đọc rỗng | VADJ (SW196 ở 1,5 V, LED "1.5"), bo RAM cắm chặt, `cap` để xem chụp thô |
