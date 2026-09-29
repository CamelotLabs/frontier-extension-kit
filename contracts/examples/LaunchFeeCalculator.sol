// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCToken} from "frontier/interfaces/IBCToken.sol";
import {IExtensionHost} from "frontier/interfaces/extensions/IExtensionHost.sol";
import {IFeeCalculator} from "frontier/interfaces/extensions/IFeeCalculator.sol";

import {HookGated} from "../HookGated.sol";

/**
 * @title LaunchFeeCalculator
 * @notice Example fee calculator: a higher fee for the first hours after a coin graduates, then
 * the rest of the chain decides. One deployment serves every pool; each pool picks its own fee
 * and duration when the coin is deployed.
 * @dev Config (`calculatorConfig` in the payload): `abi.encode(uint24 launchFee, uint32 duration)`.
 * The hook calls `quoteFee` with a `staticcall` and a 50k gas stipend: keep it view and cheap.
 * If it reverts or runs out of gas, the hook skips it and the swap uses the previous fee.
 * A direct-seed coin is born graduated and the creator's own buy runs inside the deploy
 * transaction, after registration: it pays the launch fee too.
 */
contract LaunchFeeCalculator is IFeeCalculator, HookGated {
    struct Config {
        address coin;
        uint24 launchFee;
        uint32 duration;
    }

    /// @notice Each pool's config, written once at registration.
    mapping(PoolId poolId => Config config) public configOf;

    /// @notice The launch fee is zero or above what the hook would let through (`MAX_HOOK_FEE`).
    error InvalidLaunchFee(uint24 launchFee);

    /// @notice The duration is zero.
    error InvalidDuration();

    /// @param factory The Frontier `BCTokenFactory`.
    constructor(address factory) HookGated(factory) {}

    /// @inheritdoc IFeeCalculator
    function onRegisterCalculator(PoolId poolId, bytes calldata config) external {
        IExtensionHost host = _registerPool(poolId);
        (uint24 launchFee, uint32 duration) = abi.decode(config, (uint24, uint32));
        // Validated against the registering hook's own ceiling, so a fee the clamp would cut is
        // refused at deploy time instead of silently flattened.
        if (launchFee == 0 || launchFee > host.MAX_HOOK_FEE()) revert InvalidLaunchFee(launchFee);
        if (duration == 0) revert InvalidDuration();
        configOf[poolId] = Config({coin: host.poolCoin(poolId), launchFee: launchFee, duration: duration});
    }

    /// @inheritdoc IFeeCalculator
    function quoteFee(PoolId poolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata)
        external
        view
        returns (uint24)
    {
        Config memory c = configOf[poolId];
        uint256 graduatedAt = IBCToken(c.coin).lpdAt();
        if (graduatedAt == 0 || block.timestamp >= graduatedAt + c.duration) return previousFee;
        return c.launchFee > previousFee ? c.launchFee : previousFee;
    }
}
