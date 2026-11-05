# Đánh giá IP DDR2/DDR3 cho Bow32 và bo mở rộng FMC+_DDR2_HyperRam

Tài liệu này trả lời bốn câu hỏi:

1. Bow32 (Ibex RV32IMC, bus 32 bit kiểu OBI) có làm được IP DDR2/DDR3 (controller + PHY),
   kiểm chứng ở mức RTL và trên FPGA không?
2. Bo RAM mở rộng tự thiết kế `docs/fpga/ram_extension/FMC_DDR2_HyperRam.PDF` hợp với
   board FPGA nào trong các board đang có: KV260, Arm MPS4, AMD VEK280?
3. Schematic của bo RAM có vấn đề gì cần sửa trước khi sản xuất?
4. Dùng controller mã nguồn mở [LiteDRAM](https://github.com/enjoy-digital/litedram) được
   tới đâu với bo RAM này (mục 7)?

Thiết kế IP nằm ở [ip/ddr.md](ip/ddr.md), cách chạy trên board ở
[ddr_mps4.md](ddr_mps4.md). Theo yêu cầu, chỉ build FPGA cho **MPS4**; VEK280 và KV260 chỉ
được đánh giá (mục 3), không có bitstream. Bản hiện tại (v2) dùng controller LiteDRAM trên
PHY riêng của Bow32; bản đầu tiên (v1) có controller tự viết, cùng PHY.

## 1. Kết luận

| Câu hỏi | Kết luận |
|---------|----------|
| Bow32 làm được IP DDR2/3? | **Được**, không phải đổi CPU hay giao thức bus, và đã chạy trên MPS4 (bản loopback, 2026-11-05: self-test 18/18, BIST 234/227 MB/s). Thêm một cửa sổ bộ nhớ 512 MiB ở `0x8000_0000` trên main crossbar, thanh ghi ở `0x4000_C000`/`0x4000_E000`, miền clock DDR riêng (CK 125–133 MHz), controller LiteDRAM và một PHY tự viết chỉ dùng `ODDRE1`/`IDDRE1` + MMCM dịch pha động (không dùng MIG, không dùng NoC/DDRMC của Versal). |
| Phải "đổi kiến trúc" ở đâu? | Ở **board**, không ở SoC: KV260 không có FMC và không có DRAM nối vào PL, nên Bow32 có thêm target **MPS4** (Virtex UltraScale+ XCVU13P, không có PS, nạp bitstream qua thẻ SD của MCC). PHY chỉ dùng `ODDRE1`/`IDDRE1` + MMCM (không ISERDES/OSERDES/IDELAY) nên cũng mang sang được Versal. Vì bo RAM chưa có, bản chạy trên MPS4 dùng **loopback**: PHY lái 30 chân I/O 1.8 V **không nối gì** của bank 64 (không đụng khe FMC), dữ liệu đọc quay về qua pad/IOB/IDDR thật, còn DRAM được giả lập bởi một model DDR2/DDR3 tổng hợp được (cùng mã với mô hình mô phỏng) đặt trong FPGA. Bản "card" dùng đúng pinout bo RAM hiện tại, build sẵn để nạp khi có bo. |
| DDR2 hay DDR3? | DDR2 chạy được trên phần cứng (bo RAM có IS43DR86400E). DDR3 không có phần cứng nào: kiểm chứng bằng mô phỏng, ở chế độ **DLL-off** (JESD79-3 cho phép tCK ≥ 8 ns, CL = CWL = 6) vì PHY dùng ODDR/IDDR chỉ đạt CK ≈ 125–133 MHz. |
| Bo RAM hợp board nào? | **Chỉ MPS4** (bản hiện tại). VEK280 **không** dùng được vì khe FMC+ của nó chỉ nối LA00–LA33, trong khi DQ0–7/DQS của DDR2 (và toàn bộ HyperRAM) nằm trên chân **HB**. KV260 không có khe FMC. Chuyển toàn bộ tín hiệu sang LA (đề xuất ở mục 5) thì bo dùng được trên cả VEK280, MPS4 và mọi carrier FMC LPC. |
| Có lỗi schematic cần sửa trước khi sản xuất? | Có: ngoài việc chuyển sang LA, nên đổi chiều level shifter (phía A về FPGA) để chân DIR/OE được tham chiếu đúng mức 1.5 V, và đưa DM qua level shifter để controller không phải đọc-sửa-ghi. Chi tiết ở mục 4. |

## 2. IP DDR2/3 trên Bow32: khả thi tới đâu

* **Bus.** Bus của Bow32 chỉ cho một giao dịch 32 bit đang chờ trên mỗi host, thiết bị
  chậm thì giữ `gnt = 0`. Cửa sổ DDR làm đúng như cầu AXI4-Lite (`bow_axil_bridge`):
  chốt yêu cầu, chuyển sang miền clock của controller, chờ DRAM, rồi mới cấp `gnt`. CPU
  và DMA dùng được DDR như một vùng nhớ thường (chậm: vài trăm ns mỗi word). Băng thông
  thật của DRAM được đo bằng **BIST phần cứng** (của LiteDRAM ở bản v2).
* **DM nối GND trên bo RAM.** Không có byte mask nên mỗi lệnh ghi một byte/halfword/word
  phải đọc cả burst (8 byte với x8), sửa rồi ghi lại (read-modify-write). IP hỗ trợ cả
  hai chế độ (có chân DM / không có DM).
* **Tốc độ.** PHY chỉ dùng `ODDRE1`/`IDDRE1` (có trên cả UltraScale+ và Versal) nên CK
  khoảng 125–133 MHz (DDR2-250/266). Đây vẫn đúng chuẩn DDR2 (DLL bật, tCK ≤ 8 ns, CL = 3).
  Level shifter TXV0108 trên bo RAM cũng giới hạn tốc độ ở mức này (mục 4).
* **Hiệu chỉnh (calibration).** Đường đọc đi qua hai lần level shifter (1.2–4.8 ns mỗi
  chiều) nên dữ liệu đọc về trễ tới hơn một chu kỳ CK so với clock của FPGA. PHY lấy mẫu
  DQ bằng một clock riêng có pha chỉnh được (MMCM dynamic phase shift); phần mềm quét pha,
  đọc lại một mẫu đã biết và chọn tâm "mắt" dữ liệu (giống cách hiệu chỉnh IDELAY của bộ
  thu CSI-2).

## 3. Bo RAM hợp với board nào

| Board | FPGA | Khe FMC | VADJ | Bo RAM hiện tại | Ghi chú |
|-------|------|---------|------|-----------------|---------|
| KV260 | Zynq UltraScale+ K26 | không có | — | **không dùng được** | PL không có DRAM ngoài; chỉ PS có DDR4 |
| VEK280 | Versal AI Edge XCVE2802 | FMC+ J51, **chỉ LA00–LA33** (+CLK0/1) | cố định 1.5 V | **không dùng được** | HA/HB của J51 để trống (UG1612: "FMCP1 HSPC full LA[00:33] bus", schematic trang 31). DQ/DQS của DDR2 ở HB07/09/11/13/17 nên không tới FPGA. VADJ 1.5 V khớp với thiết kế của bo RAM. |
| MPS4 | Virtex UltraScale+ XCVU13P | FMC+ HPC J11, LA/HA/HB đủ | 1.2/1.5/1.8 V (`FMC_FORCE`) | **dùng được** | LA ở bank 69/70, HB ở bank 71, đều cấp từ `VCCO_FMC`. Bo RAM không có EEPROM nên phải đặt `FMC_FORCE: 1V5` trong `config.txt` (hiện thẻ SD đang để `1V2` cho thiết kế FU3 của nhóm khác). |

Chân FPGA của các tín hiệu bo RAM trên MPS4 (theo `docs/fpga/MPS4/hpi0376b_FPGA_ALL_PINS.xlsx`):
DQ0/1 = HB07 P/N (D25/D26), DQ2/3 = HB09 (H28/G28), DQ4/5 = HB11 (L24/L25),
DQ6/7 = HB13 (P24/N24), DQS = HB17 (K27/J27), tất cả ở bank 71; CK = LA17 (H32/G32).

## 4. Review schematic FMC+_DDR2_HyperRam (ThinhHC, 28/10/2026)

Mức độ: **cao** = bo không chạy hoặc không dùng được trên board mục tiêu; **trung bình** =
chạy được nhưng biên thấp hoặc mất tính năng; **thấp** = nên sửa nếu tiện.

| # | Mức | Phát hiện | Đề xuất |
|---|-----|-----------|---------|
| 1 | cao | DQ0–7, DQS_P/N của DDR2 và toàn bộ HyperRAM nằm trên chân **HB**. VEK280 không nối HA/HB; nhiều carrier FMC (LPC) cũng không có. | Chuyển hết sang LA (38 + 16 = 54 trên 68 chân LA), xem mục 5. |
| 2 | trung bình | TXV0108: chân **DIR và OE được tham chiếu theo VCCA**. Bo đặt phía A = DRAM (1.8 V), phía B = FPGA (1.5 V), nên FPGA lái DIR/OE bằng mức 1.5 V trong khi ngưỡng VIH = 0.7 × 1.8 = 1.26 V: biên chỉ còn ~0.2 V (và âm nếu VCCA lên 1.95 V). Datasheet cũng khuyên kéo OE lên **VCCA**, bo lại kéo lên +1V5. | Đổi chiều level shifter: phía A = FPGA (VCCA = VADJ 1.5 V), phía B = DRAM (1.8 V). DIR/OE khi đó tham chiếu 1.5 V (VIH = 1.05 V); pull-up OE về VCCA. Chú ý cực tính DIR đảo lại (DIR = H: FPGA → DRAM). |
| 3 | trung bình | DM/RDQS (B3) nối thẳng GND: không có byte mask, controller phải đọc-sửa-ghi cho mọi lệnh ghi nhỏ hơn một burst. | Đưa DM qua một kênh trống của U9 (cùng nhóm với DQS) + điện trở kéo xuống 10k phía DRAM (để DM = 0 khi DIR đang ở chiều đọc). |
| 4 | trung bình | VCCB (phía FPGA) = 1.5 V nằm **dưới** vùng TXV0108 được đặc tả tốc độ (bảng switching chỉ có 1.8/2.5/3.3 V; "500 Mbps cho 1.65–3.6 V"). | Giữ CK ≤ 133 MHz (266 Mbps trên DQ) như IP đang làm, đo thực tế bằng BIST; nếu cần nhanh hơn thì dùng VADJ 1.8 V (MPS4) hoặc level shifter khác. |
| 5 | trung bình | CK_P/CK_N đi qua hai kênh đơn của U10: lệch kênh tới ±450 ps và méo duty cycle 48–56 % (datasheet), trong khi DDR2 yêu cầu tCH/tCL trung bình 0.48–0.52 tCK. | Đo duty cycle CK tại DRAM khi có bo. Phương án sạch hơn: bỏ level shifter cho CK (driver 1.8 V vi sai riêng) hoặc chọn bộ dịch mức có DCD nhỏ hơn. |
| 6 | trung bình | DQ/DQS đi qua level shifter có hướng: chiều phải đảo trước khi DRAM bắt đầu phát preamble và đảo lại sau postamble; nếu sai sẽ có tranh chấp bus (shifter và DRAM cùng lái). Thời gian enable/disable của TXV0108 tới 7 ns, datasheet không cho timing của việc đổi DIR. | Đã xử lý trong PHY: DIR bật sớm/tắt muộn và FPGA nhả/lái lại DQ theo thanh ghi (`RDIR_LEAD`, `RDIR_TAIL`, `OE_PRE`, `OE_POST`, mặc định 2/2/1/2 chu kỳ); khoảng RD → WR (11 chu kỳ) và WR → RD (8 chu kỳ) được nới tương ứng. Không cần sửa bo. |
| 6b | trung bình | Ghi: CK (U10), DQS (U9), DQ (U5), địa chỉ (U11/U12) đi qua **5 chip TXV0108 khác nhau**; datasheet chỉ đảm bảo lệch ±450 ps giữa các kênh **trong một chip**, còn tpd giữa các chip có thể lệch tới ~3 ns, ăn hết biên tDQSS (±0.25 tCK = ±1.9 ns ở 133 MHz). Hiệu chỉnh đọc không sửa được điều này. | IP có thêm "núm" pha ghi: một MMCM thứ hai dịch pha DQS+DQ so với CK (`WPS_TARGET`), phần mềm quét pha ghi bằng BIST (`calw`). Rev-B nên đặt CK, DQS, DQ ở các chip có cùng tải/độ dài đường mạch và đo tDQSS khi bring-up. |
| 7 | thấp | Không có EEPROM FMC (SCL/SDA để trống). MPS4 phải ép VADJ bằng `FMC_FORCE`; theo VITA 57.1 card nên có EEPROM. | Thêm 24C02 trên SCL/SDA (GA0/GA1) với nội dung FRU khai báo VADJ 1.5 V. |
| 8 | thấp | `VIO_B_M2C` (J39/K40) nối +1V5 (= VADJ). Trên MPS4 các bank HB lấy nguồn từ `VCCO_FMC`, không từ VIO_B_M2C, nên không ảnh hưởng; sau khi chuyển sang LA thì không cần chân này. | Bỏ nối VIO_B_M2C khi đã không dùng HB. |
| 9 | thấp | Không có điện trở đầu cuối cho CK (100 Ω vi sai) và DQ/DQS. Ở 133 MHz, đường ngắn, driver CMOS của TXV0108 + 22 Ω nối tiếp + 10 Ω tích hợp thì chấp nhận được. ODT của DRAM **phải tắt** (Rtt = 0): nếu bật, đường DQ bị kéo về 0.9 V đúng ngưỡng của đầu vào CMOS. | Giữ nguyên; driver của IP luôn tắt ODT cho bo này. |
| 10 | thấp | Đã đúng: CKE kéo xuống, CS# kéo lên, ODT kéo xuống phía DRAM (an toàn khi OE# của level shifter đang tắt); VREF = VDDQ/2 bằng 1k/1k; PRSNT_M2C_L nối GND; TDI–TDO nối vòng để không cắt chuỗi JTAG; LDO 3V3 → 1V8 riêng cho DDR2 và HyperRAM. | — |

## 5. Đề xuất pinout rev-B (chỉ dùng LA)

Nguyên tắc: nhóm dữ liệu DDR2 (DQS, DQ0–7, DM, DQ_DIR) nằm gọn **một bank trên cả hai
board** (bank 706 của VEK280, bank 70 của MPS4), lệnh/địa chỉ ở LA00–LA12, các cặp vi sai
(CK, DQS, CK HyperRAM) giữ đúng cặp P/N.

| Chân FMC | Tín hiệu | VEK280 (bank) | MPS4 (bank) |
|----------|----------|---------------|-------------|
| LA00_CC P/N | DDR2_CK_P / CK_N | AV30 / AW30 (705) | E37 / E38 (69) |
| LA01_CC P/N | DDR2_CKE / ODT | AU35 / AU36 (705) | F35 / F36 (69) |
| LA02 P/N | DDR2_CS# / RAS# | BB29 / BB30 (705) | E39 / D39 (69) |
| LA03 P/N | DDR2_CAS# / WE# | AY30 / AY31 (705) | D40 / C40 (69) |
| LA04 P/N | DDR2_BA0 / BA1 | BA31 / BB31 (705) | C39 / B40 (69) |
| LA05..LA11 P/N | DDR2_A0..A13 (P = chẵn, N = lẻ) | 705 | 69 |
| LA12_P | DDR2_OE_N (OE# của các level shifter DDR2) | AP32 (705) | B36 (69) |
| LA17_CC P/N | DDR2_DQS_P / DQS_N | AV36 / AW37 (706) | H32 / G32 (70) |
| LA19 P/N | DDR2_DQ0 / DQ1 | BA41 / BB40 (706) | E31 / D31 (70) |
| LA20 P/N | DDR2_DQ2 / DQ3 | AY39 / BA39 (706) | D29 / C29 (70) |
| LA22 P/N | DDR2_DQ4 / DQ5 | AY36 / BA37 (706) | F33 / E33 (70) |
| LA23 P/N | DDR2_DQ6 / DQ7 | AV37 / AW38 (706) | F29 / E29 (70) |
| LA27 P/N | DDR2_DM / DDR2_DQ_DIR | AY41 / AY42 (706) | H33 / G33 (70) |
| LA21_P | DDR2_DQS_DIR | BB38 (706) | F34 (69) |
| LA18_CC P/N | HR_CK_P / HR_CK_N | AW40 / AY40 (706) | G36 / G37 (69) |
| LA24, LA25, LA26, LA28 P/N | HR_DQ0..DQ7 | 706 | 69 |
| LA29 P/N | HR_RWDS / HR_CS# | AR37 / AT37 (706) | K37 / J37 (69) |
| LA30 P/N | HR_RESET# / HR_DQ_DIR | AR39 / AT38 (706) | H39 / H40 (69) |
| LA31 P/N | HR_RWDS_DIR / HR_OE_N | AR40 / AT39 (706) | J39 / J40 (69) |
| LA12_N, LA13..LA16, LA21_N, LA32, LA33 | dự phòng (11 chân) | | |

Bank 705/706 của VEK280 và bank 69/70 của MPS4 đều cấp từ VADJ của FMC (1.5 V), nên
mọi chân dùng `LVCMOS15`.

## 6. Chạy thử khi chưa có bo RAM

* **Mô phỏng RTL** (Verilator): controller LiteDRAM + bộ chuyển DFI + PHY + mô hình board
  (level shifter có trễ và chiều DIR) + mô hình DRAM DDR2/DDR3 tự viết, có kiểm tra giao
  thức và timing JEDEC.
* **Mô phỏng mức chân** (xsim + thư viện UNISIM): PHY thật trên `ODDRE1`/`IDDRE1`/`IOBUF`
  + MMCM.
* **FPGA (MPS4), bản loopback**: PHY lái 30 chân I/O không nối gì của bank 64 (cùng bank
  với clock OSCCLKA[2]); một model DRAM tổng hợp được (cùng mã với mô hình mô phỏng) trả lời
  lệnh; phần mềm hiệu chỉnh pha trên đường IDDR thật, chạy memtest/BIST, đo băng thông. Bản
  này không dùng chân FMC nên không phụ thuộc VADJ hay card nào đang cắm ở J11. Đã chạy trên
  bo ngày 2026-11-05 (cả v1 và v2: self-test 18/18, mắt đọc khoảng 245/504 bước, kết quả ở
  [ddr_mps4.md](ddr_mps4.md)).
* **FPGA (MPS4), bản card**: build với pinout bo RAM hiện tại (LA + HB, `LVCMOS15`). Chỉ nạp
  khi đã cắm bo RAM và đặt `FMC_FORCE: 1V5` trong `config.txt` của MPS4.

## 7. LiteDRAM với bo RAM này

Controller của LiteDRAM (bank machine, refresh, lập lịch, DFII, BIST) dùng tốt cho Bow32 và
là controller của bản v2. Các **PHY** của LiteDRAM thì không dùng được với bo RAM rev-A:

| Yêu cầu của bo RAM rev-A | PHY UltraScale+ của LiteDRAM (`USPDDRPHY`) |
|---------------------------|--------------------------------------------|
| DDR2 | chỉ DDR3 / DDR4 |
| điều khiển DIR/OE của TXV0108 trước và sau mỗi cửa sổ đọc | không có |
| dữ liệu đọc có thể rơi ở bất cứ đâu trong chu kỳ (hai lần level shifter, mỗi lần 1,2–4,8 ns) | căn pha đọc bằng `IDELAYE3`, khoảng 1,25 ns trong khi một bit DDR2-266 dài 3,75 ns |
| DDR2-266 (CK 133 MHz) | DDR3 cần CK ≥ 300 MHz ở chế độ DLL bật |

Vì vậy bản v2 dùng controller LiteDRAM trên PHY của Bow32 (MMCM dịch pha đọc trên cả chu
kỳ, cửa sổ DIR/OE), nối qua DFI ([ip/ddr.md](ip/ddr.md)). LiteDRAM chỉ chạy DDR2 với BL4 nên
bộ sinh của Bow32 đặt BL8 cho DDR2; khoảng chuyển hướng bus mà LiteDRAM giữ (RD→WR 16 CK,
WR→RD 12 CK ở 33,33 MHz) đủ cho cửa sổ DIR (cần 11 và 8 CK).

**Nếu còn kịp sửa bo (rev-B):** một chip **DDR3 (1,5 V) nối thẳng** khe FMC, không level
shifter, với VADJ = 1,5 V (`FMC_FORCE: 1V5` trên MPS4, cố định 1,5 V trên VEK280), các bank
HP của FPGA chạy được `SSTL15`. Khi đó dùng được nguyên `USPDDRPHY` của LiteDRAM ở DDR3-800
trở lên: ở 800 MT/s một bit dài 1,25 ns nên `IDELAYE3` phủ cả bit, có write leveling của
LiteDRAM. Cần đi dây đúng kiểu DDR3: DQ/DQS/DM của một byte cùng một bank và cùng chiều dài,
DQS và CK là cặp vi sai, có VREF và điện trở đầu cuối cho địa chỉ/lệnh. Bản rev-B chỉ dùng
LA (mục 5) vẫn đúng cho DDR3 (DDR3 x8 cần thêm RESET# và DM).

MPS4 còn có sẵn một thanh **DDR4 SODIMM 8 GB** (Micron MTA8ATF1G64HZ, bank 60–62, clock tham
chiếu 100 MHz) mà `USPDDRPHY` của LiteDRAM chạy được ngay; Bow32 chưa dùng vì mục tiêu là bo
RAM DDR2/DDR3.
