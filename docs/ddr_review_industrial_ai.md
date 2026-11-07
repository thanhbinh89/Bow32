# Review IP DDR2/DDR3 `bow_ddr` cho công nghiệp và SoC Camera AI

Tài liệu này đánh giá IP DDR2/DDR3 hiện tại (`bow_ddr` v2: controller LiteDRAM + PHY của
Bow32, [ip/ddr.md](ip/ddr.md)) theo hai mục tiêu mới, khác với mục tiêu ban đầu là học và
thử nghiệm:

1. **Công nghiệp**: chạy 24/7 nhiều năm, dải nhiệt rộng, dữ liệu không được hỏng âm thầm,
   lỗi phải được phát hiện và báo, chịu được nhiễu và trôi theo nhiệt độ / điện áp.
2. **SoC Camera AI**: bộ nhớ trung tâm cho camera → ISP → H.264 → NPU → CPU, nhiều luồng
   đồng thời, có luồng thời gian thực, và về sau đi lên ASIC.

Phạm vi: RTL `hw/ip/ddr/rtl`, bộ sinh LiteDRAM và lõi đã sinh, wrapper chân/clock
UltraScale+, firmware `sw/common/litedram`, testbench `hw/ip/ddr/dv`, các tài liệu
[ddr_mps4.md](ddr_mps4.md) và [ddr_board_review.md](ddr_board_review.md) (bo RAM). Đối chiếu
với mã nguồn LiteDRAM đúng commit được ghim (`f2d2297`). Bản review ở commit `e21b93a`.

## 1. Kết luận

IP hiện tại là một nền **học và bring-up rất tốt**: controller đã được kiểm chứng rộng rãi
(LiteDRAM), sinh lại giống từng byte, kỷ luật CDC/reset chặt, khả năng quan sát hiếm thấy
(chụp thô DQ/DQS, quét mắt, DRAM giả lập có kiểm tra JEDEC), kiểm thử lỗi có chủ đích. Tuy
vậy, **nó chưa đáp ứng được mục tiêu công nghiệp hay camera AI**. Có hai nhóm khoảng cách
chặn:

| Mục tiêu | Hiện trạng | Cần | Khoảng cách |
|----------|------------|-----|-------------|
| Băng thông hữu ích cho các master (CPU/DMA/ISP/NPU) | **5,0 / 3,6 MB/s** đọc/ghi qua cửa sổ (đo trên MPS4) | ≈ 0,7–1,1 GB/s cho 1080p30 + H.264 frame P + NPU nhỏ (mục 3.2) | **~200×** |
| Băng thông đỉnh của DRAM | 266,7 MB/s (DDR2-266 x8); BIST đo 234 / 227 MB/s | ≈ 1–2 GB/s đỉnh (hiệu suất 60–70 % khi trộn nhiều luồng) | **4–8×** |
| Dải nhiệt | refresh cố định 7,8 µs (Tc ≤ 85 °C) | Tc tới 95 °C → tREFI 3,9 µs | **chặn** |
| Toàn vẹn dữ liệu | không ECC, không phát hiện lỗi bit | SECDED + đếm lỗi + scrub | **chặn** (công nghiệp / an toàn chức năng) |
| Trôi theo nhiệt / áp | hiệu chỉnh một lần lúc khởi động | bám pha khi đang chạy, đo biên | cao |
| Giờ chạy trên DRAM thật | 0 (bo RAM chưa có; trên bo chỉ có DRAM giả lập; DDR3 chỉ mô phỏng) | đặc tính hoá trong buồng nhiệt, soak test | cao |
| Đi lên ASIC | PHY gắn với FPGA (ODDR/IDDR + MMCM), DFI không chuẩn | PHY cứng DFI 3.1/4.0 | chặn (cho ASIC) |

Hướng đi đề xuất (chi tiết ở mục 5–6): giữ **controller LiteDRAM và giao diện DFI** làm
trục; thay **lớp trên** (cửa sổ 32 bit) bằng một memory subsystem nhiều cổng burst có QoS;
thay **lớp dưới** bằng DDR3/DDR3L x16 nối thẳng với PHY SERDES (`USPDDRPHY` của LiteDRAM)
trên FPGA và PHY cứng trên ASIC; thêm các tính năng độ tin cậy (refresh theo nhiệt, ECC,
giám sát refresh, bám pha, khoá cấu hình).

