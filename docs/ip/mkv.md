# Khối mật mã MKV (`bow_mkv`)

IP tăng tốc **mã khối MKV** của dự thảo tiêu chuẩn quốc gia *TCVN XXXX:2024
Công nghệ thông tin – Các kỹ thuật an toàn – Thuật toán mật mã – Mã khối MKV*
(Ban Cơ yếu Chính phủ, bản PDF trong `docs/ref/Du-thao-TCVN-XXXX2024.pdf`). Đủ
**6 phiên bản** của chuẩn, lược đồ khóa chạy trong phần cứng, mã hoá và giải mã
mỗi lệnh một khối. Mỗi lệnh được làm hai lần và đối chiếu trước khi trả kết quả
(phát hiện lỗi tiêm vào phần cứng). Mã RTL: `hw/ip/mkv/rtl/`. Mô hình tham chiếu:
`tools/mkv/mkv_model.py`. Driver: `sw/common/include/bow_mkv.h`. Ứng dụng kiểm
thử: `sw/apps/mkv`, chạy trên KV260: [../mkv_kv260.md](../mkv_kv260.md).

```
               +--------------------------------------------------------------------+
  bus ────────►| bow_mkv: CTRL CMD STATUS IRQ_EN CYCLES  KEY[16] (W)  DIN[8]  DOUT[8]  |──► irq_fast[10]
  0x4000_B000  +--------------------------------------------------------------------+
                  │ lệnh (KEY/ENC/DEC/CLEAR), khoá 512 bit, khối 256 bit     ▲ kết quả
                  ▼                                                          │
               +--------------------------------------------------------------------+
               | bow_mkv_core                                                       |
               |   K_0 từ khoá chính ─► KL / KR (2 × 256 bit)                       |
               |                           │ UpdateKS: F(0, F(c, x)) × 2 / lần       |
               |   nửa vòng thuận:  x ^ k ─► SubCells ─► MixWords | XWords ─► x     |
               |   nửa vòng nghịch: x ─► XWords | invMixWords ─► invSubCells ─► ^ k |
               |                           ▲ k                                       |
               |   RAM khoá vòng 32 × (256 + 32 parity) bit (LUTRAM): h[0..2R]       |
               |   lượt 2 (ENC ↔ DEC, KEY lần hai), so sánh, parity ─► FAULT         |
               +--------------------------------------------------------------------+
```

| Thông số | Giá trị |
|----------|---------|
| Phiên bản | MKV-128 (khối 128 bit) khoá 128 / 192 / 256 bit, MKV-256 (khối 256 bit) khoá 256 / 384 / 512 bit; R = 6 / 7 / 8 vòng (Bảng 1 của chuẩn) |
| Lệnh | `KEY` (lược đồ khoá), `ENC`, `DEC` (một khối), `CLEAR` (xoá khoá và dữ liệu) |
| Phát hiện lỗi | mỗi lệnh làm hai lần: `ENC` giải mã lại kết quả, `DEC` mã hoá lại, `KEY` chạy lược đồ khoá lần hai; parity mỗi byte khoá vòng; phiên bản lưu kèm bản bù; bộ đếm chu kỳ thứ hai; trạng thái FSM lạ. Lỗi → `FAULT`, không trả kết quả, xoá khoá |
| Kiến trúc | **một nửa vòng mỗi chu kỳ** trên datapath 256 bit dùng chung cho hai cỡ khối |
| Số chu kỳ (`CYCLES`) | `KEY` 16R + 2 (98 / 114 / 130), `ENC` / `DEC` 4R + 4 (28 / 32 / 36), `CLEAR` 33, đã gồm lượt kiểm tra; sau reset engine tự xoá RAM khoá vòng (32 chu kỳ `BUSY`) |
| Thông lượng lõi (50 MHz) | MKV-128/128: 128 bit / 28 chu kỳ ≈ 229 Mbit/s; MKV-256/256: ≈ 457 Mbit/s |
| Trên board (CPU + driver) | ECB 124 chu kỳ/khối (MKV-128, ~6,4 MB/s), 228 chu kỳ/khối (MKV-256, ~7,0 MB/s), như khi chưa có lượt kiểm tra; phần mềm trên Ibex: 23 600…104 000 chu kỳ/khối |
| Tài nguyên (KV260) | 9 591 LUT (168 LUTRAM), 2 261 FF trong `kv260_cam`, không BRAM / DSP; phần phát hiện lỗi chiếm ~2 100 LUT, 300 FF, 20 LUTRAM. Timing đạt ở 50 MHz: slack ≥ 2,8 ns trên mọi đường qua MKV (≥ 1,2 ns ở bản `kv260`). Cùng RTL, bản `kv260` ra 11 510 LUT: Vivado ánh xạ mạng 64 S-box khác nhau tuỳ thiết kế xung quanh |
| Thanh ghi | peripheral bus `0x4000_B000`, ngắt `irq_fast[10]` |

