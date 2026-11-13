# Lệnh cài đặt — copy/paste

Máy bạn: macOS, Homebrew + conda (`/opt/homebrew/Caskroom/miniconda/...`), project ở `~/my-poc`.

## 0. Vào project

```bash
cd ~/my-poc
```

## 1. Sửa lỗi `forge build` (thiếu dependency — KHÔNG phải lỗi Solidity)

```bash
# 1a. OpenZeppelin: cần CẢ HAI bản. LoanVaultBase import bản *-upgradeable,
#     nếu chỉ cài bản thường thì vẫn fail y như cũ.
npm install @openzeppelin/contracts@5.6.1 @openzeppelin/contracts-upgradeable@5.6.1

# 1b. Foundry nếu chưa có
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc || source ~/.zshrc
foundryup

# 1c. Build
forge build
```

Nếu vẫn báo `Source "src/DualPausableUpgradeable.sol" not found` → file này **thiếu trong bản dump**,
phải thêm vào `src/`. Bản dựng lại nằm ở `verification/src/DualPausableUpgradeable.sol`, copy sang:

```bash
cp verification/src/DualPausableUpgradeable.sol ~/my-poc/src/
```

Nếu báo `Source "src/interfaces/IRoleManager.sol" not found` → thiếu file interface:

```bash
mkdir -p ~/my-poc/src/interfaces
cp verification/src/interfaces/*.sol ~/my-poc/src/interfaces/
```

## 2. Cài Certora Prover

```bash
python3 -m venv ~/certora-env
source ~/certora-env/bin/activate
pip install certora-cli
certoraRun --version          # phải in ra 8.x
```

Nếu `pip install` lỗi vì conda python 3.14:

```bash
# dùng python 3.12 của homebrew thay cho conda
brew install python@3.12
python3.12 -m venv ~/certora-env
source ~/certora-env/bin/activate
pip install certora-cli
```

## 3. API key

```bash
export CERTORAKEY=...        # key của bạn; đừng commit vào repo
```

Kiểm tra key + mạng (Certora cần ra được 2 host này):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://prover.certora.com
curl -sS -o /dev/null -w "%{http_code}\n" https://binaries.soliditylang.org/linux-amd64/list.json
```

Nếu host thứ hai trả lỗi/timeout → `certoraRun` sẽ không tải được solc 0.8.35. Cách chữa:
tải solc thủ công rồi trỏ vào đường dẫn cục bộ (mục 4).

## 4. Solc 0.8.35 (pragma của project là 0.8.35, KHÔNG phải 0.8.24)

```bash
# macOS: dùng solc-select
pip install solc-select
solc-select install 0.8.35
solc-select use 0.8.35
solc --version
```

Nếu `solc-select install` cũng bị chặn mạng, tải tay:

```bash
mkdir -p ~/.svm/0.8.35
curl -L -o ~/.svm/0.8.35/solc-0.8.35 \
  https://github.com/ethereum/solidity/releases/download/v0.8.35/solc-macos
chmod +x ~/.svm/0.8.35/solc-0.8.35
```

Rồi trong file `.conf` đổi `"solc": "solc8.35"` thành:

```json
"solc": "/Users/haanhtuanhuy/.svm/0.8.35/solc-0.8.35"
```

## 5. Build cho Certora (không cần Foundry)

```bash
cd verification
npm install                    # solc 0.8.35 + OZ 5.6.1 + @ethereumjs/vm
node scripts/compile.js        # → "OK: compiled 13 sources -> 33 contracts"
```

## 6. Kiểm tra môi trường trước khi đốt credit Prover

```bash
node scripts/run-audit.sh      # 173 + 44 assertion trên bytecode thật, phải 0 FAIL
```
