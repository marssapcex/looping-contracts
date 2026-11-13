# LoanVault verification rig (Certora + local EVM fuzz)

Đây là bộ **spec + harness + bằng chứng chạy được** cho `LoanVault` (Axcess Protocol).
Mục tiêu không phải "chạy cho ra SUCCESS" mà là: mỗi invariant trong `certora/specs/`
phải **đúng thật** — đã được kiểm chứng trên bytecode thật trước khi viết CVL.

## TL;DR — chạy cái gì

```bash
cd verification
npm install                 # solc 0.8.35 + OZ 5.6.1 + @ethereumjs/vm

node scripts/compile.js     # thay cho `forge build` (không cần Foundry/RPC)
node scripts/audit.js       # 142 assertions trên bytecode thật
node scripts/audit2.js      #  42 assertions: kịch bản adversarial
node scripts/audit3.js      # probe các invariant "không chắc đúng"

certoraRun certora/conf/accounting.conf    # cần CERTORAKEY
certoraRun certora/conf/withdrawal.conf
certoraRun certora/conf/winddown.conf
certoraRun certora/conf/transitions.conf
certoraRun certora/conf/params.conf        # PATH B: source production, không harness
```

## Vì sao phải có `compile.js` (lỗi `forge build` của bạn)

`forge build` fail vì **thiếu dependency**, không phải vì lỗi Solidity:

```
Unable to resolve imports: "./interfaces/IRoleManager.sol", "@openzeppelin/contracts/..."
```

Fix đúng thứ tự:

1. `npm i @openzeppelin/contracts@5.6.1 @openzeppelin/contracts-upgradeable@5.6.1`
   (`LoanVaultBase` cần bản **upgradeable**; bản `contracts` thường không đủ).
2. `src/DualPausableUpgradeable.sol` phải tồn tại — nó bị thiếu trong bản dump.
3. `src/interfaces/{ILoanVault,IRoleManager,IVaultLenderRegistry,IVaultFactory}.sol`
   phải nằm đúng thư mục `src/interfaces/`.
4. Pragma của project là **0.8.35** → `--solc solc8.35`, không phải `solc8.24`.

Sau đó `certoraRun` cần thêm `packages` để resolve `@openzeppelin/*` — đã khai báo
trong các file `.conf`.

## Cấu trúc

```
src/                     # LoanVault + libs, dựng lại từ source bạn dán + mock interfaces
certora/harness/
  LoanVaultHarness.sol   # subclass, override ĐÚNG 4 điểm chạm external
  Mocks.sol              # ERC20 / RoleManager / LenderRegistry cụ thể
certora/specs/
  LoanVaultAccounting.spec    # solvency, cash conservation, fee/rate, capacity, share price
  LoanVaultWithdrawal.spec    # escrow, funding, reservation isolation, queue
  LoanVaultWindDown.spec      # snapshot, entitlement, double-claim, residual/fee sweep
  LoanVaultTransitions.spec   # deposit/mint price, accrual vs penalty, rate schedule, gates
  LoanVaultParams.spec        # PATH B: parametric trên source production
scripts/
  compile.js  evm.js  setup.js  audit.js  audit2.js  audit3.js
  run-audit.sh  run-certora.sh
docs/FINDINGS.md          # invariant bị REFUTED + finding hành vi (đọc cái này trước)
```

## Hai đường kiểm chứng (và giới hạn của từng đường)

**PATH A — harness** (`accounting/withdrawal/winddown/transitions.conf`).
`LoanVault` đọc token và 2 registry qua external call. Prover havoc mọi external
call ⇒ `_cashForClaims()`, delinquency, funding, recovery pool thành biến tự do ⇒
invariant về tiền **vô nghĩa** (đúng hoặc sai đều không nói gì). Harness thay 4
điểm chạm đó bằng storage cụ thể (`ghost_held`, `ghost_denied`), **không** đổi
logic kế toán. Đây là nơi chứng minh được "reserved luôn được backing bằng cash".

**PATH B — production** (`params.conf`).
Giữ nguyên `src/LoanVault.sol`, dùng CVL `methods` summary cho token/registry, và
dùng **parametric rules** (`method f`) — quan trọng vì vault là beacon-proxy
upgradeable: rule phủ cả hàm mà implementation tương lai thêm vào.
Giới hạn: ERC-20 bị summary có thể "nói dối", nên PATH B chỉ chứng minh các
thuộc tính **không phụ thuộc tính trung thực của token**.

## Bẫy đã gặp (và cách tránh) — chi tiết trong docs/FINDINGS.md

- `exposedAmount() <= vaultCapacity()` **sai**: capacity chặn deposit, không chặn accrual.
- `totalSupply()==0 => totalAssets()==0` **sai**: còn 1 wei (virtual asset ERC-4626).
- `dueUnprocessedAssets() <= totalAssets()` **sai sau cutoff** (`exposedAmount` bị ép 0).
- `maturedRedeemShares()==0 => penaltyActiveSince()==0` **sai** sau `claimRecovery`.
- `reservedAssets() <= totalAssets()` **sai**: pool release reservation lúc funding.
- `getEpochWithdrawalRequest(e).third` **không phải CVL**: hàm trả struct.
- `claimableRedeemRequest` trả **shares**, không phải assets.
- Hook ghost ban đầu của tôi dùng `escrowShares@new` (giá trị *sau* khi ghi) → sai; đã bỏ ghost không cần thiết.

## Trạng thái

- `node scripts/audit.js`: **142 PASS / 0 FAIL**
- `node scripts/audit2.js`: **44 PASS / 0 FAIL**
- Spec: đã viết xong 5 file; **chưa chạy Certora** ở môi trường này (không có
  `CERTORAKEY`, không ra được `binaries.soliditylang.org` / release assets). Các
  con số PASS ở trên là EVM thật, **không phải** kết quả Prover — đừng trộn hai thứ.
