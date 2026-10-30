# ISP — Image Signal Processor (`bow_isp`)

ISP của Bow32 biến ảnh **RAW10 Bayer** của cảm biến thành ảnh **RGB888** hoặc
**YUV 4:4:4**, xử lý **1 pixel/clock** và có thống kê cho AE/AWB/AF, bộ capture
để CPU đọc ảnh. Mã RTL: `hw/ip/isp/rtl/`. Mô hình tham chiếu bit-exact:
`tools/isp/isp_model.py`. Driver: `sw/common/include/bow_isp.h`.

```
 cam_* (RAW10) ──┐
                 ├─► input ─► BLC ─► FIFO A ─► [5x5] ─► DPC ─► WB ─► FIFO B ─► [3x3] ─► demosaic ─┐
 TPG ────────────┘   (kiểm tra                                                                    │
                      kích thước)        ┌──────────── statistics (AE / AWB / AF / histogram) ◄───┤
                                         │                                                        ▼
                                         │                         isp_* ◄── CSC ◄── gamma ◄── CCM
                                         │                        (RGB/YUV)   │
                                         ▼                                    ▼
                                   thanh ghi ST_*                  capture (box filter) ─► buffer 32K × 24 bit
```

| Thông số | Giá trị |
|----------|---------|
| Đầu vào | AXI4-Stream video RAW10, `tdata[9:0]`, `tuser` = start of frame, `tlast` = end of line (giống đầu ra MIPI CSI-2 RX của AMD, UG934) |
| Đầu ra | AXI4-Stream 24 bit, thứ tự UG934: RGB `{R, B, G}`, YUV 4:4:4 `{V, U, Y}`; phải nhận 1 pixel/clock |
| Kích thước | rộng 16…`MaxWidth` (2048), cao 8…4095, lẻ/chẵn tuỳ ý (cảm biến dùng chẵn) |
| Thông lượng | 1 pixel/clock; trên KV260 clock video 200 MHz |
| Thanh ghi | peripheral bus `0x4000_6000` (4 KiB), ngắt `irq_fast[5]` |
| Buffer capture | main bus `0x3000_0000`, 32768 word × 24 bit (chỉ đọc) |

## Vì sao 1080p30 và 720p60

Camera có sẵn cho KV260 là **Raspberry Pi camera v2 (Sony IMX219)** cắm vào
connector J9 (MIPI CSI-2, 2 lane). Theo driver Linux, IMX219 chạy 2 lane ×
912 Mbit/s, tốc độ pixel 182,4 Mpixel/s, dòng dài 3448 pixel (18,9 µs):

| Mode | Vùng cảm biến | Frame length | fps | Pixel trung bình | Ghi chú |
|------|---------------|-------------:|----:|-----------------:|---------|
| **1080p30** (mặc định) | crop giữa 1920×1080 | 1763 dòng | 30,0 | 1920 px / 18,9 µs = 102 Mpx/s | Full HD |
| **720p60** | crop giữa 1280×720 | 881 dòng | 60,0 | 68 Mpx/s | HD, gấp đôi fps |

Trong một dòng, CSI-2 RX đưa pixel ra tối đa 182,4 Mpx/s (bằng tốc độ link).
ISP ở 200 MHz × 1 pixel/clock nhanh hơn tốc độ đó, nên chỉ cần buffer dòng nhỏ
trong CSI-2 RX. Mode tuỳ ý `mode <w> <h> [fps]` cũng được (crop giữa, không
binning). Ví dụ testbench dùng 64×48.

## Hai miền clock

| Miền | Clock | Nội dung |
|------|-------|----------|
| CPU | `clk_i` (50 MHz) | `bow_isp_regs`: thanh ghi, cổng đọc buffer capture |
| Video | `vid_clk_i` (200 MHz trên KV260) | toàn bộ pipeline pixel, TPG, thống kê, capture |

Đồng bộ giữa hai miền:

- **xung** (UPDATE, CAP_START, cập nhật xong, capture xong, thống kê mới, lỗi):
  `bow_cdc_pulse` (toggle + 2 FF). Lỗi được giới hạn tối đa 1 xung / 16 chu kỳ
  video để hai xung không bị gộp mất.