## Thuật toán

Tóm tắt điều 4 của chuẩn, với ký hiệu dùng trong RTL và mô hình.

**Trạng thái.** Khối `l` bit `X = x⁰‖x¹‖x²‖x³`, mỗi trạng thái con `xⁱ` là một
cột `t` byte (`t = 4` với MKV-128, `t = 8` với MKV-256). Byte được đánh số theo
thứ tự của chuẩn (thứ tự của các chuỗi hex ở Phụ lục A): cột `c` gồm các byte
`c·t … c·t + t − 1`.

**Các biến đổi.**

* `SubCells`: hộp thế 8 bit `s` cho từng byte (Bảng 1; nghịch đảo: Bảng 2).
* `MixWords`: mỗi cột nhân với ma trận `M4` (4 × 4) hoặc `M8` (8 × 8) trên
  GF(2⁸) với đa thức `x⁸ + x⁵ + x³ + x + 1` (`0x12B`).
* `XWords`: `yⁱ = XOR của ba cột còn lại` (tự nghịch đảo).

**Hàm vòng** với khoá vòng `K = K⁰‖K¹` (2l bit):

```
F(K, X)    = XWords(SubCells(MixWords(SubCells(X ⊕ K⁰)) ⊕ K¹))
invF(K, X) = invSubCells(invMixWords(invSubCells(XWords(X)) ⊕ K¹)) ⊕ K⁰
C = F(K_{R-1}, … F(K_0, P)) ⊕ K_post        P = invF(K_0, … invF(K_{R-1}, C ⊕ K_post))
```

**Lược đồ khoá.** Trạng thái khoá 2l bit `K_i = K_i^L‖K_i^R`, các từ `kⱼ` dài
`l/4` bit:

```
K_0 = k0 … k7                  (khoá 2l bit)
      k0 … k5 ‖ ~k2 ‖ ~k3      (khoá 3l/2 bit)
      k0 … k3 ‖ ~k0 … ~k3      (khoá l bit)
lần cập nhật i = 1 … R:
  K_i^L = F(0, F(c(2i),     K_{i-1}^R))
  K_i^R = K_i^L ⊕ F(0, F(c(2i − 1), K_{i-1}^L))       c(v) = ⟨v⟩_l ‖ 0^l
K_0 = K_0^L‖K_1^L,  K_i = K_i^R‖K_{i+1}^L,  K_post = K_R^R
```

Nói cách khác, dãy **khoá nửa vòng** `h[0..2R] = K_0^L, K_1^L, K_1^R, …,
K_R^L, K_R^R`: nửa vòng `s` của phép mã hoá dùng `h[s]`, `K_post = h[2R]`. Đây
cũng là thứ tự của RAM khoá vòng trong RTL và của dòng `K00 … K_post` ở Phụ lục A.

## Sai khác giữa văn bản dự thảo và véc tơ kiểm tra

Khi đối chiếu từng giá trị, văn bản dự thảo có **hai chỗ** mâu thuẫn với chính
các véc tơ kiểm tra ở Phụ lục A. Bow32 theo **véc tơ kiểm tra**, vì đó là kết quả
mà mọi cài đặt khác của chuẩn (cài đặt tham chiếu sinh ra các véc tơ) tạo ra:

1. **Ma trận M4 (điều 4.2.2.2).** Văn bản in `0x0C` ở hàng 2 cột 3 và hàng 3
   cột 0 (đánh số từ 0). Mọi véc tơ MKV-128 cần `0x0D`; giải hệ phương trình trên
   GF(2⁸) từ 84 cột (đầu vào, đầu ra) của bước MixWords ở Phụ lục A ra đúng
   một ma trận:

   ```
        01 02 01 03
   M4 = 03 07 01 04        (in trong dự thảo: 04 0B 03 0C / 0C 1E 06 14)
        04 0B 03 0D
        0D 1E 06 14
   ```

   Ma trận `M4⁻¹` in trong dự thảo đúng là nghịch đảo của ma trận này
   (`M4 · M4⁻¹ = I`), còn với `0x0C` thì không. M8 và M8⁻¹ đúng như in.
2. **Hằng số của lược đồ khoá (điều 4.6).** Văn bản viết `Const^Left_i =
   ⟨2i⟩_{2l}`, `Const^Right_i = ⟨2i+1⟩_{2l}` và dùng `Const_{i−1}` ở lần cập nhật
   `i`. Các véc tơ cần, ở lần cập nhật `i = 1…R`, hằng số `2i` cho nhánh tạo
   `K_i^L` (từ `K^R`) và `2i − 1` cho nhánh kia, đặt ở **nửa khoá đầu** của `F`:
   `c(v) = ⟨v⟩_l ‖ 0^l` (byte cuối của `K⁰` là `v`, `K¹ = 0`).

`tools/tests/test_mkv_model.py` giữ hai sai khác này thành test: `M4` in sai
không cho ra bước MixWords của A.1.1 và không là nghịch đảo của `M4⁻¹`; đọc
nguyên văn điều 4.6 thì sai ngay `K01` của cả 6 véc tơ.

## Kiến trúc RTL

| File | Nội dung |
|------|----------|
| `bow_mkv_tables_pkg.sv` | **sinh tự động** (`mkv_model.py tables`): S-box, S-box nghịch đảo (hàm `case`), M4, M4⁻¹, M8, M8⁻¹ |
| `bow_mkv_pkg.sv` | các lớp trên trạng thái 256 bit: `sub_cells`, `mix_words`, `inv_mix_words` (nhân GF(2⁸) với hằng → mạng XOR), `x_words`, `block_mask` |
| `bow_mkv_core.sv` | engine: FSM, datapath nửa vòng thuận / nghịch, lược đồ khoá, RAM khoá vòng |
| `bow_mkv.sv` | khối thanh ghi trên bus Bow32, giải mã lệnh, cờ trạng thái, ngắt |

**Hai cỡ khối trên một datapath.** Byte `b` của khối nằm ở `state[8b +: 8]`.
MKV-256 dùng 4 cột 64 bit, MKV-128 dùng 4 cột 32 bit ở 128 bit thấp (128 bit
cao luôn bằng 0). S-box dùng chung, chỉ MixWords (M8 hay M4) và XWords (cột 64
hay 32 bit) chọn theo cỡ khối.

**Một nửa vòng mỗi chu kỳ.** Hàm vòng tách thành hai nửa cùng dạng "cộng khoá →
SubCells → lớp tuyến tính": `M(S(x ⊕ K⁰))` rồi `XW(S(x ⊕ K¹))`. Phép giải mã là
ảnh gương: `S⁻¹(XW(x)) ⊕ K¹` rồi `S⁻¹(M⁻¹(x)) ⊕ K⁰`.

