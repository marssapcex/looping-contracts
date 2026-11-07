#!/bin/sh
# Read-only incident-pin verification. No private keys, storage overrides, or latest fallback.
set -eu
: "${BSC_ARCHIVE_RPC:?set BSC_ARCHIVE_RPC to a BSC archive endpoint}"
PIN=${PIN:-116169048}
case "$PIN" in *[!0-9]*) echo "PIN must be numeric" >&2; exit 2;; esac
[ "$PIN" -eq 116169048 ] || { echo "This incident readback is pinned only to 116169048" >&2; exit 2; }
CAST=${CAST:-cast}
POOL=0x9fa6D8a13b35E051BFc145918db0111dEc13D1A0
POOL_IMPL=0x58E2A853BB14e46BefD3148bd4280370fEA4655A
TREASURY=0x361d08ff43761E6a7E8Fcabe48048AE9010801cc
TREASURY_IMPL=0x87614D97808DcDEcB069fe8489848fa1C001e04D
FOX=0xdF81d50c6657487D19B66A1b5375E35A804Abb93
USDT=0x55d398326f99059fF775485246999027B3197955
PAIR=0xAAb18bCDEe287AEA288c0560612cAadf7c328803
ATTACK=0x3A82A2A77061017927e5331fFFd07c0308a1D2DA
TX=0x8e1775cbfd44db29744cc6687ff1822d2c47321de6e94062f789ad6181ad5514
ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E
call() { printf '\n[%s]\n' "$1"; shift; "$CAST" call "$@" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"; }
code() { printf '\n[code %s]\n' "$1"; "$CAST" code "$2" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"; }
printf 'chain-id: '; "$CAST" chain-id --rpc-url "$BSC_ARCHIVE_RPC"
printf 'pin: %s\n' "$PIN"
for item in "$POOL" "$POOL_IMPL" "$TREASURY" "$TREASURY_IMPL" "$FOX" "$PAIR" "$ATTACK" "$ROUTER"; do code "$item" "$item"; done
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
printf '\n[pool ERC1967 implementation slot]\n'
"$CAST" storage "$POOL" "$IMPL_SLOT" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"
printf '\n[treasury ERC1967 implementation slot]\n'
"$CAST" storage "$TREASURY" "$IMPL_SLOT" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"
call pool.stakeDays "$POOL" 'stakeDays()(uint256)'
call pool.treasury "$POOL" 'treasury()(address)'
call pool.foxToken "$POOL" 'foxToken()(address)'
call pool.usdtToken "$POOL" 'usdtToken()(address)'
call pool.lpFoxToken "$POOL" 'lpFoxToken()(address)'
call pool.swapRouter "$POOL" 'swapRouter()(address)'
call pool.discountRateFrom "$POOL" 'discountRateFrom()(uint256)'
call pool.discountRateTo "$POOL" 'discountRateTo()(uint256)'
call pool.pretrade_quote "$POOL" 'getSwapPrice(uint256)(uint256,uint256)' 0
call treasury.foxToken "$TREASURY" 'foxToken()(address)'
call treasury.pool_authorized "$TREASURY" 'stakingPoolMap(address)(bool)' "$POOL"
call fox.treasury "$FOX" 'treasury()(address)'
call fox.sellRatio "$FOX" 'sellRatio()(uint256)'
call fox.targetPool "$FOX" 'targetPool()(address)'
call fox.transferStatus "$FOX" 'transferStatus()(bool)'
call pair.token0 "$PAIR" 'token0()(address)'
call pair.token1 "$PAIR" 'token1()(address)'
call pair.reserves "$PAIR" 'getReserves()(uint112,uint112,uint32)'
call pair.totalSupply "$PAIR" 'totalSupply()(uint256)'
call pair.USDT_balance "$USDT" 'balanceOf(address)(uint256)' "$PAIR"
call pair.FOX_balance "$FOX" 'balanceOf(address)(uint256)' "$PAIR"
call attack.USDT_before "$USDT" 'balanceOf(address)(uint256)' "$ATTACK"
printf '\n[incident transaction]\n'
"$CAST" tx "$TX" --rpc-url "$BSC_ARCHIVE_RPC"
"$CAST" receipt "$TX" --rpc-url "$BSC_ARCHIVE_RPC"
printf '\nNext: BSC_ARCHIVE_RPC=%s ./scripts/run-pinned-replay.sh\n' "$BSC_ARCHIVE_RPC"
