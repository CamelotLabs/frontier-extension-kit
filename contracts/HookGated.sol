// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IExtensionHost} from "frontier/interfaces/extensions/IExtensionHost.sol";

/// @notice The one read an extension needs from the liquidity manager: the hook new pools bind to.
interface ICurrentHook {
    function hook() external view returns (address);
}

/**
 * @title HookGated
 * @notice Base for Frontier hook extensions. It enforces the registration rule every extension
 * must follow (S1): only the hook new pools currently bind to may register a pool, once, and each
 * pool then answers only to the hook that registered it.
 * @dev Pool ids are known before a coin exists, so an open registration could be claimed ahead of
 * the real deploy and brick it. Pinning per pool, instead of storing one hook, lets a single
 * deployment serve every hook generation: old pools keep talking to their old hook.
 */
abstract contract HookGated {
    /// @notice The Frontier coin factory; its liquidity manager names the current hook.
    address public immutable BC_TOKEN_FACTORY;

    /// @notice The hook that registered each pool.
    mapping(PoolId poolId => address hook) public hookOf;

    /// @notice The caller is not the hook new pools currently bind to.
    error NotCurrentHook(address caller);

    /// @notice The caller is not the hook this pool was registered by.
    error NotPoolHook(address caller);

    /// @param factory The Frontier `BCTokenFactory`.
    constructor(address factory) {
        BC_TOKEN_FACTORY = factory;
    }

    /// @notice Restricts a call to the hook `poolId` was registered by.
    modifier onlyPoolHook(PoolId poolId) {
        if (msg.sender != hookOf[poolId]) revert NotPoolHook(msg.sender);
        _;
    }

    /// @notice Registers `poolId` to the caller, which must be the current hook. Call it first
    /// in `onRegisterCalculator` / `onRegisterObserver`.
    /// @dev May run more than once for the same pool, all inside its deploy transaction: once per
    /// role for an extension bound as both calculator and observer, or once per entry if the creator
    /// lists it twice. Re-pinning is safe: a pool id commits to its hook address, and the hook
    /// registers a pool only during that pool's creation, so the pinned hook can never change.
    /// @param poolId The pool being registered.
    /// @return host The registering hook, to read the pool's facts and the hook's bounds from.
    function _registerPool(PoolId poolId) internal returns (IExtensionHost host) {
        address current = ICurrentHook(IBCTokenFactory(BC_TOKEN_FACTORY).liquidityManager()).hook();
        if (msg.sender != current) revert NotCurrentHook(msg.sender);
        hookOf[poolId] = current;
        return IExtensionHost(current);
    }
}