| Lệnh | Bước | Việc làm |
|------|------|----------|
| `ENC` | lúc nhận lệnh | `x ← DIN`, `in ← DIN`, `DIN ← 0` (DIN được chép: CPU ghi khối tiếp theo ngay được) |
| | `s = 0 … 2R−1` | `x ← L(S(x ⊕ h[s]))`, `L` = MixWords (s chẵn) / XWords (s lẻ) |
| | `s = 2R` | `x ← x ⊕ h[2R]` (K_post), giữ vào `DOUT` nhưng chưa cho đọc |
| | lượt 2 (2R + 1 chu kỳ) | giải mã `x` trên datapath nghịch như `DEC` |
| | `Check` | `x = in` và bộ đếm chu kỳ đúng: cho đọc `DOUT`, `DONE`; sai: `FAULT` |
| `DEC` | `s = 0` | `x ← DIN ⊕ h[2R]` (`in ← DIN`) |
| | `s = 1 … 2R` | `x ← S⁻¹(L⁻¹(x)) ⊕ h[2R − s]`, `L⁻¹` = XWords (s lẻ) / invMixWords (s chẵn); bước cuối giữ vào `DOUT` |
| | lượt 2, `Check` | mã hoá lại `x` trên datapath thuận, so với `in` như trên |
| `KEY` | lúc nhận lệnh | `KL, KR ← K_0`, `h[0] ← K_0^L`, `DOUT ← 0` |
| | mỗi lần cập nhật (8 chu kỳ) | 4 nửa vòng thuận trên `KR` với khoá `c(2i), 0, 0, 0` → `K_i^L` (ghi tạm vào `KR`, `h[2i−1]`); 4 nửa vòng trên `KL` với `c(2i−1)` → `B`; `KL ← K_i^L`, `KR ← K_i^L ⊕ B` (`h[2i]`). 6 chu kỳ không ghi RAM: `h[2R+1…31] ← 0` (khoá vòng của khoá dài hơn trước đó) |
| | lượt 2 (8R chu kỳ) | chạy lại từ `K_0` (đọc lại `KEY`), không ghi RAM mà so từng khoá nửa vòng với RAM |
| | `Check` | so `h[0]`, bộ đếm chu kỳ; đúng: `KEY_VALID`, `KEY ← 0`; sai: `FAULT` |
| | sau đó | engine rảnh luôn giữ `KL, KR, x, in` = 0: một chu kỳ sau lệnh chúng đã về 0 |

**Phát hiện lỗi.** Lỗi tiêm vào phần cứng (glitch xung clock / điện áp, laser)
làm sai một bước tính, và bản mã sai là thứ phân tích lỗi cần. Vì vậy không kết
quả nào ra khỏi IP mà chưa được làm lại theo cách khác và đối chiếu:

- `ENC` được kiểm tra bằng cách giải mã kết quả trên datapath **nghịch**, `DEC`
  bằng cách mã hoá lại trên datapath **thuận**: lượt hai phải trả lại đúng đầu
  vào (giữ trong `in`). Hai lượt dùng hai mạch khác nhau, nên cả lỗi tạm thời lẫn
  lỗi cố định ở một datapath đều lộ ra.
- `KEY` chạy lược đồ khoá hai lần từ khoá chính; lần hai so từng khoá nửa vòng
  với RAM.
- Mỗi byte khoá vòng trong RAM có một bit parity, kiểm tra ở mọi lần đọc của
  `ENC`/`DEC`: khoá vòng bị đổi trong RAM cho cùng một kết quả sai ở cả hai lượt,
  nên phép so ở trên không bắt được, parity thì bắt.
- Những thứ hai lượt dùng chung cũng được bảo vệ: phiên bản (R, cỡ khối) lưu cả
  giá trị lẫn bản bù; một bộ đếm thứ hai, nạp từ bản bù, phải đếm đúng số chu kỳ
  của lệnh (bỏ bớt vòng, kết thúc sớm đều lộ); trạng thái FSM ngoài danh sách
  hay quay về `Idle` giữa chừng là lỗi; `ENC`/`DEC` khi engine không có lược đồ
  khoá đã kiểm tra là lỗi (dù `KEY_VALID` của khối thanh ghi nói có).

Khi phát hiện lỗi, engine không trả kết quả (`DOUT` đọc ra 0), báo `fault_o`,
rồi xoá RAM khoá vòng và mọi thanh ghi (32 chu kỳ). Khối thanh ghi đặt `FAULT`,
xoá `KEY`, `DIN`, `KEY_VALID`; phần mềm phải `CLEAR` và nạp khoá lại.

