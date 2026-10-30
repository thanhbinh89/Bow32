# Bộ thu MIPI CSI-2 (`bow_csi2rx`)

Bộ thu **MIPI CSI-2** của Bow32 nhận ảnh RAW10/RAW8 của cảm biến qua **D-PHY**
1–2 lane và đưa pixel vào ISP dưới dạng AXI4-Stream RAW10, **1 pixel/clock**.
Nó thay MIPI CSI-2 RX Subsystem của AMD trong bitstream `kv260_cam`: không cần
IP hay license của hãng, mọi tầng (D-PHY, SerDes, CDC, protocol) đọc được trong
RTL, và có sẵn công cụ để học và bring-up: bộ đếm lỗi, log packet, word thô của
PHY, bản đồ eye. RTL: `hw/ip/csi2rx/rtl/` (độc lập công nghệ) và I/O của FPGA
`hw/fpga/common/rtl/bow_dphy_io_xusp.sv`. Driver: `sw/common/include/bow_csi2rx.h`.
Mô hình tham chiếu: `tools/csi2/csi2_model.py`. Chạy trên board:
[../camera_kv260.md](../camera_kv260.md).

```
          FPGA (bow_dphy_io_xusp)                     bow_csi2rx
 J9 ──► IBUFDS_DPHY, IDELAYE3,  ──rx_data──► dphy_align ×2 ──► lane_merge ──► packet ───────┐
        ISERDESE3 1:8,          ──byte_clk─► (miền byte, 114 MHz)            (ECC, CRC,     │
        BUFGCE_DIV /1, /4       ──LP {P,N}─► dphy_lp ×3 (miền video)          VC/DT, FS/FE) │
                                ◄── hs_en, byte_ce ───┘   (+ byte_rst, tap)                 ▼
 ISP ◄── m_axis RAW10 (1 pixel/clock) ◄── csi2rx_out ◄── fifo_async ◄────────────────── unpack
                                          (video)        (byte → video)              (RAW10/RAW8)
 bus ◄─► csi2rx_regs (CPU): CTRL, STATUS, IRQ, bộ đếm, DLY, LOG, RAW, FRAME/LINE_TIME, BYTECLK
```

Tên module trong RTL có tiền tố `bow_` (`bow_dphy_lp`, `bow_dphy_align`,
`bow_fifo_async`) hoặc `bow_csi2_` / `bow_csi2rx_` (`bow_csi2_packet`,
`bow_csi2rx_out`...).

| Thông số | Giá trị |
|----------|---------|
| Đầu vào | D-PHY v1.x, 1 hoặc 2 data lane, clock lane liên tục hoặc không; KV260: IMX219, 2 lane × 912 Mbit/s |
| Packet | CSI-2 v1.x: ECC header (sửa 1 bit), CRC-16, VC 2 bit, FS/FE; nhận RAW10 (0x2B) hoặc RAW8 (0x2A) của một VC, packet khác được kiểm CRC rồi bỏ |
| Đầu ra | AXI4-Stream `tdata[9:0]`, `tuser` = pixel đầu frame, `tlast` = cuối dòng (khung của ISP); RAW8 thành `byte << 2`; tôn trọng `tready` |
| Thông lượng | 1 pixel/clock video (200 Mpx/s ở 200 MHz), FIFO 256 nhóm × 4 pixel |
| Clock | CPU `clk_i`, video `vid_clk_i`, byte `byte_clk_i` = HS clock / 4 (chỉ chạy khi có HS) |
| Thanh ghi | peripheral bus `0x4000_8000` (4 KiB), ngắt `irq_fast[7]` |
| Tham số | `Lanes` (1, 2), `PhyClkHz` (tần số `vid_clk_i`), `HasPhy` (có D-PHY), `FifoDepth` (256) |

## D-PHY trong một trang

Mỗi lane là một cặp dây `P`/`N` với hai chế độ:

- **LP** (low power): hai dây được lái riêng, 0 hoặc 1,2 V. Trạng thái ghi
  `{P, N}`: LP-11 = *stop* (nghỉ), LP-01 = xin vào HS, LP-00 = cầu sang HS,
  LP-10 = vào escape mode (Bow32 không hỗ trợ: báo lỗi LP).
- **HS** (high speed): vi sai ~200 mV, bộ thu phải bật **termination 100 Ω**.
  Bit thấp của mỗi byte đi trước.

```
data lane:  LP-11 │ LP-01 │ LP-00   │ HS-0 (HS-ZERO) │ 0xB8 │ byte 0, byte 1 ... │ HS-TRAIL │ LP-11
                    T_LPX   PREPARE   ≥ 145 ns+10 UI   sync                         đảo bit cuối
clock lane: LP-11 │ LP-01 │ LP-00   │ HS-0 (CLK-ZERO) │ clock DDR 456 MHz ...... │ HS-0 (CLK-TRAIL) │ LP-11
                                      PREPARE+ZERO ≥ 300 ns  CLK-PRE trước data,   ≥ 60 ns
                                                             CLK-POST sau data
```

- Một lần vào HS gọi là một **burst**: LP-11 → LP-01 → LP-00 → HS-0 dài
  (HS-ZERO) → **byte sync `0xB8`** (chuỗi `00011101` trên dây) → dữ liệu →
  HS-TRAIL (đảo bit cuối và giữ) → LP-11. Bộ thu bật termination ngay sau
  LP-00, bỏ qua dây trong thời gian *settle*, rồi dò byte sync: word của SerDes
  có pha bit không biết trước. Trail và lúc chuyển về LP sinh vài byte rác, nên
  packet phải kết thúc theo **số byte** trong header, không theo cuối burst.
- Clock lane: clock DDR (912 Mbit/s → 456 MHz, 1 UI = 1,096 ns), vào HS bằng
  cùng chuỗi LP, chạy trước data lane (CLK-PRE) và dừng sau nó (CLK-POST, rồi
  HS-0 trong CLK-TRAIL). Clock **liên tục** ở HS mãi; clock **không liên tục**
  về LP-11 giữa các burst. IMX219 trên KV260 ở giữa: lane clock ở HS suốt một
  frame và chỉ về LP-11 trong vertical blanking (số lần vào HS của lane clock
  = số frame); data lane về LP-11 sau **mỗi packet** (mỗi frame H + 4 burst:
  FS, 2 dòng embedded, H dòng, FE).

| Thời gian (D-PHY v1.2) | Giới hạn | Bow32 (mặc định, video 200 MHz) |
|---|---|---|
| T_D-TERM-EN: bật termination sau LP-00 | ≤ 35 ns + 4 UI | ~34 ns: bộ thu LP 8 ns + 2 sync + 2 lọc + 1 FSM (chu kỳ video) |
| T_HS-SETTLE: bỏ qua dây, tính từ LP-00 | 85 ns + 6 UI … 145 ns + 10 UI | `SETTLE` 14 = 70 ns sau khi thấy LP-00 (~104 ns tính từ chân) |
| T_CLK-PREPARE + T_CLK-ZERO | ≥ 300 ns | `CLK_SETTLE` 30 = 150 ns, rồi mở cổng byte clock (lane vẫn ở HS-0) |
| T_CLK-MISS: phát hiện mất clock | ≤ 60 ns | `CLK_MISS` theo tốc độ lane (driver): 1 chu kỳ byte clock + 3 chu kỳ video = 5 (25 ns) ở 912 Mbit/s → cổng đóng ~30–45 ns sau cạnh cuối |
| T_HS-TRAIL + T_CLK-POST | ≥ ~180 ns (~20 byte clock) | packet cần ~11 byte clock sau byte cuối |

