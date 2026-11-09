# Bo mở rộng FMC+_DDR2_HyperRam: review và khả năng lắp trên Arm MPS4 / Huins MFP-VP1902

Tài liệu trả lời ba câu hỏi về bo RAM mở rộng tự thiết kế
`docs/fpga/ram_extension/FMC_DDR2_HyperRam.PDF` (ThinhHC, 28/10/2026: 9 trang schematic, bản in
PCB, ảnh 3D, BOM):

1. Schematic, PCB và BOM của bo còn vấn đề gì, cả phần DDR2 lẫn phần HyperRAM (mục 2)?
2. Bo lắp và chạy được trên **Arm MPS4** (mục 3) và **Huins MFP-VP1902** (Versal Premium
   VP1902, mục 4) không, cần làm gì trên mỗi board?
3. Trên mỗi board, chức năng nào của IP DDR2/3 (`bow_ddr`) và HyperRAM (`bow_hyperram`) test
   được bằng bo này (mục 5)?

[ddr_board_review.md](ddr_board_review.md) (2026-11-04) đã review phần DDR2 và xét ba board
KV260 / VEK280 / MPS4. Tài liệu này review lại cả bo (thêm HyperRAM, cơ khí, BOM), giữ số hiệu
#1..#10 của tài liệu đó khi một phát hiện trùng, đánh số phát hiện mới từ N1, và thêm Huins.

**Nguồn.** Schematic và BOM của bo; Arm MPS4 TRM 102577 issue 02, trang FMC của schematic
HBI-0376, pin list `hpi0376b_FPGA_ALL_PINS.xlsx`; Huins MFP-VP1902-S user guide V2.31,
schematic V2.2, netlist (`docs/fpga/Huins_MFP-VP1902/`); datasheet TI TXV0108 (SCES959A),
Infineon S80KS2562; JESD79-2 (DDR2). Tài liệu của Huins ghi là tài liệu mật: thư mục đó chỉ là
bản sao cục bộ, bị `.gitignore` như tài liệu Arm/AMD; ở đây chỉ dùng kết luận và dữ liệu ở mức
chân FMC / bank, không chép bảng chân FPGA của Huins.

**Cách kiểm.**

* Đọc từng trang schematic ở 150–300 dpi, đối chiếu ballout DDR2 x8 60 ball (JEDEC) và
  S80KS2562 24 ball, đối chiếu từng đầu vào/ra của TXV0108 với datasheet.
* Script đối chiếu 53 chân FPGA mà bo dùng (37 DDR2 + 16 HyperRAM): schematic (trang 6–8) ↔
  `hw/fpga/mps4/constr/{ddr,hyperram}_card.xdc` ↔ pin list của Arm: **53/53 khớp**; schematic ↔
  netlist Huins của cả 8 khe FMC+: **53/53 chân có ở mọi khe**, số chân đầu nối trùng.
* Vivado 2025.2 trên `xcvp1902-vsva6865-2MP-e-S` (đúng FPGA của Huins): wrapper chân thật của
  hai PHY đặt lên chân bo của khe FMC+01 (mục 4.3).

## 1. Kết luận

| | Arm MPS4 | Huins MFP-VP1902 |
|-|----------|------------------|
| Đầu nối | J11 = Samtec ASP-184329-01 (FMC+ HSPC), nối 400/560 chân: hàng A–K đủ LA/HA/HB | 8 khe FMC+ (Samtec SEAF 14 hàng = HSPC), mỗi khe đủ LA00–33, HA00–23, HB00–21, CLK0–3 |
| 53 chân của bo | tới FPGA đủ: LA ở bank 69/70, HB ở bank 71 (HP) | tới FPGA đủ ở cả 8 khe: mỗi khe 3 bank XPIO (FMC+01: 704/705/706) |
| VADJ (phía FPGA của TXV0108) | 1V2 / 1V5 / 1V8 do MCC cấp; bo không có EEPROM nên phải đặt `FMC_FORCE` trong `config.txt` (thẻ dùng chung đang `1V2` cho nhóm FU3) | VCCIO từng khe 1,0 / 1,2 / 1,5 V bằng slide switch, **mặc định 1,5 V**; 4 chân VADJ nối 0 Ω vào nguồn của khe |
| Chuẩn I/O | `LVCMOS15` (XDC hiện có), hoặc `LVCMOS18` nếu dùng VADJ 1,8 V (mục 3.3) | chỉ `LVCMOS15`: XPIO tối đa 1,5 V, Vivado từ chối `LVCMOS18` (DRC BIVB-1) |
| 3P3V / 12P0V | 2,5 A / 1 A (TRM bảng B-1); bo cần dưới 0,3 A ở 3P3V, không dùng 12 V | có cả hai |
| Bitstream Bow32 | có sẵn bản bo RAM (`make fpga BOARD=mps4 DDR_LOOPBACK=0`: DDR2 + HyperRAM trên khe FMC+), đạt timing (2026-11-08), **chưa chạy với bo thật** | chưa có target; Vivado cho thấy PHY của Bow32 đặt và đi dây được trên chân bo sau một sửa nhỏ ở wrapper chân; máy build còn phải sửa để sinh được PDI (mục 4.3) |
| Lắp được | được, kiểm cơ khí trước (N2) | được, kiểm cơ khí trước (N2) |
| Test được | **ngay**, sau khi đổi `FMC_FORCE` (cần nhóm FU3 đồng ý) | **sau khi port** Bow32 sang Versal (mục 4.4) |

