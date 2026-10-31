# Video H.264 trên Kria KV260: camera → ISP → H.264 → MP4

Hướng dẫn quay video bằng toàn bộ luồng phần cứng của Bow32 trên KV260 và lấy
về PC thành file **MP4**:

```
 Pi camera v2 ─D-PHY─► CSI-2 RX ─RAW10─► ISP ─YUV 4:4:4─► H.264 encoder ─stream─► DMA ─► video RAM 1 MiB
 (IMX219, J9)          0x4000_8000        0x4000_6000      0x4000_9000              kênh 0  0x2400_0000
                                                                                              │
             PC: bow32_video.py ◄── UART0 921600 baud ◄── Ibex (sw/apps/video: send) ◄────────┘
                 → video.h264 + video.mp4
```

> **Kết quả trên KV260 (2026-10-31):** bitstream `kv260_cam` (Vivado 2025.2) đạt
> timing ở clock video 200 MHz (setup WNS +0,066 ns, hold +0,010 ns), bus skew
> 9/9, 0 critical warning; 23 400 LUT, 71 BRAM, 39 URAM, 49 DSP. Với Pi camera
> v2: **720p30 → 45 frame @ 15 fps** (`--skip 1`, 979 KB, QP 23…30, ~24,5 KB/frame)
> và **1080p30 → 20 frame @ 15 fps** (670 KB, QP 24…30), không bỏ pixel nào
> (encoder xong mỗi frame 1080p 0,3 ms sau dòng cuối của camera); TPG ramp
> chuyển động 720p30 60 frame. Mọi stream giải mã bằng FFmpeg (PyAV) ra đúng số
> frame, Constrained Baseline, ảnh đúng; truyền 90 KiB/s ở 921600 baud, CRC đúng.
> Bitstream cơ bản `kv260` (không D-PHY, encoder chạy ở 50 MHz, nguồn là TPG)
> cũng đạt timing: WNS +5,844 ns, 22 200 LUT, 39 URAM.

Phần camera (bitstream, cáp, eye calibration, AE/AWB) giống
[camera_kv260.md](camera_kv260.md); chi tiết bộ mã hoá: [ip/h264.md](ip/h264.md),
DMA: [ip/dma.md](ip/dma.md).

## 1. Build và nạp

```bash
make sw                                  # build/sw/video/video.bin
make fpga BOARD=kv260_cam                # bitstream có H.264 + DMA + video RAM
make fpga-jtag BOARD=kv260_cam           # nạp qua JTAG (Linux trên PS vẫn chạy)
python3 tools/bow32_flash.py -p /dev/ttyACM0 --no-break flash build/sw/video/video.bin
```

Tài nguyên thêm so với bản camera: bộ mã hoá + DMA ~13 400 LUT, 6 URAM (strip
buffer), 7 BRAM, 20 DSP; video RAM 32 URAM. Toàn bản `kv260_cam`: 23 400 LUT
(20 %), 71 / 144 BRAM, 39 / 64 URAM, 49 DSP.

Không có BREAK (adapter CH9102): một ứng dụng đang chạy được đưa về loader bằng
`wr 40000010 4c4f4144` (BOOT_FLAG "LOAD") rồi `wr 4000000c 52535421` (RST_CTRL),
sau đó `bow32_flash.py --no-break flash ...`. Lưu ý: `make -C sw/apps/video` chỉ
build `.elf`; dùng `make sw` (hoặc `make -C sw/apps/video all`) để có `.bin`.

## 1b. Ví dụ một lần quay (720p30, `--skip 1`)

```
$ python3 tools/bow32_video.py -p /dev/ttyACM0 --fast 921600 rec -n 45 --skip 1 -o video.mp4
csi2rx: calibrated taps 288/272 eye 272/272
streaming 1280x720 @30 fps
waiting 5 s for exposure / white balance
recording 45 frames (skip 1)
  rec: 45 frames 1280x720, 30/2 fps, QP 30, 23300 bytes per frame
  frame 1: 3456 bytes, 13718 us
  ...
  frame 45: 24512 bytes, 13719 us
  rec: 45 frames, 979164 bytes (QP 23..30, largest 24928)
  979164/979164 bytes, 90.3 KiB/s
video.mp4: 45 frames 1280x720 @ 15.00 fps, 979164 bytes (12.4 s transfer), also video.h264
```