## Nửa FPGA: `bow_dphy_io_xusp`

Chỉ có primitive của UltraScale+ ở chế độ *component* (không có IP D-PHY) và
không có logic fabric; `bow_csi2rx` đăng ký `rx_data` và tap trên byte clock.

```
 clock lane  IBUFDS_DPHY ─HSRX_O─┬─► BUFGCE_DIV /1 ─► hs_clk    ISERDES CLK, CLK_B (đảo)
                                 └─► BUFGCE_DIV /4 ─► byte_clk  ISERDES CLKDIV, IDELAY CLK, bow_csi2rx
 data lane   IBUFDS_DPHY ─HSRX_O───► IDELAYE3 ─► ISERDESE3 1:8 ─► rx_data (Q[0] = bit đến trước)
 mọi lane    LPRX_O_P/N ─────────────────────────────────────────► lp {P, N} (bất đồng bộ)
```

| Primitive / thuộc tính | Vì sao |
|---|---|
| `IBUFDS_DPHY`, IOSTANDARD `MIPI_DPHY_DCI` (bank 66) | một buffer có cả bộ thu HS vi sai lẫn hai bộ thu LP trên cùng chân. `HSRX_DISABLE = ~hs_en` tắt bộ thu HS **và** termination (`HSRX_O = 0` khi tắt); bộ thu LP luôn bật (trễ ~8 ns). Termination đặt bằng `DIFF_TERM_ADV TERM_100` trong XDC |
| 2 × `BUFGCE_DIV` chung CE, `CE_TYPE SYNC` | /1 cho `CLK`/`CLK_B` của ISERDES, /4 = byte clock. Cổng đóng làm hai bộ chia dừng cùng lúc nên /1 và /4 luôn thẳng pha (gate bằng `CLR` thì không). Bộ thu chỉ đổi CE khi lane clock đứng yên ở HS-0, nên CE là false path |
| `CLOCK_DELAY_GROUP bow_dphy_rx_clk` | cân bằng hai cây clock /1 và /4. Đặt trong XDC qua chân `O` của `u_hs_bufg`/`u_byte_bufg`: synthesis của Vivado bỏ attribute trong RTL và còn đổi tên net (ở đây thành `u_dphy/dphy_byte_clk`). Giữ nguyên tên instance |
| `IDELAYE3` `COUNT`, `VAR_LOAD`, `EN_VTC 0`, không IDELAYCTRL | 511 tap × 2,7–4,7 ps > 1 UI ở mọi góc PVT, phần mềm chọn tap lúc chạy. `CLK` **phải** là net `CLKDIV` của ISERDES (nếu không: DRC REQP-1742 báo lỗi ở `write_bitstream` và cặp này không được xếp chung một bitslice), nên tap chỉ được nạp khi byte clock chạy, tức ở burst sau |
| `ISERDESE3` 1:8 DDR, FIFO tắt, `IS_CLK_B_INVERTED 1` | `Q[0]` là bit đến trước; D-PHY gửi LSB trước nên word đã căn chính là byte. Bộ chia /4 bên trong (đẩy `Q` ra) chỉ thẳng pha với `CLKDIV` nhờ `RST`: thừa hay thiếu một cạnh `CLK` (khi clock dừng) làm lệch tới lần `RST` sau, vì vậy `byte_rst` bật khi cổng đóng và nhả 2 byte clock sau khi clock chạy lại, mỗi lần mở cổng |

Static timing của đường bắt data không đạt được: clock đi qua BUFGCE_DIV và
cây clock toàn cục nên tới ISERDES trễ hơn data (đường trong site, 0,44–0,78 ns)
0,4–1,4 ns tuỳ PVT, gần 1 UI. Vì vậy chân data là false path và điểm lấy mẫu
được hiệu chỉnh bằng phần mềm (mục *Hiệu chỉnh eye*). Bản `kv260` cơ bản không
có `bow_dphy_io_xusp`: `bow32_kv260_top` nối mọi lane LP-11, byte clock 0,
`CsiPhy = 0` (`INFO.PHY = 0`).

## Miền clock, reset và CDC

| Miền | Clock | Nội dung |
|------|-------|----------|
| CPU | `clk_i` (50 MHz) | `bow_csi2rx_regs`: thanh ghi, bộ đếm, IRQ, đo thời gian, đọc RAM LOG/RAW |
| Video | `vid_clk_i` (200 MHz trên KV260) | 3 máy trạng thái LP (`hs_en`, `byte_ce`), FIFO phía đọc, đầu ra `m_axis` |
| Byte | `byte_clk_i` (114 MHz ở 912 Mbit/s) | aligner, ghép lane, packet, unpack, FIFO phía ghi, nạp tap, LOG/RAW, đồng hồ đo byte clock |

Byte clock chỉ chạy khi cổng mở (`byte_ce = 1`) **và** lane clock đang chạy:
logic miền byte phải đúng dù clock dừng bất cứ lúc nào. Reset (assert bất đồng
bộ, nhả đồng bộ, `bow_rst_sync`):

| Reset | Clock | Nguồn | Reset cái gì |
|-------|-------|-------|--------------|
| `vrst_n` | video | `vid_rst_ni & rst_ni` | máy trạng thái LP, đồng bộ cấu hình/trạng thái |
| `brst_n` | byte | `vid_rst_ni & rst_ni` | toggle của `bow_cdc_pulse`, bộ đếm req/ack, LOG/RAW, đồng hồ đo, nạp tap, thanh ghi `rx_data` |
| `drst_n` | byte | như trên `& rx_on` | aligner, ghép lane, packet (cả trạng thái frame), unpack, FIFO phía ghi |
| `vdrst_n` | video | như trên `& rx_on` | FIFO phía đọc, `bow_csi2rx_out` |
| `byte_rst_o` | byte | cổng đóng (`byte_ce = 0`) | `RST` của ISERDESE3, nhả 2 byte clock sau khi clock chạy lại |

`rx_on` = `CTRL.PHY_EN & CTRL.RX_EN` (một flop miền CPU). Tắt RX_EN hoặc PHY_EN
reset datapath ngay, kể cả khi byte clock đang dừng; phía byte được nhả ở những
byte clock đầu của burst sau. Packet, dòng, nhóm pixel dở dang, trạng thái frame
và FIFO đều bị xoá. Đồng bộ giữa các miền:

| Tín hiệu | Cách qua | Ghi chú |
|----------|----------|---------|
| cấu hình (CTRL, PHY_CFG) | `bow_sync` từng bit | gần tĩnh, không handshake: đổi LANES/VC/VC_ANY/DT khi RX_EN = 0, PHY_CFG/CLK_FORCE khi PHY_EN = 0 |
| sự kiện (FS, FE, dòng, lỗi, vào HS…) | một `bow_cdc_pulse` mỗi loại | miền byte: ≤ 1 lần mỗi packet/burst (burst cách nhau ≥ ~370 ns); miền video: giới hạn 1 xung / 16 chu kỳ |
| dữ liệu kèm sự kiện (FRAME_INFO, FRAME_SUM, LINE_INFO) | trực tiếp | nguồn giữ nguyên tới sự kiện cùng loại sau; CPU chép khi nhận xung |
| lệnh LOG/RAW | bộ đếm gray 4 bit: req (CPU), ack (byte) | là mức nên chạy được khi byte clock dừng (phục vụ khi có burst); tối đa 15 lệnh treo |
| tap IDELAY | `bow_sync` từng bit, nạp khi ổn định 2 chu kỳ và khác tap đã nạp | chỉ khi byte clock chạy; CNTVALUEOUT về CPU qua `bow_sync` |
| đồng hồ đo byte clock | bộ đếm gray 20 bit | cho `BYTECLK` |
| pixel | `bow_fifo_async` (con trỏ gray) | hai phía reset cùng một nguồn |
| RAM LOG/RAW | `bow_ram_sdp` (ghi ở byte, đọc ở CPU) | CPU đọc sau DONE |

Các bus gray có ràng buộc `set_bus_skew` (mục *Ràng buộc*).

## Pipeline

### Máy trạng thái LP (`bow_dphy_lp`, video, 1 + `Lanes` bản)

```
 Off --en--> WaitStop --LP-11--> Stop --LP-01--> HsRqst --LP-00--> Settle --SETTLE--> Hs
                ^                 |  ^             |  |              |                 |
                +---- LP-10/00 ---+  +---- LP-11 --+  |              +--- LP-11: Stop -+
                +------------------------- LP-10 -----+
```

- Hai bộ thu LP qua `bow_sync`, rồi lọc glitch: mức mới được nhận khi đã thấy
  `LP_FILTER` chu kỳ liên tiếp (0 tính là 1). LP-00 ở chân → `hs_en` sau
  2 + `LP_FILTER` + 1 chu kỳ video.
- `hs_en` (bộ thu HS + termination) bật từ LP-00 sau LP-01 tới LP-11; LP-01,
  LP-10 trong HS bị bỏ qua (khi ở HS, bộ thu LP thấy LP-00).
- Data lane: trạng thái `Hs` cho aligner dò sync. Ở HS quá 2^20 chu kỳ
  (5,2 ms ở 200 MHz) → lỗi LP (watchdog), tắt bộ thu, chờ LP-11.
- Lane clock: sau `CLK_SETTLE` chu kỳ mở cổng (`byte_ce = 1`) trong HS-0 của
  CLK-ZERO, khi chưa có cạnh nào. Đã thấy cạnh byte clock mà `CLK_MISS` chu kỳ
  liên tiếp không có cạnh → đóng cổng trong HS-0 của CLK-TRAIL (trạng thái
  `Trail`, bộ thu còn bật tới LP-11). LP-11 khi cổng còn mở: đóng cổng trước,
  tắt bộ thu 2 chu kỳ sau. Cạnh byte clock được thấy qua một flop miền byte đảo
  mỗi chu kỳ, `bow_sync` sang miền video. Lane clock không có watchdog.
- `PHY_EN = 0`: cổng đóng ngay, bộ thu tắt 8 chu kỳ sau (cũng khi HS clock còn
  chạy, vì vậy `bow_csi2rx_stop` chờ FSM tự đóng cổng trước). `CLK_FORCE = 1`
  (với PHY_EN = 1): bộ thu và cổng lane clock luôn bật, cho cảm biến clock liên
  tục.
- Lỗi LP (`ERR_STATUS.LP`): ở Stop thấy LP-10 (escape) hoặc LP-00 không qua
  LP-01, ở HsRqst thấy LP-10, watchdog.

### Tìm sync, căn byte (`bow_dphy_align`, byte, mỗi data lane)

Với `w24 = {rx, q1, q2}` (3 word cuối, bit j đến sau bit j−1), offset `o` khớp
khi `w24[o +: 8] == 0x00` (HS-zero) và `w24[o+8 +: 8] == 0xB8`; chỉ một offset
khớp được. Việc dò bắt đầu ở cạnh lên của `arm` (`hs_active` của lane, đã đồng
bộ); từ word sau, mỗi chu kỳ ra một byte `{rx, q1}[o +: 8]`, `sot` đi cùng byte
đầu sau sync, cho tới khi `arm` xuống. `arm` xuống mà chưa khớp → lỗi SOT.
Không chấp nhận sync sai 1 bit. `arm` đã cao lúc nhả reset (bật RX giữa burst)
không bắt đầu dò: phải chờ burst sau.

### Ghép lane (`bow_csi2_lane_merge`)

Byte 2k nằm ở lane 0, byte 2k+1 ở lane 1. Mỗi lane có FIFO 8 byte ghi từ `sot`;
đầu ra chạy khi mọi lane đều có byte, rồi lấy mỗi lane một byte mỗi chu kỳ:
lệch lane tới 4 byte được hấp thụ. Mỗi burst đúng một xung `eob` (cả burst không
có dữ liệu). Lỗi SKEW (ở cuối burst, burst bị bỏ): chỉ một số lane khoá được,
hoặc FIFO của một lane tràn trước khi xuất (lệch > 8 byte). Clock không liên tục
có thể dừng trước khi cuối burst tới miền byte; `eob` khi đó đến lúc clock chạy
lại cho burst sau, trước byte đầu của nó (≥ ~20 byte clock).

### Lớp packet (`bow_csi2_packet`)

- 4 byte đầu là header `{DI, WC LSB, WC MSB, ECC}`, DI = `{VC[1:0], DT[5:0]}`.
  ECC (CSI-2 v1.x, 24 bit data + 6 bit parity) được giải trong pipeline 3 tầng
  cạnh luồng byte trễ 3 chu kỳ: syndrome = parity(D) ⊕ ECC[5:0] (ECC[7:6] bỏ
  qua). Syndrome 0 → đúng; bằng cột của một bit data → lật bit đó (đã sửa); chỉ
  một bit 1 → lỗi ở bit parity (đã sửa); còn lại → không sửa được, bỏ phần còn
  lại của burst.
- Short packet (DT 0x00–0x0F) của VC được chọn (`CTRL.VC`, hoặc mọi VC với
  `VC_ANY`): FS bắt đầu frame (số frame = WC; FS trong frame → lỗi FRAME), FE
  hoàn tất frame và chốt `FRAME_INFO`, `FRAME_SUM` (FE không có FS → lỗi FRAME,
  trừ FE trước FS đầu tiên sau khi bật RX). Short packet khác chỉ được đếm và log.
- Long packet (DT ≥ 0x10): WC byte payload rồi CRC (byte thấp trước).
  **Accepted** = VC khớp, DT = `CTRL.DT` và là RAW8/RAW10: payload sang unpack.
  Packet khác vẫn được kiểm CRC rồi bỏ (`CNT_DROP`); 2 dòng embedded (DT 0x12)
  mỗi frame của IMX219 thuộc loại này.
- Packet kết thúc khi đủ header + WC + 2 byte, **không bao giờ** theo `eob`: so
  CRC, sự kiện, LOG; byte sau CRC bị bỏ tới burst sau. `eob` khi packet chưa đủ
  byte → TRUNC (unpack kết thúc dòng). Mỗi burst một packet.
