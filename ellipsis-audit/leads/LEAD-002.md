# LEAD-002 — `unlockedBalance(user)` reads the caller's earnings, not `user`'s

Status: **confirmed view defect; integration LEAD only, not a money-loss FINDING**  
Affected source: `contracts/MultiFeeDistribution.sol:174-183`

At line 175 the function starts with `balances[user].unlocked`, but line 176 then iterates `userEarnings[msg.sender]`. A caller querying another account therefore receives its own unlocked principal plus its own expired earnings, rather than the target account's expired earnings.

The local exact-source test mints earned balance to the attacker, advances beyond the lock period, and shows that the attacker querying the victim receives a nonzero result while the victim querying the attacker receives zero (`run.log:65-67`). No tokens move.

## why_unproven

- The supplied MFD withdrawal functions use internal balance mappings directly and do not call this view; no over-withdrawal results.
- No deployed lending, collateral, voting, accounting, or other integration relying on this view was supplied or verified.
- There is no pinned BSC call, victim loss, attacker withdrawal, or positive P&L.
- Therefore this is not promoted as a permissionless money-losing vulnerability. It is retained only so integrators can check whether they consume the incorrect value.

## Immediately runnable next check

At a screenshot-correlated archive pin, query with an explicit caller and compare against the target's balance views:

```sh
BSC_ARCHIVE_RPC='https://your-archive-endpoint'
PIN=12345678
CALLER=0x0000000000000000000000000000000000000001
USER=0x0000000000000000000000000000000000000002
MFD=0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c
cast call "$MFD" 'unlockedBalance(address)(uint256)' "$USER" \
  --from "$CALLER" --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"
cast call "$MFD" 'earnedBalances(address)(uint256,(uint256,uint256)[])' "$USER" \
  --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"
cast call "$MFD" 'totalBalance(address)(uint256)' "$USER" \
  --rpc-url "$BSC_ARCHIVE_RPC" --block "$PIN"
```

Then identify any integration that consumes `unlockedBalance`. Promotion would require a transaction through that integration producing a real attacker withdrawal and positive all-cost P&L at the same pin; the view discrepancy alone is insufficient.
