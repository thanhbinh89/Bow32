# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/), đánh số theo
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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

### Changed
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
- MIPI CSI-2 RX Subsystem của AMD trong block design `bow32_cam` và driver của
  nó (`sw/apps/camera/csi2rx.c/.h`).

### Fixed
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