Đề xuất thứ tự: (1) chạy bo trên MPS4 bằng bản build có sẵn; (2) port Bow32 sang Huins song
song; (3) gom các sửa của mục 6 cho lần làm bo sau.

> **Cảnh báo (cả hai board): chỉ cấp nguồn cho bo khi VADJ ≥ 1,5 V.** DIR và OE# của TXV0108
> tham chiếu VCCA = 1,8 V (VIH = 0,7 × VCCA = 1,26 V). Ở VADJ 1,2 V (MPS4 `FMC_FORCE: 1V2` như
> thẻ đang để, Huins slide switch ở 1,0 / 1,2 V) cả FPGA lẫn điện trở kéo lên của OE# đều không
> còn đưa được hai chân này lên mức cao: level shifter có thể bật khi lẽ ra phải cách ly, DIR
> kẹt ở chiều ghi và level shifter giành bus với DRAM / HyperRAM khi chúng trả dữ liệu. Chỉ cắm
> hoặc rút bo khi board đã tắt nguồn.

## 2. Review schematic, PCB và BOM

Bo gồm: S80KS2562 (HyperRAM 2.0 x8, 32 MiB, 1,8 V) và IS43DR86400E-25DBL (DDR2 512 Mb x8,
64 MiB) sau 8 level shifter TXV0108 (phía A = bộ nhớ 1,8 V, phía B = FPGA ở VADJ); hai LDO
TLV75718 lấy 1,8 V từ 3P3V (một cho DDR2, một cho HyperRAM); 4 LED báo nguồn; đầu nối FMC+
HSPC ASP-184330-01.

| IC | Phía A (1,8 V) | Phía B (VADJ) | DIR |
|----|----------------|---------------|-----|
| U5 | DDR2 DQ0..7 | `FMC_DDR2_DQ0..7` | `FMC_DDR2_DQ_DIR` (LA05_P), kéo xuống 10k |
| U9 | DDR2 DQS, DQS# | `FMC_DDR2_DQS_P/N` | `FMC_DDR2_DQS_DIR` (LA05_N), kéo xuống 10k |
| U10 | CK, CK#, CKE, CS#, RAS#, CAS#, WE#, ODT | LA02..LA17 | nối GND (FPGA → DRAM) |
| U11, U12 | A0..A13, BA0, BA1 | LA13..LA33 | nối GND |
| U4 | HyperRAM DQ0..7 | `FMC_HB_DQ0..7` | `FMC_HB_DIR` (LA08_P), kéo xuống 10k |
| U6 | HyperRAM CK, CK#, CS#, RESET# | HB06, HB21 | nối GND |
| U8 | HyperRAM RWDS | `FMC_HB_RWDS` (HB10_P) | `FMC_HB_RWDS_DIR` (LA14_N), kéo xuống 10k |

OE# chung cho mỗi bộ nhớ: `FMC_DDR2_OE_N` (LA10_P, 5 IC) và `FMC_HB_OE_N` (LA08_N, 3 IC), mỗi
IC một điện trở 10k kéo lên +1V5 (= VADJ).

### 2.1 Những phần đã đúng

