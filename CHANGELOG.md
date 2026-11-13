# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/), đánh số theo
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Bộ thu CSI-2, bước 6 của kế hoạch chuyển MIPI RX ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 4, 10; [docs/ip/dphy_rx.md](docs/ip/dphy_rx.md) mục *Chức năng v1.x*): **D-PHY v1.x**, mỗi
  chức năng sau một bit có giá trị reset = hành vi của bước 5. `T_INIT` (`TIM2[19:0]`: LP-11 liên
  tiếp trước `Stop`, chỉ sau READY lên hay `CMD.REINIT`), `HS_TMO` (`TIM1[23:0]`, reset 2^20 =
  watchdog cũ), `ESC_TMO` (`TIM2[31:20]`), `CTRL.HSRX_EARLY`, `CTRL.CLK_MISS_OFF`, escape và lệnh
  ULPS trên data lane, ULPS lane clock (`CTRL.ULPS_EN`; `lane_pd` mỗi lane, `UlpsActiveNot*`,
  `RxUlpsEsc`, `RxUlpsClkNot`), `CLK_TOG_DIV` (`TIM1[27:24]`), `CTRL.CLK_LOST_EN`, LATE_EOT;
  thanh ghi shadow (`CTRL`, `TIM0`–`TIM2`) + `CMD.APPLY`; `CMD.REINIT` (máy LP về `WaitStop`) và
  `CMD.AFE_CAL` (xung `cal_start`); `LANE_STOP`, `CNT_MISC[31:16]`, `CNT_DSK[31:16]`, `INFO[27]`,
  `ERR_STATUS` [3] [4] [6] [7] [10], `IRQ_STATUS.ULPS`; sự kiện miền lp tới thanh ghi qua bộ đếm
  gray 4 bit (`lp_clk` ≤ 12 × `clk_i`, `set_bus_skew` mới trên hai bo); `RxSkewCalHS` là mức trên
  mọi lane; lỗi lp trên PPI (`ErrControl*`, `ErrEsc`) là bộ đếm gray 2 bit (`bow_ppi_err_tx`, lấy
  mẫu ở controller bằng `bow_ppi_err_rx`). Driver: `bow_dphy_rx_apply()`, `bow_dphy_rx_ctrl()`,
  setter của `TIM1` / `TIM2`, `bow_dphy_rx_v1x()`, `bow_dphy_rx_power()`; `csi2_test`: `phy tinit`,
  `phy hstmo`, `phy missoff`, `phy v1x`, `phy check`. Bench mới của D-PHY một mình
  (`hw/ip/dphy_rx/dv`: `tb_bow_dphy_rx.sv` với máy phát mức bit, 12 test, 2 và 4 lane, bước CI và
  `make test-ip`; `make mutants` 35 mutant), `BOW_SYNC_JITTER` của `bow_sync` (chỉ bench đó).
  Formality `STEP=6` (mặc định, `REF=1c76364`): controller và máy LP so với bước 5.
- Bộ thu CSI-2, bước 5 của kế hoạch chuyển MIPI RX ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 3.2, 3.7, 10; [docs/ip/dphy_rx.md](docs/ip/dphy_rx.md)): **giao diện AFE**. `bow_dphy_rx` có
  mọi cổng của mục 3.2 (`afe_*`: byte clock, word, valid; cổng byte clock và `des_rst` = ¬cổng, cùng
  cạnh, từ máy LP lane clock; LP; `hsrx_en` và `term_en` riêng; mã delay tĩnh + OWN + `dly_q`; `pd`,
  `lprx_en`, `lane_pd`, `ready`, `cal_start`, `cal_done` / `cal_err`, `trim`, `status`; delay lane
  clock, sampler giám sát và điểm móc test nối 0), tham số `AfeKind` (thay `DlyVid`), `AfePdRst`,
  `TrimW`; thanh ghi `AFE_CTRL.PD` (`0x014`) và `AFE_STATUS.CAL_DONE` / `CAL_ERR`. Logic adapter
  không primitive mới: `hw/fpga/common/rtl/bow_dphy_dly_xusp.sv` (nạp `IDELAYE3` khi mã / OWN đổi,
  reset `ISERDESE3` từ `des_rst`) và `bow_dphy_dly_xphy.sv` (trình tự nạp XPHY: `RX_EN_VTC`, chờ 12,
  cách 4; `RX_RST` từ `des_rst`), instance `u_dly` trong hai adapter, chạy cả trong mô phỏng
  Verilator (`csi2_tx_model`). Checker `hw/ip/dphy_rx/dv/bow_afe_chk.sv` (bind vào mọi
  `bow_dphy_rx` của DV và mô phỏng hệ thống). `make lint` phủ sáu nơi dùng `bow32_top` (năm top
  của bo với stub cổng: stub UltraScale+ mới `hw/lint/xilinx_xusp_stubs.sv`, stub block design
  KV260 `hw/lint/kv260_bd_stubs.sv`; kết nối của `tb_bow32`, `make -C sim lint`) và
  `bow_dphy_io_xusp`. Formality: `make -C hw/ip/dphy_rx/fm equiv` mặc định
  `STEP=5 REF=3d3985a` (bộ thu sau wrapper cổng của bước 4, `hw/ip/dphy_rx/fm/bow_mipi_rx_s4.sv`).
  DV `dly` và `be` thêm phần của bước 5; bench xsim Versal kiểm luật nạp mới (cùng mã, OWN xuống /
  lên). Sửa sau review: `lane_pd` chỉ xuống theo READY mới sau PD (mục 3.6; bản đầu nhả nó theo
  READY cũ của bộ đồng bộ sau một xung PD ngắn), DV `dly` thêm xung PD hai lần ghi liền nhau;
  `bow_afe_chk` kiểm `lane_pd` bằng mô hình tham chiếu và giá trị reset của mục 3.6 khi reset bật;
  bench đơn vị `tb_afe_dly` (logic hai adapter với mô hình primitive, bit mã lệch tới một chu kỳ)
  và `tb_dphy_afe` (điều khiển và trạng thái AFE của `bow_dphy_rx`, bản ASIC và FPGA) trong
  `test-rx` (CI, `make -C hw/ip/csi2rx/dv afe`); `make mutants-rx` 28/28 (7 mutant của bản đầu, 16
  mới; chạy bench đơn vị trước); `make -C sim lint` báo cả đầu vào nối rỗng
  (`hw/lint/empty_inputs.py`, test host `tools/tests/test_empty_inputs.py`); `kv260_cam.xdc` thêm
  bus skew của mã delay + OWN vào adapter (10 ràng buộc); kiểm tra ngoài ngữ cảnh của phần bộ thu
  KV260: `make -C hw/fpga/kv260_cam rx-ooc`; đặc tả mục 3.5–3.6: hợp đồng `ready` của AFE và hai miền
  reset của điều khiển AFE.
- Bộ thu CSI-2, bước 4 của kế hoạch chuyển MIPI RX ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 4.10, 6.3, 10; [docs/ip/dphy_rx.md](docs/ip/dphy_rx.md)): **thanh ghi riêng của D-PHY** ở
  `0x4000_8C00` (offset `0xC00` của cửa sổ `CSI2RX`, `bow_mipi_rx` chia cửa sổ), tập con v1 của đặc
  tả: `ID` `0x44505201`, `INFO` / `INFO2` (loại AFE, MHz của `lp_clk`, độ rộng mã delay, AFE tự
  hiệu chỉnh, đích `SETTLE` ns + UI, byte trail của AFE), `CTRL` (CLK_CONT, DES_RST_DIS), `CMD`
  (REINIT, CNT_CLR), `AFE_STATUS` (READY, trạng thái thô của PHY), `TIM0` (bố cục `PHY_CFG` cũ),
  `LANE_LP`, `LANE_HS`, `IRQ_STATUS` / `IRQ_EN` (ERR, RAW_DONE), `ERR_STATUS` (CONTROL), `ERR_LANE`,
  `BYTECLK`, `CNT_BURST0`…`3` / `CNT_CLK` / `CNT_LPERR` (32 bit), `DLY0`…`3` (CODE, PEND, Q, OWN),
  `RAW_CTRL`, `RAW` (`0x200 + 8i`); RTL mới `bow_dphy_rx_regs.sv`, `bow_dphy_raw.sv` (nửa RAW của
  `bow_csi2_capture`), reset riêng của D-PHY (`u_lrst`, `u_brst`), ngắt của D-PHY vào
  `IRQ_STATUS[5]` của controller. Driver mới `sw/common/include/bow_dphy_rx.h` (mọi tên `DPHY_*`),
  `sw/common/src/bow_dphy_rx.c`: một công thức `SETTLE` cho mọi AFE từ `INFO2`
  (`bow_dphy_rx_settle()`: 22 trên KV260 ở 912 Mbit/s, `0x13` trên Huins, đúng từng bit như hai
  công thức cũ, `tools/tests/test_dphy_settle.py`), re-init, delay, bộ đếm, RAW, đồng hồ đo.
  Cổng mới của `bow_mipi_rx` / `bow32_top`: `phy_status_i`, `reinit_o`, `burst_rst_en_o`. Bench
  xsim Versal thêm cấu hình `reinit_pulse` (xung 640 ns của `CMD.REINIT`).
- Bộ thu CSI-2, bước 3 của kế hoạch chuyển MIPI RX ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 5.5, 8.1, 10): bench của controller một mình ở PPI, `make -C hw/ip/csi2rx/dv test-ppi` (cũng
  trong `test` và bước CI riêng): `tb_csi2rx_ppi` với `bow_ppi_bfm`, hai chế độ thời gian: D-PHY
  Bow32 (`bow_csi2rx` với PPI và dải phụ do BFM lái: `RxActiveHS` từ cuối SETTLE, khe như XPHY,
  `ErrSotSyncHS` cuối burst, lỗi lp và HS entry là xung `vid_clk_i`, `band_lane_en_lp` = `Enable`
  qua 2 flop như D-PHY) và PHY chuẩn qua wrapper cổng phẳng mới `bow_csi2rx_ppi_flat`
  (`hw/ip/csi2rx/rtl/`, không trong `csi2rx.f`; `RxActiveHS` cùng `RxSyncHS`, không khe,
  `ErrSotSyncHS` sớm, lỗi dạng xung ở clock lp của PHY, không `PhyReady`). `csi2_model.py gen
  --ppi bow|std` dựng mỗi item TX ở PPI từ chính mô hình bộ thu (kỳ vọng không đổi; luật ghép lane
  kiểm trên chu kỳ đã dựng), test mới `clkstop`, `gaps` (cả RAW có khe), `lpmask` (hai chế độ: lỗi
  LP của lane đã tắt chỉ đếm, cạnh mặt nạ chỉ ở D-PHY Bow32); 167 case (lane 1, 2, 4, khe, lệch lane
  tới 6 / 7, lỗi ECC / CRC / SoT / LP, byte clock dừng 4 cạnh sau khi `RxActiveHS` xuống hay sớm
  hơn, tràn FIFO, lọc DT / VC, EXTRA, LOG) chạy song song, cả hai chế độ sạch; `make mutants-ppi`:
  20 mutant của controller và wrapper đều chết. Hồ sơ PPI của controller sửa theo kết quả: v1 cần
  `RxActiveHS` lên trước `RxSyncHS` ít nhất 1 chu kỳ và còn cao 1 chu kỳ sau byte cuối,
  `RxSkewCalHS` dạng xung, mỗi lane đưa byte tới hết word cuối, các lane lệch nhau trong FIFO 8 byte
  và `RxActiveHS` của chúng chồng nhau; SKEW ở lệch ≥ 7 cần lane sớm làm tràn FIFO; mốc thời gian ở
  80 Mbit/s sát giới hạn; wrapper làm thay PHY chuẩn ba việc đầu (trễ miền byte 1 chu kỳ, giữ
  `RxActiveHS` 2 chu kỳ, cạnh lên của `RxSkewCalHS`) và ghi hệ quả của phần dải phụ nối hằng; phần
  dựng PHY chuẩn còn mượn bốn điều của D-PHY Bow32 (mục 5.5). Không đổi RTL nào có sẵn; `make
  lint` thêm wrapper (4 cấu hình). Bench cả bộ thu: `test-rx` chạy case song song như `test-ppi`
  (`PJOBS`); test `deskew` thêm ở cuối hai burst deskew một phần, mỗi burst với `CNT_EXT` đọc sau nó
  (mutant đếm deskew ở lane cuối lúc đầu sống), `loss` thêm ở cuối burst mất ở mức LP qua một burst
  deskew và dòng lỗi CRC có byte payload ở word cuối (4 lane). Yêu cầu "DV nhanh hơn" của bước 3
  chưa đạt: trên cùng case bench PPI không nhanh hơn bench cả bộ thu (thời gian nằm ở mô hình
  Python), chờ chủ dự án quyết.
- Đặc tả kiến trúc bộ thu MIPI cho ASIC, chưa có RTL ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)):
  camera → AFE (D-PHY analog) → giao diện AFE → D-PHY số `bow_dphy_rx` → PPI → bộ điều khiển
  CSI-2; hợp đồng AFE có timing bằng số (phát / bắt nửa chu kỳ trên `hs_byte_clk`, `des_rst`
  chỉ xoá đường dữ liệu, `clk_act` bắt buộc cho 80 Mbit/s), thanh ghi D-PHY ở `0x4000_8C00`
  (không alias), hồ sơ PPI cho PHY / controller của hãng khác, bộ máy deskew không cần byte
  tham chiếu, cổng sẵn sàng ASIC và kế hoạch chuyển theo bước 0–11 giữ mọi build và test.
  Quyết định đã chốt (2026-11-11, mục 0): đích ASIC 80 Mbit/s … 2,5 Gbit/s, không alias và chỉ
  build / chạy trên bo Huins ở các bước chuyển (KV260 chỉ mô phỏng), hợp đồng đồng bộ AFE làm đề
  xuất ban đầu, tư cách thành viên MIPI trước khi đóng băng AFE, `lp_clk` ≥ 250 MHz (dự phòng:
  termination tự động trong AFE); mục 7.1 cập nhật theo lần chạy bo 3 (BISC cách tâm 0,26–0,48 UI).
