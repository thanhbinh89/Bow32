# Review bộ mã hoá H.264 (`bow_h264`) cho camera công nghiệp và SoC camera AI

Review toàn bộ khối `hw/ip/h264` (~4 200 dòng RTL, 12 module), mô hình
`tools/h264/h264_model.py`, driver `sw/common/src/bow_h264.c`, ứng dụng
`sw/apps/video` và các test, với hai đích dùng: **camera công nghiệp** (máy
kiểm tra, ghi hình liên tục, chạy nhiều tháng không người trông) và **SoC
camera AI** (lõi ứng dụng nhanh hơn clock video nhiều lần, nhiều luồng, kết
quả AI đi kèm video). Tài liệu IP: [h264.md](h264.md).

## Tóm tắt

| | Đánh giá |
|---|---|
| Lõi thuật toán | **Tốt.** Stream RTL trùng từng byte với mô hình, mô hình giải mã bằng FFmpeg trùng từng pixel; mỗi khối ứng với một mục của chuẩn; bảng CAVLC sinh từ mô hình; khi tràn vẫn ra stream hợp lệ. |
| Tích hợp SoC (CDC, thanh ghi) | **Có lỗi thật** – đã sửa trong PR này: mất sự kiện STATUS, đường qua miền clock chỉ đúng khi clock video nhanh hơn CPU, idr_pic_id, SIZE không kiểm tra, reset riêng miền video. |
| Camera công nghiệp | Dùng được cho 1080p30 intra-only với cảnh thật sau các sửa này (ảnh rất nhiễu ở QP thấp vẫn tràn, xem mục 3). Còn thiếu: ECC cho RAM, watchdog, báo lỗi theo frame có hàng đợi, slice theo hàng MB, test lỗi đầu vào. |
| SoC camera AI | **Chưa đủ.** Intra-only (bitrate gấp ~5–10 lần IPPP), không có AXI master / DDR, không có QP theo vùng (ROI), không có metadata / SEI, một luồng. |

## 1. Cách làm

1. Đọc toàn bộ RTL (`bow_h264`, `_regs`, `_input`, `_mb`, `_pred`, `_fwd`,
   `_dc`, `_inv`, `_cavlc`, `_bitpack`, `_pkg`), thư viện CDC / FIFO dùng chung,
   phần tích hợp trong `bow32_top`, driver, ứng dụng video và ràng buộc XDC.
2. Kiểm tra lại cú pháp với chuẩn (slice header, `mb_type`, mã level / suffixLength,
   total_zeros, run_before, nC, giải lượng tử DC, emulation prevention): khớp.
3. Chạy test gốc (8/8 PASS), đo thông lượng CAVLC bằng chính RTL.
4. Với mỗi lỗi: viết test bắt được nó, **chạy test mới trên RTL cũ để thấy nó
   báo lỗi**, rồi sửa và chạy lại.

## 2. Lỗi đã sửa trong PR này

