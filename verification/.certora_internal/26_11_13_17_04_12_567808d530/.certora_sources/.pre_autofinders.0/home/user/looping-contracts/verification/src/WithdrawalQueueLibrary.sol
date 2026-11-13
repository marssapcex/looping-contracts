// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ILoanVault } from "./interfaces/ILoanVault.sol";

/// @title WithdrawalQueueLibrary (reconstructed verbatim)
library WithdrawalQueueLibrary {
    error QueueEmpty();
    error QueueIndexOutOfBounds();

    struct WithdrawalQueue {
        uint128 head;
        uint128 tail;
        mapping(uint128 => ILoanVault.WithdrawalRequest) requestMap;
    }

    function _head(WithdrawalQueue storage queue) internal view returns (uint128) {
        return queue.head;
    }

    function _tail(WithdrawalQueue storage queue) internal view returns (uint128) {
        return queue.tail;
    }

    function _isEmpty(WithdrawalQueue storage queue) internal view returns (bool) {
        return queue.tail == queue.head;
    }

    function _enqueue(WithdrawalQueue storage queue, ILoanVault.WithdrawalRequest memory request) internal {
        uint128 idx = queue.tail;
        queue.requestMap[idx] = request;
        unchecked {
            queue.tail = idx + 1;
        }
    }

    function _dequeueFront(WithdrawalQueue storage queue) internal {
        if (queue.tail <= queue.head) revert QueueEmpty();

        uint128 idx = queue.head;
        delete queue.requestMap[idx];
        unchecked {
            queue.head = idx + 1;
        }
    }

    function _dequeueBack(WithdrawalQueue storage queue) internal {
        if (queue.tail <= queue.head) revert QueueEmpty();

        unchecked {
            uint128 idx = queue.tail - 1;
            delete queue.requestMap[idx];
            queue.tail = idx;
        }
    }

    function _backMut(WithdrawalQueue storage queue) internal view returns (ILoanVault.WithdrawalRequest storage) {
        if (queue.tail <= queue.head) revert QueueEmpty();
        uint128 idx = queue.tail - 1;
        return queue.requestMap[idx];
    }

    function _peek(
        WithdrawalQueue storage queue,
        uint128 idx
    )
        internal
        view
        returns (ILoanVault.WithdrawalRequest memory)
    {
        if (idx < queue.head || idx >= queue.tail) revert QueueIndexOutOfBounds();
        return queue.requestMap[idx];
    }
}