- **Camera Sony IMX274 trên Huins MFP-VP1902**: module Leopard LI-IMX274MIPI-FMC qua bo chuyển
  camera của Huins ở khe FMC+01 (một bank XPIO, 705), 4 lane × 1440 Mbit/s, RAW10
  (`make fpga BOARD=huins_vp1902 CARD=cam`, [docs/camera_huins.md](docs/camera_huins.md)).
  - Kiểm chứng trên bo (lần chạy bo 1, 2026-11-10, PDI và firmware trước khi gộp main):
    IMX274 4 lane × 1440 Mbit/s (byte clock 180,078 MHz), 1080p30 và 720p60 không lỗi (hơn
    18 000 frame với tap đã hiệu chỉnh), `csi2_test` PASS 15/15 sau hiệu chỉnh, sọc màu đúng
    thứ tự, cảnh thật màu tự nhiên, H.264 1080p30 giải mã không lỗi (20 frame: video RAM đầy với
    rate control cũ). Đo thêm: `SETTLE` sạch 65–170 ns với PA5 = 1, PA5 = 0 hỏng sau lần bật
    lại bộ thu, trễ BISC ở mép sớm của eye, mỗi burst một packet. Kết quả từng bước và danh
    sách kiểm: docs/camera_huins.md mục 6, 7. Bản gộp main cùng các sửa dưới đây đã kiểm trong
    mô phỏng rồi trên bo ở lần chạy bo 2 (dòng sau).
  - Kiểm chứng trên bo lần 2 (2026-11-11, PDI và firmware `cd289e3`, như main `458dd33`): mọi
    kiểm tra đạt: firmware không sửa tìm thấy cảm biến (VMAX 0x906), `csi2_test` PASS 17/17,
    `extra 0` ở 1080p30 và 720p60 (trail đo được 49–52 byte trên 4 lane, `CTRL.EXTRA` 192 dư 140
    byte), `margin` 0 lỗi trên cả 4 lane (±88/±90/±90/±88 tap, BER < 1,0e-8) và giữ tap đặt
    bằng tay, `cam` đầu tự hiệu chỉnh, `flip 0 1` đúng màu (RGGB), AE/AWB đứng yên khi test
    pattern bật, 5 phút 1080p30 (9012 frame) không lỗi, H.264 1080p30 30 / 30 frame (QP 37–38)
    và 720p30 45 / 45 frame giải mã không lỗi; cửa sổ `SETTLE` và độ lệch trễ BISC như lần 1.
    Sau lần 2: `margin` in `errors at the taps in use` (thay cho `calibrated taps`), chú thích
    `CTRL.EXTRA` ghi trail đã đo; tài liệu: kết quả lần 2, trail `CTRL.EXTRA`, nạp PDI khi
    hw_server của người khác cũ hơn, việc còn mở (docs/camera_huins.md mục 5–9,
    docs/ip/csi2rx.md).
  - Sửa theo lần chạy bo 2 (phần mềm và công cụ; mô phỏng và test host, rồi trên bo ở lần 3,
    dòng sau):
    `start` của `csi2_test` kiểm 16 frame nguyên thay cho 64 packet
    (`bow_csi2rx_link_check_frames()`; ở trễ BISC có 0,2–1,5 lỗi CRC mỗi frame 1080p mà 64 packet
    không thấy), lỗi do tap in `try cal` và trên bản Versal thêm hai dòng gợi ý về trễ BISC, đầu ra
    trên KV260 giữ nguyên; mô phỏng `csi2_274` cài một lỗi CRC ở frame 6 và đếm frame của link
    check sạch. QP đầu của `rec` (`bow_h264_rc_init()`) theo (số pixel)^0,6 thay cho tỉ lệ thuận
    với số pixel: hai mode của IMX274 phủ cùng góc nhìn, ở QP 37 frame 1080p 37,5 KB và 720p
    23,0 KB; 720p 45 frame nay QP 37 (trước 33: frame đầu +45 % so với đích), 1080p 30 frame
    QP 38; kích thước và QP từng frame của lần 2 vào `tools/tests/test_h264_model.py` (rate control
    build cho host ra đúng QP từng frame của bo). `make jtag` của Huins (`tcl/jtag.tcl`): khi
    hw_server cũ hơn Vivado (`Labtools 27-3366`) in hw_server nào giữ cổng (người dùng, pid, phiên
    bản), `VIVADO=` của Vivado cùng phiên bản hoặc `HW_SERVER=`, và không dừng tiến trình của
    người khác.
  - Kiểm chứng trên bo lần 3 (2026-11-11, PDI `cd289e3`, firmware `5c68b53`): ba sửa trên chạy
    đúng (`start` bắt lỗi ở trễ BISC 7 / 7 lần và in gợi ý `cal`; `rec` chọn `QP 37 (auto)` ở 720p
    45 frame và `QP 38 (auto)` ở 1080p 30 frame, đủ frame, giải mã không lỗi; gợi ý của `make jtag`
    hiện đúng trước hw_server 2025.1 thật), `csi2_test` PASS 17/17, 30 phút 1080p30 (53 999 frame)
    không lỗi, tap không đổi. Tìm nguyên nhân độ lệch của BISC với hai PDI thử (generic tạm, chưa
    vào repo): tap ~1,86–1,89 ps, tâm eye cao hơn trễ BISC 0,26–0,48 UI (không phải 1/4 UI); slice N
    như IP của AMD không đổi gì; `DELAY_VALUE` 250 ps dời trễ BISC +132 tap với tâm không đổi, link
    sạch ở trễ BISC nhưng còn lệch +44/−24/+8/−34 tap: phần chung là một thời gian cố định ngoài
    những gì BISC đo, ~0,2 UI lệch riêng từng lane đến từ ngoài FPGA. RTL và mặc định không đổi,
    ứng dụng vẫn hiệu chỉnh; tài liệu: kết quả lần 3, độ ổn định, mục 9.1 về BISC, việc còn mở
    (docs/camera_huins.md mục 5–9, docs/ip/csi2rx.md, docs/video_kv260.md).
  - Sửa theo lần chạy bo 1: `imx274_probe()` nhận VMAX sau reset 0x906 (cảm biến trên bo) và
    0x905 (datasheet), MDSEL / HMAX / đọc lại BLKLEVEL vẫn phải khớp; khi không khớp các app in
    giá trị đã đọc (`cam_print_not_found()`) thay cho gợi ý XCLR sai. `imx274_bayer()` trả RGGB
    cả khi lật dọc (đo trên bo; mô hình mô phỏng lật theo cặp dòng). `camera` và `video` luôn
    hiệu chỉnh ở `cam` đầu, cả trên Versal: trễ BISC nằm ở mép sớm của eye (~11 % dòng lỗi
    CRC; câu hỏi mở của RTL ở docs/camera_huins.md mục 9). PA5 = 1, `SETTLE` 95 ns giữ nguyên
    (đo: sạch 65–170 ns); PA5 = 0 hỏng trên bo sau lần bật lại bộ thu, bản `FW=brst0` chỉ còn
    cho mô phỏng. `stat` / `csi` liệt kê đủ lane của bản build khi bộ thu tắt. AE/AWB dừng khi
    test pattern của cảm biến bật. `rec` của `video`: rate control mới (`bow_h264_rc_*`: đích
    = chỗ trống còn lại / số frame còn lại, bước QP 6 · log2(kích thước / đích) tối đa ±12, QP
    đầu theo kích thước frame, `qp auto`, `bow32_video.py --qp` mặc định auto): 30 frame 1080p
    vừa 1 MiB (lần 1: 20 / 30); test host với kích thước frame của bo và của mô hình H.264
    (`tools/tests/test_h264_model.py`), test hệ thống `h264` có thêm một bản quay rate control.
  - Sửa theo review bản gộp: `margin` của `camera` đo quanh trễ đang dùng (không bao giờ tap 0
    khi chưa hiệu chỉnh), `margin` của `csi2_test` lấy tap đang dùng của mọi lane
    (`bow_csi2rx_get_delays()`; `DLY_VID`: `[24:16]`); `csi2_model.py` `extra_thr()` giữ 64 cho
    1–2 lane trên UltraScale+ như stimulus của main; tài liệu: 17 check, `dropped by DT/VC`,
    FIFO 512 × 45 bit.
  - Timing với RTL đã gộp main (2026-11-10): PDI camera của Huins WNS +0,780 ns, WHS
    +0,014 ns, bus skew 11/11; Vivado không báo critical warning; kiểm tra CDC của build thêm
    vào danh sách duyệt mục CDC-11 của enable data lane 2 và 3 (luôn bằng nhau, synthesis gộp
    thành một flop như lane 0/1), chạy lại trên checkpoint đã route: 0 lỗi. `kv260_cam`: WNS
    +0,074 ns (đường găng vẫn ở `u_mb` của H.264), WHS +0,010 ns, bus skew 9/9, không có
    critical warning; chưa nạp lên KV260.
  - Bộ thu CSI-2 4 lane (`Lanes` 1, 2 hoặc 4): ghép lane 1/2/4 byte mỗi word, CRC 1–4 byte mỗi
    chu kỳ, `rx_valid_i` (word mới của từng lane), `phy_rdy_i`; nạp tap ở clock video
    (`DlyVid = 1`: không nạp sau reset, mỗi lần ghi `DLYn` đúng một lần nạp); độ sâu FIFO pixel
    là tham số (`FifoDepth`, 512 nhóm trên Huins). `bow32_top`: tham số `CsiFifoDepth`,
    `CsiDlyVid`, cổng `dphy_rx_valid_i`, `dphy_phy_rdy_i` (các top không có PHY Versal nối 1).
  - Thanh ghi CSI2RX (`ID` giữ `0x43533201`, firmware cũ vẫn nhận bitstream mới): `INFO[5]`
    DLY_VID; `CTRL[7]` LANES4; `STATUS` thêm LP / HS của lane 2, 3 và `[14]` PHY_RDY (KV260 nối
    1: lúc nghỉ đọc `0x403F` thay cho `0x003F`); `CNT_SOT23` (`0x068`), `CNT_BURST23` (`0x06C`),
    `CNT_CLR` xoá cả hai; `DLY2`, `DLY3`; `RAW` 8 bit mỗi lane ([docs/ip/csi2rx.md](docs/ip/csi2rx.md)).
    `0x048`/`0x04C` là `CNT_EXT`/`FRAME_ERR` của PR #17: nhánh này lúc đầu đặt `CNT_SOT23`/
    `CNT_BURST23` ở đó, khi gộp với main chúng dời sang hai ô trống `0x068`/`0x06C`.
  - Các sửa lỗi của PR #17 (review bộ thu) chạy cả với 4 lane: lớp packet 1–4 byte mỗi word có
    `px_err` (cả khi `px_eol` trễ một chu kỳ), FORMAT với WC 0, đếm byte sau packet (cả phần
    sau CRC trong word cuối; với 4 lane P3 của short packet trùng word `sop`); unpack tới 4
    byte mỗi chu kỳ giữ khung dòng khi FIFO tràn (Cut/Lost, `afull`), `err`, `drop_i`, SKIP;
    aligner nhận deskew và theo dõi HS-zero chỉ trên word `rx_valid` (khoảng trống và word cũ
    của FIFO XPHY không đổi kết quả); byte enable cho `DLY0`…`DLY3` (ghi không có byte 0/1
    không đổi tap, không nạp với `DlyVid` = 1). Driver: `bow_csi2rx_margin` cho 1, 2 hoặc 4
    lane (`tap`, `k`, `side` 4 phần tử), `CTRL.EXTRA` theo số lane đang dùng (+8 byte mỗi lane
    với PHY Versal: 192 ở 4 × 1440 Mbit/s), `SETTLE` theo tốc độ lane của PR #17 trên
    UltraScale+, 95 ns giữ nguyên trên Versal; `print_errors` in `sot` 4 lane khi dùng 4 lane.
    `csi2_test` `margin` trên IMX274 dùng mẫu AAAh (không có PN9). DV 4 lane chạy mọi test
    directed mới (`deskew`, `extra`, `loss`, `ovf2`, `ovf8`, `be`), unit test aligner thêm 3
    lượt có khoảng trống `rx_valid` (301 case).
  - `bow_dphy_io_versal` (`hw/fpga/common/rtl`): D-PHY RX trên XPIO của Versal, không dùng IP
    của AMD: `IBUFDS_DPHY`, XPHY chế độ native với lane clock làm strobe, XPLL 1500 MHz, BISC,
    byte clock qua BUFGCE. Sơ đồ nibble là tham số (mặc định: một sơ đồ tổng hợp, không phải
    của bo nào); núm lúc chạy `reinit_i` (khởi động lại PHY: XPLL, BISC, theo dõi VT) và
    `burst_rst_en_i` (reset FIFO RX mỗi burst).
  - Bản build `CARD=cam` (`bow32_huins_vp1902_cam_top`, MMCME5: SoC 50 MHz, video 200 MHz):
    sơ đồ nibble suy ra lúc build từ XDC chân và chức năng chân của Vivado (`make plan
    CARD=cam`, `tcl/cam_plan.tcl`; file nằm trong thư mục build, không commit), LOC của XPHY và
    kiểm tra sơ đồ trước place (`tcl/pre_opt_cam.tcl`, `tcl/cam_xphy.tcl`), SoC trong SLR của
    camera (`tcl/pre_place_cam.tcl`), kiểm tra clock, CDC đã duyệt, 11 bus skew và VCCIO của
    khe (`tcl/timing_checks_cam.tcl`, `tcl/build.tcl`). GPIO: PA4 khởi động lại D-PHY, PA5
    `BurstRxRst`, PB6 / PB7 `PHY_RDY` / `DLY_RDY` của mọi nibble, PA7 XCLR, PB5 PRSNT.
    `pins.txt`: mục `[card=x sites=...]`; `tools/huins_pins.py` từ chối khe khác và không in
    số chân trong thông báo lỗi.
  - Khoá ở `make jtag` của bo Huins: `make pdi` ghi `pdi_site.txt` (card, khe); `make jtag` in
    nó cùng bo phải cắm và từ chối PDI không có file hoặc mới hơn nó, PDI của bo kia và PDI bo
    RAM cho FMC+01 (lái chân của module camera) trừ khi `CONFIRM=1`.
  - Phần mềm: driver IMX274 (`sw/common/src/imx274.c`: reset bằng XCLR, nhận diện bằng giá trị
    mặc định sau reset, chuỗi thoát standby, readout mode 1 / 3 / 5 + crop, HMAX / VMAX,
    exposure, gain, lật dọc dưới REGHOLD, test pattern) và lớp cảm biến chung
    (`sw/common/src/cam_sensor.c`: tự nhận IMX219 hay IMX274); `camera`, `csi2_test`, `video`
    chạy với cả hai. `bow_csi2rx`: 4 lane, chờ `STATUS.PHY_RDY` khi `INFO.DLY_VID` = 1,
    `SETTLE` 95 ns với XPHY, đọc `DLYn` tới khi hai lần đọc khớp, `bow_csi2rx_read_delay()`,
    `bow_csi2rx_print_delays()`, `bow_csi2rx_forget_delays()`. Trên Versal: ứng dụng hiệu
    chỉnh ở lần khởi động đầu (như KV260) và đặt PA5 = 1 (`BurstRxRst`) mỗi lần khởi động
    bộ thu (`cam_rx_start()`; tuỳ chọn build `CAM_BURST_RST=0` cùng `SETTLE_VID_NS=115` chỉ cho
    mô phỏng); `csi2_test`
    có `phy`, `phy reinit`, `phy burstrst 0|1`, `sensor on|off` và từ chối mode có dòng làm tràn
    FIFO của bộ thu (`mode 4k` cần 1024 nhóm); `video` đặt dòng dài cho H.264 (1080p30 HMAX
    672, 720p30 448: tải ~78 %, như IMX219 trên KV260); AE/AWB ghi IMX274 tối đa một lần mỗi
    frame.
  - Công cụ: `bow32_cam.py snap --center W H` (crop giữa ảnh theo mode); `bow32_cam.py`,
    `bow32_video.py`, `bow32_ddr.py` và `bow32_hyperram.py` gửi lệnh từng ký tự và chờ echo,
    `bow32_mkv.py` (dòng hex dài) từng 8 ký tự (FIFO nhận UART 16 byte; không có echo trong 2 s
    là lỗi thay vì lệnh bị cắt).
  - Mô phỏng: bản `Imx274 = 1` của testbench hệ thống (mô hình IMX274 + PHY Versal: FIFO RX
    8 word như XPHY, word glitch, `BurstRxRst`, khởi động lại PHY), test `camera274`,
    `csi2_274`, `video274` (trong `make test` và CI) và `geo274` cùng các biến thể của
    `make -C sim test-extra` (cả firmware `FW=brst0`: `BurstRxRst` = 0, `SETTLE` 115 ns, chỉ
    mô hình); `make
    test` chạy mọi test rồi in tổng kết; `make run` nhận `PLUSARGS`, `RUN_LOG`. Unit test bộ thu: model 4 lane, test `skew` (69 case);
    `csi2_model.py` 4 lane + PHY Versal. `hw/fpga/common/dv/tb_bow_dphy_io_versal.sv` (xsim,
    model XPHY của AMD, 24 cấu hình, `make -C hw/fpga/common/dv test-dphy-versal`, cần Vivado).
    `make lint` thêm bộ thu 4 lane / 1 lane, `bow_dphy_io_versal` (3 sơ đồ, một sơ đồ phải bị
    từ chối) và top camera với stub chỉ có cổng (`hw/lint/xilinx_versal_stubs.sv`).