* **Ballout và nguồn DDR2.** Đúng ballout x8 60 ball: VDD A1/E9/H9/L1, VDDQ A9/C1/C3/C7/C9,
  VDDL E1, VREF E2, VSS/VSSQ/VSSDL đủ; G1 (BA2), L3, L7 và A2 (RDQS#) để trống. VREF = VDDQ/2
  bằng 1k/1k 1 % + 0,1 µF; 10 × 0,1 µF + 10 µF. CKE và ODT kéo xuống, CS# kéo lên ở phía
  DRAM: DRAM yên khi level shifter cách ly (OE# = 1), CKE thấp lúc cấp nguồn như JESD79-2 yêu
  cầu.
* **Ballout và nguồn HyperRAM.** Đúng ballout S80KS2562 24 ball; CS# và RESET# kéo lên 10k
  (thiết bị không được chọn khi level shifter cách ly); RFU để trống; 3 × 0,1 µF + 10 µF.
* **Điện trở nối tiếp 22 Ω** phía bộ nhớ trên CK, DQS, DQ của DDR2 và trên CK, RWDS, DQ của
  HyperRAM (cộng 10 Ω tích hợp trong đầu ra TXV0108).
* **TXV0108.** Kênh không dùng (U6, U8, U9) nối GND ở cả hai phía: dù DIR ở chiều nào, đầu ra
  của kênh đó cũng lái mức thấp (vì đầu vào đối diện là GND) vào chính GND, không tranh chấp.
  Mỗi IC có 1 µF + 0,1 µF cho mỗi nguồn. DIR kéo xuống (chiều FPGA → bộ nhớ) và OE# kéo lên: bo
  an toàn khi FPGA chưa nạp cấu hình. Khi một trong hai nguồn dưới 100 mV mọi chân của TXV0108 ở
  trạng thái trở kháng cao (VCC isolation), nên 3P3V và VADJ bật theo thứ tự nào cũng được.
* **Đầu nối.** VADJ ở cả bốn chân E39/F40/G39/H40; 3P3V ở C39/D36/D38/D40/Z40; PRSNT_M2C_L và
  HSPC_PRSNT_M2C_L nối GND; TDI–TDO nối vòng (không cắt chuỗi JTAG của carrier); PG_M2C để
  carrier tự kéo lên (R49 không hàn). Các cặp vi sai (CK DDR2 = LA17_CC, DQS = HB17_CC, CK
  HyperRAM = HB06_CC) giữ đúng cặp P/N.
* **Bring-up.** Test point ở cả hai phía của mọi kênh TXV0108 (T1..T110); LED cho 3V3 (D3),
  VADJ (D4), 1V8_DDR2 (D1), 1V8_PSRAM (D2): nhìn là biết `FMC_FORCE` / slide switch đã đúng chưa.

### 2.2 Phát hiện

Mức: **cao** = bo không chạy hoặc có thể hỏng; **trung bình** = chạy được nhưng biên thấp hoặc
mất chức năng; **thấp** = nên sửa khi làm lại.

| # | Mức | Phát hiện | Đề xuất |
|---|-----|-----------|---------|
| #2 | trung bình (cao nếu VADJ < 1,5 V) | DIR/OE# tham chiếu VCCA = 1,8 V (phía bộ nhớ) nhưng FPGA lái bằng VADJ. VIH = 1,26 V (1,28 V khi LDO lệch +1,5 %), LVCMOS15 không tải lên tới VCCO (≥ 1,425 V ở −5 %): biên DC chỉ 0,15–0,24 V, datasheet không cho biên AC. Ở VADJ 1,2 V thì hỏng hẳn (cảnh báo ở mục 1). | Rev-B: đổi phía của cả 8 IC (A = FPGA ở VADJ, B = bộ nhớ ở 1,8 V), DIR = H khi đó là FPGA → bộ nhớ. Trên MPS4 có thể dùng ngay VADJ 1,8 V (mục 3.3); trên Huins chỉ có 1,5 V. |
| N1 | trung bình | **Ghi DDR2: DQ ở U5, DQS ở U9.** Pha ghi của IP (`WPS_TARGET`, `calw`) dịch DQS và DQ **cùng nhau** so với CK, nên lệch giữa hai IC không hiệu chỉnh được. Mỗi IC có tpd 1,6–4,8 ns (B → A, VCCA = VCCB = 1,8 V), datasheet không giới hạn lệch giữa hai IC; ở DDR2-266 (bit 3,75 ns) DQ chỉ chịu được lệch khoảng ±1 ns so với DQS (nửa bit 1,875 ns trừ tDS/tDH của DDR2 và lệch kênh ±0,45 ns trong U5). Hai IC cùng lô, cùng nguồn, cùng nhiệt thường lệch ít hơn nhiều, nhưng không có gì bảo đảm. | Trên bo hiện tại: `calw` cho vùng ghi hẹp hoặc không có vùng ghi là dấu hiệu; đo lệch DQ/DQS ở test point. Rev-B: DQS và DQ trong cùng một IC dịch mức (8 DQ + DQS cần ít nhất 9 kênh: IC có giới hạn lệch giữa mọi kênh), hoặc tốt hơn DDR3 nối thẳng không level shifter (mục 6). |
| #4 | trung bình | VCCB = 1,5 V nằm ngoài các bảng switching của TXV0108 (chỉ cho VCCB 1,8 / 2,5 / 3,3 V; "500 Mbps" chỉ cho 1,65–3,6 V); dòng ra ở 1,5 V chỉ cỡ 3–8 mA. | Giữ DDR2-266 / HyperRAM 100 MHz, đo bằng BIST và độ rộng mắt (telemetry). MPS4: VADJ 1,8 V đưa TXV0108 về vùng được đặc tả. |
| #5 | trung bình | CK qua TXV0108: duty 48–56 % ở 15 pF (49–54 % ở 5 pF) trong khi DDR2 cần tCH/tCL trung bình 0,48–0,52 tCK và HyperRAM 0,45–0,55. CK_P/CK_N cùng IC (U10, U6) nên lệch giữa hai nửa nhỏ. | Đo duty CK tại test point phía bộ nhớ khi bring-up. Nếu lệch: bù bằng duty của clock lái ODDR của CK (ODDR xuất D1 khi C cao, nên duty ở chân theo duty của clock; cần một clock riêng cho ODDR này vì `ddr_clk` còn dùng cạnh xuống), hoặc hạ CK của HyperRAM. |
| #3 | trung bình | DM/RDQS (B3) nối GND: không có byte mask, mọi ghi nhỏ hơn một burst là đọc-sửa-ghi. Thêm: chân này thành **đầu ra** nếu bật RDQS (EMR1 A11 = 1) và sẽ chập vào GND. IP hiện ghi EMR1 = 0x0000, OCD 0x0380 rồi 0x0000, A11 luôn 0. | Firmware không bao giờ bật RDQS trên bo này. Rev-B: DM qua một kênh của level shifter + kéo xuống. |
| N2 | trung bình | **Kích thước.** Đo trên bản in PCB (trang 10; thước tỉ lệ là bước 1,27 mm của các via dưới đầu nối, khớp với thân U3 8 × 6 mm): bo khoảng **69 × 84 mm**, dài hơn khoảng 7,5 mm so với module FMC đơn chuẩn VITA 57.1 (69 × 76,5 mm). Vùng chân đầu nối cách mép sau 6–24 mm. Hai lỗ hai bên đầu nối có tâm cách mép sau 18 mm nhưng chỉ cách mép bên 2,9 mm: vòng đồng (Ø ~6,5 mm trên ảnh 3D) chạm mép bo. Hai lỗ phía trước có tâm cách mép trước 11 mm, cách mép bên 5,5 mm. Sai số đo khoảng ±0,5 mm (bản in không ghi kích thước). | Đối chiếu file PCB với bản vẽ cơ khí VITA 57.1/57.4 (vị trí đầu nối, lỗ, chiều dài, khoảng cách lỗ tới mép). Trước lần chạy đầu: lắp thử khi tắt nguồn trên từng board (mục 3.1, 4.1). Rev-B: đưa về 76,5 mm. |
| #6, #6b | trung bình (đã xử lý trong IP) | Đổi chiều DIR quanh mỗi lần đọc; CK (U10), DQS (U9), địa chỉ (U11/U12) qua các IC khác nhau (tDQSS). | IP: cửa sổ `RDIR_LEAD`/`RDIR_TAIL`/`OE_PRE`/`OE_POST`, pha ghi `calw` (HyperRAM: `WPS_TARGET` ±3T/16 bù lệch CK ở U6 với DQ ở U4). |
| N3 | thấp | HyperRAM, mặt nạ ghi: RWDS ở U8, DQ ở U4. Pha ghi dịch cả hai cùng nhau nên lệch giữa hai IC không hiệu chỉnh được (biên khoảng ±1,5 ns ở 100 MHz: nửa bit 2,5 ns trừ tIS/tIH 0,5 ns và lệch kênh). Chỉ ảnh hưởng ghi byte/halfword (RWDS đổi trong burst). | `test` và `verify` có ghi byte: lỗi chỉ ở ghi có mặt nạ là dấu hiệu. Rev-B: RWDS cùng IC với DQ (9 kênh, như N1). |
| N4 | thấp | HyperRAM chỉ chạy được **latency cố định 2×**: vòng đổi chiều RWDS qua U8 không đủ chỗ khi latency biến đổi ([ip/hyperram.md](ip/hyperram.md) mục 2.5). | Latency biến đổi chỉ test được bằng mô phỏng / loopback. |
| N5 | thấp | OE# kéo lên +1V5 (VCCB), datasheet yêu cầu kéo lên VCCA để giữ trở kháng cao lúc cấp nguồn. Khi VADJ đang lên (0,1–1,26 V) OE# có thể được hiểu là mức thấp. Không gây hại: VCC isolation giữ trở kháng cao dưới 100 mV, DRAM được khởi tạo lại với CKE thấp ≥ 200 µs, HyperRAM được RESET#. | Rev-B: kéo OE# lên nguồn phía VCCA (sau khi đổi phía như #2 thì đó là VADJ). |
| N6 | thấp | DDR2 ở 133,33 MHz gần giới hạn dưới của DDR2 (tCK ≤ 8 ns, tức ≥ 125 MHz khi DLL bật). | Không chạy bo dưới 125 MHz; giữ 133,33 MHz như IP. |
| #7 | thấp | Không có EEPROM FRU: MPS4 phải ép VADJ bằng `FMC_FORCE`; Huins đặt bằng slide switch. | Thêm 24C02 (SCL/SDA, GA0/GA1) khai báo VADJ 1,5 V. |
| #8 | thấp | VIO_B_M2C (J39/K40) nối +1V5. MPS4: vào net `VIO_HB` chỉ có 220 nF + 10 kΩ xuống GND (0,15 mA); Huins: qua điện trở 0 Ω không hàn. Vô hại trên cả hai. | Bỏ khi làm lại. |
| #9 | thấp | Không có điện trở đầu cuối (CK vi sai, DQ). Ở 133 MHz, đường ngắn, chấp nhận được; ODT của DRAM phải tắt (driver tắt). | Giữ nguyên. |
| N7 | thấp | BOM: LED `LTST-C190YKT` là LED vàng nhưng footprint tên `LED0603-RD_RED`; ô Revision của schematic để trống (`*`). | Sửa tên footprint; đặt chữ revision (A) để truy được bản đã sản xuất. |
| #1 | (không áp dụng) | DQ/DQS DDR2 và dữ liệu HyperRAM ở hàng HB: VEK280 không nối HA/HB. MPS4 và Huins đều nối đủ HB. | Chỉ cần đổi khi muốn dùng carrier chỉ có LA. |

### 2.3 Công suất

DDR2 512 Mb x8 ở 266 MT/s ước 60–100 mA, HyperRAM tối đa 22 mA khi đọc/ghi ở 200 MHz
(ICC1/ICC2 của datasheet; 35 mA lúc cấp nguồn), 4 LED cỡ 10 mA, TXV0108 không đáng kể: dưới
0,3 A ở 3P3V (MPS4 cấp tối đa 2,5 A). LDO TLV75718 (1 A) tiêu tán (3,3 − 1,8) × 0,1 A ≈ 0,15 W,
chấp nhận được cho SOT-23-5. Dòng VADJ của bo chỉ là phía B của TXV0108 (vài mA).

## 3. Arm MPS4

### 3.1 Lắp đặt

* **Đầu nối.** J11 là ASP-184329-01, đúng cặp với ASP-184330-01 của bo. Arm chỉ nối 400 chân
  (hàng A–K) trong 560, đủ mọi chân bo dùng; Z1 (HSPC_PRSNT) vào `FMC_nDET2`, Z40 là 3P3V.
  TRM: "supports FMC and FMC+ single-width modules that are 69 mm wide", dùng 2 lỗ định vị bên
  hông để gióng đầu nối trước khi ấn.
* **Nguồn.** MCC cấp VADJ 1V2/1V5/1V8 theo EEPROM của card; bo không có EEPROM nên phải đặt
  `FMC_FORCE: 1V5` (hoặc `1V8`, mục 3.3) trong `config.txt`. Thẻ microSD dùng chung đang để
  `FMC_FORCE: 1V2` cho thiết kế FU3: phải được nhóm đó đồng ý và trả lại sau khi thử. Không bao
  giờ để bo cắm ở J11 khi `config.txt` còn `1V2` hoặc khi đang chạy bitstream của nhóm khác (các
  chân FMC khi đó do thiết kế khác lái).
* **Cơ khí (N2).** J11 nằm sát mép dưới của board, cạnh hai nút PBRESET/PBON và đầu nối J50:
  lắp thử khi tắt nguồn, kiểm tra phần dài thêm ~7,5 mm của bo không đè lên linh kiện nào và các
  lỗ định vị trùng nhau.
* **Kiểm tra sau khi bật** (trước khi nạp bitstream của Bow32): bốn LED của bo sáng (D3 3V3,
  D4 VADJ, D1 1V8_DDR2, D2 1V8_PSRAM); đo VADJ tại T101.

### 3.2 Chân và bitstream

| Nhóm | Bank MPS4 (số chân) |
|------|---------------------|
| DDR2: lệnh, địa chỉ, DIR/OE | 69 (19), 70 (8, gồm CK = LA17_CC) |
| DDR2: DQ0..7, DQS | 71 (10) |
| HyperRAM: DQ, RWDS, CK, CS#, RESET# | 71 (13) |
| HyperRAM: DIR/OE | 69 (2), 70 (1) |

Cả ba bank là HP, cấp từ VADJ, nằm ở SLR2 (clock vào từ SLR1). Chân nằm trong
`hw/fpga/mps4/constr/ddr_card.xdc` và `hyperram_card.xdc`: 53/53 khớp schematic và pin list
của Arm. Build và chạy: [ddr_mps4.md](ddr_mps4.md) mục 6, [hyperram_mps4.md](hyperram_mps4.md)
mục 5 (`make fpga BOARD=mps4 DDR_LOOPBACK=0 FLASH_VMEM=...`, `tools/bow32_mps4.py`).
Bản build bo RAM gần nhất (2026-11-08) đạt timing nhưng biên mỏng (WNS +0,098 ns, WHS
+0,001 ns); main đã thêm phần sửa MKV sau đó, nên build lại và đọc `timing_summary.rpt` trước khi
nạp (đường `hr_clk` → `hr_wclk` là đường đầu tiên co lại khi thiết kế lớn thêm).

### 3.3 Phương án VADJ 1,8 V (chỉ MPS4)

Mọi thứ trên bo nối vào +1V5 đều chạy được ở 1,8 V (VCCB của TXV0108, điện trở kéo lên OE#,
VIO_B_M2C, mạch LED D4), và bank HP của MPS4 nhận `LVCMOS18`. Ở `FMC_FORCE: 1V8`:

* TXV0108 chạy ở VCCA = VCCB = 1,8 V, đúng cột được đặc tả của datasheet (#4);
* DIR/OE# được lái 1,8 V, biên 0,54 V so với VIH 1,26 V (#2);
* chỉ cần một biến thể build: `IOSTANDARD LVCMOS18` thay cho `LVCMOS15` trong hai XDC bo RAM
  (DRIVE 8, SLEW FAST, PULLDOWN vẫn hợp lệ ở 1,8 V), build lại và kiểm timing.

Đề xuất: chạy lần đầu ở 1,5 V như thiết kế (giống điều kiện trên Huins); nếu mắt đọc/ghi hẹp
hoặc lỗi ngẫu nhiên, chuyển sang 1,8 V để tách lỗi do level shifter khỏi lỗi của IP.

## 4. Huins MFP-VP1902

### 4.1 Lắp đặt

* **Đầu nối.** 8 khe FMC+ (Samtec SEAF 14 hàng, cùng chuẩn HSPC với ASP-184330-01), đặt dọc
  hai cạnh trái/phải của main board, trong vỏ máy. Theo netlist, mỗi khe nối đủ LA, HA, HB và
  CLK0–3 vào FPGA: bo cắm khe nào cũng được.
* **Nguồn.** VCCIO của 4 bank XPIO mỗi khe đổi bằng một slide switch (1,0 / 1,2 / 1,5 V, mặc
  định 1,5 V, LED báo mức), cùng nguồn đó tới 4 chân VADJ của khe qua điện trở 0 Ω. **Để switch
  ở 1,5 V** (cảnh báo ở mục 1). Khe cấp 3P3V, 3P3VAUX và 12 V.
* **Chân phụ.** PRSNT_M2C_L và HSPC_PRSNT vào chân FPGA (kéo lên): FPGA biết có card.
  VIO_B_M2C qua điện trở 0 Ω không hàn (#8 vô hại). VREF_A/B_M2C, PG_C2M, I2C của khe không ảnh
  hưởng tới bo.
* **Cơ khí (N2).** Module FMC+ nằm phẳng trên main board, trong khung kim loại của vỏ (hình
  "Option Module Usage" của user guide). Lắp thử khi tắt nguồn: phần dài thêm ~7,5 mm không chạm
  khung, tản nhiệt hay module ở khe bên cạnh.

| Khe | Slide switch | Bank của 53 chân (DDR2 / HyperRAM) | Clock PL Si5341 của khe |
|-----|--------------|------------------------------------|-------------------------|
| FMC+01 | SW192 | 704, 705, 706 / 704, 705 | bank 706 (chân GC) |
| FMC+10 | SW196 | 708, 709, 710 / 708, 710 | bank 710 |
| FMC+02 | SW193 | 714, 715, 716 / 714, 716 | bank 716 |
| FMC+20 | SW197 | 711, 712, 721 / 711, 712, 721 | bank 719 (ngoài các bank của khe) |
| FMC+03 | SW194 | 814, 815, 816 / 814, 815, 816 | bank 816 |
| FMC+30 | SW198 | 818, 819, 820 / 818, 819 | bank 820 |
| FMC+04 | SW195 | 804, 805, 806 / 804, 805 | bank 806 |
| FMC+40 | SW199 | 808, 809, 810 / 808, 809 | bank 810 |

Đề xuất khe FMC+01 (đã thử bằng Vivado, mục 4.3): clock PL của khe (CLK0–3 của clock module,
6,25–400 MHz đặt bằng DIP switch) vào chân GC ngay trong bank của khe, dùng làm clock vào cho
các MMCM của DDR/HyperRAM. Tránh FMC+20 (bank không liền nhau, clock ở bank khác).

### 4.2 Khác biệt với MPS4 ảnh hưởng tới IP

* **XPIO tối đa 1,5 V**: chỉ `LVCMOS15`; không có phương án VADJ 1,8 V như MPS4, nên #2 và #4
  chỉ sửa được bằng rev-B. Cùng lý do, một bo DDR2 hay HyperRAM 1,8 V nối thẳng không bao giờ chạy
  trên Huins; ngược lại XPIO nhận `SSTL15`, `SSTL135`, `HSTL_I` (đã thử bằng Vivado), nên DDR3 1,5 V
  nối thẳng (rev-B, mục 6) chạy được ở VCCIO 1,5 V.
* **MMCME5** thay cho MMCME4_ADV: VCO 2160–4320 MHz, bước dịch pha động = 1/32 chu kỳ VCO, chọn
  dịch pha theo từng đầu ra (`CLKOUTn_PHASE_CTRL = 2'b10`). Ví dụ VCO 3200 MHz: 768 bước mỗi chu kỳ
  CK 133,33 MHz (MPS4: 504), 1024 bước ở 100 MHz; firmware đọc số bước ở `PS_NOW[31:16]` nên không
  phải sửa thuật toán hiệu chỉnh.
* **Tristate trong site của chân** (mục 4.3): khác với UltraScale+, chân hai chiều của XPIO bắt
  buộc T lấy từ TDDR/TFF cùng site với ODDR dữ liệu.

### 4.3 Thử bằng Vivado trên xcvp1902

Một thiết kế thử (ngoài repo) đặt **nguyên văn** `bow_ddr_io_xilinx` và `bow_hyperram_io_xilinx`
(cấu hình bo RAM: level shifter, CK đơn, không DM) lên 53 chân của bo ở khe FMC+01, `LVCMOS15`,
DRIVE 8 / SLEW FAST như MPS4, PULLDOWN trên DQ/RWDS của HyperRAM, clock từ clock PL của khe qua
4 MMCME5 (`ddr_clk`, `wclk`, `wclk90`, `rd_clk`; `hr_clk` 270°, `hr_wclk`, `hr_rd_clk`; có dịch
pha động), dữ liệu PHY lấy từ LFSR để không bị tối ưu mất.

| Bước | Kết quả |
|------|---------|
| Tổng hợp | đạt: `ODDRE1` × 53, `IDDRE1` × 18, `IOBUF` × 19, `MMCME5` × 4, `BUFG` → `BUFGCE`: mọi primitive của hai wrapper có trên Versal, không phải đổi tên |
| Đặt chân / DRC | **lỗi DRC PDCN-2749** `XP_OUTPUT_TRISTATE_SAME_SITE` ở 10 chân hai chiều (DQ, DQS, RWDS): "I and T pins … must be driven from the same site by ODDR/OPFF and TDDR/TFF". Wrapper UltraScale+ lấy T từ một flop fabric cạnh chân (trên UltraScale+ ODDR không đặt được ở T); trên Versal phải ngược lại |
| Sửa thử | T của mỗi chân hai chiều lấy từ một `ODDRE1` (TDDR) cùng clock với ODDR dữ liệu (`~wclk90` cho DQ, `wclk` + flop cạnh xuống cho DQS, `~hr_wclk` cho DQ/RWDS HyperRAM) |
| Sau khi sửa | đặt và đi dây xong, DRC sau route không còn lỗi (chỉ một cảnh báo RTSTAT-10 của mạch thử). Mọi `ODDRE1`/`IDDRE1` nằm trong `XPIOLOGIC` của chính chân đó: `ODDR_MASTER/SLAVE`, `TDDR_MASTER/SLAVE` (T), `COMP_IDDR_MASTER/SLAVE`; 4 MMCME5 đặt được, có dịch pha động |
| Timing | mọi đường trong cùng một miền clock đạt (`ddr_clk` +2,43 ns, `hr_clk` +6,52 ns); `ddr_clk` → `wclk` / `wclk90` +0,69 / +1,90 ns. Hai chỗ hụt đều do thiết kế thử: `hr_clk` → `hr_wclk` −5,79 ns vì thiếu `set_multicycle_path -setup 2` mà XDC của MPS4 có (Vivado coi pha tĩnh 270° là latency, [hyperram_mps4.md](hyperram_mps4.md)), và một đường CDC của mạch probe |
| Ảnh nạp (PDI) | Vivado tự thêm một `ps_wizard` (PMC/PS mặc định) vào netlist của thiết kế chỉ có PL, nên bản đầu không cần tự đặt CIPS. `write_device_image` dừng ở bước build firmware PLM: `mb-gcc` đi kèm Vivado 2025.2 trên máy build hiện tại không chạy (SDK của nó thiếu `libkrb5support.so.0`, và glibc 2.34 của máy cũ hơn bản 2.36/2.38 mà trình biên dịch cần, nên không mượn thư viện của máy được). Lỗi của bản cài trên máy build, không phải của thiết kế |

Thiết kế thử và log nằm ngoài repo (thư mục tạm của phiên làm việc, có chân FPGA lấy từ netlist
mật của Huins).

### 4.4 Việc cần làm để chạy trên Huins

1. **Target mới** `hw/fpga/huins_vp1902/` (top, XDC, Makefile, Tcl): khe FMC+01; clock PL của
   khe (đặt 100 MHz bằng DIP switch của clock module) cho SoC và hai IP; console UART qua cầu
   USB-UART của board (`XIO_TX_IN0` / `XIO_RX_OUT0`, bank HDIO); nút reset và LED từ bảng chân của
   user guide (không đưa số chân vào repo nếu Huins không cho phép).
2. **Clock cho Versal**: `bow_ddr_clk_versal`, `bow_hyperram_clk_versal` dùng MMCME5, giữ đúng
   hợp đồng pha của bản UltraScale+ (`ddr_clk`/`wclk`/`wclk90`/`rd_clk`, `hr_clk` 270°), tham số
   số bước dịch pha mỗi chu kỳ CK.
3. **Wrapper chân**: thêm tuỳ chọn T trong site (như bản sửa thử ở 4.3) cho Versal và cập nhật hợp
   đồng thời gian: driver bật/tắt theo clock ghi thay vì đầu chu kỳ chân + trễ flop → chân, kiểm
   lại cửa sổ `OE_PRE`/`OE_POST` (DDR) và `RW_OE`, `OE_PRE`/`OE_POST` (HyperRAM) bằng xsim với
   UNISIM (`make test-fpga-dv`).
4. **Ràng buộc timing**: viết lại các ràng buộc có lọc theo `REF_NAME == OSERDESE3` của XDC
   MPS4; kiểm `timing_checks.tcl` trên Versal.
5. **Nạp**: Versal nạp bằng PDI qua JTAG USB của board (hoặc SD/QSPI); flow Bow32 (`make fpga`,
   `bow32_flash.py` qua UART) giữ nguyên ở phần phần mềm. Trước đó phải sửa bản cài Vivado trên
   máy build (MicroBlaze GCC dùng để build PLM, mục 4.3: việc của quản trị máy) hoặc tạo PDI trên
   máy khác.

## 5. Chức năng IP test được với bo này

✓ = test được; ✗ = không test được bằng bo này; "sim" = chỉ mô phỏng / bản loopback. Cột Huins
áp dụng sau khi port (mục 4.4).

| IP | Chức năng | MPS4 + bo | Huins + bo | Ghi chú |
|----|-----------|:---------:|:----------:|---------|
| DDR | Khởi tạo JEDEC DDR2 (CKE, EMRS2/3, EMR1, MR0 + DLL reset, OCD) | ✓ | ✓ | DDR2-266, CL3, BL8 |
| DDR | Hiệu chỉnh đọc (chụp thô, mắt, `RD_DLY`/`RD_SLIP`) qua hai lần level shifter | ✓ | ✓ | |
| DDR | Hiệu chỉnh pha ghi `calw` (±T/4) | ✓ | ✓ | đồng thời lộ ra lệch U5/U9 (N1) |
| DDR | Cửa sổ DIR/OE (`RDIR_LEAD`/`RDIR_TAIL`/`OE_PRE`/`OE_POST`, `IDLE_DRIVE`) | ✓ | ✓ | đo được ở test point |
| DDR | Cửa sổ bộ nhớ CPU/DMA, đọc-sửa-ghi khi không có DM | ✓ | ✓ | |
| DDR | DM (`DM_EN`) | ✗ | ✗ | DM nối GND (#3) |
| DDR | BIST của LiteDRAM, băng thông | ✓ | ✓ | |
| DDR | Refresh 3,9 / 7,8 µs (`REF_NORM`), `REF_MON`, `REF_STARVE`, `ST_RGAP` | ✓ | ✓ | |
| DDR | `LOCK`, `CORE_RST` + bàn giao lại, lỗi bus (`RANGE`, `NOT_READY`, `BUS_TIMEOUT`) | ✓ | ✓ | |
| DDR | ODT | ✗ | ✗ | Rtt phải tắt trên bo này (#9) |
| DDR | DDR3 (DLL-off, RESET#, ZQ, DM) | ✗ | ✗ | không có chip DDR3: sim + emulator loopback; cần rev-B (mục 6) |
| HyperRAM | RESET#, đọc ID0/ID1 | ✓ | ✓ | |
| HyperRAM | CR0/CR1: latency 3..7, cố định 2×, 34 Ω, wrap 32 byte | ✓ | ✓ | |
| HyperRAM | Latency biến đổi (RWDS ở pha CA) | ✗ | ✗ | N4: sim / loopback |
| HyperRAM | Burst tuyến tính / wrapped, read buffer, ghi posted | ✓ | ✓ | |
| HyperRAM | Mặt nạ ghi bằng RWDS (byte, halfword) | ✓ | ✓ | rủi ro N3 |
| HyperRAM | Hiệu chỉnh đọc (gập theo T/2) và ghi (±3T/16) | ✓ | ✓ | |
| HyperRAM | BIST, băng thông | ✓ | ✓ | |
| HyperRAM | Deep power down, hybrid sleep, WAKE, tCSM 4 µs / 1 µs | ✓ | ✓ | chip bậc "M" (tới 125 °C) |
| HyperRAM | CK vi sai (CR1[6] = 0) | ✓ | ✓ | bo có CK# (U6) |

## 6. Đề xuất cho lần làm bo sau (rev-B)

Gom từ mục 2 và [ddr_board_review.md](ddr_board_review.md):

1. **Đổi phía mọi TXV0108** (A = FPGA ở VADJ, B = bộ nhớ ở 1,8 V), OE# kéo lên VCCA mới (#2, N5).
   Bắt buộc nếu muốn bo chạy tốt trên Huins (VCCIO tối đa 1,5 V).
2. **DQS cùng IC với DQ** (N1) và RWDS cùng IC với DQ (N3); DM qua level shifter (#3).
3. **DDR3 (hoặc DDR3L chạy 1,5 V) nối thẳng, không level shifter** cho phần DRAM: SSTL15 ở VADJ
   1,5 V chạy được trên cả MPS4 (HP) lẫn Huins (XPIO, đã thử bằng Vivado). Đây là cách duy nhất để
   test phần DDR3 của IP trên phần cứng; xem thêm [ddr_board_review.md](ddr_board_review.md) mục 7
   và [ddr_review_industrial_ai.md](ddr_review_industrial_ai.md). HyperRAM vẫn cần level shifter
   (chỉ có bản 1,8 V và 3,0 V).
4. **EEPROM FRU** khai báo VADJ (#7); bỏ nối VIO_B_M2C (#8).
5. **Kích thước** đúng module đơn VITA 57.1/57.4, 69 × 76,5 mm (N2).
6. Giữ test point ở cả hai phía của level shifter và các LED nguồn; đặt chữ revision (N7).
