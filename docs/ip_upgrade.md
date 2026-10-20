# Nâng cấp IP và quản lý phiên bản

## Nguyên tắc

* **IP bên ngoài** (Ibex, sau này: debug module, AXI...) nằm trong
  `hw/vendor/<tên>` dưới dạng git submodule **pin theo commit**. Không sửa trực
  tiếp mã trong đó.
* Mỗi IP bên ngoài có **một wrapper** trong `hw/ip/` (ví dụ `bow_cpu_ibex`) và
  **một filelist** trong `hw/vendor/`. Phần còn lại của SoC chỉ nói chuyện với
  wrapper qua bus Bow32 ⇒ nâng cấp thường chỉ chạm 2 file đó.
* IP của Bow32 theo dõi thay đổi trong `CHANGELOG.md`; thay đổi thanh ghi phải
  cập nhật header C + `docs/ip/*.md` trong cùng commit.
* CI (`make gen-check sw lint test`) là điều kiện để merge.

## Nâng cấp Ibex

Phiên bản đang dùng: xem `git submodule status` (commit `1b29dae8`, 2026-10-19).

```bash
cd hw/vendor/lowrisc_ibex
git fetch origin
git log --oneline HEAD..origin/master -- rtl/ ibex_top.core   # đọc thay đổi RTL
git checkout <commit-mới>
cd ../../..
```

1. **Interface**: so sánh port/parameter của `rtl/ibex_top.sv` với
   `hw/ip/cpu/rtl/bow_cpu_ibex.sv` (port mới → nối giá trị an toàn, ví dụ
   `IbexMuBiOff`).
2. **Danh sách file**: sinh lại bằng FuseSoC và so với `hw/vendor/lowrisc_ibex.f`:
   ```bash
   pip install fusesoc
   fusesoc --cores-root hw/vendor/lowrisc_ibex run --target=default --setup \
           --tool=verilator --build-root /tmp/ibex_out lowrisc:ibex:ibex_top
   cat /tmp/ibex_out/default-verilator/*.vc
   ```
   Thêm/bớt file tương ứng (bỏ qua primitive không dùng: pad, usb, rom...).
3. **Kiểm chứng**: `make lint && make test`; build FPGA và so sánh
   `utilization.rpt` / timing với phiên bản trước.
4. Commit cùng lúc: con trỏ submodule + wrapper + filelist + dòng CHANGELOG.

## Đổi cấu hình Ibex

Sửa tham số khi khởi tạo `bow_cpu_ibex` trong `bow32_top.sv`, ví dụ bitmanip:

```systemverilog
bow_cpu_ibex #(.BootAddr(BootAddr), .RegFile(IbexRegFile),
               .RV32B(ibex_pkg::RV32BBalanced)) u_cpu (...);
```

và cập nhật `-march` trong `sw/mk/common.mk` (`rv32imc_zicsr_zba_zbb_zbs`).
Bật `ICache` hay `PMPEnable` cần sửa thêm trong wrapper.

## Thay thế hoàn toàn một IP

Ví dụ thay UART tự viết bằng một UART khác: giữ nguyên tên/port của wrapper
(hoặc viết wrapper mới có cùng interface bus + port chân), giữ bảng thanh ghi
(hoặc cập nhật driver C). Vì IP được chọn qua filelist, hai phiên bản có thể
tồn tại song song (`hw/ip/uart`, `hw/ip/uart_v2`) và chọn bằng `bow32_top.f`.

## Đánh số phiên bản

* SoC: `soc.chip_id` trong YAML = `0xB032` + major/minor (`0x0100` = 1.0).
  Tăng khi memory map hoặc thanh ghi thay đổi không tương thích.
* Boot ROM: `BOW32_ROM_VERSION` trong `sw/bootrom/loader.h`, trả về bởi lệnh INFO.
* Định dạng ảnh: `hdr_version` trong `bow32_image.h`.