- **Bo Huins MFP-VP1902** (`hw/fpga/huins_vp1902`, AMD Versal Premium xcvp1902): Bow32 với DDR2
  và HyperRAM của bo RAM mở rộng FMC+_DDR2_HyperRam ở khe FMC+ (mặc định FMC+10), image PDI nạp
  qua USB JTAG (`make fpga BOARD=huins_vp1902`, `make fpga-jtag BOARD=huins_vp1902`,
  [docs/ddr_huins.md](docs/ddr_huins.md)).
  - Clock trên Versal: `bow_ddr_clk_versal` (2 MMCME5: pha ghi `wclk` / `wclk90` là hai đầu
    ra dịch pha động của cùng một MMCM, không còn tầng MMCM_W) và `bow_hyperram_clk_versal`;
    768 / 1024 bước dịch pha mỗi CK; clock vào là dao động 200 MHz cố định của bo
    (`CLK_SRC=ref200`; clock PL của khe, `CLK_SRC=site`, chưa dùng được: chưa có bias đầu vào
    đã kiểm, clock module đang ở 16 MHz).
  - `bow_ddr_io_xilinx` / `bow_hyperram_io_xilinx`: tham số `TFromOddr` (mặc định 0, MPS4
    không đổi): trên XPIO của Versal, T của mỗi chân hai chiều lấy từ một ODDRE1 trong site
    của chân (DRC PDCN-2749).
  - Không có số chân FPGA của Huins trong repo (tài liệu của Huins là tài liệu mật):
    `constr/pins.txt` ghi cổng → net của bo, `tools/huins_pins.py` sinh XDC chân từ netlist
    trong bản sao cục bộ lúc build.
  - Chạy trên bo (2026-11-09, bo RAM ở FMC+10): DDR2 self-test 21/21, `verify` 40/40, BIST
    214 MB/s, lần đầu IP DDR2 chạy với chip DDR2 thật; HyperRAM self-test 19/19, `verify`
    40/40, BIST 188 / 180 MB/s (sau lần chạy chip thật trên MPS4).
  - Kiểm chứng: cấu hình `vcard`/`vx16`/`vlb` (DDR) và `vcard`/`vdirect`/`vlb` (HyperRAM) của
    testbench chân trong xsim, `test-vclk` (hai wrapper clock MMCME5), `make mutants` 117 bản.
- Review bo RAM mở rộng `FMC_DDR2_HyperRam` (cả DDR2 và HyperRAM, cơ khí, BOM) và khả năng lắp
  trên Arm MPS4 và Huins MFP-VP1902 ([docs/fmc_ram_card_review.md](docs/fmc_ram_card_review.md)):
  53 chân của bo đối chiếu với XDC của MPS4 và netlist của cả 8 khe FMC+ của Huins; chỉ cấp
  nguồn khi VADJ ≥ 1,5 V; DQ và DQS của DDR2 ở hai level shifter khác nhau (lệch không hiệu
  chỉnh được); bo dài ~84 mm (chuẩn 76,5 mm); MPS4 test được ngay với bản build bo RAM, Huins
  cần port (Vivado trên xcvp1902: T của chân hai chiều phải lấy từ TDDR cùng site, DRC
  PDCN-2749); bảng chức năng IP test được trên mỗi board; đề xuất rev-B.
- `bow_bus_deny` (`hw/ip/bus`): tường lửa trước một host, yêu cầu tới một cửa sổ địa chỉ
  trả lỗi bus; `bow32_top` dùng nó để chặn DMA khỏi thanh ghi MKV. NMI của Ibex nối vào
  alert nghiêm trọng của MKV.
- **DDR: độ tin cậy cho mục tiêu công nghiệp** (P0 của
  [docs/ddr_review_industrial_ai.md](docs/ddr_review_industrial_ai.md)):
  - Refresh theo nhiệt độ: lõi LiteDRAM refresh mỗi 3,87 µs (Tc 85..95 °C); `CTRL.REF_NORM`
    cho bộ đếm refresh của lõi chạy chu kỳ gấp đôi (7,74 µs, Tc ≤ 85 °C), có hiệu lực từ lần
    refresh kế tiếp.
  - Giám sát refresh: `CTRL.REF_MON`, `STATUS.REF_STARVE` + ngắt sau 8 khoảng không có REF,
    khoảng REF dài nhất ở `ST_RGAP` (`0x0BC`).
  - Khoá cấu hình `CTRL.LOCK` (chỉ reset SoC xoá): `CTRL`/`LAT`/pha, lệnh (trừ `SNAP`,
    `CLR_STATS`) và ghi CSR LiteDRAM bị từ chối, `STATUS.LOCK_ERR`.
  - Firmware: chính sách refresh (`bow_ld_set_refresh_norm`), bật giám sát sau bàn giao, tắt
    trong đoạn DFII; telemetry độ rộng mắt (% chu kỳ CK, cảnh báo dưới 25 %); lệnh
    `refresh`, `lock`; March C- trong `memtest`; self-test 21 mục (thêm tốc độ refresh, giám
    sát refresh, March C-).
  - Kiểm chứng: bước refresh / giám sát / `LOCK` trong `tb_bow_ddr`, `LOCK` qua reset SoC
    trong `tb_bow_ddr_rst`, mô hình DRAM kiểm thêm nợ REF trung bình theo JEDEC (hoãn tối đa
    8, trả trước tối đa 8) với chế độ nóng `hot_i`; `make -C hw/ip/ddr/dv regress NSEEDS=n` và workflow hằng đêm
    `ddr-nightly.yml` (25 seed).
- **HyperRAM** `bow_hyperram` (`hw/ip/hyperram`): bộ điều khiển HyperBus tự viết cho
  HyperRAM 2.0 x8 (Infineon S80KS2562, 32 MiB) của bo RAM mở rộng. Cửa sổ 256 MiB ở
  `0x6000_0000` (device thứ 9 của main crossbar, 32 MiB có thiết bị, ngoài vùng → lỗi bus),
  thanh ghi ở `0x4000_F000`, ngắt `irq_fast[12]` ([docs/ip/hyperram.md](docs/ip/hyperram.md)).
  - Controller (miền CK): bộ thực thi lệnh (APPLY, bước pha đọc/ghi, chụp thô, HW_RESET,
    đọc/ghi CR0/CR1, WAKE, BIST, thống kê), lịch giao dịch theo HyperBus (CA 48 bit, latency
    1×/2× cố định hoặc theo RWDS, mặt nạ RWDS khi ghi, burst tuyến tính / wrapped), mọi
    thông số thời gian là thanh ghi tính từ tần số CK, giao dịch vượt tCSM bị từ chối, CS#
    giữ thấp thêm `RD_HOLD` chu kỳ sau word đọc cuối, bản sao CR0/CR1 và trạng thái nguồn
    (deep power down, hybrid sleep) giữ qua reset SoC.
  - Cửa sổ bus: read buffer 4 line × 32 byte (line fill wrapped, word cần trước), ghi
    posted gộp khối 32 byte (đẩy thành một burst), write-through, `NOT_READY` / `RANGE` /
    timeout → `BROKEN` tới `CORE_RST`; hai FIFO 2 clock (gray) tới controller.
  - PHY: `ODDRE1`/`IDDRE1` qua wrapper chân của bo, FIFO đọc 2 clock chạy liên tục, bộ căn
    dữ liệu theo RWDS (chế độ `STRICT` báo lỗi thay vì trả dữ liệu lệch), chụp thô 64 chu
    kỳ; điều khiển DIR/OE của level shifter TXV0108 theo từng chu kỳ.
  - BIST trong phần cứng (PRBS xorshift32 / đếm, đo băng thông thật của HyperBus).
  - HyperRAM giả lập tổng hợp được `bow_hyperram_dev` (UltraRAM, kiểm tra giao thức, mã lỗi
    ở `DBG`) cho bản loopback trên bo khi chưa có chip.
  - `HrEn = 0`: bản stub (KV260).
- Driver `sw/common/src/bow_hyperram.c` (khởi tạo, hiệu chỉnh pha đọc bằng chụp thô và pha
  ghi, BIST, nguồn), ứng dụng `sw/apps/hyperram` (shell, self-test 19 mục) và
  `tools/bow32_hyperram.py` (self-test, hiệu chỉnh, mắt đọc, băng thông, `verify` so dữ liệu
  đọc lại với mô hình Python của BIST và xorshift).
- Mô phỏng: test hệ thống `hyperram` (firmware thật trên SoC + mô hình clock/pad + HyperRAM
  giả lập); `hw/ip/hyperram/dv`: mô hình S80KS2562 mức chân viết từ datasheet (thời gian,
  thanh ghi, mọi kiểu burst, nguồn, 21 bộ đếm vi phạm), mô hình bo TXV0108 (độ trễ theo seed,
  tranh chấp, đầu vào thả nổi), mô hình clock MMCM và pad twin; `tb_bow_hyperram` lái IP như
  driver ở 5 cấu hình (loopback, bo RAM, nối thẳng 166 MHz, stub, chip tắt DQ sớm), trong
  `make test-ip` và CI (Verilator 5.020); `tb_bow_hyperram_io_xilinx`
  (xsim, unisim) cho hai wrapper chân / clock của bo, cấu hình bo RAM / nối thẳng / loopback,
  và 42 bản đột biến của hai wrapper trong `make -C hw/fpga/common/dv mutants` (đều bị bắt).
- Đã chạy trên Arm MPS4 (bản loopback, 2026-11-07, hai lượt): self-test 19/19 (cả sau `RESET`
  của MCC), `verify` 340/340 case so với mô hình Python, BIST trên toàn 1 MiB 0 lỗi ở 184,4 MB/s
  (đỉnh 200 MB/s), hybrid sleep / deep power down, 24/24 lần `init` từ 24 pha xuất phát; DDR 18/18
  trên cùng bitstream. Trên bo lộ ra một lỗi của hiệu chỉnh đọc (đã sửa: bản đồ mắt gập theo T/2,
  [docs/ip/hyperram.md](docs/ip/hyperram.md) mục 4). Sau review của PR #6 (42 / 49 phát hiện được
  xác nhận, đều đã sửa) chạy lại 2026-11-08: self-test 19/19 ba lượt, `verify` 60/60, DDR 18/18.
  Vòng review thứ hai (của chính các bản sửa) xác nhận thêm 5 phát hiện; khi viết test hồi quy
  cho từng bản sửa (mục 9b của testbench IP) lộ thêm hai lỗi RTL quanh reset kênh (POWER đọc
  "hoạt động" ngay sau reset kênh giữa lúc hồi phục; reset kênh cắt ngang xung WAKE), đều đã sửa.
  `make -C hw/ip/hyperram/dv mutants`: 18 bản RTL, mỗi bản gỡ một bản sửa, đều bị testbench bắt.
  Bitstream sau vòng hai chạy trên MPS4: self-test 19/19 ba lượt, `verify` 60/60, DDR 18/18.
  Trên chip thật (bo RAM ở khe FMC+ J11 của MPS4, `FMC_FORCE: 1V5`, bitstream bản bo RAM từ
  main `ed949e1`, 2026-11-09): self-test 19/19, `verify` 40/40, mắt ghi tốt ở mọi điểm quét,
  BIST (PRBS hai seed và dữ liệu đếm) và `memtest` của CPU trên toàn 32 MiB 0 lỗi, BIST
  184,1 MB/s; luật dùng chung bo khi bo RAM đang cắm và thứ tự trả bo ở
  [docs/hyperram_mps4.md](docs/hyperram_mps4.md) mục 5.4.
- Arm MPS4: bản build có cả DDR và HyperRAM (`HR_LOOPBACK`, mặc định theo `DDR_LOOPBACK`),
  hai MMCM HyperRAM (`bow_hyperram_clk_xusp`) sau BUFGCE riêng từ cùng oscillator, wrapper
  chân `bow_hyperram_io_xilinx`, XDC loopback (bank 65) và bo RAM (khe FMC+), ràng buộc CDC
  và bus skew, kiểm tra trong `tcl/timing_checks.tcl`; hướng dẫn chạy
  [docs/hyperram_mps4.md](docs/hyperram_mps4.md).
- Hướng dẫn đưa HyperRAM lên ASIC ([docs/ip/hyperram.md](docs/ip/hyperram.md) mục 9): IP
  không có phần analog; phần giữ / phần thay (pad, flop DDR, PLL, DLL), hai kiến trúc đường
  đọc, SDC, DFT, kiểm chứng.