- **mức** (EN, SRC_TPG): `bow_sync`.
- **dữ liệu tĩnh**: cấu hình staging, cấu hình capture và kết quả thống kê chỉ
  được bên nhận đọc khi bên gửi đã ngừng thay đổi chúng (được đảm bảo bởi giao
  thức xung ở trên).
- **RAM 2 clock**: bảng gamma (CPU ghi, video đọc), buffer capture (video ghi,
  CPU đọc).

Reset miền video = `vid_rst_ni & rst_ni`, qua `bow_rst_sync` (assert bất đồng
bộ, nhả đồng bộ).

## Pipeline

Mọi stage dùng số nguyên, công thức dưới đây giống hệt mô hình Python. Toạ độ
`(x, y)` tính từ góc trên trái của frame, màu Bayer của pixel:

```
BAYER = màu của pixel (0,0): 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR
cfa(x, y) = { (y & 1) ^ BAYER[1], (x & 1) ^ BAYER[0] }   -> 0 R, 1 Gr, 2 Gb, 3 B
```

### Input (`bow_isp_input`)

Đảm bảo hình học của frame: frame bắt đầu ở pixel có `tuser`; `tlast` phải đi
cùng pixel `width-1` của mỗi dòng; frame kết thúc sau `height` dòng. Sai lệch
(tlast sớm/muộn, SOF giữa frame) → **huỷ frame** (reset các stage sau,
`STATUS.ERR_INPUT`). Kích thước thật của luồng vào luôn được đo
(`IN_SIZE`), rất hữu ích khi bring-up camera. Khi ISP tắt (`CTRL.EN = 0`),
`tready = 1` (luồng bị bỏ); tắt giữa frame cũng huỷ frame đó.

Frame bị huỷ có thể dừng giữa một dòng đầu ra: phần còn lại của dòng được gửi
bằng pixel 0, `tlast` ở pixel `width-1`, nên mọi dòng ra đều đủ `width` pixel;
frame đó chỉ kết thúc sớm (ít dòng hơn), `tuser` kế tiếp là frame mới.

`IN_SIZE` là số dòng giữa hai SOF gần nhất: ngay sau khi đổi nguồn hoặc
khởi động lại luồng, nó có thể cho chiều cao của frame bị cắt (ví dụ
`1920x29`), từ frame thứ hai thì đúng.

### BLC — black level (`bow_isp_blc`)

`p' = max(p − BLC, 0)`. IMX219 có black level 64 (RAW10).

### DPC — defect pixel correction (`bow_isp_dpc`)

Cửa sổ 5×5, so với 8 pixel **cùng màu** (khoảng cách 2):
```
mn, mx = min / max của 8 hàng xóm cùng màu
p' = mx  nếu p > mx + DPC_TH
p' = mn  nếu p + DPC_TH < mn
p' = p   ngược lại            (ST_DPC đếm số pixel bị sửa)
```

### WB — white balance (`bow_isp_wb`)

`p' = min((p · WB[cfa] + 128) >> 8, 1023)`, gain u4.8 (256 = 1,0) cho R, Gr,
Gb, B.

### Demosaic (`bow_isp_demosaic`)

Nội suy bilinear trên cửa sổ 3×3:
```
cross = (N + S + W + E + 2) >> 2      diag = (NW + NE + SW + SE + 2) >> 2
hor   = (W + E + 1) >> 1              ver  = (N + S + 1) >> 1
R: (p, cross, diag)   B: (diag, cross, p)   Gr: (hor, p, ver)   Gb: (ver, p, hor)
```

### Biên ảnh và bộ tạo cửa sổ (`bow_isp_window`)

Cửa sổ N×N (N = 5 và 3) dùng N−1 dòng trong BRAM. Ngoài biên, pixel được
**phản chiếu không lặp** (reflect-101: `p[-1] = p[1]`, `p[W] = p[W-2]`) nên
màu Bayer của hàng xóm luôn đúng. Để tạo R = (N−1)/2 cột cuối và R dòng cuối,
bộ tạo cửa sổ tự chèn pixel "ảo" sau mỗi dòng/frame và hạ `in_ready` trong lúc
đó; vì thế nguồn cần có blanking ngang/dọc (camera nào cũng có).

