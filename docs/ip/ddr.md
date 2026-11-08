# Bộ điều khiển DDR2/DDR3 (`bow_ddr` v2: LiteDRAM + PHY của Bow32)

IP SDRAM DDR2/DDR3 của Bow32, gồm hai nửa:

* **Controller = [LiteDRAM](https://github.com/enjoy-digital/litedram)**, sinh ra bằng
  Python (Migen/LiteX) thành một file Verilog thuần: bank machine, refresh, lập lịch lệnh,
  DFII (phần mềm ra lệnh DRAM trực tiếp để khởi tạo và hiệu chỉnh), BIST và cổng native.
* **PHY = PHY riêng của Bow32** (`bow_ddr_phy` + `bow_ddr_io_xilinx` + `bow_ddr_clk_xusp`):
  `ODDRE1`/`IDDRE1`, MMCM dịch pha động cho clock lấy mẫu đọc (cả một chu kỳ CK) và cho
  pha ghi, cửa sổ DIR/OE cho level shifter TXV0108 của bo RAM, chụp thô để hiệu chỉnh.

Giữa hai nửa là bộ chuyển DFI `bow_ddr_dfi`. Mục tiêu vẫn là **học và thử nghiệm**
DDR2/DDR3 từ RTL tới FPGA, ưu tiên bo RAM mở rộng
`docs/fpga/ram_extension/FMC_DDR2_HyperRam.PDF` trên Arm MPS4.

| Thư mục / file | Nội dung |
|----------------|----------|
| `hw/ip/ddr/litedram/` | bộ sinh lõi LiteDRAM: `bow_ddr_litedram_gen.py`, `ddr2.yml`, `ddr3.yml`, `requirements.txt`, giấy phép LiteDRAM/LiteX |
| `hw/ip/ddr/litedram/generated/` | lõi đã sinh (không sửa tay): `ddr2/litedram_ddr2.v`, `ddr3/litedram_ddr3.v`, `csr.csv`, `init.csv`, header C |
| `hw/ip/ddr/rtl/` | RTL của Bow32: top, cầu bus, bộ chuyển DFI, thanh ghi, PHY, emulator DRAM |
| `hw/ip/ddr/dv/` | testbench mức IP (Verilator) và mô hình DRAM / level shifter / clock |
| `hw/fpga/common/rtl/bow_ddr_{io_xilinx,clk_xusp}.sv` | chân và clock cho UltraScale+ |
| `sw/common/include/bow_ddr.h`, `sw/common/src/bow_ddr.c` | driver PHY (mọi ứng dụng) |
| `sw/common/litedram/` | phần mềm phía LiteDRAM: DFII, khởi tạo JEDEC, hiệu chỉnh, bàn giao, BIST (chỉ ứng dụng `ddr`) |
| `sw/apps/ddr`, `tools/bow32_ddr.py` | ứng dụng thử nghiệm và công cụ trên PC |

Đánh giá bo RAM và lý do chọn kiến trúc: [../ddr_board_review.md](../ddr_board_review.md);
chạy trên MPS4: [../ddr_mps4.md](../ddr_mps4.md); khoảng cách tới mục tiêu công nghiệp và
SoC camera AI: [../ddr_review_industrial_ai.md](../ddr_review_industrial_ai.md).

| Thông số | Giá trị |
|----------|---------|
| Bộ nhớ | DDR2 (bo RAM: ISSI IS43DR86400E, 512 Mb x8, CL3, BL8) và DDR3 (Micron MT41K64M16 x16, chế độ DLL-off, CL = CWL = 6, chỉ mô phỏng) |
| Tốc độ | CK 133,33 MHz (DDR2-266), DDR3 125 MHz; controller LiteDRAM chạy ở CK/4 |
| Cửa sổ | `0x8000_0000`, giải mã 512 MiB, dung lượng thật 64 MiB (DDR2) / 128 MiB (DDR3), ngoài vùng → lỗi bus |
| Ghi nhỏ hơn burst | DM nếu có (DDR3), không thì đọc-sửa-ghi cả burst (bo RAM nối DM xuống GND) |
| Thanh ghi | CSR của LiteDRAM ở `0x4000_C000` (8 KiB), thanh ghi PHY/cầu ở `0x4000_E000` (4 KiB) |
| Ngắt | `irq_fast[11]` (lỗi, chụp thô xong, bước pha xong, APPLY) |
| Hiệu chỉnh | phần mềm: quét pha đọc + chụp thô, tìm mắt, `RD_DLY`/`RD_SLIP`; tuỳ chọn quét pha ghi bằng BIST |
| BIST | của LiteDRAM (generator + checker, dữ liệu PRBS hoặc đếm), đo băng thông |
| Khi không có DDR | `DdrEn = 0` (KV260): bản stub, cửa sổ và CSR trả lỗi bus, `INFO[24] = 0` |

```
 clk_i (SoC 50 MHz)        ddr_sys_clk (CK/4)                  ddr_clk (CK)              chân
 main xbar ─cửa sổ─> bow_ddr_win ═CDC═> native ─┐
 periph ─0x4000_C000─> bow_ddr_csr ═CDC═> wb_ctrl ─> litedram_ddr2/3 ─DFI 1:4─> bow_ddr_dfi ─> bow_ddr_phy ─> bow_ddr_io_xilinx
 periph ─0x4000_E000─> bow_ddr_regs ═══════════════kênh lệnh (APPLY, pha, chụp thô)═══════^          ^
                                                                    rd_clk: FIFO đọc <─ IDDR <─ DQ/DQS
 board: MMCM_A (clk_sys, ddr_clk, ddr_sys_clk; pha ghi dịch ở CLKOUT2) + MMCM_W (wclk, wclk90) + MMCM_B (rd_clk: pha đọc)
```

## Vì sao LiteDRAM + PHY riêng

LiteDRAM có controller tốt và đã chạy trên rất nhiều board, nhưng các PHY của nó không hợp
với bo RAM:

* PHY UltraScale+ (`USPDDRPHY`) chỉ hỗ trợ DDR3/DDR4, không có DDR2.
* Không PHY nào điều khiển chân DIR/OE của level shifter TXV0108.
* `USPDDRPHY` căn pha đọc bằng `IDELAYE3`, tầm chỉnh khoảng 1,25 ns trong khi một bit ở
  DDR2-266 dài 3,75 ns. Dữ liệu đọc của bo RAM đi qua hai lần level shifter (mỗi chiều
  1,2–4,8 ns) nên có thể rơi vào bất cứ đâu trong chu kỳ: chỉ chỉnh được 1/3 chu kỳ là không
  đủ. PHY của Bow32 lấy mẫu bằng một clock riêng có pha chỉnh được trên cả chu kỳ (MMCM).

Vì vậy Bow32 dùng controller của LiteDRAM và giữ PHY riêng, nối qua giao diện chuẩn DFI.
Phần dưới controller (PHY, chân, clock, emulator, mô hình, các bản build MPS4) giữ nguyên từ
bản v1, bản có controller tự viết.

## Lõi LiteDRAM

### Sinh lõi

```bash
make litedram          # venv Python 3.9 ở build/litex-venv (lần đầu cần mạng), sinh cả hai lõi
make litedram-check    # sinh lại vào thư mục tạm và so sánh với generated/
```

Phiên bản được ghim trong `requirements.txt`: LiteX `c12fae3`, LiteDRAM `f2d2297` (2026.08),
Migen 0.10.0. Kết quả sinh lại giống từng byte: ngày giờ, "git revision" và `` `timescale``
được bỏ đi. Python phải là 3.9 (Makefile mặc định `python3.9`): Migen đặt tên tín hiệu theo
bytecode, Python khác cho logic giống hệt nhưng tên khác nên `litedram-check` báo khác.

`bow_ddr_litedram_gen.py` dựng lõi bằng API của LiteDRAM. Lõi gồm controller, BIST
generator/checker, CSR `ddrctrl` (`init_done`/`init_error`), bus CSR `wb_ctrl` và một
"PHY" chỉ đưa DFI ra cổng. Lõi không dùng primitive nào của nhà sản xuất: Verilator mô phỏng
và Vivado tổng hợp cùng một file. Giấy phép BSD-2 của LiteDRAM/LiteX nằm cạnh bộ sinh
(`LICENSE.litedram`, `LICENSE.litex`).

Bộ sinh còn ghi `litedram_<lõi>_pkg.sv`: số chân DQ/địa chỉ/bank, DM, RESET#, kích thước
word native, dung lượng, `read_latency`/`write_latency`, CL/CWL, CK và tREFI của lõi.
`bow_ddr.sv` lấy mọi tham số từ package này và dừng (`$fatal` lúc elaboration: lint và
tổng hợp Vivado dừng; thêm một bản trong `initial` dừng mô phỏng ở thời điểm 0 khi build bỏ qua
lỗi đó, như `-Wno-fatal` của Verilator) khi lõi không khớp PHY (ví dụ
`write_latency` ≠ 0) hoặc `ClkHz` không hợp với lõi. Timing của lõi tính theo chu kỳ
controller: CK chậm hơn chỉ làm dài các khoảng chờ, trừ tREFI (khoảng giữa hai REF của lõi
phải ≤ 3,9 µs, `REF_NORM` nhân đôi thành ≤ 7,8 µs: lõi DDR2 cần CK ≥ 132,31 MHz, lõi DDR3
CK ≥ 124,11 MHz); CK nhanh hơn làm ngắn chúng: tối đa +1 %. `make
lint` elaborate cả hai lõi ở đúng CK, và hai cấu hình sai (DDR2 ở 132 MHz, lõi DDR3 ở
133 MHz) phải bị từ chối.

Ba chỗ bộ sinh khác cấu hình mặc định của LiteDRAM:

* **Không auto-precharge**: hàng được đóng bằng PRE riêng (A10 = 0 trên RD/WR). Emulator và
  mô hình DRAM của Bow32 không mô phỏng RDA/WRA; chỉ tốn chút băng thông khi truy cập ngẫu
  nhiên.
* **tREFI = `trefi_ns` của cấu hình, làm tròn xuống**: cả `ddr2.yml` và `ddr3.yml` đặt
  3900 ns, tốc độ refresh JEDEC khi nhiệt độ vỏ DRAM (Tc) 85..95 °C. DDR2 129 chu kỳ =
  3,87 µs, DDR3 121 chu kỳ = 3,872 µs. Bộ đếm refresh của LiteDRAM được thay bằng một bộ có
  thêm chu kỳ thứ hai: chân `ref_norm` của lõi (`CTRL.REF_NORM`) cho nó nạp 2 × tREFI, tức
  7,74 µs khi Tc ≤ 85 °C (mục [Refresh](#refresh-giám-sát-refresh-và-khoá-cấu-hình)). Đây là
  thay đổi duy nhất trong logic của lõi so với LiteDRAM.
  Các thời gian khác làm tròn lên như LiteDRAM: tREFI là giới hạn trên, làm tròn lên sẽ vượt
  datasheet.
* **Cổng native không bị chặn trong lõi** theo `init_done`/`init_error`: cửa sổ đã từ chối
  truy cập mới khi chưa `READY`; một truy cập đang chạy (kể cả RMW) luôn được làm xong khi
  firmware xoá `init_done` để vào chế độ DFII.

| Lõi | Bộ nhớ | CK / controller | Cổng native | DFI mỗi pha |
|-----|--------|-----------------|-------------|-------------|
| `ddr2` | IS43DR86400E x8, 4 bank, 14 bit hàng, 10 bit cột, 64 MiB, CL3 CWL2 | 133,33 / 33,33 MHz | địa chỉ 23 bit (đơn vị 8 byte), dữ liệu 64 bit | address 14, bank 2, data 16, mask 2 |
| `ddr3` | MT41K64M16 x16, 8 bank, 13 bit hàng, 10 bit cột, 128 MiB, DLL-off CL6 CWL6 | 125 / 31,25 MHz | địa chỉ 23 bit (đơn vị 16 byte), dữ liệu 128 bit | address 13, bank 3, data 32, mask 4 |

Cả hai lõi: DFI 1:4 (pha n của chu kỳ controller T = xung CK thứ 4T+n), BL8,
`read_latency` 12, `write_latency` 0, lệnh RD/WR ở pha 2. Một word của cổng native là một
burst; byte k của word là beat k (x8) hoặc nửa beat k/2 (x16), little endian như cửa sổ.

* **DDR2 với BL8.** LiteDRAM chỉ chạy DDR2 với BL4 trên DFI 1:2, trong khi PHY và emulator
  của Bow32 dùng BL8, độ dài burst mà DDR2 cũng cho phép. Bộ sinh đặt BL8 cho DDR2 ở hai
  chỗ: bảng độ dài burst của LiteDRAM (căn địa chỉ, khoảng RD→WR) và thanh ghi mode của
  chuỗi khởi tạo (MR 0x0333/0x0233). Thông số chip lấy giá trị chậm nhất của các cấp tốc độ
  và tCCD = 4 xung.
* **DDR3 DLL-off** dùng chế độ `dll_off` có sẵn của LiteDRAM (MR1 A0 = 1, CL = CWL = 6).

Cổng của lõi: `clk`/`rst` (đồng bộ), `init_done`/`init_error`, `user_clk`/`user_rst`,
`user_port_native_0_*`, `wb_ctrl_*` (Wishbone 32 bit, địa chỉ word = offset CSR / 4),
`dfi_p0..3_*`.

### Thanh ghi CSR của LiteDRAM (`0x4000_C000`)

Bản đồ giống nhau ở cả hai lõi: `generated/<lõi>/csr.csv` và `include/generated/csr.h`.
Firmware định nghĩa `CSR_BASE = BOW32_DDR_CTRL_BASE`.

| Offset | Khối | Thanh ghi |
|-------:|------|-----------|
| 0x0000 | `ddrctrl` | `init_done`, `init_error`: firmware ghi sau khi hiệu chỉnh; cửa sổ chỉ nhận truy cập mới khi `init_done = 1`, `init_error = 0` (`STATUS.READY`) |
| 0x0800 | `sdram` (DFII) | `dfii_control` (SEL = điều khiển phần cứng, CKE, ODT, RESET_N; reset = SEL) và cho mỗi pha n (cách nhau 0x18): `pi<n>_command`, `command_issue`, `address`, `baddress`, `wrdata`, `rddata` |
| 0x1000 | `sdram_checker` | BIST đọc: `reset`, `start`, `done`, `base`, `end`, `length`, `random`, `ticks`, `errors` |
| 0x1800 | `sdram_generator` | BIST ghi: `reset`, `start`, `done`, `base`, `end`, `length`, `random`, `ticks` |

`init.csv` là chuỗi khởi tạo JEDEC của `sdram_phy.h` ở dạng bảng cho testbench.

## Kiến trúc

### Miền clock

| Miền | Khối |
|------|------|
| `clk_i` (SoC) | `bow_ddr_regs`, phía bus của `bow_ddr_win` và `bow_ddr_csr` |
| `ddr_sys_clk` (CK/4) | lõi LiteDRAM, phía controller của hai cầu, chốt DFI |
| `ddr_clk` (CK) | `bow_ddr_dfi` (phát lệnh, trả dữ liệu đọc, thực thi lệnh của thanh ghi), `bow_ddr_phy` |
| `rd_clk` (CK, pha chỉnh được) | IDDR và phía ghi của FIFO đọc |
| `wclk`/`wclk90` | chỉ trong wrapper chân (pha ghi) |

`ddr_sys_clk` và `ddr_clk` ra từ cùng một MMCM, mỗi cạnh lên của `ddr_sys_clk` trùng một
cạnh lên của `ddr_clk`: đường giữa hai miền là đồng bộ và được phân tích timing bình thường.
Các cặp còn lại là bất đồng bộ: bắt tay bốn pha qua `bow_sync`, dữ liệu giữ yên trong lúc
bắt tay, `set_max_delay -datapath_only` trên MPS4.

Reset liên kết (`ddr_rst_ni & sys_rst_n`, đồng bộ vào bốn miền) xoá mọi trạng thái CDC ở cả
hai phía. Reset cầu = reset liên kết hoặc `CTRL.CORE_RST`: giữ hai cầu và lõi LiteDRAM.

* Hai bộ bước pha (pha đọc, pha ghi) chỉ reset theo `ddr_rst_ni` (MMCM mất lock hoặc bị
  reset), không theo reset SoC: reset SoC (BREAK của UART, reset mềm, `CB_nRST`) không đưa
  pha của MMCM về 0, nên bộ đếm cũng giữ nguyên, và một lần bước pha đang chạy được làm nốt.
  `PS_NOW`/`WPS_NOW` luôn là pha thật; giới hạn ±T/4 của pha ghi luôn tính từ pha 0 thật.
  Sau reset liên kết, khi cả hai bộ bước pha rảnh, bộ chuyển DFI tự khởi động lại FIFO đọc
  ở pha đọc đã tới (như `RFIFO_SYNC`) và lấy pha đó làm mốc của `PS_GO`; lệnh chờ tới lúc
  đó.
* Điều kiện với board: `ddr_rst_ni` xuống thì pha của MMCM cũng phải về 0. MMCM giữ pha đã
  dịch qua cả lúc mất lock, nên `bow_ddr_clk_xusp` reset cả ba MMCM mỗi khi một `LOCKED`
  rơi sau khi đã lock (64 chu kỳ clock vào; UG572 cũng yêu cầu reset sau khi mất lock). Pha
  ghi nằm ở `MMCM_A`, MMCM cũng tạo clock SoC: trên MPS4, MMCM DDR mất lock thì cả SoC bị
  reset (không chỉ reset liên kết như ở mức IP).
* Lõi LiteDRAM reset đồng bộ, chậm hơn cầu một hai chu kỳ controller: các flop chứa lệnh
  native (địa chỉ, dữ liệu ghi, byte enable) không bị reset, để một lệnh ghi lõi đã nhận
  nhưng chưa phát vẫn mang đúng dữ liệu khi `CORE_RST` đến (nếu bị xoá, DRAM không có DM sẽ
  bị ghi cả word bằng 0).

### Các module

| File | Nội dung |
|------|----------|
| `bow_ddr.sv` | top: reset, chọn lõi theo `DdrMem` (2 = DDR2, 3 = DDR3), nối các khối |
| `bow_ddr_win.sv` | cửa sổ bộ nhớ → cổng native (đọc-sửa-ghi, lỗi, timeout) |
| `bow_ddr_csr.sv` | slot `0x4000_C000` → `wb_ctrl` của LiteDRAM |
| `bow_ddr_regs.sv` | thanh ghi PHY/cầu, STATUS/IRQ, phía `clk_i` của kênh lệnh |
| `bow_ddr_dfi.sv` | bộ chuyển DFI + thực thi lệnh phía `ddr_clk` (APPLY, bước pha, RFIFO_SYNC, CAP_ARM, đếm ACT/REF) |
| `bow_ddr_phy.sv` | PHY không phụ thuộc công nghệ (giữ từ v1) |
| `bow_ddr_ps.sv` | bước pha MMCM (PSEN/PSDONE) |
| `bow_ddr_dev.sv`, `bow_ddr_lb.sv` | thiết bị DDR2/DDR3 tổng hợp được có kiểm tra JEDEC; emulator loopback |
| `bow_ddr_stub.sv` | bản thay thế khi `DdrEn = 0` |
| `bow_ddr_pkg.sv` | kiểu dùng chung: lệnh, cấu hình PHY, bundle chân, pha DFI |

## Cửa sổ bộ nhớ

Offset `o` trong cửa sổ, word native = một burst (8 byte DDR2, 16 byte DDR3):

```
DDR2: o = { hàng[13:0], bank[1:0], cột[9:3], byte[2:0] }      64 MiB
DDR3: o = { hàng[12:0], bank[2:0], cột[9:3], byte[3:0] }      128 MiB
```

(ánh xạ ROW_BANK_COL của LiteDRAM: truy cập tuần tự đi hết một trang rồi sang bank kế.)

* Mỗi truy cập là một giao dịch 32 bit: cầu giữ `gnt = 0`, chuyển yêu cầu sang miền
  controller, chờ kết quả rồi trả `rvalid` đúng một chu kỳ sau `gnt` (luật bus Bow32).
* Đọc: một word native, lấy làn 32 bit theo `o[2]` (DDR2) hoặc `o[3:2]` (DDR3).
* Ghi: có DM và `CTRL.DM_EN` → ghi word với mặt nạ byte; không thì đọc-sửa-ghi cả word.
  RMW nguyên tử vì cửa sổ là người dùng duy nhất của cổng native, nhưng **không** nguyên tử
  với BIST của LiteDRAM (có cổng crossbar riêng): đừng chạy BIST trên vùng CPU đang dùng.
* Lỗi bus ngay, không truy cập DRAM: chưa `READY` hoặc cầu đang reset (`NOT_READY`),
  offset ≥ dung lượng (`RANGE`). `ERR_ADDR` giữ địa chỉ của lần lỗi cuối.
* Timeout `WinTimeout` (2^20 chu kỳ `clk_i`), hoặc clock DDR ngừng giữa chừng trong khi MMCM
  vẫn lock (`CLK_OK` = 0) → lỗi bus, `BUS_TIMEOUT`, và cầu chuyển sang trạng thái **chết**
  (`STATUS.BROKEN`): mọi truy cập sau đó bị từ chối cho tới `CORE_RST`. Lý do: cầu không biết
  phía controller còn làm truy cập dở hay không; một câu trả lời muộn không bao giờ được nhận
  nhầm cho yêu cầu sau.
* `CORE_RST` giữa chừng → lỗi bus, `NOT_READY`; MMCM mất lock giữa chừng → lỗi bus,
  `BUS_TIMEOUT`. Cả hai reset luôn hai phía của cầu (reset cầu / reset liên kết), nên không có
  `BROKEN` và không cần thêm `CORE_RST`.
* Với bản loopback chỉ 4 MiB đầu có thật (`EMU`); truy cập trên đó gây lỗi `ROW_RANGE` của
  emulator (`DBG`).

## Cầu CSR

Slot `0x4000_C000` (8 KiB) đi thẳng tới `wb_ctrl` của LiteDRAM qua bắt tay bốn pha. Từ chối
(lỗi bus, `CSR_ERR`) khi clock DDR không chạy, khi `CORE_RST`, khi reset do `CORE_RST` gây
ra chưa xong (xem `READY`) hoặc lõi đang reset; lỗi Wishbone hoặc timeout cũng cho
`CSR_ERR`. Timeout, hoặc clock ngừng giữa chừng khi MMCM vẫn lock, thêm `BUS_TIMEOUT` và
`BROKEN`, như cửa sổ. Chỉ dùng truy cập 32 bit.

## Bộ chuyển DFI

* **Lệnh.** Pha n của chu kỳ controller T được giải mã ở chu kỳ `ddr_clk` 4T+4+n, vào PHY ở
  4T+5+n, ra chân ở 4T+6+n và DRAM chốt ở cạnh CK 4T+8+n: trễ cố định 8 CK, giữ nguyên mọi
  khoảng cách JEDEC mà LiteDRAM tính. `cs_n = 0`: `{ras_n, cas_n, we_n}` = 000 MRS, 001 REF,
  010 PRE, 011 ACT, 100 WR, 101 RD, 110 ZQ, 111 NOP; `cs_n = 1`: không có lệnh.
* **Ghi.** Một WR mang burst của chính chu kỳ controller đó (`write_latency` 0, dữ liệu của
  cả 4 pha), byte enable = `!wrdata_mask`.
* **Đọc.** LiteDRAM lấy `rddata` của mọi pha đúng 12 chu kỳ controller sau RD (không nhìn
  `rddata_valid`; chỉ DFII chốt theo `rddata_valid`). Burst từ PHY vào một FIFO 16 ô và
  được đưa ra đúng chu kỳ đó. FIFO rỗng đúng lúc cần → `RD_LATE`; burst thừa → `RD_EXTRA`.
* **Ngân sách đọc:** RL + `RD_DLY` + `RD_SLIP` ≤ 4 × 12 − 14 − n với n = pha của RD (LiteDRAM
  và firmware dùng pha 2): ≤ 32, tức `RD_DLY` + `RD_SLIP` ≤ 29 cho DDR2 CL3 và ≤ 26 cho DDR3
  CL6. Bản loopback đo được 10, bo RAM trong mô phỏng 10–12: dư nhiều.
* **CKE/ODT/RESET#** lấy từ pha 0 của DFI (DFII điều khiển khi khởi tạo, controller giữ 1 khi
  ở chế độ phần cứng), qua cổng `CTRL.EN` (0 → CKE = RESET# = ODT = 0, mọi lệnh bị bỏ); ODT
  còn AND với `CTRL.ODT_EN` (bo RAM: Rtt tắt, luôn 0).
* Pha của từng chu kỳ `ddr_clk` trong chu kỳ controller được suy ra từ một flop đảo mỗi chu
  kỳ `ddr_sys_clk`; trước khi khoá pha mọi lệnh bị bỏ.

Khoảng chuyển hướng bus mà LiteDRAM giữ cho DDR2 ở 33,33 MHz: RD→WR 4 chu kỳ = 16 CK,
WR→RD (tWTR + độ trễ ghi + tCCD) 3 chu kỳ = 12 CK, đủ cho cửa sổ DIR của level shifter (cần
11 và 8 CK, xem dưới).

## PHY

Giữ nguyên từ v1. Bảng thời gian dưới đây là của `bow_ddr_phy`; chu kỳ j là chu kỳ `ddr_clk`
PHY đưa giá trị ra.

### Hợp đồng thời gian ở chân

* CK, DQS, DQ/DM, các output enable, DIR/OE của level shifter: xuất hiện ở chu kỳ chân j+1.
  Beat 0 của DQ nằm giữa quanh cạnh lên DQS, beat 1 quanh cạnh xuống: DQ/DM ra bằng
  `ODDRE1` trên `~wclk90`, DQS bằng `ODDRE1` trên `wclk`.
* Lệnh/địa chỉ/CKE/ODT: `ODDRE1` trên `ddr_clk`, giá trị chu kỳ j nằm từ (j+1.5)T tới
  (j+2.5)T: DRAM chốt lệnh ở cạnh j+2.
* Đọc: `IDDRE1` trên `rd_clk` lấy một mẫu ở cạnh lên và một ở cạnh xuống; FIFO bất đồng bộ
  16 ô đưa luồng mẫu về `ddr_clk`.

### Ghi và đọc

* Ghi (lệnh ở chu kỳ n): preamble DQS ở n+WL, 4 chu kỳ dữ liệu, postamble ở n+WL+5; hai burst
  liền nhau không có preamble/postamble ở giữa.
* Đọc: burst lấy từ chu kỳ luồng n + RL + 2 + `RD_DLY`, beat 0 là mẫu cạnh lên (`RD_SLIP = 0`)
  hoặc cạnh xuống (`RD_SLIP = 1`). `RD_DLY` gom mọi độ trễ: chân ra, level shifter, DRAM,
  IDDR và FIFO.

### Level shifter (bo RAM)

Với `IDLE_DRIVE = 1` FPGA luôn lái DQ/DQS (= 0) trừ trong cửa sổ đọc, nên đầu vào của
TXV0108 không bao giờ thả nổi. Cửa sổ đọc của lệnh RD ở chu kỳ n:

```
dir_on  = n + RL - RDIR_LEAD        DIR -> chiều đọc (DRAM -> FPGA)
oe_off  = max(n, dir_on - OE_PRE)   FPGA nhả DQ/DQS
dir_off = n + RL + 6 + RDIR_TAIL    DIR -> chiều ghi
oe_on   = dir_off + OE_POST         FPGA lái lại
```

Cần RL ≥ `RDIR_LEAD + OE_PRE`, RD→WR ≥ RL + 6 + `RDIR_TAIL + OE_POST` − WL và WR→RD ≥
WL + 6 + `RDIR_LEAD + OE_PRE` − RL (mặc định bo RAM 2/1/2/2: 11 và 8 CK; LiteDRAM cho 16 và
12 CK). Mô phỏng báo lỗi nếu một cửa sổ ghi chồng lên cửa sổ đọc.

### Pha đọc, pha ghi và FIFO

* `PS_TARGET` + `CMD.PS_GO`: bước pha `rd_clk` (504 bước mỗi CK ở VCO 1200 MHz). Không đi xa
  quá 2 chu kỳ CK so với lúc `RFIFO_SYNC` gần nhất.
* `WPS_TARGET` + `CMD.WPS_GO`: dịch DQS và DQ so với CK, trong ±T/4.
* `CMD.RFIFO_SYNC`: xả và khởi động lại FIFO đọc; độ trễ có thể đổi ±1 chu kỳ nên phải hiệu
  chỉnh lại.
* FIFO tràn/cạn → `RFIFO_ERR`, `RFIFO_BROKEN` cho tới `RFIFO_SYNC`.

## Khởi tạo, hiệu chỉnh và bàn giao

Toàn bộ do firmware làm (`sw/common/litedram/`), theo thứ tự:

1. **Bật PHY.** `dfii_control = 0` (DFII chiếm DFI, CKE = 0), `CTRL = EN | CK_EN | LS_EN |
   IDLE_DRIVE` (+ `DDR3`, `DM_EN` theo `INFO`), `ODT_EN = 0`, `LAT` theo loại bộ nhớ,
   `APPLY`. Chờ ≥ 200 µs (DDR2: CK chạy, CKE thấp; DDR3: RESET# thấp).
2. **JEDEC init** bằng `init_sequence()` của `sdram_phy.h` đúng lõi (`INFO[26]` chọn DDR2 hay
   DDR3; hai header nằm trong hai file C riêng nên một firmware chạy được cả hai):

   | Lệnh | DDR2 (bo RAM) | DDR3 DLL-off |
   |------|---------------|--------------|
   | điều khiển | CKE = 1 | RESET# = 1, chờ, CKE = 1 |
   | MR2 / MR3 | 0x0000 / 0x0000 (sau PREA) | 0x0008 (CWL 6) / 0x0000 |
   | MR1 | 0x0000: DLL bật, Rtt tắt, DQS# bật | 0x0003: DLL tắt |
   | MR0 | 0x0333 (DLL reset, CL3, BL8, WR2), PREA, 2 × REF, 0x0233 | 0x0320 (CL6, BL8) |
   | cuối | EMR1 OCD default 0x0380, OCD exit 0x0000 | ZQCL |

3. **Hiệu chỉnh đọc** (như v1, lệnh qua DFII): ghi mẫu P = `A5 5A F0 0F C3 3C 96 69` vào một
   burst; với mỗi pha `rd_clk`: `CAP_ARM` + RD, ghép 32 chu kỳ chụp thô thành 64 beat, tìm vị
   trí p của P; mắt = dải pha liên tiếp dài nhất có cùng p (vòng tròn qua 0); đặt pha giữa,
   `RD_DLY = p/2 − 4`, `RD_SLIP = p mod 2`, `APPLY`, đọc lại P và ~P.
4. **Bàn giao:** PREA, `dfii_control = SEL | CKE | ODT | RESET_N` (LiteDRAM tự refresh, DDR3
   thêm ZQCS mỗi giây), `init_done = 1` → `STATUS.READY`, cửa sổ dùng được. Hiệu chỉnh hỏng
   → `init_error = 1` (refresh vẫn chạy).
5. (Tuỳ chọn, `calw`) quét pha ghi ±T/4 bằng BIST, chọn giữa vùng không lỗi. Mọi lỗi sau
   khi bắt đầu quét (`WPS_GO` bị từ chối, vùng đạt dưới 20 %, BIST ở pha đã chọn hỏng) →
   trả lại pha ghi cũ và kiểm nó bằng BIST (PRBS và dữ liệu đếm); pha cũ cũng hỏng →
   `init_error = 1` (cửa sổ bị chặn, chạy `cal` lại). `bow_ld_handover` luôn chặn cổng
   native (xoá `init_done`, chờ 20 µs) trước đoạn DFII của nó.

`cal` và `calw` dùng 64 word native đầu của DRAM (mẫu huấn luyện, BIST kiểm tra): dữ liệu ở
đó bị ghi đè. `eye` (chỉ quét và in mắt) thì giữ dữ liệu: đọc hai word dưới mẫu trước khi
quét và ghi lại sau đó. Với bộ nhớ đang `READY`, `eye` chỉ trả lại cửa sổ khi đọc lại đúng
mẫu ở pha cũ (việc đồng bộ lại FIFO đọc khi quét có thể làm dữ liệu lệch một chu kỳ); nếu
không, cửa sổ bị chặn tới lần `cal` sau.

Ở chế độ phần mềm (DFII) **không có refresh**: sau khi DRAM đã khởi tạo, firmware chỉ rời
chế độ phần cứng trong những đoạn ngắn (PREA + REF, vài lệnh, đóng bank, trả lại; khoảng
11 µs, không in gì bên trong). Trong mỗi đoạn, firmware tắt `REF_MON` rồi bật lại khi xong:
không có refresh để giám sát.
Emulator và mô hình DRAM báo `REF_STARVE` khi quá 9 × tREFI (70 µs ở 7,8 µs) không có REF,
hoặc khi nợ quá 8 REF so với lịch tREFI. Sau RD bằng DFII phải chờ khoảng 1 µs rồi mới đọc `pi<n>_rddata`.

`CORE_RST` (khi cầu chết): lõi trở lại chế độ phần cứng với `init_done = 0`, DRAM vẫn giữ
khởi tạo. Bàn giao lại: `dfii_control = CKE | ODT | RESET_N` (không bao giờ ghi 0 sau khi đã
khởi tạo: CKE thấp nghĩa là phải khởi tạo DDR2 lại), PREA, `SEL | CKE | ODT | RESET_N`,
`init_done = 1`. Giữ `CORE_RST` ngắn vì trong lúc đó không có refresh (`bow_ddr_core_reset`
tắt `REF_MON` cùng lúc).

## Refresh, giám sát refresh và khoá cấu hình

Ba tính năng cho mục tiêu công nghiệp (giai đoạn P0 của
[../ddr_review_industrial_ai.md](../ddr_review_industrial_ai.md)). Cả ba bit `CTRL` dưới
đây tác dụng ngay, không qua `APPLY`.

* **Tốc độ refresh theo nhiệt độ (`CTRL.REF_NORM`).** Mặc định `REF_NORM = 0`: lõi LiteDRAM
  refresh mỗi 3,87 µs, tốc độ JEDEC khi Tc 85..95 °C. `REF_NORM = 1`: bộ đếm refresh của lõi
  nạp 2 × tREFI, refresh mỗi 7,74 µs, chỉ dùng khi Tc ≤ 85 °C. Bit đi qua bộ đồng bộ vào miền
  `ddr_sys_clk` và có hiệu lực từ lần nạp lại kế tiếp (chậm nhất sau một khoảng refresh). Mỗi
  lần refresh, LiteDRAM phải xả hàng đợi, PREA, chờ tRFC rồi mở lại hàng (khoảng 20 chu kỳ
  controller), nên mặc định an toàn tốn băng thông: xem [Giới hạn](#giới-hạn). Firmware:
  `bow_ld_set_refresh_norm()` (chính sách, mặc định 3,9 µs), `bow_ddr_set_refresh()`; ứng dụng
  `ddr`: `refresh 3.9|7.8`.
* **Giám sát refresh (`CTRL.REF_MON`).** Khi bật, `bow_ddr_dfi` đếm chu kỳ CK từ REF cuối cùng
  tới PHY. Quá 8 lần khoảng cách mong đợi (8 × 4 × `TRefi` CK, gấp đôi khi `REF_NORM`; 31 µs
  hoặc 62 µs): `STATUS.REF_STARVE` (W1C, ngắt qua `IRQ_EN`), tức đã lỡ 8 REF, trước giới hạn
  JEDEC một REF. Khoảng cách dài nhất khi bật nằm ở `ST_RGAP` (chụp bằng `SNAP`, xoá bằng
  `CLR_STATS`). Tắt bit thì bộ đếm dừng và về 0. `bow_ld_handover` bật nó; firmware tắt nó
  trong các đoạn DFII, khi dừng DRAM và khi `CORE_RST`. Giới hạn theo `REF_NORM` hiện tại:
  ngay sau khi xoá `REF_NORM`, khoảng 7,74 µs đang dở vẫn được đo với giới hạn 31 µs. Nó bắt được: firmware để quên DFII ở
  chế độ phần mềm, `CORE_RST` kéo dài, refresher của lõi hỏng.
* **Khoá cấu hình (`CTRL.LOCK`).** Ghi 1 sau khi bàn giao; chỉ reset SoC mới xoá. Khi khoá:
  ghi `CTRL` bị bỏ qua (trừ xoá `REF_NORM`, về phía an toàn), `LAT`, `PS_TARGET`,
  `WPS_TARGET` bị bỏ qua; `CMD` chỉ còn nhận `SNAP` và `CLR_STATS` (lệnh khác: `CMD_ERR`);
  mọi lần ghi CSR của LiteDRAM bị từ chối (lỗi bus, `CSR_ERR`), đọc vẫn được. Mỗi thay đổi
  bị từ chối đặt `STATUS.LOCK_ERR` (ghi lại đúng giá trị đang có thì không). Cửa sổ bộ nhớ,
  `IRQ_EN` và các bit W1C vẫn dùng được. Sau khi khoá không còn hiệu chỉnh lại, BIST hay
  `CORE_RST` được: một cầu `BROKEN` chỉ hồi phục bằng reset SoC. Firmware: `bow_ddr_lock()`;
  ứng dụng `ddr`: `lock`.

Telemetry: sau `cal`/`calw`, firmware in `ddr: telemetry: read eye | write range W of S steps
(P % of CK)`, kèm `WARNING` khi dưới 25 % chu kỳ (`BOW_LD_EYE_WARN_PCT`, tiêu chí biên của
bản review); `info` in thêm độ rộng mắt đọc theo % CK.

## Bản đồ thanh ghi PHY/cầu (`0x4000_E000`)

Offset của v1 được giữ khi ý nghĩa không đổi.

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| 0x000 | `ID` | R | `0x44445202` ("DDR", phiên bản 2: controller LiteDRAM) |
| 0x004 | `INFO` | R | [4:0] độ rộng DQ, [6:5] số lane − 1, [10:7] số chân địa chỉ − 1, [12:11] số chân bank − 1, [13] có DM, [15:14] loại PHY (1 chân thật, 2 emulator loopback), [23:16] MHz, [24] DdrEn, [25] có RESET#, [26] lõi DDR3, [31:27] read latency của DFI (12) |
| 0x008 | `CTRL` | RW | [0] EN, [4] DM_EN, [5] DDR3, [6] IDLE_DRIVE, [7] LS_EN, [10] ODT_EN, [11] CK_EN, [12] CORE_RST, [13] REF_NORM, [14] REF_MON, [15] LOCK. Reset `0x40`. CORE_RST, REF_NORM, REF_MON, LOCK tác dụng ngay; các bit khác qua APPLY |
| 0x00C | `CMD` | W | đúng một bit mỗi lần ghi: [0] APPLY, [1] PS_GO, [4] RFIFO_SYNC, [5] SNAP, [6] CLR_STATS, [7] WPS_GO, [8] CAP_ARM |
| 0x010 | `STATUS` | R/W1C | [0] BUSY, [1] READY, [2] CLK_OK, [3] APPLIED, [5] PS_DONE, [6] CAP_DONE, [9] CMD_ERR, [10] RFIFO_ERR, [11] BUS_TIMEOUT, [12] DBG_ERR, [13] LINK, [14] PS_ERR, [15] RFIFO_BROKEN, [16] INIT_DONE, [17] INIT_ERROR, [18] RD_LATE, [19] RD_EXTRA, [20] NOT_READY, [21] RANGE, [22] CSR_ERR, [23] BROKEN, [24] REF_STARVE, [25] LOCK_ERR. Bit chỉ đọc: 0, 1, 2, 12, 13, 15, 16, 17, 23 |
| 0x014 | `IRQ_EN` | RW | các bit W1C của `STATUS`: `irq = \|(STATUS & IRQ_EN)` |
| 0x01C | `LAT` | RW | [5:0] RL, [11:6] WL, [16:12] RD_DLY, [17] RD_SLIP, [19:18] OE_PRE, [23:20] RDIR_LEAD, [27:24] RDIR_TAIL, [31:28] OE_POST. Reset `0x22240083` (bo RAM) |
| 0x030 | `PS_TARGET` | RW | pha đọc mong muốn (có dấu, bước MMCM) |
| 0x034 | `PS_NOW` | R | [15:0] pha đọc hiện tại (giữ qua reset SoC), [31:16] số bước mỗi CK |
| 0x054 | `WPS_TARGET` | RW | pha ghi mong muốn (\|giá trị\| ≤ số bước / 4) |
| 0x058 | `WPS_NOW` | R | pha ghi hiện tại (giữ qua reset SoC) |
| 0x098 | `EMU` | R | [4:0] log2 dung lượng emulator (0 = không có) |
| 0x09C | `CLK_HZ` | R | tần số CK chính xác |
| 0x0A0..0x0B0 | `ST_RD`, `ST_WR`, `ST_ACT`, `ST_REF`, `ST_RMW` | R | thống kê (chụp bằng `SNAP`): đọc/ghi native của cửa sổ, ACT/REF ra DRAM, số lần RMW |
| 0x0B4 | `DBG` | R | trạng thái của board (emulator: {lỗi, init xong, mã lỗi, số lỗi}), từng bit qua bộ đồng bộ: đọc hai lần nếu cần số lỗi chính xác |
| 0x0B8 | `ERR_ADDR` | R | địa chỉ bus của truy cập cửa sổ lỗi gần nhất |
| 0x0BC | `ST_RGAP` | R | khoảng cách REF dài nhất khi `REF_MON` = 1, tính bằng chu kỳ CK − 1 (chụp bằng `SNAP`) |
| 0x100..0x17C | `CAP[0..31]` | R | chụp thô DQ: x8 [7:0] cạnh lên, [15:8] cạnh xuống |
| 0x180..0x1FC | `CAPS[0..31]` | R | chụp thô DQS |

* `READY` = `CLK_OK` & !`CORE_RST` & (reset lõi đã xong) & `INIT_DONE` & !`INIT_ERROR` &
  !`BROKEN`. "Reset lõi đã xong": sau khi `CORE_RST` về 0, `READY` (và cầu CSR) chờ tới khi
  thấy lõi vào reset rồi ra khỏi reset (vài chu kỳ). Nhờ vậy một xung `CORE_RST` ngắn không
  để lại `READY` cũ trong lúc lõi đang xoá `init_done`. Nếu clock DDR ngừng trong lúc xung
  và `clk_i` chậm hơn `ddr_sys_clk` / 2, lần reset của lõi khi clock chạy lại (2 chu kỳ
  `ddr_sys_clk`) có thể lọt qua bộ đồng bộ: khi đó trạng thái chờ tự kết thúc sau 127 chu kỳ
  `clk_i` có `CLK_OK` mà lõi đã ra khỏi reset.
* `PS_NOW`/`WPS_NOW` theo bộ đếm của bộ bước pha: kết quả của `PS_GO`/`WPS_GO` khi lệnh
  xong, còn khi không có lệnh thì đọc trực tiếp (mỗi bit qua bộ đồng bộ, lấy khi hai mẫu liên
  tiếp bằng nhau). Đúng khi bộ đếm giữ mỗi giá trị ít nhất ba chu kỳ `clk_i` (một bước pha
  mất 13 chu kỳ CK = 97,5 ns ở 133 MHz) và độ lệch giữa các bit nhỏ hơn một chu kỳ `clk_i`.
* `APPLY` chờ PHY rảnh (tối đa 4096 CK) rồi chép `CTRL`/`LAT`; không rảnh → `CMD_ERR`. Dùng
  khi đang ở chế độ phần mềm hoặc không có truy cập.
* `CAP_ARM`: RD kế tiếp tới PHY sẽ chụp thô 32 chu kỳ, xong thì `CAP_DONE`.
* `REF_STARVE` (bộ giám sát refresh) và `LOCK_ERR` (thay đổi bị `LOCK` từ chối): xem mục
  [Refresh](#refresh-giám-sát-refresh-và-khoá-cấu-hình).

## Lập trình

```c
#include "bow32.h"
#include "bow_litedram.h"            // sw/common/litedram (ứng dụng ddr)

bow_ddr_info_t info;  bow_ddr_config_t cfg;  bow_ld_cal_t cal;
if (!bow_ddr_probe(&info)) return;    // không có IP, hoặc stub (DdrEn = 0)
bow_ddr_config_for(&info, &cfg);      // bo RAM DDR2 / DDR3 DLL-off
if (!bow_ld_init(&cfg, true)) return; // bật nguồn, JEDEC init, refresh
if (!bow_ld_calibrate(4, true, &cal)) return;   // mắt đọc, RD_DLY, bàn giao, BIST
// bàn giao xong: refresh 3,9 µs, bộ giám sát refresh bật
bow_ld_set_refresh_norm(true);        // 7,8 µs, chỉ khi Tc ≤ 85 °C
bow_ddr_lock();                       // tuỳ chọn: khoá cấu hình tới lần reset sau
volatile uint32_t *ddr = (volatile uint32_t *)BOW32_DDR_BASE;
ddr[0] = 0x12345678u;                 // CPU truy cập trực tiếp qua cửa sổ
```

## Mô hình DRAM và emulator

`bow_ddr_dev` là thiết bị DDR2/DDR3 theo chu kỳ, tổng hợp được: giải mã MRS (CL/AL/CWL/BL/DLL),
theo dõi bank, kiểm tra trình tự khởi tạo (chấp nhận EMRS2/EMRS3 theo cả hai thứ tự vì
LiteDRAM gửi EMRS3 trước), mọi timer JEDEC, và refresh quá hạn (`REF_STARVE`): quá 9 × tREFI
không có REF, hoặc nợ quá 8 REF (mỗi tREFI một REF đến hạn, mỗi REF trả một, được trả trước
tối đa 8: tREFI là khoảng trung bình). Đầu vào `hot_i`
chọn tREFI / 2 (Tc 85..95 °C): bản loopback buộc 0, testbench dùng nó để kiểm tra chế độ
nóng. Trong mô phỏng nó nằm trong
`ddr_mem_model` (chân, level shifter, tDQSS, preamble/postamble, setup/hold). Trên FPGA,
`bow_ddr_lb` nối nó ngay sau PHY (bản loopback, 4 MiB UltraRAM); lỗi đọc được ở `DBG`.

## Kiểm chứng

* `make -C hw/ip/ddr/dv test` (trong `make test-ip`): Verilator, toàn bộ `bow_ddr` (lõi
  LiteDRAM thật) + mô hình clock/chân/level shifter/DRAM, 4 cấu hình: `lb` (emulator loopback,
  như bản MPS4), `card` (DDR2 x8 qua TXV0108), `ddr3` (x16 DLL-off, DM, RESET#), `stub`.
  Testbench chạy đúng luồng của firmware bằng thanh ghi: khởi tạo từ `init.csv`, hiệu chỉnh
  bằng chụp thô, bàn giao, truy cập cửa sổ (kể cả RMW byte/halfword) so với mô hình tham chiếu,
  BIST, ngân sách đọc (32 kịp, 33 → `RD_LATE`), lỗi `RANGE`/`NOT_READY`, timeout, `CORE_RST`.
  BIST có thêm một lượt dữ liệu và địa chỉ ngẫu nhiên (xung đột hàng), và một bộ giám sát
  DFI báo lỗi mọi RD/WR có A10 = 1 (auto-precharge). Thêm `rst` (`tb_bow_ddr_rst.sv`): xung
  `CORE_RST` ngắn (cả khi đọc CSR ngay trong chu kỳ nhả), `CORE_RST` giữa lúc ghi byte, reset
  SoC giữa lúc bước pha, xoá `init_done` khi đang có truy cập cửa sổ, clock DDR ngừng (MMCM
  vẫn lock) khi đang truy cập → `BUS_TIMEOUT` + `BROKEN`, `LOCK` được reset SoC xoá.
  Bước 10 của testbench: tần suất REF đo bằng `ST_REF` với `REF_NORM` 0 / 1, `ST_RGAP`,
  `REF_STARVE` và ngắt khi tắt refresh bằng DFII, mô hình DRAM ở chế độ nóng (nợ REF tăng
  khi `REF_NORM` = 1), toàn bộ hành vi `LOCK`.
* `make -C hw/ip/ddr/dv regress NSEEDS=100`: mọi cấu hình với seed 1..100 (độ trễ bo, mô
  hình DRAM, truy cập ngẫu nhiên rút theo seed) và `rst`; GitHub Actions chạy 25 seed mỗi
  đêm (`.github/workflows/ddr-nightly.yml`).
* `make run TEST=ddr` (trong `make test`): ứng dụng `ddr` chạy `test quick` (21 mục) trên CPU
  với emulator loopback.
* `make test-fpga-dv`: xsim với UNISIM cho chân và clock (cả `ddr_sys_clk`).
* `make litedram-check`: lõi trong repo đúng là lõi sinh từ cấu hình.
* Board: [../ddr_mps4.md](../ddr_mps4.md).

## Giới hạn

* Mỗi truy cập CPU/DMA qua cửa sổ là một giao dịch 32 bit (vài trăm ns); băng thông thật đo
  bằng BIST.
* DDR3 chỉ ở chế độ DLL-off (≤ 125 MHz), chưa có phần cứng; không write leveling, không ODT
  động.
* Hiệu chỉnh đọc dùng một pha chung cho mọi bit DQ.
* Lõi LiteDRAM làm tròn lên mọi thời gian theo chu kỳ controller (30 ns ở DDR2), trừ tREFI
  (làm tròn xuống).
* Refresh mặc định 3,9 µs (an toàn tới Tc 95 °C) tốn băng thông: trên MPS4 BIST ghi / đọc
  213,7 / 213,7 MB/s, so với 233,5 / 226,4 MB/s ở 7,8 µs (`REF_NORM`), tức chậm 8,5 % /
  5,6 %, vì mỗi lần refresh LiteDRAM mất khoảng 20 chu kỳ controller. Chọn `REF_NORM` theo
  nhiệt độ của sản phẩm (FPGA chưa đọc nhiệt độ DRAM).
* Đoạn DFII (hiệu chỉnh, quét mắt) dài tới 50 µs: ở Tc > 85 °C nên giữ dưới 31 µs (8 × 3,9 µs).

## Bài tập mở rộng

* Cache (line = 1 burst) trước cửa sổ để CPU chạy được mã từ DDR.
* Dùng thêm cổng native của LiteDRAM cho DMA hoặc video (crossbar đã có sẵn).
* Deskew từng bit bằng `IDELAYE3` và hiệu chỉnh theo bit.
* Bo RAM rev-B dùng DDR3 1,5 V nối thẳng (không level shifter): khi đó dùng được PHY
  `USPDDRPHY` của LiteDRAM ở DDR3-800 trở lên ([../ddr_board_review.md](../ddr_board_review.md)).
