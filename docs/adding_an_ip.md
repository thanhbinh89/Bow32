# Thêm một IP mới (ví dụ thực tế: GPIO)

Quy trình chung cho một ngoại vi trên peripheral bus. GPIO (`bow_gpio`, hai
port GPIOA/GPIOB ở `0x4000_4000` / `0x4000_5000`) đã được thêm vào Bow32 đúng
theo các bước dưới đây: mở các file được nhắc tới để xem kết quả.

## 1. RTL

```
hw/ip/gpio/
├── gpio.f              # rtl/bow_gpio.sv (cần common.f cho bow_sync)
└── rtl/bow_gpio.sv
```

Theo mẫu device trong [bus.md](bus.md): `gnt = 1`, `rvalid` 1 chu kỳ sau,
giải mã `addr[11:2]`, đồng bộ input bằng `bow_sync`. Một module = một port;
SoC dùng hai instance (giống UART0/UART1).

```systemverilog
module bow_gpio import bow_bus_pkg::*; #(
  parameter int unsigned      Width   = 8,
  parameter logic [Width-1:0] AfMask  = '0,  // chân có chức năng thay thế
  parameter logic [Width-1:0] AfReset = '0,
  parameter logic [Width-1:0] AfIdle  = '1
) (
  input  logic             clk_i, rst_ni,
  input  bus_req_t         bus_req_i,
  output bus_rsp_t         bus_rsp_o,
  input  logic [Width-1:0] gpio_i,                       // pad
  output logic [Width-1:0] gpio_o, gpio_oe_o,
  input  logic [Width-1:0] af_out_i, af_oe_i,            // ngoại vi
  output logic [Width-1:0] af_in_o,
  output logic             irq_o
);
  // 0x00 IN  0x04 OUT  0x08 OUT_SET  0x0C OUT_CLR  0x10 OUT_TGL  0x14 DIR
  // 0x18 OD  0x1C AF   0x20 IRQ_EN   0x24 IRQ_RISE 0x28 IRQ_FALL 0x2C IRQ_STATUS
  ...
endmodule
```

Thêm `-F ../ip/gpio/gpio.f` vào `hw/top/bow32_top.f`. Lint riêng IP với nhiều bộ
tham số trước khi nối vào SoC:

```bash
verilator --lint-only -Wall -Wno-UNUSEDPARAM -GWidth=32 hw/ip/bus/rtl/bow_bus_pkg.sv \
  hw/ip/common/rtl/bow_sync.sv hw/ip/gpio/rtl/bow_gpio.sv --top-module bow_gpio
```

## 2. Memory map

`hw/top/data/bow32_memmap.yaml`:

```yaml
periph_bus:
  ...
  - {name: gpioa, base: 0x40004000, size: 0x1000, desc: "GPIO port A (8 pins)"}
  - {name: gpiob, base: 0x40005000, size: 0x1000, desc: "GPIO port B (8 pins, PB0/PB1 = UART1 TX/RX)"}
irq_fast:
  ...
  - {name: gpioa, line: 3, desc: "GPIO port A pin edge"}
  - {name: gpiob, line: 4, desc: "GPIO port B pin edge"}
```

```bash
make gen     # cập nhật bow32_memmap_pkg.sv, bow32_memmap.h, bow32_memory.ld, docs/memory_map.md
```

`PeriphNumDevices` tự tăng từ 4 lên 6, có thêm `PeriphDevGpioa = 4`,
`PeriphDevGpiob = 5`, `IrqFastGpioa = 3`, `IrqFastGpiob = 4` (SV) và
`BOW32_GPIOA_BASE`, `BOW32_IRQ_FAST_GPIOA`... (C).

## 3. Nối vào SoC (`hw/top/rtl/bow32_top.sv`)

```systemverilog
bow_gpio #(
  .Width (8)
) u_gpioa (
  .clk_i,
  .rst_ni    (sys_rst_n),
  .bus_req_i (periph_req[PeriphDevGpioa]),
  .bus_rsp_o (periph_rsp[PeriphDevGpioa]),
  .gpio_i    (gpioa_i),
  .gpio_o    (gpioa_o),
  .gpio_oe_o (gpioa_oe_o),
  .af_out_i  ('0),
  .af_oe_i   ('0),
  .af_in_o   (),
  .irq_o     (gpioa_irq)
);
```

* Ngắt: `irq_fast[IrqFastGpioa] = gpioa_irq`.
* Chân: thêm port ở `bow32_top`; pad (`IOBUF`) đặt ở board top
  `hw/fpga/kv260/rtl/bow32_kv260_top.sv` vì phụ thuộc công nghệ, và chân vật lý
  trong XDC (PA0..PA3 = J2 chân 2/4/6/8).
* Chức năng thay thế: GPIOB nhận `af_out_i/af_oe_i` từ UART1 TX và trả
  `af_in_o[1]` cho UART1 RX: UART1 không còn port riêng ở `bow32_top`.

## 4. Phần mềm

* `sw/common/include/bow_gpio.h`: struct thanh ghi + macro bit + hàm inline,
  dùng `BOW32_GPIOA_BASE` từ `bow32_memmap.h`; include vào `bow32.h`.
* Driver phức tạp hơn thì đặt trong `sw/common/src/<ip>.c` — `app.mk` tự biên
  dịch mọi file trong `sw/common/src/`.
* App mẫu `sw/apps/gpio_demo/` (shell lệnh trên UART0), `sw/Makefile` tự tìm
  thấy app mới.

## 5. Kiểm chứng

1. `make lint` — không được có warning mới.
2. Test hệ thống: test `gpio` trong `sim/tb/tb_bow32.sv` (mô hình pad có pull-up,
   gửi lệnh cho `gpio_demo` rồi kiểm tra chân) và trong `TESTS` / `FLASH_gpio` của
   `sim/Makefile`. Test cũ (`boot`, `irq`) kiểm tra UART1 đi qua chức năng thay thế.
3. (Tuỳ chọn) testbench riêng cho IP: `hw/ip/<ip>/dv/`.
4. Tài liệu `docs/ip/gpio.md` (bảng thanh ghi giống các IP khác).
5. Có chân trên board: `make fpga`, xem `io_placed.rpt` và timing.

## Checklist

- [ ] `hw/ip/<ip>/rtl/*.sv` + `<ip>.f`, lint sạch `-Wall`
- [ ] YAML memory map + `make gen` (file sinh ra được commit)
- [ ] Nối trong `bow32_top.sv` (+ board top, XDC nếu có chân)
- [ ] Header C + driver + app ví dụ
- [ ] Test mô phỏng, `make test` PASS
- [ ] `docs/ip/<ip>.md`, cập nhật README / CHANGELOG