- **SDRAM DDR2/DDR3** `bow_ddr` (`hw/ip/ddr`): controller **LiteDRAM** trên PHY riêng
  của Bow32. Cửa sổ bộ nhớ 512 MiB ở `0x8000_0000` trên main crossbar (3 × 8), CSR của
  LiteDRAM ở `0x4000_C000` (8 KiB), thanh ghi PHY/cầu ở `0x4000_E000`, ngắt
  `irq_fast[11]` ([docs/ip/ddr.md](docs/ip/ddr.md)).
  - Lõi LiteDRAM sinh bằng `hw/ip/ddr/litedram/bow_ddr_litedram_gen.py` từ `ddr2.yml`
    (bo RAM: IS43DR86400E x8, CK 133,33 MHz) và `ddr3.yml` (MT41K64M16 x16, DLL-off,
    125 MHz, mô phỏng): controller ở CK/4, DFI 1:4, BL8 (DDR2 được đặt BL8 thay cho BL4
    của LiteDRAM), BIST generator/checker, CSR qua Wishbone, cổng native; LiteX/LiteDRAM
    ghim phiên bản, sinh lại giống từng byte (`make litedram`, `make litedram-check`).
  - Cầu bus: `bow_ddr_win` (cửa sổ → cổng native, bắt tay 4 pha qua miền clock,
    đọc-sửa-ghi khi không có DM, `NOT_READY`/`RANGE`, timeout → trạng thái `BROKEN` tới
    `CORE_RST`), `bow_ddr_csr` (→ `wb_ctrl`).
  - `bow_ddr_dfi`: DFI 1:4 → một lệnh mỗi CK cho PHY (trễ cố định 8 CK), trả dữ liệu đọc
    đúng `read_latency` 12, phát hiện `RD_LATE`/`RD_EXTRA`, thực thi APPLY/bước pha/chụp
    thô; CKE/ODT/RESET# theo DFI.
  - PHY giữ từ bản trước: `ODDRE1`/`IDDRE1` + MMCM dịch pha đọc và ghi (1/504 CK), FIFO
    đọc 2 clock, chụp thô 32 chu kỳ, cửa sổ DIR/OE cho level shifter TXV0108 của bo RAM.
  - `DdrEn = 0` (KV260): bản stub.
- Sau review (lõi, cầu bus, firmware, CDC) và hai vòng kiểm chứng độc lập:
  - Bộ sinh LiteDRAM: tắt auto-precharge (emulator và mô hình DRAM không mô phỏng
    RDA/WRA), tREFI làm tròn xuống (7,77 µs ở DDR2, trước đó 7,83 µs), cổng native không còn bị
    chặn trong lõi theo `init_done` (truy cập đang chạy luôn xong), revision LiteX dạng
    bất kỳ được bỏ khỏi file sinh; thêm `litedram_<lõi>_pkg.sv`. `bow_ddr` dừng elaboration
    (lint, mô phỏng, tổng hợp) khi lõi không khớp PHY, khi CK làm khoảng REF vượt 7,8 µs
    hoặc CK cao hơn CK của lõi quá 1 %; `make lint` elaborate cả lõi DDR2 và DDR3 và kiểm
    hai cấu hình sai phải bị từ chối.
  - `bow_ddr_regs`: `READY` và cầu CSR chờ lõi reset xong sau `CORE_RST` (xung ngắn không
    còn làm treo truy cập tới timeout; có đường dự phòng khi clock DDR ngừng trong lúc xung);
    hai cầu từ chối khi đang trong reset cầu; mất clock DDR giữa truy cập báo
    `BUS_TIMEOUT` như tài liệu.
  - Firmware: `eye` giữ dữ liệu dưới mẫu huấn luyện và chặn cửa sổ khi không kiểm lại được
    đường đọc; mọi đường lỗi của `calw` sau khi bắt đầu quét trả lại pha ghi cũ, kiểm nó
    bằng BIST (PRBS và đếm) và chặn cửa sổ nếu pha cũ cũng hỏng; `bow_ld_handover` chặn cổng
    native trước đoạn DFII; self-test: chu kỳ REF lấy theo lõi, mục 18 thấy cả cờ lỗi của
    các mục trước; `bow32_ddr.py` chỉ nhận dấu nhắc ở đầu dòng.
  - CDC/RDC: `CORE_RST` đúng lúc lõi phát một lệnh ghi đã nhận không còn ghi 0 vào DRAM
    (flop lệnh native của cầu cửa sổ không reset); bộ bước pha đọc/ghi chỉ reset theo
    lock của MMCM, nên sau reset SoC (BREAK, reset mềm, `CB_nRST`) `PS_NOW`/`WPS_NOW` vẫn
    là pha thật và quét pha ghi không vượt ±T/4 đã kiểm timing; sau reset liên kết FIFO
    đọc được khởi động lại ở pha đọc đã tới; `bow_ddr_clk_xusp` reset cả ba MMCM khi một
    MMCM mất lock (pha về 0 cùng bộ đếm; trên MPS4 việc này reset cả SoC, vì `MMCM_A` cũng
    tạo clock SoC); `DBG` của `bow_ddr_lb` được chốt bằng flop trước khi qua miền clock của
    SoC; tầng bắt dữ liệu của FIFO đọc là flop (không SRL); `tcl/timing_checks.tcl` báo lỗi
    khi `report_cdc` thấy logic tổ hợp trước một bộ đồng bộ dữ liệu (CDC-10 ngoài chân CLR
    của bộ đồng bộ reset) hoặc CDC-11 / 12 / 13 / 14.
  - Test thêm: lượt BIST địa chỉ ngẫu nhiên và bộ giám sát A10 trong `tb_bow_ddr`, các phần
    A2 / D / E của `tb_bow_ddr_rst`, mất lock (cả mất lock riêng `MMCM_W`) trong xsim của
    `bow_ddr_clk_xusp`, `strip_dates` của bộ sinh, dấu nhắc của `bow32_ddr.py`; mỗi test
    mới được kiểm bằng cách đưa lại lỗi cũ vào và thấy nó báo lỗi.
- `bow_ddr_dev` / `bow_ddr_lb`: DRAM DDR2/DDR3 tổng hợp được, kiểm tra trình tự khởi tạo
  và mọi luật JEDEC (thanh ghi `DBG`), dùng làm DRAM giả lập 4 MiB (UltraRAM) cho bản
  loopback trên bo khi chưa có chip.
- Board **Arm MPS4** (`hw/fpga/mps4`, `make fpga BOARD=mps4`, XCVU13P): `bow_ddr_clk_xusp`
  (3 MMCME4: SoC 50 MHz, CK 133,33 MHz, clock controller CK/4, clock ghi và clock đọc
  dịch pha), `bow_ddr_io_xilinx`, bản loopback (mặc định) và bản bo RAM
  (`DDR_LOOPBACK=0`), file cho thẻ microSD của MCC; console ở UART0 của FPGA (cổng USB 1
  với `UARTMODE: 0`), reset theo `CB_nPOR` và `CB_nRST`; ràng buộc CDC
  (`set_max_delay -datapath_only`) và `tcl/timing_checks.tcl` kiểm tra loại ràng buộc của
  từng cặp clock ([docs/ddr_mps4.md](docs/ddr_mps4.md)).
- Firmware: driver PHY `bow_ddr.h/.c`; `sw/common/litedram/` (DFII, khởi tạo JEDEC bằng
  chuỗi sinh từ LiteDRAM cho DDR2 và DDR3 trong cùng một firmware, hiệu chỉnh đọc bằng
  chụp thô, hiệu chỉnh pha ghi bằng BIST, bàn giao cho controller, BIST); ứng dụng `ddr`
  (`test` 18 mục, `init`, `cal`, `calw`, `eye`, `verify`, `bist`, `memtest`, `bench`,
  `cap`, `rd`/`wr`/`dump`); tool `tools/bow32_ddr.py` (`test`, `cal`, `eye`, `bench`,
  `verify` so với bản Python của bộ sinh dữ liệu BIST); unit test
  `tools/tests/test_bow32_ddr.py`.
- `tools/bow32_mps4.py`: nạp Bow32 lên Arm MPS4 qua thẻ microSD của MCC (`install`,
  `deploy`, `reboot`, `reset`, `restore`, `show`). Chỉ ghi `MB/HBI0376B/BOW32/` và dòng
  `APPFILE` của `board.txt`, không bao giờ ghi `config.txt`. Mỗi `install` trên thẻ đang
  chọn thiết kế khác giữ bản sao `board.txt` mới nhất của nhóm kia (trên thẻ và trên PC);
  `restore` chỉ trả dòng `APPFILE` (cả file chỉ khi `board.txt` hỏng, từ bản giữ trên thẻ,
  file hỏng được lưu lại); mọi lần ghi qua file tạm + `os.replace`, không thay file chỉ-đọc,
  bitstream mới chỉ thay bản cũ khi đã chép và đọc lại đủ; giá trị `APPFILE` dừng ở `;`.
  `REBOOT`/`RESET` qua console MCC rồi chờ console Bow32. Unit test
  `tools/tests/test_bow32_mps4.py` (thẻ giả, MCC giả). `restore` không bao giờ chọn một file
  không có trên thẻ, `--appfile` không chọn được BOW32 (đó là việc của `install`); file tạm
  của `board.txt` nằm trong `BOW32/`; REBOOT mà MCC không báo nạp FPGA xong là lỗi.
- Testbench IP `hw/ip/ddr/dv` (lõi LiteDRAM thật + mô hình clock, chân, level shifter,
  DRAM DDR2/DDR3; cấu hình `lb`, `card`, `ddr3`, `stub`; `tb_bow_ddr_rst.sv` cho các góc
  reset và miền clock) và test mô phỏng hệ thống `ddr` (`test quick` PASS 18/18).
- Đánh giá khả năng làm DDR trên Bow32 và bo RAM mở rộng `FMC_DDR2_HyperRam`: chỉ hợp
  với Arm MPS4 (VEK280 chỉ nối chân LA của FMC+, KV260 không có FMC), góp ý schematic và
  đề xuất sơ đồ chân chỉ dùng LA ([docs/ddr_board_review.md](docs/ddr_board_review.md)).
- Đánh giá bộ thu CSI-2 cho camera công nghiệp và SoC camera AI: 12 phát hiện có vị trí
  mã (tràn FIFO làm hỏng khung AXI4-Stream — tái hiện bằng mô phỏng, lỗi CRC không đi
  theo luồng ảnh, deskew, eye không bù nhiệt, packet sau trong cùng burst bị bỏ không báo
  lỗi...), bảng khoảng cách theo use case, kiến trúc PPI / nhiều luồng và lộ trình đề xuất
  ([docs/csi2rx_review.md](docs/csi2rx_review.md)). F1 (nhiều packet trong một burst) đã
  được sửa lại thành P2: CSI-2 v1.x bắt buộc LP-11 giữa các packet, chỉ máy phát sai chuẩn
  hay LRTE của v2.0+ mới gửi như vậy.
