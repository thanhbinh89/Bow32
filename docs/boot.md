# Boot ROM, ảnh ứng dụng và UART loader

Mã nguồn: `sw/bootrom/` (≈3.3 KiB trong ROM 8 KiB) · Host tool: `tools/bow32_flash.py`

## Quy trình boot

Ibex bắt đầu tại `0x0000_0080` (boot_addr + 0x80). ROM khởi tạo stack/bss trong
SRAM, cấu hình UART0 theo `SYSCTRL.BOOT_BAUD`, in banner rồi quyết định:

```
                      reset
                        │
          RST_CAUSE.BREAK? ──yes──────────────┐
                        │no                    │
     BOOT_FLAG == "LOAD"? ──yes───────────────┤
                        │no                    │
   ảnh trong flash hợp lệ? ──no───────────────┤
                        │yes                   ▼
     BOOT_FLAG == "APP!"? ──yes──┐       UART loader (vô hạn)
                        │no      │             ▲
   chờ BOOT_WAIT ms một byte     │             │
   0xA5 trên UART0 ──nhận được───┼─────────────┘
                        │hết giờ │
                        ▼        ▼
                 nhảy tới hdr->entry (ứng dụng)
```

Ví dụ log trên UART0 (115200 8N1):

```
Bow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1
boot: waiting 300 ms for host
boot: starting image @08000020 (2340 bytes)

Hello from Bow32!
```

Ngoại lệ trong ROM in `ROM trap: mcause=... mepc=... mtval=...` rồi dừng.

## Định dạng ảnh (`sw/common/include/bow32_image.h`)

Ảnh nằm ở đầu flash (`0x0800_0000`):

| Offset | Trường | Giá trị |
|-------:|--------|---------|
| 0x00 | `magic` | `0x32334F42` ("BO32") |
| 0x04 | `hdr_version` | 1 |
| 0x08 | `size` | số byte payload (sau header) |
| 0x0C | `crc32` | CRC-32 (zlib) của payload |
| 0x10 | `entry` | địa chỉ lệnh đầu tiên (thường `0x0800_0020` = `_start`) |
| 0x14 | `reserved[3]` | 0 |

Linker script `app_flash.ld` dành chỗ cho header (section `.image_hdr`), build
system chạy `tools/bow32_image.py patch` để điền `size` và `crc32`. ROM chỉ
nhảy vào ảnh nếu magic, version, size, entry và CRC đều đúng.

```bash
python3 tools/bow32_image.py info build/sw/hello/hello.bin
```

## Giao thức UART loader

UART0, cùng baud với ROM (115200). Mọi trường nhiều byte là little-endian, CRC
là CRC-32 của zlib (`sw/common/include/bow32_boot_proto.h`).

```
yêu cầu : 0xA5 | CMD    | LEN[2] | PAYLOAD[LEN] | CRC32[4] (tính trên CMD..PAYLOAD)
phản hồi: 0xB5 | STATUS | LEN[2] | PAYLOAD[LEN] | CRC32[4] (tính trên STATUS..PAYLOAD)
```

Byte mở đầu nằm ngoài vùng ASCII nên không lẫn với text ROM in ra. Byte chờ
quá 200 ms giữa một frame → frame bị huỷ.

| CMD | Tên | Payload yêu cầu | Payload phản hồi |
|----:|-----|-----------------|------------------|
| 0x01 | INFO | – | chip_id, rom_version, flash_base, flash_size, page_size, max_data, sram_base, sram_size (8 × u32) |
| 0x02 | ERASE | addr u32, len u32 (`len = 0xFFFFFFFF`: mass erase) | – |
| 0x03 | WRITE | addr u32 + data (≤ 256 byte, bội số của 4, addr căn word) | – |
| 0x04 | READ | addr u32, len u32 (≤ 256; ROM/flash/SRAM) | data |
| 0x05 | CRC | addr u32, len u32 | crc32 u32 |
| 0x06 | BOOT | – | – (sau đó reset với `BOOT_FLAG = "APP!"`) |
| 0x07 | RESET | – | – (reset, boot bình thường) |

STATUS: `0` OK, `1` lỗi CRC, `2` lệnh lạ, `3` tham số sai, `4` lỗi flash, `5` độ dài sai.

## Vào loader

1. **UART BREAK** (mặc định của `bow32_flash.py`): giữ TX của adapter ở mức
   thấp > 10 ms → SoC reset với `RST_CAUSE.BREAK` → ROM vào loader ngay.
2. Firmware gọi `bow_system_reset(BOOT_FLAG_LOADER)` (ví dụ: gõ `B` trong app `hello`).
3. Flash trống / ảnh hỏng → ROM tự vào loader.
4. Gửi `0xA5` trong cửa sổ `BOOT_WAIT` sau reset (`bow32_flash.py --no-break`
   liên tục gửi INFO trong khi bạn reset board).

## Dùng `bow32_flash.py`

```bash
pip install -r requirements.txt
T=tools/bow32_flash.py
python3 $T -p /dev/ttyUSB0 info
python3 $T -p /dev/ttyUSB0 flash build/sw/hello/hello.bin   # erase + write + verify CRC + boot
python3 $T -p /dev/ttyUSB0 read 0x08000000 64
python3 $T -p /dev/ttyUSB0 erase --all
python3 $T -p /dev/ttyUSB0 monitor                          # xem UART (Ctrl-C để thoát)
```

Windows: `-p COM5`. Thêm `-v` để xem text ROM in ra trong lúc kết nối.

Giao thức được kiểm tra hai phía: testbench `sim/tb/tb_bow32.sv` (test `load`)
chạy với ROM thật trong mô phỏng RTL, và `tools/tests/test_bow32_flash.py`
kiểm tra host tool với mô hình Python của loader.
