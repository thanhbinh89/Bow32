# Bus Bow32

Định nghĩa: `hw/ip/bus/rtl/bow_bus_pkg.sv`. Giao thức trùng với bus bộ nhớ của
Ibex (một tập con của [OBI](https://github.com/openhwgroup/obi)).

## Tín hiệu

| Tín hiệu | Hướng | Mô tả |
|----------|-------|-------|
| `req` | host → device | có yêu cầu |
| `we` | host → device | 1 = ghi |
| `be[3:0]` | host → device | byte enable |
| `addr[31:0]` | host → device | địa chỉ byte (căn word) |
| `wdata[31:0]` | host → device | dữ liệu ghi |
| `gnt` | device → host | chấp nhận yêu cầu (được phép tổ hợp từ `req`) |
| `rvalid` | device → host | có phản hồi |
| `rdata[31:0]` | device → host | dữ liệu đọc |
| `err` | device → host | lỗi bus |

Trong RTL các tín hiệu được gói thành struct `bus_req_t` / `bus_rsp_t`.

## Quy tắc

1. Host đặt `req = 1` và giữ nguyên `we/be/addr/wdata` cho tới khi thấy `gnt`.
2. Giao dịch xảy ra ở mỗi chu kỳ có `req && gnt`.
3. **Đúng một chu kỳ sau** giao dịch, device trả `rvalid = 1` (cả đọc lẫn ghi),
   kèm `rdata` (khi đọc) và `err`.
4. Device cần thêm thời gian thì **hạ `gnt`** (backpressure), không được trễ `rvalid`.

```
clk     _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
req     ___/‾‾‾‾‾‾‾‾‾‾‾\_________     đọc A (device bận 1 chu kỳ), rồi đọc B liền sau
addr    ---< A   >< B >---------
gnt     _______/‾‾‾‾‾‾‾\_________
rvalid  ___________/‾‾‾‾‾‾‾\_____
rdata   -----------< dA >< dB >--
```

Nhờ latency cố định, crossbar chỉ cần nhớ "giao dịch vừa được grant đi tới
device nào" trong 1 chu kỳ để định tuyến phản hồi — không cần đếm giao dịch
đang chờ. Trong mô phỏng, `bow_bus_xbar` kiểm tra quy tắc 3 và báo `$error` nếu
một device vi phạm.

## Crossbar `bow_bus_xbar`

```systemverilog
bow_bus_xbar #(
  .NumHosts   (2),
  .NumDevices (MainNumDevices),
  .DevBase    (MainDevBase),   // từ bow32_memmap_pkg
  .DevMask    (MainDevMask)
) u_main_xbar (...);
```

* Device `d` được chọn khi `(addr & DevMask[d]) == DevBase[d]`.
* Mỗi device có `bow_rr_arbiter` riêng; con trỏ ưu tiên chỉ dịch khi device
  thực sự `gnt`.
* Không trúng device nào → được `gnt` ngay, chu kỳ sau trả `err = 1`.
* `NumHosts = 1` → crossbar thành bộ giải mã địa chỉ (dùng cho peripheral bus).

## Viết một device

Mẫu tối thiểu cho một khối thanh ghi luôn sẵn sàng (xem `bow_uart.sv`,
`bow_sysctrl.sv`):

```systemverilog
assign bus_rsp_o.gnt = 1'b1;                       // luôn sẵn sàng
always_ff @(posedge clk_i or negedge rst_ni)
  if (!rst_ni) rvalid_q <= 1'b0;
  else begin
    rvalid_q <= bus_req_i.req;                      // phản hồi đúng 1 chu kỳ sau
    if (bus_req_i.req && !bus_req_i.we) rdata_q <= rdata_d;
  end
assign bus_rsp_o.rvalid = rvalid_q;
assign bus_rsp_o.rdata  = rdata_q;
assign bus_rsp_o.err    = 1'b0;
```

Device chậm (ví dụ `bow_flash` khi đang erase): `gnt = !busy`.

Hướng dẫn đầy đủ để thêm một IP vào SoC: [adding_an_ip.md](adding_an_ip.md).

## Mở rộng sau này

* Nhiều host hơn (DMA, debug module system bus): tăng `NumHosts`.
* Device có latency thay đổi / nhiều giao dịch treo: cần thêm FIFO định tuyến
  phản hồi trong crossbar (bài tập hay), hoặc chuyển sang TL-UL / AXI4-Lite qua
  bridge.
