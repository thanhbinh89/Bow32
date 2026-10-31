# DMA (`bow_dma`)

Bộ điều khiển DMA của Bow32: **bus master** thứ ba của main crossbar (sau
Ibex instr / data), 2 kênh dùng chung một cổng bus. Mã RTL:
`hw/ip/dma/rtl/bow_dma.sv`. Driver: `sw/common/include/bow_dma.h`.

```
                 +-----------------------------------------+
  H.264 m_axis ->| kênh 0  stream -> bộ nhớ (S2M)           |
                 | kênh 1  bộ nhớ -> bộ nhớ (M2M)            |--> main xbar (host 2) --> VRAM, SRAM, ...
  thanh ghi ---->| round robin, 1 giao dịch / lần, IRQ      |
                 +-----------------------------------------+
```

| Thông số | Giá trị |
|----------|---------|
| Kênh | 2 (tham số `NumCh`), mỗi kênh M2M hoặc S2M |
| Stream vào | kênh 0: đầu ra bộ mã hoá H.264 (`tlast` = cuối frame); kênh 1: không nối |
| Đơn vị | word 32 bit, địa chỉ và độ dài bội số 4 |
| Tốc độ | 2 chu kỳ / word ghi (S2M: 100 MB/s ở 50 MHz), M2M 4 chu kỳ / word |
| Lỗi bus | dừng kênh, `STATUS.ERR` (ví dụ địa chỉ không ánh xạ, ghi vào ROM) |
| Thanh ghi | peripheral bus `0x4000_A000`, ngắt `irq_fast[9]` |

## Chế độ

- **M2M**: chép `LEN` byte từ `SRC` sang `DST`, xong thì `DONE`, `EN` tự về 0.
- **S2M tuyến tính** (`RING = 0`): ghi các word của stream vào `DST + WPTR`;
  khi đủ `LEN` byte thì `DONE` và stream phải chờ (back-pressure, không mất dữ
  liệu).
- **S2M vòng** (`RING = 1`): `WPTR` quay về 0 ở `LEN`; kênh chờ khi buffer đầy
  (`(WPTR + 4) mod LEN == RPTR`), bên đọc (CPU) cập nhật `RPTR`.
- **DROP** (S2M): nhận và bỏ các word của stream (vẫn đếm packet). Dùng để xả
  bộ mã hoá mà không ghi đè dữ liệu đã thu.

Mỗi khi ghi xong word có `tlast`: `PKT_CNT + 1`, `PKT_END = WPTR` (sau packet),
`STATUS.PKT`. Với stream H.264: số frame và kích thước phần stream đã nằm trọn
trong bộ nhớ.

Ghi `CTRL.EN` từ 0 lên 1 bắt đầu kênh (`WPTR`, `COUNT`, `PKT_*` về 0). Giữa hai
giao dịch, các kênh được chọn luân phiên.

## Bản đồ thanh ghi (`0x4000_A000`)

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| 0x000 | `ID` | R | `0x444D4101` ("DMA", phiên bản 1) |
| 0x004 | `INFO` | R | [7:0] số kênh |

Kênh c ở `0x040 × (c + 1)` (kênh 0: `0x040`, kênh 1: `0x080`):

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| +0x00 | `CTRL` | RW | [0] EN, [1] MODE (0 M2M, 1 S2M), [2] RING, [3] DROP, [8] IE_DONE, [9] IE_PKT, [10] IE_ERR |
| +0x04 | `STATUS` | R/W1C | [0] BUSY, [1] DONE, [2] PKT, [3] ERR, [4] FULL (S2M đang chờ chỗ trống) |
| +0x08 | `SRC` | RW | địa chỉ nguồn (M2M) |
| +0x0C | `DST` | RW | địa chỉ đích / buffer |
| +0x10 | `LEN` | RW | byte cần chép / kích thước buffer |
| +0x14 | `WPTR` | R | offset ghi (S2M) / số byte đã chép (M2M) |
| +0x18 | `RPTR` | RW | S2M vòng: offset đọc của bên tiêu thụ |
| +0x1C | `PKT_CNT` | R | số packet của stream |
| +0x20 | `PKT_END` | R | `WPTR` sau packet cuối |
| +0x24 | `COUNT` | R | byte đã ghi từ lúc bắt đầu |

## Lập trình

```c
#include "bow32.h"

/* H.264 stream -> video RAM */
bow_dma_stream(0, (void *)BOW32_VRAM_BASE, BOW32_VRAM_SIZE, false);
...
uint32_t frames = DMA->CH[0].PKT_CNT, bytes = DMA->CH[0].PKT_END;

/* chép bộ nhớ */
bow_dma_copy(1, dst, src, 256);
if (!bow_dma_wait(1, 100)) { /* timeout hoặc lỗi bus */ }
```

## Bus master

DMA đưa ra request theo đúng giao thức của Bow32 ([../bus.md](../bus.md)): giữ
`req` cho tới `gnt`, đọc `rvalid`/`err` đúng một chu kỳ sau. Arbiter
round-robin của từng device trong main crossbar chia băng thông với CPU: CPU
đọc VRAM (gửi stream qua UART) trong khi DMA ghi VRAM không làm hỏng giao dịch
nào. Kiểm chứng: lệnh `dmatest` của `sw/apps/video` (test hệ thống `h264`):
SRAM → VRAM → SRAM, rồi đọc từ địa chỉ không ánh xạ phải ra `ERR`.

## Bài tập mở rộng

- Giao dịch pipeline (1 word / chu kỳ): request kế tiếp ngay chu kỳ có `rvalid`.
- Danh sách mô tả (scatter-gather) trong bộ nhớ.
- Kênh bộ nhớ → ngoại vi có tín hiệu yêu cầu (ví dụ UART TX đầy FIFO).