- CRC-16: x^16 + x^12 + x^5 + 1 phản xạ (0x8408), khởi tạo 0xFFFF, không XOR
  cuối (CRC-16/MCRF4XX), 1–2 byte mỗi chu kỳ; chạy qua payload rồi qua 2 byte
  CRC nhận được, kết quả 0 là đúng. Pixel đi trước khi biết CRC: lỗi CRC không
  bỏ dữ liệu.
- FORMAT: dòng accepted với RAW10 có WC % 5 ≠ 0, hoặc RAW8 có WC = 0.

### Unpack (`bow_csi2_unpack`)

```
RAW10: 5 byte -> 4 pixel   P_i = {B_i, B4[2i+1:2i]}        RAW8: P_i = {B_i, 2'b00}
nhóm FIFO, 44 bit: {sof, eol, số pixel - 1 [1:0], px3 .. px0}, px0 ở [9:0]
```

Dòng RAW8 có WC % 4 ≠ 0 kết thúc bằng một nhóm thiếu; byte thừa của RAW10 bị
bỏ. Nhóm cuối được giữ lại một bước để `eol` nằm đúng nhóm cuối (cả khi dòng bị
cắt). `FRAME_SUM` = tổng giá trị 10 bit của mọi pixel đã vào FIFO từ FS tới FE.
FIFO đầy → nhóm bị bỏ, cờ OVF cho packet đó.

### FIFO và đầu ra (`bow_fifo_async`, `bow_csi2rx_out`)

FIFO 2 clock 256 nhóm × 44 bit (1 RAMB36), con trỏ gray qua 2 flop `ASYNC_REG`,
phía đọc kiểu first-word-fall-through. Đầu ra giữ hai nhóm (`cur`, `next`), lấy
nhóm mới khi `next` trống; `tready` chỉ đẩy pixel đi: 1 pixel/clock liên tục,
`tuser` ở pixel 0 của nhóm `sof`, `tlast` ở pixel cuối của nhóm `eol`, mọi
`m_axis_*` ra từ flop.

Thông lượng: đầu ra 200 Mpx/s ở 200 MHz. RAW10 ở 2 × 912 Mbit/s là 182,4 Mpx/s:
vừa. RAW8 là 228 Mpx/s trong burst: FIFO (1024 pixel) hấp thụ phần dư của một
dòng (12 %, dòng 1920 pixel → ~240 pixel) khi các dòng cách nhau một line time
như của IMX219; các dòng RAW8 liền nhau liên tục sẽ làm tràn FIFO (OVF).

## Lỗi và bộ đếm

| `ERR_STATUS` | Bộ đếm | Ý nghĩa | Thường do |
|----|----|----|----|
| [0] SOT | `CNT_SOT` lane 0 / 1 | lane vào HS mà không thấy sync | tap IDELAY ngoài eye |
| [1] ECC_CORR | `CNT_ECC[15:0]` | header sai 1 bit, đã sửa | eye hẹp |
| [2] ECC_ERR | `CNT_ECC[31:16]` | header không sửa được, burst bị bỏ | tap sai |
| [3] CRC | `CNT_CRC[15:0]` | CRC sai (pixel vẫn được đưa ra) | tap sai, nhiễu |
| [4] TRUNC | `CNT_CRC[31:16]` | burst hết trước khi đủ packet | lỗi bit giữa burst, tắt RX giữa packet |
| [5] OVF | `CNT_DROP[31:16]` | FIFO pixel đầy, nhóm bị bỏ | RAW8 liền nhau, `tready` thấp lâu |
| [6] SKEW | `CNT_MISC[31:24]` | các lane không cùng khoá, burst bị bỏ | sync hỏng trên một lane |
| [7] FORMAT | `CNT_MISC[31:24]` | WC không hợp RAW10/RAW8 | cảm biến sai format |
| [8] FRAME | `CNT_MISC[31:24]` | FS trong frame, FE không có FS | mất FS/FE khi đổi tap, đổi VC |
| [9] LP | `CNT_MISC[23:16]` | chuỗi LP sai, watchdog HS | escape mode, nhiễu, dây hở |

`ERR_STATUS` là cờ dính (W1C). Bộ đếm bão hoà, xoá bằng `CNT_CLR`.
`bow_csi2rx_link_errors()` = ECC (cả hai) + CRC + TRUNC + SOT + OVF + misc; link
tốt là 0. Bộ đếm khác: `CNT_FRAME` (FS), `CNT_PKT` (header đúng hoặc đã sửa, mọi
VC/DT), `CNT_LINE`, `CNT_DROP[15:0]`, `CNT_BURST` (số lần vào HS mỗi data lane),
`CNT_MISC[15:0]` (lane clock).

## Bản đồ thanh ghi (`0x4000_8000`)

| Offset | Tên | Truy cập | Bit (giá trị reset) |
|-------:|-----|:--:|-----|
| 0x000 | `ID` | R | `0x43533201` ("CS2", phiên bản 1) |
| 0x004 | `INFO` | R | [3:0] số data lane, [4] PHY (có D-PHY), [15:8] clock video (MHz), [31:16] độ sâu FIFO (nhóm). `kv260_cam`: `0x0100C812`, `kv260`: `0x01003202` |
| 0x008 | `CTRL` | RW | [0] PHY_EN (0), [1] RX_EN (0), [2] LANES: 0 = 1 lane, 1 = 2 lane (1), [3] CLK_FORCE (0), [4] VC_ANY (0), [6:5] VC (0), [13:8] DT (0x2B) |
| 0x00C | `PHY_CFG` | RW | chu kỳ video: [7:0] SETTLE (14), [11:8] LP_FILTER (2), [23:16] CLK_SETTLE (30), [31:24] CLK_MISS (8, 0 = tắt) |
| 0x010 | `STATUS` | R | LP sau bộ lọc `{P,N}`: [1:0] lane clock, [3:2] lane 0, [5:4] lane 1; HS bật: [8] lane clock, [9] lane 0, [10] lane 1; [11] CE (cổng byte clock mở), [12] IN_FRAME, [13] BYTECLK_OK |
| 0x014 | `IRQ_STATUS` | R/W1C | [0] FS, [1] FE, [2] ERR (một bit `ERR_STATUS` được set), [3] LOG_DONE, [4] RAW_DONE |
| 0x018 | `IRQ_EN` | RW | bit giống `IRQ_STATUS` (0); `irq = \|(IRQ_STATUS & IRQ_EN)` → `irq_fast[7]` |
| 0x01C | `ERR_STATUS` | R/W1C | [9:0] cờ dính, xem *Lỗi và bộ đếm* |
| 0x020 | `CNT_CLR` | W | [0] = 1: xoá mọi bộ đếm 0x024…0x044 |
| 0x024 | `CNT_FRAME` | R | số FS của VC được chọn |
| 0x028 | `CNT_PKT` | R | packet có header đúng hoặc đã sửa |
| 0x02C | `CNT_LINE` | R | packet pixel accepted đã đủ byte |
| 0x030 | `CNT_ECC` | R | [15:0] đã sửa, [31:16] không sửa được |
| 0x034 | `CNT_CRC` | R | [15:0] lỗi CRC, [31:16] packet bị cắt |
| 0x038 | `CNT_SOT` | R | lỗi sync: [15:0] lane 0, [31:16] lane 1 |
| 0x03C | `CNT_DROP` | R | [15:0] long packet bị bộ lọc VC/DT bỏ, [31:16] packet bị tràn FIFO |
| 0x040 | `CNT_BURST` | R | số lần vào HS: [15:0] lane 0, [31:16] lane 1 |
| 0x044 | `CNT_MISC` | R | [15:0] số lần vào HS của lane clock, [23:16] lỗi LP, [31:24] lỗi skew + format + frame |
| 0x050 | `FRAME_INFO` | R | frame hoàn chỉnh cuối: [15:0] số dòng, [31:16] số frame (WC của FS) |
| 0x054 | `LINE_INFO` | R | dòng accepted cuối: [15:0] WC, [21:16] DT, [23:22] VC |
| 0x058 | `FRAME_SUM` | R | tổng giá trị pixel của frame hoàn chỉnh cuối |
| 0x05C | `FRAME_TIME` | R | chu kỳ CPU giữa hai FS cuối |
| 0x060 | `LINE_TIME` | R | chu kỳ CPU giữa hai lần kết thúc dòng cuối trong một frame |
| 0x064 | `BYTECLK` | R | [19:0] số byte clock trong 65536 chu kỳ CPU (khi clock chạy) |
| 0x070 | `DLY0` | RW | ghi [8:0] tap lane 0; đọc [8:0] tap đã ghi, [24:16] tap đang dùng (CNTVALUEOUT) |
| 0x074 | `DLY1` | RW | như `DLY0` cho lane 1 (đọc 0 khi `Lanes = 1`) |
| 0x080 | `LOG_CTRL` | RW | ghi: [0] ARM, [1] TRIG_FS, [2] STOP_FE. Đọc: [0] ARMED, [1] TRIG_FS, [2] STOP_FE, [8] DONE, [21:16] WPTR |
| 0x084 | `RAW_CTRL` | RW | ghi: [0] ARM, [1] NOW. Đọc: [0] ARMED, [1] NOW, [8] DONE |
| 0x400–0x4FC | `LOG[0..63]` | R | packet log (bên dưới) |
| 0x800–0x8FC | `RAW[0..63]` | R | [7:0] word lane 0, [15:8] word lane 1 |

