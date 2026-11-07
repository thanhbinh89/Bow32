# Đánh giá bộ thu MIPI CSI-2 (`bow_csi2rx`) cho camera công nghiệp và SoC camera AI

Tài liệu này trả lời ba câu hỏi:

1. Bộ thu CSI-2 hiện tại (đặc tả ở [ip/csi2rx.md](ip/csi2rx.md)) đúng và chắc tới đâu?
2. Còn thiếu gì để dùng trong **camera công nghiệp** (machine vision, FPGA Zynq/Kria,
   −40…+85 °C, chạy 24/7)?
3. Còn thiếu gì để dùng trong **SoC camera AI** (ASIC hoặc FPGA lớn, 4 lane, nhiều
   cảm biến, ảnh đi thẳng vào NPU/DDR)?

Phạm vi review: RTL `hw/ip/csi2rx/rtl/` (11 file), I/O FPGA
`hw/fpga/common/rtl/bow_dphy_io_xusp.sv`, driver `sw/common/src/bow_csi2rx.c`, testbench
`hw/ip/csi2rx/dv/`, mô hình `tools/csi2/csi2_model.py`, tài liệu. Mục 9 ghi những gì đã
chạy lại để kiểm tra. Mức ưu tiên: **P0** = chặn use case, **P1** = cần cho sản phẩm,
**P2** = nên có.

## 1. Kết luận

| Use case | Kết luận |
|----------|----------|
| Học tập / FPGA, 1–2 lane ≤ ~1 Gbit/s, RAW10/RAW8, một cảm biến (IMX219 trên KV260) | **Đạt.** Thiết kế sạch, chia lớp đúng (I/O FPGA tách khỏi phần độc lập công nghệ), ECC/CRC đúng đặc tả, quan sát được rất tốt (LOG, RAW, bộ đếm, FRAME_SUM, đo thời gian), kiểm chứng bằng mô hình Python viết độc lập từ đặc tả, chạy trên board. |
| Camera công nghiệp trên FPGA (Zynq/Kria UltraScale+) | **Dùng làm nền được, chưa đưa vào sản phẩm được.** Bốn điểm P0: nhiều packet trong một HS burst bị bỏ **không báo lỗi** (F1); tràn FIFO làm hỏng khung AXI4-Stream (F2, đã tái hiện bằng mô phỏng); lỗi CRC/cắt dòng không đi theo luồng ảnh (F3); điểm lấy mẫu IDELAY không bù nhiệt và không tự bám (F6) nên chưa có bằng chứng chạy được trên dải nhiệt công nghiệp. Thêm RAW12 (hầu hết cảm biến công nghiệp). |
| SoC camera AI (ASIC) | **Tái dùng được lớp giao thức, không tái dùng được PHY và datapath.** D-PHY ở đây là primitive UltraScale+ ở chế độ component, không mang sang ASIC; SoC sẽ dùng D-PHY (hoặc C/D-PHY) cứng qua giao diện **PPI**. Datapath 1 pixel/clock, 2 lane, một VC/DT là khoảng 1/5 thông lượng cần cho một cảm biến 4 lane × 2,5 Gbit/s; cần bộ định tuyến VC/DT nhiều luồng, metadata (số frame, timestamp, cờ lỗi), và đưa lớp packet sang miền clock chạy liên tục. Xem kiến trúc đề xuất ở mục 6. |

## 2. Điểm mạnh (giữ khi phát triển tiếp)

- **Đúng đặc tả ở những chỗ khó.** Bảng cột ECC (`bow_csi2rx_pkg.sv:69`) khớp CSI-2 v1.x
  và là mã SEC-DED thật: mọi cột data có trọng số lẻ (3 hoặc 5), nên **không lỗi 2 bit
  nào bị sửa sai** (đã kiểm tra cả 435 cặp, mục 9). CRC-16 (0x8408, init 0xFFFF, kiểm
  bằng phần dư 0) đúng. Packet kết thúc theo WC, không theo cuối burst: đúng cách xử lý
  byte rác của HS-TRAIL.
- **CDC có chủ đích, có ràng buộc.** Reset bất đồng bộ / nhả đồng bộ cho từng miền,
  sự kiện qua `bow_cdc_pulse`, lệnh qua bộ đếm gray req/ack (chạy được khi byte clock
  dừng), FIFO pixel con trỏ gray, 7 `set_bus_skew` được build script kiểm tra.
