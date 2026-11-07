#!/bin/sh
# Read-only pinned-BSC verification. No keys, broadcasts, or latest-block fallback.
set -eu
: "${BSC_ARCHIVE_RPC:?set BSC_ARCHIVE_RPC to an archive endpoint}"
: "${PIN:?set PIN to the screenshot-correlated numeric block}"
case "$PIN" in *[!0-9]*) echo "PIN must be numeric" >&2; exit 2;; esac
CAST="${CAST:-cast}"
EPS=0xA7f552078dcC247C2684336020c03648500C6d9F
MFD=0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c
LP=0xcce949De564fE60e7f96C85e55177F8B9E4CF61b
POOL=0xFD4afeAc39DA03a05f61844095A75c4fB7D766DA
IMPL=0x1E97685aa5b1F9c6Dc44aF52a1BBa8049F43226c
call() { label=$1; shift; printf '\n[%s]\n' "$label"; "$CAST" call "$@" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"; }
code() { label=$1; address=$2; printf '\n[code %s %s]\n' "$label" "$address"; "$CAST" code "$address" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"; }
printf 'pin=%s rpc=%s\n' "$PIN" "$BSC_ARCHIVE_RPC"
"$CAST" chain-id --rpc-url "$BSC_ARCHIVE_RPC"
code EPS "$EPS"
code MultiFeeDistribution "$MFD"
code LpTokenStaker "$LP"
code CryptoSwapProxy "$POOL"
code CryptoSwapImplementation "$IMPL"
call EPS.decimals "$EPS" 'decimals()(uint256)'
call EPS.totalSupply "$EPS" 'totalSupply()(uint256)'
call EPS.minter "$EPS" 'minter()(address)'
call MFD.totalSupply "$MFD" 'totalSupply()(uint256)'
call MFD.lockedSupply "$MFD" 'lockedSupply()(uint256)'
call MFD.stakingToken "$MFD" 'stakingToken()(address)'
call MFD.rewardData_EPS "$MFD" 'rewardData(address)(uint256,uint256,uint256,uint256)' "$EPS"
call LP.poolLength "$LP" 'poolLength()(uint256)'
call LP.rewardsPerSecond "$LP" 'rewardsPerSecond()(uint256)'
call LP.startTime "$LP" 'startTime()(uint256)'
call LP.totalAllocPoint "$LP" 'totalAllocPoint()(uint256)'
call LP.rewardMinter "$LP" 'rewardMinter()(address)'
for pid in 0 1 2 3 4 5 6 7 8 9 10 11; do
  call "LP.poolInfo_$pid" "$LP" 'poolInfo(uint256)(address,uint256,uint256,uint256,uint256)' "$pid"
done
# The dynamic array has no length getter. Stop at the first out-of-range read.
i=0
while [ "$i" -lt 16 ]; do
  if ! "$CAST" call "$LP" 'emissionSchedule(uint256)(uint128,uint128)' "$i" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"; then
    echo "emissionSchedule first unavailable index=$i"
    break
  fi
  i=$((i+1))
done
call Pool.mid_fee "$POOL" 'mid_fee()(uint256)'
call Pool.token "$POOL" 'token()(address)'
call Pool.coin0 "$POOL" 'coins(uint256)(address)' 0
call Pool.coin1 "$POOL" 'coins(uint256)(address)' 1
call Pool.D "$POOL" 'D()(uint256)'
call Pool.balance0 "$POOL" 'balances(uint256)(uint256)' 0
call Pool.balance1 "$POOL" 'balances(uint256)(uint256)' 1
call Pool.virtual_price "$POOL" 'virtual_price()(uint256)'
printf '\nNext promotion gate: if rewardsPerSecond and remaining schedule can produce a stale-rate interval, replay the attacker deposit/claim/withdraw/exit against Anvil at this exact pin, sweep EPS to a real liquid asset, and assert positive P&L after gas and swap costs. Otherwise retain LEAD-001 as unproven.\n'
