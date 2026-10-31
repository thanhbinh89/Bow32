# Bow32 — MCU RISC-V 32-bit cho mục đích học tập

Bow32 là một vi điều khiển (MCU) 32-bit đơn giản, xây dựng quanh lõi
[lowRISC Ibex](https://github.com/lowRISC/ibex) (RV32IMC), được thiết kế để
**học kiến trúc SoC từ RTL tới firmware** và kiểm chứng trên board
**AMD Kria KV260 (SOM K26)**. Bow32 có một **ISP (image signal processor)**,
một **bộ thu MIPI CSI-2** tự viết (D-PHY trên primitive I/O của UltraScale+,
không dùng IP của AMD) và một **bộ mã hoá H.264** tự viết cùng **DMA** và
**video RAM 1 MiB**: camera → CSI-2 → ISP → H.264 → DMA → RAM là một luồng
phần cứng liền mạch, ra file **MP4** trên PC. Chạy thử với Raspberry Pi camera
v2 (IMX219) của KV260 ở **1080p30** hoặc **720p60**.

```
                 +-----------------------------------------------------------+
                 |                         bow32_top                         |
                 |                                                           |
                 |  +-----------+ instr +------------------+                 |
                 |  |   Ibex    |------>|                  |---> ROM   8 KiB |  0x0000_0000
                 |  |  RV32IMC  |       |   main crossbar  |---> FLASH 128KiB|  0x0800_0000
                 |  | (2-stage) |------>|  3 hosts x 7 dev |---> SRAM  16KiB |  0x2000_0000
                 |  +-----------+ data  +------------------+---> VRAM  1 MiB |  0x2400_0000
                 |        ^           DMA --^      |  +-----> ISP buffer     |  0x3000_0000
                 |        ^ irq_fast[9:0]          |  +--------> AXI4-Lite --+--> m_axil_*  0x5000_0000
                 |        |                        v                         |
                 |        |                       +----------------+         |
                 |        +-----------------------| periph xbar    |         |  0x4000_0000
                 |                                |  SYSCTRL       |         |  + reset manager
                 |                                |  FLASH_CTRL    |         |
   uart0 <-------+--------------------------------|  UART0         |         |  console / bootloader
                 |                           +----|  UART1         |         |
   gpioa[7:0] <--+---------------------------|----|  GPIOA         |         |  PA7 = camera enable
   gpiob[7:0] <--+---------------------------+--->|  GPIOB         |         |  PB0/PB1 = UART1
                 |                                |  ISP regs -----+---+     |  0x4000_6000
   i2c0 <--------+--------------------------------|  I2C0          |   |     |  0x4000_7000
                 |       +------------------------|  CSI2RX regs   |   |     |  0x4000_8000
                 |       |                  +-----|  H264 regs     |   |     |  0x4000_9000
                 |       |                  |  +--|  DMA regs      |   |     |  0x4000_A000
                 |       |                  |  |  +----------------+   |     |
                 |       v                  |  |                       v     |
   D-PHY (J9) ---+--> CSI-2 RX ---> ISP: BLC DPC WB demosaic CCM gamma CSC --+--> isp_* RGB/YUV
   (2 lane)      |                          v  v                YUV 4:4:4    |
                 |          H.264 encoder (intra, CAVLC) --stream--> DMA ----+--> VRAM
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
| **ISP** | RAW10 Bayer → RGB888 / YUV444, 1 pixel/clock (200 MHz trên KV260): BLC, DPC, white balance, demosaic, CCM, gamma, CSC; thống kê AE/AWB/AF + histogram; capture có lọc thu nhỏ; test pattern; 2 miền clock ([docs/ip/isp.md](docs/ip/isp.md)) |
| **Bộ thu MIPI CSI-2** | D-PHY RX trên primitive I/O của UltraScale+ (`IBUFDS_DPHY`, `IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`; không dùng IP AMD) + CSI-2 RX: 1–2 lane, máy trạng thái LP, tìm sync, ECC, CRC-16, lọc VC/DT, RAW10/RAW8 → AXI4-Stream 1 pixel/clock; eye hiệu chỉnh bằng phần mềm; bộ đếm lỗi, log packet, word thô của PHY; 2 × 912 Mbit/s với IMX219 ([docs/ip/csi2rx.md](docs/ip/csi2rx.md)) |
| **Bộ mã hoá H.264** | Constrained Baseline, intra only (IDR mỗi frame, `I_16x16` đủ 4 mode luma + 4 mode chroma, chọn mode theo SAD), CAVLC, 4:2:0, QP 10…51 mỗi frame, cờ deblocking; 392 chu kỳ/macroblock ở 200 MHz (1080p tới ~62 fps); stream Annex B chuẩn, bit-exact với mô hình Python, giải mã bằng FFmpeg trùng từng pixel ([docs/ip/h264.md](docs/ip/h264.md)) |
| **DMA** | 2 kênh, bus master thứ ba của main crossbar: memory→memory, stream→memory (tuyến tính / vòng / bỏ), đếm packet (frame), lỗi bus, ngắt ([docs/ip/dma.md](docs/ip/dma.md)) |
| **Video RAM** | 1 MiB (UltraRAM), 0 wait-state, cổng crossbar riêng cho buffer DMA / stream video |
| I2C master | 100/400 kHz, START lặp lại, clock stretching; điều khiển cảm biến camera |
| Cầu AXI4-Lite | cửa sổ `0x5000_0000` tới IP AXI4-Lite của block design (hiện để trống), timeout → bus error |
| Công cụ | `bow32_flash.py` (nạp qua UART), `bow32_cam.py` (chụp ảnh → PNG, xem trực tiếp), `bow32_video.py` (quay video → `.h264` + `.mp4`), `bow32_image.py` (header/CRC), `gen_memmap.py` (memory map một nguồn), `isp_model.py` (mô hình ISP bit-exact), `csi2_model.py` (mô hình bộ thu CSI-2), `h264/h264_model.py` (mô hình encoder bit-exact + decoder), `h264/mp4.py` (ghi MP4, không cần ffmpeg) |
| Kiểm chứng | Lint Verilator `-Wall`, 9 test mô phỏng hệ thống (boot, nạp qua UART, BREAK, flash, ngắt, GPIO, camera, CSI-2, H.264) + test riêng của ISP, bộ thu CSI-2 và bộ mã hoá H.264 so với mô hình Python, chạy trong CI; test chân D-PHY bằng xsim (cần Vivado) |
| FPGA | Flow Vivado bằng script cho Kria KV260 (bản cơ bản và bản camera `kv260_cam`, không cần IP/license MIPI), overlay để nạp bằng `xmutil` trên Linux |

## Bắt đầu nhanh

```bash
git clone --recursive https://github.com/thanhbinh89/Bow32.git
cd Bow32
# (đã clone mà quên --recursive)  git submodule update --init --recursive

pip install -r requirements.txt   # pyserial, PyYAML

make sw        # boot ROM + ứng dụng mẫu   -> build/sw/
make lint      # lint RTL
make test      # chạy toàn bộ test mô phỏng (Verilator)
make test-ip   # test riêng của ISP, bộ thu CSI-2 và bộ mã hoá H.264 (so với mô hình Python)
make test-tools # unit test của công cụ Python
make test-fpga-dv # test mức chân D-PHY I/O + bộ thu CSI-2 (xsim, cần Vivado)
make fpga      # bitstream + firmware cho Kria KV260 (cần Vivado)
```

Nạp ứng dụng vào flash qua UART0 (board đang chạy bitstream Bow32):

```bash
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/hello/hello.bin
python3 tools/bow32_flash.py -p /dev/ttyUSB0 monitor
```

Camera (Raspberry Pi camera v2 trên J9, bitstream `kv260_cam`), xem
[docs/camera_kv260.md](docs/camera_kv260.md):

```bash
make fpga BOARD=kv260_cam
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/camera/camera.bin
python3 tools/bow32_cam.py -p /dev/ttyUSB0 --fast 921600 cmd cam "ae on" "awb on"
python3 tools/bow32_cam.py -p /dev/ttyUSB0 -b 921600 snap -o frame.png
# kiểm tra bộ thu CSI-2: nạp build/sw/csi2_test/csi2_test.bin, gõ `test`
```

Video H.264 → MP4 (camera → ISP → H.264 → DMA → video RAM → UART), xem
[docs/video_kv260.md](docs/video_kv260.md):

```bash
python3 tools/bow32_flash.py -p /dev/ttyUSB0 flash build/sw/video/video.bin
python3 tools/bow32_video.py -p /dev/ttyUSB0 --fast 921600 rec -n 45 --skip 1 -o video.mp4
```

### Công cụ cần có

| Công cụ | Phiên bản | Dùng cho |
|---------|-----------|----------|
| RISC-V GCC bare-metal (`riscv64-unknown-elf-`, `riscv32-unknown-elf-` hoặc `riscv-none-elf-`) | ≥ 12 | firmware |
| Verilator | ≥ 5.0 (CI dùng 5.020) | lint, mô phỏng |
| Python | ≥ 3.8 | công cụ host |
| Vivado (kèm `bootgen`) | 2022.2 trở lên, có hỗ trợ K26 (đã thử 2025.2; không cần IP MIPI hay license) | FPGA, test chân D-PHY (xsim) |
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
│   │   ├── mem/                  #   RAM 1 port, SRAM, ROM, video RAM (UltraRAM)
│   │   ├── flash/                #   flash nội + controller
│   │   ├── uart/                 #   UART
│   │   ├── gpio/                 #   GPIO / IOPAD (2 port, chức năng thay thế)
│   │   ├── isp/                  #   ISP: rtl/ + dv/ (test bit-exact với mô hình)
│   │   ├── csi2rx/               #   bộ thu MIPI CSI-2: rtl/ + dv/ (mô hình máy phát D-PHY)
│   │   ├── h264/                 #   bộ mã hoá H.264: rtl/ + dv/ (test bit-exact với mô hình)
│   │   ├── dma/                  #   DMA 2 kênh (bus master)
│   │   ├── i2c/                  #   I2C master
│   │   ├── axil/                 #   cầu Bow32 bus -> AXI4-Lite
│   │   ├── sysctrl/              #   system controller + reset manager
│   │   └── common/               #   FIFO (cả FIFO 2 clock), synchronizer, CDC, RAM 2 port
│   ├── top/
│   │   ├── data/bow32_memmap.yaml#   memory map: NGUỒN DUY NHẤT
│   │   └── rtl/                  #   bow32_top.sv + package sinh tự động
│   ├── fpga/
│   │   ├── common/               #   primitive cho Xilinx, đọc filelist bằng Tcl,
│   │   │                         #   rtl/: D-PHY I/O UltraScale+, dv/: test chân D-PHY (xsim)
│   │   ├── kv260/                #   top board, XDC, Tcl Vivado, overlay Linux
│   │   └── kv260_cam/            #   bản camera: D-PHY J9 -> bộ thu CSI-2, clock video 200 MHz
│   └── lint/                     # waiver Verilator
├── sim/                          # testbench hệ thống (Verilator)
├── sw/
│   ├── common/                   # HAL, driver (UART, I2C, ISP, CSI-2 RX, IMX219, H.264, DMA...), crt0, linker script
│   ├── bootrom/                  # romcode: boot + UART loader
│   ├── apps/                     # hello, uart_irq, flash_demo, gpio_demo, camera, csi2_test, video
│   └── mk/                       # Makefile dùng chung
├── tools/                        # công cụ Python phía host (+ isp/, csi2/, h264/: mô hình, MP4)
├── docs/                         # tài liệu (tiếng Việt)
└── .github/workflows/ci.yml      # CI: gen-check, sw, test-tools, lint, test, ISP / CSI-2 RX / H.264 dv
```

## Tài liệu

| Tài liệu | Nội dung |
|----------|----------|
| [docs/architecture.md](docs/architecture.md) | Kiến trúc tổng thể, clock/reset, ngắt, quyết định thiết kế |
| [docs/memory_map.md](docs/memory_map.md) | Bản đồ bộ nhớ (sinh tự động) |
| [docs/bus.md](docs/bus.md) | Giao thức bus, crossbar, cách gắn thiết bị mới |
| [docs/ip/](docs/ip/) | Đặc tả từng IP và thanh ghi: CPU, UART, GPIO, flash, sysctrl, bộ nhớ, ISP, bộ thu CSI-2, H.264, DMA, I2C, cầu AXI4-Lite |
| [docs/ip/isp.md](docs/ip/isp.md) | ISP: pipeline, công thức từng stage, thống kê, capture, thanh ghi |
| [docs/ip/csi2rx.md](docs/ip/csi2rx.md) | Bộ thu MIPI CSI-2: D-PHY, I/O UltraScale+, CDC, packet, thanh ghi, hiệu chỉnh eye, ràng buộc |
| [docs/camera_kv260.md](docs/camera_kv260.md) | Chạy camera trên KV260: bitstream, ứng dụng `camera` và `csi2_test`, chụp ảnh về PC |
| [docs/ip/h264.md](docs/ip/h264.md) | Bộ mã hoá H.264: kiến trúc, các khối, quyết định của encoder, stream, thanh ghi, kiểm chứng |
| [docs/ip/dma.md](docs/ip/dma.md) | DMA: chế độ M2M / stream, ring buffer, thanh ghi |
| [docs/video_kv260.md](docs/video_kv260.md) | Quay video H.264 / MP4 trên KV260: ứng dụng `video`, `bow32_video.py`, kết quả |
| [docs/boot.md](docs/boot.md) | Quy trình boot, định dạng ảnh, giao thức UART loader |
| [docs/simulation.md](docs/simulation.md) | Chạy mô phỏng, xem waveform, viết test mới |
| [docs/fpga_kria.md](docs/fpga_kria.md) | Build và chạy trên Kria KV260 |
| [docs/adding_an_ip.md](docs/adding_an_ip.md) | Hướng dẫn thêm IP mới (ví dụ GPIO) |
| [docs/ip_upgrade.md](docs/ip_upgrade.md) | Nâng cấp Ibex và các IP, quản lý phiên bản |
| [docs/roadmap.md](docs/roadmap.md) | Lộ trình học / mở rộng tiếp theo |

## Giấy phép

Mã nguồn Bow32 dùng giấy phép Apache-2.0 (giống Ibex), xem [LICENSE](LICENSE).
Ibex và các primitive của lowRISC giữ giấy phép gốc trong submodule.