- **Xử lý byte clock gián đoạn** (clock lane không liên tục) cẩn thận: CE của hai
  `BUFGCE_DIV` chỉ đổi khi lane clock đứng yên ở HS-0, `ISERDESE3` được reset mỗi burst
  để căn lại bộ chia /4 bên trong.
- **Quan sát và chẩn đoán**: 10 cờ lỗi dính, bộ đếm theo loại, LOG 64 packet với 4 chế
  độ trigger, RAW word của PHY, `FRAME_SUM`, `FRAME_TIME`/`LINE_TIME`, đo tần số byte
  clock, bản đồ eye. Đây là phần nên giữ nguyên trong mọi bản sau.
- **Kiểm chứng**: mô hình tham chiếu viết từ đặc tả (không từ RTL), 30 case trong CI
  (random + lỗi cài vào + directed), test mức chân bằng unisim, test hệ thống với
  firmware thật, `csi2_test` 16/16 trên KV260.
- **Nhỏ**: 1 740 LUT, 2 234 FF, 1 RAMB36 (bằng ~ một nửa Ibex).

## 3. Phát hiện

| ID | Mức | Vấn đề | Vị trí | Hệ quả |
|----|-----|--------|--------|--------|
| F1 | P0 | Mỗi HS burst chỉ một packet; byte sau CRC bị bỏ tới burst sau mà **không có cờ hay bộ đếm** (`trunc` chỉ xét `dst_q != Idle`) | `bow_csi2_packet.sv:308`, `:193` | CSI-2 cho phép nhiều packet liền nhau trong một burst (FS + dòng đầu, dòng + LE, nhiều VC của deserializer GMSL/FPD-Link, cảm biến tốc độ cao). Với cảm biến như vậy mất dòng/FS mỗi frame, ISP huỷ frame, phần mềm chỉ thấy `no lines (DT/VC filter?)`. |
| F2 | P0 | Tràn FIFO pixel bỏ **từng nhóm**, kể cả nhóm mang `eol` hay `sof` | `bow_csi2_unpack.sv:87`, `bow_fifo_async` bỏ push khi đầy | Luồng ra sai khung AXI4-Stream: một dòng không có `tlast`, dính vào dòng sau, `tuser` nằm giữa dòng. Đã tái hiện (mục 9): dòng 72 pixel với `tuser` ở pixel 12, trong khi `FRAME_INFO` vẫn báo frame 20 dòng. ISP của Bow32 tự huỷ frame sai kích thước nên hệ thống Bow32 không hỏng ảnh, nhưng khối khác (DMA ghi DDR, NPU) sẽ nhận ảnh lệch. `tready` thấp thật sự xảy ra: ISP giữ `tready = 0` khi cập nhật cấu hình (`hold_i`). |
| F3 | P0 | Lỗi CRC, packet bị cắt, tràn FIFO chỉ vào thanh ghi/LOG, không đi theo pixel | `bow_csi2_packet.sv:331`, cổng `m_axis_*` trong `bow_csi2rx.sv:51` | Khối sau không biết dòng/frame nào hỏng (pixel đi trước khi biết CRC). Công nghiệp: ảnh hỏng có thể bị đo/kiểm sai. AI: suy luận trên frame hỏng. Cần cờ lỗi theo dòng/frame và chính sách bỏ frame. |
| F4 | P1 | Aligner chỉ nhận đúng `0x00` rồi `0xB8`; burst deskew (D-PHY v1.2, sync toàn bit 1 rồi mẫu `0101…`) thành lỗi SOT | `bow_dphy_align.sv:47` | Cảm biến bật deskew định kỳ (bắt buộc trên 1,5 Gbit/s, một số cảm biến cho bật cả ở tốc độ thấp hơn) làm `CNT_SOT` tăng liên tục, `bow_csi2rx_link_check()` báo hỏng. Cũng không chấp nhận sync sai 1 bit (D-PHY phân biệt `ErrSotHS` sửa được với `ErrSotSyncHS`). |
| F5 | P1 | `SETTLE` cố định 70 ns, không theo tốc độ lane | `bow_csi2rx.c:68` | T_HS-SETTLE là 85 ns + 6 UI … 145 ns + 10 UI: ổn ở 912 Mbit/s, sớm quá ở tốc độ thấp (giới hạn (c) của tài liệu IP). Sửa được chỉ trong driver: tính theo `lane_rate`, nhắm giữa cửa sổ. |
| F6 | P0 (công nghiệp) | `IDELAYE3` ở `COUNT`, `EN_VTC 0`; eye chỉ hiệu chỉnh khi phần mềm gọi; tiêu chí "32 dòng không lỗi" | `bow_dphy_io_xusp.sv:134`, `bow_csi2rx.c:188` | Clock trễ hơn data 0,4–1,4 ns tuỳ PVT (≈ 1 UI ở 912 Mbit/s), lề hiện tại ±0,47 ns quanh tâm, đo ở nhiệt độ phòng. Trôi nhiệt của cây clock toàn cục và của tap (không VTC) chưa được đo. 32 dòng 1080p ≈ 6×10^5 bit chỉ chứng minh BER < ~5×10^-6 (95 %), nên mép eye tìm được lạc quan so với BER 10^-12. |
| F7 | P1 | Lớp packet, sự kiện, LOG chạy trên byte clock bị gate; phần việc cuối packet cần ~11 byte clock sau byte cuối | `bow_csi2rx.sv:473` (chú thích), tài liệu IP mục *Đo thời gian* | Máy phát có T_CLK-POST ngắn (hoặc tốc độ thấp) làm FE, ngắt, `FRAME_SUM` trễ tới burst sau, có khi hết cả vertical blanking. Với pipeline AI kích hoạt theo FE, đây là độ trễ không xác định. Gốc của nhiều độ phức tạp khác (tap chỉ nạp được trong burst, reset nhả ở burst sau). |
| F8 | P2 | Bỏ qua `ECC[7:6]` (VCX của CSI-2 v2.0); lỗi 3 bit ở header có 93 % khả năng bị "sửa" thành header khác | `bow_csi2_packet.sv:134` | Luồng dùng VC ≥ 4 bị coi là lỗi ECC hoặc lẫn VC. Header sửa sai (WC sai) làm packet dài/ngắn sai; CRC thường bắt được, nhưng nên có kiểm tra WC so với độ rộng mong đợi. |
| F9 | P2 | Ghi thanh ghi bỏ qua `be` (byte enable) | `bow_csi2rx_regs.sv:113`, `:495` | Ghi byte/halfword (Ibex lặp byte trên cả word) ghi sai các trường khác. Driver chỉ ghi word nên chưa lộ; với IP tích hợp vào SoC khác nên xử lý `be` hoặc báo bus error. |
| F10 | P2 | Sự kiện LP được giải phóng mỗi 16 chu kỳ video, đúng chỉ khi `vid_clk_i ≤ 5 × clk_i` | `bow_csi2rx.sv:276` | Ràng buộc tích hợp ẩn: SoC có CPU clock thấp (chế độ tiết kiệm) và video clock cao sẽ mất bộ đếm. Nên ghi vào bảng tham số hoặc kiểm bằng assertion. |
| F11 | P2 | Bộ đếm lỗi 16 bit, `CNT_BURST` bão hoà sau ~60 frame 1080p | `bow_csi2rx_regs.sv:275` | Chạy 24/7 cần bộ đếm 32 bit hoặc đếm theo cửa sổ (lỗi/giây) để theo dõi suy giảm link. |
| F12 | P1 (ASIC) | Cấu hình qua `bow_sync` từng bit, không bắt tay; đổi VC/DT/LANES phải tắt RX | `bow_csi2rx.sv:187`, `:321` | Công cụ CDC sẽ báo mọi bus này, cần waiver. Không đổi được luồng khi đang chạy (đổi chế độ HDR, chọn VC khác) mà không mất frame. |