`13718 us` là thời gian từ start of frame tới khi NAL của frame đó ra hết: 720
dòng camera mất 13,6 ms, encoder theo kịp từng strip.

Ứng dụng in khi khởi động:

```
Bow32 video demo (camera -> ISP -> H.264 -> DMA), type h for help
camera: IMX219 found (id 0219)
csi2rx: Bow32 receiver, 2 lanes, PHY clock 199 MHz
h264: Bow32 encoder, max width 2048, 4 strips; DMA 2 channels; video RAM 1024 KiB
```

## 2. Quay bằng tool trên PC

```bash
python3 tools/bow32_video.py -p /dev/ttyACM0 --fast 921600 rec -n 45 --skip 1 -o video.mp4
```

`rec` làm lần lượt: `mode` (mặc định 720p30), `cam` (lần đầu hiệu chỉnh eye),
bật AE/AWB và chờ vài giây cho chúng khoá, `qp`, `deblock`, rồi lệnh `rec n skip
kbytes` của board, `send`, kiểm tra CRC và ghi `video.h264` + `video.mp4`.

| Tuỳ chọn | Ý nghĩa |
|----------|---------|
| `-n 45` | số frame được mã hoá |
| `--skip 1` | bỏ 1 frame camera sau mỗi frame mã hoá: 30 fps → 15 fps (video dài gấp đôi trong cùng bộ nhớ) |
| `--kbytes 20` | kích thước mong muốn mỗi frame; mặc định = 1 MiB / n |
| `--qp 30` | QP của frame đầu; rate control tăng / giảm 1 mỗi frame |
| `--mode 1080p` / `--mode 640 360` | kích thước (rộng bội số 16, cao chẵn) |
| `--source tpg4` | test pattern chuyển động của ISP thay cho camera |
| `--no-deblock` | tắt bộ lọc deblocking trong decoder |

`bow32_video.py mp4 video.h264 -o video.mp4 --fps 15` đóng gói lại một stream có
sẵn (không cần board).

## 3. Shell của ứng dụng `video`

```
cam | tpg [n] | stop | mode 1080p|720p|<w> <h> [fps] | ae on|off | awb on|off
qp <10..51> | deblock on|off
rec <n> [skip] [kbytes]     quay n frame vào video RAM
send                        gửi: "H264 <bytes> <crc32> <frames> <w> <h> <fps_num> <fps_den>",
                            dữ liệu, "END"
stat | dmatest | info | baud | rd | wr
```

`rec` ghi SPS + PPS vào đầu video RAM, cho DMA kênh 0 ghi stream ngay sau, bật
encoder (`FRAMES = n`, `SKIP`), rồi theo dõi từng frame (`FRAME_CNT`,
`FRAME_BYTES`) để chỉnh QP. Khi chỗ trống còn ít hơn 2 lần frame lớn nhất, nó
ra lệnh STOP; frame đang mã hoá vẫn vừa. Nếu bộ nhớ vẫn đầy, DMA chuyển sang
DROP để xả encoder và bản quay giữ nguyên các frame đã đủ (`PKT_CNT`,
`PKT_END`).

## 4. Giới hạn và lựa chọn

- **Độ dài**: 1 MiB video RAM. Video toàn intra cần ~20–80 KB mỗi frame 720p
  (tuỳ cảnh và QP): khoảng 15–50 frame. `--skip` kéo dài thời gian, QP cao /
  kích thước nhỏ cho nhiều frame hơn.
- **Tốc độ truyền**: UART 921600 baud ≈ 90 KB/s: 1 MiB mất ~12 s.
- **Thông lượng encoder**: 392 chu kỳ/MB ở 200 MHz. Camera 1080p30 của IMX219
  đưa 120 macroblock mỗi 16 dòng × 18,9 µs = 302 µs; encoder cần 235 µs: kịp.
  Khi không kịp (ví dụ cảnh rất chi tiết ở QP thấp làm CAVLC chậm), encoder bỏ
  pixel (`ERR_OVF`, ứng dụng báo `warning`) nhưng stream vẫn hợp lệ.
- **Màu**: ISP xuất BT.709 video range (Y 16…235), SPS báo đúng (VUI), mọi
  trình phát hiển thị đúng màu.
