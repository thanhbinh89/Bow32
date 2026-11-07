# Đánh giá IP mã khối MKV (`bow_mkv`) cho SoC camera AI

Tài liệu này đánh giá khối mật mã MKV của Bow32 ([ip/mkv.md](ip/mkv.md), `hw/ip/mkv/`)
theo thông lệ thiết kế IP bảo mật trong công nghiệp và theo các chuẩn, quy định áp dụng
cho **SoC camera AI** (camera giám sát IP, camera thông minh có suy luận trên thiết bị).
Câu hỏi cần trả lời: IP đang có đủ để làm khối mật mã của một SoC như vậy chưa, thiếu gì,
và phải sửa theo thứ tự nào.

Phạm vi: RTL (`bow_mkv.sv`, `bow_mkv_core.sv`, `bow_mkv_pkg.sv`), driver
(`sw/common/src/bow_mkv.c`), kiểm chứng (`hw/ip/mkv/dv`, `tools/mkv`), tích hợp trong
`bow32_top` (bus, DMA, ngắt, reset), ở commit `e21b93a`. Cách làm:

1. Đọc RTL, driver, tài liệu, đối chiếu với từng yêu cầu ở mục 2.
2. Chạy lại test có sẵn: `make -C hw/ip/mkv/dv test` (Verilator 5.020, 4 seed) **đạt**:
   khớp mô hình ở mọi trạng thái nửa vòng và mọi khoá vòng, 10/10 lỗi tiêm vào mỗi seed bị
   phát hiện.
3. Thêm 8 thí nghiệm cho những mô hình lỗi mà testbench chưa có
   (`hw/ip/mkv/dv/tb_mkv_review.sv`, chạy bằng `make -C hw/ip/mkv/dv review`, mục 7). Đây
   không phải test đạt/không đạt: mỗi thí nghiệm in ra IP **đang** làm gì.

## 1. Kết luận

| Mặt | Đánh giá |
|-----|----------|
| Đúng thuật toán (TCVN 14263:2024) | **Tốt.** Khớp Phụ lục A từng khoá vòng, mô hình tham chiếu độc lập, 25 bản mutation đều làm test hỏng, 360/360 khối ngẫu nhiên trên KV260. |
| Chống tiêm lỗi (FI) | **Kiến trúc tốt, còn lỗ.** Làm hai lần trên hai datapath khác nhau (thuận / nghịch) là lựa chọn đúng. Nhưng RAM khoá vòng là phần dùng chung của hai lượt, và parity theo byte không đủ để che nó: lỗi 2 bit trong một byte (E2) hay một dòng RAM bị chép sang dòng khác (E3) cho **bản mã sai đi ra với `DONE`, không có `FAULT`**. Lỗi kiểu này tồn tại tới lần `KEY` sau, nên dùng được cho phân tích lỗi vi sai (DFA). Thêm: thanh ghi kết quả không được kiểm (E1), lệnh xoá không được kiểm (E4, E5), không giới hạn số lần thử (E8). |
| Kênh kề (SCA) | **Chưa có** (tài liệu đã nói rõ). Không masking, không hiding. Vì vậy không đạt mức nào có kiểm thử SCA của phòng thử nghiệm (ISO/IEC 17825, PSA Certified L3, SESIP mức cao, CC `AVA_VAN.4/5`). |
| Khoá và kiểm soát truy cập | **Chưa có.** Khoá đi qua phần mềm; mọi master (CPU, DMA) dùng được và thay được khoá; SoC chưa có OTP, TRNG, key manager, PMP. |
| Chức năng cho camera AI | **Thiếu.** Chỉ có ECB, không có AEAD/MAC, không nối với DMA; driver đạt ~6,3 MB/s (~50 Mbit/s) và chiếm trọn CPU. Đủ cho một luồng H.264, không đủ cho dữ liệu thô, mô hình AI lớn hay mã hoá bộ nhớ DDR. |
| Tích hợp SoC | Một lệnh ghi có thể giữ bus **144 chu kỳ** (E7), chặn cả bus ngoại vi và ngắt. Lỗi chỉ báo qua `STATUS` và một ngắt tắt được, không có đường alert tới SoC. |
| Kiểm chứng, quy trình | Tốt cho một IP học tập (4 tầng, có tiêm lỗi, có mutation). So với công nghiệp: thiếu assertion, coverage, formal, chiến dịch tiêm lỗi có hệ thống, kiểm tra trên netlist. |

**Tổng kết:** IP đúng chuẩn và có nền tảng chống tiêm lỗi tốt hơn mức thường thấy ở IP mở.
Nhưng nó **chưa** sẵn sàng làm khối mật mã cho SoC camera AI thương mại. Có ba nhóm việc:
(A) sửa trong IP (mục 4, ưu tiên P0/P1 ở mục 6); (B) thêm khối ở mức SoC mà IP cần dựa vào
(mục 5); (C) quy trình và đánh giá độc lập trước khi xin chứng nhận.

## 2. Mô hình đe doạ và chuẩn tham chiếu