## 4. Camera công nghiệp: yêu cầu và khoảng cách

| Yêu cầu | Hiện trạng | Việc cần làm | Ưu tiên |
|---------|------------|--------------|---------|
| Tương thích cảm biến: nhiều packet/burst, LS/LE | một packet/burst (F1) | đọc header kế tiếp sau CRC, bỏ byte filler; LS/LE dùng được làm mốc dòng | P0 |
| Định dạng | RAW8, RAW10 | RAW12 (đa số cảm biến global shutter), RAW14/16 cho HDR; đầu ra ≥ 12 bit | P0 |
| Toàn vẹn frame | pixel đi trước CRC, không cờ lỗi (F3); tràn FIFO hỏng khung (F2) | `tuser[1]` = dòng lỗi ở `tlast`, trạng thái frame ở FE; bỏ cả dòng khi tràn (giữ chỗ cho nhóm `eol`) hoặc bỏ cả frame; chế độ "drop frame on error" | P0 |
| Dải nhiệt −40…+85 °C | tap cố định sau hiệu chỉnh, không VTC (F6) | bám eye tự động (dò hai mép ±k tap trong blanking, hoặc dùng lane clock liên tục để nạp tap ngoài burst), hiệu chỉnh lại theo nhiệt độ SYSMON; đo eye trong buồng nhiệt | P0 |
| Khởi động nhanh | hiệu chỉnh đầy đủ ở lần `cam` đầu (cần cảm biến đang stream) | lưu tap đã hiệu chỉnh vào flash theo board, chỉ kiểm tra lề lúc khởi động | P1 |
| Giám sát và tự phục hồi | máy LP tự về Stop; eye chỉ làm lại khi phần mềm gọi | watchdog frame (không có FS/FE trong N ms → ngắt), kiểm tra kích thước (WC, số dòng so với cấu hình), kiểm tra số frame liên tục (WC của FS), ngắt theo tỉ lệ `ECC_CORR` | P1 |
| Deskew, sync sai 1 bit | lỗi SOT (F4) | nhận và bỏ qua burst deskew (hoặc dùng để hiệu chỉnh), chấp nhận sync sai 1 bit có báo `ErrSotHS` | P1 |
| Bố trí PCB | lane cố định | ánh xạ lane lập trình được (lane swap) | P2 |
| Chẩn đoán dài hạn | bộ đếm 16 bit (F11) | bộ đếm 32 bit, đếm lỗi theo cửa sổ thời gian, log lỗi kèm timestamp | P2 |
| An toàn chức năng (IEC 61508, nếu cần SIL) | ECC/CRC header/payload có | tiêm lỗi bằng phần mềm để tự kiểm cơ chế an toàn (lật một bit header/CRC trong datapath), ECC cho RAM FIFO, parity thanh ghi cấu hình, timeout | P2 |
| Trigger, đồng bộ nhiều camera | `FRAME_TIME` tương đối | timestamp phần cứng ở FS/FE (timer SoC hoặc PTP), chốt cùng số frame | P1 |