- Bộ thu CSI-2, giai đoạn 0 của review ([docs/csi2rx_review.md](docs/csi2rx_review.md)
  mục 10), chạy trên KV260 (`csi2_test` 18/18):
  - `m_axis_tuser_o` 2 bit: [1] = dòng lỗi cùng `tlast` (CRC, FORMAT, bị cắt trong payload,
    Cut khi tràn FIFO, hoặc một dòng trước đó của frame bị mất: FIFO đầy, không có nhóm
    pixel, burst mất trước unpack vì header không sửa được / lỗi sync / SKEW / EXTRA /
    packet bị cắt không phải dòng / vào HS bị từ chối ở mức LP). Nhóm FIFO 45 bit.
  - `tuser[0]` chỉ ở pixel (0, 0): nhóm `sof` không ghi được (FIFO đầy), dòng đầu không có
    nhóm pixel nào, hoặc một burst mất trước dòng đầu thì cả frame bị bỏ tới FS/FE sau,
    `ERR_STATUS.SKIP` [11] (đếm trong `CNT_MISC[31:24]`). Dòng mất chỉ được ghi nhận trong
    frame: dòng ngoài frame không mang `sof`/`err`.
  - Thanh ghi `FRAME_ERR` (`0x04C`): các bit `ERR_STATUS` của từng frame (từ FE trước tới FE
    của nó), chốt ở FE, sự kiện tới trong 2 chu kỳ sau FE vẫn thuộc frame vừa kết thúc;
    thấy được cả dòng mất ở đuôi frame mà luồng ảnh không báo được.
  - FORMAT: dòng accepted có WC = 0 (cả RAW10), hoặc RAW10 có WC % 5 ≠ 0.
  - Tràn FIFO giữ khung dòng: dòng đã bắt đầu luôn có `tlast` (nhờ `afull_o` mới của
    `bow_fifo_async`), FIFO đầy thì bỏ cả dòng.
  - Burst deskew (HS-zero rồi sync `FFFFh`) không còn là lỗi SOT, nhưng chỉ được nhận ở
    chỗ HS-zero kết thúc và với đủ 16 bit 1: byte sync hỏng vẫn là lỗi SOT dù dữ liệu sau đó
    chứa `0x00 0xFF`, hay sync hỏng thành `0xFC`/`0xFE`/`0xFF` trước DI `0x2B`.
    `CNT_EXT` (`0x048`): [15:0] burst có byte sau packet vượt `CTRL.EXTRA` ([23:16], reset
    64, `ERR_STATUS.EXTRA` [10]), [31:16] burst deskew.
  - Ghi thanh ghi theo byte enable.
  - Tham số `CpuClkHz` của `bow_csi2rx`: elaborate báo lỗi khi `vid_clk_i` > 16/3 × `clk_i`
    (`bow32_top` truyền `ClkFreqHz`; `make lint` có case âm 50/300 MHz; mô phỏng dừng bằng
    `$fatal` cả khi Verilator build với `-Wno-fatal`).
  - Driver: `SETTLE` đặt bit cũ nhất aligner xét (nó nhìn lùi 2 word ISERDES) vào giữa
    85 ns + 6 UI … 145 ns + 2 UI (22 ở 912 Mbit/s và 200 MHz; IMX219 trên board chạy sạch ở
    6…30); `CTRL.EXTRA` theo tốc độ lane; `extra` trong bộ đếm và
    `bow_csi2rx_link_errors()`; `CSI2RX_ERR_TAP`, `CSI2RX_ERR_SKIP`, `FRAME_ERR`,
    `bow_csi2rx_print_errors()`; kiểm tra lề sau hiệu chỉnh `bow_csi2rx_margin()` (tâm và
    tâm ± eye/4 mỗi lane, chỉ báo, BER theo số bit đã kiểm; sau một điểm sạch xoá bộ đếm
    trước khi ghi tap, timer khởi động lại ở FS nên frame mất FS không làm điểm sau "not
    measured", lỗi đã thấy vẫn là kết quả).
  - `csi2_test`: check `margin` (dữ liệu PN9, 60 frame mỗi điểm), lệnh `margin [k]
    [frames]`, mỗi frame được kiểm cũng phải có `FRAME_ERR` = 0, dòng lỗi in đủ các bộ đếm
    (cả `extra`); `start` báo "no data" khi không có packet. `camera`, `video`: kiểm tra lề 8
    frame mỗi điểm sau mỗi lần hiệu chỉnh; chỉ hiệu chỉnh lại khi link check (2,4 frame +
    6 ms) lỗi do tap hoặc không có dữ liệu (khi đó `cam` báo `calibration failed`, `error`),
    lỗi khác giữ tap; `camera` có lệnh `margin`.
  - DV: case `ovf` so từng pixel khi tràn FIFO; case mới `deskew`, `extra`, `loss`, `ovf2`,
    `ovf8`, `be` và unit test aligner `tb_dphy_align.sv` (53 case, nhiều case chạy cả với 1
    lane, 1 trên 2 lane và clock liên tục); lệnh `wrbe`, byte sau packet và burst thô (skew
    calibration) trong `stim.txt`; cột `tuser[1]` trong `out.txt`, `FRAME_ERR` trong bản
    ghi `fe`; mô hình tính đầu ra giữ 3 nhóm khi nhóm đầu có 1 pixel; `BOW_CDC_JITTER`
    (chỉ mô phỏng) cho `bow_cdc_pulse` nhận toggle muộn một chu kỳ ngẫu nhiên; 57 mutant
    RTL đều bị bắt; 29 unit test.
  - Test mức chân xsim: giá trị của driver, burst skew calibration, T_EOT max, T_HS-PREPARE
    min/max với HS-ZERO đúng tối thiểu trên mọi lane và sync giả ở cuối HS-PREPARE; kiểm
    white-box cửa sổ dò đầu tiên bắt đầu trong HS-zero; quét `+SETTLE=`: 20…28 đạt.
  - SoC sim `camera`: `cam` lại với tap giữ nguyên, lỗi FRAME (`taps kept`), cảm biến im
    lặng (`error`). SoC sim `csi2`: margin khi eye trôi với thời gian frame như cảm biến
    thật và điểm lỗi không phải điểm cuối.
  - `kv260_cam`: `phys_opt_design` sau route (đường macroblock H.264 ở 200 MHz thiếu
    26 ps sau thay đổi này); WNS +0,005 ns, bus skew đạt. KV260: `csi2_test` 18/18,
    `camera` và `video` chạy đúng.
- Review IP DDR theo mục tiêu công nghiệp và SoC camera AI: băng thông (cửa sổ 32 bit
  5 / 3,6 MB/s, DRAM 267 MB/s, cần ≈ 1–2 GB/s), refresh 3,9 µs khi Tc > 85 °C, ECC, bám pha
  theo nhiệt, QoS, DFI chuẩn cho PHY ASIC; lộ trình P0–P3
  ([docs/ddr_review_industrial_ai.md](docs/ddr_review_industrial_ai.md)).
- **Mã khối MKV** `bow_mkv` (`hw/ip/mkv`) theo TCVN 14263:2024 "Thuật toán mã khối
  MKV" (lúc đầu theo bản dự thảo, xem Changed): MKV-128 (khoá 128 / 192 / 256 bit)
  và MKV-256 (khoá 256 / 384 / 512 bit), R = 7 / 8 / 9. Lược đồ khoá trong phần cứng (8R + 1 chu kỳ, khoá nửa vòng trong
  RAM 32 × 256 bit LUTRAM), mã hoá / giải mã một khối 2R + 2 chu kỳ (một nửa vòng
  mỗi chu kỳ, datapath 256 bit chung cho hai cỡ khối), `CLEAR` xoá khoá, `KEY` chỉ
  ghi, lệnh lỗi → `ERR`, ghi `CMD` / đọc `DOUT` tự chờ trên bus khi đang bận, `DIN`
  ghi được khi đang chạy. Thanh ghi `MKV` ở `0x4000_B000`, ngắt `irq_fast[10]`;
  9 524 LUT, 2 282 FF ([docs/ip/mkv.md](docs/ip/mkv.md)).
- Hai sai khác giữa văn bản dự thảo và Phụ lục A của nó, chứng minh bằng chính
  véc tơ kiểm tra và giữ thành test: ma trận M4 có `0x0D` (không phải `0x0C`) ở
  (2, 3) và (3, 0); hằng số lần cập nhật khoá `i` là `2i` / `2i − 1` ở nửa khoá
  đầu (`⟨v⟩_l ‖ 0`), không phải `⟨2(i−1)⟩_2l` / `⟨2(i−1)+1⟩_2l`. TCVN 14263:2024 đã
  sửa cả hai.
- `tools/mkv/extract_vectors.py`: trích S-box, ma trận và 6 véc tơ của Phụ lục A
  bản dự thảo (khoá vòng, 6 bước mỗi vòng, bản mã) từ PDF vào
  `tools/mkv/draft_vectors.json`; Phụ lục A của TCVN 14263:2024 (ảnh scan) chép vào
  `tools/mkv/tcvn14263_vectors.json`. `tools/mkv/mkv_model.py`: mô hình tham chiếu
  (`selftest` với mọi giá trị của cả hai phụ lục, `gen` / `check` cho testbench,
  `tables`: bảng RTL / C và véc tơ C, trong `make gen` / `gen-check`); 28 unit test
  `tools/tests/test_mkv_model.py`.
- Testbench IP `hw/ip/mkv/dv` (`make test-ip`, CI): Phụ lục A + khoá/khối ngẫu
  nhiên qua bus thanh ghi, so cả trạng thái sau mỗi nửa vòng và RAM khoá vòng với
  mô hình; test có hướng cho lỗi, `KEY_VALID`, `CLEAR`, ngắt, `CYCLES`, stall.
- Driver `bow_mkv.h/.c` (`bow_mkv_set_key`, `encrypt`, `decrypt`, `ecb`, `clear`);
  ứng dụng `mkv` (`test`, `kat`, `key` / `enc` / `dec`, `bench`) với MKV phần mềm
  `mkv_sw.c` để đối chiếu; tool `tools/bow32_mkv.py` (`test`, `kat`, `verify`,
  `bench`) so kết quả của board với mô hình Python.
- Test mô phỏng hệ thống `mkv`.
- Kết quả trên KV260 (bitstream `kv260_cam`, timing đạt): `test` PASS 13/13,
  `kat` 6/6 bản mã trùng Phụ lục A của TCVN 14263:2024, `verify` 360/360 khối ngẫu
  nhiên trùng mô hình; ECB 127 / 239 chu kỳ mỗi khối (MKV-128 / MKV-256), nhanh hơn
  MKV phần mềm trên Ibex 140…360 lần mỗi khối ([docs/mkv_kv260.md](docs/mkv_kv260.md)).
- **Bộ mã hoá H.264** `bow_h264` (`hw/ip/h264`): đầu ra ISP (YUV 4:4:4) →
  byte stream H.264 Annex B, Constrained Baseline, intra only (mỗi frame một
  IDR slice `I_16x16`, CAVLC). 4:2:0 (trung bình 2x2), strip buffer 4 × 16 dòng
  (UltraRAM), dự đoán luma V/H/DC/plane + chroma DC/H/V/plane chọn theo SAD,
  DCT 4x4, lượng tử, DC Hadamard, tái tạo đúng chuẩn, CAVLC (nC, coeff_token,
  level, total_zeros, run_before), emulation prevention, NAL đệm tới 4 byte.
  QP 10…51 mỗi frame, FRAMES / SKIP, cờ deblocking, thống kê (FRAME_BYTES,
  FRAME_CYCLES, MB_CYCLES); frame lỗi / encoder chậm vẫn cho stream hợp lệ
  (ERR_INPUT / ERR_OVF). 392 chu kỳ/macroblock ở clock video 200 MHz. Thanh
  ghi `H264` ở `0x4000_9000`, ngắt `irq_fast[8]` ([docs/ip/h264.md](docs/ip/h264.md)).
- **DMA** `bow_dma` (`hw/ip/dma`): bus master thứ ba của main crossbar, 2 kênh
  memory→memory / stream→memory (tuyến tính, vòng, DROP), đếm packet, lỗi bus,
  ngắt. Kênh 0 nhận stream H.264. Thanh ghi `DMA` ở `0x4000_A000`, ngắt
  `irq_fast[9]` ([docs/ip/dma.md](docs/ip/dma.md)).
- **Video RAM** `bow_vram`: 1 MiB ở `0x2400_0000` (UltraRAM, 0 wait-state),
  vùng `VRAM` trong linker script; `bow_uram_sdp` (RAM 2 port kiểu UltraRAM) trong
  `hw/ip/common`.
- Mô hình bit-exact `tools/h264/h264_model.py` (encoder, decoder cho đúng tập con
  này, SPS/PPS, sinh bảng CAVLC cho RTL `bow_h264_tables_pkg.sv`, lệnh
  `gen` / `check` / `decode` / `tables`), đối chiếu với FFmpeg: giải mã trùng từng
  pixel. `tools/h264/mp4.py`: ghi MP4 (fast start) không cần ffmpeg.
- Testbench IP `hw/ip/h264/dv` (`make test-ip`): stream RTL trùng từng byte với mô
  hình (kích thước, crop, QP đổi từng frame, SKIP, deblocking, khoảng trống đầu
  vào, back-pressure đầu ra, 2 clock lệch); CI chạy nó.
- Driver `bow_h264.h/.c` (SPS/PPS giống từng byte mô hình), `bow_dma.h`.
- Ứng dụng `video`: camera / TPG → ISP (BT.709 video range) → H.264 → DMA → VRAM,
  rate control mỗi frame, dừng an toàn khi VRAM gần đầy, `send` qua UART0,
  `dmatest`. Tool `tools/bow32_video.py`: quay và ghi `.h264` + `.mp4`.
- Test mô phỏng `h264`: `dmatest`, TPG 64×48 → 3 frame qua UART, stream được
  giải mã và kiểm tra 8 sọc màu.
- Unit test `tools/tests/test_h264_model.py` (mô hình, MP4, tool, bảng RTL, SPS/PPS
  của C; đối chiếu FFmpeg khi có PyAV).
- **Bộ thu MIPI CSI-2** `bow_csi2rx` (`hw/ip/csi2rx`), thay MIPI CSI-2 RX
  Subsystem của AMD: phần số của D-PHY (máy trạng thái LP bật bộ thu HS và
  termination, cổng byte clock, phát hiện mất clock, tìm sync 0xB8 và căn byte
  mỗi lane), ghép 1–2 lane, lớp packet (ECC header sửa 1 bit, CRC-16, lọc
  VC/DT, FS/FE), unpack RAW10/RAW8, FIFO 2 clock, đầu ra AXI4-Stream RAW10
  1 pixel/clock cho ISP. Bộ đếm lỗi, log 64 packet, 64 word thô mỗi lane, đo
  `FRAME_TIME`/`LINE_TIME`/`BYTECLK`. Thanh ghi `CSI2RX` ở `0x4000_8000`, ngắt
  `irq_fast[7]` ([docs/ip/csi2rx.md](docs/ip/csi2rx.md)).
- `bow_fifo_async` (FIFO 2 clock, con trỏ gray) trong `hw/ip/common`.
- D-PHY I/O cho UltraScale+ `hw/fpga/common/rtl/bow_dphy_io_xusp.sv`
  (`IBUFDS_DPHY`, `IDELAYE3` COUNT, `ISERDESE3` 1:8, 2 × `BUFGCE_DIV`) và test
  mức chân với unisim `make -C hw/fpga/common/dv test` (xsim, cần Vivado).
- Driver `bow_csi2rx.h/.c`: start/stop quanh stream, bộ đếm, link check, hiệu
  chỉnh eye của tap IDELAY lúc chạy, log packet, word thô, in trạng thái.
- Ứng dụng `csi2_test`: shell bring-up (`stat`, `cal`, `log`, `raw`, `delay`,
  `mode`, `tp`, `fmt`, `irq`, `rd`/`wr`) và `test [quick]` (11 check; trên
  board 16: 1080p30 và 720p60).
- Ứng dụng `camera`: lệnh `cal [step]`, `csilog [fs|fe]`, `csi` theo bộ thu mới;
  hiệu chỉnh eye ở `cam` đầu tiên.
- Mô hình Python `tools/csi2/csi2_model.py` (viết từ đặc tả, không từ RTL) +
  19 unit test; testbench IP `hw/ip/csi2rx/dv` với mô hình máy phát D-PHY
  `csi2_tx_model.sv` (30 case mặc định, 210/210 với 40 seed); `make test-ip`;
  CI chạy test IP của bộ thu.
- Test mô phỏng `csi2`: `csi2_test test quick` rồi cài lỗi (ECC, CRC, SoT/skew)
  và kiểm tra đúng số đếm.
- Kết quả trên KV260 + camera v2: `csi2_test: PASS (16/16)`, 2 lane ×
  912 Mbit/s, byte clock 114,06 MHz, frame 33326 µs (1080p30) / 16653 µs
  (720p60), không lỗi ECC/CRC/SoT trong nhiều phút, eye ~260 tap (~0,94 ns) mỗi
  lane; Vivado 2025.2: WNS +1,023 ns, bus skew 7/7 đạt, 0 lỗi DRC.
- **ISP** `bow_isp` (`hw/ip/isp`): RAW10 Bayer → RGB888 / YUV444, 1 pixel/clock,
  hai miền clock (CPU / video). Pipeline BLC, DPC (5×5), white balance,
  demosaic bilinear (3×3), CCM, gamma (3 LUT), CSC; thống kê (tổng RGB, luma,
  histogram 64 bin, AF, DPC); capture có lọc hộp 1/2/4/8 vào buffer 32K × 24 bit
  (`0x3000_0000`); test pattern generator; cấu hình staging + `UPDATE` giữa hai
  frame. Thanh ghi ở `0x4000_6000`, ngắt `irq_fast[5]`.
- Mô hình ISP bit-exact `tools/isp/isp_model.py` và testbench `hw/ip/isp/dv`
  (`make -C hw/ip/isp/dv test`).
- I2C master `bow_i2c` (`0x4000_7000`, `irq_fast[6]`), driver `bow_i2c.h`.
- Cầu Bow32 bus → AXI4-Lite `bow_axil_bridge` (cửa sổ `0x5000_0000`, timeout
  → bus error); `bow_probe_read32/write32` đọc/ghi không gây exception.
- Ứng dụng `camera`: driver IMX219 (1080p30, 720p60, mode tuỳ ý, test pattern,
  flip, exposure, gain), driver MIPI CSI-2 RX của AMD, AE, AWB gray world,
  capture và gửi ảnh qua UART.
- `tools/bow32_cam.py`: chụp ảnh về PNG, xem trực tiếp, chạy lệnh shell; unit test.
- Bitstream camera `hw/fpga/kv260_cam` (`make fpga BOARD=kv260_cam`): block design
  PS + clk_wiz + MIPI CSI-2 RX Subsystem (2 lane, 912 Mbit/s, RAW10), ISP 200 MHz.
- KV260 (cả hai bản): PA7 = RPI_ENABLE (F11), I2C0 = switch I2C TCA9546A của
  camera (G11/F10).
- Test mô phỏng `camera`: mô hình TCA9546A + IMX219 (I2C), luồng CSI-2, thanh
  ghi CSI-2 RX (AXI4-Lite), kiểm tra ảnh sọc màu RGB/YUV, AE/AWB.
- Thư viện chung: `bow_cdc_pulse`, `bow_rst_sync`, `bow_ram_sdp` (RAM 2 clock).
- IP GPIO / IOPAD `bow_gpio`: GPIOA, GPIOB (2 × 8 chân) ở `0x4000_4000` /
  `0x4000_5000`, ngắt `irq_fast[3]` / `irq_fast[4]`; hướng, push-pull/open-drain,
  set/clear/toggle nguyên tử, ngắt theo cạnh, chức năng thay thế (pinmux).
- Driver `bow_gpio.h`, ứng dụng `gpio_demo` (shell lệnh trên UART0), test mô
  phỏng `gpio`.
- KV260: PA0..PA3 ra PMOD J2 chân 2/4/6/8 (`IOBUF`, pull-up).
- `make fpga-jtag`: nạp bitstream qua JTAG bằng xsdb (nhả PROG_B, gỡ cách ly
  PS-PL, nhả `pl_resetn0`).
- `bow32_flash.py monitor` là terminal tương tác; báo lỗi rõ khi adapter không
  gửi được BREAK.
- Đánh giá IP MKV cho SoC camera AI ([docs/mkv_security_review.md](docs/mkv_security_review.md)):
  mô hình đe doạ, chuẩn tham chiếu (TCVN 14263, QĐ 724/QĐ-BTTTT, ISO/IEC 19790, 17825,
  CRA, CWE), phát hiện về tiêm lỗi, kênh kề, khoá, tích hợp, kiểm chứng, lộ trình P0–P2.
  `make -C hw/ip/mkv/dv review` (`tb_mkv_review.sv`, nay trong `make test` của IP) chạy 8 thí
  nghiệm: lỗi 2 bit trong một byte khoá vòng và dòng RAM bị tráo cho bản mã sai mà không
  `FAULT`, `dout_q` không được kiểm, `CLEAR` / xoá sau reset cắt ngắn được, FSM, giữ bus
  144 chu kỳ, không giới hạn số lần thử.

### Changed
- Bộ thu CSI-2, bước 6 (xem *Added*): PPI v1.x giữa D-PHY và controller: `ErrControl` /
  `ErrControlClk` là bộ đếm gray 2 bit (bước 2–5: xung một chu kỳ ở bit 0), `RxSkewCalHS` mức (bước
  2–5: xung; controller đếm cạnh lên, nên `CNT_EXT[31:16]` không đổi), `PpiLpClkHz` của controller
  được tới 32 × `PhyClkHz` (trước: phải bằng); wrapper cổng phẳng đổi xung lỗi của PHY chuẩn thành bộ
  đếm gray ở clock lp của PHY (tham số mới `LpClkHz`). Bản đồ thanh ghi D-PHY: `CMD[1]` là REINIT của
  máy LP, hiệu chỉnh AFE chuyển sang `CMD[2]` AFE_CAL (driver `bow_dphy_rx_reinit()` ghi cả hai);
  `CTRL` / `TIM0` có hiệu lực sau `CMD.APPLY` (driver ghi APPLY; phần mềm khác phải ghi `CMD` = 1
  sau khi đổi chúng); `INFO` có bit 27 (KV260 `0x0824C822`, Huins `0x08A4C844`); HS_TMO cũng vào
  `ERR_STATUS[3]`. Ràng buộc `set_bus_skew`: 11 trên KV260, 12 trên Huins (bộ đếm sự kiện của
  D-PHY). Kiểm tra CDC ngoài ngữ cảnh của KV260 nhận thêm flop termination (`term_q`) trước
  `ISERDESE3`, cùng loại với `hs_en_q`. Bench xsim KV260 ghi `CMD.APPLY` sau `TIM0`.
- Bộ thu CSI-2, bước 5 (xem *Added*): cổng PHY `dphy_*` của `bow32_top` (và cổng của `bow_mipi_rx`)
  thành giao diện AFE ở cả sáu nơi dùng, cổng cũ không giữ: `byte_clk_i` / `rx_data_i` /
  `rx_valid_i` → `hs_byte_clk_i` / `hs_data_i` / `hs_valid_i`, `byte_ce_o` → `clk_gate_en_o`,
  `byte_rst_o` và `burst_rst_en_o` → `des_rst_o`, `clk_hs_en_o` / `hs_en_o` → `*hsrx_en_o` +
  `*term_en_o`, `dly_tap_o` / `dly_load_o` / `dly_tap_i` → `dly_code_o` / `dly_own_o` / `dly_q_i`,
  `reinit_o` → `cal_start_o`, `phy_rdy_i` / `phy_status_i` → `ready_i` / `status_i`, mới `pd_o`,
  `*lprx_en_o`; tham số `CsiDlyVid` → `CsiAfeKind`. Hai adapter đổi cổng theo (giữ tên file và
  instance của XDC; Versal: `reinit_i` → `pd_i` + `cal_start_i`, `burst_rst_en_i` → `des_rst_i`);
  ràng buộc bus skew của mã delay trong `huins_vp1902_cam.xdc` chọn mã + OWN của `u_dphy_rx/u_regs`
  và bộ đồng bộ của adapter (`u_dphy/u_dly`), số ràng buộc giữ 11 / 9. Hành vi đổi có chủ ý: trên
  Versal ghi lại đúng mã delay đang dùng (OWN đã 1) không nạp nữa (bước 4: mỗi lần ghi `DLYn` một
  lần nạp) và lần nạp tới XPHY sớm hơn vài chu kỳ lp; `CTRL.DES_RST_DIS` = 1 nay cũng tắt reset
  `ISERDESE3` của KV260 (bit thử, firmware không đặt); `AFE_CTRL` (`0x4000_8C14`) đọc PD (0) thay
  cho "đọc 0". Firmware không đổi (`bow_dphy_rx.h`: chú thích và macro mới `DPHY_AFE_CTRL_PD`,
  `DPHY_AFE_CAL_DONE`, `DPHY_AFE_CAL_ERR`; object code giống từng byte bước 4).
- Bộ thu CSI-2, bước 4 (xem *Added*): **không có alias**: các thanh ghi PHY cũ của controller
  (`PHY_CFG`, phần LP / HS / CE / BYTECLK_OK / PHY_RDY của `STATUS`, `CNT_BURST`, `CNT_BURST23`,
  `CNT_MISC[23:0]`, `BYTECLK`, `DLY0`…`3`, `RAW_CTRL`, `RAW` ở `0x800`, `CTRL.CLK_FORCE`, `INFO[5]`,
  `IRQ_STATUS[4]`) đọc 0; `INFO[6]` mới của controller = "D-PHY ở `0xC00`", driver từ chối bitstream
  trước bước 4 (`csi2rx: bitstream before the D-PHY split, rebuild it`): PDI / bitstream và firmware
  phải cùng commit. Dải phụ tạm thời của bước 2–3 bỏ hẳn; D-PHY che `ErrControl[l]` theo `Enable`
  của lane và `ErrControlClk` khi `CTRL.CLK_CONT` (`CLK_FORCE` cũ), controller chỉ còn OR của chúng.
  Hành vi đổi: lỗi LP của lane clock khi `CLK_CONT` = 1 và lỗi của một data lane ở chu kỳ enable của
  nó vừa xuống không còn vào `ERR_STATUS.LP` / `CNT_MISC[23:16]` của controller (`CNT_LPERR`,
  `ERR_STATUS.CONTROL`, `ERR_LANE` của D-PHY vẫn thấy chúng); aligner không còn bị reset khi RX tắt
  (DV `stop` không đổi kết quả), còn controller đếm sự kiện của nó như trước (*Fixed*). Top camera
  Huins thôi nối GPIO PA4 / PA5 / PB6 / PB7: `reinit_i` từ `CMD.REINIT` (xung 32 chu kỳ, thay mức
  phần mềm giữ trên PA4), `burst_rst_en_i` = ¬`CTRL.DES_RST_DIS` (1 từ reset: `BurstRxRst` bật ngay
  từ reset, trước đó PA5 = 0 tới khi firmware đặt 1), trạng thái thô của XPHY vào
  `AFE_STATUS[15:8]`, LED10 = `AFE_STATUS.READY`. `bow_csi2rx.h` / `.c` chỉ còn lớp CSI-2 (delay,
  RAW, đồng hồ đo, bộ đếm PHY sang `bow_dphy_rx`); `cam_sensor.c` ghi `DES_RST_DIS` thay cho PA5;
  lệnh `phy`, `phy reinit`, `phy burstrst` của `csi2_test` đọc / ghi thanh ghi D-PHY (`phy: READY 1,
  every nibble PHY_RDY 1 DLY_RDY 1, XPLL LOCKED 1 LOCKED_FB 1 (AFE_STATUS 00000f01), DES_RST_DIS 0`;
  `phy: READY n us after CMD.REINIT`), `phy-idle` in `LANE_LP` / `LANE_HS`. Mô phỏng: `csi2_274` so
  `rd 40008c24` (`TIM0`) = `051e0213` thay cho `rd 4000800c`, `csi2` thêm `rd 40008c24` =
  `04100209`, `+S274_PA5` thành `+S274_DESRST`, `FW=brst0` dùng `-DDPHY_SETTLE_NS=140u`; DV `csi2rx`
  theo bản đồ mới (dump đọc cả hai khối và địa chỉ cũ, `be` phủ cửa sổ D-PHY, PHY Versal của bench
  nhận re-init / `BurstRxRst` từ bộ thu), bench PPI không còn dải phụ (`lpmask`: OR của mọi lane),
  mutant PPI 19; XDC (`kv260_cam.xdc`, `huins_vp1902_cam.xdc`): selector req / ack của RAW và yêu
  cầu / mã của `DLYn` theo cell mới trong `u_dphy_rx` (vẫn 9 / 11 ràng buộc bus skew).
- Bộ thu CSI-2, bước 2 của kế hoạch chuyển MIPI RX ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 5.3, 10): `bow_mipi_rx` (`hw/ip/csi2rx/rtl/`, cổng và tham số như `bow_csi2rx` trước đây,
  instance vẫn tên `u_csi2rx` trong `bow32_top`) ghép `bow_dphy_rx` (`u_dphy_rx`) và controller
  CSI-2 `bow_csi2rx` (`u_csi2rx`) bằng PPI v1 (`bow_ppi_pkg`, 8 bit mỗi lane: `ppi_hs_t` miền byte,
  `ppi_lp_t` / `ppi_lp_clk_t` miền lp, `RxByteClkHS`, `Enable`) cộng một dải phụ tạm thời (cổng
  `band_*`: reset, `CLK_FORCE`, `PHY_CFG`, `DLYn`, trạng thái PHY, xung vào HS, word thô cho RAW),
  mỗi tín hiệu ghi bước 4 hay 5 bỏ nó. `ErrControl` / `ErrControlClk` là xung cùng clock
  (`PpiLpClkHz` của controller phải bằng `PhyClkHz`, kiểm khi elaborate); luật đánh dấu burst mất
  về controller, `ev_lp_loss_o` bỏ; reset aligner `drst_n` qua dải phụ. Cổng, thanh ghi, XDC và
  hành vi không đổi: Formality `make -C hw/ip/dphy_rx/fm equiv STEP=2` (luật đổi tên theo bước,
  top `bow_mipi_rx` phía implementation) tương đương 5/5 cấu hình với `3a1e780` và với `35ef151`,
  mọi cặp cùng tên; DV `csi2rx` và log của các test camera trong `make test` giống bước 1. `make
  lint` lint thêm `bow_mipi_rx` và controller một mình; luật CDC-11 của bản camera Huins cắt đường
  ở bộ thu `u_csi2rx` đầu tiên (`make -C hw/fpga/huins_vp1902 test-cdc`); `sim/tb/tb_bow32.sv` đọc
  `dut.u_csi2rx.u_csi2rx.cfg.phy_en`. Sau review: `bow_ppi_pkg` chuyển vào `hw/ip/common`
  (`common.f`), controller không cần nguồn của D-PHY; `PpiLpClkHz` không còn mặc định (mọi
  instance phải nêu clock lp của PHY); luồng Formality chỉ đổi tên phía implementation và kiểm
  từng cell nằm đúng khối D-PHY / controller (`partition.rpt`); bộ kiểm `bow_ppi_chk`
  (`hw/ip/dphy_rx/dv`, bind vào `bow_dphy_rx` trong DV `csi2rx` và `sim`) kiểm các đầu ra PPI v1
  mà controller chưa dùng.