Camera AI đặt ở nơi công cộng hay trong nhà; ai cũng mua được một chiếc để mổ. Kẻ tấn
công vì vậy có thể có quyền truy cập vật lý, không chỉ từ mạng:

| | Kẻ tấn công | Ví dụ với camera AI | IP cần chống |
|---|---|---|---|
| T1 | Từ xa (mạng) | lỗ hổng web/RTSP/ONVIF, chiếm firmware | không lộ khoá kể cả khi firmware ứng dụng bị chiếm (key sideload, phân quyền) |
| T2 | Phần mềm cục bộ | ứng dụng AI bên thứ ba, DMA bị lập trình sai | kiểm soát truy cập thanh ghi, DMA, chính sách dùng khoá |
| T3 | Vật lý, không xâm nhập | đo công suất / EM, glitch clock / điện áp | SCA (masking / hiding), cảm biến glitch, phát hiện lỗi |
| T4 | Vật lý, bán xâm nhập | EMFI, laser trên chip đã mài | phát hiện lỗi nhiều bit, giới hạn số lần thử, xoá khoá có kiểm |

Các chuẩn và quy định dùng để đối chiếu:

| Nhóm | Văn bản | Liên quan tới IP |
|------|---------|------------------|
| Thuật toán | TCVN 14263:2024 (MKV) | đúng thuật toán, véc tơ kiểm tra |
| Việt Nam, camera | Quyết định 724/QĐ-BTTTT (07/5/2024), bộ tiêu chí an toàn thông tin mạng cơ bản cho camera giám sát; Quyết định 736/QĐ-BTTTT (2021), yêu cầu cơ bản cho thiết bị IoT tiêu dùng | mã hoá kênh giao tiếp theo tiêu chuẩn Việt Nam hoặc quốc tế tương đương, bảo vệ dữ liệu người dùng, quản lý lỗ hổng |
| Việt Nam, dữ liệu | Luật Bảo vệ dữ liệu cá nhân số 91/2025/QH15 (hiệu lực 01/01/2026), Nghị định 356/2025/NĐ-CP | hình ảnh, dữ liệu sinh trắc học (khuôn mặt) mà camera AI xử lý |
| Việt Nam, mật mã dân sự | quy chuẩn kỹ thuật của Ban Cơ yếu Chính phủ / Bộ Quốc phòng cho từng loại sản phẩm (ví dụ QCVN 15:2023/BQP cho sản phẩm bảo mật dữ liệu lưu giữ; có quy chuẩn riêng cho bảo mật luồng IP); Thông tư 126/2026/TT-BQP (danh mục sản phẩm mật mã dân sự rủi ro cao); TCVN 11295:2016 (= ISO/IEC 19790:2012) | chế độ hoạt động, quản lý khoá, tự kiểm tra, xoá khoá |
| Mô-đun mật mã | ISO/IEC 19790 / FIPS 140-3, ISO/IEC 24759; ISO/IEC 17825 (kiểm thử chống tấn công không xâm nhập) | tự kiểm tra, xoá CSP/SSP, trạng thái lỗi, quyền truy cập, SCA |
| Chứng nhận sản phẩm | ISO/IEC 15408 (Common Criteria) + thang tấn công JIL; SESIP (EN 17927); PSA Certified; IEC 62443-4-1 / 4-2 (camera công nghiệp, hạ tầng); ETSI EN 303 645 | mức chống tấn công vật lý cần đạt |
| Thị trường EU | Cyber Resilience Act (Quy định (EU) 2024/2847): camera an ninh gia đình thuộc "important products" Class I (Phụ lục III); báo cáo lỗ hổng bị khai thác từ 11/9/2026 | yêu cầu thiết kế an toàn, quản lý lỗ hổng |
| Phân loại điểm yếu | MITRE CWE, nhóm thiết kế phần cứng (CWE-1194) | gắn mã CWE cho từng phát hiện |
| Thiết kế tham chiếu | khối AES của [OpenTitan](https://opentitan.org/) (mã nguồn mở, có danh sách biện pháp đối phó `SEC_CM`) | so sánh với IP mật mã công nghiệp |
| Camera ô tô (nếu có) | ISO 26262, ISO/SAE 21434 | an toàn chức năng, chỉ số lỗi tiềm ẩn |

Số hiệu và nội dung các văn bản Việt Nam, và cách phân loại camera trong Phụ lục III của
CRA, được tra qua nguồn thứ cấp (báo chí, cổng tra cứu văn bản, bản chép lại). Hãy đối chiếu với văn bản gốc và với Ban Cơ yếu Chính phủ về quy chuẩn áp
dụng cho đúng loại sản phẩm trước khi dùng cho hồ sơ chứng nhận.

## 3. Điểm mạnh (nên giữ)

- **Đúng chuẩn, kiểm chứng nhiều tầng:** mô hình ↔ Phụ lục A (288 giá trị) ↔ RTL (mọi trạng
  thái nửa vòng, mọi khoá vòng) ↔ SoC ↔ board; mutation testing.
- **Dư thừa thời gian trên hai mạch khác nhau:** `ENC` được kiểm bằng datapath nghịch, `DEC`
  bằng datapath thuận. Lỗi tạm thời lẫn lỗi cố định *trong datapath* đều lộ, kể cả lỗi bền
  vững ở một S-box (trên FPGA: lỗi SEU ở bộ nhớ cấu hình của LUT), vì S-box thuận và S-box
  nghịch là hai mạch khác nhau.
- **Kiểm tra cả phần điều khiển:** bộ đếm chu kỳ thứ hai nạp từ bản bù, phiên bản lưu kèm bản
  bù, trạng thái lạ, quay về `Idle` giữa chừng, `ENC` khi engine không có khoá.
- **Thời gian cố định;** `KEY` chỉ ghi; `DOUT` đọc ra 0 khi chưa có kết quả đã kiểm và bị giữ
  trên bus khi đang chạy (hai rào chắn độc lập).
- **Vệ sinh khoá:** `KEY` lấy khoá rồi xoá, cần đủ từ khoá mới; `DIN` về 0; thanh ghi engine về
  0 khi rảnh; xoá khoá vòng của khoá dài hơn trước đó; xoá RAM sau reset.
- **Tài liệu trung thực:** mục "Bảo mật" của [ip/mkv.md](ip/mkv.md) liệt kê đúng những gì IP
  chưa có (SCA, kiểm soát truy cập, giới hạn của phát hiện lỗi).

## 4. Phát hiện

Mức độ: **Cao** (lộ khoá, hoặc kết quả sai được tuyên bố là đã kiểm, trong mô hình đe doạ ở
mục 2), **Trung bình** (làm yếu một biện pháp bảo vệ, hoặc chặn một yêu cầu chuẩn / chứng
nhận), **Thấp** (cứng hoá, vệ sinh). "E*n*" là thí nghiệm ở mục 7.

### 4.1 Chống tiêm lỗi

**F1. Cao: RAM khoá vòng chỉ có parity theo byte và không gắn với địa chỉ: lỗi bền vững
trong RAM cho bản mã sai đi ra (E2, E3).** CWE-1240, CWE-1261.

- Mã nguồn: `bow_mkv_core.sv:110-125` (một bit parity chẵn mỗi byte), `:247` (`par_err`).
- Hai lượt của `ENC`/`DEC` đọc **cùng một RAM**. Khoá vòng bị đổi ở đó thì cả hai lượt cùng
  dùng một khoá sai, nên D(E(P)) = P và phép so sánh không thấy gì. Parity là lớp bảo vệ duy
  nhất, nhưng:
  - **E2:** lật 2 bit trong một byte của `h[13]` (MKV-256/256, R = 7: khoá con thứ hai của
    vòng cuối). Kết quả: bản mã sai, `DONE`, không `FAULT`; `DEC` bản mã sai trả lại đúng P.
    `C ⊕ C*` chỉ khác 0 ở byte 5 của ba cột (ví dụ `…00e2…00e2…00e2…`). Đó là dấu vết của
    **một S-box ở vòng cuối, đi qua XWords**, đúng dạng mà DFA vòng cuối cần: thử từng byte
    của `XW⁻¹(K_post)` sẽ ra `K_post` byte một, rồi `h[2R−1]`. Theo chính [ip/mkv.md](ip/mkv.md),
    một cặp khoá nửa vòng liền nhau đủ để suy ra khoá chính.
  - **E3:** chép cả dòng `h[11]` (kèm parity của nó) đè lên `h[12]`, mô phỏng lỗi bộ giải mã
    địa chỉ hay word line. Parity vẫn đúng, nên bản mã sai cũng đi ra.
- Lỗi nằm yên trong RAM tới lần `KEY` sau: kẻ tấn công lấy được nhiều cặp (đúng, sai) chỉ với
  một lần tiêm, tức tấn công lỗi bền vững (PFA). Trên FPGA, LUTRAM (`RAM32M`) xếp các bit
  của một byte cạnh nhau, nên lỗi nhiều bit liền kề là thực tế. Trên ASIC cũng vậy nếu RAM là
  register file tự tạo, không xen cột.
- **Đề xuất:** mã phát hiện lỗi có khoảng cách Hamming ≥ 4 và **gắn địa chỉ**. Ví dụ: Hsiao
  (39,32) cho mỗi 32 bit, với địa chỉ dòng XOR vào bit kiểm tra (cách OpenTitan bảo vệ bộ nhớ:
  ECC + xáo trộn theo địa chỉ). Hoặc hai bản khoá vòng ở hai RAM tách rời, bản thứ hai lưu
  dạng bù, lượt hai đọc bản thứ hai. Thêm một test có hướng cho lỗi 2 bit và lỗi tráo dòng.

**F2. Trung bình: thanh ghi kết quả `dout_q` nằm ngoài phép kiểm (E1).** CWE-1261.

- `dout_q` được ghi ở cuối lượt một (`bow_mkv_core.sv:357`, `:373`), còn lượt hai chạy trên
  `st_q`. `Check` so `st_q` với `in_q` (`:246`, `:255`) và không bao giờ đọc `dout_q`. Sau
  khi cho đọc, `dout_q` cũng không có gì bảo vệ cho tới lệnh kế tiếp (`bow_mkv.sv:241`).
- **E1:** lật 1 bit của `dout_q` giữa lượt kiểm tra. Kết quả sai đi ra với `DONE`, không `FAULT`.
- Lỗi đặt sau phép tính cuối thì không giúp suy ra khoá. Nhưng nó phá lời cam kết "không kết
  quả nào ra khỏi IP mà chưa được kiểm", và là kết quả sai về toàn vẹn dữ liệu (khung hình,
  trọng số mô hình bị hỏng mà không ai biết).
