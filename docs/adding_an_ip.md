# Thêm một IP mới (ví dụ: GPIO)

Quy trình chung cho một ngoại vi trên peripheral bus. Ví dụ dưới đây thêm
`bow_gpio` 8 bit ở slot `0x4000_4000`.

## 1. RTL

```
hw/ip/gpio/
├── gpio.f              # rtl/bow_gpio.sv
└── rtl/bow_gpio.sv
```

Theo mẫu device trong [bus.md](bus.md): `gnt = 1`, `rvalid` 1 chu kỳ sau,
giải mã `addr[11:2]`, đồng bộ input bằng `bow_sync`.

```systemverilog
module bow_gpio import bow_bus_pkg::*; (
  input  logic       clk_i, rst_ni,
  input  bus_req_t   bus_req_i,
  output bus_rsp_t   bus_rsp_o,
  input  logic [7:0] gpio_i,
  output logic [7:0] gpio_o,
  output logic [7:0] gpio_oe_o
);
  // 0x00 OUT (RW)  0x04 IN (R)  0x08 OE (RW)
  ...
endmodule
```

Thêm `-F ../ip/gpio/gpio.f` vào `hw/top/bow32_top.f`.

## 2. Memory map

`hw/top/data/bow32_memmap.yaml`:

```yaml
periph_bus:
  ...
  - {name: gpio, base: 0x40004000, size: 0x1000, desc: "GPIO 8 bit"}
```

```bash
make gen     # cập nhật bow32_memmap_pkg.sv, bow32_memmap.h, bow32_memory.ld, docs/memory_map.md
```

`PeriphNumDevices` tự tăng thành 5 và có `PeriphDevGpio = 4`.

## 3. Nối vào SoC (`hw/top/rtl/bow32_top.sv`)

```systemverilog
bow_gpio u_gpio (
  .clk_i,
  .rst_ni    (sys_rst_n),
  .bus_req_i (periph_req[PeriphDevGpio]),
  .bus_rsp_o (periph_rsp[PeriphDevGpio]),
  .gpio_i, .gpio_o, .gpio_oe_o
);
```

Thêm port ở `bow32_top`, nối ở board top (`bow32_kv260_top.sv`) và XDC (ví dụ
4 chân PMOD còn lại `B10 E12 D11 B11` = J2 chân 2, 4, 6, 8). Có ngắt: thêm vào
`irq_fast` trong YAML và gán `irq_fast[IrqFastGpio]`.

## 4. Phần mềm

* `sw/common/include/bow_gpio.h`: struct thanh ghi + macro bit, dùng
  `BOW32_GPIO_BASE` từ `bow32_memmap.h`; include vào `bow32.h`.
* Driver (nếu cần) trong `sw/common/src/bow_gpio.c` — `app.mk` tự biên dịch
  mọi file trong `sw/common/src/`.
* App mẫu `sw/apps/gpio_blink/`.

## 5. Kiểm chứng

1. `make lint` — không được có warning mới.
2. Test hệ thống: thêm kịch bản trong `sim/tb/tb_bow32.sv` (đọc/ghi chân GPIO
   từ testbench) và vào `TESTS` trong `sim/Makefile`.
3. (Tuỳ chọn) testbench riêng cho IP: `hw/ip/gpio/dv/`.
4. Tài liệu `docs/ip/gpio.md` (bảng thanh ghi giống các IP khác).

## Checklist

- [ ] `hw/ip/<ip>/rtl/*.sv` + `<ip>.f`, lint sạch `-Wall`
- [ ] YAML memory map + `make gen` (file sinh ra được commit)
- [ ] Nối trong `bow32_top.sv` (+ board top, XDC nếu có chân)
- [ ] Header C + driver + app ví dụ
- [ ] Test mô phỏng, `make test` PASS
- [ ] `docs/ip/<ip>.md`, cập nhật README / CHANGELOG
