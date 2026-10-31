# Bộ nhớ: SRAM, ROM, video RAM, RAM primitive

RTL: `hw/ip/mem/rtl/`

| Module | Vai trò |
|--------|---------|
| `bow_ram_1p` | RAM 1 port, 32 bit, byte enable, đọc đồng bộ (read-first). Viết theo template để Vivado suy ra **block RAM**. Khởi tạo bằng `$readmemh` (`MemInitFile`) hoặc `InitValue`. |
| `bow_sram` | 16 KiB tại `0x2000_0000`, 0 wait-state. |
| `bow_rom` | 8 KiB tại `0x0000_0000`, nội dung = `build/sw/bootrom/bootrom.vmem`. Ghi → bus error. |
| `bow_vram` | **video RAM** 1 MiB tại `0x2400_0000`, 0 wait-state, buffer cho DMA (stream H.264). Word 64 bit + 8 byte enable trong RAM, mỗi truy cập 32 bit dùng một nửa; viết theo template để Vivado suy ra **UltraRAM** (1 MiB = 32 khối 4K × 72 bit). Không khởi tạo được (bằng 0 sau khi nạp bitstream), giữ nguyên qua reset. |

Định dạng `.vmem`: một word 32 bit hex mỗi dòng (little-endian), tạo bằng
`tools/bow32_image.py vmem`.

Tài nguyên trên K26 (ước lượng): ROM 2 + SRAM 4 + flash 32 = **38 / 144 BRAM36**;
video RAM **32 / 64 URAM** (bộ mã hoá H.264 dùng thêm 6 URAM cho strip buffer).

### Vì sao một vùng RAM riêng cho video

SRAM 16 KiB vẫn đủ cho `.data`, `.bss` và stack của mọi ứng dụng mẫu (ứng dụng
`video` dùng chưa tới 3 KiB). Thứ cần nhiều chỗ là **dữ liệu**: stream H.264
(một frame 720p intra ~20–80 KB). Video RAM nằm ở cổng riêng của main crossbar
nên DMA ghi stream không tranh băng thông với CPU đọc/ghi SRAM, và có thể làm
lớn (URAM) mà không đổi SRAM 0 wait-state của CPU. Trong linker script nó là
vùng `VRAM` (`NOLOAD`), C dùng `BOW32_VRAM_BASE` / `BOW32_VRAM_SIZE`.

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
* SRAM chính bằng URAM (dung lượng lớn hơn, đổi lại latency 1 chu kỳ khi cascade dài).
