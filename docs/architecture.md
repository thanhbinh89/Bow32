# Kiến trúc Bow32

## Sơ đồ khối

```
             clk_i ──────────────────────────────────────────────┐
             rst_ni ──> bow_rstmgr ──> por_rst_n (SYSCTRL)        │
                           ^    └────> sys_rst_n (mọi khối khác)  │
                           │ sys_rst_req                          │
 ┌─────────────────────────┼──────────────────────────────────────┼──┐
 │  bow_cpu_ibex           │                                      │  │
 │  ┌───────────────┐      │       bow_bus_xbar (main, 3 x 9)     │  │
 │  │ ibex_top      │ instr├──────>┌──────────────┐               │  │
 │  │ RV32IMC       │      │       │ decode + RR  │──> bow_rom    │  │
 │  │               │ data ├──────>│ arbiter/dev  │──> bow_flash ─┼──┤ (mem port)
 │  └───────▲───────┘      │  ┌───>└──────────────┘──> bow_sram   │  │
 │          │irq_fast[12:0]│  │ DMA       │        └─> bow_vram 1 MiB
 └──────────┼──────────────┼──┼───────────┼───────────────────────┘  │
            │              │       bow_bus_xbar (periph, 1 host)     │
            │              │       ┌──────────────┐                  │
            │              └───────│ SYSCTRL      │<── uart0_rx (BREAK detect)
            │                      │ FLASH_CTRL   │── reg port của bow_flash
            ├──────────────────────│ UART0        │<─> uart0_rx/tx
            ├──────────────────────│ UART1        │──┐ chức năng thay thế
            ├──────────────────────│ GPIOA        │<─┼─> gpioa[7:0]   (PA7 = bật camera trên KV260)
            ├──────────────────────│ GPIOB        │<─┴─> gpiob[7:0]  (PB0/PB1 = UART1 TX/RX)
            ├──────────────────────│ ISP (regs)   │──┐
            ├──────────────────────│ I2C0         │<─┼─> scl/sda (open drain)
            ├──────────────────────│ CSI2RX       │──┼──┐
            ├──────────────────────│ H264 (regs)  │──┼──┼──┐
            ├──────────────────────│ DMA (regs)   │──┼──┼──┼──┐
            ├──────────────────────│ MKV (mã khối)│  │  │  │  │
            ├──────────────────────│ DDR CSR, PHY │──┼──┼──┼──┼──┐
            └──────────────────────│ HyperRAM regs│  │  │  │  │  │
                                   └──────────────┘  │  │  │  │  │
   main xbar ──> ISP capture buffer (0x3000_0000) ───┤  │
   main xbar ──> bow_axil_bridge ──> m_axil_* (AXI4-Lite, 0x5000_0000)
   main xbar ──> bow_ddr (cửa sổ 0x8000_0000) ──> LiteDRAM ──DFI──> PHY ──> ddr_io_* ──> pad wrapper
   main xbar ──> bow_hyperram (cửa sổ 0x6000_0000) ──> controller ──> PHY ──> hr_io_* ──> pad wrapper
                                                     │  │
   dphy_* (D-PHY I/O) ──> bow_mipi_rx ───────────────┼──┘  │  │
                              │ RAW10 (m_axis)       │     │  │
                              └──> bow_isp ──────────┴──> isp_* (RGB888 / YUV444, vid_clk_i)
                                      │ YUV 4:4:4          │  │
                                      └──> bow_h264 ───────┘  │   H.264 byte stream
                                              └──> bow_dma ───┘   (kênh 0) ──> main xbar ──> VRAM
```

