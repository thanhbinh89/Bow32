# Khối mật mã MKV (`bow_mkv`)

IP tăng tốc **mã khối MKV** theo tiêu chuẩn quốc gia **TCVN 14263:2024** *Công
nghệ thông tin – Kỹ thuật an toàn – Thuật toán mã khối MKV* (Ban Cơ yếu Chính
phủ xây dựng, Bộ Khoa học và Công nghệ công bố). Đủ **6 phiên bản** của chuẩn,
lược đồ khóa chạy trong phần cứng, mã hoá và giải mã mỗi lệnh một khối. Mỗi lệnh
được làm hai lần và đối chiếu trước khi trả kết quả (phát hiện lỗi tiêm vào phần
cứng); lỗi bị đếm từ lúc bật nguồn, quá ngưỡng thì IP tự khoá. Mã RTL: `hw/ip/mkv/rtl/`. Mô hình tham chiếu: `tools/mkv/mkv_model.py`.
Driver: `sw/common/include/bow_mkv.h`. Ứng dụng kiểm thử: `sw/apps/mkv`, chạy
trên Arm MPS4 và KV260: [../mkv_kv260.md](../mkv_kv260.md).

Văn bản tiêu chuẩn thuộc bản quyền của Viện Tiêu chuẩn Chất lượng Việt Nam và chỉ
được dùng nội bộ, nên không có trong repo. Bản **dự thảo**
(`docs/ref/Du-thao-TCVN-XXXX2024.pdf`, cũng chỉ để bản cục bộ) là một mã khác, khác
bản chuẩn ở ba điểm của thuật toán (xem [So với bản dự thảo](#so-với-bản-dự-thảo)).
Các véc tơ kiểm tra của chuẩn được chép vào `tools/mkv/tcvn14263_vectors.json`, bảng
và véc tơ của bản dự thảo vào `tools/mkv/draft_vectors.json`.

```
               +--------------------------------------------------------------------+
  bus ────────►| bow_mkv: CTRL CMD STATUS IRQ_EN CYCLES  KEY[16] (W) DIN[8] (W) DOUT[8]|──► irq_fast[10]
  0x4000_B000  |   bộ đếm lỗi + LOCKED (miền power-on reset), KEY_LOCK, chính sách  |──► alert ─► NMI
  (DMA bị chặn)+--------------------------------------------------------------------+
                  │ lệnh (KEY/ENC/DEC/CLEAR, TEST), khoá 512 bit, khối 256 bit ▲ kết quả
                  ▼                                                          │
               +--------------------------------------------------------------------+
               | bow_mkv_core                                                       |
               |   K_int từ khoá chính ─► K⁰ / K¹ (2 × 256 bit)                     |
               |                    │ cập nhật: G(G(x ⊕ Const ⊕ ⟨v⟩)), 2 nhánh / lần |
               |   nửa vòng thuận:  x ^ k ─► SubCells ─► MixWords | XWords ─► x     |
               |   nửa vòng nghịch: x ─► XWords | invMixWords ─► invSubCells ─► ^ k |
               |                           ▲ k                                       |
               |   RAM khoá vòng 32 × (256 + 56 mã) bit (LUTRAM): h[0..2R], mã Hsiao |
               |   xen kẽ gắn địa chỉ dòng; DOUT kèm bản bù; FSM thưa, cờ mubi4      |
               |   lượt 2 (ENC ↔ DEC, KEY lần hai), 2 bộ so sánh ─► FAULT            |
               +--------------------------------------------------------------------+
```

| Thông số | Giá trị |
|----------|---------|
| Phiên bản | MKV-128 (khối 128 bit) khoá 128 / 192 / 256 bit, MKV-256 (khối 256 bit) khoá 256 / 384 / 512 bit; R = 7 / 8 / 9 vòng (Bảng 1 của chuẩn) |
| Lệnh | `KEY` (lược đồ khoá), `ENC`, `DEC` (một khối), `CLEAR` (xoá khoá và dữ liệu, có đọc lại kiểm tra); `TEST` kèm `KEY`/`ENC`/`DEC`: tự kiểm phần phát hiện lỗi |
| Phát hiện lỗi | mỗi lệnh làm hai lần: `ENC` giải mã lại kết quả, `DEC` mã hoá lại, `KEY` chạy lược đồ khoá lần hai (và đọc lại các dòng đã xoá); mỗi quyết định qua hai bộ so sánh khác cấu trúc; khoá vòng có mã phát hiện lỗi gắn địa chỉ dòng (thấy mọi lỗi tới 3 bit mỗi từ mã, mọi chùm tới 24 bit liền nhau, dòng đọc nhầm địa chỉ); `DOUT` kèm bản bù; phiên bản lưu kèm bản bù; bộ đếm chu kỳ thứ hai; FSM mã thưa (hai trạng thái khác nhau ≥ 3 bit); cờ cho ra kết quả dạng mubi4. Lỗi → `FAULT`, không trả kết quả, xoá khoá. `FaultLimit` (4) lỗi từ lúc bật nguồn → `LOCKED` tới power-on reset, alert nghiêm trọng (NMI) |
| Kiểm soát truy cập | `KEY_LOCK` (khoá cố định tới reset), chính sách `NO_ENC` / `NO_DEC`, DMA không tới được thanh ghi MKV (tường lửa bus), truy cập sai trả lỗi bus |
| Kiến trúc | **một nửa vòng mỗi chu kỳ** trên datapath 256 bit dùng chung cho hai cỡ khối |
| Số chu kỳ (`CYCLES`) | `KEY` 16R + 2 (114 / 130 / 146), `ENC` / `DEC` 4R + 4 (32 / 36 / 40), `CLEAR` 65 (ghi 0 rồi đọc lại 32 dòng), đã gồm lượt kiểm tra; sau reset, sau lỗi và khi mất `KEY_VALID` engine tự xoá RAM khoá vòng (64 chu kỳ `BUSY`) |
| Thông lượng lõi (50 MHz) | MKV-128/128: 128 bit / 32 chu kỳ = 200 Mbit/s; MKV-256/256: 400 Mbit/s |
| Trên board (CPU + driver) | ECB 135 chu kỳ/khối (MKV-128, ~5,9 MB/s), 247 chu kỳ/khối (MKV-256, ~6,5 MB/s), như nhau với cả ba độ dài khoá (CPU chậm hơn lõi; đo trên MPS4); phần mềm trên Ibex: 33 800…130 000 chu kỳ/khối |
| Tài nguyên | 12 100 LUT (180 LUTRAM), 2 792 FF trong `kv260_cam` (Vivado 2025.2), không BRAM / DSP; khối thanh ghi 204 LUT / 917 FF, engine 11 896 LUT / 1 875 FF. Trước lần sửa theo [đánh giá bảo mật](../mkv_security_review.md): 9 526 LUT (168 LUTRAM), 2 278 FF cùng flow, tức +2 574 LUT (+27 %), +514 FF (bản bù của đầu vào và kết quả, cờ mubi4, bộ đếm lỗi), +12 LUTRAM (56 bit mã thay cho 32 bit parity). Timing đạt ở 50 MHz: đường xấu nhất qua MKV còn +1,44 ns; WNS của cả `kv260_cam` +0,155 ns vẫn ở H.264 (clock video 200 MHz). Số LUT của MKV đổi nhiều theo thiết kế xung quanh (Vivado ánh xạ mạng 64 S-box khác nhau: cùng RTL cũ từng ra 9 524 ở `kv260_cam`, 11 581 ở `kv260`). Bản `mps4` (XCVU13P): 13 138 LUT (180 LUTRAM), 2 785 FF, đường xấu nhất qua MKV ở 50 MHz +2,63 ns |
| Thanh ghi | peripheral bus `0x4000_B000`, ngắt `irq_fast[10]`, alert nghiêm trọng → NMI của Ibex |

## Thuật toán

Tóm tắt điều 5 của chuẩn, với ký hiệu dùng trong RTL và mô hình.

**Trạng thái.** Khối `l` bit `X = x⁰‖x¹‖x²‖x³`, mỗi trạng thái con `xᶜ` là một
cột `t` byte, `w = 8t` bit (`t = 4` với MKV-128, `t = 8` với MKV-256). Byte được
đánh số theo thứ tự của chuẩn (thứ tự của các chuỗi hex ở Phụ lục A): cột `c`
gồm các byte `c·t … c·t + t − 1`, byte `j` của cột là `xᶜⱼ`, cũng là byte thứ `j`
(tính từ trái) của xâu `w` bit `xᶜ`.

**Các biến đổi.**

* `SubCells`: hộp thế 8 bit `s` cho từng byte (Bảng 2; nghịch đảo: Bảng 3).
* `MixWords` (điều 5.4.3): cột `c` **xoay trái `c·w/4` bit** rồi nhân với ma trận
  `M4` (4 × 4) hoặc `M8` (8 × 8) trên GF(2⁸) với đa thức `x⁸ + x⁵ + x³ + x + 1`
  (`0x12B`): `yᶜ = M_t (xᶜ ⋘_w c·w/4)`. Với MKV-128 cột `c` xoay `c` byte, với
  MKV-256 xoay `2c` byte: byte `j` của kết quả xoay là byte `(j + c·t/4) mod t`.
  `invMixWords` nhân `M_t⁻¹` rồi xoay phải cùng số bit.
* `XWords`: `yᶜ = XOR của ba cột còn lại` (tự nghịch đảo).

**Hàm vòng** với khoá vòng `K_i = K_i⁰‖K_i¹` (2l bit), điều 5.2 / 5.3:

```
F(K, X)    = XWords(SubCells(MixWords(SubCells(X ⊕ K⁰)) ⊕ K¹))
invF(K, X) = invSubCells(invMixWords(invSubCells(XWords(X)) ⊕ K¹)) ⊕ K⁰
C = F(K_{R-1}, … F(K_0, P)) ⊕ K_post        P = invF(K_0, … invF(K_{R-1}, C ⊕ K_post))
```

**Lược đồ khoá** (điều 5.5). Trạng thái khoá 2l bit `K = K⁰‖K¹`, các từ `kⱼ`
dài `l/4` bit, `G(X) = XWords(SubCells(MixWords(SubCells(X))))`:

```
K_int = k0 … k7                  (khoá 2l bit)
        k0 … k5 ‖ ~k2 ‖ ~k3      (khoá 3l/2 bit)
        k0 … k3 ‖ ~k0 … ~k3      (khoá l bit)
K⁰‖K¹ = K_int,  RK_0 = K⁰
với i = 0 … R − 1:
  K¹ ← G(G(K¹ ⊕ Const¹_l ⊕ ⟨2i + 2⟩_l))
  K⁰ ← G(G(K⁰ ⊕ Const⁰_l ⊕ ⟨2i + 1⟩_l)) ⊕ K¹
  SWAP(K⁰, K¹);  RK_{2i+1} = K⁰;  RK_{2i+2} = K¹
K_i = RK_{2i} ‖ RK_{2i+1},  K_post = RK_{2R}
```

`⟨v⟩_l` là số `v` viết thành `l` bit (big-endian: `v` ở byte cuối). Hằng số:

```
Const⁰_128 = 9302ee911a2ad98cad13e7948ad8b3b2      Const⁰_256 = Const⁰_128 ‖ Const¹_128
Const¹_128 = d4da00f33f11fd8822166bb9cd187c55      Const¹_256 = 43c853a3f90f70ae8d72ad0e7aac0c71
                                                                afad739c17a14bd656c9436300def1e5
```

Dãy **khoá nửa vòng** `h[0..2R] = RK_0 … RK_2R`: nửa vòng `s` của phép mã hoá
dùng `h[s]`, `K_post = h[2R]`. Đây cũng là thứ tự của RAM khoá vòng trong RTL và
của các dòng khoá vòng in đậm ở Phụ lục A.

## So với bản dự thảo

Bản dự thảo (`docs/ref/Du-thao-TCVN-XXXX2024.pdf`, Bow32 cài theo bản này tới
phiên bản 1 của IP, `ID = 0x4D4B5601`) và TCVN 14263:2024 giống nhau ở S-box,
`M8`, `M4⁻¹`, `M8⁻¹`, `XWords`, cấu trúc vòng, `K_int` và thứ tự byte, nhưng khác
nhau ở **ba điểm của thuật toán**, nên là hai mã khác nhau: dữ liệu mã bằng IP
cũ không giải mã được bằng IP mới (`ID = 0x4D4B5602`) và ngược lại.

| | Dự thảo | TCVN 14263:2024 |
|---|---|---|
| Số vòng R (khoá l / 3l/2 / 2l) | 6 / 7 / 8 | **7 / 8 / 9** |
| MixWords | nhân ma trận | **xoay cột `c` đi `c·w/4` bit**, rồi nhân ma trận |
| Khoá của `F` đầu ở mỗi nhánh lược đồ khoá | `⟨2i + 1⟩_l`, `⟨2i + 2⟩_l` | **`Const⁰_l` ⊕** `⟨2i + 1⟩_l`, **`Const¹_l` ⊕** `⟨2i + 2⟩_l` |
| Ma trận `M4` in trong văn bản | sai: `0x0C` ở (2, 3) và (3, 0) | đúng: `0x0D` |
| Phụ lục A | bản rõ `1122…ff00`, khoá `0102…0f11…`; khoá vòng, 6 bước mỗi vòng | bản rõ `ffee…1100`, khoá `0001…`; thêm 9 bước của cả hai nhánh ở mỗi lần cập nhật khoá |

Ngoài ra văn bản chuẩn đổi số điều (điều 4 → 5; MixWords 4.2.2.2 → 5.4.3, lược
đồ khoá 4.6 → 5.5) và ký hiệu (`K^L`, `K^R` → `K⁰`, `K¹`; khoá vòng `RK_j`).

Văn bản dự thảo còn **mâu thuẫn với chính véc tơ của nó** ở hai chỗ, đều đã được
sửa trong bản chuẩn: ma trận `M4` in `0x0C` (chỉ `0x0D` mới cho ra các véc tơ và là
nghịch đảo của `M4⁻¹` in cùng trang), và hằng số lược đồ khoá viết là
`Const^Left_i = ⟨2i⟩_{2l}`, `Const^Right_i = ⟨2i+1⟩_{2l}`, dùng `Const_{i−1}` ở lần
cập nhật `i`, trong khi các véc tơ cần `⟨2i⟩_l`, `⟨2i − 1⟩_l` ở nửa khoá đầu của
`F` (đúng như điều 5.5 của bản chuẩn, chỉ thiếu `Const`).

Mô hình giữ cả hai bản: `mkv_model.py` mặc định theo chuẩn; trong
`with edition(DRAFT):` nó tính mã của bản dự thảo và cho ra **mọi giá trị** ở Phụ
lục A của bản dự thảo (`tools/mkv/draft_vectors.json`). `tools/tests/test_mkv_model.py`
kiểm rằng bỏ bất kỳ điểm nào trong ba điểm trên thì sai véc tơ của chuẩn, và giữ
hai lỗi của văn bản dự thảo thành test.

## Kiến trúc RTL

| File | Nội dung |
|------|----------|
| `bow_mkv_tables_pkg.sv` | **sinh tự động** (`mkv_model.py tables`): S-box, S-box nghịch đảo (hàm `case`), M4, M4⁻¹, M8, M8⁻¹, hằng số `Const⁰_l`, `Const¹_l` |
| `bow_mkv_pkg.sv` | các lớp trên trạng thái 256 bit: `sub_cells`, `mix_words`, `inv_mix_words` (xoay cột: chỉ là nối dây; nhân GF(2⁸) với hằng → mạng XOR), `x_words`, `block_mask`, `ks_const`; cờ `mubi4`, mã phát hiện lỗi của RAM khoá vòng `rk_edc` |
| `bow_mkv_core.sv` | engine: FSM, datapath nửa vòng thuận / nghịch, lược đồ khoá, RAM khoá vòng, phát hiện lỗi, xoá có kiểm tra |
| `bow_mkv.sv` | khối thanh ghi trên bus Bow32, giải mã lệnh, cờ trạng thái, ngắt, bộ đếm lỗi và `LOCKED` (miền power-on reset), `KEY_LOCK`, chính sách, lỗi bus |

**Hai cỡ khối trên một datapath.** Byte `b` của khối nằm ở `state[8b +: 8]`.
MKV-256 dùng 4 cột 64 bit, MKV-128 dùng 4 cột 32 bit ở 128 bit thấp (128 bit
cao luôn bằng 0). S-box dùng chung, chỉ MixWords (xoay `2c` hay `c` byte, M8 hay
M4), XWords (cột 64 hay 32 bit) và hằng số lược đồ khoá chọn theo cỡ khối.

**Một nửa vòng mỗi chu kỳ.** Hàm vòng tách thành hai nửa cùng dạng "cộng khoá →
SubCells → lớp tuyến tính": `M(S(x ⊕ K⁰))` rồi `XW(S(x ⊕ K¹))`. Phép giải mã là
ảnh gương: `S⁻¹(XW(x)) ⊕ K¹` rồi `S⁻¹(M⁻¹(x)) ⊕ K⁰`.

| Lệnh | Bước | Việc làm |
|------|------|----------|
| `ENC` | lúc nhận lệnh | `x ← DIN`, `in ← DIN`, `DIN ← 0` (DIN được chép: CPU ghi khối tiếp theo ngay được) |
| | `s = 0 … 2R−1` | `x ← L(S(x ⊕ h[s]))`, `L` = MixWords (s chẵn) / XWords (s lẻ) |
| | `s = 2R` | `x ← x ⊕ h[2R]` (K_post), giữ vào `DOUT` nhưng chưa cho đọc |
| | lượt 2 (2R + 1 chu kỳ) | giải mã `x` trên datapath nghịch như `DEC` (`TEST`: lượt này bắt đầu từ `x` lệch 1 bit) |
| | `Check` | hai bộ so sánh (`x = in` và `x ⊕ ~in` toàn 1) đều đúng, `DOUT` khớp bản bù, bộ đếm chu kỳ đúng: cờ `DOUT` hợp lệ (mubi4, ghép từ cả hai bộ so sánh), `DONE`; sai: `FAULT` |
| `DEC` | `s = 0` | `x ← DIN ⊕ h[2R]` (`in ← DIN`) |
| | `s = 1 … 2R` | `x ← S⁻¹(L⁻¹(x)) ⊕ h[2R − s]`, `L⁻¹` = XWords (s lẻ) / invMixWords (s chẵn); bước cuối giữ vào `DOUT` |
| | lượt 2, `Check` | mã hoá lại `x` trên datapath thuận, so với `in` như trên |
| `KEY` | lúc nhận lệnh | `K⁰, K¹ ← K_int`, `h[0] ← K⁰` (`RK_0`), `DOUT ← 0` |
| | lần cập nhật `i` (8 chu kỳ) | 4 nửa vòng thuận trên `K¹` với khoá `Const¹ ⊕ ⟨2i⟩, 0, 0, 0` → `A` (ghi tạm vào `K¹`, `h[2i−1]`); 4 nửa vòng trên `K⁰` với `Const⁰ ⊕ ⟨2i−1⟩` → `B`; `K⁰ ← A`, `K¹ ← A ⊕ B` (`h[2i]`), tức SWAP của điều 5.5. 6 chu kỳ không ghi RAM: `h[2R+1…31] ← 0` (khoá vòng của khoá dài hơn trước đó) |
| | lượt 2 (8R chu kỳ) | chạy lại từ `K_int` (đọc lại `KEY`), không ghi RAM mà so từng khoá nửa vòng với RAM (so cả dữ liệu lẫn mã); trong 6 chu kỳ còn lại đọc lại `h[2R+1…31]`, phải bằng 0 |
| | `Check` | so `h[0]`, bộ đếm chu kỳ; đúng: `KEY_VALID`, `KEY ← 0`; sai: `FAULT` |
| | sau đó | engine rảnh luôn giữ `K⁰, K¹, x, in` = 0: một chu kỳ sau lệnh chúng đã về 0 |
| `CLEAR` | 32 chu kỳ | ghi 0 vào 32 dòng (mã của dòng 0 tại địa chỉ đó), xoá mọi thanh ghi |
| | 32 chu kỳ | đọc lại 32 dòng: phải bằng 0 với mã đúng; bộ đếm chu kỳ phải khớp bộ đếm dòng ở **mọi** chu kỳ. Sai thì xoá lại từ đầu và báo `FAULT`, không bao giờ báo `DONE` cho một lần xoá bị cắt ngắn |

**Phát hiện lỗi.** Lỗi tiêm vào phần cứng (glitch xung clock / điện áp, laser)
làm sai một bước tính, và bản mã sai là thứ phân tích lỗi cần. Vì vậy không kết
quả nào ra khỏi IP mà chưa được làm lại theo cách khác và đối chiếu:

- `ENC` được kiểm tra bằng cách giải mã kết quả trên datapath **nghịch**, `DEC`
  bằng cách mã hoá lại trên datapath **thuận**: lượt hai phải trả lại đúng đầu
  vào (giữ trong `in`, và bản bù trong `in_n`). Hai lượt dùng hai mạch khác
  nhau, nên cả lỗi tạm thời lẫn lỗi cố định ở một datapath đều lộ ra.
- `KEY` chạy lược đồ khoá hai lần từ khoá chính; lần hai so từng khoá nửa vòng
  với RAM và đọc lại các dòng phía trên `h[2R]` mà lần một đã xoá.
- **RAM khoá vòng** là phần hai lượt dùng chung: khoá vòng bị đổi ở đó cho cùng
  một kết quả sai ở cả hai lượt. Mỗi lần đọc (của `ENC`, `DEC`, lần so của `KEY`,
  lượt đọc lại của `CLEAR`) được kiểm bằng một mã phát hiện lỗi: mỗi dòng là 8 từ
  mã Hsiao (39,32) xen kẽ (từ `j` gồm bit `j` của 32 byte, 7 bit kiểm tra), nên
  thấy mọi lỗi 1–3 bit trong một từ, tức mọi chùm tới 24 bit liền nhau (các bit
  cạnh nhau của một LUTRAM thuộc các từ khác nhau). Địa chỉ dòng được cộng vào bit
  kiểm tra: một dòng đọc ở địa chỉ khác (lỗi bộ giải mã địa chỉ, word line, dòng
  bị chép sang dòng khác) cũng không khớp mã.
- **Thanh ghi kết quả** `DOUT` có bản bù ghi cùng lúc, được so ở `Check` và suốt
  thời gian kết quả còn đọc được: lệch là `FAULT`, `DOUT` đọc ra 0 ngay.
- **Không có điểm hỏng đơn trong phép so:** mỗi quyết định của `Check` qua hai bộ
  so sánh khác cấu trúc (`ENC`/`DEC`: `x = in` và `x ⊕ in_n` toàn 1; `KEY`: dữ liệu
  và mã của dòng). Cờ cho đọc `DOUT` và cờ "có lược đồ khoá" là mubi4 (`0110`
  đúng, `1001` sai, giá trị khác là lỗi) ghép từ cả hai bộ so sánh, nên một bộ so
  sánh kẹt ở "bằng" không tự cho ra được kết quả nào.
- Những thứ hai lượt dùng chung khác cũng được bảo vệ: phiên bản (R, cỡ khối)
  lưu cả giá trị lẫn bản bù; một bộ đếm thứ hai, nạp từ bản bù, phải đếm đúng số
  chu kỳ của lệnh (bỏ bớt vòng, kết thúc sớm đều lộ); FSM mã **thưa** (6 bit, hai
  trạng thái bất kỳ khác nhau ≥ 3 bit: lật một bit là ra mã không có), trạng thái
  ngoài danh sách hay quay về `Idle` giữa chừng là lỗi; `ENC`/`DEC` khi engine
  không có lược đồ khoá đã kiểm tra là lỗi, và `KEY_VALID` của khối thanh ghi mà
  engine không có lược đồ khoá cũng là lỗi (`STATUS.KEY_VALID` là AND của hai bên).
- **Thao tác xoá được kiểm tra** (`CLEAR`, sau reset, sau lỗi, khi mất `KEY_VALID`):
  ghi 0 rồi đọc lại cả 32 dòng, bộ đếm chu kỳ phải khớp bộ đếm dòng ở mọi chu kỳ,
  và phát hiện lỗi vẫn chạy trong lúc xoá. Lần xoá bị cắt ngắn được làm lại, có
  báo `FAULT`.
- **Tự kiểm phần phát hiện lỗi:** `CMD = TEST | KEY/ENC/DEC` cố ý làm lệch 1 bit ở
  đầu lượt hai; lệnh phải kết thúc bằng `FAULT` (không bị đếm). Một `TEST` mà không
  có `FAULT` nghĩa là phần phát hiện lỗi hỏng: IP tự khoá. Driver chạy nó trong
  `bow_mkv_selftest()` lúc khởi động.
- Các thanh ghi của phần dư thừa mang thuộc tính `keep` để Vivado không gộp hay
  bỏ chúng; flow ASIC cần `dont_touch` / `size_only` tương ứng.

Khi phát hiện lỗi, engine không trả kết quả (`DOUT` đọc ra 0), báo `fault_o`,
rồi xoá RAM khoá vòng và mọi thanh ghi (64 chu kỳ). Khối thanh ghi đặt `FAULT`,
xoá `KEY`, `DIN`, `KEY_VALID` và tăng bộ đếm `FAULTS`.

**Giới hạn số lần thử.** Bộ đếm lỗi (`STATUS.FAULTS`) và cờ `LOCKED` nằm trong
miền **power-on reset** (`por_rst_ni`): reset hệ thống (phần mềm, UART BREAK)
không xoá chúng. Bộ đếm có bản bù; `LOCKED` là mubi4, mọi giá trị khác `False` đều
là khoá. Tới `FaultLimit` lỗi (tham số, mặc định 4, đọc ở `INFO[19:16]`), khi bộ
đếm bị sửa, hay khi một `TEST` không bị phát hiện, IP **tự khoá** tới lần bật
nguồn sau: mọi lệnh trừ `CLEAR` bị từ chối, ghi `CTRL`/`KEY`/`DIN` bị bỏ, không
truy cập nào bị giữ trên bus, những gì engine còn giữ bị xoá. Lúc khoá, IP bật
**alert nghiêm trọng** (`STATUS.ALERT`, chân `alert_fatal_o`) nối vào NMI của
Ibex: không tắt được bằng `IRQ_EN`; handler mặc định (`bow_nmi_handler`) in thông
báo rồi dừng. `alert_fault_o` (một xung mỗi lỗi được đếm) dành cho bộ xử lý alert
của SoC sau này; Bow32 chưa có, nên lỗi lẻ chỉ báo qua ngắt `FAULT`.

**RAM khoá vòng.** 32 × (256 + 56 mã) bit, ghi đồng bộ, đọc bất đồng bộ
(Vivado suy ra LUTRAM). Mã hoá đọc `h[s]`, giải mã đọc `h[2R − s]`: không cần tính lại
lược đồ khoá theo chiều ngược. LUTRAM không có reset, nên sau mỗi reset FSM bắt
đầu ở `Clear`: 64 chu kỳ ghi 0 rồi đọc lại (`BUSY` = 1, không đặt `DONE`,
`CYCLES` giữ 0).

**Đường dài nhất** (50 MHz, 20 ns): đọc RAM → XOR → S-box → M8 → mux → thanh
ghi, ngắn hơn đường qua bus (Ibex → crossbar → ghi thanh ghi MKV: slack +1,27 ns
ở `kv260_cam`, +3,8 ns ở `kv260`, chủ yếu là trễ dây, thay đổi theo mỗi lần place
& route; các đường bắt đầu từ thanh ghi MKV còn ≥ +3,4 ns). Muốn nhanh hơn có thể làm cả vòng mỗi chu kỳ (gấp đôi S-box).

## Bản đồ thanh ghi (`0x4000_B000`)

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| 0x000 | `ID` | R | `0x4D4B5602` ("MKV", phiên bản 2: TCVN 14263:2024; phiên bản 1 là mã của bản dự thảo) |
| 0x004 | `INFO` | R | [0] có MKV-128, [1] có MKV-256, [2] có phát hiện lỗi, [3] mã phát hiện lỗi của khoá vòng, [4] bộ đếm lỗi / `LOCKED` / alert, [5] lệnh `TEST`, [6] `NOSTALL`, [7] `KEY_LOCK` và chính sách, [15:8] số chu kỳ mỗi vòng của `ENC`/`DEC` (4: 2 + lượt kiểm tra), [19:16] `FaultLimit` — `0x000404FF` |
| 0x008 | `CTRL` | RW | [0] `BLOCK` (0 MKV-128, 1 MKV-256), [2:1] `KLEN` (0: k = l, 1: k = 3l/2, 2: k = 2l, 3: không hợp lệ) — phiên bản cho lệnh `KEY` kế tiếp; [3] `NOSTALL` (xem dưới); [4] `KEY_LOCK` (ghi 1 để đặt, chỉ reset mới xoá); [5] `NO_DEC`, [6] `NO_ENC` (chính sách dùng khoá) |
| 0x00C | `CMD` | W | mỗi lần ghi **một** bit: [0] `KEY`, [1] `ENC`, [2] `DEC`, [3] `CLEAR`; [4] `TEST` chỉ đi kèm `KEY`/`ENC`/`DEC`; ghi 0 không làm gì |
| 0x010 | `STATUS` | R/W1C | [0] `BUSY`, [1] `KEY_VALID`, [2] `DONE` (W1C), [3] `ERR` (W1C), [4] `WIDE`, [5] `FAULT` (W1C), [6] `LOCKED`, [7] `ALERT` (W1C), [11:8] `ROUNDS`, [15:12] `FAULTS` (số lỗi từ lúc bật nguồn, bão hoà ở 15) — `WIDE`/`ROUNDS`: phiên bản của lược đồ khoá đang có (0 nếu chưa có) |
| 0x014 | `IRQ_EN` | RW | [2] ngắt khi `DONE`, [3] ngắt khi `ERR`, [5] ngắt khi `FAULT` |
| 0x018 | `CYCLES` | R | số chu kỳ của lệnh cuối, từ lúc ghi `CMD` tới khi có kết quả |
| 0x040–0x07C | `KEY[0..15]` | W | khoá chính, byte `b` = `KEY[b/4]` bit `8·(b%4)`; về 0 khi lệnh `KEY` xong (lượt hai đọc lại khoá) hay bị từ chối |
| 0x080–0x09C | `DIN[0..7]` | W | khối vào, cùng thứ tự byte (MKV-128: `DIN[0..3]`); về 0 khi `ENC`/`DEC` lấy khối |
| 0x0C0–0x0DC | `DOUT[0..7]` | R | khối ra (MKV-128: `DOUT[4..7]` = 0); về 0 khi `KEY`; đọc ra 0 khi chưa có kết quả đã kiểm tra hay khi `LOCKED` |

**Lỗi bus.** Đọc `CMD` / `KEY` / `DIN`, ghi `ID` / `INFO` / `CYCLES` / `DOUT` và
mọi offset khác trả `err` (Ibex: load / store access fault) và không có tác dụng.
DMA không tới được cửa sổ MKV: `bow32_top` đặt tường lửa (`bow_bus_deny`) trước
cổng DMA của main crossbar, yêu cầu tới `0x4000_B000…0x4000_BFFF` trả lỗi bus.

Thứ tự byte: word thanh ghi là little-endian của chuỗi byte của chuẩn, nên trên
Ibex (little-endian) một mảng `uint8_t` căn 4 byte chép thẳng bằng `lw`/`sw`.
Mọi thanh ghi nhận byte enable (`sb`, `sh`).

**Lệnh bị từ chối** (đặt `ERR`, không chạy): `ENC`/`DEC` khi `KEY_VALID = 0` hay
chính sách cấm (`NO_ENC`/`NO_DEC`), `KEY` khi `KLEN = 3`, khi `KEY_LOCK`, hoặc khi
chưa ghi đủ k/32 từ khoá của phiên bản trong `CTRL` kể từ lệnh `KEY`/`CLEAR` (hay
reset) trước, `CMD` có nhiều hơn một bit (`TEST` đi một mình hay với `CLEAR` cũng
vậy), mọi lệnh trừ `CLEAR` khi `LOCKED`. `KEY` bị từ chối xoá luôn các từ khoá đã
ghi. Một từ tính là đã ghi khi có ghi vào nó, kể cả chỉ một byte; byte không ghi
lại là 0, không bao giờ là byte của khoá cũ. `KEY_VALID` = 1 sau `KEY`, về 0 khi
ghi `KEY[i]`, khi đổi phiên bản trong `CTRL` (hai trường hợp này engine xoá luôn
lược đồ khoá và kết quả cũ, 64 chu kỳ, không đặt `DONE`), khi `CLEAR`. `CLEAR` xoá
`KEY`, `DIN`, `DOUT`, trạng thái và cả 32 dòng RAM khoá vòng. Ghi bị bỏ (`KEY`
khi `KEY_LOCK`, đổi phiên bản hay chính sách khi `KEY_LOCK`, ghi khi `LOCKED`) cũng
đặt `ERR`.

**`FAULT`** (W1C): engine phát hiện lỗi, không trả kết quả, đã xoá khoá vòng,
`KEY`, `DIN`, `DOUT`, `KEY_VALID`. Lệnh bị lỗi không đặt `DONE`. Lỗi là dấu hiệu
tấn công hay phần cứng hỏng: phần mềm nên ghi lại và báo lên, **không tự động thử
lại**. Muốn dùng lại: `CLEAR`, xoá `FAULT`, nạp khoá lại; tới `FaultLimit` lỗi IP
tự khoá (`LOCKED`).

**`KEY_LOCK`** (`CTRL[4]`): sau khi nạp khoá, firmware khởi động có thể cố định
nó tới lần reset sau: `KEY`, phiên bản và chính sách không đổi được nữa (ghi bị
bỏ, `ERR`), lệnh `KEY` bị từ chối; `ENC`/`DEC` (theo chính sách) và `CLEAR` vẫn
chạy. Ví dụ khoá giải mã mô hình AI: `NO_ENC | KEY_LOCK`, phần mềm ứng dụng chỉ
giải mã được, không dùng khoá đó để mã hoá được.

Vì `KEY` xoá thanh ghi khoá, mỗi lần chạy lược đồ khoá phải ghi lại cả khoá
(`bow_mkv_set_key` vẫn làm vậy). Đổi `CTRL` rồi chạy `KEY` mà không ghi khoá
mới sẽ bị từ chối, không lặng lẽ dùng khoá toàn 0.

**Chờ trên bus thay vì hỏi vòng.** Khi một lệnh đang chạy (`BUSY`), ghi
`CTRL` / `CMD` và đọc `DOUT` bị giữ (`gnt = 0`, [../bus.md](../bus.md)) tới khi
xong; ghi `KEY` cũng vậy, trừ khi engine chỉ đang xoá. Vì vậy phần mềm ghi `CMD`
rồi đọc `DOUT` ngay, không cần vòng hỏi `BUSY`; ghi `CMD` ngay sau `KEY` sẽ tự chờ
lược đồ khoá. Đọc `STATUS`/`ID` và ghi `DIN`/`STATUS`/`IRQ_EN` không bao giờ bị giữ.

Một truy cập bị giữ chặn cả bus ngoại vi (tới 144 chu kỳ khi `CMD` chờ `KEY` của
MKV-256/512) và làm trễ ngắt. Với **`NOSTALL`** (`CTRL[3]`) không truy cập nào bị
giữ: ghi `CTRL` / `CMD` / `KEY` khi đang bận bị bỏ và đặt `ERR`, đọc `DOUT` khi đang
bận ra 0; phần mềm hỏi vòng `BUSY` hay chờ ngắt `DONE` (driver tự làm khi bit
này bật: `bow_mkv_set_nostall(true)`). Khi `LOCKED` cũng không truy cập nào bị giữ.

## Lập trình

```c
#include "bow32.h"

static uint8_t key[32] = {...};
static const uint8_t pt[16] = {...};
uint8_t ct[16], back[16];

if (!bow_mkv_selftest()) {               /* một lần lúc khởi động: 6 KAT + 3 TEST */
  /* IP hỏng hay đã LOCKED: không dùng, báo lên */
}
if (!bow_mkv_set_key(128, 256, key)) {   /* bow_mkv_error(): phiên bản, từ chối, FAULT, LOCKED */
}
bow_mkv_wipe(key, sizeof(key));          /* khoá đã ở trong IP */
if (!bow_mkv_encrypt(pt, ct)) {          /* CYCLES = 4R + 4 = 40 */
  /* FAULT: kết quả đã bị huỷ (ct = 0), khoá đã bị xoá. Ghi lại và báo lên;
     không tự động nạp lại khoá và thử lại (mỗi lần thử là một mẫu cho kẻ
     tấn công, IP tự khoá sau FaultLimit lỗi) */
}
bow_mkv_decrypt(ct, back);
bow_mkv_ecb(false, buf, buf, nblocks);   /* nhiều khối, ghi DIN khối sau khi IP đang chạy */
bow_mkv_lock_key(false, true);           /* tuỳ chọn: chỉ giải mã, khoá cố định tới reset */
bow_mkv_clear();                         /* xoá khoá */
```

`bow_mkv_set_key()` từ chối nạp khoá khi `bow_mkv_selftest()` chưa qua. Mọi hàm
trả `false` để lại lý do trong `bow_mkv_error()` (`bow_mkv_error_name()` cho chuỗi).
Driver không reentrant: ngắt và chương trình chính không được cùng dùng IP.

Không dùng driver: `CTRL`, `KEY[i]`, `CMD = KEY`; rồi mỗi khối `DIN[i]`,
`CMD = ENC`, đọc `DOUT[i]`.

## Kiểm chứng

Bốn tầng, mỗi tầng dựa trên tầng trước:

1. **Mô hình ↔ chuẩn.** Văn bản chuẩn là ảnh scan, không trích tự động được:
   Phụ lục A của TCVN 14263:2024 được chép vào `tools/mkv/tcvn14263_vectors.json`,
   mỗi phiên bản gồm khoá, bản rõ, **mọi khoá vòng** `RK_0 … RK_2R`, 9 bước của
   cả hai nhánh ở lần cập nhật khoá đầu, 6 bước của vòng đầu và vòng cuối, bản mã
   (288 giá trị, mỗi giá trị đọc lại ở 300 dpi). S-box, ma
   trận và hằng số đối chiếu với điều 5.4, 5.5. Bản dự thảo có lớp chữ:
   `tools/mkv/extract_vectors.py` trích từ PDF (`pdftotext`) hai bảng S-box, bốn
   ma trận và 6 véc tơ của Phụ lục A dự thảo **với mọi giá trị trung gian** vào
   `tools/mkv/draft_vectors.json`. `mkv_model.py selftest` và 28 unit test
   (`make test-tools`) kiểm tra mô hình khớp từng giá trị của cả hai phụ lục
   (bản dự thảo với phiên bản `DRAFT` của mô hình), giải mã, ba điểm khác nhau
   (bỏ một điểm là sai véc tơ của chuẩn), hai lỗi của văn bản dự thảo, file sinh
   ra còn mới.
2. **RTL ↔ mô hình** (`make -C hw/ip/mkv/dv test`, cũng trong `make test-ip` và
   CI). `mkv_model.py gen` sinh Phụ lục A + khoá/khối ngẫu nhiên cho cả 6 phiên
   bản (cả khoá toàn 0, toàn 1); `tb_bow_mkv.sv` chạy qua bus thanh ghi (ghi
   byte enable ngẫu nhiên, ghi `DIN` khi đang chạy, đọc `DOUT` bị giữ hay sau hỏi
   vòng) và ghi lại **trạng thái sau mỗi nửa vòng** và **RAM khoá vòng** sau mỗi
   `KEY`; `mkv_model.py check` so tất cả. Sau mỗi `KEY` testbench còn kiểm tra
   `KL`/`KR`/trạng thái về 0 (chu kỳ kế) và `h[2R+1…31]` = 0. Thêm các test có
   hướng: `ERR`, `KEY_VALID`, `KEY` cần khoá mới đủ từ (ghi thiếu byte 0 phải
   cho bản mã của khoá có byte 0 = 0, không phải của khoá cũ), `DIN`/`DOUT` về 0,
   `CLEAR` (RAM về 0), ngắt, `CYCLES`, stall, reset (RAM khoá vòng về 0, không
   `DONE`).
   Các test có hướng của lần sửa theo [đánh giá bảo mật](../mkv_security_review.md):
   lỗi bus (đọc `CMD`/`KEY`/`DIN`, ghi `ID`/`INFO`/`CYCLES`/`DOUT`, lỗ trong bản
   đồ, không thay đổi gì), mất `KEY_VALID` do ghi `KEY` hay đổi phiên bản thì RAM
   khoá vòng và `DOUT` bị xoá ngay, `KEY` bị từ chối không để lại từ khoá nào,
   `NOSTALL` (không truy cập nào bị giữ, ghi khi đang bận bị bỏ, `DOUT` ra 0, `DIN`
   vẫn ghi được), chính sách `NO_ENC`/`NO_DEC` và `KEY_LOCK` (ghi bị bỏ, `KEY` bị
   từ chối, `CLEAR` vẫn chạy, chỉ reset mới gỡ).
   **Tiêm lỗi** (`force`/`release` một thanh ghi trong một chu kỳ, ghi thẳng vào một
   thanh ghi của RTL — bit bị lật giữ nguyên tới khi RTL ghi lại —, hay ghi thẳng
   vào RAM khoá vòng). Mỗi lỗi phải cho `FAULT` (đếm đúng một lần ở `FAULTS` và
   `alert_fault_o`, trừ lỗi của `TEST`), không `DONE`, `DOUT` = 0, khoá, thanh ghi
   và cả 32 dòng RAM (với mã của dòng 0) về 0; sau mỗi lỗi có power-on reset:
   - trạng thái trong lượt một của `ENC`, trong lượt kiểm tra của `DEC`, trong
     lượt một của `KEY`;
   - RAM khoá vòng: 1 bit, 2 bit trong một byte, cả một byte, 24 bit liền nhau,
     một bit kiểm tra, một dòng chép đè lên dòng khác (kèm mã của nó);
   - thanh ghi kết quả trong lượt kiểm tra, sau khi đã cho đọc (`DOUT` ra 0 ngay),
     bản bù của nó;
   - bộ đếm bước (bỏ nửa vòng), bộ đếm chu kỳ, số vòng khi rảnh;
   - FSM: hai mã không phải trạng thái, về `Idle` giữa `ENC`, lật từng bit trong
     `Check` của `KEY` (cả 6 bit) và một bit trong mỗi trạng thái khác;
   - một bit của từng cờ mubi4 (lượt hai, loại lệnh, có lược đồ khoá, có kết quả);
   - một bộ so sánh của `Check` kẹt ở "bằng" (từng bộ trong hai bộ, cho `ENC` và
     cho `KEY`) cùng một lỗi ở lượt một: bộ còn lại và cờ ghép vẫn bắt;
   - `CLEAR` bị cắt ngắn lúc ghi 0 và lúc đọc lại, lần xoá sau reset bị cắt ngắn;
   - một dòng phía trên `h[2R]` có dữ liệu khi `KEY` đọc lại;
   - `KEY_VALID` của khối thanh ghi bị bật khi engine không có khoá;
   - `TEST` của `KEY`/`ENC`/`DEC` (không bị đếm), `TEST` mà phần lệch bị mất (IP
     tự khoá, xoá lược đồ khoá, `DOUT` ra 0).
   Rồi **lockout**: `FaultLimit` lỗi liên tiếp thì `LOCKED`, `ALERT`, alert
   nghiêm trọng; khi khoá, mọi lệnh trừ `CLEAR` bị từ chối và không truy cập nào
   bị giữ; ghi 1 vào `ALERT` tắt alert nhưng không gỡ khoá; reset hệ thống không
   gỡ khoá, không xoá `FAULTS`; bộ đếm lỗi bị sửa thì khoá ngay; power-on reset gỡ
   khoá. Thêm: ngắt `FAULT`, `DOUT` đọc ra 0 khi không có kết quả đã kiểm tra.
   RTL còn có **assertion** (Verilator `--assert`): không có kết quả đọc được khi
   engine bận, `Check` chỉ cho ra kết quả khi cả hai bộ so sánh đồng ý, sau lỗi
   luôn là lần xoá không `DONE`, lần xoá chỉ xong khi bộ đếm chu kỳ đúng.
   4 seed: 514 phép toán, ~8 700 trạng thái, 264 lược đồ khoá, 192 lỗi phát hiện
   (48 mỗi seed); thử thêm `make run SEED=99 COUNT=600` (1 231 phép toán, ~21 000
   trạng thái). `make test` chạy cả `tb_mkv_review.sv` (`make review`): 8 thí
   nghiệm của bản đánh giá, giờ là test đạt / không đạt (mục 7 của
   [../mkv_security_review.md](../mkv_security_review.md)).
   **Mutation** (`make mutants`, `hw/ip/mkv/dv/mutants.py`): 33 bản RTL, mỗi bản bỏ
   một biện pháp (mã RAM, gắn địa chỉ, bản bù `DOUT`, đọc lại khi xoá, đếm khi xoá,
   đọc lại dòng cũ của `KEY`, cờ mubi4, `KEY_VALID`, FSM, bộ so sánh thứ hai, bộ đếm
   chu kỳ, phiên bản, `Idle` giữa chừng, xoá khi lỗi, `TEST`, lockout, miền reset,
   bộ đếm bị sửa, xoá khi khoá, `NOSTALL`, `KEY_LOCK`, chính sách, xoá khi mất
   `KEY_VALID`, `KEY` bị từ chối, `DIN` chỉ ghi, AND của `KEY_VALID`) hay một điểm
   của chuẩn, đều làm test hỏng. Không phải mutant vì vẫn bị bắt nhờ phép kiểm khác:
   FSM mã dày (bộ đếm chu kỳ của trạng thái nó rơi vào bắt), bỏ kiểm mã ở lượt giải
   mã (lượt mã hoá của cùng lệnh đọc lại mọi khoá vòng). Trước lần sửa này: 25 bản
   của bản RTL cũ, mỗi bản bỏ một cơ chế hay một điểm của chuẩn, cũng đều làm test
   hỏng. Bốn bản quay về bản dự thảo: `MixWords` hay
   `invMixWords` không xoay (chính IP báo `FAULT` ở lệnh đầu, vì chiều thuận và
   chiều nghịch không còn khớp), lược đồ khoá không có `Const` (sai véc tơ đầu), R
   của bản dự thảo (sai `ROUNDS` ngay ở `KEY` đầu). Các bản còn lại: giữ khoá
   trong `KEY`, nhận `KEY` thiếu từ, giữ `DIN`/`DOUT`, giữ khoá vòng của khoá dài
   trước, giữ `K_R`, không xoá RAM sau reset, và tắt từng phép kiểm tra (parity,
   so kết quả, so lược đồ khoá, bộ đếm chu kỳ, bỏ qua `Check`, phiên bản, trạng
   thái, lệnh bị mất, `ENC` không khoá, che `DOUT`, xoá khi lỗi).
3. **Hệ thống** (`make run TEST=mkv`): firmware `sw/apps/mkv` trên Ibex trong SoC
   đầy đủ chạy tự kiểm tra lúc khởi động của driver, `test quick` (19 nhóm kiểm
   tra, xem dưới) rồi `key`/`enc`/`dec` qua shell, so với giá trị của mô hình.
4. **Trên board** ([../mkv_kv260.md](../mkv_kv260.md)): `test` (đủ, 20 khoá
   ngẫu nhiên mỗi phiên bản), `tools/bow32_mkv.py kat` (bản mã so với giá trị in
   trong chuẩn) và `verify` (khoá/khối ngẫu nhiên từ PC, so với mô hình Python —
   độc lập với phần mềm chạy trên board). Bản hiện tại chạy trên Arm MPS4
   (2026-11-08): tự kiểm tra lúc khởi động PASS, `test` 19/19, `kat` 6/6, `verify`
   360/360 và 1 800/1 800 khối.

`test` của ứng dụng: (1) ID/INFO, (2) MKV phần mềm (`mkv_sw.c`, viết theo chuẩn)
khớp Phụ lục A cả khoá vòng, (3)(4) IP mã hoá / giải mã 6 véc tơ + `STATUS`,
`CYCLES`, (5) IP ↔ phần mềm trên khoá/khối ngẫu nhiên: E, D, D(E(x)) = x, (6)
ECB (ghi `DIN` khi đang chạy, buffer lệch, tại chỗ), (7) lệnh lỗi, (8)
`KEY_VALID`, (9) `CLEAR` (65 chu kỳ, `DOUT` về 0), (10) ngắt `DONE`/`ERR` tới
`irq_fast[10]` (đọc `mip`), (11) stall bus (`CMD` trong lúc `KEY`, `DOUT` trong lúc
`ENC`), (12) xoá: `KEY` không có khoá mới bị từ chối, khoá ghi bằng `sb` thiếu
byte 0 cho đúng bản mã của khoá có byte 0 = 0 (so với MKV phần mềm), `DOUT` về 0
sau `KEY`, (13) lỗi bus (đọc `CMD`/`KEY`/`DIN`, ghi `ID`/`DOUT`, lỗ), (14) `NOSTALL`
(`CMD` trong lúc `KEY` bị bỏ, `DOUT` ra 0 ngay, ECB qua driver vẫn đúng), (15)
chính sách `NO_ENC`/`NO_DEC`, (16) `TEST` của `KEY`/`ENC`/`DEC` cho `FAULT`, không bị
đếm, IP chạy lại sau `CLEAR`, (17) DMA không đọc / ghi được thanh ghi MKV (đọc
thanh ghi của chính DMA thì được), (18) tự kiểm tra lúc khởi động của driver lại
qua, (19) `INFO` báo có phát hiện lỗi, không có `FAULT` nào ngoài các `TEST`,
`FAULTS` không đổi (không báo nhầm). `KEY_LOCK` chỉ reset mới gỡ nên chỉ được
kiểm ở tầng 2. Lỗi thật thì phần mềm không tự tạo được: phần phát hiện được kiểm
chứng bằng tiêm lỗi trong mô phỏng (tầng 2), lệnh `TEST` kiểm nó trên board.

## Bảo mật

Những gì IP bảo đảm:

- Thời gian mỗi lệnh cố định, không phụ thuộc dữ liệu hay khoá (`CYCLES`).
- Phát hiện lỗi tiêm vào (mục "Phát hiện lỗi" ở trên): không kết quả nào ra
  khỏi IP mà chưa được làm lại bằng mạch khác và đối chiếu bằng hai bộ so sánh;
  khoá vòng có mã phát hiện lỗi gắn địa chỉ, kết quả có bản bù; phiên bản, bộ
  đếm, FSM (mã thưa), các cờ (mubi4) và cả thao tác xoá được kiểm tra. Lỗi thì
  không ra gì và khoá bị xoá.
- Số lần thử có giới hạn: `FaultLimit` lỗi từ lúc bật nguồn thì IP tự khoá tới
  power-on reset (reset hệ thống không gỡ), báo bằng alert không tắt được (NMI).
  Phần phát hiện lỗi tự kiểm được bằng `TEST`; driver chạy nó và KAT 6 phiên bản
  trong `bow_mkv_selftest()`, chưa qua thì không nạp được khoá.
- `KEY` và `DIN` chỉ ghi, RAM khoá vòng không đọc được qua bus, `DOUT` không đọc
  được giữa chừng (bus chờ, hay đọc ra 0 với `NOSTALL`), `CTRL`/`KEY` không đổi
  được khi đang chạy, truy cập sai trả lỗi bus.
- Khoá chỉ nằm ở nơi cần, trong thời gian cần. Lệnh `KEY` lấy khoá khỏi `KEY`
  và xoá về 0, nên ghi đè một phần khoá rồi chạy lại `KEY` không bao giờ trộn
  byte mới với byte của khoá đã dùng. Không làm vậy thì ai ghi được `KEY` và ra
  lệnh được, dù không đọc được khoá, có thể dò khoá từng byte bằng cách so bản
  mã. `KEY` cũng cần đủ từ khoá mới, nên đổi phiên bản trong `CTRL` không dùng lại
  được khoá bí mật cho phiên bản khác, và không lặng lẽ chạy khoá toàn 0; `KEY`
  bị từ chối thì các từ khoá đã ghi bị xoá.
- Engine giữ `K_R` và trạng thái bằng 0 khi rảnh (một chu kỳ sau lệnh), xoá
  khoá vòng của khoá dài hơn trước đó (và đọc lại để kiểm), xoá cả RAM sau mỗi
  reset, sau mỗi lỗi, khi khoá, và ngay khi mất `KEY_VALID` (ghi `KEY`, đổi phiên
  bản). UpdateKS đảo ngược được (`F` là hoán vị khi khoá cố định), nên một cặp
  `K_i^L`, `K_i^R` bất kỳ đã đủ suy ra khoá chính: các bản sao này quý ngang khoá
  chính.
- `DIN` về 0 khi lệnh lấy khối, `DOUT` về 0 khi có khoá mới; `CLEAR` xoá hết.
  Sau phiên làm việc nên gọi `bow_mkv_clear()`, và xoá bộ đệm khoá bằng
  `bow_mkv_wipe()`.
- Kiểm soát truy cập ở mức IP: `KEY_LOCK` cố định khoá đã nạp tới reset, chính
  sách `NO_ENC` / `NO_DEC` giới hạn cách dùng khoá; DMA không tới được thanh ghi
  MKV (tường lửa trong `bow32_top`).

Những gì IP **chưa** có (xem xét theo mô hình đe doạ của sản phẩm; lộ trình ở
[../mkv_security_review.md](../mkv_security_review.md)):

- Chống tấn công kênh kề (công suất, điện từ): datapath không masking, không
  hiding. Lượt kiểm tra còn làm mỗi khoá được dùng gấp đôi số lần. Masking cần
  TRNG, Bow32 chưa có.
- Giới hạn của phát hiện lỗi:
  - Lỗi giống hệt nhau ở cả hai lượt thì không lộ. Hai lượt chạy ở hai thời
    điểm khác nhau, trên hai datapath khác nhau, nên khó làm vậy nhưng không
    phải không thể.
  - Mã của RAM khoá vòng có khoảng cách 4: một số mẫu 4 bit lỗi trong cùng một
    từ mã (bit `j` của 4 byte khác nhau) có thể lọt.
  - Lỗi ở `DIN`/`KEY` trước khi engine lấy là lỗi của đầu vào, không phải của
    phép tính. Lỗi bền vững dùng chung ở phần lược đồ khoá của một phiên bản chỉ
    lộ ở KAT của `bow_mkv_selftest()` (chạy lúc khởi động), không lộ giữa chừng.
  - Không có cảm biến glitch / điện áp ở mức SoC, không có bộ xử lý alert (lỗi lẻ
    chỉ báo qua ngắt `FAULT`; lỗi nghiêm trọng là NMI).
  - Bộ đếm lỗi nằm trong flop: bật lại nguồn là xoá. Sản phẩm cần bộ đếm trong
    bộ nhớ không mất (OTP / flash) nếu muốn giới hạn qua nhiều lần bật nguồn.
- Kiểm soát truy cập ở mức SoC: CPU chạy một mức đặc quyền, Bow32 chưa bật PMP,
  nên mọi phần mềm trên CPU đều dùng được IP như nhau. `KEY_LOCK` và chính sách
  chỉ có ích khi phần mềm khởi động (tin cậy) đặt chúng trước khi chạy phần mềm
  khác.
- Khoá vẫn đi qua phần mềm (RAM, thanh ghi CPU): chưa có OTP / key manager để nạp
  thẳng khoá vào IP.

Chế độ hoạt động (CBC, CTR, GCM…) do phần mềm làm trên lệnh `ENC`/`DEC`;
`bow_mkv_ecb` chỉ là ECB (khối rõ trùng → khối mã trùng), không toàn vẹn.

Đánh giá IP theo thông lệ công nghiệp và chuẩn bảo mật cho SoC camera AI (mô hình
đe doạ, các phát hiện, thí nghiệm tiêm lỗi `make -C hw/ip/mkv/dv review`, lộ trình
sửa, trạng thái sau khi sửa): [../mkv_security_review.md](../mkv_security_review.md).

## Bài tập mở rộng

- Cả vòng mỗi chu kỳ (2 lớp S-box): 4R + 4 → 2R + 4 chu kỳ.
- Tham số tắt lượt kiểm tra (2R + 2 chu kỳ) cho thiết kế không cần chống tiêm lỗi.
- Bản nhỏ: một cột mỗi chu kỳ (S-box và MixWords chia 4).
- Chế độ CTR / CBC trong phần cứng, nạp dữ liệu bằng DMA (kênh 1 M2M) để không
  tốn CPU.
- Tham số `Block256 = 0` để bỏ phần MKV-256 khi chỉ cần MKV-128.
