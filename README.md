# Bow32 — MCU RISC-V 32-bit cho mục đích học tập

Bow32 là một vi điều khiển (MCU) 32-bit đơn giản, xây dựng quanh lõi
[lowRISC Ibex](https://github.com/lowRISC/ibex) (RV32IMC), được thiết kế để
**học kiến trúc SoC từ RTL tới firmware** và kiểm chứng trên board
**AMD Kria KV260 (SOM K26)**.

```
                 +-----------------------------------------------------------+
                 |                         bow32_top                         |
                 |                                                           |
                 |  +-----------+ instr +------------------+                 |
                 |  |   Ibex    |------>|                  |---> ROM   8 KiB |  0x0000_0000
                 |  |  RV32IMC  |       |   main crossbar  |---> FLASH 128KiB|  0x0800_0000
                 |  | (2-stage) |------>|  2 hosts x 4 dev |---> SRAM  16KiB |  0x2000_0000
                 |  +-----------+ data  +------------------+        |        |
                 |        ^ irq_fast[4:0]                           v        |
                 |        |                               +----------------+ |
                 |        +-------------------------------| periph xbar    | |  0x4000_0000
                 |                                        |  SYSCTRL       | |  + reset manager
                 |                                        |  FLASH_CTRL    | |
   uart0 <-------+----------------------------------------|  UART0         | |  console / bootloader
                 |                                   +----|  UART1         | |
   gpioa[7:0] <--+-----------------------------------|----|  GPIOA         | |  0x4000_4000
   gpiob[7:0] <--+-----------------------------------+--->|  GPIOB         | |  PB0/PB1 = UART1
                 |                                        +----------------+ |
                 +-----------------------------------------------------------+
```

## Tính năng

| Khối | Mô tả |
|------|-------|
| CPU | Ibex cấu hình "small": RV32IMC + Zicsr, pipeline 2 tầng, mul 3 chu kỳ, ngắt nhanh (fast IRQ) |
| Bus | Giao thức kiểu OBI (giống bus native của Ibex), crossbar có arbiter round-robin, bus error cho địa chỉ không ánh xạ |
| SRAM | 16 KiB, 0 wait-state (BRAM) |
| Flash nội | 128 KiB, mô phỏng ngữ nghĩa NOR flash: erase theo page 1 KiB / mass erase, program chỉ xoá bit 1→0, khoá bằng key, có ngắt EOP |
| Boot ROM | 8 KiB, kiểm tra header + CRC32 của ảnh trong flash, **UART loader** để nạp chương trình vào flash |
| UART ×2 | 8N1, baud lập trình được, FIFO TX/RX 16 byte, ngắt |
| GPIO (IOPAD) ×2 | 2 port × 8 chân: hướng, push-pull/open-drain, set/clear/toggle nguyên tử, ngắt theo cạnh, **chức năng thay thế** (UART1 trên PB0/PB1); 6 chân ra PMOD của KV260 |
| SYSCTRL | Chip ID, tần số clock, nguyên nhân reset, soft reset, **UART BREAK → reset vào bootloader** |
| Công cụ | `bow32_flash.py` (nạp qua UART), `bow32_image.py` (header/CRC), `gen_memmap.py` (memory map một nguồn) |
| Kiểm chứng | Lint Verilator `-Wall`, 6 test mô phỏng hệ thống (boot, nạp qua UART, BREAK, flash, ngắt, GPIO) chạy trong CI |
| FPGA | Flow Vivado bằng script cho Kria KV260, overlay để nạp bằng `xmutil` trên Linux |

## Bắt đầu nhanh

```bash
git clone --recursive https://github.com/thanhbinh89/Bow32.git
cd Bow32
# (đã clone mà quên --recursive)  git submodule update --init --recursive

pip install -r requirements.txt   # pyserial, PyYAML

make sw        # boot ROM + ứng dụng mẫu   -> build/sw/
make lint      # lint RTL
make test      # chạy toàn bộ test mô phỏng (Verilator)
make fpga      # bitstream + firmware cho Kria KV260 (cần Vivado)
```

Nạp ứng dụng vào flash qua UART0 (board đang chạy bitstream Bow32):

```bash
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/hello/hello.bin
python3 tools/bow32_flash.py -p /dev/ttyUSB0 monitor
```

### Công cụ cần có

| Công cụ | Phiên bản | Dùng cho |
|---------|-----------|----------|
| RISC-V GCC bare-metal (`riscv64-unknown-elf-`, `riscv32-unknown-elf-` hoặc `riscv-none-elf-`) | ≥ 12 | firmware |
| Verilator | ≥ 5.0 (CI dùng 5.020) | lint, mô phỏng |
| Python | ≥ 3.8 | công cụ host |
| Vivado (kèm `bootgen`) | 2022.2 trở lên, có hỗ trợ K26 | FPGA |
| `dtc` (device-tree-compiler) | | overlay cho Kria |

Ubuntu 24.04: `sudo apt install gcc-riscv64-unknown-elf verilator python3-serial python3-yaml device-tree-compiler`

## Cấu trúc thư mục

```
Bow32/
├── hw/
│   ├── vendor/lowrisc_ibex/      # Ibex (git submodule, pin theo commit)
│   ├── vendor/*.f                # filelist của Ibex
│   ├── ip/                       # IP của Bow32, mỗi IP: rtl/ + <ip>.f
│   │   ├── bus/                  #   bus package, crossbar, arbiter
│   │   ├── cpu/                  #   wrapper Ibex (cô lập interface CPU)
│   │   ├── mem/                  #   RAM 1 port, SRAM, ROM
│   │   ├── flash/                #   flash nội + controller
│   │   ├── uart/                 #   UART
│   │   ├── gpio/                 #   GPIO / IOPAD (2 port, chức năng thay thế)
│   │   ├── sysctrl/              #   system controller + reset manager
│   │   └── common/               #   FIFO, synchronizer
│   ├── top/
│   │   ├── data/bow32_memmap.yaml#   memory map: NGUỒN DUY NHẤT
│   │   └── rtl/                  #   bow32_top.sv + package sinh tự động
│   ├── fpga/
│   │   ├── common/               #   primitive cho Xilinx, đọc filelist bằng Tcl
│   │   └── kv260/                #   top board, XDC, Tcl Vivado, overlay Linux
│   └── lint/                     # waiver Verilator
├── sim/                          # testbench hệ thống (Verilator)
├── sw/
│   ├── common/                   # HAL, crt0, linker script, header
│   ├── bootrom/                  # romcode: boot + UART loader
│   ├── apps/                     # hello, uart_irq, flash_demo, gpio_demo
│   └── mk/                       # Makefile dùng chung
├── tools/                        # công cụ Python phía host
├── docs/                         # tài liệu (tiếng Việt)
└── .github/workflows/ci.yml      # CI: gen-check, sw, lint, test
```

## Tài liệu

| Tài liệu | Nội dung |
|----------|----------|
| [docs/architecture.md](docs/architecture.md) | Kiến trúc tổng thể, clock/reset, ngắt, quyết định thiết kế |
| [docs/memory_map.md](docs/memory_map.md) | Bản đồ bộ nhớ (sinh tự động) |
| [docs/bus.md](docs/bus.md) | Giao thức bus, crossbar, cách gắn thiết bị mới |
| [docs/ip/](docs/ip/) | Đặc tả từng IP và thanh ghi: CPU, UART, GPIO, flash, sysctrl, bộ nhớ |
| [docs/boot.md](docs/boot.md) | Quy trình boot, định dạng ảnh, giao thức UART loader |
| [docs/simulation.md](docs/simulation.md) | Chạy mô phỏng, xem waveform, viết test mới |
| [docs/fpga_kria.md](docs/fpga_kria.md) | Build và chạy trên Kria KV260 |
| [docs/adding_an_ip.md](docs/adding_an_ip.md) | Hướng dẫn thêm IP mới (ví dụ GPIO) |
| [docs/ip_upgrade.md](docs/ip_upgrade.md) | Nâng cấp Ibex và các IP, quản lý phiên bản |
| [docs/roadmap.md](docs/roadmap.md) | Lộ trình học / mở rộng tiếp theo |

## Giấy phép

Mã nguồn Bow32 dùng giấy phép Apache-2.0 (giống Ibex), xem [LICENSE](LICENSE).
Ibex và các primitive của lowRISC giữ giấy phép gốc trong submodule.