### CCM — color correction matrix và CSC (`bow_isp_mat3x3`)

Cùng một khối ma trận 3×3, hệ số s3.8 (12 bit có dấu, 256 = 1,0):
```
out_i = clamp((Σ_j c_ij · in_j + (off_i << 8) + 128) >>> 8, 0, max)
```
- **CCM** trên RGB tuyến tính 10 bit (`max` = 1023, offset 11 bit có dấu).
- **CSC** trên RGB 8 bit sau gamma (`max` = 255, offset 9 bit có dấu). Driver
  nạp BT.709 full range: `Y = .2126R + .7152G + .0722B`, Cb/Cr có offset 128.

### Gamma (`bow_isp_gamma`)

3 bảng 1024 → 8 bit (R, G, B), CPU ghi qua `GAMMA_ADDR/GAMMA_DATA`. Khi tắt:
`out = in >> 2`. Driver nạp đường cong sRGB (65 điểm, nội suy tuyến tính).

### Bật / tắt từng khối

`MODULES`: bit 0 BLC, 1 DPC, 2 WB, 3 CCM, 4 GAMMA, 5 CSC. Khối tắt vẫn giữ
nguyên latency, nên bật/tắt giữa hai frame không làm lệch pipeline.

## Luồng điều khiển và lỗi

ISP **không có back-pressure bên trong**. Đầu vào hạ `tready` khi FIFO A/B sắp
đầy (lúc bộ tạo cửa sổ chèn pixel biên) hoặc khi đang chờ áp cấu hình; đầu ra
phải nhận 1 pixel/clock. Các cờ lỗi (W1C trong `STATUS`):

| Cờ | Ý nghĩa | Thường do |
|----|---------|-----------|
| `ERR_INPUT` | frame vào sai kích thước, bị bỏ | `SIZE` khác kích thước cảm biến (xem `IN_SIZE`) |
| `ERR_FIFO` | tràn FIFO nội bộ | nguồn không có blanking (không xảy ra với camera thật) |
| `ERR_OUTPUT` | `isp_tready = 0` khi có pixel | đầu ra nối vào khối chậm |
| `ERR_CAP` | vùng capture lớn hơn buffer | `CAP_SIZE` quá lớn |

## Cấu hình staging và `UPDATE`

Thanh ghi `0x020…0x0CC` là **bản staging**. Ghi xong thì ghi `UPDATE = 1`:
phần cứng chép staging vào cấu hình đang chạy **giữa hai frame** (khi pipeline
rỗng), rồi xoá `STATUS.UPD_PENDING`. Không ghi staging khi `UPD_PENDING = 1`.
Nhờ vậy một frame không bao giờ bị xử lý bằng nửa cấu hình cũ, nửa mới.
Bảng gamma và thanh ghi capture có hiệu lực ngay.

## Thống kê

Lấy sau demosaic (RGB tuyến tính 10 bit, đã qua BLC/DPC/WB), trong cửa sổ
`STAT_X/STAT_Y` (bao gồm hai biên). Chụp lại ở cuối mỗi frame
(`STATUS.FRAME_DONE`, `FRAME_CNT`):

| Thanh ghi | Nội dung | Dùng cho |
|-----------|----------|----------|
| `ST_SUM_R/G/B`, `ST_CNT` | tổng R, G, B và số pixel có cả 3 kênh `< STAT_SAT` | AWB gray world |
| `ST_SUM_Y` | tổng `Y = (77R + 150G + 29B + 128) >> 8` | AE |
| `HIST[0..63]` | histogram của `Y >> 4` | AE, hiển thị |
| `ST_AF` | `Σ |G(x) − G(x−1)|` | lấy nét (độ sắc nét) |
| `ST_DPC` | số pixel DPC đã sửa | |
| `ST_FRAME` | số frame của bộ thống kê này | đọc nhất quán |