- **Đề xuất:** lưu `dout_q` kèm parity hay bản bù, kiểm ở `Check` và ở mỗi lần đọc qua bus.
  Hoặc cho lượt hai bắt đầu *từ* `dout_q` (thêm 1 chu kỳ) và giữ mã kiểm của `dout_q` tới khi
  đọc xong.

**F3. Trung bình: thao tác xoá (`CLEAR`, sau reset, sau lỗi) không được kiểm, và phát hiện lỗi
bị tắt khi đang xoá (E4, E5).** CWE-1239, ISO/IEC 19790 (xoá SSP).

- `fault_now` và `fault_q` bị chặn khi `fsm_q == Clear` (`bow_mkv_core.sv:256`, `:284`).
  Trạng thái `Clear` chỉ đếm `step_q` tới 31 (`:390-409`) rồi báo `done_o` (`:424`).
- **E4:** một lần glitch làm `step_q` nhảy từ 1 lên 30 khi đang `CLEAR`. IP báo `DONE`, không
  `FAULT`, nhưng **14 dòng khoá vòng còn nguyên** trong RAM. **E5:** cùng lỗi đó ở lần xoá
  sau reset: khoá vòng của phiên trước còn lại sau reset.
- Các khoá vòng còn lại không đọc được qua bus, và `ENC` bị từ chối. Nhưng chúng vẫn nằm đó
  cho các đường khác: scan chain, đầu dò, dư ảnh (remanence). Và phần mềm được báo là đã xoá.
