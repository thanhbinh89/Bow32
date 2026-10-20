# Bộ nhớ: SRAM, ROM, RAM primitive

RTL: `hw/ip/mem/rtl/`

| Module | Vai trò |
|--------|---------|
| `bow_ram_1p` | RAM 1 port, 32 bit, byte enable, đọc đồng bộ (read-first). Viết theo template để Vivado suy ra **block RAM**. Khởi tạo bằng `$readmemh` (`MemInitFile`) hoặc `InitValue`. |
| `bow_sram` | 16 KiB tại `0x2000_0000`, 0 wait-state. |
| `bow_rom` | 8 KiB tại `0x0000_0000`, nội dung = `build/sw/bootrom/bootrom.vmem`. Ghi → bus error. |

Định dạng `.vmem`: một word 32 bit hex mỗi dòng (little-endian), tạo bằng
`tools/bow32_image.py vmem`.

Tài nguyên trên K26 (ước lượng): ROM 2 + SRAM 4 + flash 32 = **38 / 144 BRAM36**.

## Nạp nội dung

* **Mô phỏng**: testbench nạp ROM/flash qua backdoor
  (`$readmemh(..., dut.u_rom.u_rom.mem)`), nên đổi firmware không cần build lại
  mô hình Verilator.
* **FPGA**: `build.tcl` truyền đường dẫn tuyệt đối của `bootrom.vmem` (và tuỳ
  chọn ảnh flash) qua generic `RomInitFile` / `FlashInitFile`; nội dung nằm
  trong bitstream. Sửa ROM ⇒ build lại bitstream (hoặc dùng `updatemem` của
  Vivado để thay nội dung BRAM mà không chạy lại implementation).

## Bài tập mở rộng

* SRAM 2 port (instr + data song song không tranh chấp).
* ECC (SECDED) cho SRAM — dùng `prim_secded_*` có sẵn trong Ibex.
* Thay BRAM bằng URAM cho dung lượng lớn hơn.
