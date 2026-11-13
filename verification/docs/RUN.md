# Lệnh chạy — copy/paste

Tất cả chạy từ `verification/` (nơi có `certora/` và `node_modules/`).

## 0. Kiểm tra trước (miễn phí, không tốn credit)

```bash
cd verification
node scripts/compile.js        # bytecode phải compile được
node scripts/run-audit.sh      # 187 assertion trên EVM thật
```

## 1. Chạy từng spec

```bash
export CERTORAKEY=...

# conservation laws (mạnh nhất về mặt "mất tiền")
certoraRun certora/conf/ghost.conf

# solvency / fee / share price
certoraRun certora/conf/accounting.conf

# escrow → funding → claim, reservation isolation
certoraRun certora/conf/withdrawal.conf

# snapshot, entitlement, double-claim, residual sweep
certoraRun certora/conf/winddown.conf

# deposit/mint price, accrual vs penalty, rate schedule, gates
certoraRun certora/conf/transitions.conf

# parametric trên SOURCE PRODUCTION (không harness)
certoraRun certora/conf/params.conf
```

## 2. Chạy tất cả

```bash
./scripts/run-certora.sh
```

## 3. Chạy 1 rule cụ thể (nhanh, ít credit)

```bash
certoraRun certora/conf/ghost.conf --rule fundingIsTheOnlyBurnPath
certoraRun certora/conf/withdrawal.conf --rule fundingIsExact
certoraRun certora/conf/ghost.conf --rule supplyIsClosed
```

## 4. Tăng độ sâu khi rule ra TIMEOUT

```bash
certoraRun certora/conf/ghost.conf \
  --loop_iter 6 \
  --optimistic_loop true \
  --smt_timeout 1800 \
  --rule_sanity basic
```

`--rule_sanity basic` là bắt buộc trên mọi lần chạy: nó cảnh báo invariant
**vacuous** (không có trạng thái nào chạm tới). Spec này đã bị làm sạch để
không còn tautology, nhưng vẫn phải bật để bắt lần hồi quy.

## 5. Đọc kết quả

| Trạng thái | Nghĩa | Hành động |
|---|---|---|
| `VERIFIED` | không có counterexample trong giới hạn `loop_iter` | tăng `loop_iter` cho rule quan trọng trước khi tin |
| `VIOLATED` | có trace phản ví dụ | mở **Call Trace**, xem `msg.sender`, `block.timestamp`, giá trị storage |
| `TIMEOUT` | không kết luận | tăng `smt_timeout` / `loop_iter`, hoặc tách rule |
| `ERROR` | sai CVL hoặc sai đường dẫn | đọc message, thường là hàm chưa khai báo trong `methods {}` |

## 6. Nếu gặp các lỗi CVL hay gặp

**`Function X is not declared`** → hàm đó chưa có trong `methods { }`.
Thêm đúng chữ ký, ví dụ `function epochShares(uint256) external returns (uint256) envfree;`

**`Cannot resolve tuple`** → hàm trả struct/tuple như `getEpochWithdrawalRequest` hay
`scheduledInterestRate`. Dùng các getter phụ trong harness (`epochShares`,
`epochFunded`, `epochFundedAssets`) thay vì destructure.

**`Rule is vacuously true`** → precondition `require` quá mạnh. Đây là lỗi spec,
không phải thành tích. Siết lại `require` hoặc bỏ.

**`Could not resolve import @openzeppelin/...`** → thiếu `packages` trong `.conf`:

```json
"packages": [{ "path": "node_modules/@openzeppelin/contracts", "type": "npm" }]
```

## 7. Chạy lại đúng 1 rule đang VIOLATED để lấy trace gọn

```bash
certoraRun certora/conf/ghost.conf --rule <tên_rule> --dump_difficulty_stats
```

Report HTML mở tự động; trace nằm ở tab **Rule Report → Call Trace**.