- **Đề xuất:** bộ đếm thứ hai cho `Clear` (như `ENC`); thêm lượt đọc lại kiểm 32 dòng đều bằng
  0 (RAM đã đọc bất đồng bộ, tốn thêm 32 chu kỳ); để phát hiện lỗi chạy cả khi xoá (lỗi thì
  xoá lại và báo alert); ghi dữ liệu giả ngẫu nhiên trước khi ghi 0 (mục 4.2).

**F4. Trung bình: không giới hạn số lần thử, lỗi chỉ báo qua ngắt tắt được (E8).** CWE-1247,
CWE-1319.

- Sau `FAULT`, IP nhận `CLEAR` rồi khoá mới ngay (`bow_mkv.sv:198-205`). Báo lỗi chỉ có
  `STATUS.FAULT` và ngắt theo `IRQ_EN` (`:209`). Ví dụ lập trình ở [ip/mkv.md](ip/mkv.md)
  (mục "Lập trình") còn **khuyên tự động** `bow_mkv_clear()` rồi nạp lại khoá.
- **E8:** 50 lần tiêm lỗi liên tiếp. Cả 50 lần đều bị phát hiện, và cả 50 lần IP đều nhận
  khoá mới.
- Tấn công tiêm lỗi thật cần hàng nghìn tới hàng triệu lần thử để trúng đúng thời điểm.
  Firmware tự nạp lại khoá sau lỗi là đang cho kẻ tấn công một oracle không giới hạn.
- **Đề xuất:** bộ đếm `FAULT` có ngưỡng, vượt ngưỡng thì khoá IP (`LOCKED`) tới khi bật lại
  nguồn; một đầu ra **alert nghiêm trọng** không tắt được, nối tới bộ xử lý alert / reset
  manager của SoC (OpenTitan tách alert phục hồi được và alert nghiêm trọng). Sửa ví dụ trong
  tài liệu: ghi log, báo lên, giới hạn tần suất, không tự động thử lại.

**F5. Thấp: FSM mã hoá nhị phân; cờ `KEY_VALID` của khối thanh ghi tách rời engine (E6).**
CWE-1245.

- `fsm_e` 3 bit nhị phân, `(* fsm_encoding = "none" *)` (`bow_mkv_core.sv:77`, `:84`): lật 1
  bit là sang một trạng thái hợp lệ khác. Khối thanh ghi bật `KEY_VALID` khi thấy xung
  `core_done` (`bow_mkv.sv:189-196`), không theo cờ `ks_valid_q` của engine.
- **E6:** lật 1 bit ở `Check` của `KEY` (`Check` 101 → `Clear` 100). Kết quả: `STATUS` báo
  `KEY_VALID = 1`, nhưng engine đã xoá lược đồ khoá. `ENC` kế tiếp bị bắt (`start_err` →
  `FAULT`), nên không lộ gì. Tôi đã xét các lần lật 1 bit khác (`Encrypt` ↔ `Decrypt`,
  `KeySched` → `Check`/`Idle`): đều bị bộ đếm chu kỳ hay phép so kết quả bắt. Vì vậy mức là
  Thấp, nhưng độ bền của FSM đang dựa vào một bộ so sánh duy nhất (F6).