## Capture

`CAP_CTRL.START` → frame **hoàn chỉnh** kế tiếp được chụp: vùng
`(x0, y0)` kích thước `(w << s) × (h << s)` pixel, lọc hộp D×D (D = 2^s,
s = 0…3) thành `w × h` word `{c0, c1, c2}` (0xRRGGBB hoặc 0xYYUUVV) tại địa chỉ
`by · w + bx`:
```
out(bx, by) = (Σ khối D×D + D²/2) >> 2s
```
`s = 0` là crop độ phân giải đầy đủ (ví dụ 160×120 ở giữa ảnh để lấy nét).
Khi xong: `STATUS.CAP_DONE`. Ảnh 1080p cả khung: `s = 3` → 240×135 = 32400 word.
Bề rộng đầu ra ≤ 1024 khi `s ≥ 1`.

## TPG — test pattern generator

Tạo frame RAW10 với cùng khung AXI4-Stream như camera (`CTRL.SRC_TPG = 1`),
kích thước `SIZE`, blanking `TPG_BLANK`:

| `TPG_CTRL[1:0]` | Mẫu |
|----|-----|
| 0 | 8 sọc màu: trắng, vàng, cyan, xanh lá, tím, đỏ, xanh dương, đen (0x3C0 / 0) |
| 1 | ramp xám `(x + y + offset) mod 1024` |
| 2 | bàn cờ 32×32 (0x3C0 / 0x040) |
| 3 | màu đơn `TPG_COLOR` |

`TPG_CTRL[4]` = chuyển động (offset +4 mỗi frame). TPG giúp kiểm tra toàn bộ
ISP trên board mà chưa cần camera (bitstream `kv260` không có CSI-2 RX).

## Bản đồ thanh ghi (`0x4000_6000`)

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| 0x000 | `ID` | R | `0x49535001` ("ISP", phiên bản 1) |
| 0x004 | `CTRL` | RW | [0] EN, [1] SRC_TPG |
| 0x008 | `UPDATE` | W | [0] áp cấu hình staging giữa hai frame |
| 0x00C | `STATUS` | R/W1C | [0] UPD_PENDING, [1] FRAME_DONE, [2] CAP_DONE, [3] CAP_BUSY, [4] ERR_INPUT, [5] ERR_FIFO, [6] ERR_OUTPUT, [7] ERR_CAP |
| 0x010 | `IRQ_EN` | RW | bit giống `STATUS` (1, 2, 4..7) → `irq_fast[5]` |
| 0x014 | `FRAME_CNT` | R | số frame đã xử lý |
| 0x018 | `IN_SIZE` | R | kích thước đo được: [27:16] cao, [11:0] rộng |
| 0x01C | `INFO` | R | [31:16] buffer (K word), [15:0] `MaxWidth` |
| 0x020 | `SIZE` | RW* | [27:16] cao, [11:0] rộng (reset 1920×1080) |
| 0x024 | `MODULES` | RW* | [0] BLC [1] DPC [2] WB [3] CCM [4] GAMMA [5] CSC |
| 0x028 | `BAYER` | RW* | 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR |
| 0x02C | `BLC` | RW* | black level (reset 64) |
| 0x030 | `DPC_TH` | RW* | ngưỡng DPC (reset 64) |
| 0x034–0x040 | `WB_R/GR/GB/B` | RW* | gain u4.8 (reset 0x100) |
| 0x044 | `STAT_X` | RW* | [27:16] x1, [11:0] x0 |
| 0x048 | `STAT_Y` | RW* | [27:16] y1, [11:0] y0 |
| 0x04C | `STAT_SAT` | RW* | ngưỡng bão hoà cho tổng RGB (reset 1023) |
| 0x050 | `TPG_CTRL` | RW* | [1:0] mẫu, [4] chuyển động |
| 0x054 | `TPG_BLANK` | RW* | [31:16] số dòng vblank, [15:0] số chu kỳ hblank |
| 0x058 | `TPG_COLOR` | RW* | [29:20] B, [19:10] G, [9:0] R |
| 0x060–0x080 | `CCM[0..8]` | RW* | s3.8, theo hàng (c00, c01, c02, c10, …) |
| 0x084–0x08C | `CCM_OFF[0..2]` | RW* | 11 bit có dấu (đơn vị 10 bit) |
| 0x0A0–0x0C0 | `CSC[0..8]` | RW* | s3.8 |
| 0x0C4–0x0CC | `CSC_OFF[0..2]` | RW* | 9 bit có dấu (đơn vị 8 bit) |
| 0x0E0 | `GAMMA_ADDR` | RW | [9:0] chỉ số, [18:16] bảng (bit 0 R, 1 G, 2 B) |
| 0x0E4 | `GAMMA_DATA` | W | 8 bit, chỉ số tự tăng |
| 0x0F0 | `CAP_CTRL` | W | [0] START |
| 0x0F4 | `CAP_ORIGIN` | RW | [27:16] y0, [11:0] x0 |
| 0x0F8 | `CAP_SIZE` | RW | [27:16] h, [11:0] w (pixel đầu ra) |
| 0x0FC | `CAP_SCALE` | RW | s: lọc hộp 2^s |
| 0x100–0x11C | `ST_SUM_R, ST_SUM_G, ST_SUM_B, ST_CNT, ST_SUM_Y, ST_AF, ST_DPC, ST_FRAME` | R | thống kê frame cuối |
| 0x200–0x2FC | `HIST[0..63]` | R | histogram |

