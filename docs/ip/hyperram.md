# Bộ điều khiển HyperRAM (`bow_hyperram`)

IP HyperBus master của Bow32 cho bộ nhớ **HyperRAM 2.0 x8** (Infineon S80KS2562: 256 Mb =
32 MiB, 1,8 V, 200 MHz). Mục tiêu là chip HyperRAM trên bo RAM mở rộng
`docs/fpga/ram_extension/FMC_DDR2_HyperRam.PDF` (đi qua level shifter TI TXV0108) cắm trên
Arm MPS4; bản build mặc định của MPS4 chạy với một HyperRAM giả lập trong FPGA, qua chân
thật của FPGA (loopback). Đã chạy trên chip thật qua bo RAM ngày 2026-11-09 (self-test 19/19,
toàn 32 MiB 0 lỗi, BIST 184 MB/s): [../hyperram_mps4.md](../hyperram_mps4.md) mục 5.

Chuẩn tuân theo:

* **HyperBus**: định dạng lệnh/địa chỉ 48 bit, đếm latency, ba vai trò của RWDS (báo latency,
  strobe đọc, mặt nạ ghi), burst tuyến tính / wrapped / hybrid, không gian thanh ghi big endian,
  theo datasheet S80KS2562 (Infineon 002-31337 Rev *C) và đặc tả HyperBus của Infineon.
* **Mọi thông số thời gian của thiết bị** là thanh ghi (tCSM, tRWR/tCSHI, tRP/tRH/tVCS,
  tCSDPD/tEXTDPD, latency) với giá trị reset tính từ tần số CK, không hằng số ẩn trong RTL.
* **Giao diện**: cửa sổ bộ nhớ trên bus chính (đọc/ghi byte, halfword, word, thực thi lệnh
  được), một slot thanh ghi trên bus ngoại vi, một ngắt nhanh; mọi CDC dùng FIFO bất đồng bộ
  mã Gray hoặc bắt tay bốn pha, ràng buộc và kiểm tra trong build FPGA.

| Thư mục / file | Nội dung |
|----------------|----------|
| `hw/ip/hyperram/rtl/` | RTL: top, cửa sổ bus, thanh ghi, controller, BIST, PHY, emulator, stub, package |
| `hw/ip/hyperram/dv/` | mô hình S80KS2562 mức chân, mô hình bo (TXV0108), mô hình clock, pad twin, testbench IP |
| `hw/fpga/common/rtl/bow_hyperram_{io_xilinx,clk_xusp}.sv` | chân và clock cho UltraScale+ |
| `sw/common/include/bow_hyperram.h`, `sw/common/src/bow_hyperram.c` | driver: lệnh, thanh ghi thiết bị, hiệu chỉnh, BIST, nguồn |
| `sw/apps/hyperram`, `tools/bow32_hyperram.py` | ứng dụng thử nghiệm (shell UART) và công cụ trên PC |

Chạy trên MPS4: [../hyperram_mps4.md](../hyperram_mps4.md). Bo RAM và lý do chọn MPS4:
[../ddr_board_review.md](../ddr_board_review.md).

| Thông số | Giá trị |
|----------|---------|
| Thiết bị | HyperRAM 2.0 x8, một CS# (S80KS2562: ID0 0x0E86, ID1 0x0001), CK đơn (CK# = bù) |
| Tốc độ | CK 100 MHz trên MPS4 (VCO 1200 MHz / 12), DDR: 200 MB/s đỉnh trên HyperBus |
| Latency | 3..7 xung (CR0[7:4]), cố định 2× (mặc định, bắt buộc trên bo RAM) hoặc biến đổi (RWDS) |
| Burst | tuyến tính và wrapped 32 byte (line fill, word cần trước), BIST tuyến tính tới 255 word |
| Cửa sổ | `0x6000_0000`, giải mã 256 MiB, dung lượng thật 32 MiB, ngoài vùng → lỗi bus |
| Đệm | read buffer 4 line × 32 byte; write buffer gộp ghi (posted) 1 khối 32 byte |
| Thanh ghi | `0x4000_F000` (4 KiB) |
| Ngắt | `irq_fast[12]` (lệnh xong, chụp thô xong, BIST xong, lỗi) |
| Hiệu chỉnh | phần mềm: quét pha đọc với chụp thô (ID0 rồi mẫu bộ nhớ), `RD_DLY`; quét pha ghi (bo RAM) |
| Nguồn | RESET#, deep power down, hybrid sleep, WAKE (xung CS#) |
| Khi không có HyperRAM | `HrEn = 0`: stub, cửa sổ trả lỗi bus, `INFO[3] = 0` |

```
 clk_i (SoC 50 MHz)                               hr_clk (CK)                         chân
 main xbar ─cửa sổ─> bow_hyperram_win ══FIFO lệnh══> bow_hyperram_ctrl ──ý định chân──> bow_hyperram_phy ─> pad wrapper
                     (read/write buffer) <══FIFO trả lời══  (bộ thực thi lệnh,           (thanh ghi chân,
 periph ─0x4000_F000─> bow_hyperram_regs ══bắt tay 4 pha══>  phân xử, engine, BIST,       FIFO đọc <── hr_rd_clk ── IDDR
                                                             CR0/CR1, bước pha)           bộ căn theo RWDS, chụp thô)
 board: MMCM_H (hr_clk 270°, hr_wclk: dịch pha ghi) + MMCM_R (hr_rd_clk: dịch pha đọc)
```

## 1. Giao thức HyperBus (những gì IP dựa vào)

Các điểm sau được đối chiếu với hình 30, 31, 33 của datasheet (đã đo trên bản PDF):

* Đánh số chu kỳ CK k = 1, 2, … từ cạnh lên đầu tiên sau khi CS# xuống; r_k / f_k là cạnh
  lên / xuống. **CA** ở chu kỳ 1..3: CA[47:40] tại r1, [39:32] f1, [31:24] r2, [23:16] f2,
  [15:8] r3, [7:0] f3 (dữ liệu từ host căn giữa cạnh CK).
