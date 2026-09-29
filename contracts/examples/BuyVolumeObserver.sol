// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IHookObserver} from "frontier/interfaces/extensions/IHookObserver.sol";

import {HookGated} from "../HookGated.sol";

/**
 * @title BuyVolumeObserver
 * @notice Example observer: records how much ETH each buyer spent on each coin, a base for a
 * leaderboard, a quest or a reward program.
 * @dev Config (`observer config` in the payload): empty, or `abi.encode(uint256 minBuyWei)` to
 * ignore small buys. Subscribe with `CALL_AFTER_SWAP`. The hook calls observers last, with a raw
 * call under a gas budget shared by all of the pool's observers (600k), and ignores reverts: an
 * observer can never block a swap, but a greedy one starves the observers after it.
 */
contract BuyVolumeObserver is IHookObserver, HookGated {
    /// @notice Buys below this many wei are ignored, per pool.
    mapping(PoolId poolId => uint256 minBuyWei) public minBuyOf;

    /// @notice ETH spent by each buyer on each pool, in wei.
    mapping(PoolId poolId => mapping(address buyer => uint256 ethSpent)) public volumeOf;

    /// @notice Emitted on every recorded buy.
    event Buy(PoolId indexed poolId, address indexed buyer, uint256 ethIn, uint256 buyerTotal);

    /// @param factory The Frontier `BCTokenFactory`.
    constructor(address factory) HookGated(factory) {}

    /// @inheritdoc IHookObserver
    function onRegisterObserver(PoolId poolId, bytes calldata config) external {
        _registerPool(poolId);
        if (config.length != 0) minBuyOf[poolId] = abi.decode(config, (uint256));
    }

    /// @inheritdoc IHookObserver
    /// @dev Gated on the pool's hook because it writes state that a reward could be built on:
    /// the arguments are the caller's, so an open entry point would let anyone forge volume.
    function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24, uint256 feeAmount, bytes calldata hookData)
        external
        onlyPoolHook(poolId)
    {
        // ETH is always currency0: a negative amount0 is ETH going into the pool, i.e. a buy.
        int128 amount0 = delta.amount0();
        if (amount0 >= 0) return;
        // `delta` is net of the hook's non-LP fee, which a buy pays in ETH: add it back to get
        // what the buyer actually spent.
        uint256 ethIn = uint256(uint128(-amount0)) + feeAmount;
        if (ethIn < minBuyOf[poolId]) return;

        address buyer = _buyer(hookData);
        uint256 total = volumeOf[poolId][buyer] + ethIn;
        volumeOf[poolId][buyer] = total;
        emit Buy(poolId, buyer, ethIn, total);
    }

    /// @inheritdoc IHookObserver
    function onFeeChange(PoolId, uint24, uint24) external {}

    /// @dev Who bought: a frontend or router may pass the buyer as 32 bytes of `hookData` (needed
    /// for smart wallets); otherwise the transaction's origin. Treat `hookData` as untrusted: here
    /// a false claim only credits someone else with your own buy.
    function _buyer(bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 32) {
            address declared = address(uint160(uint256(bytes32(hookData))));
            if (declared != address(0)) return declared;
        }
        return tx.origin;
    }
}
