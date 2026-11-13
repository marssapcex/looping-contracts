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

    function _head(WithdrawalQueue storage queue) internal view returns (uint128) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006c0000, 1037618708588) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006c0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006c1000, queue.slot) }
        return queue.head;
    }

    function _tail(WithdrawalQueue storage queue) internal view returns (uint128) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006d0000, 1037618708589) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006d0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006d1000, queue.slot) }
        return queue.tail;
    }

    function _isEmpty(WithdrawalQueue storage queue) internal view returns (bool) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006f0000, 1037618708591) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006f0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006f1000, queue.slot) }
        return queue.tail == queue.head;
    }

    function _enqueue(WithdrawalQueue storage queue, ILoanVault.WithdrawalRequest memory request) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00700000, 1037618708592) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00700001, 2) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00701000, queue.slot) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00701001, request) }
        uint128 idx = queue.tail;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000111,idx)}
        queue.requestMap[idx] = request;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00020114,0)}
        unchecked {
            queue.tail = idx + 1;
        }
    }

    function _dequeueFront(WithdrawalQueue storage queue) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006e0000, 1037618708590) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006e0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006e1000, queue.slot) }
        if (queue.tail <= queue.head) revert QueueEmpty();

        uint128 idx = queue.head;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000112,idx)}
        delete queue.requestMap[idx];
        unchecked {
            queue.head = idx + 1;
        }
    }

    function _dequeueBack(WithdrawalQueue storage queue) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00710000, 1037618708593) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00710001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00711000, queue.slot) }
        if (queue.tail <= queue.head) revert QueueEmpty();

        unchecked {
            uint128 idx = queue.tail - 1;
            delete queue.requestMap[idx];
            queue.tail = idx;
        }
    }

    function _backMut(WithdrawalQueue storage queue) internal view returns (ILoanVault.WithdrawalRequest storage) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00720000, 1037618708594) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00720001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00721000, queue.slot) }
        if (queue.tail <= queue.head) revert QueueEmpty();
        uint128 idx = queue.tail - 1;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000113,idx)}
        return queue.requestMap[idx];
    }

    function _peek(
        WithdrawalQueue storage queue,
        uint128 idx
    )
        internal
        view
        returns (ILoanVault.WithdrawalRequest memory)
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00730000, 1037618708595) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00730001, 2) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00731000, queue.slot) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00731001, idx) }
        if (idx < queue.head || idx >= queue.tail) revert QueueIndexOutOfBounds();
        return queue.requestMap[idx];
    }
}