## 5. SoC camera AI: yêu cầu và khoảng cách

| Yêu cầu | Hiện trạng | Việc cần làm | Ưu tiên |
|---------|------------|--------------|---------|
| Thông lượng | 2 lane × ~1 Gbit/s, 1 pixel/clock = 200 Mpx/s (1080p60 vừa, 4K30 = 249 Mpx/s không vừa) | 4 lane × 2,5 Gbit/s = 10 Gbit/s (RAW10 1 Gpx/s, RAW12 833 Mpx/s): 4 pixel/clock ở 250–300 MHz; tham số `Lanes` 1/2/4, `Ppc` 1/2/4; datapath packet 4–8 byte/chu kỳ | P0 |
| PHY | primitive UltraScale+ component mode, LP FSM và termination điều khiển trong controller | giao diện **PPI** cho D-PHY cứng (`RxByteClkHS`, `RxDataHS`, `RxValidHS`, `RxActiveHS`, `RxSyncHS`, `RxClkActiveHS`, `Stopstate`, `ErrSotHS`, `ErrSotSyncHS`, `RxUlpsEsc`, `RxSkewCalHS`). `bow_dphy_lp`/`bow_dphy_align`/`bow_dphy_io_xusp` thành một adapter "PPI cho FPGA"; trên FPGA tốc độ cao nên dùng bitslice native mode (clock không qua BUFG) thay cho component mode | P0 |
| Nhiều luồng | một VC/DT, packet khác bị bỏ | bộ định tuyến N bộ lọc (VC, DT) → N luồng: ISP, RAW thẳng vào bộ nhớ (AI trên ảnh RAW), embedded data (DT 0x12, metadata phơi sáng/gain của cảm biến), HDR DOL/staggered (mỗi phơi sáng một VC/DT), 4 camera qua deserializer (4 VC) | P0 |
| Định dạng | RAW8/RAW10 | RAW8–RAW16 (RAW20 nếu HDR), YUV422 8/10 bit, RGB888/565, user-defined 0x30–0x37 (ToF, depth), long packet chung (đi thẳng vào bộ nhớ) | P0 |
| Metadata | `FRAME_INFO`, `FRAME_SUM` trong thanh ghi | mỗi frame: số frame, timestamp FS/FE, số dòng, cờ lỗi, VC/DT; đi theo luồng (tuser mở rộng) hoặc luồng metadata riêng ghi cạnh buffer | P1 |
| Đường vào bộ nhớ | qua ISP; DMA Bow32 chỉ ghi VRAM | AXI4 master ghi frame vào DDR: stride, vòng buffer, descriptor kèm trạng thái frame (roadmap mức 4 "AXI4 master") | P1 |
| Độ trễ thấp | ngắt FS/FE | ngắt mỗi N dòng (xử lý theo slice), FE không phụ thuộc byte clock (F7) | P1 |
| Miền clock | lớp packet trên byte clock bị gate (F7) | chỉ aligner + ghép lane ở byte clock, qua FIFO 2 clock ngay sau đó; packet, router, unpack ở clock CSI chạy liên tục | P1 |
| Nguồn | không ULPS (LP-10 là lỗi LP) | nhận vào/ra ULPS không báo lỗi; gate clock video khi không có luồng | P2 |
| CSI-2 v2.x/v3 | v1.x | VCX (16 VC), RAW16/20; LRTE, scrambling, C-PHY khi cảm biến mục tiêu cần | P2 |
| Bảo mật | không | MIPI CSE (xác thực/toàn vẹn dữ liệu cảm biến) nếu sản phẩm cần (ô tô, an ninh) | P2 |
| Sign-off ASIC | lint Verilator, DV với mô hình | CDC/RDC (SpyGlass/Questa), cấu hình qua shadow register + bắt tay "apply" (F12), DFT: mux clock test cho miền byte, scan qua reset synchronizer, MBIST cho FIFO 256×44 và RAM LOG/RAW; formal cho FIFO 2 clock và req/ack gray; coverage chức năng | P1 |
| Tích hợp | bus Bow32 kiểu OBI | wrapper APB/AXI4-Lite, thanh ghi sinh từ mô tả (roadmap: kiểu `reggen`), IP-XACT | P1 |

