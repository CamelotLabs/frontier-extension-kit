// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookGated} from "contracts/HookGated.sol";
import {HookPayload} from "contracts/HookPayload.sol";
import {BuyVolumeObserver} from "contracts/examples/BuyVolumeObserver.sol";

/// @dev Runs against Frontier's real `FactoryHook` (from lib/factory-hook) on a local Uniswap v4 stack.
contract BuyVolumeObserverTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    BuyVolumeObserver internal observer;

    function setUp() public override {
        super.setUp();
        observer = new BuyVolumeObserver(address(factory));
    }

    function test_onAfterSwap_buy_creditsDeclaredBuyer() public {
        (MockBCToken token, PoolId poolId) = _launch("");
        address smartWallet = makeAddr("smart wallet");

        _swapEthForCoinWithHookData(address(token), users.buyerOne, 0.5 ether, abi.encode(smartWallet));

        assertEq(observer.volumeOf(poolId, smartWallet), 0.5 ether);
    }

    function test_onAfterSwap_buyWithoutHookData_creditsTxOrigin() public {
        (MockBCToken token, PoolId poolId) = _launch("");

        _swapEthForCoin(address(token), users.buyerOne, 0.5 ether);

        assertEq(observer.volumeOf(poolId, tx.origin), 0.5 ether);
    }

    /// @dev On an exact-output buy the hook charges its fee after the swap, so `delta` alone
    /// understates the spend; the observer adds `feeAmount` back and lands on what left the wallet.
    function test_onAfterSwap_exactOutputBuy_recordsWhatTheBuyerPaid() public {
        (MockBCToken token, PoolId poolId) = _launch("");
        uint256 before = users.buyerOne.balance;

        _exactOutputBuyOn(address(token), users.buyerOne, 1_000_000 ether, 1 ether);

        uint256 paid = before - users.buyerOne.balance;
        assertGt(paid, 0);
        assertEq(observer.volumeOf(poolId, tx.origin), paid);
    }

    function test_onAfterSwap_sell_recordsNothing() public {
        (MockBCToken token, PoolId poolId) = _launch("");

        _swapCoinForEth(address(token), users.buyerOne, 1_000_000 ether);

        assertEq(observer.volumeOf(poolId, tx.origin), 0);
    }

    function test_onAfterSwap_buyBelowMinimum_recordsNothing() public {
        (MockBCToken token, PoolId poolId) = _launch(abi.encode(uint256(1 ether)));

        _swapEthForCoin(address(token), users.buyerOne, 0.5 ether);

        assertEq(observer.volumeOf(poolId, tx.origin), 0);
    }

    function test_RevertWhen_onAfterSwapNotFromPoolHook() public {
        (, PoolId poolId) = _launch("");

        vm.prank(users.buyerOne);
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, users.buyerOne));
        observer.onAfterSwap(poolId, toBalanceDelta(-100 ether, 1), 0, 0, "");
    }

    function test_RevertWhen_registeredByAnyoneButTheHook() public {
        PoolId poolId = PoolId.wrap(keccak256("a pool id computed before its coin exists"));

        vm.prank(users.buyerOne);
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotCurrentHook.selector, users.buyerOne));
        observer.onRegisterObserver(poolId, "");
    }

    function _launch(bytes memory observerConfig) internal returns (MockBCToken token, PoolId poolId) {
        return _deployGraduated(
            HookPayload.withFee(HookPayload.DEFAULT_FIXED_FEE)
                .addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, observerConfig),
            false
        );
    }
}