### Kiểm chứng lại trước khi review

`make -C hw/ip/ddr/dv test` với Verilator 5.020 (bản CI dùng), seed 1, tại commit
`e21b93a`:

| Cấu hình | Kết quả |
|----------|---------|
| `lb` (bản loopback MPS4, DRAM giả lập) | PASS |
| `card` (DDR2 x8 qua TXV0108) | PASS |
| `ddr3` (x16 DLL-off, DM, RESET#) | PASS |
| `stub` (`DdrEn = 0`) | PASS |
| `rst` (reset / CDC) | PASS |

## 2. Điểm mạnh nên giữ

* **Controller tái sử dụng qua DFI**: bank machine, refresh, lập lịch, DFII, BIST của
  LiteDRAM; phiên bản ghim, `make litedram-check` đảm bảo lõi trong repo đúng là lõi sinh từ
  cấu hình. Đây là đúng chỗ để tách: controller giữ, PHY và frontend thay được.
* **Kiểm tra lúc elaboration** (`bow_ddr.sv`): lõi không khớp PHY, CK quá chậm cho tREFI,
  CK nhanh hơn lõi 1 % đều dừng lint/tổng hợp. Cách làm này nên mở rộng cho mọi tham số
  độ tin cậy mới (nhiệt độ, ECC).
* **Cô lập lỗi**: timeout → `BROKEN`, không bao giờ nhận nhầm câu trả lời muộn; `RD_LATE` /
  `RD_EXTRA` / `RFIFO_ERR`; `ERR_ADDR`; ngắt. Đúng tinh thần "lỗi phải lộ ra".
* **Ngữ nghĩa reset và pha MMCM** được nghĩ kỹ: bộ đếm pha giữ qua reset SoC, MMCM mất khoá
  thì reset cả ba, lõi reset chậm hơn cầu không làm ghi 0 vào DRAM.
* **Mô hình DRAM tổng hợp được** (`bow_ddr_dev`) dùng cả trong mô phỏng và trong FPGA: mọi
  vi phạm JEDEC của controller lộ ra ở `DBG`.
* **Kiểm thử**: 4 cấu hình + bộ reset/CDC, chạy đúng luồng firmware bằng thanh ghi, so với
  mô hình tham chiếu, chèn lỗi (timeout, mất clock), và đã chạy trên bo (18/18, `verify`
  30/30 so với mô hình Python trên PC).

## 3. Yêu cầu tham chiếu

### 3.1 Công nghiệp

| Yêu cầu | Ý nghĩa với DDR |
|---------|-----------------|
| Dải nhiệt: môi trường −40…+85 °C, vỏ DRAM (Tc) thường tới 95 °C | JESD79-2/-3: Tc > 85 °C cần refresh gấp đôi (tREFI 3,9 µs); chip loại công nghiệp / automotive; tpd của level shifter và độ trễ đường mạch trôi theo nhiệt |
| Chạy liên tục, tuổi thọ dài | không hỏng âm thầm: ECC, scrub, đếm lỗi; theo dõi biên timing; nguồn linh kiện dài hạn |
| Nhiễu điện từ (IEC 61000-4-x) | chuẩn I/O có termination, VREF, ODT; trở kháng có kiểm soát |
| An toàn chức năng (IEC 61508; ISO 26262 nếu camera ô tô) | chẩn đoán RAM (ECC, March test), giám sát refresh, khoá cấu hình, chèn lỗi để đo độ phủ chẩn đoán, FMEDA |
| Khả năng phục hồi | lỗi được báo bằng ngắt, phục hồi không cần tắt nguồn, có watchdog |

### 3.2 Camera AI: ngân sách băng thông và dung lượng

Giả định: cảm biến 1080p30, ISP ra NV12 (YUV 4:2:0, 8 bit: 3,11 MB/frame), H.264 có frame P
(mục "H.264 nâng cao" của [roadmap.md](roadmap.md)), một mạng phát hiện cỡ YOLO-nano INT8 với
đầu vào 640×640 ở 15 fps.

| Luồng | MB/s |
|-------|-----:|
| ISP → DDR (ghi NV12) | 93 |
| H.264: đọc frame hiện tại | 93 |
| H.264: đọc tham chiếu (cửa sổ tìm kiếm, ≈ 1,5×) | 140 |
| H.264: ghi frame tái tạo | 93 |
| Bitstream (4–8 Mbit/s) | 1 |
| Tiền xử lý AI: đọc nguồn ở 15 fps / ghi tensor 640×640×3 | 47 + 18 |
| NPU: đọc tensor | 18 |
| NPU: weights (3–7 MB mỗi frame, không cache trên chip) | 45–105 |
| NPU: feature map tràn ra DDR | 100–300 |
| CPU / hệ điều hành / mạng / OSD | 50–150 |
| **Tổng** | **≈ 700–1 060** |

Với nhiều luồng trộn lẫn, hiệu suất DRAM thực tế khoảng 60–70 % → cần đỉnh ≈ 1,0–1,8 GB/s:
DDR3-800 x16 (1,6 GB/s) là mức tối thiểu, **DDR3/DDR3L-1600 x16 (3,2 GB/s)** cho dư gấp đôi,
LPDDR4/4X x16 (≥ 6,4 GB/s) cho 4K hoặc NPU > 2 TOPS. Riêng 720p30 NV12 là 41,5 MB/s mỗi luồng.

Dung lượng (1080p): vòng 3 frame ISP 9,3 MB, tham chiếu + tái tạo 6,2 MB, tensor AI 2,5 MB,
model + vùng nhớ tạm của NPU 5–20 MB, vòng bitstream 4–8 MB → **≈ 30–55 MB với RTOS**, thêm
≥ 32–64 MB nếu chạy Linux. 64 MiB của bo DDR2 đủ cho RTOS nhưng sát nút; camera AI chạy
Linux nên có **256–512 MiB** (2–4 Gb x16).

Ngoài băng thông, camera AI còn cần: luồng **thời gian thực** (ISP không có back-pressure
bên trong, mất chỗ ghi = hỏng frame) cùng tồn tại với luồng **khối lớn** (NPU, CPU); truy
cập **2D theo tile** (macroblock 16×16, cửa sổ tìm kiếm) chứ không chỉ tuần tự; và bảo vệ
dữ liệu hình ảnh / model (dữ liệu cá nhân theo Nghị định 13/2023/NĐ-CP, sở hữu trí tuệ của
model).

## 4. Phát hiện

Mức: **chặn** = không đạt mục tiêu nếu không sửa; **cao** = rủi ro lớn hoặc thiếu tính
năng chính; **trung bình** = chạy được nhưng biên thấp / mất hiệu năng; **thấp** = nên làm.

### A. Băng thông và kiến trúc hệ thống (camera AI)

| # | Mức | Phát hiện | Đề xuất |
|---|-----|-----------|---------|
| A1 | chặn | **Mọi master đi qua một cửa sổ 32 bit, một giao dịch mỗi lần, bắt tay 4 pha qua miền clock**: `bow_ddr_win.sv:140-141` chỉ phát yêu cầu mới khi `ack` của lần trước đã về 0; mỗi word = hai lượt đồng bộ mỗi chiều + độ trễ đọc cố định 12 chu kỳ controller (360 ns). Đo trên bo: 5,0 / 3,6 MB/s, ≈ 2 % đỉnh DRAM. DMA (`bow_dma`, một giao dịch mỗi lần) cũng phải đi qua đây. | Memory subsystem nhiều cổng (mục 5): dùng thêm cổng native của crossbar LiteDRAM, mỗi cổng có frontend burst (`LiteDRAMAXI2Native` cho NPU/CPU, `LiteDRAMDMAWriter/Reader` cho ISP/H.264, có sẵn trong LiteDRAM), qua `LiteDRAMNativePortCDC` (FIFO bất đồng bộ) thay cho bắt tay 4 pha; ghi kiểu posted (báo lỗi ghi bằng ngắt + `ERR_ADDR`); CPU qua cache line = 1 burst. |
| A2 | chặn | **Đỉnh DRAM 266,7 MB/s**: x8 DDR2-266; PHY `ODDRE1`/`IDDRE1` + MMCM và level shifter TXV0108 giới hạn CK ≈ 125–133 MHz; controller chạy ở CK/4 = 33 MHz với cổng 64 bit. | Bo rev-B: **DDR3/DDR3L x16 nối thẳng** (đã đề xuất ở [ddr_board_review.md](ddr_board_review.md) mục 7), PHY SERDES (`USPDDRPHY` của LiteDRAM: `OSERDESE3`/`ISERDESE3`, `IDELAYE3` từng bit, write leveling) ở 800–1600 MT/s; controller 100–200 MHz, cổng native 128–256 bit. |
| A3 | cao | **Không có QoS**: crossbar LiteDRAM là round-robin theo từng bank (`litedram/core/crossbar.py`, cây `crossbar.roundrobin_*` trong `litedram_ddr2.v:199-203`), không ưu tiên, không giới hạn băng thông. Khi NPU/CPU chiếm bus, cổng ISP (không back-pressure) có thể tràn. | Arbiter trước controller: ưu tiên/khẩn cấp theo mức FIFO cho cổng thời gian thực (ISP ghi, display đọc), bộ điều tiết băng thông (token bucket) cho NPU/CPU; FIFO mỗi cổng thời gian thực ≥ độ trễ xấu nhất × băng thông (ví dụ 20 µs × 93 MB/s ≈ 2 KB, gồm refresh và các khoảng bảo trì). |
| A4 | cao | **Ánh xạ địa chỉ chỉ ROW_BANK_COL** (commit LiteDRAM được ghim chỉ có kiểu này), trang DRAM 1 KiB (x8) / 2 KiB (x16). Frame 1920 byte/dòng: mỗi dòng của một macroblock 16×16 rơi vào hàng DRAM khác → ACT/PRE gần như mỗi 16 byte khi H.264 đọc tham chiếu. | Bố trí frame dạng **tile** căn theo trang DRAM (ví dụ tile 64×16 luma = 1 KiB), XOR bit bank với bit hàng thấp ở frontend của Bow32 (không cần sửa LiteDRAM) để các luồng đồng thời rải đều bank. |
| A5 | trung bình | **Không DM trên bo rev-A** (`ddr2.yml:16`): mọi ghi nhỏ hơn 8 byte là đọc-sửa-ghi (2 lần truy cập). RMW chỉ nguyên tử khi cửa sổ là người dùng duy nhất (`bow_ddr_win.sv:43-46`): khi có nhiều master, hai master ghi chung một burst sẽ hỏng dữ liệu. | DM trên rev-B (đã nêu ở review bo, mục 4 #3); bộ gom ghi (write-combining) đủ burst trước controller cho luồng tuần tự; nếu còn RMW trong hệ nhiều master thì khoá theo địa chỉ burst ở arbiter. |
| A6 | trung bình | Dung lượng 64 MiB (DDR2), 128 MiB (DDR3, chỉ mô phỏng); cửa sổ giải mã 512 MiB. | 2–4 Gb x16 (256–512 MiB) cho camera AI chạy Linux (mục 3.2). |
| A7 | trung bình | **Chưa có nền tảng nào có cả camera lẫn DDR của IP**: DDR chỉ ở MPS4 (`DdrEn = 1`), camera chỉ ở KV260 (`DdrEn = 0`, stub, `bow32_kv260_cam_top.sv:159`); luồng camera → ISP → H.264 → DMA → VRAM 1 MiB không qua DDR. | Bước đầu làm được ngay với IP hiện tại: DMA ghi bitstream H.264 vào DDR (1080p30 intra ≈ 1 MB/s, 720p ≈ 0,7 MB/s, dưới 3,6 MB/s của cửa sổ) để ghi hình dài hơn VRAM; cần một nền tảng có cả hai. Trong lúc chờ bo DDR3, phần camera AI trên KV260 đi qua AXI HP tới DDR4 của PS (mục "AXI4 master" của roadmap). |
| A8 | thấp | CPU không cache: mỗi lần đọc ≥ 360 ns + CDC, không chạy mã từ DDR được (đã có trong roadmap). | Cache line 64 B (8 burst x8 / 4 burst x16), khớp với kích thước khối của ECC inline (B2). |

### B. Độ tin cậy công nghiệp

| # | Mức | Phát hiện | Đề xuất |
|---|-----|-----------|---------|
| B1 | chặn | **Refresh cố định ở 7,8 µs** (Tc ≤ 85 °C): `TREFI_NS = 7800.0` (`bow_ddr_litedram_gen.py:66`), kiểm tra cứng 7800 ns (`bow_ddr.sv:131`), lõi sinh ra bộ đếm hằng `9'd258` (`litedram_ddr2.v:1509`), không có núm lúc chạy. Ở Tc 85–95 °C phải là 3,9 µs: chạy 7,8 µs là ngoài datasheet, rủi ro mất dữ liệu do retention. | Thêm `trefi_ns` vào `ddr2.yml`/`ddr3.yml`, bản công nghiệp đặt **3900** (chi phí refresh tăng từ ≈ 2 % lên ≈ 4 %: tRFC 105 ns làm tròn lên 4 chu kỳ controller); tham số hoá `g_bad_refi` và `REF_STARVE` của mô hình DRAM theo cùng giá trị. Lưu ý LiteDRAM từ chối tREFI < 100 chu kỳ controller (`litedram/core/refresher.py:234`): 3,9 µs @ 33,33 MHz = 130 chu kỳ thì được, 1,95 µs (một số chip tới 105 °C) = 65 chu kỳ thì cần clock controller cao hơn. Khi thêm self-refresh: DDR2 EMRS(2) A7 (SRF), DDR3 MR2 ASR/SRT. Chọn chip mã nhiệt độ công nghiệp / automotive. |
| B2 | chặn | **Không có ECC**, không phát hiện lỗi bit. ECC của LiteDRAM (`LiteDRAMNativePortECC`) là **side-band**: mã hoá từng beat vào cổng DRAM rộng hơn (`litedram/frontend/ecc.py:113`), cần thêm làn DQ cho bit kiểm tra → không dùng được với một chip x8 hay x16. | (a) Rev-B có làn ECC (ví dụ x16 dữ liệu + x8 ECC) → dùng ECC của LiteDRAM. (b) Không thêm chip: **ECC inline** tự làm ở frontend của Bow32: SECDED (72,64), mỗi word native x8 (một burst, 64 bit) đúng một từ mã; 8 word = 64 B dữ liệu ↔ 1 word ECC; vùng ECC = 1/8 dung lượng, cache ECC nhỏ; ghi một phần buộc RMW (khớp với bo không DM). Cả hai: đếm lỗi sửa được / không sửa được, địa chỉ lỗi, ngắt, lỗi không sửa được → lỗi bus (poison), scrub định kỳ, chèn lỗi bằng thanh ghi để kiểm thử chẩn đoán. |
| B3 | cao | **Hiệu chỉnh chỉ một lần lúc khởi động**, không theo dõi trôi. Đường đọc đi qua hai lần TXV0108 và được lấy mẫu bằng clock MMCM (không dùng DQS), nên tpd trôi theo nhiệt đi thẳng vào biên. Hiệu chỉnh lại khi đang chạy (`bow_ld_eye`, `bow_litedram.c:646`) phải chặn cửa sổ và vào DFII, nơi không có refresh (`bow_litedram.c:184`): không dùng được khi camera đang ghi. `APPLY` cần PHY rảnh trong 4096 CK, có thể thất bại khi tải liên tục. | **Bám pha nền** bằng phần cứng sẵn có: MMCM dịch pha không glitch khi đang chạy, và trong dải pha có cùng p (giữa mắt) `RD_DLY`/`RD_SLIP` không đổi, nên bước `PS_GO` nhỏ được khi có traffic. Dành riêng một ô DRAM chứa mẫu P; định kỳ (hoặc khi SYSMON báo nhiệt độ đổi quá ΔT) dò biên ở tâm ± Δ trong một khoảng ngắn độc quyền (ví dụ V-blank), dời tâm nếu biên lệch; tương tự với một BIST nhỏ cho pha ghi. Cần thêm: chụp thô chỉ cho RD tới ô mẫu (lọc theo địa chỉ, không phải "RD kế tiếp"), và cửa sổ cập nhật do controller cấp (như `dfi_ctrlupd`, C2). Xuất độ rộng mắt và biên (telemetry) có ngưỡng cảnh báo. Lâu dài: deskew từng bit (`IDELAYE3`), PHY có DQS gating. |
| B4 | cao | **Chưa có giờ chạy trên DRAM thật**: bo RAM chưa sản xuất, bản chạy trên bo dùng DRAM giả lập trong FPGA qua loopback chân; DDR3 chưa có phần cứng. Mô hình bo rút trễ một lần mỗi seed (không trôi theo thời gian). | Kế hoạch đặc tính hoá khi có bo: buồng nhiệt −40 / 25 / 85 (95) °C, nguồn ±5 %, soak ≥ 72 h (memtest + BIST + `verify`), ghi độ rộng mắt đọc/ghi theo nhiệt độ, đo duty cycle CK và tDQSS tại chân DRAM (review bo #5, #6b). Tiêu chí: 0 lỗi, biên còn lại ≥ 25 % chu kỳ ở mọi góc. |
| B5 | cao | **Tín hiệu kém cho môi trường nhiễu**: `LVCMOS15`, `DRIVE 8`, `SLEW FAST` qua TXV0108, không termination, không VREF/ODT phía FPGA (`ddr_card.xdc:62-66`). | Rev-B DDR3/DDR3L nối thẳng: `SSTL15`/`SSTL135` + ODT + VREF + điện trở đầu cuối cho lệnh/địa chỉ, trở kháng có kiểm soát, mô phỏng SI bằng IBIS trước khi đặt mạch. |
| B6 | trung bình | **Không có giám sát refresh trên phần cứng thật**: `REF_STARVE` chỉ có trong mô hình / DRAM giả lập (`bow_ddr_dev.sv:245`), trong khi firmware có các đoạn DFII không refresh, `CORE_RST` dừng refresh, và một phần mềm lỗi có thể để DFII ở chế độ phần mềm. | Trong `bow_ddr_dfi` (đã đếm REF cho `ST_REF`): đếm thời gian từ REF cuối tới PHY, quá 8 × tREFI → `STATUS.REF_STARVE` + ngắt; tuỳ chọn watchdog phần cứng tự trả DFII về chế độ phần cứng / nhả `CORE_RST` sau thời hạn. |
| B7 | trung bình | **Cấu hình không được khoá**: `CTRL`/`LAT`/pha ghi được bất cứ lúc nào, `CORE_RST` tác dụng ngay; một lần ghi nhầm làm hỏng toàn bộ bộ nhớ. | Bit `LOCK` (chỉ reset mới xoá) sau khi bàn giao; chỉ M-mode truy cập được slot (PMP); kiểm tra định kỳ CRC của cấu hình đã áp dụng. |
| B8 | trung bình | Không self-refresh / power-down (LiteDRAM không tự làm); MMCM mất khoá → reset cả SoC, DRAM mất nội dung. | Self-refresh qua DFII + CKE cho chế độ ngủ của camera chạy pin; với công nghiệp: ghi nguyên nhân reset và trạng thái DDR trước reset để phân tích sự cố. |
| B9 | thấp | Kiểm tra lúc khởi động có walking 1/0, địa chỉ, PRBS (tốt) nhưng không có kiểu March; IEC 61508 khuyến nghị March cho lỗi coupling. | Thêm March C- vào `memtest`, chạy lúc khởi động và định kỳ trên vùng dành riêng. |
| B10 | thấp | Nguồn linh kiện: DDR2 ngày càng ít nhà cung cấp. | Chọn DDR3/DDR3L từ nhà cung cấp có chương trình vòng đời dài; xác nhận dải nhiệt và tpd(T) của level shifter nếu còn dùng. |

### C. Đi lên SoC (ASIC)

| # | Mức | Phát hiện | Đề xuất |
|---|-----|-----------|---------|
| C1 | chặn | **PHY gắn với FPGA**: `ODDRE1`/`IDDRE1`, IOB, MMCM dịch pha động; ASIC không có tương đương (cần DLL / dây trễ số, I/O SSTL có ZQ, training phần cứng). | PHY cứng DDR3/DDR3L/LPDDR4 có DFI 3.1/4.0 từ foundry hoặc nhà cung cấp IP; giữ PHY Bow32 cho FPGA và giảng dạy. |
| C2 | cao | **DFI không chuẩn** (`bow_ddr_dfi.sv:36-44`): trễ đọc cố định 12 chu kỳ, bỏ qua `rddata_valid`, `write_latency` 0, không có `tphy_wrlat` / `trddata_en` lập trình được, không `dfi_init_start/complete`, `dfi_ctrlupd_*` / `dfi_phyupd_*` (cách PHY chuẩn tự bù trôi VT), `dfi_lp_*`. LiteDRAM cũng không có ctrlupd/phyupd. | Lớp DFI 3.1 chuẩn: nhận dữ liệu đọc theo `rddata_valid` (FIFO trả về có hạn chót của `bow_ddr_dfi` là điểm khởi đầu tốt), lập lịch cửa sổ ctrlupd giữa các refresh, bắt tay init/phyupd. Cùng cơ chế này phục vụ luôn B3 trên FPGA. |
| C3 | trung bình | Lõi LiteDRAM sinh ra dùng giá trị khởi tạo `reg x = ...` (818 thanh ghi) và `int_rst = 1'd1` cho reset nội bộ; FPGA dựa vào cấu hình, ASIC bỏ qua giá trị khởi tạo. FIFO là mảng `reg`. | Chứng minh mọi thanh ghi trạng thái nằm trong khối `sys_rst` (mô phỏng 4 trạng thái / X-prop, lint reset); FIFO → macro SRAM hoặc flop; DFT (scan) qua các miền clock; CDC sign-off (kỷ luật hiện tại là nền tốt). |
| C4 | trung bình | LiteDRAM thiếu ECC inline, QoS, DFI chuẩn và tài liệu an toàn chức năng. | Với ASIC công nghiệp: so sánh chi phí bổ sung các phần trên + chương trình kiểm chứng tương xứng với controller thương mại đã có silicon; quyết định trước khi đặt PHY. |

### D. Kiểm chứng

| # | Mức | Phát hiện | Đề xuất |
|---|-----|-----------|---------|
| D1 | cao | Không mô phỏng được trôi: `ddr_board_model` rút trễ một lần mỗi seed. | Trễ level shifter / đường mạch trôi chậm theo "nhiệt độ" trong lúc chạy; kiểm tra rằng bám pha (B3) giữ 0 lỗi và báo động trước khi mất mắt. |
| D2 | trung bình | CI chạy seed 1; có target `seeds` nhưng không có hồi quy nhiều seed; chưa có coverage. | Hồi quy đêm 50–100 seed mỗi cấu hình; `verilator --coverage`; covergroup cho chuỗi lệnh và các khoảng JEDEC sát biên. |
| D3 | trung bình | Chưa có formal cho bắt tay 4 pha của hai cầu, FIFO bất đồng bộ, bộ bước pha. | SymbiYosys cho các khối nhỏ này (roadmap đã có cho FIFO). |
| D4 | thấp | Chèn lỗi đã tốt (timeout, `CORE_RST`, mất clock). | Thêm: lật bit (khi có ECC), refresh starvation trên phần cứng (B6), mất khoá MMCM khi đang tải, nhiều master ghi cùng burst (A5). |

## 5. Kiến trúc đề xuất

```
                       miền SoC / master                      miền controller (100–200 MHz)
 ISP ghi (thời gian thực) ─ DMA writer ─ FIFO ≥2 KB ─┐
 display / H.264 đọc ─────── DMA reader ─ FIFO ─────┤   arbiter QoS        ┌─ ECC inline (B2, nếu không có làn ECC)
 H.264 tham chiếu (tile) ─── AXI4 128b ─────────────┼─► (ưu tiên + điều  ──┼─ XOR bank / tile (A4)
 NPU ─────────────────────── AXI4 128–256b ─────────┤    tiết băng thông)  └─► cổng native LiteDRAM (CDC FIFO)
 CPU ─ cache line 64 B ───── AXI4 / native ─────────┘                              │
                                                                       controller LiteDRAM (refresh 3,9 µs, DFII, BIST)
 thanh ghi: LOCK, REF_STARVE, đếm ECC, telemetry mắt                               │ DFI 1:4
                                                                       FPGA: USPDDRPHY (DDR3/DDR3L x16, 800–1600 MT/s)
                                                                       ASIC: PHY cứng DFI 3.1/4.0 (DDR3L / LPDDR4)
```

* Controller và DFI giữ nguyên vai trò; mọi thứ mới nằm ở frontend (trên) hoặc PHY (dưới).
* Cửa sổ 32 bit hiện tại vẫn giữ cho debug và firmware, như một cổng có ưu tiên thấp.
* Bộ máy hiệu chỉnh phần mềm, chụp thô và DRAM giả lập vẫn dùng được cho bring-up bo mới.

## 6. Lộ trình

| Giai đoạn | Nội dung | Tiêu chí hoàn thành |
|-----------|----------|---------------------|
| **P0** (trên IP hiện tại) | B1 `trefi_ns` + bản 3,9 µs; B6 giám sát refresh phần cứng; B7 `LOCK`; D2 hồi quy nhiều seed; A7 DMA ghi bitstream H.264 vào DDR; telemetry độ rộng mắt | test IP PASS với cả 7,8 và 3,9 µs; `REF_STARVE` bắt được trong test chèn lỗi; 100 seed × 4 cấu hình PASS |
| **P1** (bo rev-B, băng thông) | DDR3/DDR3L x16 nối thẳng + `USPDDRPHY`; nhiều cổng native + CDC FIFO + frontend AXI/DMA; arbiter QoS; posted write; bố trí tile + XOR bank | BIST ≥ 1,2 GB/s ở DDR3-800 trở lên; 3 luồng đồng thời (ISP 93 MB/s + H.264 + tải nền) không tràn FIFO thời gian thực trong 24 h |
| **P2** (công nghiệp) | ECC (side-band hoặc inline) + scrub + đếm lỗi + chèn lỗi; bám pha nền (B3, D1); March test; đặc tính hoá trong buồng nhiệt (B4); FMEDA | 0 lỗi không sửa được trong soak 72 h ở −40 / 85 (95) °C; mọi lỗi 1 bit chèn vào được sửa và đếm; biên ≥ 25 % chu kỳ ở mọi góc |
| **P3** (ASIC SoC) | Chọn PHY cứng (và controller), lớp DFI 3.1/4.0, X-prop, DFT; cân nhắc LPDDR4/4X | lõi qua lint reset và X-prop; mô phỏng với mô hình PHY của nhà cung cấp |

## 7. Ghi chú về số liệu

* Băng thông hiện tại lấy từ [ddr_mps4.md](ddr_mps4.md) mục 4.6 (MPS4, 2026-11-05).
* Đỉnh DRAM = CK × 2 × độ rộng: DDR2-266 x8 = 266,7 MB/s; DDR3-1600 x16 = 3,2 GB/s.
* Chi phí refresh ≈ (tRFC + tRP làm tròn lên chu kỳ controller) / tREFI: (120 + 30) ns /
  7,8 µs ≈ 1,9 %, / 3,9 µs ≈ 3,8 % (DDR2 512 Mb ở 33,33 MHz).
* Ngân sách camera AI (mục 3.2) là ước lượng bậc độ lớn cho một thiết kế điển hình; con số
  NPU phụ thuộc mạnh vào SRAM trên chip và khả năng gộp lớp của NPU.
