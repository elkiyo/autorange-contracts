// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutoRangePlatformConfigV1} from "../src/official/AutoRangePlatformConfigV1.sol";

/// @title Prueba 4 — AutoRangePlatformConfigV1 (the platform-wide config the
/// factory reads at vault-creation time and every vault reads live on each
/// operation). No fork needed — pure unit coverage of the constructor
/// guards, the onlyOwner gate on all 11 setters, the bps ceilings, the
/// zero-address guards, the Ownable2Step two-step ownership handoff, the
/// full-array-replace semantics of setOperatorPool, and creationFeeParams()
/// packing.
///
/// Flow — who may write what:
///
///   deployer --constructor(guards)--> AutoRangePlatformConfigV1
///                                        |
///          owner ----setX() (onlyOwner)--+--> feeToken / defaultOperator / maxDepositUsd
///                                        |    performanceFeeBps (<=10000)
///                                        |    creationFeeBps (<=10000) / creationFeeUsdt
///                                        |    creationFeeTierThresholdUsd / creationFeeFlatUsd
///                                        |    treasury / forceRebalanceCooldownSeconds
///                                        |    operatorPool[] (whole-array replace)
///                                        |
///   pendingOwner --acceptOwnership()-----+   (transferOwnership only ARMS it;
///                                            the handoff needs the 2nd tx)
///
///   anyone-else --setX()--> revert OwnableUnauthorizedAccount
contract AutoRangePlatformConfigV1Test is Test {
    address owner = makeAddr("platformOwner");
    address stranger = makeAddr("stranger");
    address feeToken = makeAddr("feeToken");
    address defaultOperator = makeAddr("defaultOperator");
    address treasury = makeAddr("treasury");

    uint256 constant MAX_DEPOSIT = 20_000_000_000;
    uint256 constant PERF_BPS = 1_000;

    AutoRangePlatformConfigV1 config;

    function setUp() public {
        config = new AutoRangePlatformConfigV1(owner, feeToken, defaultOperator, MAX_DEPOSIT, PERF_BPS, 0, treasury);
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    function test_constructor_setsEveryFieldAndOwner() public view {
        assertEq(config.owner(), owner);
        assertEq(config.feeToken(), feeToken);
        assertEq(config.defaultOperator(), defaultOperator);
        assertEq(config.maxDepositUsd(), MAX_DEPOSIT);
        assertEq(config.performanceFeeBps(), PERF_BPS);
        assertEq(config.creationFeeUsdt(), 0);
        assertEq(config.treasury(), treasury);
        // fields not in the constructor default to 0
        assertEq(config.creationFeeBps(), 0);
        assertEq(config.forceRebalanceCooldownSeconds(), 0);
        assertEq(config.creationFeeTierThresholdUsd(), 0);
        assertEq(config.creationFeeFlatUsd(), 0);
        assertEq(config.operatorPool().length, 0);
    }

    function test_constructor_revertsOnZeroFeeToken() public {
        vm.expectRevert(bytes("feeToken=0"));
        new AutoRangePlatformConfigV1(owner, address(0), defaultOperator, MAX_DEPOSIT, PERF_BPS, 0, treasury);
    }

    function test_constructor_revertsOnZeroDefaultOperator() public {
        vm.expectRevert(bytes("defaultOperator=0"));
        new AutoRangePlatformConfigV1(owner, feeToken, address(0), MAX_DEPOSIT, PERF_BPS, 0, treasury);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(bytes("treasury=0"));
        new AutoRangePlatformConfigV1(owner, feeToken, defaultOperator, MAX_DEPOSIT, PERF_BPS, 0, address(0));
    }

    function test_constructor_revertsOnPerformanceFeeOver100pct() public {
        vm.expectRevert(bytes("performanceFeeBps>100%"));
        new AutoRangePlatformConfigV1(owner, feeToken, defaultOperator, MAX_DEPOSIT, 10_001, 0, treasury);
    }

    function test_constructor_acceptsPerformanceFeeExactly100pct() public {
        AutoRangePlatformConfigV1 c =
            new AutoRangePlatformConfigV1(owner, feeToken, defaultOperator, MAX_DEPOSIT, 10_000, 0, treasury);
        assertEq(c.performanceFeeBps(), 10_000);
    }

    // ---------------------------------------------------------------------
    // onlyOwner on every setter
    // ---------------------------------------------------------------------

    function test_everySetter_isOnlyOwner() public {
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(denied);
        config.setPerformanceFeeBps(1);
        vm.expectRevert(denied);
        config.setFeeToken(makeAddr("x"));
        vm.expectRevert(denied);
        config.setDefaultOperator(makeAddr("x"));
        vm.expectRevert(denied);
        config.setMaxDepositUsd(1);
        vm.expectRevert(denied);
        config.setCreationFeeUsdt(1);
        vm.expectRevert(denied);
        config.setCreationFeeBps(1);
        vm.expectRevert(denied);
        config.setTreasury(makeAddr("x"));
        vm.expectRevert(denied);
        config.setForceRebalanceCooldownSeconds(1);
        vm.expectRevert(denied);
        config.setCreationFeeTierThresholdUsd(1);
        vm.expectRevert(denied);
        config.setCreationFeeFlatUsd(1);
        vm.expectRevert(denied);
        config.setOperatorPool(new address[](0));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Bounds + zero-address guards on the setters
    // ---------------------------------------------------------------------

    function test_setPerformanceFeeBps_boundary() public {
        vm.startPrank(owner);
        config.setPerformanceFeeBps(10_000); // exactly 100% ok
        assertEq(config.performanceFeeBps(), 10_000);
        vm.expectRevert(bytes("performanceFeeBps>100%"));
        config.setPerformanceFeeBps(10_001);
        vm.stopPrank();
    }

    function test_setCreationFeeBps_boundary() public {
        vm.startPrank(owner);
        config.setCreationFeeBps(10_000);
        assertEq(config.creationFeeBps(), 10_000);
        vm.expectRevert(bytes("creationFeeBps>100%"));
        config.setCreationFeeBps(10_001);
        vm.stopPrank();
    }

    function test_zeroAddressGuards_onFeeTokenOperatorTreasury() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("feeToken=0"));
        config.setFeeToken(address(0));
        vm.expectRevert(bytes("operator=0"));
        config.setDefaultOperator(address(0));
        vm.expectRevert(bytes("treasury=0"));
        config.setTreasury(address(0));
        vm.stopPrank();
    }

    /// The threshold/flat/cooldown/maxDeposit/creationFeeUsdt setters have NO
    /// upper bound or zero guard by design (0 is a meaningful value for each).
    function test_unboundedSetters_acceptZeroAndLargeValues() public {
        vm.startPrank(owner);
        config.setMaxDepositUsd(0); // "no cap"
        config.setCreationFeeUsdt(0);
        config.setForceRebalanceCooldownSeconds(0);
        config.setCreationFeeTierThresholdUsd(type(uint256).max);
        config.setCreationFeeFlatUsd(type(uint256).max);
        vm.stopPrank();
        assertEq(config.maxDepositUsd(), 0);
        assertEq(config.creationFeeTierThresholdUsd(), type(uint256).max);
        assertEq(config.creationFeeFlatUsd(), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PerformanceFeeBpsUpdated(uint256 newFeeBps);
    event TreasuryUpdated(address newTreasury);
    event OperatorPoolUpdated(address[] newPool);
    event ForceRebalanceCooldownSecondsUpdated(uint256 newCooldown);

    function test_setters_emitTheirEvents() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(config));
        emit PerformanceFeeBpsUpdated(777);
        config.setPerformanceFeeBps(777);

        vm.expectEmit(true, true, true, true, address(config));
        emit TreasuryUpdated(makeAddr("newTreasury"));
        config.setTreasury(makeAddr("newTreasury"));

        vm.expectEmit(true, true, true, true, address(config));
        emit ForceRebalanceCooldownSecondsUpdated(21_600);
        config.setForceRebalanceCooldownSeconds(21_600);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // operatorPool — whole-array replace, no per-entry guard
    // ---------------------------------------------------------------------

    function test_setOperatorPool_replacesTheWholeArray() public {
        address[] memory a = new address[](2);
        a[0] = makeAddr("opA");
        a[1] = makeAddr("opB");
        vm.prank(owner);
        config.setOperatorPool(a);
        assertEq(config.operatorPool().length, 2);
        assertEq(config.operatorPool()[0], a[0]);
        assertEq(config.operatorPool()[1], a[1]);

        // A second call REPLACES (not appends).
        address[] memory b = new address[](1);
        b[0] = makeAddr("opC");
        vm.prank(owner);
        config.setOperatorPool(b);
        assertEq(config.operatorPool().length, 1);
        assertEq(config.operatorPool()[0], b[0]);

        // Clearing it back to empty is allowed.
        vm.prank(owner);
        config.setOperatorPool(new address[](0));
        assertEq(config.operatorPool().length, 0);
    }

    function test_setOperatorPool_allowsZeroAddressEntry_documentedAsInert() public {
        address[] memory a = new address[](2);
        a[0] = address(0); // inert: address(0) can never be msg.sender
        a[1] = makeAddr("opReal");
        vm.prank(owner);
        config.setOperatorPool(a); // does not revert
        assertEq(config.operatorPool()[0], address(0));
    }

    // ---------------------------------------------------------------------
    // creationFeeParams() packing
    // ---------------------------------------------------------------------

    function test_creationFeeParams_returnsThePackedTriple() public {
        vm.startPrank(owner);
        config.setCreationFeeTierThresholdUsd(1_000_000_000);
        config.setCreationFeeFlatUsd(1_000_000);
        config.setCreationFeeBps(10);
        vm.stopPrank();
        (uint256 threshold, uint256 flat, uint256 bps) = config.creationFeeParams();
        assertEq(threshold, 1_000_000_000);
        assertEq(flat, 1_000_000);
        assertEq(bps, 10);
    }

    // ---------------------------------------------------------------------
    // Ownable2Step — two-step ownership handoff
    // ---------------------------------------------------------------------

    function test_ownable2Step_transferRequiresExplicitAccept() public {
        address newOwner = makeAddr("newPlatformOwner");

        vm.prank(owner);
        config.transferOwnership(newOwner);

        // Step 1 only ARMS it — the current owner still owns it.
        assertEq(config.owner(), owner);
        assertEq(config.pendingOwner(), newOwner);

        // The current owner can still act.
        vm.prank(owner);
        config.setPerformanceFeeBps(123);
        assertEq(config.performanceFeeBps(), 123);

        // A non-pending address cannot accept.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        config.acceptOwnership();

        // The pending owner completes the handoff.
        vm.prank(newOwner);
        config.acceptOwnership();
        assertEq(config.owner(), newOwner);
        assertEq(config.pendingOwner(), address(0));

        // The old owner is now locked out; the new owner is in.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        config.setPerformanceFeeBps(1);
        vm.prank(newOwner);
        config.setPerformanceFeeBps(456);
        assertEq(config.performanceFeeBps(), 456);
    }

    function test_ownable2Step_pendingTransferCanBeOverwrittenOrCancelled() public {
        vm.prank(owner);
        config.transferOwnership(makeAddr("candidateA"));
        vm.prank(owner);
        config.transferOwnership(makeAddr("candidateB")); // overwrites A
        assertEq(config.pendingOwner(), makeAddr("candidateB"));

        vm.prank(owner);
        config.transferOwnership(address(0)); // cancel
        assertEq(config.pendingOwner(), address(0));
        assertEq(config.owner(), owner);
    }
}
