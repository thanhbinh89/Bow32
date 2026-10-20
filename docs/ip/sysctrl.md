# System controller (`bow_sysctrl`) và reset manager (`bow_rstmgr`)

RTL: `hw/ip/sysctrl/rtl/` · Header: `sw/common/include/bow_sysctrl.h`

## Reset

```
rst_ni (board, async) ──> [2FF sync] ──> por_rst_n ──> SYSCTRL (giữ qua reset hệ thống)
                                          │
        sys_rst_req (SW / BREAK) ───> [bộ đếm 32 chu kỳ] ──> sys_rst_n ──> CPU, bus, IP
```

| Nguồn reset | Reset miền | `RST_CAUSE` |
|-------------|-----------|-------------|
| Board (`rst_ni`, trên Kria là `pl_resetn0`) | POR + system | `POR` |
| Ghi `RST_CTRL = 0x52535421` ("RST!") | system | `SW` |
| UART0 RX ở mức thấp ≥ `BreakCycles` (10 ms) | system | `BREAK` |

## Thanh ghi (`SYSCTRL`, `0x4000_0000`)

| Offset | Tên | Quyền | Mô tả |
|-------:|-----|-------|-------|
| `0x00` | `CHIP_ID` | R | `0xB0320100` |
| `0x04` | `CLK_FREQ` | R | tần số clock hệ thống (Hz) — firmware dùng để tính baud, delay |
| `0x08` | `RST_CAUSE` | R/W1C | `[0]` POR `[1]` SW `[2]` BREAK (cộng dồn tới khi bị xoá) |
| `0x0C` | `RST_CTRL` | W | ghi `0x52535421` → reset hệ thống |
| `0x10` | `BOOT_FLAG` | RW | thanh ghi nháp sống qua reset hệ thống; ROM hiểu `"LOAD"` (`0x4C4F4144`) và `"APP!"` (`0x41505021`) |
| `0x14` | `BOOT_WAIT` | R | thời gian (ms) ROM chờ host trước khi chạy ứng dụng |
| `0x18` | `BOOT_BAUD` | R | baud ROM dùng trên UART0 |
| `0x1C` | `BRK_CTRL` | RW | `[0]` cho phép BREAK reset (mặc định 1) |

`BOOT_WAIT`, `BOOT_BAUD`, `CLK_FREQ` là tham số của `bow32_top` — testbench
dùng 1 ms và 1 Mbaud để mô phỏng nhanh, board dùng 300 ms và 115200.

## Ví dụ

```c
if (SYSCTRL->RST_CAUSE & SYSCTRL_RST_CAUSE_SW) { ... }
bow_system_reset(BOOT_FLAG_LOADER);   // khởi động lại vào UART loader
```