## 6. Kiến trúc đề xuất cho bản tiếp theo

```
           byte clock (gated, theo PHY)                     clock CSI (chạy liên tục, 250–300 MHz)
 PPI ──► deskew / căn lane ──► ghép lane ──► FIFO 2 clock ──► giải packet (nhiều packet/burst,
 (PHY cứng          (FPGA: bow_dphy_*                         ECC + VCX, CRC, LS/LE, filler)
  hoặc adapter       thành adapter PPI)                                    │
  FPGA)                                                                    ▼
                                                     bộ định tuyến VC/DT (N bộ lọc) ──┬──► luồng 0: unpack RAW8–16/YUV,
                                                                                      │    1/2/4 pixel/clock ─► kiểm tra frame ─► ISP
                                                                                      ├──► luồng 1: RAW/long packet ─► DMA ─► DDR
                                                                                      └──► luồng 2: embedded data + metadata frame
 thanh ghi (giữ nguyên LOG, RAW, bộ đếm, FRAME_SUM, đo thời gian) + timestamp + ngắt FS/FE/dòng N/lỗi theo luồng
```

- "Kiểm tra frame" = kích thước so với cấu hình, CRC, số frame liên tục, timeout; gắn
  `tuser[1]` (dòng lỗi) và trạng thái frame; chính sách bỏ dòng/frame khi tràn hay lỗi.
- Tái dùng: `ecc_parity`, `crc16_byte`, logic header 3 tầng của `bow_csi2_packet`
  (mở rộng thành vòng lặp nhiều packet và 4–8 byte/chu kỳ), `bow_csi2_unpack` (thêm
  định dạng, nhiều pixel/clock), `bow_csi2_capture`, `bow_csi2rx_regs`, toàn bộ hạ
  tầng mô hình Python + testbench.
- Làm mới: adapter PPI, FIFO sau ghép lane, router, kiểm tra frame, metadata, AXI4
  master.

## 7. Lộ trình đề xuất