W1C: ghi 1 để xoá; nếu phần cứng set đúng chu kỳ đó thì set thắng. Offset không
có thanh ghi đọc ra 0, ghi bị bỏ qua (không bus error). Bộ đếm 32/16/8 bit bão
hoà (`CNT_BURST` đầy sau ~60 frame 1080p).

```
LOG entry: [5:0] DT  [7:6] VC  [23:8] WC (sau khi sửa ECC)
           [25:24] ECC: 0 đúng, 1 đã sửa, 2 không sửa được (header thô)
           [26] lỗi CRC  [27] bị cắt  [28] accepted  [29] tràn FIFO
```

Mỗi packet có header giải được cho một entry, ghi lúc packet kết thúc (long
packet: 3 byte clock sau, để có cờ tràn FIFO); burst bị cắt trước khi đủ header
không có entry.

## Đo thời gian: `FRAME_TIME`, `LINE_TIME`, `BYTECLK`

- `FRAME_TIME`: chu kỳ CPU giữa hai FS cuối của VC được chọn, 0 sau reset tới
  khi thấy 2 FS. `LINE_TIME`: chu kỳ CPU giữa hai lần kết thúc dòng accepted gần nhất
  **trong cùng frame** (mốc reset ở FS).
- Tắt RX xoá các mốc nhưng giữ giá trị thanh ghi: sau khi bật lại, giá trị cũ
  còn thấy tới khi có hai FS mới, nên hãy đọc sau ít nhất hai frame.
- `BYTECLK`: cứ 256 chu kỳ CPU lấy hiệu của đồng hồ gray (mod 2^20), giữ max
  của 256 cửa sổ rồi nhân 256 (cập nhật mỗi 1,3 ms ở 50 MHz). f_byte =
  `BYTECLK` × f_cpu / 65536 (`bow_csi2rx_byteclk_hz()`), độ phân giải
  ~195 kHz, cần burst dài hơn ~2 cửa sổ (10 µs). Trên board đo được
  114,06 MHz (danh định 912/8 = 114 MHz).
- Packet kết thúc theo số byte, nhưng phần việc cuối (so CRC, sự kiện, LOG, CDC)
  cần **~11 byte clock** sau byte dữ liệu cuối. Máy phát đúng D-PHY cho ~20
  (T_HS-TRAIL + T_CLK-POST). Nếu clock dừng sớm hơn, phần việc đó chạy khi
  clock chạy lại ở burst sau: bộ đếm và pixel vẫn đúng, chỉ thời điểm sự kiện
  (và FRAME_TIME/LINE_TIME) bị lệch.

## Debug: STATUS, LOG, RAW, CLK_FORCE

- `STATUS`: PHY bật, cảm biến standby → `0x003F` (mọi lane LP-11). Lane nằm ở
  LP-00 mãi: IMX219 sau khi bật nguồn chưa stream lần nào, vì vậy
  `imx219_probe()` stream 100 µs rồi dừng (như probe của Linux).
- LOG: 64 entry, một entry mỗi packet:

  | `LOG_CTRL` (ghi) | Ghi gì | Kết thúc |
  |---|---|---|
  | `ARM` | 64 packet kế tiếp | entry thứ 64 |
  | `ARM` + `TRIG_FS` | 64 packet từ FS kế tiếp của VC được chọn | entry thứ 64 |
  | `ARM` + `STOP_FE` | vòng tròn | sau khi log một FE của VC được chọn; `WPTR` = entry cũ nhất (0 nếu chưa quay vòng) |
  | `ARM` + `TRIG_FS` + `STOP_FE` | từ FS tới FE | FE, tối đa 64 entry |

  `ARMED` = đang chờ; xong thì `DONE = 1` và `IRQ_STATUS.LOG_DONE`. ARM khi
  đang chờ thì bắt đầu lại. `bow_csi2rx_log()` trả entry theo thứ tự thời gian,
  `bow_csi2rx_print_log()` in mỗi entry một dòng `<i> vc<v> dt <xx> <tên> wc <n>`
  cùng các cờ `ecc-corrected`, `ecc-error`, `crc-error`, `truncated`,
  `accepted`, `overflow`. Một frame IMX219 bình thường: FS (wc = số frame),
  2 × EMB (dt 12), H dòng RAW10 `accepted`, FE.
- RAW: 64 word liên tiếp `{lane 1, lane 0}` từ chu kỳ `hs_active` của lane 0
  lên (ARM) hoặc ngay lập tức (NOW): thấy HS-zero, byte sync ở một pha bit bất
  kỳ và header. Lệnh `raw` của `csi2_test` in các word và tìm byte sync
  (`sync byte at bit …`).
- Lệnh LOG/RAW là mức: ARM khi byte clock dừng vẫn được phục vụ ở burst sau.
  DONE đến 2 byte clock sau word cuối; nếu clock dừng ngay sau đó, DONE đến ở
  burst kế tiếp.
