# Flash nội (`bow_flash`)

RTL: `hw/ip/flash/rtl/bow_flash.sv` · Driver: `bow_flash.h`, `bow_flash.c`

128 KiB, 128 page × 1 KiB. Trên FPGA được hiện thực bằng block RAM nhưng
**hành xử như NOR flash** để firmware được viết đúng cách:

| Thao tác | Hành vi |
|----------|---------|
| Đọc / thực thi (XIP) | 0 wait-state, qua cửa sổ `0x0800_0000` trên main bus |
| Erase page / mass erase | mọi bit về 1 (`0xFFFFFFFF`); ~1 chu kỳ / word (256 chu kỳ / page) |
| Program | ghi vào cửa sổ flash khi `CTRL.PG = 1`: `mới = cũ & dữ liệu` (chỉ xoá bit 1→0), theo byte enable |
| Khi đang bận | bus bị stall (`gnt = 0`) — code chạy từ flash vẫn đúng, chỉ chờ |
| Bảo vệ | sau reset flash bị **khoá**; phải ghi key vào `KEY` trước khi program/erase |

Ghi vào cửa sổ flash khi không ở chế độ program → bus error (store access
fault) và `STATUS.WRPERR`. Program một bit 0 thành 1 → `STATUS.PGERR`.

Nội dung giữ qua reset SoC (và BREAK reset) nhưng **mất khi nạp lại bitstream
hoặc tắt nguồn** (BRAM). Có thể nạp sẵn ảnh vào bitstream:
`make fpga FLASH_VMEM=build/sw/hello/hello.vmem`.

## Thanh ghi (`FLASH_CTRL`, `0x4000_1000`)

| Offset | Tên | Quyền | Bit |
|-------:|-----|-------|-----|
| `0x00` | `KEY` | W | ghi `0xB032F1A5` để mở khoá; giá trị khác → khoá |
| `0x04` | `CTRL` | RW | `[0]` PG `[1]` PER (page erase) `[2]` MER (mass erase) `[4]` EOPIE |
| | | W | `[8]` STRT: bắt đầu erase (cần PER hoặc MER) |
| | | R/W1 | `[31]` LOCK: đọc 1 = đang khoá, ghi 1 = khoá lại |
| `0x08` | `ADDR` | RW | địa chỉ nằm trong page cần erase |
| `0x0C` | `STATUS` | R | `[0]` BUSY |
| | | R/W1C | `[1]` EOP (xong thao tác) `[2]` WRPERR `[3]` PGERR |
| `0x10` | `SIZE` | R | dung lượng (byte) |
| `0x14` | `PAGE_SIZE` | R | kích thước page (byte) |

Ngắt `irq_fast[2] = STATUS.EOP && CTRL.EOPIE`.

## Trình tự

```c
bow_flash_unlock();                        // KEY = 0xB032F1A5
bow_flash_erase(0x0801FC00, 1024);         // ADDR, CTRL = PER|STRT, chờ BUSY = 0
bow_flash_program(0x0801FC00, buf, 64);    // CTRL = PG, ghi từng word, kiểm tra STATUS
bow_flash_lock();                          // CTRL = LOCK
```

Ví dụ lưu dữ liệu kiểu "append log" (ít erase): `sw/apps/flash_demo/`.

## Bài tập mở rộng

* Thêm wait-state đọc cấu hình được (giống `FLASH_ACR.LATENCY` của STM32) và
  một prefetch buffer / cache nhỏ để bù lại.
* Mô phỏng thời gian erase/program thực tế (ms) bằng bộ đếm.
* Option bytes / vùng bảo vệ ghi (write protection theo page).
* Lưu thật sự không bay hơi: nối flash với QSPI trên K26 hoặc với DDR của PS
  qua AXI (xem [roadmap.md](../roadmap.md)).