| # | Mức | Vấn đề (RTL cũ) | Hậu quả | Sửa |
|---|:---:|-----------------|---------|-----|
| 1 | Cao | `STATUS` W1C: lần ghi `STATUS` gán lại cả thanh ghi, đè lên sự kiện tới cùng chu kỳ (kể cả khi chỉ xoá bit khác hoặc ghi 0) | mất `FRAME_DONE` / `DONE` / lỗi; driver dùng ngắt treo, vòng chờ `DONE` không bao giờ thoát | sự kiện thắng W1C: `(status & ~clr) \| set` (như `bow_csi2rx_regs`, `bow_mkv`) |
| 2 | Cao (SoC) | EN qua `bow_sync`; START, STOP, QP qua `bow_cdc_pulse` (xung cần cách nhau ≥ 3 chu kỳ video, QP phải đứng yên tới khi được lấy) | đúng chỉ khi clock video nhanh hơn CPU vài lần (KV260: 200 / 50 MHz; hai lần ghi cách 2 chu kỳ CPU cần video ≥ 1,5 lần CPU, QP không lẫn bit cần ≥ 3 lần). CPU nhanh hơn (SoC 400 MHz – 1 GHz, video 150 – 300 MHz): hai lần ghi QP liền nhau mất / lẫn bit (QP > 51 → `slice_qp_delta` sai chuẩn), START ngay sau EN có thể bị bỏ, EN = 0 ngắn không tới | **một bản ghi điều khiển** `ctrl_t` qua `bow_cdc_hs` (bắt tay req/ack): đúng thứ tự, giữ giá trị mới nhất, giữ lại một lần EN = 0 (`dis`), lệnh cuối thắng; START khi EN = 0 bị bỏ ngay ở thanh ghi |
| 3 | Trung bình | `ERR_OVF` / `ERR_INPUT` sang miền CPU: bộ giới hạn 1 xung / 16 chu kỳ video + `bow_cdc_pulse` | cần CPU ≥ 3/16 clock video (≥ 56 MHz với video 300 MHz); MCU công nghiệp 25 – 50 MHz mất `ERR_OVF` | cờ dính + `bow_cdc_hs` |
| 4 | Trung bình | `DONE` và `FRAME_DONE` qua hai `bow_cdc_pulse` riêng | `DONE` có thể thấy trước `FRAME_CNT` / `FRAME_BYTES` mới | một xung, `DONE` lấy từ `FRAME_INFO.LAST` cùng chu kỳ |
| 5 | Trung bình | `idr_pic_id` về 0 ở mỗi START | ghi liên tục qua STOP / START (đổi cấu hình, phục hồi lỗi): hai IDR liền nhau cùng `idr_pic_id`, sai 7.4.3 (bộ giải mã có thể gộp hai ảnh) | không đặt lại ở START (luân phiên từ reset) |
| 6 | Trung bình | `SIZE` không kiểm tra | rộng > `MaxWidth`: strip buffer và line buffer (cả TotalCoeff cho nC) bị chồng địa chỉ → **stream không giải mã được**; cao 4082 – 4094: số hàng MB tràn 8 bit = 0 → không frame nào ra, `DONE` không đến; 0 → engine chạy 256 MB / hàng | kẹp 16…min(`MaxWidth`, 4080) × 16…4080 (đọc lại thấy giá trị thật) |
| 7 | Thấp | chỉ `vid_rst_ni` tích cực (ví dụ MMCM video mất lock): phía CPU của FIFO ra và các `bow_cdc_pulse` không reset | FIFO ra lệch con trỏ (từ rác tới DMA), xung giả | `xrst_n`: phía CPU của mọi đường qua miền clock reset cùng; thanh ghi tự gửi lại EN / DEBLOCK / QP |
| 8 | Thấp | (testbench) đặt pixel đúng cạnh clock bằng `<=` | đúng chỉ khi được gọi đúng cạnh `vclk` (mất pixel SOF khi gọi lệch) | đặt tín hiệu 0,1 ns sau cạnh |


**Tính năng thêm, cần cho cả hai đích:** `FRAME_INFO` (`0x03C`): QP, `idr_pic_id`,
DEBLOCK, LAST và **lỗi của chính frame đó**. Trước đây `ERR_OVF` là một cờ chung:
khi encoder chậm hơn camera, strip không có chỗ được mã hoá bằng **mẫu cũ** (stream
vẫn hợp lệ) nhưng phần mềm không biết frame nào bị — với AI (phát hiện, đếm) hoặc
kiểm tra công nghiệp, frame như vậy phải bị bỏ hoặc đánh dấu. Ứng dụng `video`
dùng `FRAME_INFO` để in QP thật và đếm frame có strip cũ.

### Test bắt được lỗi trên RTL cũ

Testbench mới chạy trên RTL ở `e21b93a` (đã tắt hai kiểm tra của tính năng mới:
`FRAME_INFO`, kẹp `SIZE`), 8 seed × 3 tỉ lệ clock:

| Kiểm tra | RTL cũ | RTL mới |
|----------|--------|---------|
| STATUS bị đọc / ghi W1C liên tục trong lúc mã hoá (#1) | mất `FRAME_DONE` / `DONE` ở 15 / 24 case (cả 3 tỉ lệ clock) | 18 / 18 PASS |
| hai lần ghi QP liền nhau, CPU 400 MHz / video 143 MHz (#2) | stream sai từ frame 1 – 2 ở 4 / 8 seed | PASS |
| START lần hai, `FRAMES = 1` (#5) | frame đó sai `idr_pic_id` ở 4 / 4 seed có restart (clock gốc và clock chậm; với CPU nhanh 3 seed đã sai trước đó vì QP) | PASS |

## 3. Thông lượng thực tế

Tài liệu cũ ghi 392 chu kỳ / MB (đúng cho engine macroblock). Nhưng tầng E của
CAVLC phát **một phần tử cú pháp mỗi chu kỳ** (coeff_token, từng level,
total_zeros, từng run_before, + 1 chu kỳ chuyển khối), bit packer **1 byte / chu
kỳ**; chỉ có 2 slot hệ số giữa engine và CAVLC. Ước lượng theo FSM của RTL bằng
mô hình (128×64) và đo trong mô phỏng RTL (128×32, đếm chu kỳ `est_q ≠ EIdle`):

| Nội dung | QP | E (ước lượng) | E (đo RTL) | byte / MB | giới hạn |
|----------|---:|--------------:|-----------:|----------:|----------|
| nhiễu | 10 | 484 (max 510) | 507 | 464 | CAVLC + packer |
| nhiễu | 28 | 598 (max 633) | 565 | 221 | CAVLC (nhiều run_before) |
| cảnh | 10 | 465 (max 523) | 455 | 181 | CAVLC |
| cảnh | 22 | 188 | – | 73 | engine (392) |
| cảnh | 28 | 112 | 119 | 36 | engine (392) |

Ở 200 MHz: 1080p (8 160 MB) từ ~62 fps (cảnh dễ) xuống **~39 fps** với nhiễu
ngẫu nhiên (630 chu kỳ / MB, trường hợp xấu nhất); 720p ~140 … ~88 fps.

Trung bình cả frame không đủ để kết luận: camera đưa mỗi hàng MB trong 16 dòng,
còn strip buffer chỉ giữ 4 strip. IMX219 1080p30 (18,9 µs / dòng) cho
16 × 18,9 µs × 200 MHz / 120 MB ≈ **504 chu kỳ / MB** trong lúc nhận dòng (817 nếu
tính cả vblank). Cảnh thật (QP 10: 455) kịp, nhiễu ngẫu nhiên QP 10 (507) sát ngân
sách; nhiễu QP 22 – 34 (565 đo trong RTL, ~570 – 630 theo mô hình) đầy strip buffer
sau ~12 – 25 hàng MB (trong 68) → `ERR_OVF`, phần còn lại của frame là strip mẫu cũ
(giờ thấy được trong `FRAME_INFO`). 1080p60 chỉ
đạt với cảnh dễ. Camera công nghiệp gain cao (ban đêm, phơi sáng ngắn) và cảnh
nhiều chi tiết (sỏi, lá, vải trong máy kiểm tra) ở QP thấp tiến gần trường hợp này.

Hướng tăng: CAVLC 2 phần tử / chu kỳ (level + run_before song song, coeff_token
gộp với dấu trailing ones), bỏ chu kỳ chuyển khối, packer 2 – 4 byte / chu kỳ;
thêm slot hệ số (2 → 4) và strip (`NumStrips` 8: 12 URAM ở rộng 2048) để hấp thụ
dao động giữa các hàng; QP tối thiểu theo độ nhiễu khi firmware thấy `ERR_OVF`.

## 4. Rủi ro còn lại và khuyến nghị (chưa làm trong PR này)

Ưu tiên: **P0** chặn sản phẩm, **P1** nên có trước khi triển khai, **P2** cải thiện.

### Camera công nghiệp

| Ưu tiên | Vấn đề | Khuyến nghị |
|:---:|--------|-------------|
| P1 | Không có ECC / parity: strip buffer (6 URAM), line buffer, slot hệ số, FIFO ra; lỗi mềm (SEU) cho ảnh hỏng hoặc stream hỏng mà không ai biết | bật ECC của UltraRAM (`EN_ECC_RD/WR`) và BRAM 64 bit, đưa lỗi sửa được / không sửa được vào `STATUS` và `FRAME_INFO` |
| P1 | Không có watchdog: FSM kẹt (bitpack chờ DMA mãi) chỉ thấy qua `BUSY` | giới hạn `FRAME_CYCLES` (thanh ghi), quá hạn → lỗi + ngắt; lệnh ABORT xả pipeline mà không cần reset |
| P1 | `FRAME_INFO` chỉ giữ frame mới nhất: CPU trễ > 1 frame thì mất thông tin | FIFO trạng thái theo frame (số thứ tự, byte, QP, lỗi, thời điểm SOF) |
| P1 | Một slice mỗi frame: mất một gói trên mạng mất cả frame; độ trễ ≥ 1 frame | slice mỗi hàng MB (NAL mỗi hàng): giới hạn lỗi trong một hàng, giải mã được trước khi hết frame |
| P1 | Không có test lỗi đầu vào: `ERR_OVF`, `ERR_INPUT` (frame / dòng ngắn, EN = 0 giữa frame), cờ lỗi của `FRAME_INFO` | thêm case vào `tb_bow_h264` và mô hình (mô hình cần biết strip nào giữ mẫu cũ) |
| P2 | Điều khiển tốc độ bit bằng phần mềm, 1 QP / frame, trễ 1 frame | rate control phần cứng theo hàng MB (`mb_qp_delta`), CBR / VBR có trần |
| P2 | QP tối thiểu 10, 8 bit: không có chế độ gần không mất mát cho đo lường | `I_PCM` (Baseline có) cho vùng cần giữ nguyên; độ sâu 10 bit cần High 10 |
| P2 | Không có dấu thời gian / số thứ tự frame trong stream | SEI `user_data_unregistered` với số frame, thời điểm trigger |

### SoC camera AI

| Ưu tiên | Vấn đề | Khuyến nghị |
|:---:|--------|-------------|
| P0 | Intra-only: bitrate ~5–10 lần IPPP cùng chất lượng → lưu trữ / mạng nhiều camera không chịu được | frame P (`P_Skip` + tìm chuyển động nhỏ ±16, frame tham chiếu trong DDR); GOP cấu hình được, IDR theo yêu cầu |
| P0 | Ra qua DMA vào VRAM 1 MiB; không có AXI4 master | AXI4 master ghi vào ring buffer trong DDR (địa chỉ 64 bit, burst, nhiều giao dịch chờ, con trỏ đọc / ghi cho phần mềm) |
| P1 | Vào chỉ từ ISP (YUV 4:4:4, không back-pressure) | chế độ đọc frame NV12 từ DDR: mã hoá luồng phụ (thu nhỏ), frame có OSD / kết quả AI vẽ lên, nhiều camera xen kẽ |
| P1 | Không có QP theo vùng | bản đồ QP theo MB (ROI từ bộ phát hiện: mặt, biển số chất lượng cao, nền QP cao) — với `I_16x16` chỉ cần `mb_qp_delta` trong CAVLC và QP theo MB trong engine |
| P1 | Không có metadata | SEI cho kết quả AI / dấu thời gian, đồng bộ với frame qua FIFO trạng thái |
| P2 | Một ngữ cảnh | nhiều ngữ cảnh thanh ghi để chia thời gian cho nhiều luồng |
| P2 | Không có clock gating | gate engine khi rảnh (1080p30 chỉ dùng ~50 % engine) |
| P2 | Không có toàn vẹn stream | ký / mã hoá frame bằng khối MKV có sẵn (video làm bằng chứng) |

### Kiểm chứng

- Test đơn vị chỉ dùng frame nhỏ (≤ 80×48): chưa có case ở 1920×1080 / rộng
  `MaxWidth` (địa chỉ strip buffer, độ sâu line buffer ở biên). Nên có test dài
  chạy hằng đêm.
- Chưa có SVA / formal cho FSM và CDC; nên chạy `report_cdc` của Vivado trong
  flow `kv260_cam` như đã làm cho DDR.
- Chưa có functional coverage (tổ hợp mode, đường escape của level, suffixLength 6,
  TotalCoeff 16).
- PR này không chạy lại Vivado (không có trong môi trường review): phần thêm ~60
  flop và hai bộ đồng bộ; nên chạy lại `make fpga BOARD=kv260_cam` để xác nhận
  timing / tài nguyên. Dữ liệu của `bow_cdc_hs` là bus quasi-static (đổi ≥ 2 chu
  kỳ đích trước khi được lấy), cùng loại với các thanh ghi cấu hình đã nằm trong
  `set_clock_groups`, không cần thêm ràng buộc.
- `bow_isp_regs` có cùng kiểu W1C như lỗi #1 (ngoài phạm vi PR này, nên sửa
  giống hệt).

## 5. Điểm mạnh nên giữ

- Mô hình Python là đặc tả: mọi quyết định của encoder ghi trong
  [h264.md](h264.md), RTL bit-exact, mô hình đối chiếu với FFmpeg.
- Strip buffer thay cho frame buffer: không cần DDR, độ trễ ~16 dòng + mã hoá.
- Khi encoder chậm / đầu vào hỏng, stream **luôn hợp lệ** (strip vẫn được mã
  hoá) — đúng hướng cho thiết bị không người trông; giờ có thêm cờ theo frame.
- Pipeline 1 hàng 4 mẫu / chu kỳ, dùng chung bộ dự đoán cho mọi pass: ít tài
  nguyên (~13 400 LUT cùng DMA, 20 DSP).

## 6. Lộ trình đề xuất

1. **Công nghiệp (ngắn):** ECC + watchdog, FIFO trạng thái theo frame, slice
   theo hàng MB, test lỗi đầu vào và test Full HD, `report_cdc`.
2. **SoC AI:** AXI4 master + ring buffer DDR, đầu vào NV12 từ DDR, ROI QP
   (`mb_qp_delta`), SEI metadata.
3. **Hiệu năng / bitrate:** CAVLC 2 phần tử / chu kỳ, frame P, nhiều luồng.