- `CLK_FORCE`: cảm biến clock liên tục đã ở HS lúc bộ thu bật thì lane clock
  không bao giờ đi qua LP-11 → LP-01 → LP-00. `CLK_FORCE = 1` bật bộ thu và cổng
  lane clock ngay khi PHY_EN = 1. IMX219 không cần. Chỉ đặt khi lane clock
  **đã ở HS**: termination và cổng khi đó bật cả ở trạng thái LP (cạnh rác
  của bộ thu HS lọt vào byte clock), và `ISERDESE3` chỉ được reset (căn lại
  clock /4 bên trong) một lần mỗi lần bật PHY_EN.

## Hiệu chỉnh eye

Vì clock trễ 0,4–1,4 ns so với data tuỳ chip và nhiệt độ, không có tap cố định
dùng được cho mọi board: `bow_csi2rx_calibrate(step, tap_ms, &cal, verbose)`
tìm tap IDELAY của mỗi data lane trong lúc cảm biến stream (nội dung bất kỳ).

1. Một điểm đo: ghi `DLY0`/`DLY1`, chờ CNTVALUEOUT = tap (cần một burst; hết
   giờ = không có byte clock → huỷ), chờ 50 µs (sự kiện của burst cũ), xoá bộ
   đếm và `ERR_STATUS`, rồi tap **tốt** nếu `CNT_LINE` đạt 32 trước lỗi đầu
   tiên (SOT, ECC_CORR, ECC_ERR, CRC, TRUNC, SKEW), **xấu** ở lỗi đầu tiên hoặc
   sau `tap_ms`. Lỗi FRAME không tính (frame mất FS ở tap trước kết thúc bằng
   FE không có FS). `tap_ms` ≥ 1,2 × chu kỳ frame + 2 ms: một tap có thể phải
   chờ hết vertical blanking.
2. Pass 1: hai lane cùng tap, tap 0…511 bước `step`. Không có eye chung (lệch
   lane lớn): lane 1 cố định ở 0, 128, 256, 384 và quét lane 0, lấy tổ hợp đầu
   tiên có eye.
3. Pass 2: quét từng lane, lane kia ở tâm của pass 1.
4. Chọn dải tap tốt dài nhất (không quay vòng 511 → 0); dải không chạm đầu nào
   (0 hay 511) được ưu tiên nếu dài ít nhất một nửa (eye có thể còn tiếp ngoài
   dải quét). Tap = tâm dải, độ rộng = số điểm × `step`.
5. Nạp kết quả, chờ một FE, xoá bộ đếm và `ERR_STATUS`. Thất bại: trả lại tap
   cũ và `false`.

Bản đồ đo trên KV260 (`csi2_test`, bước 8, 64 điểm = tap 0, 8, …, 504; `#` =
32 dòng không lỗi ở tap đó):

```
lanes |###......################################......#################| tap 196 width 256
lane0 |####.....##################################....#################| tap 204 width 272 (other lane at 196)
lane1 |###.....#################################....###################| tap 192 width 264 (other lane at 196)
```

Mỗi lane có ~260 tap tốt (~0,94 ns). Mẫu lặp lại sau ~304 tap = 1 UI (1096 ps),
tức ~3,6 ps/tap. Tap chọn được 204/192. Tap reset 0 tình cờ nằm trong vùng tốt
nhưng chỉ cách mép ~24 tap, nên ứng dụng `camera` hiệu chỉnh ở `cam` đầu tiên
(bước 16: `csi2rx: calibrated taps 208/200 eye 272/256`) và chỉ làm lại khi
`bow_csi2rx_link_check()` thấy lỗi ở lần `cam` sau. Tap được giữ trong thanh
ghi qua stop/start, mất khi reset SoC.

## Ràng buộc và kiểm tra sau build (`kv260_cam`)

| Ràng buộc (`constr/kv260_cam.xdc`) | Tác dụng |
|---|---|
| `PACKAGE_PIN` D7/D6, E5/D5, G6/F6 | lane clock, lane 0, lane 1 của J9 (bank 66), như platform của AMD |
| `IOSTANDARD MIPI_DPHY_DCI`, `DIFF_TERM_ADV TERM_100` | bộ thu D-PHY (HS + LP) trong bank HP; termination 100 Ω bật/tắt cùng `HSRX_DISABLE` |
| `create_clock -name dphy_hs_clk -period 2.193` trên `clk_p` | HS clock 456 MHz; Vivado tự suy ra byte clock /4 (`dphy_byte_clk`, 8,772 ns) và clock /4 bên trong ISERDES (`dphy_hs_clk_DIV4_INV`) |
| `set_clock_groups -asynchronous`: `clk_sys`, `clk_vid`, `dphy_hs_clk` + clock suy ra | mọi đường giữa các nhóm đi qua bộ đồng bộ, bus gray hoặc RAM 2 clock; gồm cả bộ thu LP của chân clock (lấy mẫu ở `clk_vid`) |
| `set_false_path -from` chân data | bắt data không có static timing (eye hiệu chỉnh lúc chạy); bộ thu LP của chân data được đồng bộ ở `clk_vid` |
| `set_false_path -to` chân CE của hai BUFGCE_DIV | CE là flop `clk_vid`, FSM chỉ đổi nó khi lane clock đứng yên ở HS-0 (PHY_EN = 0 đóng cổng ngay, nên driver chờ `STATUS.CE` = 0 trước khi xoá PHY_EN) |
| `CLOCK_DELAY_GROUP bow_dphy_rx_clk` | cân bằng cây clock /1 và /4; net được tìm qua chân `O` của buffer |
| 7 × `set_bus_skew` | bus gray (clock group không che `set_bus_skew`): con trỏ ghi FIFO 8,7 ns, con trỏ đọc 5 ns, đồng hồ đo byte clock 8,7 ns, req/ack LOG/RAW 5 ns; đích là flop đồng bộ đầu tiên |

`tcl/build.tcl` ghi thêm `clocks.rpt`, `clock_interaction.rpt`,
`check_timing.rpt`, `methodology.rpt`, `drc.rpt`, `bus_skew.rpt`, chép
`clockInfo.txt`, và in `CRITICAL WARNING` khi timing không đạt (setup, hold
hoặc pulse width: dòng kết luận của `timing_summary.rpt`), khi bus skew bị vi
phạm hoặc không đủ 7 `Slack (MET)` (ràng buộc mất cell vì RTL đổi tên sẽ biến
mất khỏi báo cáo), khi `CLOCK_DELAY_GROUP` không có đủ 2 net, hoặc khi không
có `clockInfo.txt` để kiểm tra. Bản hiện tại
(Vivado 2025.2): WNS +1,023 ns (`clk_vid` 200 MHz), WHS +0,010 ns, byte clock
WNS +4,683 ns, bus skew 7/7 đạt (lệch thật 0,36–0,95 ns), 0 lỗi DRC. Cảnh báo
bình thường: [../camera_kv260.md](../camera_kv260.md) mục 3.

## Driver