* CA: [47] R/W# (1 = đọc), [46] không gian thanh ghi, [45] burst tuyến tính, [44:16] địa chỉ
  word [31:3], [15:3] = 0, [2:0] địa chỉ word [2:0]. Thanh ghi: ID0/ID1 ở word 0/1, CR0/CR1 ở
  word 0x800/0x801 (CA[31:24] = 01). Ghi thanh ghi phải tuyến tính (CA[45] = 1).
* **Latency đếm từ f2**: word dữ liệu đầu tiên (đọc, ghi bộ nhớ, đọc thanh ghi) ở chu kỳ
  **t_D = L + 3** (1×) hoặc **2L + 3** (2×), byte A ở r_{t_D}, byte B ở f_{t_D}; word n ở
  chu kỳ t_D + n. Ghi thanh ghi không có latency: word duy nhất ở chu kỳ 4.
* **RWDS**: thiết bị lái RWDS từ khi CS# xuống (tDSV ≤ 5 ns) trong pha CA: mức cao = 2×
  (latency cố định, hoặc trùng refresh khi latency biến đổi). Đọc: sau CA RWDS thấp, rồi cao
  cùng byte A / thấp cùng byte B (đồng pha với DQ, lệch ≤ ±0,4 ns), thiết bị có thể lái DQ
  (chưa hợp lệ) từ r_{t_D−1}. Ghi bộ nhớ: thiết bị nhả RWDS sau f3, host phải lái RWDS thấp
  ("preamble") trước f_{t_D−1}, rồi RWDS = mặt nạ (1 = không ghi byte). Ghi thanh ghi: host
  **không** lái RWDS.
* Dữ liệu bộ nhớ theo thứ tự host: IP dùng little endian (byte địa chỉ 2n = byte A của word
  n). Thanh ghi big endian (byte A = [15:8]).
* Thời gian chính (bản 200 MHz): tCSHI ≥ 6 ns, tRWR ≥ 35 ns (từ CS# lên của giao dịch trước
  tới f2), tCSS ≥ 4 ns, tCSM ≤ 4 µs (≤ 85 °C) hoặc 1 µs (CR1[1:0] = 10, chip +105/+125 °C;
  chip của bo RAM là S80KS2562GABHM020, bậc "M" tới 125 °C), tRP ≥ 200 ns, tRH ≥ 200 ns,
  tVCS ≤ 150 µs, tCSDPD 200..3000 ns + tEXTDPD 150 µs, tCSHS 60..3000 ns + tEXTHS 100 µs,
  tDPDIN / tHSIN ≥ 3 µs từ lúc vào DPD / HS tới xung WAKE sớm nhất (driver chờ 5 µs ở cuối
  `bow_hr_deep_power_down` / `bow_hr_hybrid_sleep`).

## 2. Kiến trúc

### 2.1 Miền clock và reset

| Miền | Khối |
|------|------|
| `clk_i` (SoC) | cửa sổ (`bow_hyperram_win`), thanh ghi, phía `clk_i` của hai FIFO và của bắt tay lệnh |
| `hr_clk` (CK) | controller, PHY, thanh ghi chân, cờ T của pad, PSCLK của hai MMCM, emulator |
| `hr_rd_clk` (CK, pha chỉnh được) | IDDR và phía ghi của FIFO đọc |
| `hr_wclk` (CK + T/4, pha chỉnh được ±3T/16) | chỉ ODDR của DQ/RWDS trong wrapper chân |

* Reset **bo** (`hr_rst_ni` = hai MMCM đã lock): bản sao CR0/CR1, trạng thái nguồn của thiết
  bị và hai bộ bước pha. HyperRAM giữ thanh ghi và dữ liệu qua reset SoC, nên controller cũng
  giữ hiểu biết về nó (khởi động ấm: firmware có thể dùng lại thiết bị đã cấu hình).