| Giai đoạn | Nội dung | Phát hiện xử lý | Khối lượng |
|-----------|----------|-----------------|------------|
| 0. Sửa nhanh | cờ + bộ đếm "byte sau packet vượt ngưỡng rác" (phát hiện nhiều packet/burst); giữ một chỗ trong FIFO cho nhóm `eol` và bỏ phần còn lại của dòng khi tràn; `tuser[1]` lỗi dòng; nhận và bỏ qua burst deskew; `SETTLE` theo `lane_rate` trong driver; xử lý `be`; sau hiệu chỉnh kiểm tra lề ở tâm ±k tap với thời gian đo dài | F1 (cờ), F2, F3, F4, F5, F6 (một phần), F9 | nhỏ: vài ngày, mỗi mục kèm case DV |
| 1. Công nghiệp (FPGA) | nhiều packet/burst + LS/LE; RAW12; bám eye tự động + hiệu chỉnh theo nhiệt; watchdog frame, kiểm tra kích thước, số frame; bộ đếm 32 bit; timestamp FS; kế hoạch thử nhiệt (mục 8) | F1, F6, F11 | trung bình: vài tuần |
| 2. SoC AI | adapter PPI + PHY cứng; 4 lane, 2/4 pixel/clock; lớp packet ở clock liên tục; router VC/DT + metadata; AXI4 master; cấu hình có bắt tay; sign-off CDC/DFT/MBIST; formal | F7, F8, F10, F12 | lớn: vài tháng |

## 8. Kiểm chứng bổ sung

- **DV** (thêm vào `csi2_model.py` / `csi2_tx_model.sv`): burst có nhiều packet (cần mô
  hình TX hỗ trợ); case tràn FIFO **có kiểm tra khung** thay cho `nocheck ovf`; `tready`
  ngẫu nhiên kéo dài với kiểm tra `tuser`/`tlast`; burst deskew; chuỗi escape/ULPS; VC
  xen kẽ; tốc độ lane ngoài 770–1050 Mbit/s đã kiểm (sau khi sửa F5 và phần xả pipeline
  cuối burst).
- **Formal**: `bow_fifo_async`, giao thức req/ack gray, thuộc tính của luồng ra (mỗi
  dòng accepted có đúng một `tlast`, `tuser` chỉ ở pixel 0 sau FS).
- **Coverage chức năng**: lớp syndrome ECC, WC mod 5, pha bit của aligner, độ lệch lane,
  vị trí cắt packet, trạng thái máy LP.
- **Board, mức công nghiệp**: bản đồ eye ở −40/+25/+85 °C và VCCINT ±3 %; soak BER
  (0 lỗi trong 3×10^12 bit ≈ 27 phút ở 2 × 912 Mbit/s cho BER < 10^-12, 95 %) ở nhiệt độ
  góc; 1 000 lần bật nguồn/bật stream; thay đổi chiều dài cáp/flex; ESD/EMC theo sản phẩm.
- **Tuân thủ**: đo T_D-TERM-EN, T_HS-SETTLE, T_CLK-SETTLE bằng máy phát D-PHY (hiện
  ~34 ns cho T_D-TERM-EN, sát giới hạn 35 ns + 4 UI); test protocol CSI-2 với máy phát
  pattern.

## 9. Những gì đã kiểm tra trong lần review này (2026-11-07)

- `make -C hw/ip/csi2rx/dv test` với Verilator 5.020: **30/30 PASS** (20 random, 10
  directed), 22 s.
- Bảng cột ECC so với phương trình parity của CSI-2 v1.x: khớp cả 24 cột. Kiểm tra vét
  cạn trên 30 bit (24 data + 6 parity): 0/435 lỗi 2 bit bị sửa sai; 3 780/4 060 lỗi 3 bit
  rơi vào syndrome "sửa được" (bản chất của mã, F8). Hai syndrome lẻ còn trống: `0x3D`,
  `0x3E`.
- Tái hiện F2 bằng một case DV tự tạo (tạo bằng `csi2_model.py`, không đưa vào repo):
  frame RAW10 60 × 20 pixel với `tready = 0`, rồi `tready = 1` và một frame thứ hai. Kết
  quả: 17 dòng đủ 60 pixel, dòng 18 dài **72 pixel** (12 pixel của frame 1 không có
  `tlast` + dòng đầu của frame 2) với `tuser` ở pixel 12; `FRAME_INFO` của frame 1 vẫn
  là 20 dòng. Lý do: `bow_csi2_unpack` đẩy nhóm cuối dòng (`eol`) vào FIFO đầy và nhóm
  đó bị bỏ như mọi nhóm khác.
- F1 xác nhận bằng đọc mã: sau `last`, `dst_q = Idle` tới `sop` kế tiếp, và `trunc` chỉ
  xét `dst_q != Idle`, nên byte của packet thứ hai không sinh sự kiện nào. Mô hình TX hiện
  tại chỉ gửi một packet mỗi burst nên chưa mô phỏng được.