```c
#include "bow32.h"      /* bow_csi2rx.h */
#include "imx219.h"     /* driver cảm biến, sw/common */

uint32_t lanes;
bool phy;
if (!bow_csi2rx_probe(&lanes, &phy) || !phy) return;   /* bitstream không có D-PHY */

bow_csi2rx_start(2, CSI2_DT_RAW10, IMX219_LANE_RATE);  /* TRƯỚC stream-on: phải thấy LP-11 */
imx219_configure(1920, 1080, 1763);         /* 1080p30 */
imx219_stream(true);
if (!bow_csi2rx_link_check(64, 200)) {      /* 64 packet không lỗi? */
  bow_csi2rx_cal_t cal;                     /* tap_ms >= 1,2 frame + 2 ms */
  bow_csi2rx_calibrate(16, 42, &cal, true);
}
bow_csi2rx_wait_frame(100);                 /* FE kế tiếp */
uint32_t h = CSI2RX_FRAME_LINES(CSI2RX->FRAME_INFO);   /* 1080 */
bow_csi2rx_print_status();                  /* "csi2rx: link ok" ... */

imx219_stream(false);
bow_csi2rx_stop(34 + 10);                   /* SAU stream-off: chờ hết frame đang gửi */
```

| Hàm | Việc |
|-----|------|
| `bow_csi2rx_probe(&lanes, &phy)` | kiểm tra `ID`, đọc `INFO`; `false` nếu không có bộ thu (bitstream cũ: bus error được bắt) |
| `bow_csi2rx_start(lanes, dt, lane_rate)` | `PHY_CFG` theo `INFO` MHz và tốc độ lane (bit/s, ví dụ `IMX219_LANE_RATE`): SETTLE 70 ns, CLK_SETTLE 150 ns, LP_FILTER 2, CLK_MISS = 1 chu kỳ byte clock (8 UI) + 3 chu kỳ video; `CTRL` = PHY_EN + RX_EN + lane + DT (VC 0), xoá bộ đếm và cờ |
| `bow_csi2rx_stop(ms)` | gọi sau stream-off: chờ hết frame (FE, hoặc IN_FRAME = 0 và không có burst mới trong 2 line time), chờ FSM lane clock đóng cổng (`STATUS.CE` = 0, tối đa 1 ms), rồi `CTRL = 0`; giữ tap |
| `bow_csi2rx_set_rx(on)` | chỉ RX_EN, quanh việc đổi VC/DT |
| `bow_csi2rx_clear()` | xoá bộ đếm và `ERR_STATUS` |
| `bow_csi2rx_counters(&c)`, `bow_csi2rx_link_errors(&c)` | đọc bộ đếm; tổng lỗi link |
| `bow_csi2rx_link_check(n, ms)` | xoá bộ đếm, `true` khi có `n` packet không lỗi |
| `bow_csi2rx_wait_frame(ms)` | chờ FE kế tiếp của VC được chọn |
| `bow_csi2rx_set_delay(lane, tap)`, `bow_csi2rx_wait_delay(ms)` | ghi tap; chờ tới khi mọi lane dùng tap đã ghi (cần một burst) |
| `bow_csi2rx_calibrate(step, tap_ms, &cal, verbose)` | hiệu chỉnh eye; `verbose` in một dòng bản đồ mỗi lần quét |
| `bow_csi2rx_log(e, mode, ms)`, `bow_csi2rx_print_log(e, n)` | LOG theo thứ tự thời gian, số entry (0 = hết giờ) |
| `bow_csi2rx_raw(w, now, ms)` | 64 word thô mỗi lane |
| `bow_csi2rx_byteclk_hz(ms)` | tần số byte clock (max của `BYTECLK` trong `ms`) |
| `bow_csi2rx_print_status()` | `csi2rx: link ok` / `link errors` / `no data`, bộ đếm, thời gian, PHY; byte clock đo trong 1 frame + 2 ms (clock không liên tục dừng suốt vertical blanking, `BYTECLK` chỉ nhìn 65536 chu kỳ CPU) |

Quy tắc: đổi LANES/VC/VC_ANY/DT khi RX_EN = 0, PHY_CFG và CLK_FORCE khi
PHY_EN = 0; bật bộ thu trước khi cảm biến stream và tắt sau khi cảm biến gửi
xong frame cuối; tap ghi vào `DLYn` có hiệu lực ở burst sau. Ngắt: `IRQ_EN`,
`bow_irq_fast_enable(BOW32_IRQ_FAST_CSI2RX)` (mcause `0x80000017`), ISR ghi 1 vào
`IRQ_STATUS` để xoá (ví dụ: `sw/apps/csi2_test/main.c`).

## Kiểm chứng

| Mức | Cách chạy | Kiểm tra |
|-----|-----------|----------|
| Mô hình Python | `make test-tools` (`tools/tests/test_csi2_model.py`, 19 test) | vector ECC/CRC, mọi lỗi 1 bit và 2 bit của header, RAW10, aligner ở mọi pha bit, luật của bộ thu, chế độ LOG; checker bắt được lỗi cài vào |
| IP (Verilator) | `make -C hw/ip/csi2rx/dv test` (cũng trong `make test-ip` và CI) | 30 case: 20 random (seed 1–4 × {2 lane, 2 lane + lỗi, 1 lane + lỗi, 1 trên 2 lane, 1 trên 2 lane + lỗi}, xen kẽ RAW8 và clock liên tục) + directed `lp`, `watchdog`, `clk`, `cmd`, `ovf`, `stop`, `byteclk`, `eye` (`cmd`, `stop` thêm với 1 lane). Pixel (`tuser`/`tlast`), bộ đếm, FRAME/LINE_INFO, FRAME_SUM, FRAME/LINE_TIME, LOG so với mô hình; bất biến PHY (LP-00 → `hs_en` ≤ 4 + LP_FILTER chu kỳ, CE chỉ đổi khi lane clock tĩnh) |
| FPGA, mức chân (xsim) | `source <Vivado>/settings64.sh; make -C hw/fpga/common/dv test` | unisim `IBUFDS_DPHY`, `IDELAYE3`, `ISERDESE3`, `BUFGCE_DIV`; máy phát D-PHY từng bit ở 912 Mbit/s, clock không liên tục: word ISERDES, không có xung runt, CE chỉ đổi ở HS-0, `RST` mỗi burst ≥ 20 byte clock trước sync, `DLY` → CNTVALUEOUT, pixel và thanh ghi. Cần Vivado, không chạy trong CI; eye không mô phỏng được (unisim không có lệch clock/data) |
| Hệ thống | `make run TEST=camera`, `make run TEST=csi2` | firmware thật với `csi2_tx_model.sv` và mô hình IMX219 ([../simulation.md](../simulation.md)) |
| Board | `csi2_test`, lệnh `test` | bên dưới |

Mô hình Python được viết từ đặc tả và quy tắc MIPI, **không** từ RTL, để hai
bên kiểm tra lẫn nhau: `csi2_model.py gen` sinh `cfg.txt`/`stim.txt`, testbench
`tb_bow_csi2rx.sv` lái `csi2_tx_model.sv` (cảm biến + I/O của board) và ghi
`out.txt`/`regs.txt`, `csi2_model.py check` so sánh. `make -C hw/ip/csi2rx/dv run
SEED=7 LANES=1 ERRORS=1` (thêm `DUT_LANES=1|2`, `RAW8=1`, `CONTCLK=1`) hoặc
`make -C hw/ip/csi2rx/dv run TEST=clk` chạy một case và giữ file trong
`build/csi2rx_dv/<case>/`. Với `SEEDS="1 2 … 40"`: 210/210 case đạt (~195k
pixel, ~17,5k lần so thanh ghi, mọi vị trí lỗi 1 bit của header).

