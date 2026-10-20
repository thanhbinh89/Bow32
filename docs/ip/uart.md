# UART (`bow_uart`)

RTL: `hw/ip/uart/rtl/` · Driver: `sw/common/include/bow_uart.h`, `sw/common/src/bow_uart.c`

* Khung 8N1, LSB trước, baud = `f_clk / BAUD.DIV` (mặc định 115200 @ 50 MHz).
* FIFO TX và RX 16 byte (`FifoDepth`).
* RX lấy mẫu một lần ở giữa bit (sau khi đồng bộ 2 flip-flop). Sau reset hoặc
  sau frame error (ví dụ BREAK), RX đợi đường truyền về mức cao rồi mới tìm
  start bit tiếp theo.
* Một đường ngắt: `irq = (RX_IE && RX_VALID) || (TX_IE && TX_EMPTY)`.

| Instance | Base | Ngắt |
|----------|------|------|
| UART0 | `0x4000_2000` | `irq_fast[0]` |
| UART1 | `0x4000_3000` | `irq_fast[1]` |

## Thanh ghi

| Offset | Tên | Quyền | Bit |
|-------:|-----|-------|-----|
| `0x00` | `DATA` | W | `[7:0]` byte đưa vào TX FIFO (bị bỏ nếu FIFO đầy) |
| | | R | `[7:0]` byte lấy ra từ RX FIFO, `[31]` `RX_EMPTY` (=1: không có dữ liệu, không pop) |
| `0x04` | `STATUS` | R | `[0]` TX_FULL `[1]` TX_EMPTY `[2]` TX_IDLE (FIFO rỗng và bộ phát rảnh) `[3]` RX_VALID `[4]` RX_FULL |
| | | R/W1C | `[5]` RX_OVERRUN `[6]` RX_FRAME_ERR |
| `0x08` | `CTRL` | RW | `[0]` TX_EN (reset 1) `[1]` RX_EN (reset 1) `[2]` RX_IE `[3]` TX_IE |
| | | W | `[4]` RX_FLUSH `[5]` TX_FLUSH (tự xoá) |
| `0x0C` | `BAUD` | RW | `[15:0]` số chu kỳ clock mỗi bit (tối thiểu 16) |

Đọc `DATA` sẽ pop RX FIFO — kể cả đọc bằng debugger.

## Ví dụ

```c
bow_uart_init(UART1, 115200);
bow_uart_puts(UART1, "hello\n");
int c = bow_uart_getc_nb(UART1);     // -1 nếu chưa có dữ liệu

UART1->CTRL |= UART_CTRL_RX_IE;      // ngắt khi có dữ liệu
bow_irq_fast_enable(BOW32_IRQ_FAST_UART1);
bow_irq_global_enable();
```

Ví dụ ngắt đầy đủ: `sw/apps/uart_irq/`.

## Bài tập mở rộng

* Thêm parity / 2 stop bit (thanh ghi `CTRL`).
* Lấy mẫu 16× với majority vote để chống nhiễu.
* Ngưỡng ngắt RX theo mức FIFO (watermark), RX timeout.
* Đếm và báo BREAK riêng (bit `STATUS.BREAK`).
