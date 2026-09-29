// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IFeeCalculator} from "frontier/interfaces/extensions/IFeeCalculator.sol";
import {IHookObserver} from "frontier/interfaces/extensions/IHookObserver.sol";

import {HookGated} from "contracts/HookGated.sol";
import {HookPayload} from "contracts/HookPayload.sol";

/// @dev One contract bound as both calculator and observer of the same pool.
contract DualRoleExtension is IFeeCalculator, IHookObserver, HookGated {
    mapping(PoolId poolId => uint256 swaps) public swapsOf;

    constructor(address factory) HookGated(factory) {}

    function onRegisterCalculator(PoolId poolId, bytes calldata) external {
        _registerPool(poolId);
    }

    function onRegisterObserver(PoolId poolId, bytes calldata) external {
        _registerPool(poolId);
    }

    function quoteFee(PoolId poolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata)
        external
        view
        returns (uint24)
    {
        // Fee rises by 0.1 % per recorded swap: the observer role feeds the calculator role.
        return previousFee + uint24(swapsOf[poolId]) * 1000;
    }

    function onAfterSwap(PoolId poolId, BalanceDelta, uint24, uint256, bytes calldata) external onlyPoolHook(poolId) {
        ++swapsOf[poolId];
    }

    function onFeeChange(PoolId, uint24, uint24) external {}
}

contract DualRoleExtensionTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    DualRoleExtension internal extension;

    function setUp() public override {
        super.setUp();
        extension = new DualRoleExtension(address(factory));
    }

    function test_bothRoles_onOnePool_deployAndInteract() public {
        IFactoryHook.HookConfigV2 memory config = HookPayload.withFee(HookPayload.DEFAULT_FIXED_FEE);
        config = config.addCalculator(address(extension), "");
        config = config.addObserver(address(extension), HookPayload.CALL_AFTER_SWAP, "");
        (MockBCToken token, PoolId poolId) = _deployGraduated(config, false);
        assertEq(extension.hookOf(poolId), address(hook));

        _swapEthForCoin(address(token), users.buyerOne, 0.1 ether);
        _swapEthForCoin(address(token), users.buyerOne, 0.1 ether);

        assertEq(extension.swapsOf(poolId), 2);
        assertEq(hook.getCurrentFee(poolId), HookPayload.DEFAULT_FIXED_FEE + 1000);
    }
}