Từ phiên bản có camera, main crossbar có 6 device (thêm buffer capture của ISP
và cửa sổ AXI4-Lite) và peripheral bus có 9 slot (thêm ISP, I2C0, CSI2RX). Bản
có video thêm **host thứ ba (DMA)** và **video RAM 1 MiB** trên main crossbar
(3 host × 7 device), bộ mã hoá **H.264** và **DMA** trên peripheral bus
(11 slot): camera → CSI-2 → ISP → H.264 → DMA → VRAM là một luồng phần cứng
liên tục, CPU chỉ cấu hình và gửi stream đi ([ip/h264.md](ip/h264.md),
[ip/dma.md](ip/dma.md)). Slot thứ 12 của peripheral bus là khối mã khối **MKV**
(TCVN 14263:2024, [ip/mkv.md](ip/mkv.md)), chỉ có thanh ghi. **DDR2/DDR3**
(`bow_ddr`, [ip/ddr.md](ip/ddr.md)) là controller LiteDRAM (sinh từ Python) trên PHY
riêng của Bow32, có ba cổng: cửa sổ bộ nhớ 512 MiB ở `0x8000_0000` (device thứ 8 của main
crossbar), CSR của LiteDRAM ở `0x4000_C000` (8 KiB) và thanh ghi PHY/cầu ở `0x4000_E000`;
tham số `DdrEn` của `bow32_top` chọn IP thật (Arm MPS4) hay bản stub (KV260: trả lỗi
bus), `DdrMem` chọn lõi DDR2 (bo RAM) hay DDR3. **HyperRAM** (`bow_hyperram`,
[ip/hyperram.md](ip/hyperram.md)) là bộ điều khiển HyperBus tự viết (controller, read/write
buffer, BIST, PHY `ODDRE1`/`IDDRE1` + 2 MMCM): cửa sổ 256 MiB ở `0x6000_0000` (device thứ 9
của main crossbar, 32 MiB có thiết bị), thanh ghi ở `0x4000_F000`, ngắt `irq_fast[12]`;
`HrEn` chọn IP thật hay stub như `DdrEn`.
Bộ thu MIPI CSI-2 (`bow_mipi_rx`: phần số của D-PHY `bow_dphy_rx` và controller
`bow_csi2rx` nối bằng PPI) nhận các tín hiệu D-PHY `dphy_*` (trên KV260 từ
`bow_dphy_io_xusp` ở board top) và đưa RAW10 vào ISP. Đặc tả:
[ip/isp.md](ip/isp.md), [ip/csi2rx.md](ip/csi2rx.md), [ip/i2c.md](ip/i2c.md),
[ip/axil_bridge.md](ip/axil_bridge.md).

Mã nguồn: `hw/top/rtl/bow32_top.sv`. Địa chỉ và số cổng lấy từ package sinh tự
động `bow32_memmap_pkg` (xem [memory_map.md](memory_map.md)).

## CPU

Ibex cấu hình **"small"** (cấu hình được lowRISC hỗ trợ chính thức):

| Tham số | Giá trị | Ý nghĩa |
|---------|---------|---------|
| ISA | RV32IMC + Zicsr | `misa = 0x40101104` |
| `RV32M` | `RV32MFast` | nhân 3 chu kỳ, chia ~37 chu kỳ |
| `RV32ZC` | `RV32Zca` | lệnh nén chuẩn "C" |
| `RegFile` | FF (mô phỏng) / FPGA (LUTRAM trên Kria) | |
| PMP, ICache, debug | tắt | có thể bật khi học tiếp |
| `boot_addr_i` | `0x0000_0000` | PC sau reset = `0x80`, `mtvec` = `0x0` (vectored) |

Ibex chỉ hỗ trợ chế độ ngắt *vectored*: base của `mtvec` phải căn 256 byte.
Mọi tuỳ chỉnh Ibex nằm trong wrapper `hw/ip/cpu/rtl/bow_cpu_ibex.sv`: phần còn
lại của SoC không biết đến các port riêng của Ibex (CHERIoT, TRVK, lockstep...).

## Bus

Một giao thức duy nhất cho toàn SoC: chính là bus native của Ibex (tập con của
OBI) — `req/gnt` để bắt tay, `rvalid` **đúng 1 chu kỳ** sau `gnt`. Thiết bị chậm
giữ `gnt = 0`. Chi tiết: [bus.md](bus.md).

* **Main crossbar**: 3 host (instr, data, DMA) × 9 device. Mỗi device có arbiter
  round-robin riêng → instruction fetch từ flash, load/store vào SRAM và DMA ghi
  VRAM có thể diễn ra cùng chu kỳ. Grant chưa được nhận thì bị khoá (thiết bị chậm như cầu
  AXI4-Lite luôn thấy một request ổn định).