**RAM khoá vòng.** 32 × (256 + 32 parity) bit, ghi đồng bộ, đọc bất đồng bộ
(Vivado suy ra LUTRAM). Mã hoá đọc `h[s]`, giải mã đọc `h[2R − s]`: không cần tính lại
lược đồ khoá theo chiều ngược. LUTRAM không có reset, nên sau mỗi reset FSM bắt
đầu ở `Clear`: 32 chu kỳ ghi 0 (`BUSY` = 1, không đặt `DONE`, `CYCLES` giữ 0).

**Đường dài nhất** (50 MHz, 20 ns): đọc RAM → XOR → S-box → M8 → mux → thanh
ghi, ngắn hơn đường qua bus (Ibex → crossbar → ghi thanh ghi MKV: slack +2,8 ns
ở `kv260_cam`, +1,2 ns ở `kv260`, chủ yếu là trễ dây). Muốn nhanh hơn có thể làm cả vòng mỗi chu kỳ (gấp đôi S-box).

## Bản đồ thanh ghi (`0x4000_B000`)

| Offset | Tên | Truy cập | Mô tả |
|-------:|-----|:--:|-------|
| 0x000 | `ID` | R | `0x4D4B5601` ("MKV", phiên bản 1) |
| 0x004 | `INFO` | R | [0] có MKV-128, [1] có MKV-256, [2] có phát hiện lỗi, [15:8] số chu kỳ mỗi vòng của `ENC`/`DEC` (4: 2 + lượt kiểm tra) |
| 0x008 | `CTRL` | RW | [0] `BLOCK` (0 MKV-128, 1 MKV-256), [2:1] `KLEN` (0: k = l, 1: k = 3l/2, 2: k = 2l, 3: không hợp lệ) — phiên bản cho lệnh `KEY` kế tiếp |
| 0x00C | `CMD` | W | mỗi lần ghi **một** bit: [0] `KEY`, [1] `ENC`, [2] `DEC`, [3] `CLEAR`; ghi 0 không làm gì |
| 0x010 | `STATUS` | R/W1C | [0] `BUSY`, [1] `KEY_VALID`, [2] `DONE` (W1C), [3] `ERR` (W1C), [4] `WIDE`, [5] `FAULT` (W1C), [11:8] `ROUNDS` — `WIDE`/`ROUNDS`: phiên bản của lược đồ khoá đang có (0 nếu chưa có) |
| 0x014 | `IRQ_EN` | RW | [2] ngắt khi `DONE`, [3] ngắt khi `ERR`, [5] ngắt khi `FAULT` |
| 0x018 | `CYCLES` | R | số chu kỳ của lệnh cuối, từ lúc ghi `CMD` tới khi có kết quả |
| 0x040–0x07C | `KEY[0..15]` | W | khoá chính, byte `b` = `KEY[b/4]` bit `8·(b%4)`; đọc ra 0; về 0 khi lệnh `KEY` xong (lượt hai đọc lại khoá) |
| 0x080–0x09C | `DIN[0..7]` | RW | khối vào, cùng thứ tự byte (MKV-128: `DIN[0..3]`); về 0 khi `ENC`/`DEC` lấy khối |
| 0x0C0–0x0DC | `DOUT[0..7]` | R | khối ra (MKV-128: `DOUT[4..7]` = 0); về 0 khi `KEY`; đọc ra 0 khi chưa có kết quả đã kiểm tra |

Thứ tự byte: word thanh ghi là little-endian của chuỗi byte của chuẩn, nên trên
Ibex (little-endian) một mảng `uint8_t` căn 4 byte chép thẳng bằng `lw`/`sw`.
Mọi thanh ghi nhận byte enable (`sb`, `sh`).

**Lệnh bị từ chối** (đặt `ERR`, không chạy): `ENC`/`DEC` khi `KEY_VALID = 0`,
`KEY` khi `KLEN = 3` hoặc khi chưa ghi đủ k/32 từ khoá của phiên bản trong `CTRL`
kể từ lệnh `KEY`/`CLEAR` (hay reset) trước, `CMD` có nhiều hơn một bit. Một từ
tính là đã ghi khi có ghi vào nó, kể cả chỉ một byte; byte không ghi lại là 0,
không bao giờ là byte của khoá cũ. `KEY_VALID` = 1 sau `KEY`, về 0 khi ghi
`KEY[i]`, khi đổi giá trị `CTRL`, khi `CLEAR`. `CLEAR` xoá `KEY`, `DIN`, `DOUT`,
trạng thái và cả 32 dòng RAM khoá vòng.