- **Đề xuất:** mã hoá trạng thái thưa, khoảng cách Hamming ≥ 3 (như `prim_sparse_fsm` của
  OpenTitan); `STATUS.KEY_VALID` = cờ của khối thanh ghi AND `ks_valid` của engine; mã nhiều
  bit (kiểu `mubi4`) cho các cờ quyết định việc cho ra kết quả: `chk_q`, `op_key_q`,
  `dout_ok_q`, `ks_valid_q`, `check_ok`.

**F6. Trung bình: bộ so sánh là điểm hỏng đơn, và không có cách tự kiểm phần phát hiện lỗi.**
CWE-1334; chỉ số lỗi tiềm ẩn (ISO 26262).

- `res_ne`, `ks_ne`, `check_ok` mỗi thứ là một net (`bow_mkv_core.sv:245-257`). Một lỗi
  stuck-at bền vững ở đó lặng lẽ tắt toàn bộ phần chống tiêm lỗi; sau đó chỉ cần một lỗi tạm
  thời là có bản mã sai cho DFA. Tài liệu thừa nhận phần mềm không tự tạo được lỗi thật
  ([ip/mkv.md](ip/mkv.md), "Kiểm chứng").
- **Đề xuất:** hai bộ so sánh bù nhau, kết quả mã nhiều bit; thanh ghi `FAULT_TEST` để phần
  mềm cố ý làm lệch lượt hai và kiểm rằng `FAULT` bật (như `ALERT_TEST` của OpenTitan). Chạy
  nó khi boot.

**F7. Trung bình: phần dư thừa không được bảo vệ khỏi tối ưu hoá của công cụ tổng hợp.**
CWE-1240.

- Không có `keep` / `dont_touch` nào trong `hw/ip/mkv/rtl`. `wide_n_q`, `rounds_n_q` luôn là
  bản bù của `wide_q`, `rounds_q`; `cfg_err` luôn bằng 0 khi không có lỗi. Một flow ASIC tối
  ưu tuần tự mạnh có thể gộp thanh ghi bù hay coi `cfg_err` là hằng. Vivado hiện vẫn giữ
  (~2 100 LUT cho phần phát hiện lỗi), nhưng không có gì bảo đảm sau này.
- **Đề xuất:** bọc thanh ghi và cổng của biện pháp đối phó bằng cell `size_only` /
  `dont_touch` (kiểu `prim_flop`, `prim_buf`); kiểm tương đương và chạy tiêm lỗi trên netlist
  sau tổng hợp.

**F8. Trung bình: lỗi bền vững dùng chung ở lược đồ khoá không lộ; không có tự kiểm tra khi
khởi động.** ISO/IEC 19790 / FIPS 140-3: tự kiểm tra trước khi hoạt động và tự kiểm tra theo
điều kiện (CAST).

- Hai lượt của `KEY` dùng cùng datapath thuận và cùng hằng số `sched_const`
  (`bow_mkv_core.sv:158-176`). Một lỗi stuck-at ở đó (hằng số, mux `k0r`, `sched_v`) cho cùng
  một lược đồ khoá sai ở cả hai lượt. `ENC`/`DEC` vẫn khớp nhau vì cùng đọc RAM, nên IP lặng
  lẽ tính một mã khác. Hậu quả: mất tương thích, và có thể là một lược đồ khoá yếu hơn.
- Boot ROM chỉ kiểm CRC32 ảnh ([boot.md](boot.md)); KAT chỉ có trong ứng dụng thử `sw/apps/mkv`.
- **Đề xuất:** KAT một véc tơ Phụ lục A cho mỗi phiên bản được bật, chạy trong boot ROM hay
  BIST phần cứng trước khi cho dùng `KEY`. Lỗi KAT thì vào trạng thái lỗi bền.

### 4.2 Kênh kề

**S1. Cao (với T3/T4): không masking, không hiding.** CWE-1300.

- Datapath lặp 256 bit, thanh ghi cập nhật mỗi nửa vòng; lược đồ khoá chạy trên `kl_q`/`kr_q`
  mỗi lần `KEY`. Rò rỉ Hamming distance của trạng thái và khoá là trực tiếp. Lượt kiểm tra
  còn cho kẻ tấn công thêm vết của vòng cuối (tài liệu đã nói).
- Xoá về 0 cũng rò: ở `Idle` (`bow_mkv_core.sv:287-292`) và `Clear` (`:390-396`), thanh ghi
  chuyển từ giá trị cuối về 0, nên công suất tỉ lệ với trọng số Hamming của giá trị đó. Sau
  `KEY`, giá trị đó là khoá nửa vòng cuối.
