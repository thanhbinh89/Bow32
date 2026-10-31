# Cầu Bow32 bus → AXI4-Lite (`bow_axil_bridge`)

Mở một cửa sổ của bản đồ địa chỉ Bow32 sang thiết bị **AXI4-Lite** bên ngoài
SoC, ví dụ một IP AXI trong block design của FPGA. Bản camera đầu tiên dùng nó
để điều khiển MIPI CSI-2 RX Subsystem của AMD; từ khi Bow32 có bộ thu riêng
([csi2rx.md](csi2rx.md)), cả hai bitstream KV260 đều để trống cửa sổ (mọi truy
cập kết thúc bằng timeout → bus error). RTL: `hw/ip/axil/rtl/bow_axil_bridge.sv`.

| | |
|---|---|
| Cửa sổ | `axil` = `0x5000_0000`, 64 KiB (main bus) |
| Địa chỉ AXI | địa chỉ bus mod 2^`AddrWidth` (16 bit) = offset trong cửa sổ |
| Giao dịch | một giao dịch một lúc, 32 bit, `wstrb` = byte enable của bus |
| Lỗi | `SLVERR`/`DECERR` (`resp[1] = 1`) → bus error → exception load/store access fault |
| Timeout | `TimeoutCycles` = 1024 chu kỳ không có trả lời → bus error |

## Hoạt động

Bus Bow32 yêu cầu `rvalid` đúng **một chu kỳ sau `gnt`**. Thiết bị AXI có thể
trả lời chậm bao lâu cũng được, nên cầu giữ `gnt = 0` trong suốt giao dịch AXI:

```
Idle --req--> Write (AW + W, chờ B)  --B--> Grant (gnt = 1) --> Idle (rvalid, err)
         \--> Read  (AR, chờ R)      --R-->
```

Trong lúc đó host vẫn giữ nguyên request (quy tắc của bus). Arbiter
round-robin của crossbar **khoá grant** cho tới khi request được nhận
(`bow_rr_arbiter`), nên một host khác không thể chen vào giữa giao dịch.

Timeout là lưới an toàn khi không có thiết bị (cả hai bitstream KV260 hiện
nay: AXI không được nối) hoặc thiết bị không có clock: cầu bỏ giao dịch và trả
bus error, CPU không bị treo. Việc hạ `VALID` khi chưa có `READY` vi phạm AXI, nên
đây chỉ là chế độ "hệ thống hỏng", không phải hoạt động bình thường.

Firmware đọc an toàn (không bị exception) bằng `bow_probe_read32()` /
`bow_probe_write32()` (`bow_probe.h`): lệnh `rd`/`wr` của các shell dùng nó, và
`bow_csi2rx_probe()` cũng vậy (bitstream cũ không có slot CSI2RX trả bus error).

## Kiểm chứng

Test hệ thống `camera`: mô hình AXI4-Lite với độ trễ ngẫu nhiên (1024 word đọc
ghi được, offset `0x0004` cố định `0x00000009`), vùng trả `SLVERR`
(`0x5000_4000`) và vùng không bao giờ trả lời (`0x5000_8000`, timeout); firmware
truy cập qua lệnh `rd`/`wr`.