`RW*` = staging, có hiệu lực sau `UPDATE`.

## Lập trình

```c
#include "bow32.h"

bow_isp_init(1920, 1080, ISP_BAYER_RGGB);   /* mọi khối bật, CCM đơn vị, gamma sRGB */
ISP->WB[ISP_WB_R] = 410;                    /* 1.6x */
bow_isp_update(100);                        /* chờ áp cấu hình */
ISP->CTRL = ISP_CTRL_EN;                    /* nguồn: camera (cam_*) */

bow_isp_stats_t s;
bow_isp_wait_frame(100);
bow_isp_read_stats(&s);                     /* mean Y = s.sum_y / s.npix */

bow_isp_capture(0, 0, 240, 135, 3, 1000);   /* cả khung 1080p, lọc 8x8 */
uint32_t rgb = ISP_BUF[0];                  /* 0x00RRGGBB */
```

Ứng dụng đầy đủ (AE, AWB, capture, gửi ảnh): `sw/apps/camera`, xem
[../camera_kv260.md](../camera_kv260.md).

## Kiểm chứng

| Mức | Cách chạy | Kiểm tra |
|-----|-----------|----------|
| Unit, bit-exact | `make -C hw/ip/isp/dv test` | cấu hình + ảnh ngẫu nhiên (và TPG): luồng ra, thống kê, histogram, buffer capture khớp **từng bit** với `tools/isp/isp_model.py`; 2 clock bất đồng bộ, đầu vào có khoảng trống ngẫu nhiên |
| Hệ thống | `make run TEST=camera` | firmware thật: I2C tới IMX219 mô hình, luồng camera, CSI-2 RX qua AXI4-Lite, sọc màu RGB/YUV nhận qua UART, AE/AWB hội tụ |

`make -C hw/ip/isp/dv run SEED=7 TPG=1 WIDTH=160 HEIGHT=90` chạy một case và
giữ file trong `build/isp_dv/`.

## Bài tập mở rộng

- Demosaic thích nghi theo cạnh (Malvar-He-Cutler 5×5) thay cho bilinear.
- Khử nhiễu 2D (bilateral nhỏ) trước demosaic, sharpen sau gamma.
- Thống kê theo lưới (ví dụ 16×9 vùng) cho AE theo vùng / AWB chính xác hơn.
- Lens shading correction (bảng gain theo vị trí).
- 2 pixel/clock để chạy 1080p60 ở clock thấp hơn.
- Đưa đầu ra `isp_*` ra màn hình (DisplayPort của PS hoặc HDMI qua PMOD).