Trên KV260 + Raspberry Pi camera v2 (J9), 2026-10-30:

- `csi2_test`, lệnh `test`: `csi2_test: PASS (16/16)`: phy-idle; link-up,
  calibrate, integrity, packets, timing ở 1080p30 rồi 720p60; isp, raw8,
  filter, restart, irq.
- 2 lane × 912 Mbit/s, `BYTECLK` 114,06 MHz; frame 33326 µs (1080p30) và
  16653 µs (720p60), dòng 18,86–18,94 µs; `FRAME_SUM` đúng từng bit (1080p màu
  đơn `0x3d2e1c00`, 720p `0x1b30f000`); không có lỗi ECC/CRC/SOT/TRUNC trong
  nhiều phút; 2 dòng embedded mỗi frame vào `CNT_DROP`.
- Ứng dụng `camera`: AE/AWB hội tụ, ảnh PNG 1080p30 và 720p60 đúng, ISP không
  báo lỗi.

## Tài nguyên (`kv260_cam`, Vivado 2025.2)

| Khối | LUT | FF | Khác |
|------|----:|---:|------|
| `bow_csi2rx` | 1740 (72 LUTRAM) | 2234 | 1 RAMB36 (FIFO pixel) |
| ↳ `bow_csi2rx_regs` | 673 | 758 | |
| ↳ `bow_csi2_packet` | 293 | 326 | |
| ↳ 3 × `bow_dphy_lp` | 256 | 121 | |
| ↳ `bow_csi2_unpack` | 96 | 166 | |
| ↳ `bow_csi2_capture` (LOG, RAW) | 94 (56 LUTRAM) | 100 | |
| ↳ `bow_csi2_lane_merge` | 75 (16 LUTRAM) | 43 | |
| ↳ `bow_fifo_async` | 31 | 70 | 1 RAMB36 |
| ↳ `bow_csi2rx_out` | 17 | 105 | |
| `bow_dphy_io_xusp` | – | – | 3 `IBUFDS_DPHY`; mỗi lane 1 `IDELAYE3` + 1 `ISERDESE3` chung một `BITSLICE_RX_TX`; 2 `BUFGCE_DIV` |

So sánh: Ibex 3593 LUT, ISP 3780 LUT; cả thiết kế 10001 LUT, 12273 FF.

## Giới hạn

- Chỉ nhận: không có escape mode, ULPS, turnaround hay LP data (LP-10 từ Stop
  là lỗi LP).
- Mỗi HS burst một packet: byte sau CRC bị bỏ tới burst sau. IMX219 về LP-11
  sau mỗi packet; cảm biến gửi nhiều packet trong một burst cần sửa lớp packet.
- 1–2 lane, VC 2 bit (CSI-2 v1.x, không có VCX của v2.0), một VC/DT tại một
  thời điểm, ISP chỉ nhận RAW8/RAW10.
- 1 pixel/clock: RAW8 liền nhau ở 2 × 912 Mbit/s (228 Mpx/s) nhanh hơn
  200 Mpx/s; chỉ ổn khi các dòng có khoảng nghỉ.
- Tốc độ lane ≥ ~350 Mbit/s (đã kiểm chứng 770–1050 Mbit/s trong DV, 912 Mbit/s
  trên board). Lý do, đều ở phía tốc độ thấp: (a) bộ thu thấy hoạt động của
  lane clock qua cạnh byte clock (8 UI một cạnh), nên `CLK_MISS` = n phải dài
  hơn một chu kỳ byte clock (driver tính theo `lane_rate`); cổng đóng muộn
  nhất ~20 + 5n ns sau cạnh cuối (45 ns ở 912 Mbit/s), vượt T_CLK-TRAIL tối
  thiểu 60 ns khi dưới ~333 Mbit/s (máy phát có T_CLK-TRAIL dài hơn thì vẫn
  được); (b) cuối burst, các byte còn trong pipeline ISERDES → aligner → ghép
  lane (~5–6 byte clock) phải ra trước khi `arm` tắt, mà T_HS-TRAIL + phát hiện
  LP-11 chỉ dài ~8 byte clock ở 912 Mbit/s và ngắn dần (tính theo byte clock)
  khi tốc độ giảm: dưới ~220 Mbit/s packet bị cắt cụt; (c) `SETTLE` cố định
  70 ns, trong khi T_HS-SETTLE tối thiểu là 85 ns + 6 UI và aligner nhìn lùi
  2 word: ở tốc độ thấp nhiễu của HS-PREPARE có thể khớp sync giả (mô phỏng
  của review).
- Nhiều packet trong một burst: packet sau packet đầu bị bỏ **không có cờ báo**
  nào. Nếu có frame mà không có dòng nào, `bow_csi2rx_print_status()` báo
  `csi2rx: no lines (DT/VC filter?)` (cũng là triệu chứng khi `CTRL.DT`/`VC`
  không khớp luồng).
- `CLK_FORCE` chỉ dùng khi lane clock đã ở HS (xem mục Debug).
- Tap ở chế độ COUNT, không bù nhiệt/áp (`EN_VTC 0`): điểm lấy mẫu trôi theo
  nhiệt độ, và chỉ được hiệu chỉnh lại khi được gọi (`cam` thấy lỗi, lệnh `cal`).
  Hiệu chỉnh cần cảm biến đang stream.
- Thời gian bật termination theo clock video (~34 ns ở 200 MHz, sát giới hạn
  35 ns + 4 UI): clock video thấp hơn hoặc `LP_FILTER` > 2 làm nó trễ hơn.
- Cấu hình qua `bow_sync` từng bit, không handshake: phải theo quy tắc đổi cấu
  hình khi RX/PHY tắt.

## Bài tập mở rộng

- 4 lane: `Lanes = 4` trong ghép lane và lớp packet (4 byte/chu kỳ), thêm I/O;
  RAW10 ở 4 × 912 Mbit/s là 365 Mpx/s, cần đầu ra (và ISP) 2 pixel/clock.
- RAW12 (DT 0x2C, 3 byte → 2 pixel) với đầu ra 12 bit; YUV422 8 bit (DT 0x1E).
- Nhiều packet trong một burst (đọc header kế tiếp sau CRC) và LS/LE.
- Thống kê, ngắt theo dòng/frame: ngắt mỗi N dòng, min/max của `LINE_TIME`,
  jitter của `FRAME_TIME`, đếm frame hỏng.
- Tự hiệu chỉnh lại eye: ISR theo dõi `ECC_CORR`/`CRC`, hoặc liên tục dò hai
  mép eye (±k tap) để bám theo trôi nhiệt.
- Deskew của D-PHY v1.2 (burst `0101…`, cần từ 1,5 Gbit/s) để hiệu chỉnh bằng
  phần cứng thay vì đếm dòng.
- Lane chậm (80–350 Mbit/s): xả pipeline ở cuối burst (aligner xuất nốt word
  cuối, ghép lane pop hết FIFO rồi mới `eob`), và phát hiện mất clock bằng
  chính HS clock thay vì byte clock.
- ULPS và escape mode: nhận biết vào/ra ULPS, đọc LP data (LPDT).
- Kiểm chứng formal (SymbiYosys) cho `bow_fifo_async` và giao thức req/ack gray.
