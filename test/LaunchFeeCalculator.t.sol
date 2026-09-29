// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookGated} from "contracts/HookGated.sol";
import {HookPayload} from "contracts/HookPayload.sol";
import {LaunchFeeCalculator} from "contracts/examples/LaunchFeeCalculator.sol";

/// @dev Runs against Frontier's real `FactoryHook` (from lib/factory-hook) on a local Uniswap v4 stack.
contract LaunchFeeCalculatorTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    uint24 internal constant BASE_FEE = 3000; // 0.30 %
    uint24 internal constant LAUNCH_FEE = 20_000; // 2 %
    uint32 internal constant DURATION = 1 hours;

    LaunchFeeCalculator internal calculator;

    function setUp() public override {
        super.setUp();
        calculator = new LaunchFeeCalculator(address(factory));
    }

    function test_quote_duringLaunchWindow_chargesLaunchFee() public {
        (, PoolId poolId) = _launch(BASE_FEE, abi.encode(LAUNCH_FEE, DURATION));

        assertEq(_buyFee(poolId), LAUNCH_FEE);
    }

    function test_quote_afterLaunchWindow_fallsBackToBaseFee() public {
        (, PoolId poolId) = _launch(BASE_FEE, abi.encode(LAUNCH_FEE, DURATION));

        vm.warp(block.timestamp + DURATION);

        assertEq(_buyFee(poolId), BASE_FEE);
    }

    function test_quote_neverLowersTheRunningFee() public {
        uint24 highBase = 30_000;
        (, PoolId poolId) = _launch(highBase, abi.encode(LAUNCH_FEE, DURATION));

        assertEq(_buyFee(poolId), highBase);
    }

    function test_swap_appliesLaunchFee() public {
        (MockBCToken coin_, PoolId poolId) = _launch(BASE_FEE, abi.encode(LAUNCH_FEE, DURATION));

        _swapEthForCoin(address(coin_), users.buyerOne, 0.1 ether);

        assertEq(hook.getCurrentFee(poolId), LAUNCH_FEE);
    }

    /// @dev Measured from a cold caller, as the hook sees it: over the stipend the stage is skipped.
    function test_quote_fitsInTheHookStipend() public {
        (, PoolId poolId) = _launch(BASE_FEE, abi.encode(LAUNCH_FEE, DURATION));
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        uint256 before = gasleft();
        calculator.quoteFee(poolId, BASE_FEE, BASE_FEE, 0, 0, params);
        uint256 used = before - gasleft();

        assertLt(used, hook.CALC_GAS_STIPEND());
    }

    function test_RevertWhen_launchFeeAboveHookCeiling() public {
        uint24 tooHigh = hook.MAX_HOOK_FEE() + 1;
        IFactoryHook.HookConfigV2 memory config =
            HookPayload.withFee(BASE_FEE).addCalculator(address(calculator), abi.encode(tooHigh, DURATION));
        MockBCToken token = _newCoin("Bad", "BAD");

        vm.expectRevert(abi.encodeWithSelector(LaunchFeeCalculator.InvalidLaunchFee.selector, tooHigh));
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(config));
    }

    function test_RevertWhen_registeredByAnyoneButTheHook() public {
        PoolId poolId = PoolId.wrap(keccak256("a pool id computed before its coin exists"));

        vm.prank(users.buyerOne);
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotCurrentHook.selector, users.buyerOne));
        calculator.onRegisterCalculator(poolId, abi.encode(LAUNCH_FEE, DURATION));
    }

    function _launch(uint24 baseFee, bytes memory calculatorConfig)
        internal
        returns (MockBCToken token, PoolId poolId)
    {
        return _deployGraduated(
            HookPayload.withFee(baseFee).addCalculator(address(calculator), calculatorConfig), false
        );
    }

    /// @dev The fee the hook would charge on a 0.1 ETH buy right now.
    function _buyFee(PoolId poolId) internal view returns (uint24 totalFee) {
        (totalFee,,) = hook.previewFee(
            poolId,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
    }

    function _noStaking() internal pure returns (IBCTokenFactory.StakingConfig memory) {
        return IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)});
    }
}
