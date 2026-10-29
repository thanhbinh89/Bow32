# Kiến trúc Bow32

## Sơ đồ khối

```
             clk_i ──────────────────────────────────────────────┐
             rst_ni ──> bow_rstmgr ──> por_rst_n (SYSCTRL)        │
                           ^    └────> sys_rst_n (mọi khối khác)  │
                           │ sys_rst_req                          │
 ┌─────────────────────────┼──────────────────────────────────────┼──┐
 │  bow_cpu_ibex           │                                      │  │
 │  ┌───────────────┐      │       bow_bus_xbar (main)            │  │
 │  │ ibex_top      │ instr├──────>┌──────────────┐               │  │
 │  │ RV32IMC       │      │       │ decode + RR  │──> bow_rom    │  │
 │  │               │ data ├──────>│ arbiter/dev  │──> bow_flash ─┼──┤ (mem port)
 │  └───────▲───────┘      │       └──────────────┘──> bow_sram   │  │
 │          │irq_fast[6:0] │              │                       │  │
 └──────────┼──────────────┼──────────────┼───────────────────────┘  │
            │              │       bow_bus_xbar (periph, 1 host)     │
            │              │       ┌──────────────┐                  │
            │              └───────│ SYSCTRL      │<── uart0_rx (BREAK detect)
            │                      │ FLASH_CTRL   │── reg port của bow_flash
            ├──────────────────────│ UART0        │<─> uart0_rx/tx
            ├──────────────────────│ UART1        │──┐ chức năng thay thế
            ├──────────────────────│ GPIOA        │<─┼─> gpioa[7:0]   (PA7 = bật camera trên KV260)
            ├──────────────────────│ GPIOB        │<─┴─> gpiob[7:0]  (PB0/PB1 = UART1 TX/RX)
            ├──────────────────────│ ISP (regs)   │──┐
            └──────────────────────│ I2C0         │<─┼─> scl/sda (open drain)
                                   └──────────────┘  │
   main xbar ──> ISP capture buffer (0x3000_0000) ───┤
   main xbar ──> bow_axil_bridge ──> m_axil_* (AXI4-Lite, 0x5000_0000)
                                                     │
   cam_* (RAW10, vid_clk_i) ──> bow_isp ─────────────┴──> isp_* (RGB888 / YUV444, vid_clk_i)
```

Từ phiên bản có camera, main crossbar có 6 device (thêm buffer capture của ISP
và cửa sổ AXI4-Lite) và peripheral bus có 8 slot (thêm ISP, I2C0). Đặc tả:
[ip/isp.md](ip/isp.md), [ip/i2c.md](ip/i2c.md), [ip/axil_bridge.md](ip/axil_bridge.md).

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

* **Main crossbar**: 2 host (instr, data) × 6 device. Mỗi device có arbiter
  round-robin riêng → instruction fetch từ flash và load/store vào SRAM có thể
  diễn ra cùng chu kỳ. Grant chưa được nhận thì bị khoá (thiết bị chậm như cầu
  AXI4-Lite luôn thấy một request ổn định).
* **Peripheral bus**: cũng là `bow_bus_xbar` với 1 host, chia vùng 64 KiB thành
  các slot 4 KiB.
* Địa chỉ không ánh xạ → `err = 1` → Ibex sinh *access fault*.

## Clock và reset

* Miền clock CPU `clk_i` (50 MHz trên Kria) cho CPU, bus và mọi ngoại vi.
* Miền clock video `vid_clk_i` chỉ dùng trong pipeline pixel của ISP (200 MHz
  trong bản build camera, bằng `clk_i` trong bản cơ bản). Mọi tín hiệu qua lại
  hai miền đều qua bộ đồng bộ (xem [ip/isp.md](ip/isp.md)).
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

`irq_timer_i`, `irq_external_i`, `irq_software_i` đang nối 0 — chỗ trống để học
thêm CLINT/PLIC (xem [roadmap.md](roadmap.md)).

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
| CSI-2 RX tạm dùng IP của AMD (trong block design) | Có camera chạy ngay; bộ thu riêng của Bow32 là bước học sau |

## Quy ước mã nguồn

* RTL theo [lowRISC Verilog style guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md):
  `_i/_o` cho port, `_ni` cho tín hiệu tích cực thấp, `_q/_d` cho thanh ghi,
  tham số `CamelCase`, module tiền tố `bow_` (IP) và `bow32_` (cấp SoC).
* C: C11 (gnu11), freestanding, tiền tố `bow_`; thanh ghi truy cập qua struct
  `volatile` (`UART0->STATUS`).
* Mỗi IP có `rtl/`, filelist `<ip>.f`, header C trong `sw/common/include/` và
  tài liệu trong `docs/ip/`.
