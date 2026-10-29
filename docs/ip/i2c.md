# I2C master (`bow_i2c`)

I2C master đơn giản, **mỗi lệnh một byte**: phần mềm ghi `CMD` (START tuỳ
chọn + 1 byte ghi hoặc đọc + STOP tuỳ chọn) rồi chờ `STATUS.DONE`. Dùng để điều
khiển cảm biến camera (IMX219) qua switch I2C TCA9546A trên KV260.
RTL: `hw/ip/i2c/rtl/bow_i2c.sv`, driver: `sw/common/include/bow_i2c.h`.

| | |
|---|---|
| Địa chỉ | `I2C0` = `0x4000_7000`, ngắt `irq_fast[6]` (lệnh xong) |
| Tốc độ | `SCL = clk / (4 · DIV)`: 100 kHz (`DIV` = 125 @ 50 MHz, mặc định), 400 kHz (`DIV` = 31) |
| Pad | open drain: `*_oe_o = 1` kéo đường dây xuống 0, `*_i` = mức trên dây; cần pull-up |
| Hỗ trợ | START lặp lại, ACK/NACK khi đọc, slave kéo dài clock (clock stretching) |
| Không có | multi-master (arbitration), địa chỉ 10 bit, FIFO |

## Thanh ghi

| Offset | Tên | Truy cập | Bit |
|-------:|-----|:--:|-----|
| 0x00 | `CTRL` | RW | [0] EN, [1] IE (ngắt khi `DONE`), [31:16] DIV = 1/4 chu kỳ SCL tính bằng chu kỳ clock |
| 0x04 | `CMD` | W | [7:0] byte ghi, [8] START, [9] STOP, [10] WRITE, [11] READ, [12] NACK (trả NACK cho byte đọc, dùng cho byte cuối) |
| 0x08 | `STATUS` | R/W1C | [0] BUSY, [1] NACK (byte vừa ghi không được ACK), [2] DONE (W1C), [15:8] byte vừa đọc |

Ghi `CMD` khi `BUSY = 1` bị bỏ qua. `CMD` chỉ có STOP = gửi điều kiện STOP.
Tắt `EN` sẽ nhả cả hai đường dây và đưa máy trạng thái về rảnh (dùng để thoát
khi bus bị kẹt).

## Thời gian

Mỗi bit và mỗi điều kiện START/STOP dài 4 "quarter" (`DIV` chu kỳ); đường dây
đổi ở cuối quarter:

```
bit:    quarter 0: đặt SDA (SCL thấp) | 1: SCL thấp | 2: SCL cao, chờ SCL thật sự cao | 3: SCL cao
        lấy mẫu SDA ở cuối quarter 2
START:  nhả SDA | nhả SCL | (cả hai cao) kéo SDA xuống | kéo SCL xuống
STOP:   SDA thấp, SCL thấp | nhả SCL | (SCL cao) nhả SDA | bus rảnh
```

Ở quarter 2, bộ đếm chỉ chạy khi SCL đọc về là 1, nên slave giữ SCL thấp
(clock stretching) hay độ trễ của bộ đồng bộ chỉ làm chu kỳ cao dài thêm.

## Driver

```c
bow_i2c_init(I2C0, 400000);

uint8_t sel = 0x04;                                   /* TCA9546A: kênh 2 */
bow_i2c_write(I2C0, 0x74, &sel, 1);

uint8_t reg[2] = {0x00, 0x00}, id[2];                 /* IMX219 chip id */
int r = bow_i2c_write_read(I2C0, 0x10, reg, 2, id, 2);  /* START lặp lại */
if (r == I2C_ENACK) bow_printf("no ACK\n");
```

Mỗi giao dịch kết thúc bằng STOP. Mã lỗi: `I2C_ENACK` (địa chỉ/byte không được
ACK), `I2C_ETIMEOUT` (bus kẹt, driver tắt/bật lại controller).

## Kiểm chứng

Test hệ thống `camera` (`make run TEST=camera`): mô hình TCA9546A + IMX219 trong
`sim/tb/tb_bow32.sv` (địa chỉ 16 bit, tự tăng, slave kéo dài clock sau mỗi vài
byte), firmware dò chip ID, ghi ~200 thanh ghi và đọc lại.

## Bài tập mở rộng

- FIFO lệnh để gửi cả giao dịch mà không chờ từng byte; ngắt + DMA.
- Arbitration multi-master, phát hiện bus kẹt (SDA bị giữ thấp → 9 xung SCL).
- Chế độ slave.
