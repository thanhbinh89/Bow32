# CPU: Ibex (`bow_cpu_ibex`)

RTL: `hw/ip/cpu/rtl/bow_cpu_ibex.sv` · Lõi: `hw/vendor/lowrisc_ibex` (submodule)

Wrapper nhận hai cổng bus Bow32 (`instr`, `data`) và các đường ngắt. Bên trong
nó cấu hình `ibex_top` và nối cố định các tính năng không dùng:

| Port Ibex | Bow32 |
|-----------|-------|
| `boot_addr_i` | `BootAddr` (memory map, `0x0`) |
| `irq_fast_i[14:0]` | ngắt ngoại vi (UART0/1, flash, GPIOA/B) |
| `irq_timer_i`, `irq_external_i`, `irq_software_i` | 0 (chưa có CLINT/PLIC) |
| `debug_req_i` | 0 (chưa có debug module) |
| `fetch_enable_i` | `IbexMuBiOn` |
| `cheriot_enable_i` | `IbexMuBiOff` |
| `*_intg_*`, scrambling, TRVK, lockstep, shadow ports | nối 0 / bỏ trống |

Tham số có thể đổi qua wrapper: `RegFile`, `RV32M`, `RV32B`, `RV32ZC`.
Ví dụ bật bitmanip: `RV32B = ibex_pkg::RV32BBalanced` và thêm `_zba_zbb_zbs`
vào `-march` trong `sw/mk/common.mk`.

## Primitive phụ thuộc công nghệ

Ibex cần `prim_buf`, `prim_clock_gating` (bắt buộc) và vài primitive khác:

| Filelist | Dùng cho |
|----------|----------|
| `hw/vendor/lowrisc_ibex_prim_generic.f` | mô phỏng / lint (clock gate dạng latch) |
| `hw/fpga/common/prim_xilinx.f` | FPGA: clock gate pass-through (định nghĩa `BOW32_FPGA_CLOCK_GATING` để dùng `BUFGCE`) |

## Tài liệu Ibex

* User guide: https://ibex-core.readthedocs.io
* Exceptions / interrupts: mục *Exceptions and Interrupts*
* CSR: mục *Control and Status Registers* (`mcycle`, `minstret`, `mtvec`...)