* **Peripheral bus**: cũng là `bow_bus_xbar` với 1 host, chia vùng 64 KiB thành
  các slot 4 KiB.
* Địa chỉ không ánh xạ → `err = 1` → Ibex sinh *access fault*.

## Clock và reset

* Miền clock CPU `clk_i` (50 MHz trên Kria) cho CPU, bus và mọi ngoại vi.
* Miền clock video `vid_clk_i` dùng trong pipeline pixel của ISP, toàn bộ bộ mã
  hoá H.264 và trong máy trạng thái LP / đầu ra pixel của bộ thu CSI-2 (200 MHz
  trong bản build camera, bằng `clk_i` trong bản cơ bản).
* Miền **byte clock** của bộ thu CSI-2 = HS clock của camera / 4 (114 MHz ở
  912 Mbit/s), lấy từ lane clock của D-PHY và chỉ chạy khi có HS: tìm sync,
  ghép lane, giải packet, unpack. Bản cơ bản không có D-PHY nên clock này
  nối 0.
* Miền **DDR** của `bow_ddr` (khi `DdrEn = 1`): `ddr_sys_clk_i` = CK/4 cho controller
  LiteDRAM, `ddr_clk_i` = CK của DRAM (133,33 MHz trên MPS4) cho bộ chuyển DFI và PHY
  (cùng MMCM, đồng bộ với nhau), `ddr_rd_clk_i` cùng tần số CK nhưng pha dịch được (bắt
  dữ liệu đọc), cộng hai clock ghi chỉ dùng trong wrapper chân của board. Reset liên kết
  `ddr_rst_ni & sys_rst_n` (MMCM lock) đồng bộ vào từng miền ([ip/ddr.md](ip/ddr.md)).
* Miền **HyperRAM** của `bow_hyperram` (khi `HrEn = 1`): `hr_clk_i` = CK (100 MHz trên MPS4)
  cho controller và PHY, `hr_rd_clk_i` cùng tần số, pha dịch được (bắt dữ liệu đọc), cộng
  clock ghi chỉ dùng trong wrapper chân. Cả ba bất đồng bộ với `clk_i`: lệnh và dữ liệu qua
  hai FIFO 2 clock, thanh ghi qua bắt tay bốn pha ([ip/hyperram.md](ip/hyperram.md)).
* Mọi tín hiệu qua lại giữa các miền đều qua bộ đồng bộ, bus gray hoặc RAM
  2 clock (xem [ip/isp.md](ip/isp.md), [ip/csi2rx.md](ip/csi2rx.md), [ip/ddr.md](ip/ddr.md),
  [ip/hyperram.md](ip/hyperram.md)).
* `bow_rstmgr` tạo hai miền reset (assert bất đồng bộ, nhả đồng bộ):
  * **POR** (`por_rst_n`): chỉ reset SYSCTRL — giữ *reset cause*, `BOOT_FLAG`,
    bộ phát hiện BREAK qua các lần reset hệ thống.
  * **System** (`sys_rst_n`): CPU, bus, bộ nhớ, UART, GPIO, flash controller.
    Được kích khi POR, khi phần mềm ghi `SYSCTRL.RST_CTRL`, hoặc khi UART0 RX
    bị giữ mức thấp ≥ 10 ms (BREAK). GPIO trở về chân vào, PB0/PB1 về UART1.
* Nội dung SRAM và flash **không** bị xoá khi reset (giống MCU thật).

## Ngắt