- **Đề xuất:**
  - Masking bậc 1 (S-box DOM hay threshold implementation, trạng thái và khoá hai phần), cần
    PRNG được nạp từ TRNG.
  - Nếu chưa làm được masking: hiding, tức vòng giả ngẫu nhiên, xáo thứ tự S-box ở bản xử lý
    theo cột, nhiễu.
  - Xoá bằng dữ liệu giả ngẫu nhiên.
  - Chính sách đổi khoá phiên.
  - Đánh giá TVLA theo ISO/IEC 17825 trên bo đo SCA (ChipWhisperer CW305/CW310; KV260 không
    hợp để đo).

**S2. Thấp: so sánh giá trị bí mật** (`ks_ne`, khoá vòng tính lại so với RAM). CWE-1255.
Chỉ so bằng nhau, rò ít; nên gộp vào masking ở trên.

### 4.3 Khoá và kiểm soát truy cập

**K1. Cao (mức SoC): khoá đi qua phần mềm, không có đường khoá phần cứng.** Khoá thiết bị,
khoá luồng video, khoá giải mã mô hình AI phải nằm trong OTP/eFuse hay được dẫn xuất từ PUF
qua một key manager, rồi **nạp thẳng (sideload)** vào IP mà phần mềm không thấy. Bow32 chưa
có OTP, TRNG hay key manager. **Đề xuất:** cổng `key_sideload_i` + `KEY_SEL`; đường khoá do
phần mềm ghi bị tắt theo lifecycle ở bản sản xuất.

**K2. Cao (mức SoC): mọi master đều dùng được và thay được khoá.** CWE-1262, CWE-1256,
CWE-1189.

- DMA là host thứ ba của main crossbar và tới được `0x4000_xxxx` (`bow32_top.sv`, mục
  "Peripheral bus"). Ibex cấu hình `PMPEnable = 0`, `SecureIbex = 0`
  (`hw/ip/cpu/rtl/bow_cpu_ibex.sv:49`, `:62`). Không có tường lửa bus.
- Hệ quả: IP là một oracle mã hoá / giải mã cho bất kỳ mã nào chạy được trên SoC.
- **Đề xuất:**
  - Chỉ cho truy cập có đặc quyền: thuộc tính đặc quyền trên bus, hay PMP / ePMP với chế độ
    U cho ứng dụng.
  - Chặn DMA khỏi vùng ngoại vi bảo mật.
  - `KEY_LOCK` ghi một lần tới reset (CWE-1233).
  - Bit chính sách dùng khoá: chỉ mã hoá / chỉ giải mã.

**K3. Thấp: dữ liệu còn nằm lại lâu hơn cần.**

- Khoá vòng còn trong RAM sau khi `KEY_VALID` về 0 vì ghi `KEY` hay đổi `CTRL`
  (`bow_mkv.sv:156`, `:169`), tới `CLEAR` hay `KEY` sau.
- `key_q` còn nguyên sau một lệnh `KEY` bị từ chối (`:123`).
- `DIN` đọc được bởi mọi master (bản rõ trước khi `ENC`, `:238-239`).
- `DOUT` vẫn đọc được sau khi `KEY_VALID` về 0.
- **Đề xuất:** xoá RAM khi mất `KEY_VALID`; `DIN` chỉ ghi; xoá `key_q` khi `KEY` bị từ chối.

**K4. Thấp: giao diện thanh ghi không báo lỗi bus và không có toàn vẹn bus.** Ghi vào thanh ghi
chỉ đọc, đọc `KEY`, offset không có đều trả về bình thường (`bus_rsp_o.err = 0`,
`bow_mkv.sv:268`). **Đề xuất:** trả `err` cho truy cập không hợp lệ; với SoC thương mại, toàn
vẹn đầu-cuối trên bus (như TL-UL integrity của OpenTitan).

**K5. Trung bình (khi lên ASIC): scan / DFT.** Scan chain đi qua `key_q`, `kl_q`/`kr_q`,
`dout_q` (và RAM khoá vòng nếu làm bằng flop) sẽ xả được khoá. CWE-1191, CWE-1243.
**Đề xuất:** loại khỏi scan hay dùng secure scan; xoá khi vào chế độ test; chế độ test do
lifecycle cho phép.

### 4.4 Chức năng và hiệu năng cho camera AI

**P1. Cao (chức năng): chỉ có ECB, không có AEAD / MAC.** Luồng video và dữ liệu khuôn mặt cần
bí mật, toàn vẹn và chống phát lại (Quyết định 724/QĐ-BTTTT: mã hoá kênh giao tiếp; Luật Bảo
vệ dữ liệu cá nhân: dữ liệu sinh trắc học). Mô hình AI cần bảo vệ sở hữu trí tuệ; lưu trữ cần
toàn vẹn. MKV-256 có khối 256 bit, nên không ghép thẳng được với GHASH 128 bit của GCM.
**Đề xuất:**

- CTR và một MAC (CMAC theo ISO/IEC 9797-1, hay GHASH với MKV-128) trong phần cứng; hoặc ít
  nhất trong phần mềm, với nonce lấy từ TRNG (ISO/IEC 10116, ISO/IEC 19772).
- Hỏi Ban Cơ yếu về chế độ và cấu trúc được chấp nhận cho từng loại sản phẩm.