* Reset **kênh** = `hr_rst_ni & rst_ni & !CTRL.CORE_RST`, đồng bộ vào từng miền: FIFO, bắt tay
  lệnh, controller, PHY, phía kênh của cửa sổ. Khi kênh reset, CS# lên ngay (giao dịch đang
  chạy bị huỷ, HyperBus cho phép), level shifter bị cách ly (OE# = 1).
* Phía bus của cửa sổ và thanh ghi dùng `rst_ni`: một truy cập đã được `gnt` luôn có `rvalid`.

### 2.2 Cửa sổ bộ nhớ (`bow_hyperram_win`)

* **Read buffer** (`CTRL.RBUF_EN`): 4 line × 32 byte (8 word bus = 16 word HyperRAM), tag và
  bit hợp lệ từng word. Đọc trúng trả lời như SRAM (`gnt` cùng chu kỳ, `rvalid` chu kỳ sau).
  Trượt → một line fill: với `CTRL.WRAP_FILL` là **burst wrapped bắt đầu ở word cần đọc**
  (word đó về trước, dùng đúng tính năng "critical word first" của HyperRAM; cần CR0[1:0] = 11,
  nhóm 32 byte), nếu không thì burst tuyến tính từ đầu line. Bus được trả lời ngay khi word cần
  đã về; phần còn lại của line tiếp tục về trong khi các lần đọc trúng khác được phục vụ. Chỉ
  một line fill tại một thời điểm; line thay thế theo vòng.
* **Ghi** luôn cập nhật line nếu line có trong buffer (write-through): buffer không bao giờ cũ.
* **Ghi posted** (`CTRL.WPOST`): lần ghi được gộp vào write buffer (một khối 32 byte, byte
  enable từng byte) và được `gnt` ngay. Khối được đẩy thành **một burst** (từ word ghi đầu tới
  word ghi cuối; byte không ghi được che bằng RWDS) khi: có ghi vào khối khác, trước mọi lần đọc
  trượt (line fill thấy dữ liệu mới), `CMD.FLUSH`, hoặc `WB_TMO` chu kỳ không có ghi. Ghi
  posted bị controller từ chối (thiết bị đang ngủ, EN = 0) thì mất và đặt `STATUS.WR_ERR` (không
  phải lỗi bus). Controller trả lời **mọi** khối ghi, posted hay không (`WDONE` khi giao dịch
  xong, `ERR` khi bị từ chối); cửa sổ đếm khối posted đang bay và chỉ báo rảnh khi đã nhận đủ trả
  lời, nên `STATUS.WIN_IDLE` = 1 sau `CMD.FLUSH` nghĩa là dữ liệu đã nằm trong thiết bị (driver
  `bow_hr_flush` dựa vào đó trước khi ghi CR0/CR1 để ngủ; lệnh của bộ thực thi được ưu tiên hơn
  cửa sổ nên nếu không chờ, một lệnh ngủ có thể vượt mặt khối ghi còn trong FIFO).
* `WPOST = 0`: mỗi lần ghi là một giao dịch, trả lời sau khi controller báo xong.
* **Lỗi bus** (không truy cập thiết bị): offset ≥ 32 MiB (`RANGE`), cửa sổ chưa sẵn sàng
  (`NOT_READY`: chưa `INIT_DONE`, thiết bị ngủ, `CORE_RST`, mất link — kể cả một truy cập đang
  chờ khi `CORE_RST` / mất link xảy ra). Đọc lỗi (không có dữ liệu, RWDS sai) → lỗi bus,
  `RD_ERR`, line bị bỏ. Không có trả lời trong 2^18 chu kỳ, hoặc mất clock HyperRAM khi link vẫn
  lên → lỗi bus, `BUS_TIMEOUT`, cửa sổ **chết** (`STATUS.BROKEN`) tới `CORE_RST`: một câu trả
  lời muộn không bao giờ bị nhận nhầm. `ERR_ADDR` giữ địa chỉ.
* Một khối posted bị từ chối: `STATUS.WR_ERR` lên cùng lúc với câu trả lời (không muộn hơn
  `WIN_IDLE`), và read buffer bị xoá (line có thể đã nhận dữ liệu ghi mà thiết bị không có).
* `INVAL` (lệnh, hoặc IP tự gửi) có hiệu lực ngay: mọi line, kể cả line đang fill (truy cập
  đang chờ fill đó vẫn được trả lời từ dữ liệu của fill, nhưng line không còn hợp lệ).

### 2.3 Controller (`bow_hyperram_ctrl`)

Nguồn công việc, theo thứ tự ưu tiên: **bộ thực thi lệnh** (từ thanh ghi: APPLY, PS_GO,
WPS_GO, RFIFO_SYNC, CAP_ARM, HW_RESET, REG_RD/REG_WR, WAKE, BIST, SNAP, CLR_STATS), rồi
**cửa sổ** và **BIST** luân phiên. Một giao dịch chỉ bắt đầu khi bộ căn đọc của PHY rảnh
(dữ liệu đọc trước đã về), nên các câu trả lời đi đúng thứ tự lệnh.

Lịch của một giao dịch (t = chu kỳ giao dịch; t = 0 là chu kỳ đầu CS# thấp, nên chu kỳ CK k
của thiết bị là t = k; L, cố định/biến đổi lấy từ **bản sao CR0** trong controller):

| t | Chân |
|---|------|
| −2 | FPGA nhả RWDS (thiết bị sắp lái nó trong pha CA) |
| −1 | `ls_dir_rwds` = 1 (HyperRAM → FPGA) |
| 0 .. t_C − 1 | CS# thấp (t_C = t_E, hoặc t_E + `RD_HOLD` khi đọc); DQ do FPGA lái (0) trừ cửa sổ đọc |
| 1 .. 3 | CK chạy (tới t_E − 1), DQ = CA |
| `LAT_SMP` | latency biến đổi: lấy mức RWDS (qua `bow_sync`), chậm nhất ở L + 2 |
| t_D .. t_E − 1 | dữ liệu (t_D = 4 cho ghi thanh ghi; t_E = t_D + N) |
| ghi bộ nhớ | `ls_dir_rwds` về 0 ở `RW_DIR`, FPGA lái RWDS thấp (preamble) từ `RW_OE`, rồi mặt nạ |
| đọc | FPGA nhả DQ từ max(4, D − `RDIR_LEAD` − `OE_PRE`) (D = 2L + 3 khi cố định, L + 3 khi biến đổi: lúc sớm nhất thiết bị có thể lái), `ls_dir_dq` = 1 từ `OE_PRE` chu kỳ sau; cả hai về sau khi CS# lên: `ls_dir_*` ở t_C + 1 + `RDIR_TAIL`, FPGA lái lại `OE_POST` chu kỳ sau |
| bộ căn đọc | arm ở t = max(4, D − `ARM_LEAD`) với N word |
| giao dịch kế | t = −2 của nó khi mọi cửa sổ đã về nghỉ và t = 0 cách t_C ít nhất `CSHI` chu kỳ |

* Giao dịch có thời gian CS# thấp (trường hợp xấu nhất 2L + 3 + N, cộng `RD_HOLD` khi đọc)
  vượt `TCSM` bị **từ chối** (`TCSM_ERR`), không bao giờ vi phạm tCSM.
* **`RD_HOLD`**: thiết bị xuất byte B của word cuối tCKD (tới 5 ns) sau cạnh xuống cuối và
  ngừng lái DQ tOZ sau khi CS# lên (tOZ chỉ có giá trị tối đa). Nếu CS# lên ngay nửa chu kỳ
  sau cạnh đó, byte B cuối có thể chỉ còn cửa sổ gần 0 (100 MHz: 5 ns − tCKD), đúng ở lần đọc
  ID0 dùng để hiệu chỉnh. Không có cạnh CK thì thiết bị giữ nguyên đầu ra, nên giữ CS# thấp
  thêm một chu kỳ (CK dừng) cho byte B trọn một chu kỳ, giá 1 chu kỳ mỗi giao dịch đọc.
* REG_WR cập nhật bản sao: CR0 đổi latency của mọi giao dịch sau đó; CR0[15] = 0 → deep power
  down, CR1[5] = 1 → hybrid sleep (cửa sổ bị chặn). REG_RD CR1 đưa trường chỉ-đọc CR1[1:0]
  (chu kỳ refresh, theo cấp nhiệt độ của chip) vào bản sao; HW_RESET và ra khỏi DPD giữ trường đó
  (chip không đổi nó). WAKE: xung CS# `TWAKE[15:0]` chu kỳ không có CK, chờ `TWAKE[31:16]`; WAKE
  khi thiết bị đang hoạt động thì không làm gì (`CMD_DONE`, không có xung CS# vô nghĩa), WAKE khi
  đang hồi phục chờ hồi phục xong rồi mới quyết. HW_RESET: RESET# thấp `TRST[15:0]`, chờ
  `TRST[31:16]`. `CMD_DONE` của WAKE / HW_RESET chỉ tới khi hồi phục xong (POWER = hoạt động).
  Trạng thái nguồn và bản sao nằm trong miền reset của bo: RESET# đặt bản sao về trạng thái bật
  nguồn ngay từ chu kỳ đầu; WAKE đổi trạng thái khi xung CS# đã trọn (ra khỏi DPD: trạng thái bật
  nguồn, dữ liệu mất; ra khỏi HS: CR1[5] = 0), một xung bị reset kênh cắt ngang để POWER ở DPD /
  HS (chip có thể chưa coi xung ngắn là lệnh thức: WAKE lại; xung thừa trên chip đã thức chỉ là một
  giao dịch bị bỏ qua). Thời gian hồi phục được chốt lúc bắt đầu và đếm trong miền của bo: một
  reset kênh giữa chừng (reset SoC, `CORE_RST`) vẫn để POWER về hoạt động đúng lúc. Ghi ID0/ID1,
  ghi CR0 với mã latency dành riêng, bước pha vượt giới hạn và `BIST_GO` khi BIST đang chạy bị từ
  chối với `ERR_CODE` = `ARG` (7); bước pha mà MMCM không trả PSDONE: `ERR_CODE` = 8 (pha đã đi
  được số bước đã xác nhận).

### 2.4 PHY (`bow_hyperram_phy`) và wrapper chân

Hợp đồng thời gian (`bow_hyperram_pkg`, T = chu kỳ CK, pha ghi 0): giá trị của chu kỳ PHY j ra
chân ở chu kỳ chân j + 1; CK cao trong nửa đầu; DQ/RWDS byte A trong [(j+0,75)T, (j+1,25)T)
(giữa cạnh lên CK), byte B trong [(j+1,25)T, (j+1,75)T). Trên UltraScale+:

| Chân | Primitive | Clock |
|------|-----------|-------|
| CK_P / CK_N | `ODDRE1` D1 = ck_en, D2 = 0 (CK_N bù) | `hr_clk` |
| CS#, RESET#, DIR, OE# | `ODDRE1` D1 = D2 | `hr_clk` |
| DQ[7:0], RWDS (ra) | `ODDRE1` | `~hr_wclk` (= `hr_clk` + 3T/4 ± pha ghi) |
| DQ, RWDS (vào) | `IDDRE1` SAME_EDGE_PIPELINED | `hr_rd_clk` |
| T của DQ/RWDS | flop fabric (một flop mỗi pad) | `hr_clk` |

Vì sao `hr_clk` ở 270° của MMCM_H: output có dịch pha tinh phải có pha tĩnh 0 (DRC AVAL-152)
nhưng clock ghi phải sớm hơn clock controller một phần tư chu kỳ: `hr_clk` ở 270°, `hr_wclk` ở
0° (+ dịch pha) cùng một VCO cho `hr_wclk` = `hr_clk` + T/4, đường controller → ODDR đồng bộ:
ở pha ghi 0 có 3T/4 cho setup và T/4 cho hold. Pha ghi gần +T/4 sẽ không còn biên hold, nên
dải pha ghi là ±3T/16 (controller từ chối hơn thế) và STA kiểm cả dải đó bằng độ bất định
3T/16. Vivado coi pha 270° là độ trễ clock chứ không nằm trong dạng sóng, nên cặp cạnh mặc
định của nó sai một chu kỳ: XDC của bo đặt `set_multicycle_path -setup 2` (không có `-hold 1`).

**Đọc**: mẫu IDDR (cạnh lên, cạnh xuống) đi qua FIFO bất đồng bộ 16 ô chạy liên tục (cùng tần
số nên độ trễ cố định tới khi pha đọc dịch trọn một chu kỳ; `RFIFO_SYNC` khởi động lại). **Bộ căn
theo RWDS** (cách HyperBus định nghĩa dữ liệu đọc, nhưng lấy mẫu đồng bộ hệ thống thay vì dùng
RWDS làm clock): được arm `RD_DLY` chu kỳ sau token của controller, nó cần ít nhất hai mẫu RWDS
thấp rồi một mẫu cao = byte A, mẫu thấp kế = byte B. Mức cao của pha CA (chỉ báo 2×) kéo dài
nhiều mẫu nên không bao giờ bị lấy nhầm. Chế độ `STRICT` (mặc định): RWDS phải đảo mỗi nửa
chu kỳ, nếu không → lỗi `RWDS` (thay vì trả dữ liệu lệch); không tới byte A đầu tiên trong
`ARM_LEAD + RD_TMO` chu kỳ → lỗi `RD_TMO`. Lệch `RD_DLY`: arm muộn tới `ARM_LEAD − 2` chu kỳ vẫn
đúng dữ liệu, muộn hơn → `RD_TMO`; arm sớm vẫn đúng suốt khoảng latency (bộ căn chỉ cần hai
mẫu RWDS thấp trước byte A), tới khi điểm arm chạm mức RWDS của pha CA hoặc byte A không tới trong
`ARM_LEAD + RD_TMO` chu kỳ, sớm hơn thì giao dịch báo lỗi. Không bao giờ trả dữ liệu sai lặng lẽ
(nên "đọc vẫn đúng" không chứng minh `RD_DLY` nằm gần giá trị hiệu chỉnh: dùng chụp thô).

**Chụp thô**: `CAP_ARM` rồi giao dịch kế tiếp: 64 chu kỳ luồng mẫu từ chu kỳ controller của
t = 0 vào `CAP[0..63]` = {RWDS xuống, RWDS lên, DQ xuống, DQ lên}. Chỉ số c của byte A đầu tiên
cho `RD_DLY = c − t_D`.

**Mức RWDS của pha CA** (latency biến đổi) đi thẳng từ pad qua `bow_sync` trên `hr_clk`:
`LAT_SMP` = n lấy mức RWDS tại pad ngay trước r_(n−3) (6: cuối chu kỳ CA thứ 2, ngay trước r3),
quyết định ở chu kỳ controller min(n, L + 2) + 2, đúng lúc cho L ≥ 4 (L = 3 dùng 5). Giới hạn trên:
mức đó phải tới pad (qua level shifter) trước khi thiết bị đổi RWDS sau f3.

### 2.5 Level shifter của bo RAM (TXV0108)

Bo RAM: phía A = HyperRAM (1,8 V), phía B = FPGA (VADJ 1,5 V). U4 = DQ0..7 (DIR =
`FMC_HB_DIR`), U6 = CK_P, CK_N, CS#, RESET# (DIR nối GND: luôn FPGA → HyperRAM), U8 = RWDS
(DIR = `FMC_HB_RWDS_DIR`), OE# chung `FMC_HB_OE_N`; DIR = H: A → B (HyperRAM → FPGA). Datasheet
TXV0108: tpd 1,2..4,8 ns mỗi chiều, bật/tắt đầu ra (ten/tdis) tới 7 ns, lệch kênh ±450 ps trong
một chip, đầu vào **không được thả nổi**. Các giá trị mặc định của `LAT` (bo RAM, 100 MHz) suy
ra như sau:

* Lúc nghỉ: DIR = FPGA → HyperRAM, FPGA lái DQ/RWDS = 0 (`IDLE_DRIVE`): không đầu vào nào thả
  nổi lâu. Trong reset kênh (và từ lúc nạp cấu hình tới chu kỳ PHY đầu tiên) FPGA thả DQ/RWDS để
  không chồng lái với level shifter còn đang lái một lần đọc bị cắt; mạch vào của TXV0108 luôn
  hoạt động (cả khi OE# = 1) nên bản bo RAM bật pull-down yếu của chân FPGA cho DQ/RWDS.
* RWDS: FPGA nhả ở t = −2, DIR → đọc ở t = −1 (tắt đầu ra A ≤ 7 ns trước khi CS# tới thiết bị
  và thiết bị lái RWDS).
* Đọc: thiết bị có thể lái DQ từ r_{t_D−1}; DIR → đọc ở t_D − 2 (`RDIR_LEAD` = 2), FPGA nhả DQ
  một chu kỳ trước (`OE_PRE` = 1). Sau CS# lên thiết bị nhả trong ≤ 5 ns (+ U6 ≤ 4,8 ns): DIR về
  ở t_C + 1 + 2 (t_C = t_E + `RD_HOLD`: lúc CS# lên; `RDIR_TAIL` = 2), FPGA lái lại sau
  `OE_POST` = 1. Một reset kênh giữa lúc đọc thả DQ/RWDS ngay (thanh ghi chân của PHY về
  `HR_IO_OUT_RST`) và chỉ lái lại sau reset, ít nhất một chu kỳ sau khi OE# = 1: không chồng lái.
* Ghi bộ nhớ: thiết bị nhả RWDS ≤ 5 ns sau f3 (+ trễ U6): DIR → ghi ở t = 5 (`RW_DIR`), FPGA lái
  preamble từ t = 6 (`RW_OE`), tới thiết bị trước f_{t_D−1} khi t_D ≥ 8. **Latency cố định (2×)
  là bắt buộc trên bo RAM** (t_D = 2L + 3 ≥ 9); với latency biến đổi và L = 4 (t_D = 7) không đủ
  chỗ cho vòng đổi chiều RWDS qua level shifter.
* Ghi: CK đi qua U6, DQ qua U4: lệch giữa hai chip cùng loại ở cùng điều kiện được bù bằng **pha
  ghi** (`WPS_TARGET`, ±3T/16 = ±1,875 ns ở 100 MHz) quét bằng phần mềm (`calw`). Đọc: CK đi, dữ liệu về qua hai level
  shifter (tới ~15 ns): bù bằng pha đọc trên trọn chu kỳ và `RD_DLY`.
* `LAT_SMP` = 6 vì RWDS của pha CA tới pad FPGA tới ~15 ns sau CS# (U6 + tDSV + U8).
* Lưu ý điện (như DDR, [../ddr_board_review.md](../ddr_board_review.md) mục 4): DIR/OE tham
  chiếu VCCA = 1,8 V nhưng FPGA lái 1,5 V (biên ~0,2 V); VCCB = 1,5 V ngoài vùng tốc độ được đặc
  tả của TXV0108; méo duty CK tới 48..56 % (HyperRAM cần 45..55 %).

## 3. Bản đồ thanh ghi (`0x4000_F000`)

Giá trị reset ở dưới là của MPS4 (CK 100 MHz); `TIM0`, `TRST`, `TWAKE` tính từ tần số CK.

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| 0x000 | `ID` | R | `0x48524D01` ("HRM", phiên bản 1) |
| 0x004 | `INFO` | R | [1:0] loại PHY (1 chân, 2 emulator loopback), [2] có level shifter, [3] HrEn, [7:4] log2(dung lượng) − 16, [15:8] MHz, [18:16] số line − 1, [23:20] log2(byte mỗi line), [24] có BIST. MPS4 loopback: `0x0153_649A` |
| 0x008 | `CTRL` | RW | [0] EN, [1] LS_EN (OE# = 0), [2] IDLE_DRIVE, [3] STRICT — có hiệu lực sau APPLY; [8] INIT_DONE, [9] RBUF_EN, [10] WRAP_FILL, [11] WPOST, [12] CORE_RST — có hiệu lực ngay. Reset `0x0000_060C` |
| 0x00C | `CMD` | W | đúng một bit mỗi lần ghi: [0] APPLY, [1] PS_GO, [2] WPS_GO, [3] RFIFO_SYNC, [4] CAP_ARM, [5] HW_RESET, [6] REG_RD, [7] REG_WR, [8] WAKE, [9] FLUSH, [10] INVAL, [11] BIST_GO, [12] BIST_STOP, [13] SNAP, [14] CLR_STATS |
| 0x010 | `STATUS` | R/W1C | R: [0] BUSY, [1] READY, [2] CLK_OK, [3] APPLIED, [5:4] POWER (0 hoạt động, 1 DPD, 2 HS, 3 đang hồi phục), [6] BIST_BUSY, [7] BROKEN, [20] DBG_ERR, [21] RFIFO_BROKEN, [22] WIN_IDLE. W1C: [8] CMD_DONE, [9] CMD_ERR, [10] CAP_DONE, [11] BIST_DONE, [12] RD_ERR, [13] WR_ERR, [14] RFIFO_ERR, [15] BUS_TIMEOUT, [16] NOT_READY, [17] RANGE, [18] BIST_ERR, [19] TCSM_ERR |
| 0x014 | `IRQ_EN` | RW | các bit W1C của `STATUS`: `irq = \|(STATUS & IRQ_EN)` |
| 0x018 | `LAT` | RW | [3:0] RDIR_LEAD, [7:4] RDIR_TAIL, [9:8] OE_PRE, [11:10] OE_POST, [15:12] RW_DIR, [19:16] RW_OE, [23:20] ARM_LEAD, [28:24] RD_DLY. Reset `0x0036_5522` (bo RAM) |
| 0x01C | `TIM0` | RW | [11:0] TCSM (chu kỳ CS# thấp tối đa), [15:12] CSHI (chu kỳ CS# cao tối thiểu), [19:16] LAT_SMP, [23:20] RD_TMO, [25:24] RD_HOLD (đọc: CS# giữ thấp thêm chừng ấy chu kỳ sau word cuối, CK dừng). Reset `0x01C6_405F` (1 µs − 5, 35 ns, 6, 12, 1) |
| 0x020 | `TRST` | RW | [15:0] RESET# thấp, [31:16] chờ sau đó (chu kỳ). Reset `0x3A98_0064` (1 µs, 150 µs) |
| 0x024 | `TWAKE` | RW | [15:0] xung CS# của WAKE, [31:16] chờ sau đó. Reset `0x3A98_0028` (400 ns, 150 µs) |
| 0x028 | `REG_SEL` | RW | thanh ghi thiết bị của REG_RD/REG_WR: 0 ID0, 1 ID1, 2 CR0, 3 CR1 |
| 0x02C | `REG_DATA` | RW | [15:0] dữ liệu REG_WR / kết quả REG_RD |
| 0x030 | `CR0` | R | bản sao CR0 của controller (latency, cố định) |
| 0x034 | `CR1` | R | bản sao CR1 ([1:0] chỉ-đọc ở thiết bị, theo bậc nhiệt độ: cập nhật khi `REG_RD` CR1) |
| 0x038 | `PS_TARGET` | RW | pha đọc mong muốn (có dấu, bước MMCM) |
| 0x03C | `PS_NOW` | R | [15:0] pha đọc (giữ qua reset SoC), [31:16] số bước mỗi CK (672) |
| 0x040 | `WPS_TARGET` | RW | pha ghi mong muốn (\|w\| ≤ 3 × số bước / 16, MPS4: 126) |
| 0x044 | `WPS_NOW` | R | [15:0] pha ghi, [31:16] số bước mỗi CK |
| 0x048 | `CLK_HZ` | R | tần số CK |
| 0x04C | `ERR_ADDR` | R | địa chỉ bus của truy cập cửa sổ lỗi gần nhất |
| 0x050 | `EMU` | R | [4:0] log2 dung lượng emulator (0 = không có) |
| 0x054 | `DBG` | R | từ debug của bo (emulator: [31] lỗi, [29:28] nguồn, [23:16] mã lỗi đầu, [15:0] số lỗi), từng bit qua bộ đồng bộ |
| 0x058 | `ERR_CODE` | R | [7:0] mã lỗi của lệnh cuối, [15:8] của giao dịch lỗi cuối: 0 không lỗi, 1 không có dữ liệu đọc, 2 RWDS không phải strobe, 3 vượt tCSM, 4 thiết bị đang ngủ, 5 chưa EN / không có clock / kênh đang reset, 6 FIFO đọc hỏng, 7 đối số bị từ chối (lệnh CMD sai dạng, ghi ID0/ID1, mã latency CR0 dành riêng, bước pha vượt giới hạn, `BIST_GO` khi BIST đang chạy), 8 bước pha: MMCM không trả PSDONE |
| 0x05C | `WB_TMO` | RW | [15:0] write buffer tự đẩy sau N chu kỳ `clk_i` không có ghi (0 = tắt). Reset 64 |
| 0x060 | `BIST_CTRL` | RW | [0] lượt ghi, [1] lượt đọc, [2] dữ liệu đếm (0 = PRBS), [15:8] word mỗi burst |
| 0x064 | `BIST_ADDR` | RW | địa chỉ word HyperRAM đầu tiên |
| 0x068 | `BIST_LEN` | RW | số word |
| 0x06C | `BIST_SEED` | RW | seed |
| 0x070 | `BIST_CYCLES` | R | số chu kỳ CK của lần chạy |
| 0x074 | `BIST_ERRS` | R | word sai của lượt đọc |
| 0x078 | `BIST_FADDR` | R | địa chỉ word sai đầu tiên |
| 0x07C | `BIST_FDATA` | R | [15:0] mong đợi, [31:16] đọc được |
| 0x080..0x0BC | `ST[0..15]` | R | thống kê (chụp bằng SNAP): giao dịch đọc, ghi, word đọc, word ghi, giao dịch 2×, truy cập thanh ghi, giao dịch lỗi/bị từ chối, giao dịch BIST, read buffer trúng, trượt, lần đẩy write buffer |
| 0x100..0x1FC | `CAP[0..63]` | R | chụp thô: [7:0] DQ cạnh lên, [15:8] DQ cạnh xuống, [16] RWDS lên, [17] RWDS xuống |

* `CMD` bị từ chối (`CMD_ERR`) khi đang có lệnh (BUSY), khi có nhiều bit (`ERR_CODE` 7), khi kênh
  đang reset (`CORE_RST`, mất link, và chu kỳ đầu sau khi nhả: cả FLUSH / INVAL; `ERR_CODE` đọc 5,
  giữ sau reset tới lệnh kế tiếp), hoặc (lệnh cho phía hr) khi chưa có `CLK_OK` (5). Mỗi lần ghi
  `CMD` hoặc được làm, hoặc bị từ chối, không bao giờ cả hai. Đối số (cấu hình cho APPLY, đích pha, thanh ghi thiết bị, BIST) được chép
  lúc ghi `CMD` và giữ yên tới khi xong.
* `READY` = `CLK_OK` & `APPLIED` & `INIT_DONE` & !`CORE_RST` & !`BROKEN` & POWER = hoạt động.
* `PS_NOW`, `WPS_NOW`, `CR0`, `CR1`, POWER đi qua bộ đồng bộ từng bit và được nhận khi hai mẫu
  liên tiếp bằng nhau (chỉ đổi trong các lệnh); kết quả BIST, thống kê, `CAP` là tĩnh sau sự
  kiện tương ứng. Trong reset kênh và 3 chu kỳ sau đó (bộ đồng bộ reset cùng kênh) `CR0` / `CR1`
  đọc giá trị mặc định, `PS_NOW` / `WPS_NOW` đọc 0 và POWER đọc 3 (đang hồi phục): trạng thái của
  bo chưa biết, không bao giờ đọc nhầm "hoạt động" giữa lúc hồi phục.

## 4. Khởi tạo và hiệu chỉnh (driver `bow_hr_init`)

1. **Bật**: `CTRL` = EN | IDLE_DRIVE | STRICT | RBUF_EN | WRAP_FILL | WPOST (+ LS_EN trên bo RAM),
   `LAT`/`TIM0` theo loại PHY, APPLY.
2. **HW_RESET**: RESET# 1 µs, chờ 150 µs; thanh ghi thiết bị về mặc định (latency 7, cố định).
3. **Hiệu chỉnh thô**: quét pha đọc một chu kỳ (bước 8), mỗi điểm một lần đọc ID0 có chụp thô;
   điểm tốt khi word tìm thấy trong luồng (theo RWDS) là 0x0E86. IDDR lấy mẫu ở cả hai cạnh của
   `hr_rd_clk` và DQ/RWDS đổi ở cả hai cạnh CK, nên vùng pha xấu lặp lại mỗi T/2: bản đồ được
   **gập theo T/2** (một pha tốt khi nó và pha cách T/2 đều tốt), mắt = dải tốt liên tiếp dài nhất
   của bản đồ đã gập (vòng tròn), đặt pha ở giữa (trong ±T/4 quanh pha cũ), `RFIFO_SYNC`, đo
   `RD_DLY` từ chụp thô. Không gập thì bước thô có thể lọt một vùng xấu hẹp (~5 bước) và gộp hai
   mắt nửa chu kỳ thành một dải mà giữa dải chính là vùng xấu bị lọt: đã gặp trên MPS4 (82/84
   điểm tốt, `init` hỏng tuỳ pha xuất phát); sau khi sửa, 24/24 lần `init` từ 24 pha xuất phát
   rải trên nửa chu kỳ đều đúng, tâm lệch nhau ≤ 4 bước.
4. **Cấu hình**: CR0 = latency theo CK (≤ 85 MHz: 3, ≤ 104: 4, ≤ 133: 5, ≤ 166: 6, còn lại 7),
   cố định, 34 Ω, wrap 32 byte; đọc lại; đọc CR1: [1:0] = 01 → tCSM 4 µs, 10 → 1 µs → `TCSM`.
5. **Hiệu chỉnh tinh**: ghi mẫu 32 byte (mọi bit DQ đảo giữa các byte) vào offset 0, quét lại pha
   (bước 4) với chụp thô của line fill, giữa mắt, `RD_DLY`, kiểm lại mẫu và ID0.
6. **INIT_DONE**: cửa sổ mở (`STATUS.READY`).
7. (Bo RAM) `bow_hr_calibrate_write`: quét pha ghi ±3T/16, mỗi điểm ghi mẫu, đọc lại, đọc ID0.

```c
#include "bow32.h"

bow_hr_info_t info;  bow_hr_config_t cfg;  bow_hr_cal_t cal;
if (!bow_hr_probe(&info)) return;               // không có IP, hoặc stub (HrEn = 0)
if (!bow_hr_init(&info, &cfg, &cal, true)) return;
volatile uint32_t *hr = (volatile uint32_t *)BOW32_HYPERRAM_BASE;
hr[0] = 0x12345678u;                            // CPU truy cập trực tiếp qua cửa sổ
bow_hr_bist_res_t r;                            // BIST: ghi + đọc 64 KiB, PRBS
bow_hr_bist(0, 32768, bow_hr_bist_burst_max(), HR_BIST_WRITE | HR_BIST_READ, 1, &r);
```

## 5. BIST

Bộ sinh/kiểm tra trong miền `hr_clk` là một nguồn giao dịch như cửa sổ (luân phiên với nó): burst
tuyến tính `BIST_CTRL[15:8]` word (driver: dài nhất vừa tCSM), lượt ghi rồi lượt đọc. Dữ liệu
mỗi word HyperRAM: PRBS = trạng thái xorshift32 (13, 17, 5) từ `BIST_SEED` (0 → 1), word k = 16
bit thấp sau k bước; đếm = (địa chỉ word ^ seed) & 0xFFFF. Byte A = [7:0]. `BIST_CYCLES` cho
băng thông thật của HyperBus. Một burst bị từ chối (vượt `TCSM`, thiết bị đang ngủ) kết thúc
lượt chạy với `BIST_ERR` (`ERR_CODE` cho lý do). BIST đi vòng qua read buffer: IP tự `INVAL`
read buffer khi mỗi lượt BIST xong (và khi `HW_RESET`, `WAKE` xong: ra khỏi deep power down thì
mảng nhớ đã mất); driver vẫn gọi `INVAL` cho chắc. Đừng dùng cửa sổ trên vùng BIST đang chạy.

## 6. Emulator HyperRAM (`bow_hyperram_dev`)

Thiết bị HyperRAM 2.0 tổng hợp được, ở mức thanh ghi chân của PHY: CA, latency 1×/2× (latency
biến đổi: 2× cho "va chạm refresh" rút mỗi giao dịch một lần từ LFSR 4 bit chu kỳ 15, đúng 3 trong
mỗi 15 giao dịch bất kể thời điểm; một LFSR chạy mỗi chu kỳ bị khoá vào chu kỳ vòng lặp của CPU
và không cho 2× nào), đọc/ghi bộ nhớ (tuyến tính, wrapped 16/32/64/128, hybrid), thanh
ghi ID/CR, mặt nạ RWDS, DPD/HS/WAKE, RESET#. Bộ nhớ 8 byte mỗi hàng với byte enable (UltraRAM
trên MPS4, 1 MiB = 32 UltraRAM, đọc trễ 3 chu kỳ với flop cuối trong fabric để đường tới ODDR của chân ngắn). Kiểm tra giao thức, mã lỗi ở `DBG`: 01 bit CA dành riêng, 02 ghi thanh ghi
sai, 03 FPGA lái RWDS khi thiết bị lái, 04 FPGA lái DQ khi thiết bị lái, 05 thiếu preamble /
mặt nạ, 06 đọc thanh ghi quá một word, 07 vượt tCSM, 08 CS# cao quá ngắn, 09 truy cập khi ngủ /
đang hồi phục, 0A ngoài dung lượng emulator, 0B RESET# quá ngắn / CS# quá sớm sau RESET#, 0C mã
latency dành riêng, 0D xung WAKE sai độ dài, 0E CS# lên khi CA chưa xong, 0F CK khi CS# cao.

## 7. Kiểm chứng

* `make run TEST=hyperram` (trong `make test`): SoC đầy đủ, firmware `sw/apps/hyperram` chạy
  `test quick` (19 mục) trên CPU qua mô hình clock (dịch pha MMCM), mô hình pad loopback và
  emulator; emulator không được báo lỗi giao thức nào.
* `make -C hw/ip/hyperram/dv test` (trong `make test-ip` và CI): testbench IP lái IP như driver,
  với mô hình S80KS2562 mức chân **độc lập với RTL** (viết từ datasheet: thời gian
  tCKD/tDSV/tIS/tIH/tCSM/tRWR…, thanh ghi, burst, DPD/HS, kiểm tra vi phạm) và mô hình bo TXV0108
  (độ trễ ngẫu nhiên theo seed, đếm tranh chấp và đầu vào thả nổi); 5 cấu hình: loopback, bo RAM,
  nối thẳng 166 MHz, stub, chip tắt DQ trước byte cuối ([../simulation.md](../simulation.md)).
  Nó đã tìm ra ba lỗi (đã sửa): burst BIST bị từ chối làm treo `BIST_BUSY`, `WIN_IDLE` lên trước
  khi khối ghi posted vào chip, `unique case` của thanh ghi lệnh. Mục 9b của testbench kiểm từng
  bản sửa của hai vòng review PR #6 (cuộc đua khối ghi đang staged ↔ REG_RD, INVAL sau BIST khi
  line đang nạp, khối posted bị từ chối, `CORE_RST` khi đang đọc / giữa hồi phục WAKE / ở chu kỳ
  đầu sau khi nhả, mã `ERR_CODE`, `BIST_FADDR`, bản sao CR1, không chồng lái DQ/RWDS); `make -C
  hw/ip/hyperram/dv mutants` gỡ từng bản sửa trong một bản sao RTL (18 đột biến): cả 18 phải FAIL.
* `make test-fpga-dv` (cần Vivado): `tb_bow_hyperram_io_xilinx` chạy hai wrapper của bo với
  model unisim (ODDRE1/IDDRE1/IOBUF/MMCME4_ADV): hợp đồng thời gian chân, mức nghỉ và SRVAL, bắt
  mẫu đọc khi dịch pha, pha ghi ±T/4, mất lock; `make -C hw/fpga/common/dv mutants` kiểm chính testbench này bằng
  42 bản hỏng có chủ đích của hai wrapper ([../simulation.md](../simulation.md)).
* `make lint`: SoC với `HrEn` = 0, 1 (chân) và 1 (loopback cùng DDR); `make -C hw/ip/hyperram/dv
  lint` thêm emulator và các mô hình. `xvlog` của Vivado dịch toàn bộ SoC không lỗi, và `make -C
  hw/ip/hyperram/dv xsim CFG=card` chạy testbench IP bằng xsim (không tham chiếu trước khai báo:
  Verilator chấp nhận, xvlog thì không).
* `make test-tools`: mô hình Python của dữ liệu BIST / xorshift, parser và lệnh của
  `tools/bow32_hyperram.py` trên bo giả.
* Build MPS4: timing, kiểm tra CDC (`tcl/timing_checks.tcl`, `report_cdc`), bus skew của 3 FIFO.
* Bo: [../hyperram_mps4.md](../hyperram_mps4.md).

## 8. Giới hạn và bài tập mở rộng

* Một CS#, một thiết bị x8; chưa có HyperRAM 3.0 x16 hay HyperFlash.
* Cửa sổ: một giao dịch bus 32 bit mỗi lần (bus Bow32 một giao dịch treo); băng thông thật đo
  bằng BIST.
* Hiệu chỉnh đọc dùng một pha chung cho mọi bit DQ và RWDS; chưa deskew từng bit (`IDELAYE3`).
* Bài tập: prefetch line kế (burst hybrid: wrap rồi tuyến tính), giao diện AXI4 cho DMA, thực thi
  mã từ HyperRAM (đã chạy được nhờ read buffer), active clock stop.