| Nguồn | Đường | `mcause` |
|-------|-------|----------|
| UART0 (RX có dữ liệu / TX rỗng) | `irq_fast_i[0]` | `0x80000010` |
| UART1 | `irq_fast_i[1]` | `0x80000011` |
| Flash (kết thúc thao tác) | `irq_fast_i[2]` | `0x80000012` |
| GPIOA (cạnh trên chân) | `irq_fast_i[3]` | `0x80000013` |
| GPIOB | `irq_fast_i[4]` | `0x80000014` |
| ISP (frame / capture xong, lỗi) | `irq_fast_i[5]` | `0x80000015` |
| I2C0 (lệnh xong) | `irq_fast_i[6]` | `0x80000016` |
| CSI2RX (FS, FE, lỗi, LOG/RAW xong) | `irq_fast_i[7]` | `0x80000017` |
| H264 (frame xong, đủ FRAMES, lỗi) | `irq_fast_i[8]` | `0x80000018` |
| DMA (kênh xong, packet, lỗi bus) | `irq_fast_i[9]` | `0x80000019` |
| MKV (lệnh xong, lệnh lỗi, lỗi phần cứng) | `irq_fast_i[10]` | `0x8000001A` |
| DDR (APPLY, chụp thô / bước pha xong, lỗi) | `irq_fast_i[11]` | `0x8000001B` |
| HyperRAM (lệnh xong, chụp thô / BIST xong, lỗi) | `irq_fast_i[12]` | `0x8000001C` |

`irq_timer_i`, `irq_external_i`, `irq_software_i` đang nối 0 — chỗ trống để học
thêm CLINT/PLIC (xem [roadmap.md](roadmap.md)).

**NMI** (`irq_nm_i`, `mcause` `0x8000001F`, vector `mtvec + 0x7C`): alert nghiêm trọng
của MKV — khối mã khối tự khoá sau `FaultLimit` lỗi phần cứng ([ip/mkv.md](ip/mkv.md)).
Không tắt được bằng `mie`; handler mặc định `bow_nmi_handler()` in thông báo rồi dừng.
Boot ROM gặp NMI cũng in `ROM trap` và dừng.

**Tường lửa DMA:** DMA đi qua `bow_bus_deny` trước main crossbar: yêu cầu của nó tới
cửa sổ MKV (`0x4000_B000…0x4000_BFFF`) trả lỗi bus, không tới được thanh ghi khoá và
không mã / giải mã thay CPU được.

## Quyết định thiết kế (và vì sao)