**P2. Trung bình: thông lượng và tải CPU.**

| | Lõi (50 MHz) | Qua driver |
|---|---|---|
| MKV-128 | 200 Mbit/s | ~6,3 MB/s (~50 Mbit/s), CPU bận 100 % (bị giữ trên bus) |
| MKV-256 | 400 Mbit/s | ~6,7 MB/s |

- **Đủ** cho một luồng H.264 1080p30 (vài Mbit/s).
- **Không đủ** cho:
  - YUV 4:2:0 1080p30 thô (~93 MB/s);
  - giải mã mô hình vài chục MB khi khởi động (vài giây);
  - mã hoá bộ nhớ DDR trực tiếp: độ trễ 4R + 4 chu kỳ mỗi khối, không pipeline.
- **Đề xuất:**
  - Giao diện stream nối với DMA (một kênh vào, một kênh ra) để CPU không phải chép.
  - Tính trước keystream CTR.
  - Bản cả vòng mỗi chu kỳ, hay bản unroll có pipeline cho mã hoá bộ nhớ.

**P3. Trung bình: một truy cập giữ bus tới 144 chu kỳ (E7).**

- Ghi `CTRL`/`CMD`/`KEY` và đọc `DOUT` bị giữ `gnt = 0` suốt lệnh (`bow_mkv.sv:77-79`).
- **E7:** ghi `CMD` ngay sau `KEY` của MKV-256/512 bị giữ **144 chu kỳ**.
- Crossbar khoá grant của thiết bị `periph` cho host đang chờ ([bus.md](bus.md)). Trong lúc đó:
  - DMA không tới được bất kỳ ngoại vi nào;
  - CPU đứng ở lệnh load/store đó tới khi có `gnt`, nên ngắt (CSI-2, ISP, H.264, UART)
    trễ thêm tới 144 chu kỳ.
  Mỗi lần đọc `DOUT` trong vòng ECB cũng giữ bus tới 4R + 3 chu kỳ.
- **Đề xuất:** tuỳ chọn không chặn (trả `BUSY`/`ERR` và để phần mềm hỏi vòng hay chờ ngắt);
  hoặc đặt IP trên một cổng riêng, không chung với ngoại vi điều khiển thời gian thực.

### 4.5 Kiểm chứng và quy trình

**V1. Trung bình: so với kiểm chứng IP bảo mật trong công nghiệp.** Có: mô hình tham chiếu,
ngẫu nhiên có ràng buộc, tiêm lỗi có hướng, mutation. Thiếu:

- **Assertion SVA** trong RTL (không có `assert` nào trong `hw/ip/mkv`): quy tắc bus,
  "`DOUT` = 0 khi `!dout_ok_q`", "khoá không bao giờ tới `rdata`".
- **Coverage** chức năng và coverage mã (`verilator --coverage`) trong CI.
- **Formal:** tính chất của FSM, xoá khoá, và luồng thông tin (khoá không tới được cổng đọc
  bus). Có thể làm bằng Yosys-SBY hay công cụ thương mại.
- **Chiến dịch tiêm lỗi có hệ thống:** mọi flop × mọi chu kỳ, cộng lỗi nhiều bit và lỗi địa
  chỉ ở RAM. Hiện chỉ có 10 điểm có hướng. Kết quả nên đo bằng **tỉ lệ phát hiện**.
- Tiêm lỗi trên netlist sau tổng hợp (F7).
- Testbench được biên dịch với `-Wno-lint -Wno-style`.

**V2. Thấp: sản phẩm đi kèm IP.** Mô tả thanh ghi một nguồn (SystemRDL / IP-XACT), từ đó sinh
RTL, header C và tài liệu; hiện `bow_mkv.sv`, `bow_mkv.h`, `mkv.md` được giữ đồng bộ bằng
tay. Thêm ràng buộc SDC, hướng dẫn tích hợp, và **danh sách biện pháp đối phó** (kiểu
`SEC_CM` của OpenTitan) để lập security target khi xin chứng nhận.

### 4.6 Driver

**D1. Thấp.**

- Không có hàm xoá an toàn cho bộ đệm khoá (`explicit_bzero`).
- `bow_mkv_ecb` chỉ trả `bool`, không phân biệt `ERR` với `FAULT`. Nó không kiểm `DONE` từng
  khối mà chỉ nhìn `KEY_VALID` ở cuối (`bow_mkv.c:74-88`).
- Không có khoá loại trừ khi ISR và chương trình chính cùng dùng IP.
- Ví dụ tự động thử lại sau lỗi: xem F4.

## 5. Mức SoC: những gì IP cần dựa vào

Các mục dưới đây không thuộc `bow_mkv`, nhưng không có chúng thì IP không đạt được mục đích
trong một camera AI:

