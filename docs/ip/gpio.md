# GPIO / IOPAD (`bow_gpio`)

RTL: `hw/ip/gpio/rtl/` · Driver: `sw/common/include/bow_gpio.h` · Demo: `sw/apps/gpio_demo/`

Mỗi instance là một port `Width` chân (mặc định 8):

* hướng từng chân (`DIR`), xuất push-pull hoặc open-drain (`OD`);
* ghi nguyên tử `OUT_SET` / `OUT_CLR` / `OUT_TGL`: không cần read-modify-write,
  an toàn khi ISR và vòng lặp chính cùng đổi chân;
* `IN` đọc mức thật của chân (qua bộ đồng bộ 2 flip-flop), kể cả chân đang xuất;
* chọn **chức năng thay thế** (`AF`): chân do một ngoại vi điều khiển thay cho
  GPIO (pinmux);
* ngắt theo cạnh lên/xuống từng chân, cờ `IRQ_STATUS` xoá bằng cách ghi 1.

| Instance | Base | Ngắt | Chức năng thay thế |
|----------|------|------|--------------------|
| GPIOA | `0x4000_4000` | `irq_fast[3]` | — |
| GPIOB | `0x4000_5000` | `irq_fast[4]` | PB0 = UART1 TX, PB1 = UART1 RX (bật sau reset) |

## Thanh ghi

Thanh ghi 32 bit, dùng bit `[7:0]`, truy cập theo word.

| Offset | Tên | Quyền | Mô tả |
|-------:|-----|-------|-------|
| `0x00` | `IN` | R | mức chân, trễ 2–3 chu kỳ do bộ đồng bộ |
| `0x04` | `OUT` | RW | dữ liệu xuất |
| `0x08` | `OUT_SET` | W | `OUT \|= giá trị` (đọc ra 0) |
| `0x0C` | `OUT_CLR` | W | `OUT &= ~giá trị` (đọc ra 0) |
| `0x10` | `OUT_TGL` | W | `OUT ^= giá trị` (đọc ra 0) |
| `0x14` | `DIR` | RW | 1 = xuất, 0 = vào (sau reset: tất cả là vào) |
| `0x18` | `OD` | RW | 1 = open-drain: `OUT = 0` kéo chân xuống, `OUT = 1` thả nổi |
| `0x1C` | `AF` | RW | 1 = chân do chức năng thay thế điều khiển; chân không có AF đọc ra 0 |
| `0x20` | `IRQ_EN` | RW | cho phép ngắt |
| `0x24` | `IRQ_RISE` | RW | bắt cạnh lên |
| `0x28` | `IRQ_FALL` | RW | bắt cạnh xuống (bật cả hai = mọi cạnh) |
| `0x2C` | `IRQ_STATUS` | R/W1C | đã thấy cạnh được chọn; được set kể cả khi `IRQ_EN = 0` (dùng để polling) |

`irq = |(IRQ_STATUS & IRQ_EN)` là ngắt mức tới `irq_fast` của Ibex: ISR phải
ghi 1 vào các bit của `IRQ_STATUS` để xoá, nếu không ngắt sẽ gọi lại liên tục.
Cạnh xảy ra đúng chu kỳ phần mềm xoá cờ vẫn được giữ lại.

## Pad và chức năng thay thế

```
                    bow_gpio
  OUT, DIR, OD ──> logic GPIO ──┐
                                ├─ AF ──> gpio_o, gpio_oe_o ──> IOBUF ──── chân
  ngoại vi ──> af_out_i ────────┘                              │
               af_oe_i                                         │
  ngoại vi <── af_in_o  = chân khi AF = 1, AfIdle khi AF = 0 <─┤ gpio_i
  IN       <── đồng bộ 2 FF <──────────────────────────────────┘
```

| Chế độ | `gpio_oe_o` | `gpio_o` |
|--------|-------------|----------|
| vào (`DIR = 0`) | 0 | – |
| push-pull | 1 | `OUT` |
| open-drain | `~OUT` | 0 |
| chức năng thay thế (`AF = 1`) | `af_oe_i` | `af_out_i` |

* Pad (IO buffer) nằm **ngoài** IP vì phụ thuộc công nghệ: trên Kria là `IOBUF`
  trong `hw/fpga/kv260/rtl/bow32_kv260_top.sv`, trở kéo lên đặt trong XDC (FPGA
  không đổi được pull lúc chạy); trong mô phỏng, testbench mô hình pad có trở
  kéo lên và báo lỗi nếu chip và testbench cùng lái một chân.
* Khi `AF = 0`, ngoại vi thấy mức nghỉ `AfIdle` (mặc định 1): UART1 RX không
  nhận rác khi PB1 đang dùng làm GPIO.
* UART0 có chân riêng, không qua GPIO: boot ROM, loader và bộ phát hiện BREAK
  luôn dùng được, phần mềm không thể vô tình tắt chân console.

Tham số: `Width`, `AfMask` (chân nào có AF), `AfReset` (AF sau reset),
`AfIdle`. Trong `bow32_top`: GPIOA không có AF; GPIOB có `AfMask = AfReset = 8'h03`.

## Trên Kria KV260

| Chân | PMOD J2 | FPGA | Ghi chú |
|------|---------|------|---------|
| PA0 | 2 | B10 | có sẵn RC 20 Ω + 33 pF xuống GND trên carrier |
| PA1 | 4 | E12 | |
| PA2 | 6 | D11 | |
| PA3 | 8 | B11 | |
| PB0 | 5 | D10 | UART1 TX sau reset |
| PB1 | 7 | C11 | UART1 RX sau reset |

Mọi chân có pull-up, `DRIVE 8` mA, `SLEW SLOW`. PA4..PA7 và PB2..PB7 không có
chân trên board: đọc lại mức chip đang xuất (0 khi không xuất). Cách nối dây và
chạy thử: [fpga_kria.md](../fpga_kria.md#5-chạy-thử-gpio).

## Ví dụ

```c
bow_gpio_output(GPIOA, GPIO_PIN(0));        // PA0: LED
bow_gpio_toggle(GPIOA, GPIO_PIN(0));

// Nút nhấn từ PA2 xuống GND (pad có pull-up): ngắt khi nhấn
bow_gpio_irq_config(GPIOA, GPIO_PIN(2), GPIO_EDGE_FALL);
bow_irq_fast_enable(BOW32_IRQ_FAST_GPIOA);
bow_irq_global_enable();

void bow_irq_fast_handler(unsigned line) {
  if (line == BOW32_IRQ_FAST_GPIOA) {
    uint32_t pins = GPIOA->IRQ_STATUS;
    GPIOA->IRQ_STATUS = pins;               // xoá cờ (W1C)
    /* ... */
  }
}

// PB0/PB1 làm GPIO thay vì UART1
GPIOB->AF &= ~(GPIOB_AF_UART1_TX | GPIOB_AF_UART1_RX);
```

Shell tương tác để thử mọi thanh ghi: `sw/apps/gpio_demo/` (gõ `h` để xem lệnh).

## Bài tập mở rộng

* Ngắt theo mức; lọc dội phím (debounce) bằng bộ đếm trong IP.
* Pinmux đầy đủ: mỗi chân chọn 1 trong N chức năng (`AFSEL` 4 bit/chân như
  STM32) khi có thêm SPI, I2C, PWM.
* Thanh ghi điều khiển pad cho ASIC: pull-up/pull-down, drive strength,
  schmitt trigger, nối tới pad cell thay vì `IOBUF`.
* Tôn trọng byte enable (`be`) để `sb`/`sh` chỉ ghi một phần thanh ghi.