**`FAULT`** (W1C): engine phát hiện lỗi, không trả kết quả, đã xoá khoá vòng,
`KEY`, `DIN`, `DOUT`, `KEY_VALID`. Lệnh bị lỗi không đặt `DONE`. Muốn dùng lại:
`CLEAR`, xoá `FAULT`, nạp khoá lại.

Vì `KEY` xoá thanh ghi khoá, mỗi lần chạy lược đồ khoá phải ghi lại cả khoá
(`bow_mkv_set_key` vẫn làm vậy). Đổi `CTRL` rồi chạy `KEY` mà không ghi khoá
mới sẽ bị từ chối, không lặng lẽ dùng khoá toàn 0.

**Chờ trên bus thay vì hỏi vòng.** Khi một lệnh đang chạy (`BUSY`), ghi
`CTRL` / `CMD` / `KEY` và đọc `DOUT` bị giữ (`gnt = 0`, [../bus.md](../bus.md))
tới khi xong. Vì vậy phần mềm ghi `CMD` rồi đọc `DOUT` ngay, không cần vòng hỏi
`BUSY`; ghi `CMD` ngay sau `KEY` sẽ tự chờ lược đồ khoá. Đọc `STATUS`/`ID` và ghi
`DIN`/`STATUS`/`IRQ_EN` không bao giờ bị giữ.

## Lập trình

```c
#include "bow32.h"

static const uint8_t key[32] = {...}, pt[16] = {...};
uint8_t ct[16], back[16];

if (!bow_mkv_set_key(128, 256, key)) { /* phiên bản không có trong chuẩn, hay FAULT */ }
if (!bow_mkv_encrypt(pt, ct)) {          /* CYCLES = 4R + 4 = 36 */
  /* FAULT: kết quả đã bị huỷ (ct = 0), khoá đã bị xoá */
  bow_mkv_clear();                       /* xoá cả FAULT */
  bow_mkv_set_key(128, 256, key);
}
bow_mkv_decrypt(ct, back);
bow_mkv_ecb(false, buf, buf, nblocks);   /* nhiều khối, ghi DIN khối sau khi IP đang chạy */
bow_mkv_clear();                         /* xoá khoá */
```

Không dùng driver: `CTRL`, `KEY[i]`, `CMD = KEY`; rồi mỗi khối `DIN[i]`,
`CMD = ENC`, đọc `DOUT[i]`.

## Kiểm chứng

Bốn tầng, mỗi tầng dựa trên tầng trước:

1. **Mô hình ↔ PDF.** `tools/mkv/extract_vectors.py` trích từ PDF (`pdftotext`)
   hai bảng S-box, bốn ma trận và 6 véc tơ của Phụ lục A **với mọi giá trị
   trung gian** (khoá `K00…K_post`, 6 bước của mỗi vòng, bản mã) vào
   `tools/mkv/tcvn_mkv_vectors.json`. `mkv_model.py selftest` và 21 unit test
   (`make test-tools`) kiểm tra mô hình khớp từng giá trị (6 phiên bản, 252 trạng
   thái, 90 khoá nửa vòng), giải mã, hai sai khác ở trên, file sinh ra còn mới.
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
   **Tiêm lỗi** (`force`/`release` một thanh ghi trong một chu kỳ, hay ghi thẳng
   vào RAM khoá vòng), mỗi lỗi phải cho `FAULT`, không `DONE`, `DOUT` = 0, khoá
   và thanh ghi về 0, rồi IP chạy lại đúng sau `KEY` mới:
   - trạng thái trong lượt một của `ENC`, trong lượt kiểm tra của `DEC`;
   - một bit khoá vòng trong RAM;
   - bộ đếm bước (bỏ nửa vòng), bộ đếm chu kỳ;
   - số vòng khi rảnh, trạng thái FSM lạ, FSM về `Idle` giữa `ENC`;
   - trạng thái trong lượt một của `KEY`;
   - `KEY_VALID` của khối thanh ghi bị bật khi engine không có khoá.
   Thêm: ngắt `FAULT`, `DOUT` đọc ra 0 khi không có kết quả đã kiểm tra.
   4 seed: ~510 phép toán, ~7 700 trạng thái, 264 lược đồ khoá, 40 lỗi phát
   hiện; thử thêm `make run SEED=99 COUNT=600` (1 231 phép toán). Đổi `M4` về
   `0x0C` hay lệch hằng số lược đồ khoá thì test hỏng ngay ở véc tơ đầu.
   Mutation (21 bản RTL, mỗi bản bỏ một cơ chế) đều làm test hỏng: giữ khoá
   trong `KEY`, nhận `KEY` thiếu từ, giữ `DIN`/`DOUT`, giữ khoá vòng của khoá dài
   trước, giữ `K_R`, không xoá RAM sau reset, và tắt từng phép kiểm tra (parity,
   so kết quả, so lược đồ khoá, bộ đếm chu kỳ, bỏ qua `Check`, phiên bản, trạng
   thái, lệnh bị mất, `ENC` không khoá, che `DOUT`, xoá khi lỗi).
3. **Hệ thống** (`make run TEST=mkv`): firmware `sw/apps/mkv` trên Ibex trong SoC
   đầy đủ chạy `test quick` (13 nhóm kiểm tra, xem dưới) rồi `key`/`enc`/`dec`
   qua shell, so với giá trị của mô hình.
4. **Trên board** ([../mkv_kv260.md](../mkv_kv260.md)): `test` (đủ, 20 khoá
   ngẫu nhiên mỗi phiên bản), `tools/bow32_mkv.py kat` (bản mã so với giá trị in
   trong PDF) và `verify` (khoá/khối ngẫu nhiên từ PC, so với mô hình Python —
   độc lập với phần mềm chạy trên board).

`test` của ứng dụng: (1) ID/INFO, (2) MKV phần mềm (`mkv_sw.c`, viết theo chuẩn)
khớp Phụ lục A cả khoá vòng, (3)(4) IP mã hoá / giải mã 6 véc tơ + `STATUS`,
`CYCLES`, (5) IP ↔ phần mềm trên khoá/khối ngẫu nhiên: E, D, D(E(x)) = x, (6)
ECB (ghi `DIN` khi đang chạy, buffer lệch, tại chỗ), (7) lệnh lỗi, (8)
`KEY_VALID`, (9) `CLEAR`, (10) ngắt `DONE`/`ERR` tới `irq_fast[10]` (đọc `mip`),
(11) stall bus (`CMD` trong lúc `KEY`, `DOUT` trong lúc `ENC`), (12) xoá: `KEY`
không có khoá mới bị từ chối, khoá ghi bằng `sb` thiếu byte 0 cho đúng bản mã
của khoá có byte 0 = 0 (so với MKV phần mềm), `DIN` về 0 khi `DEC` bắt đầu,
`DOUT` về 0 sau `KEY`, (13) `INFO` báo có phát hiện lỗi và không có `FAULT` nào
trong cả self-test (không báo nhầm). Lỗi thật thì phần mềm không tự tạo được:
phần phát hiện được kiểm chứng bằng tiêm lỗi trong mô phỏng (tầng 2).

## Bảo mật

Những gì IP bảo đảm:

- Thời gian mỗi lệnh cố định, không phụ thuộc dữ liệu hay khoá (`CYCLES`).
- Phát hiện lỗi tiêm vào (mục "Phát hiện lỗi" ở trên): không kết quả nào ra
  khỏi IP mà chưa được làm lại bằng mạch khác và đối chiếu; khoá vòng có parity;
  phiên bản, bộ đếm, FSM được kiểm tra. Lỗi thì không ra gì và khoá bị xoá.