| Quyết định | Lý do |
|------------|-------|
| Bus = interface native của Ibex, latency cố định 1 chu kỳ | Không cần adapter, crossbar chỉ ~100 dòng, dễ đọc waveform |
| Flash mô phỏng bằng BRAM nhưng giữ ngữ nghĩa NOR | Firmware viết y như cho MCU thật (unlock, erase, program 1→0) |
| Header + CRC32 cho ảnh ứng dụng | ROM không bao giờ nhảy vào ảnh nạp dở |
| UART BREAK → reset vào loader | Trên Kria không có nút reset cho PL; host tool luôn lấy lại quyền điều khiển |
| Memory map sinh từ YAML | Một nguồn duy nhất cho RTL, C, linker script, tài liệu |
| Ibex là git submodule pin theo commit | Nâng cấp có kiểm soát, xem [ip_upgrade.md](ip_upgrade.md) |
| Filelist `.f` thay vì FuseSoC | Ít công cụ phụ thuộc; Verilator đọc trực tiếp, Vivado đọc qua `filelist.tcl` |
| ISP 1 pixel/clock, không back-pressure bên trong | Pipeline thẳng, mỗi stage là một module nhỏ dễ đọc; camera luôn có blanking |
| ISP có mô hình Python bit-exact | Mọi công thức kiểm chứng được từng bit; sửa RTL thì sửa mô hình |
| Bộ thu MIPI CSI-2 tự viết thay MIPI CSI-2 RX Subsystem của AMD (bản camera đầu tiên dùng IP này) | Mục tiêu học: D-PHY, SerDes, CDC, protocol đều đọc được trong RTL; không cần IP/license của hãng; mọi thứ quan sát được (bộ đếm lỗi, log packet, word thô, bản đồ eye); phần IP độc lập công nghệ, chỉ `bow_dphy_io_xusp` dùng primitive UltraScale+ |
| Eye của D-PHY hiệu chỉnh bằng phần mềm lúc chạy | Clock tới ISERDES trễ 0,4–1,4 ns so với data tuỳ PVT: static timing không đạt được; IDELAY + quét tap trong driver là đủ |
| Bộ mã hoá H.264 tự viết, intra only (`I_16x16`, CAVLC) | Đọc hiểu được từng khối theo chuẩn; không cần frame tham chiếu nên nằm gọn trong FPGA (strip buffer 4 × 16 dòng); stream giải mã được bằng mọi trình phát |
| Stream H.264 đi qua DMA vào video RAM riêng | Phần cứng nối liền camera → bộ nhớ; CPU (50 MHz) không phải chép dữ liệu; VRAM ở cổng crossbar riêng nên không làm chậm SRAM của CPU |
| MKV: một nửa vòng mỗi chu kỳ, lược đồ khoá tính một lần vào LUTRAM | Hai nửa của hàm vòng cùng dạng "cộng khoá → S-box → lớp tuyến tính" nên dùng chung một lớp S-box; giải mã đọc khoá vòng theo thứ tự ngược, không phải tính lại; 4R + 4 chu kỳ/khối (gồm lượt kiểm tra) vẫn nhanh hơn nhiều so với CPU ghi/đọc thanh ghi |
| MKV theo TCVN 14263:2024, mô hình giữ cả bản dự thảo | Bản chuẩn là một mã khác bản dự thảo (R, xoay cột trong MixWords, hằng số lược đồ khoá): IP đổi `ID` sang phiên bản 2; mô hình tái tạo cả hai Phụ lục A, chứng minh ba điểm đó là toàn bộ khác biệt ([ip/mkv.md](ip/mkv.md)) |
| DDR: controller LiteDRAM, PHY riêng nối qua DFI | Controller đã chạy trên rất nhiều board, sinh lại được từ cấu hình; PHY của LiteDRAM không làm được DDR2 trên UltraScale+, không điều khiển level shifter và không chỉnh được pha đọc trên cả chu kỳ, nên Bow32 giữ PHY riêng |
| PHY DDR chỉ dùng `ODDRE1`/`IDDRE1` + MMCM dịch pha, hiệu chỉnh bằng phần mềm | Đọc hiểu được từng chu kỳ ở chân; không cần IP MIG/license; cùng cách dùng được trên mọi FPGA có DDR register ở I/O. Giá phải trả: CK thấp (DDR2-266, DDR3 chỉ chế độ DLL-off) |
| Bản loopback với DRAM giả lập tổng hợp được (`bow_ddr_lb`) | Chạy được trên bo trước khi có chip DRAM: PHY vẫn lái chân thật, dữ liệu đọc đi qua IOB/IDDR/FIFO; DRAM giả lập kiểm tra mọi luật JEDEC nên lỗi của controller lộ ra ngay ở thanh ghi `DBG` |
| HyperRAM: controller tự viết, không dùng IP của hãng | HyperBus đơn giản (một CS#, 13 chân: DQ[7:0], RWDS, CS#, CK/CK#, RESET#) nên toàn bộ giao thức đọc được trong RTL; điều khiển được DIR/OE của level shifter và lịch đổi chiều theo từng chu kỳ; dữ liệu đọc được căn theo RWDS như chuẩn nhưng lấy mẫu bằng clock của FPGA (pha hiệu chỉnh bằng phần mềm), nên không cần dùng RWDS làm clock |
| HyperRAM: mọi thông số thời gian là thanh ghi, controller giữ bản sao CR0/CR1 | Đổi chip / tần số / bo (có hay không level shifter) mà không sửa RTL; giao dịch vượt tCSM bị từ chối thay vì vi phạm; latency lấy từ bản sao nên không đọc lại thiết bị trước mỗi giao dịch |

## Quy ước mã nguồn

* RTL theo [lowRISC Verilog style guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md):
  `_i/_o` cho port, `_ni` cho tín hiệu tích cực thấp, `_q/_d` cho thanh ghi,
  tham số `CamelCase`, module tiền tố `bow_` (IP) và `bow32_` (cấp SoC).
* C: C11 (gnu11), freestanding, tiền tố `bow_`; thanh ghi truy cập qua struct
  `volatile` (`UART0->STATUS`).
* Mỗi IP có `rtl/`, filelist `<ip>.f`, header C trong `sw/common/include/` và
  tài liệu trong `docs/ip/`.