- Bộ thu CSI-2, bước 1 của kế hoạch chuyển MIPI RX ([docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 10): phần số của D-PHY (máy LP, phát hiện cạnh byte clock, `byte_rst`, flop word, đồng
  bộ `arm`, aligner, nạp tap, đồng hồ đo byte clock và các bộ đồng bộ của chúng) tách thành
  `bow_dphy_rx` (`hw/ip/dphy_rx/`, instance `u_dphy_rx` bên trong `bow_csi2rx`); cổng và bản đồ
  thanh ghi của `bow_csi2rx` không đổi, RAW vẫn ở `bow_csi2_capture`. `bow_dphy_lp` và
  `bow_dphy_align` chuyển sang `hw/ip/dphy_rx/rtl/`, `bow_csi2_sync` thành `bow_sync_bus`
  (`hw/ip/common/rtl/`, tên instance và `g_bit` giữ nguyên). Tương đương hình thức với `main`
  trước bước 1 (`3a1e780`): Synopsys Formality, RTL với RTL, 5 cấu hình (`make -C
  hw/ip/dphy_rx/fm equiv`; thay cho Yosys eqy, D8 sửa đổi đã duyệt ngày 2026-11-11), đạt khi mọi compare point
  tương đương và mọi cặp khớp có tên giống hệt sau luật đổi tên `u_dphy_rx/` → rỗng; `REF` có
  thể là commit từ bước 1 trở đi; `make lint` lint thêm `bow_dphy_rx` một mình; `make -C
  hw/fpga/common/dv` bỏ qua file không còn tồn tại trong `build/fpga_dv/files.txt` cũ (thư mục
  build có từ trước khi chuyển file không còn báo "No rule to make target"). Trước đó (bước 1a):
  `set_bus_skew` của bộ thu trong `kv260_cam.xdc` / `huins_vp1902_cam.xdc` và danh sách CDC đã
  duyệt của bản camera Huins chọn cell theo đuôi tên phân cấp (`make -C hw/fpga/huins_vp1902
  test-cdc`; cell D-PHY chỉ được nhận ở dưới `u_csi2rx`), probe hộp trắng của
  `tb_bow_dphy_io_xusp` gắn vào `bow_dphy_align` bằng `bind`. `tcl/build.tcl` của `kv260_cam` và
  của bản camera Huins kiểm cell của từng `set_bus_skew` (`hw/fpga/common/tcl/bus_skew_checks.tcl`,
  test tclsh trong `make test-tools`): cell ngoài khối của ràng buộc, flop đích không có đường từ
  nguồn hay số flop nguồn khác số flop đích là `CRITICAL WARNING`.
- `kv260_cam`: `tcl/build.tcl` dùng directive `Explore` cho place, phys_opt và route (với RTL bộ
  thu 4 lane, clock video 200 MHz còn −0,040 ns với directive mặc định, +0,065 ns với
  `Explore`).
- CI: bước mô phỏng hệ thống chạy cả hai bản dựng của testbench (KV260 và IMX274), lưu
  `build/sim/h264*.hex`.
- DDR: lõi LiteDRAM sinh với `trefi_ns: 3900` (`ddr2.yml`, `ddr3.yml`; DDR2 129 chu kỳ,
  DDR3 121), bộ đếm refresh của lõi có thêm chu kỳ 2 × tREFI (chân `ref_norm`, đi theo
  `CTRL.REF_NORM`); kiểm tra lúc elaboration theo 3,9 µs. Mặc định 3,9 µs chậm hơn: BIST trên
  MPS4 ghi / đọc 213,7 / 213,7 MB/s, so với 233,5 / 226,4 MB/s ở 7,8 µs. `REF_STARVE` của
  emulator / mô hình DRAM kiểm thêm nợ REF trung bình (hoãn tối đa 8, trả trước tối đa 8)
  bên cạnh 9 × tREFI không có REF.
- `bow_ddr_ps` chuyển sang `hw/ip/common` thành `bow_mmcm_ps` (dùng chung cho DDR và HyperRAM).
- `bow_ddr_clk_xusp` xuất thêm đầu ra IBUF của oscillator (`clk_ibuf_o`) cho các cây clock
  khác; cây clock DDR giữ nguyên.
- **MKV theo TCVN 14263:2024** thay cho bản dự thảo. Bản chuẩn khác bản dự thảo ở
  ba điểm của thuật toán, nên là một mã khác (dữ liệu mã bằng IP cũ không giải mã
  được bằng IP mới) ([docs/ip/mkv.md](docs/ip/mkv.md), "So với bản dự thảo"):
  - R = 7 / 8 / 9 vòng (dự thảo 6 / 7 / 8): `KEY` 16R + 2 = 114 / 130 / 146 chu kỳ,
    `ENC` / `DEC` 4R + 4 = 32 / 36 / 40;
  - `MixWords` xoay cột `c` đi `c·w/4` bit trước khi nhân ma trận, `invMixWords`
    xoay ngược sau khi nhân (chỉ là nối dây);
  - lược đồ khoá cộng thêm hằng số `Const⁰_l` / `Const¹_l` (điều 5.5) vào khoá
    của `F` đầu ở mỗi nhánh.

  `ID` = `0x4D4B5602` (phiên bản 2), để phần mềm nhận ra bitstream cũ
  (`0x4D4B5601`, mã của bản dự thảo). Driver (`bow_mkv_rounds`), MKV phần mềm
  `mkv_sw.c` (R tối đa 9), bảng sinh tự động (thêm hằng số), testbench, test hệ
  thống `mkv` theo chuẩn. Mô hình giữ bản dự thảo (`edition(DRAFT)`) và test kiểm
  rằng thiếu bất kỳ điểm nào trong ba điểm thì sai véc tơ của chuẩn. Mô hình và RTL
  khớp cả 288 giá trị chép từ Phụ lục A của chuẩn. Diện tích không đổi: `kv260_cam`
  MKV 9 526 → 9 524 LUT, 2 278 → 2 282 FF so với `main` build lại cùng flow (tổng hợp
  riêng IP: +14 LUT); timing đạt. Trên KV260: `test` 13/13, `kat` 6/6, `verify`
  360/360.
- `bow32_top`: main crossbar 3 host (thêm DMA) × 7 device (thêm VRAM), peripheral
  bus 11 slot (thêm H264, DMA); đầu ra ISP đi vào bộ mã hoá H.264; tham số
  `VramBytes`, `H264MaxWidth`, `H264Strips`.
- `kv260_cam.xdc`: 2 `set_bus_skew` cho FIFO đầu ra của H.264 (`build.tcl` kiểm tra 9).
- `make gen` / `gen-check` gồm bảng CAVLC của RTL.
- `kv260_cam`: chân D-PHY J9 vào `bow_dphy_io_xusp` + `bow_csi2rx`; block design
  `bow32_cam` chỉ còn PS + `clk_wiz` + 2 `proc_sys_reset` (không cần IP hay
  license MIPI); XDC mới (HS clock 2,193 ns, nhóm clock bất đồng bộ, false path
  cho data và CE, `CLOCK_DELAY_GROUP`, 7 `set_bus_skew`); `build.tcl` ghi thêm
  báo cáo clocks / clock_interaction / check_timing / methodology / drc /
  bus_skew + `clockInfo.txt` và cảnh báo khi bus skew hoặc clock delay group sai.
- `bow32_top`: bỏ port `cam_t*`, thêm port `dphy_*` và tham số `CsiLanes`,
  `CsiPhy`, `VidClkHz`; peripheral bus 9 slot. Bản `kv260` cơ bản có CSI2RX
  không có D-PHY (`CsiPhy = 0`, mọi lane LP-11).
- Driver IMX219 chuyển từ `sw/apps/camera` sang `sw/common` (`imx219.h/.c`):
  probe stream 100 µs để lane vào LP-11, format RAW8/RAW10, màu cho test
  pattern màu đơn, pattern 0–4.
- Test `camera`: luồng D-PHY qua `csi2_tx_model.sv` + mô hình IMX219 (LP-00 sau
  khi bật nguồn; FS, 2 dòng embedded, các dòng, FE; mỗi packet một burst),
  clock video 107,5 MHz.
- Cửa sổ AXI4-Lite `0x5000_0000`: không còn thiết bị trong `kv260_cam` (truy cập
  timeout → bus error).
- `bow32_top`: thêm port I2C0, miền clock video + luồng camera/ISP, master
  AXI4-Lite; main crossbar 2×6, peripheral bus 8 slot.
- `bow_rr_arbiter` khoá grant cho tới khi device nhận request.
- UART1 là chức năng thay thế của PB0 (TX) / PB1 (RX), bật sau reset:
  `bow32_top` bỏ port `uart1_rx_i/uart1_tx_o`, thêm `gpioa_*` / `gpiob_*`. Trên
  KV260 UART1 vẫn ở J2 chân 5/7.

### Removed
- Tài liệu của hãng và bản dự thảo TCVN khỏi repo và khỏi toàn bộ lịch sử git (repo
  public): TRM bo MPS4 của Arm, schematic carrier KV260 của AMD và
  `docs/ref/Du-thao-TCVN-XXXX2024.pdf`. Lịch sử được viết lại ngày 2026-11-06: mọi commit
  đều có hash mới, clone cũ cần clone lại. Tài liệu của Arm/AMD
  (`docs/fpga/MPS4/`, `docs/fpga/vek280/`,
  `docs/fpga/xtp682-kria-k26-carrier-card-schematic/`) và hai PDF TCVN chỉ để bản cục bộ
  (`.gitignore`). Bảng và véc tơ của bản dự thảo vẫn ở `tools/mkv/draft_vectors.json`.
- MIPI CSI-2 RX Subsystem của AMD trong block design `bow32_cam` và driver của
  nó (`sw/apps/camera/csi2rx.c/.h`).

### Fixed
- Bộ thu CSI-2, bước 6 (sửa sau review, trước khi gộp; [docs/ip/mipi_rx_arch.md](docs/ip/mipi_rx_arch.md)
  mục 10, *Sửa sau review bước 6*): mức ULPS trên PPI theo thứ tự của PPI công khai
  (`UlpsActiveNot*` = ¬`Ulps`, lên lại ở mark thức dậy; `RxUlpsEsc` / ¬`RxUlpsClkNot` tới LP-11 cuối
  lần thức dậy; bản đầu ngược lại), LP-00 sau một mark lạc đưa lane về `Ulps` (`lane_pd` lên lại),
  `IRQ_STATUS.ULPS` của lần thoát chỉ ở LP-11; `CMD.REINIT` ở lane clock đang HS qua `Exit` (cổng
  đóng trước, bộ thu và termination 2 chu kỳ sau, rồi `WaitStop`; bản đầu tắt cả hai cùng cạnh);
  `HS_TMO` / `ESC_TMO` so bằng ≥ (một giá trị nhỏ hơn số đếm đang chạy có tác dụng ngay, không chờ bộ
  đếm quay vòng); `ID` = `0x44505202` (`ID[7:0]` = phiên bản bản đồ thanh ghi, 2 vì `CMD[1]` đổi
  nghĩa) và driver từ chối phiên bản khác của nó ("csi2rx: D-PHY register map version 1, this
  firmware needs 2: ..."; firmware của bước 5 trên PDI mới: "csi2rx: bitstream before the D-PHY
  split, rebuild it"); `CMD[31]` DIRTY (đọc 1 khi một shadow được ghi từ lần APPLY cuối); adapter
  `HSRX_DISABLE` = ¬`term_en` (bản đầu ¬(`hsrx_en` ∨ `term_en`) bật termination từ LP-01 khi
  `HSRX_EARLY` = 1; mặc định không đổi). Ràng buộc: `set_bus_skew` mới của bản chép shadow →
  `cfg_lp_q` (cùng toggle APPLY) và của `CLK_TOG_DIV` → `u_sync_tdiv` (KV260 13, Huins 14);
  luật CDC-13 ngoài ngữ cảnh của KV260 nhận `term_q` thay `hs_en_q`. Driver: `CLK_MISS` tính theo
  `CLK_TOG_DIV` (`bow_dphy_rx_set_clk_tog_div()` tính lại nó), APPLY không xong là lỗi
  (`CSI2RX_EAPPLY`, `bow_csi2rx_strerror()`), `csi2_test` `phy tinit` / `phy hstmo` kiểm độ rộng
  trường và báo APPLY hỏng. Kiểm chứng: mô hình `BOW_SYNC_JITTER` của `bow_sync` chạy thật (bản đầu
  không bao giờ chạy: Verilator 5.020 không đánh thức `always @(d_i)`, clock của bench khoá pha),
  bench D-PHY với clock không là bội của nhau, `make test` hỏng khi không có lần nhận muộn nào; mô
  hình đó cho thấy giới hạn tỉ số clock của `CLK_TOG_DIV` trong tài liệu sai (đúng: byte clock <
  2^`CLK_TOG_DIV` × `lp_clk` có lề, mục 4.3); bench kiểm các bất biến AFE của mục 8.3 (cổng, bộ thu
  lane clock, ngân sách termination); `mutants_dphy.py` 53 mutant (18 mới), với 2 và 4 lane, 53/53
  chết; Formality `STEP=6` cắt ở `lp_err` hai phía thay vì giữ `ErrControl*` 0 (ba mutant lỗi lp
  của review nay hỏng); `csi2` / `csi2_274` kiểm `CMD` = 0 sau APPLY, `csi2_274` chạy `phy v1x` /
  `phy check`. Tài liệu: `CMD.REINIT` cũ của bước 4–5 là `CMD.AFE_CAL`; mỗi trường chưa làm có một
  bước (DSK_* bước 8, `DLY_REL` / `INFO[30]` bước 8, `CTRL.EN` / `LANE_EN` / SoT bước 10); LATE_EOT
  và HS_TMO trong `ERR_STATUS` là ngoại lệ chỉ báo cáo; quy trình SETTLE của Huins ghi `CMD.APPLY`.
- Bộ thu CSI-2, bước 4 (sửa sau review, trước khi gộp): từ khi aligner dùng reset riêng của D-PHY,
  controller vẫn biến `ErrSotSyncHS` / `RxSkewCalHS` của nó thành `CNT_SOT`, `ERR_STATUS.SOT`,
  `CNT_EXT[31:16]`, `IRQ_STATUS.ERR` cả khi RX tắt: burst khi `RX_EN` = 0 mà `PHY_EN` = 1 được đếm,
  và dừng bộ thu giữa lúc một burst dò sync sinh một lỗi SoT trên mọi lane đang dò, tới cùng burst
  đầu sau khi chạy lại (byte clock đã dừng trước khi `RxActiveHS` xuống), tức sau khi `start()` đã
  xoá bộ đếm: link check sau một lần chạy lại có thể hỏng. Controller nay bỏ các sự kiện đó khi
  reset đường dữ liệu đang bật và ở burst mà `RxActiveHS` của lane đã cao lúc reset nhả (`stale_q`),
  đúng cách đếm của bước 1–3; datapath pixel không đổi (271 case DV cũ cho kích thích, pixel, thanh
  ghi và log giống từng byte). DV mới `rxoff` (1, 2, 4 lane) và `raw` (RAW của D-PHY với khe đọc của
  PHY Versal sau sync và lane 0 vào HS muộn: hai mutant RAW của bước 3 lại bị bắt), mutant mới
  `mutants-rx` của DV (5/5). Driver: `bow_dphy_rx_settle()` với lane rate 0 trên Versal cho
  `0x13` như `SETTLE_VID_NS` cũ (bản đầu cho 14), test host quét cả lane rate 0 và đích `brst0`;
  dòng `phy:` của `stat` là một ảnh chụp (`LANE_LP` / `LANE_HS` và bộ đếm của D-PHY đọc tới khi hai
  lần giống nhau). Đặc tả mục 5.5: hồ sơ PPI theo wrapper của bước 4 (không `phy_ready_i`, không
  `STATUS.CE` / `PHY_RDY`, không mặt nạ enable lane) và yêu cầu mới cho PHY chuẩn: chỉ báo
  `ErrControl[l]` khi `Enable[l]` = 1.
- DV bộ thu CSI-2 (`csi2_model.py`): test `deskew` và `loss` trên bộ thu 4 lane với PHY Versal
  (`BurstRxRst` = 0) hỏng ở khoảng 1/3 seed Verilator (trên `main` 9/30 và 10/30; directed test chỉ
  chạy seed 1 nên không thấy): trễ FIFO trôi theo word glitch đưa cửa sổ dò sync vào nhiễu
  HS-PREPARE, nơi luật leader của deskew không nhận burst deskew; mô hình coi cửa sổ bắt đầu trong
  HS-zero. Hai test đó nay chạy không có word glitch (0/30 hỏng ở cả 4 cấu hình); random vẫn có
  trôi. `docs/simulation.md`: `TIM0` (`PHY_CFG`) của mô phỏng KV260 là 9/16/4 chu kỳ, không phải 8.
- Unit test aligner (`hw/ip/csi2rx/dv/tb_dphy_align.sv`): với Verilator 5.020 queue cục bộ của
  hàm `pack()`/`mk()` giữ nội dung của lần gọi trước cùng chỗ gọi, nên case "pha k" phát lại
  burst của pha 0…k−1 trước (deskew pha 1–7 thật ra được nhận ở burst pha 0); nay xoá queue
  đầu mỗi lần gọi, mọi pha được thử riêng.
- Bộ thu CSI-2 (`bow_csi2_lane_merge`): lệch đúng 7 byte clock giữa các lane cho SKEW kèm packet
  bị cắt (TRUNC) vì word vẫn được lấy ra trong chu kỳ tràn; giờ chu kỳ đó không lấy word nào:
  0–6 byte clock nhận đúng, từ 7 chỉ SKEW, không ra gì (test `skew` của `hw/ip/csi2rx/dv`).
- Self-test HyperRAM: dòng chi tiết không kèm số in thêm `(null)(null)` (thấy trên bo RAM ở
  mục [14]: `level shifters: variable latency refused (fixed only)(null)(null)`); `detail()`
  giờ nhận số đối số tùy ý.
- `docs/hyperram_mps4.md`: hướng dẫn cũ bảo `restore` và trả `FMC_FORCE` về `1V2` ngay sau
  khi thử, lúc bo RAM còn cắm (lần bật kế tiếp cấp 1,2 V cho TXV0108 hay nạp thiết kế khác với
  bo RAM trên khe); giờ tháo bo RAM trước (mục 5.4).
- CI: test hệ thống `ddr` hỏng với Verilator 5.020 (`init: APPLY refused`).
  Verilator trước 5.022 inline `ddr_clk_model` (1 ps) vào `tb_bow32` (1 ns) và tính
  delay theo đơn vị 1 ns của module cha (verilator/verilator#4806). Kết quả là clock
  DDR chạy giật cục và `CLK_OK` rớt. Giờ mô hình không bị inline nữa
  (`no_inline_module`) và tự kiểm tra thời điểm của mỗi cạnh CK.
- `kv260_cam` build được với Vivado 2025.2 (`tcl/cam_bd.tcl`):
  `make_bd_pins_external` bỏ qua pin đã nối nên port `sys_clk`/`vid_clk`/
  `*_resetn` được tạo bằng `create_bd_port`; `C_EN_CSI_V2_0` đưa
  `CMN_PXL_FORMAT` của CSI-2 RX về RAW8 nên tham số chính được đặt lại sau và
  kiểm tra lại (cả vị trí chân D-PHY); `clk_wiz` lấy tần số vào từ `pl_clk0`
  (99,999 MHz) thay vì 100 MHz cố định (lỗi `validate_bd_design`).
- ISP: frame bị huỷ giữa một dòng (tắt ISP khi đang stream, lỗi hình học) làm
  đầu ra `isp_*` có SOF giữa dòng; giờ dòng đó được điền nốt bằng pixel 0
  (test `camera` hỏng khi đổi từ camera sang `tpg`).
- `bow32_cam.py --fast`: chờ câu trả lời của lệnh `baud` ở tốc độ mới trước khi
  đồng bộ, prompt thừa không còn làm lệnh kế tiếp báo lỗi.

### Security
- MKV (`bow_mkv`): sửa các phát hiện của bản đánh giá bảo mật
  ([docs/mkv_security_review.md](docs/mkv_security_review.md), mục 8; mô tả ở
  [docs/ip/mkv.md](docs/ip/mkv.md)). Cả 8 thí nghiệm của bản đánh giá giờ là test đạt.
  - RAM khoá vòng: 8 từ mã Hsiao (39,32) xen kẽ mỗi dòng, gắn địa chỉ dòng, thay cho
    parity byte (32 × 312 bit). Lỗi 2 bit trong một byte, chùm tới 24 bit, dòng bị chép
    sang dòng khác trước đây cho bản mã sai với `DONE`; giờ là `FAULT`.
  - `DOUT` có bản bù, kiểm ở `Check` và suốt lúc còn đọc được. Mỗi quyết định của
    `Check` qua hai bộ so sánh khác cấu trúc, cờ cho ra kết quả là mubi4 ghép từ cả hai;
    FSM mã thưa 6 bit (khoảng cách 3); `STATUS.KEY_VALID` = AND với engine, lệch là lỗi.
  - Xoá có kiểm tra: `CLEAR` / sau reset / sau lỗi ghi 0 rồi đọc lại 32 dòng, bộ đếm
    chu kỳ kiểm ở mọi chu kỳ, phát hiện lỗi chạy cả khi xoá (cắt ngắn → xoá lại,
    `FAULT`, không `DONE`). `CLEAR` 33 → 65 chu kỳ, xoá sau reset 32 → 64. `KEY` đọc lại
    các dòng phía trên `h[2R]` nó đã xoá.
  - Bộ đếm lỗi và `LOCKED` trong miền power-on reset (cổng mới `por_rst_ni`): 4 lỗi
    (`FaultLimit`) → IP tự khoá tới lần bật nguồn sau, alert nghiêm trọng nối vào NMI
    của Ibex (`irq_nm_i`, handler mặc định `bow_nmi_handler` in và dừng);
    `STATUS[6]` `LOCKED`, `[7]` `ALERT`, `[15:12]` `FAULTS`.
  - Lệnh `TEST` (`CMD[4]` kèm `KEY`/`ENC`/`DEC`): làm lệch lượt hai, phải ra `FAULT`
    (không đếm); `TEST` không bị phát hiện thì IP tự khoá.
  - `CTRL[3]` `NOSTALL` (không truy cập nào bị giữ, thay cho chờ tới 144 chu kỳ),
    `CTRL[4]` `KEY_LOCK`, `CTRL[5]` `NO_DEC`, `CTRL[6]` `NO_ENC`. `DIN` chỉ ghi; đọc
    `CMD`/`KEY`/`DIN`, ghi `ID`/`INFO`/`CYCLES`/`DOUT` và offset trống trả lỗi bus.
    Mất `KEY_VALID` (ghi `KEY`, đổi phiên bản) thì engine xoá lược đồ khoá và `DOUT`
    ngay; `KEY` bị từ chối xoá các từ khoá. `INFO` = `0x000404FF`.
  - DMA không tới được thanh ghi MKV: tường lửa `bow_bus_deny` (`hw/ip/bus`) trước
    cổng DMA của main crossbar.
  - Driver: `bow_mkv_selftest()` (KAT 6 phiên bản + 3 `TEST`, sinh từ mô hình vào
    `sw/common/src/bow_mkv_kat.h`; chưa qua thì không nạp được khoá), `bow_mkv_error()`,
    `bow_mkv_wipe()`, `bow_mkv_set_nostall()`, `bow_mkv_lock_key()`; ECB kiểm `ERR` /
    `FAULT` của cả lần gọi. App `mkv` chạy tự kiểm tra lúc khởi động, `test` có 19
    nhóm (thêm lỗi bus, `NOSTALL`, chính sách, `TEST`, DMA bị chặn, tự kiểm tra), lệnh
    `post`.
  - Kiểm chứng: assertion SVA (`--assert`), tiêm lỗi 48 điểm mỗi seed (thêm mã RAM,
    `DOUT`, xoá, FSM từng bit, cờ mubi4, bộ so sánh kẹt, `TEST`, lockout),
    `tb_mkv_review.sv` trong `make test`, `make mutants` (33 bản RTL bỏ từng biện pháp,
    đều làm test hỏng).
  - Chi phí (`kv260_cam`, cùng flow): MKV 9 526 → 12 100 LUT, 2 278 → 2 792 FF,
    168 → 180 LUTRAM; timing vẫn đạt (MKV +1,44 ns, WNS cả thiết kế +0,155 ns ở H.264).
    `CLEAR` 33 → 65 chu kỳ; `KEY`, `ENC`, `DEC` không đổi. Qua driver: lược đồ khoá
    +94…127 chu kỳ, một khối +6…16, ECB +1…8 chu kỳ mỗi khối (132 / 240; lệch vài chu
    kỳ theo vị trí code trong flash) vì các kiểm tra mới; lõi và bus không chậm đi.
  - Trên board (Arm MPS4, bitstream `mps4` có cả DDR và HyperRAM, WNS +0,169 ns, MKV
    13 300 LUT): tự kiểm tra lúc khởi động PASS, `test` 19/19, `kat` 6/6, `verify`
    360/360 và 1 800/1 800 khối; `ddr` 21/21, `hyperram` 19/19 trên cùng bitstream
    ([docs/mkv_kv260.md](docs/mkv_kv260.md)).
- MKV (`bow_mkv`): khoá và dữ liệu không còn nằm lại sau khi dùng
  ([docs/ip/mkv.md](docs/ip/mkv.md), "Bảo mật"):
  - Lệnh `KEY` xoá thanh ghi `KEY` và chỉ chạy khi đã ghi đủ k/32 từ khoá mới
    kể từ `KEY`/`CLEAR` trước (không thì `ERR`). Trước đây byte không ghi lại
    vẫn là byte của khoá cũ: ai ghi được `KEY` và ra lệnh được, dù không đọc
    được khoá, có thể dò khoá từng byte bằng cách so bản mã; đổi `CTRL` cũng
    dùng lại được khoá cho phiên bản khác.
  - Engine giữ `K_R` và trạng thái bằng 0 khi rảnh (một chu kỳ sau lược đồ khoá),
    xoá khoá vòng của khoá dài hơn trước đó trong các chu kỳ không ghi RAM (`KEY` vẫn 8R + 1 chu
    kỳ), và sau reset xoá cả RAM khoá vòng (32 chu kỳ `BUSY`, không `DONE`).
  - `DIN` về 0 khi `ENC`/`DEC` lấy khối, `DOUT` về 0 khi `KEY`.
  - Diện tích (so với bản dựng lại từ `main`, cùng flow): logic thêm ~17 FF
    (mặt nạ từ khoá đã ghi, cờ xoá RAM sau reset), LUT không tăng: `kv260_cam`
    MKV 7 533 → 7 467 LUT, 1 956 → 1 961 FF. Ở `kv260` 8 735 → 9 489 LUT, nhưng
    đó là Vivado ánh xạ lại mạng S-box: chỉ đổi khối thanh ghi, lõi giữ nguyên RTL,
    lõi vẫn +825 LUT. FSM giữ mã hoá cũ (`fsm_encoding = "none"`): đổi trạng thái
    reset sang `Clear` làm Vivado mã lại FSM, tốn thêm ~200 LUT. Timing vẫn đạt;
    số chu kỳ của mọi lệnh không đổi.
  - Testbench kiểm tra từng điểm; đưa lại từng điểm yếu thì test hỏng. Ứng dụng
    `mkv` có thêm kiểm tra (12).
- MKV phát hiện lỗi tiêm vào phần cứng (glitch, laser), vì bản mã sai là thứ
  phân tích lỗi cần:
  - Mỗi lệnh làm hai lần trước khi trả kết quả: `ENC` giải mã lại kết quả trên
    datapath nghịch, `DEC` mã hoá lại trên datapath thuận, rồi so với đầu vào;
    `KEY` chạy lược đồ khoá lần hai và so từng khoá nửa vòng với RAM.
  - RAM khoá vòng có parity mỗi byte (lỗi ở khoá vòng lưu trữ giống nhau ở cả
    hai lượt). Phiên bản lưu kèm bản bù; bộ đếm chu kỳ thứ hai; trạng thái FSM
    lạ, FSM về `Idle` giữa chừng, `ENC` khi engine không có khoá đều là lỗi.
  - Lỗi → `STATUS.FAULT` (W1C, ngắt `IRQ_EN[5]`), không `DONE`, `DOUT` đọc ra 0,
    RAM khoá vòng, `KEY`, `DIN`, `KEY_VALID` bị xoá. `INFO` = `0x407`.
  - `CYCLES`: `KEY` 16R + 2, `ENC`/`DEC` 4R + 4. Trên board ECB không đổi (CPU
    là phần chậm), một khối đơn lẻ +~20 chu kỳ.
  - Driver: `bow_mkv_encrypt` / `decrypt` / `ecb` trả `bool` (false khi lỗi hay
    chưa có khoá), `bow_mkv_clear` xoá cả `FAULT`.
  - Testbench tiêm 10 loại lỗi (`force` thanh ghi trạng thái, bộ đếm bước, bộ
    đếm chu kỳ, số vòng, FSM, `KEY_VALID`; lật bit trong RAM khoá vòng): tất cả
    bị phát hiện, không lọt kết quả, xoá sạch, IP dùng lại được. 21 mutation (bỏ
    từng cơ chế) đều làm test hỏng. Ứng dụng có thêm kiểm tra (13), `test` giờ là
    `PASS (13/13)`.
  - Chi phí: MKV 7 467 → 9 591 LUT, 1 961 → 2 261 FF, 148 → 168 LUTRAM
    (`kv260_cam`); timing vẫn đạt.

## [0.1.0] - 2026-10-20

### Added
- SoC `bow32_top`: Ibex RV32IMC (cấu hình "small", commit `1b29dae8`), main
  crossbar 2×4 và peripheral bus.
- IP: SRAM 16 KiB, boot ROM 8 KiB, flash nội 128 KiB (ngữ nghĩa NOR, page 1 KiB),
  2 × UART (FIFO 16 byte, ngắt), SYSCTRL + reset manager (soft reset, UART BREAK reset).
- Memory map một nguồn (`hw/top/data/bow32_memmap.yaml`) + `tools/gen_memmap.py`.
- Boot ROM: kiểm tra header/CRC32 ảnh flash, UART loader (INFO/ERASE/WRITE/READ/CRC/BOOT/RESET).
- Firmware: HAL, crt0, linker script, ứng dụng `hello`, `uart_irq`, `flash_demo`.
- Host tools: `bow32_flash.py`, `bow32_image.py`, unit test.
- Mô phỏng Verilator: test `boot`, `load`, `break`, `flash`, `irq`.
- Flow Vivado cho Kria KV260 + overlay `xmutil` (chưa chạy thử trên board).
- CI GitHub Actions.
