# Codespaces / máy mới — 3 lệnh

Repo: https://github.com/marssapcex/looping-contracts

## Lỗi hay gặp (đọc trước)

| Lỗi | Nguyên nhân thật |
|---|---|
| `cd: looping-contracts/verification: No such file` | Mày **đã ở trong** repo rồi. Dùng `cd verification` |
| `Cannot find module '/workspaces/looping-contracts/scripts/compile.js'` | `npm install` chạy ở **root** (package.json HyperLend), không phải `verification/` |
| `Cannot find module 'solc'` (khi chạy `node scripts/compile.js`) | chưa `npm install` **trong `verification/`** |
| `read_from_conf_file: certora/conf/ghost.conf: not found` | đang đứng sai thư mục, không phải thiếu file |
| `cd: /home/codespace/looping-contracts/verification` | codespace của mày ở `/workspaces/...`, không phải `/home/codespace/...` |
| syntax error near `(` | copy dính chữ `→ ...` hoặc 2 lệnh bị nối |

## Cài 1 lần

```bash
# 1. lấy code mới nhất
cd /workspaces/looping-contracts
git pull origin master

# 2. node deps — PHẢI trong verification/
bash verification/scripts/bootstrap.sh
```

`bootstrap.sh` tự `cd` vào `verification/`, cài `node_modules`, compile, chạy 217 assertion.
Kết quả đúng phải là:

```
OK: compiled 13 sources -> 33 contracts (0.47 MB)
=== 173 PASS / 0 FAIL / 4 NOTE ===
=== 44 PASS / 0 FAIL / 4 NOTE ===
GHOST RULES VALIDATED
```

## Certora (1 lần)

```bash
python3 -m venv ~/certora-env
source ~/certora-env/bin/activate
pip install certora-cli solc-select
solc-select install 0.8.35 && solc-select use 0.8.35
export CERTORAKEY=...          # thêm vào ~/.bashrc nếu muốn giữ
certoraRun --version
python3 -m certora_cli.CertoraProver --version 2>/dev/null || true
```

Python 3.14 trong codespace đã cài được `certora-cli 8.20.3` — không cần hạ version.

## Chạy Prover

```bash
cd /workspaces/looping-contracts
bash verification/scripts/certora-all.sh              # tất cả 6 spec
bash verification/scripts/certora-all.sh ghost        # 1 spec
bash verification/scripts/certora-all.sh ghost withdrawal
```

Script tự check `certoraRun` + `CERTORAKEY` + `node_modules` trước khi đốt credit.

## Lỗi `Cannot run solc8.35` (hay gặp nhất)

```
attribute/flag 'solc': Cannot run solc8.35
```

Không phải mày thiếu solc. Certora đọc giá trị `"solc": "solc8.35"` trong conf rồi gọi
`shutil.which("solc8.35")` — tức là nó tìm **một file thực thi tên đúng là `solc8.35`**.
`solc-select` chỉ cài binary tên `solc`, nên `solc-select install 0.8.35` xong vẫn fail.

`certora-all.sh` giờ tự tạo shim. Nếu muốn làm tay:

```bash
mkdir -p ~/.certora-bin
ln -sf "$(command -v solc)" ~/.certora-bin/solc8.35
export PATH="$HOME/.certora-bin:$PATH"
solc8.35 --version        # phải ra 0.8.35
```

Hoặc bỏ hẳn `solc` khỏi conf và để nó dùng `solc` trên PATH:

```json
"solc": "/home/codespace/certora-env/bin/solc"
```

## Lỗi Java

```
Cannot run local checks because of missing a suitable java installation
```

certoraRun typecheck CVL ở máy trước khi upload. Không có JDK thì nó dừng. Hai cách:

```bash
sudo apt-get install -y openjdk-21-jre-headless     # codespace / ubuntu
pip install jdk4py                                  # không cần sudo, JRE nằm trong pip package
```

Với `jdk4py`, script tự set `JAVA_HOME` và `PATH`.

## Nếu Prover báo lỗi cấu hình

| Lỗi | Nguyên nhân |
|---|---|
| `cannot use 'collections.OrderedDict' as a set element` | `packages` phải là **list string** `"tên=đường/dẫn"`, không phải object `{"path":..,"type":..}`. Đã sửa trong mọi conf. |
| `Stack too deep ... LoanVaultDeposits.sol:407` | conf phải có `"solc_via_ir": true`. Đã bật. |
| `attribute/flag 'solc': Cannot run solc8.35` | cần file tên đúng `solc8.35` trên `PATH` (không phải `solc`). |
| `Cannot run local checks because of missing a suitable java installation` | `apt install openjdk-21-jre-headless`, hoặc `pip install jdk4py` rồi trỏ `JAVA_HOME`. |
| `code size to deposit exceeds maximum code size` (chỉ ở `audit.js`) | harness 24KB; local rig compile legacy (đủ), Prover compile viaIR (không deploy nên không sao). |

## Vì sao không cần `forge build`

`verification/` có bản source đầy đủ để Prover dùng (`verification/src/`, 13 file, đã gồm
`DualPausableUpgradeable.sol` và `interfaces/` mà bản dump ban đầu thiếu).
Prover chỉ cần solc + deps npm, không cần Foundry.

Nếu vẫn muốn `forge build` ở root: xem `docs/RUN.md` mục "Foundry (tuỳ chọn)".

## Nếu `git pull` báo lỗi

```
error: The following untracked working tree files would be overwritten by merge:
        verification/.certora_internal/latest
Aborting
```

Nghĩa là mày đã chạy `certoraRun` ít nhất một lần, nên có thư mục rác
`verification/.certora_internal/` (có thể 100+ MB). Repo cũ lỡ track thư mục này
(commit `a34a1ce`), nên git từ chối merge. Chữa một lần:

```bash
cd /workspaces/looping-contracts
rm -rf verification/.certora_internal
git pull origin master          # từ 5b4aaa3 trở đi sẽ không tái diễn
```

Từ commit `5b4aaa3`, `.certora_internal/` đã nằm trong `verification/.gitignore`.
Đừng bao giờ `git add -A` trong thư mục này — dùng `git add verification/src verification/certora verification/scripts verification/docs`.