| Khối / chức năng | Hiện trạng Bow32 | Cần cho camera AI |
|------------------|------------------|-------------------|
| Root of trust, secure boot | boot ROM kiểm CRC32; UART loader ghi flash không cần xác thực; UART BREAK → bootloader | ROM kiểm chữ ký số (ECDSA/EdDSA, hay thuật toán theo quy chuẩn trong nước), chống hạ phiên bản, tắt loader ở bản sản xuất |
| OTP / eFuse, lifecycle | chưa có | trạng thái dev / prod / RMA, khoá thiết bị, cấu hình bảo mật không đổi được |
| TRNG / DRBG | chưa có | nonce, IV, khoá phiên, PRNG cho masking (ISO/IEC 18031, NIST SP 800-90A/B) |
| Key manager | chưa có | dẫn xuất khoá theo mục đích, nạp thẳng vào MKV (K1) |
| Alert handler, cảm biến | chưa có | nhận alert của MKV (F4); cảm biến glitch clock / điện áp / nhiệt (CWE-1247) |
| Phân quyền | không PMP, DMA tới mọi nơi | PMP/ePMP, chế độ U cho ứng dụng, tường lửa DMA (K2) |
| Debug, test | chưa có debug module; ASIC sẽ có JTAG/scan | khoá debug theo lifecycle, xoá bí mật khi vào debug/test (CWE-1191, K5) |
| Bộ nhớ ngoài | DDR không mã hoá | mã hoá (và tốt nhất xác thực) khung hình, mô hình AI trong DDR (P2) |

## 6. Lộ trình đề xuất

| Ưu tiên | Việc | Phát hiện |
|---------|------|-----------|
| **P0**, trước khi dùng với dữ liệu thật | Mã phát hiện lỗi gắn địa chỉ cho RAM khoá vòng; kiểm lại thao tác xoá; bộ đếm lỗi + `LOCKED` + alert; chỉ cho truy cập có đặc quyền và chặn DMA; KAT khi khởi động; AEAD ít nhất trong phần mềm | F1, F3, F4, K2, F8, P1 |
| **P1** | Bảo vệ `dout_q`; FSM thưa + cờ nhiều bit; hai bộ so sánh + `FAULT_TEST`; `dont_touch` cho phần dư thừa; tuỳ chọn không giữ bus; vệ sinh `DIN`/`key_q`/RAM; lỗi bus; driver; SVA + coverage + chiến dịch tiêm lỗi; biến E1–E8 thành test đạt/không đạt sau khi sửa | F2, F5, F6, F7, P3, K3, K4, D1, V1 |
| **P2**, khi nhắm mức chứng nhận có kiểm thử vật lý | Masking + TRNG; cổng nạp khoá từ key manager; CTR/MAC và stream DMA trong phần cứng; các khối SoC ở mục 5; đánh giá SCA/FI độc lập trước khi nộp hồ sơ | S1, K1, K5, P1, P2, V2 |

Đối chiếu nhanh với các vùng yêu cầu của ISO/IEC 19790 (TCVN 11295:2016):

| Vùng | Hiện trạng | Việc cần làm |
|------|-----------|--------------|
| Tự kiểm tra (trước khi hoạt động, theo điều kiện) | chỉ có KAT trong ứng dụng thử | KAT ở boot ROM / BIST (F8) |
| Xoá SSP | có, nhưng không kiểm và cắt ngắn được (E4, E5) | F3 |
| Trạng thái lỗi | `FAULT` có, nhưng thoát ngay bằng `CLEAR` | F4 |
| Vai trò, giao diện, kiểm soát truy cập SSP | chưa có | K1, K2 |
| Giảm thiểu tấn công không xâm nhập | chưa có | S1 |
| An ninh vật lý (mức 3–4) | ngoài IP | mục 5 |

## 7. Chạy lại

```bash
make -C hw/ip/mkv/dv test     # test có sẵn: RTL ↔ mô hình, tiêm lỗi có hướng (4 seed)
make -C hw/ip/mkv/dv review   # 8 thí nghiệm của tài liệu này
```

Kết quả của `review` ở commit được đánh giá (Verilator 5.020):

```
RESULT E1 dout_q bit flip in the check pass: NOT DETECTED: wrong result released with DONE, no FAULT
RESULT E2 two-bit flip in one byte of h[13]: NOT DETECTED: wrong result released with DONE, no FAULT
RESULT E3 row h[12] := h[11]: NOT DETECTED: wrong result released with DONE, no FAULT
RESULT E4 CLEAR cut short: DONE 1, FAULT 0, 14 round key rows left
RESULT E5 reset wipe cut short: STATUS 00000000, 14 round key rows left
RESULT E6 FSM Check -> Clear in KEY: KEY_VALID 1, FAULT 0, engine key schedule 0
RESULT E7 CMD write right after KEY (R = 9) stalls the bus 144 cycles
RESULT E8 50 fault attempts: 50 detected, 50 new keys accepted after a fault
```

Lỗi được tiêm bằng `force`/`release` một thanh ghi trong một chu kỳ, hay ghi thẳng vào RAM
khoá vòng, giống `tb_bow_mkv.sv`. Đây là mô hình lỗi ở mức RTL: nó cho biết cơ chế phát hiện
có che một loại lỗi hay không, chứ không đo xác suất tạo được lỗi đó trên silicon hay FPGA.
