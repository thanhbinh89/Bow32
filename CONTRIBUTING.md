# Đóng góp / quy trình làm việc

1. Tạo nhánh từ `main`, mỗi thay đổi một chủ đề.
2. Trước khi commit:
   ```bash
   make gen-check   # file sinh từ memory map đã cập nhật?
   make sw          # firmware build không warning
   make lint        # Verilator -Wall sạch
   make test        # mọi test mô phỏng PASS
   make test-tools
   ```
3. Thay đổi thanh ghi / memory map ⇒ cập nhật trong cùng commit: RTL, header C
   (`sw/common/include/`), tài liệu (`docs/ip/`), `CHANGELOG.md`.
4. Không sửa mã trong `hw/vendor/` — xem `docs/ip_upgrade.md`.

## Quy ước

* RTL: [lowRISC Verilog style guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md)
  (`_i/_o/_ni`, `_q/_d`, tham số `CamelCase`, `always_ff`/`always_comb`, reset
  bất đồng bộ tích cực thấp), tiền tố `bow_` / `bow32_`.
* C: gnu11, freestanding, 2 space, tiền tố `bow_`, thanh ghi qua struct `volatile`.
* Python: PEP 8, chỉ dùng thư viện chuẩn + `requirements.txt`.
* Comment code bằng tiếng Anh, tài liệu trong `docs/` bằng tiếng Việt.
* Commit message: `<khu vực>: <mô tả ngắn>` (ví dụ `uart: add parity support`).