- `KEY` chỉ ghi, RAM khoá vòng không đọc được qua bus, `DOUT` không đọc được
  giữa chừng (bus chờ), `CTRL`/`KEY` không đổi được khi đang chạy.
- Khoá chỉ nằm ở nơi cần, trong thời gian cần. Lệnh `KEY` lấy khoá khỏi `KEY`
  và xoá về 0, nên ghi đè một phần khoá rồi chạy lại `KEY` không bao giờ trộn
  byte mới với byte của khoá đã dùng. Không làm vậy thì ai ghi được `KEY` và ra
  lệnh được, dù không đọc được khoá, có thể dò khoá từng byte bằng cách so bản
  mã. (Khoá đã ghi mà chưa chạy `KEY` thì vẫn bị master khác chen vào được: đó
  là việc của kiểm soát truy cập, xem dưới.)
  `KEY` cũng cần đủ từ khoá mới, nên đổi phiên bản trong `CTRL` không dùng lại
  được khoá bí mật cho phiên bản khác, và không lặng lẽ chạy khoá toàn 0.
- Engine giữ `K_R` và trạng thái bằng 0 khi rảnh (một chu kỳ sau lệnh), xoá
  khoá vòng của khoá dài hơn trước đó, và xoá cả RAM sau mỗi reset. UpdateKS đảo
  ngược được (`F` là hoán vị khi khoá cố định), nên một cặp `K_i^L`, `K_i^R` bất
  kỳ đã đủ suy ra khoá chính: các bản sao này quý ngang khoá chính.
- `DIN` về 0 khi lệnh lấy khối, `DOUT` về 0 khi có khoá mới; `CLEAR` xoá hết.
  Sau phiên làm việc nên gọi `bow_mkv_clear()`.

Những gì IP **chưa** có (xem xét theo mô hình đe doạ của sản phẩm):

- Chống tấn công kênh kề (công suất, điện từ): datapath không masking, không
  hiding. Lượt kiểm tra còn làm mỗi khoá được dùng gấp đôi số lần.
- Giới hạn của phát hiện lỗi:
  - Lỗi giống hệt nhau ở cả hai lượt thì không lộ. Hai lượt chạy ở hai thời
    điểm khác nhau, trên hai datapath khác nhau, nên khó làm vậy nhưng không
    phải không thể.
  - Lỗi ngay trong mạch so sánh, cờ kết quả hay phần đếm có thể lọt.
  - Parity không thấy số bit lỗi chẵn trong cùng một byte khoá vòng.
  - Lỗi ở `DIN`/`KEY` trước khi engine lấy là lỗi của đầu vào, không phải của
    phép tính.
  - Không có cảm biến glitch / điện áp ở mức SoC.
- Kiểm soát truy cập: mọi master tới được bus (CPU, DMA) đều dùng được khoá đã
  nạp để mã / giải mã, và thay được khoá. Bow32 chưa có PMP. Nếu cần tách quyền:
  bit khoá `KEY_LOCK`, cờ chỉ mã hoá / chỉ giải mã, PMP, chặn DMA khỏi vùng
  ngoại vi.
- Khoá vẫn đi qua phần mềm (RAM, thanh ghi CPU): phần mềm phải tự xoá bộ đệm
  khoá sau khi dùng.

Chế độ hoạt động (CBC, CTR, GCM…) do phần mềm làm trên lệnh `ENC`/`DEC`;
`bow_mkv_ecb` chỉ là ECB (khối rõ trùng → khối mã trùng), không toàn vẹn.

## Bài tập mở rộng

- Cả vòng mỗi chu kỳ (2 lớp S-box): 4R + 4 → 2R + 4 chu kỳ.
- Tham số tắt lượt kiểm tra (2R + 2 chu kỳ) cho thiết kế không cần chống tiêm lỗi.
- Bản nhỏ: một cột mỗi chu kỳ (S-box và MixWords chia 4).
- Chế độ CTR / CBC trong phần cứng, nạp dữ liệu bằng DMA (kênh 1 M2M) để không
  tốn CPU.
- Tham số `Block256 = 0` để bỏ phần MKV-256 khi chỉ cần MKV-128.
