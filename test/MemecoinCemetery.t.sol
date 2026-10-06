// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MemecoinCemetery, ICemeteryToken} from "src/MemecoinCemetery.sol";

/// @notice Foundry cheatcodes used by this dependency-free suite.
interface CemeteryVm {
    /// @notice Changes the local block timestamp.
    function warp(uint256 timestamp) external;

    /// @notice Reads the current timestamp without compiler caching across warp calls.
    function getBlockTimestamp() external view returns (uint256 timestamp);

    /// @notice Sets the caller of the next external call.
    function prank(address caller) external;

    /// @notice Gives an account local test ETH.
    function deal(address account, uint256 balance) external;

    /// @notice Requires the next call to revert with a particular error selector.
    function expectRevert(bytes4 selector) external;

    /// @notice Requires the next call to revert, including ABI decoding failures.
    function expectRevert() external;

    /// @notice Checks indexed topics, data, and the emitter of the next expected event.
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
}

/// @notice Mutable ERC-20 read mock; all balances and failures are confined to local tests.
contract CemeteryTokenMock is ICemeteryToken {
    /// @notice Explicit failure used to distinguish token errors from cemetery errors.
    error MockReadFailure();

    /// @dev Supply reported to the cemetery.
    uint256 private _supply;
    /// @dev Balances reported to the cemetery.
    mapping(address => uint256) private _balances;
    /// @dev Read modes: 0 succeeds, 1 reverts, 2 returns nothing, 3 returns only 31 bytes.
    uint8 private _supplyMode;
    /// @dev Independently configurable balance read mode.
    uint8 private _balanceMode;

    /// @notice Creates a token with a chosen supply and no initial holders.
    constructor(uint256 supply) {
        _supply = supply;
    }

    /// @notice Simulates a change in total supply.
    function setSupply(uint256 supply) external {
        _supply = supply;
    }

    /// @notice Simulates a holder acquiring or losing tokens.
    function setBalance(address account, uint256 balance) external {
        _balances[account] = balance;
    }

    /// @notice Independently changes the behavior of each ERC-20 read.
    function setReadModes(uint8 supplyMode, uint8 balanceMode) external {
        _supplyMode = supplyMode;
        _balanceMode = balanceMode;
    }

    /// @notice Returns the configured supply or simulates a non-standard token response.
    function totalSupply() external view returns (uint256) {
        return _respond(_supply, _supplyMode);
    }

    /// @notice Returns the configured balance or simulates a non-standard token response.
    function balanceOf(address account) external view returns (uint256) {
        return _respond(_balances[account], _balanceMode);
    }

    /// @dev Produces valid, reverting, empty, and truncated ABI responses.
    function _respond(uint256 value, uint8 mode) private pure returns (uint256) {
        if (mode == 1) revert MockReadFailure();
        if (mode == 2) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, value)
                return(0, 31)
            }
        }
        return value;
    }
}

/// @notice Shared assertions without a dependency on an uncommitted forge-std installation.
abstract contract CemeteryTestSupport {
    /// @dev Standard local Foundry cheatcode address.
    CemeteryVm internal constant vm = CemeteryVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Checks every field, including fields that should be cleared after resurrection.
    function _assertGrave(
        MemecoinCemetery cemetery,
        address token,
        MemecoinCemetery.State expectedState,
        address expectedDigger,
        string memory expectedEpitaph,
        uint256 expectedTimestamp
    ) internal view {
        (MemecoinCemetery.State state, address digger, string memory epitaph, uint256 timestamp) =
            cemetery.graveOf(token);
        require(state == expectedState, "wrong grave state");
        require(digger == expectedDigger, "wrong digger");
        require(keccak256(bytes(epitaph)) == keccak256(bytes(expectedEpitaph)), "wrong epitaph");
        require(timestamp == expectedTimestamp, "wrong grave timestamp");
    }

    /// @dev Builds a byte-counted epitaph, including empty and oversized inputs.
    function _epitaph(uint256 length) internal pure returns (string memory) {
        bytes memory value = new bytes(length);
        for (uint256 i; i < length; ++i) {
            value[i] = bytes1("x");
        }
        return string(value);
    }
}

/// @notice Exercises success paths, rejected calls, byte lengths, and arithmetic boundaries.
/// forge-config: default.fuzz.runs = 1000
contract MemecoinCemeteryTest is CemeteryTestSupport {
    /// @dev Independent specification values; assertions do not derive them from the contract.
    uint256 private constant PERIOD = 30 days;
    /// @dev A non-holder who can open a wake.
    address private constant DIGGER = address(0xD166);
    /// @dev Holder with exactly 0.1% of the initial supply.
    address private constant HOLDER = address(0xA11CE);
    /// @dev Unrelated caller used to demonstrate permissionless sealing and re-digging.
    address private constant OTHER = address(0xB0B);
    /// @dev Contract under test.
    MemecoinCemetery private cemetery;
    /// @dev Default ERC-20 fixture.
    CemeteryTokenMock private token;

    /// @notice Expected event shape, including indexed token and digger.
    event WakeOpened(address indexed token, address indexed digger, string epitaph, uint256 endsAt);
    /// @notice Expected event shape, including indexed token and holder.
    event Resurrected(address indexed token, address indexed holder);
    /// @notice Expected burial data must retain the original digger.
    event Buried(address indexed token, string epitaph, address indexed digger, uint256 sealedAt);

    /// @notice Deploys a fresh cemetery and local token without a fork or network dependency.
    function setUp() public {
        vm.warp(1_700_000_000);
        cemetery = new MemecoinCemetery();
        token = new CemeteryTokenMock(1_000_000);
        token.setBalance(HOLDER, 1000);
    }

    /// @notice The initial record is empty and the public limits match the brief.
    function test_initialStateAndLimits() public view {
        _assertNone(address(token));
        _assertNone(address(0));
        require(cemetery.graveCount() == 0, "initial graves");
        require(cemetery.WAKE_DURATION() == PERIOD, "wake duration");
        require(cemetery.REDIG_COOLDOWN() == PERIOD, "cooldown duration");
        require(cemetery.MAX_EPITAPH_BYTES() == 140, "epitaph limit");
    }

    /// @notice A non-holder opens a fee-free wake with the specified event and record.
    function test_digEmitsAndStoresWakeWithoutHoldingTokens() public {
        uint256 endsAt = vm.getBlockTimestamp() + PERIOD;
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit WakeOpened(address(token), DIGGER, "Gone too soon", endsAt);
        vm.prank(DIGGER);
        cemetery.dig(address(token), "Gone too soon");
        _assertGrave(cemetery, address(token), MemecoinCemetery.State.Wake, DIGGER, "Gone too soon", endsAt);
        require(cemetery.graveCount() == 0, "wake counted as grave");
        require(token.balanceOf(DIGGER) == 0 && token.balanceOf(HOLDER) == 1000, "tokens moved");
        require(address(cemetery).balance == 0, "ETH collected");
    }

    /// @notice A second caller cannot replace either an active or an expired unsealed wake.
    function test_digRejectsDuplicateWakeBeforeAndAfterDeadline() public {
        uint256 endsAt = _open();
        vm.expectRevert(MemecoinCemetery.GraveExists.selector);
        vm.prank(OTHER);
        cemetery.dig(address(token), "replacement");
        vm.warp(endsAt + 1);
        vm.expectRevert(MemecoinCemetery.GraveExists.selector);
        cemetery.dig(address(token), "replacement");
        _assertWake(endsAt);
        require(cemetery.graveCount() == 0, "expired wake counted");
    }

    /// @notice Both an empty epitaph and an epitaph of exactly 140 bytes are accepted.
    function test_digAcceptsEmptyAndMaximumEpitaphs() public {
        cemetery.dig(address(token), "");
        _assertGrave(
            cemetery, address(token), MemecoinCemetery.State.Wake, address(this), "", vm.getBlockTimestamp() + PERIOD
        );
        CemeteryTokenMock second = new CemeteryTokenMock(1000);
        string memory maximum = _epitaph(140);
        cemetery.dig(address(second), maximum);
        _assertGrave(
            cemetery,
            address(second),
            MemecoinCemetery.State.Wake,
            address(this),
            maximum,
            vm.getBlockTimestamp() + PERIOD
        );
    }

    /// @notice A rejected 141-byte epitaph leaves no record and does not start a cooldown.
    function test_digRejects141BytesAndAllowsCorrectedRetry() public {
        vm.expectRevert(MemecoinCemetery.EpitaphTooLong.selector);
        cemetery.dig(address(token), _epitaph(141));
        _assertNone(address(token));
        require(cemetery.graveCount() == 0, "failed dig counted");
        _open();
    }

    /// @notice The limit counts UTF-8 bytes rather than visible characters.
    function test_epitaphLimitCountsUtf8Bytes() public {
        bytes memory text = new bytes(140);
        for (uint256 i; i < 140; i += 2) {
            text[i] = 0xc3;
            text[i + 1] = 0xa9;
        }
        cemetery.dig(address(token), string(text));
        CemeteryTokenMock second = new CemeteryTokenMock(1000);
        vm.expectRevert(MemecoinCemetery.EpitaphTooLong.selector);
        cemetery.dig(address(second), string(bytes.concat(text, hex"c3a9")));
        _assertNone(address(second));
    }

    /// @notice Exact threshold ownership cancels the wake and emits the objecting holder.
    function test_itLivesAtExactThresholdEmitsAndClearsRecord() public {
        _open();
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Resurrected(address(token), HOLDER);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
        require(cemetery.graveCount() == 0, "resurrection counted");
        require(token.balanceOf(HOLDER) == 1000, "holder paid tokens");
    }

    /// @notice Both a non-holder and a holder one unit below 0.1% are rejected atomically.
    function test_itLivesRejectsZeroAndBelowThresholdBalances() public {
        uint256 endsAt = _open();
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(OTHER);
        cemetery.itLives(address(token));
        token.setBalance(HOLDER, 999);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        token.setBalance(HOLDER, 1000);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice A transfer during the wake removes the old holder's eligibility and grants the new holder's.
    function test_itLivesUsesCurrentBalanceAndActualCaller() public {
        uint256 endsAt = _open();
        token.setBalance(HOLDER, 0);
        token.setBalance(OTHER, 1000);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        vm.prank(OTHER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Minting and burning during a wake change the threshold at objection time.
    function test_itLivesUsesCurrentSupply() public {
        uint256 endsAt = _open();
        token.setSupply(2_000_000);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        token.setSupply(500_000);
        token.setBalance(HOLDER, 500);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice A fractional-unit threshold rounds upward: supply 1001 requires two units.
    function test_itLivesRoundsUpFractionalThreshold() public {
        token.setSupply(1001);
        token.setBalance(HOLDER, 1);
        uint256 endsAt = _open();
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        token.setBalance(HOLDER, 2);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Even a one-unit total supply requires an actual holder.
    function test_itLivesWithOneUnitSupply() public {
        token.setSupply(1);
        token.setBalance(HOLDER, 1);
        _open();
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(OTHER);
        cemetery.itLives(address(token));
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Maximum supply and maximum balance do not overflow threshold arithmetic.
    function test_itLivesHandlesMaximumSupplyAndBalance() public {
        token.setSupply(type(uint256).max);
        token.setBalance(HOLDER, type(uint256).max);
        _open();
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Zero-supply tokens can be buried but cannot be resurrected by zero or bogus balances.
    function test_zeroSupplyWakeRejectsObjectionsAndCanBeSealed() public {
        token.setSupply(0);
        uint256 endsAt = _open();
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(OTHER);
        cemetery.itLives(address(token));
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        vm.warp(endsAt);
        cemetery.seal(address(token));
        _assertBuried(endsAt);
    }

    /// @notice The final second before the deadline still permits resurrection.
    function test_itLivesAtLastSecondOfWake() public {
        uint256 endsAt = _open();
        vm.warp(endsAt - 1);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice The deadline itself closes objections, even if no one has sealed the grave.
    function test_itLivesRejectsAtAndAfterDeadline() public {
        uint256 endsAt = _open();
        vm.warp(endsAt);
        vm.expectRevert(MemecoinCemetery.WakeEnded.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        vm.warp(endsAt + 1);
        vm.expectRevert(MemecoinCemetery.WakeEnded.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        cemetery.seal(address(token));
        _assertBuried(endsAt + 1);
    }

    /// @notice Calls without a wake revert both before digging and after cancellation.
    function test_itLivesAndSealRequireWake() public {
        _expectNoWake();
        _open();
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _expectNoWake();
        _assertNone(address(token));
    }

    /// @notice A wake cannot be sealed immediately or one second before its deadline.
    function test_sealRejectsBeforeDeadline() public {
        uint256 endsAt = _open();
        vm.expectRevert(MemecoinCemetery.WakeStillOpen.selector);
        cemetery.seal(address(token));
        vm.warp(endsAt - 1);
        vm.expectRevert(MemecoinCemetery.WakeStillOpen.selector);
        cemetery.seal(address(token));
        _assertWake(endsAt);
        require(cemetery.graveCount() == 0, "early seal counted");
    }

    /// @notice Anyone can seal exactly at the deadline, retaining the original digger and epitaph.
    function test_sealAtDeadlineEmitsAndCountsGrave() public {
        uint256 endsAt = _open();
        vm.warp(endsAt);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Buried(address(token), "Rest in peace", DIGGER, endsAt);
        vm.prank(OTHER);
        cemetery.seal(address(token));
        _assertBuried(endsAt);
        require(cemetery.graveCount() == 1, "grave not counted");
    }

    /// @notice A delayed seal records its actual timestamp, rather than the wake's deadline.
    function test_lateSealRecordsActualSealingTime() public {
        uint256 endsAt = _open();
        uint256 sealedAt = endsAt + 90 days;
        vm.warp(sealedAt);
        _assertWake(endsAt);
        require(cemetery.graveCount() == 0, "automatically buried");
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Buried(address(token), "Rest in peace", DIGGER, sealedAt);
        cemetery.seal(address(token));
        _assertBuried(sealedAt);
    }

    /// @notice A buried record survives repeated operations, changed token reads, and long delays.
    function test_sealedGraveIsPermanentAndCountedOnce() public {
        uint256 endsAt = _open();
        vm.warp(endsAt);
        cemetery.seal(address(token));
        _expectBuriedOperationsRevert();
        vm.warp(endsAt + 3650 days);
        token.setSupply(1000);
        token.setBalance(OTHER, 1000);
        _expectBuriedOperationsRevert();
        _assertBuried(endsAt);
        require(cemetery.graveCount() == 1, "grave counted more than once");
    }

    /// @notice Re-digging waits 30 days from cancellation, not from the original dig or deadline.
    function test_redigCooldownStartsAtCancellationAndAllowsExactBoundary() public {
        uint256 originalEnd = _open();
        uint256 canceledAt = vm.getBlockTimestamp() + 10 days;
        vm.warp(canceledAt);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        uint256 readyAt = canceledAt + PERIOD;
        _expectCooldown();
        vm.warp(originalEnd);
        _expectCooldown();
        vm.warp(readyAt - 1);
        _expectCooldown();
        _assertNone(address(token));
        vm.warp(readyAt);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit WakeOpened(address(token), OTHER, "A second chance", readyAt + PERIOD);
        vm.prank(OTHER);
        cemetery.dig(address(token), "A second chance");
        _assertGrave(cemetery, address(token), MemecoinCemetery.State.Wake, OTHER, "A second chance", readyAt + PERIOD);
        require(cemetery.graveCount() == 0, "re-dig counted");
        vm.warp(readyAt + PERIOD);
        cemetery.seal(address(token));
        _assertGrave(
            cemetery, address(token), MemecoinCemetery.State.Buried, OTHER, "A second chance", readyAt + PERIOD
        );
        require(cemetery.graveCount() == 1, "re-dug grave count");
    }

    /// @notice Each successful resurrection starts its own full cooldown.
    function test_secondResurrectionRestartsCooldown() public {
        _open();
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        vm.warp(vm.getBlockTimestamp() + PERIOD);
        _open();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        uint256 readyAt = vm.getBlockTimestamp() + PERIOD;
        vm.warp(readyAt - 1);
        _expectCooldown();
        vm.warp(readyAt);
        _open();
    }

    /// @notice Wakes, cooldowns, and graves for different tokens remain independent.
    function test_multipleTokensHaveIndependentRecordsAndCounts() public {
        CemeteryTokenMock second = new CemeteryTokenMock(2000);
        CemeteryTokenMock third = new CemeteryTokenMock(0);
        second.setBalance(OTHER, 2);
        uint256 endsAt = _open();
        vm.prank(OTHER);
        cemetery.dig(address(second), "Second");
        cemetery.dig(address(third), "Third");
        vm.prank(OTHER);
        cemetery.itLives(address(second));
        _assertWake(endsAt);
        _assertNone(address(second));
        vm.warp(endsAt);
        cemetery.seal(address(third));
        require(cemetery.graveCount() == 1, "first count");
        _assertWake(endsAt);
        cemetery.seal(address(token));
        require(cemetery.graveCount() == 2, "second count");
        cemetery.dig(address(second), "Second again");
        require(cemetery.graveCount() == 2, "wake counted");
        _assertGrave(cemetery, address(third), MemecoinCemetery.State.Buried, address(this), "Third", endsAt);
    }

    /// @notice Zero addresses, EOAs, and contracts lacking ERC-20 reads cannot be dug.
    function test_digRejectsUnavailableTokenAddresses() public {
        address[3] memory invalid = [address(0), OTHER, address(cemetery)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(MemecoinCemetery.TokenUnavailable.selector);
            cemetery.dig(invalid[i], "Unavailable");
            _assertNone(invalid[i]);
        }
        require(cemetery.graveCount() == 0, "invalid token counted");
    }

    /// @notice A reverting supply read prevents digging without leaving a record or cooldown.
    function test_digCatchesRevertingTotalSupply() public {
        _checkDigReadFailure(1, 0);
    }

    /// @notice A reverting balance read prevents digging even though the digger need not hold tokens.
    function test_digCatchesRevertingBalanceOf() public {
        _checkDigReadFailure(0, 1);
    }

    /// @notice A token may fail after digging; a failed supply read cannot cancel its wake.
    function test_itLivesCatchesRevertingTotalSupply() public {
        _checkObjectionReadFailure(1, 0);
    }

    /// @notice A failed balance read cannot cancel a wake or prevent a later successful objection.
    function test_itLivesCatchesRevertingBalanceOf() public {
        _checkObjectionReadFailure(0, 1);
    }

    /// @notice Empty and truncated responses from either read cannot create a wake.
    function test_digRejectsMalformedTokenResponses() public {
        for (uint8 mode = 2; mode <= 3; ++mode) {
            token.setReadModes(mode, 0);
            vm.expectRevert();
            cemetery.dig(address(token), "Malformed supply");
            _assertNone(address(token));
            token.setReadModes(0, mode);
            vm.expectRevert();
            cemetery.dig(address(token), "Malformed balance");
            _assertNone(address(token));
        }
        token.setReadModes(0, 0);
        _open();
    }

    /// @notice Malformed responses during a wake leave all record fields unchanged.
    function test_itLivesRejectsMalformedTokenResponses() public {
        uint256 endsAt = _open();
        for (uint8 mode = 2; mode <= 3; ++mode) {
            token.setReadModes(mode, 0);
            vm.expectRevert();
            vm.prank(HOLDER);
            cemetery.itLives(address(token));
            _assertWake(endsAt);
            token.setReadModes(0, mode);
            vm.expectRevert();
            vm.prank(HOLDER);
            cemetery.itLives(address(token));
            _assertWake(endsAt);
        }
        token.setReadModes(0, 0);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Token failures after a valid dig do not block permissionless sealing.
    function test_sealDoesNotDependOnTokenReads() public {
        uint256 endsAt = _open();
        token.setReadModes(1, 1);
        vm.warp(endsAt);
        cemetery.seal(address(token));
        _assertBuried(endsAt);
        require(cemetery.graveCount() == 1, "failed token could not be buried");
    }

    /// @notice Both plain ETH transfers and unknown-selector calls with ETH are rejected.
    function test_rejectsPlainEthAndFallbackCalls() public {
        _rejectValue("");
        _rejectValue(hex"deadbeef");
        (bool success,) = address(cemetery).call(hex"deadbeef");
        require(!success, "unknown selector accepted");
        _assertNone(address(token));
    }

    /// @notice An otherwise valid dig rejects attached ETH and does not open a wake.
    function test_digRejectsEth() public {
        _rejectValue(abi.encodeCall(MemecoinCemetery.dig, (address(token), "Paid dig")));
        _assertNone(address(token));
        _open();
    }

    /// @notice An otherwise eligible holder cannot attach ETH to an objection.
    function test_itLivesRejectsEth() public {
        uint256 endsAt = _open();
        token.setBalance(address(this), 1000);
        _rejectValue(abi.encodeCall(MemecoinCemetery.itLives, (address(token))));
        _assertWake(endsAt);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice An otherwise mature wake cannot be sealed with attached ETH.
    function test_sealRejectsEth() public {
        uint256 endsAt = _open();
        vm.warp(endsAt);
        _rejectValue(abi.encodeCall(MemecoinCemetery.seal, (address(token))));
        _assertWake(endsAt);
        require(cemetery.graveCount() == 0, "paid seal counted");
        cemetery.seal(address(token));
        _assertBuried(endsAt);
    }

    /// @notice Read-only entry points also reject ETH.
    function test_viewsRejectEth() public {
        _rejectValue(abi.encodeCall(MemecoinCemetery.graveOf, (address(token))));
        _rejectValue(abi.encodeWithSignature("graveCount()"));
        _rejectValue(abi.encodeWithSignature("WAKE_DURATION()"));
        _rejectValue(abi.encodeWithSignature("REDIG_COOLDOWN()"));
        _rejectValue(abi.encodeWithSignature("MAX_EPITAPH_BYTES()"));
    }

    /// @notice Arbitrary epitaph bytes at valid lengths and arbitrary callers are stored exactly.
    function testFuzz_digPreservesEpitaph(bytes calldata input, address callerSeed) public {
        uint256 length = input.length > 140 ? 140 : input.length;
        string memory epitaph = string(input[:length]);
        address caller = address(uint160(callerSeed) | 1);
        vm.prank(caller);
        cemetery.dig(address(token), epitaph);
        _assertGrave(
            cemetery, address(token), MemecoinCemetery.State.Wake, caller, epitaph, vm.getBlockTimestamp() + PERIOD
        );
        require(cemetery.graveCount() == 0, "fuzz wake counted");
    }

    /// @notice All generated oversized epitaphs revert without changing state.
    function testFuzz_digRejectsOversizedEpitaph(uint8 extraBytes) public {
        string memory epitaph = _epitaph(141 + uint256(extraBytes));
        vm.expectRevert(MemecoinCemetery.EpitaphTooLong.selector);
        cemetery.dig(address(token), epitaph);
        _assertNone(address(token));
        require(cemetery.graveCount() == 0, "oversized epitaph counted");
    }

    /// @notice For every nonzero uint256 supply, the least eligible balance succeeds and one less fails.
    function testFuzz_itLivesThresholdAcrossFullSupplyRange(uint256 supply) public {
        if (supply == 0) supply = 1;
        // ceil(supply / 1000), using a different overflow-safe expression than the implementation.
        uint256 threshold = (supply - 1) / 1000 + 1;
        token.setSupply(supply);
        token.setBalance(HOLDER, threshold - 1);
        uint256 endsAt = _open();
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        token.setBalance(HOLDER, threshold);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Every generated time strictly within the wake rejects sealing and permits objections.
    function testFuzz_wakeTimingBeforeDeadline(uint256 offsetSeed) public {
        uint256 endsAt = _open();
        vm.warp(vm.getBlockTimestamp() + offsetSeed % PERIOD);
        vm.expectRevert(MemecoinCemetery.WakeStillOpen.selector);
        cemetery.seal(address(token));
        _assertWake(endsAt);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @notice Every generated time at or after the deadline rejects objections and permits sealing.
    function testFuzz_wakeTimingAfterDeadline(uint32 delay) public {
        uint256 endsAt = _open();
        uint256 sealedAt = endsAt + uint256(delay);
        vm.warp(sealedAt);
        vm.expectRevert(MemecoinCemetery.WakeEnded.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        cemetery.seal(address(token));
        _assertBuried(sealedAt);
        require(cemetery.graveCount() == 1, "fuzz seal count");
    }

    /// @notice Cooldown boundaries hold regardless of when within the wake cancellation occurs.
    function testFuzz_redigCooldown(uint256 objectionOffset) public {
        _open();
        vm.warp(vm.getBlockTimestamp() + objectionOffset % PERIOD);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        uint256 readyAt = vm.getBlockTimestamp() + PERIOD;
        vm.warp(readyAt - 1);
        _expectCooldown();
        vm.warp(readyAt);
        _open();
    }

    /// @dev Opens the standard wake and independently validates its entire record.
    function _open() private returns (uint256 endsAt) {
        endsAt = vm.getBlockTimestamp() + PERIOD;
        vm.prank(DIGGER);
        cemetery.dig(address(token), "Rest in peace");
        _assertWake(endsAt);
    }

    /// @dev Checks the standard wake's complete record.
    function _assertWake(uint256 endsAt) private view {
        _assertGrave(cemetery, address(token), MemecoinCemetery.State.Wake, DIGGER, "Rest in peace", endsAt);
    }

    /// @dev Checks the standard permanent grave's complete record.
    function _assertBuried(uint256 sealedAt) private view {
        _assertGrave(cemetery, address(token), MemecoinCemetery.State.Buried, DIGGER, "Rest in peace", sealedAt);
    }

    /// @dev Checks the required empty representation, including during cooldown.
    function _assertNone(address tokenAddress) private view {
        _assertGrave(cemetery, tokenAddress, MemecoinCemetery.State.None, address(0), "", 0);
    }

    /// @dev Checks that both wake-only operations reject a nonexistent wake.
    function _expectNoWake() private {
        vm.expectRevert(MemecoinCemetery.NoWake.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        vm.expectRevert(MemecoinCemetery.NoWake.selector);
        cemetery.seal(address(token));
    }

    /// @dev Checks all mutators reject an already buried token.
    function _expectBuriedOperationsRevert() private {
        vm.expectRevert(MemecoinCemetery.GraveExists.selector);
        vm.prank(OTHER);
        cemetery.dig(address(token), "Overwrite");
        vm.expectRevert(MemecoinCemetery.NoWake.selector);
        vm.prank(OTHER);
        cemetery.itLives(address(token));
        vm.expectRevert(MemecoinCemetery.NoWake.selector);
        cemetery.seal(address(token));
    }

    /// @dev Checks cooldown enforcement for both the original digger and a different caller.
    function _expectCooldown() private {
        vm.expectRevert(MemecoinCemetery.CooldownActive.selector);
        vm.prank(DIGGER);
        cemetery.dig(address(token), "Too soon");
        vm.expectRevert(MemecoinCemetery.CooldownActive.selector);
        vm.prank(OTHER);
        cemetery.dig(address(token), "Too soon");
        _assertNone(address(token));
    }

    /// @dev Verifies a reverting read is wrapped and recovery needs no cooldown.
    function _checkDigReadFailure(uint8 supplyMode, uint8 balanceMode) private {
        token.setReadModes(supplyMode, balanceMode);
        vm.expectRevert(MemecoinCemetery.TokenUnavailable.selector);
        cemetery.dig(address(token), "Unavailable");
        _assertNone(address(token));
        require(cemetery.graveCount() == 0, "failed read counted");
        token.setReadModes(0, 0);
        _open();
    }

    /// @dev Verifies failed token reads leave an existing wake intact and retryable.
    function _checkObjectionReadFailure(uint8 supplyMode, uint8 balanceMode) private {
        uint256 endsAt = _open();
        token.setReadModes(supplyMode, balanceMode);
        vm.expectRevert(MemecoinCemetery.TokenUnavailable.selector);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertWake(endsAt);
        require(cemetery.graveCount() == 0, "failed objection counted");
        token.setReadModes(0, 0);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertNone(address(token));
    }

    /// @dev Sends value through a selected entry point and verifies no ETH was retained.
    function _rejectValue(bytes memory data) private {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(cemetery).call{value: 1 wei}(data);
        require(!success, "ETH accepted");
        require(address(cemetery).balance == 0, "ETH retained");
        require(address(this).balance == 1 ether, "ETH lost on rejected call");
    }
}

/// @notice Drives random local calls while maintaining an independent lifecycle model.
/// @dev Expected reverts are checked explicitly so unexpected reverts cannot silently reduce coverage.
contract CemeteryLifecycleHandler is CemeteryTestSupport {
    /// @dev Expected record, including the cooldown which is not exposed by graveOf.
    struct ExpectedGrave {
        /// @dev Expected lifecycle state.
        MemecoinCemetery.State state;
        /// @dev Expected original digger.
        address digger;
        /// @dev Expected epitaph, preserved permanently once buried.
        string epitaph;
        /// @dev Expected wake deadline or sealing time.
        uint256 timestamp;
        /// @dev Earliest next dig after a successful objection.
        uint256 nextDigAt;
    }

    /// @dev Cemetery driven exclusively by this handler during the invariant campaign.
    MemecoinCemetery private immutable _cemetery;
    /// @dev Three independent tokens permit cross-token state and count checks.
    CemeteryTokenMock[3] private _tokens;
    /// @dev Model records are updated only for operations the specification permits.
    ExpectedGrave[3] private _expected;
    /// @dev Model token supplies, kept independent of cemetery reads.
    uint256[3] private _supplies;
    /// @dev Model balances by token and actor.
    uint256[3][3] private _balances;
    /// @dev Whether either required read should fail for each token.
    bool[3] private _readFails;

    /// @notice Creates mock tokens and holders initially at, below, and above the threshold.
    constructor(MemecoinCemetery cemetery) {
        _cemetery = cemetery;
        for (uint256 i; i < 3; ++i) {
            _tokens[i] = new CemeteryTokenMock(1_000_000);
            _supplies[i] = 1_000_000;
            for (uint256 j; j < 3; ++j) {
                uint256 balance = j == 0 ? 1000 : (j == 1 ? 999 : 2000);
                _balances[i][j] = balance;
                _tokens[i].setBalance(_actor(j), balance);
            }
        }
    }

    /// @notice Attempts valid, duplicate, oversized, unavailable, and cooldown-blocked digs.
    function dig(uint256 tokenSeed, uint256 actorSeed, uint8 lengthSeed) external {
        uint256 i = tokenSeed % 3;
        address caller = _actor(actorSeed % 3);
        string memory epitaph = _epitaph(uint256(lengthSeed) % 142);
        ExpectedGrave storage record = _expected[i];
        bytes4 expectedError;
        if (bytes(epitaph).length > 140) expectedError = MemecoinCemetery.EpitaphTooLong.selector;
        else if (record.state != MemecoinCemetery.State.None) expectedError = MemecoinCemetery.GraveExists.selector;
        else if (vm.getBlockTimestamp() < record.nextDigAt) expectedError = MemecoinCemetery.CooldownActive.selector;
        else if (_readFails[i]) expectedError = MemecoinCemetery.TokenUnavailable.selector;

        _call(caller, abi.encodeCall(MemecoinCemetery.dig, (address(_tokens[i]), epitaph)), expectedError);
        if (expectedError == bytes4(0)) {
            record.state = MemecoinCemetery.State.Wake;
            record.digger = caller;
            record.epitaph = epitaph;
            record.timestamp = vm.getBlockTimestamp() + 30 days;
        }
    }

    /// @notice Attempts objections using current modeled supply, balance, and read availability.
    function itLives(uint256 tokenSeed, uint256 actorSeed) external {
        uint256 i = tokenSeed % 3;
        uint256 j = actorSeed % 3;
        ExpectedGrave storage record = _expected[i];
        bytes4 expectedError;
        if (record.state != MemecoinCemetery.State.Wake) {
            expectedError = MemecoinCemetery.NoWake.selector;
        } else if (vm.getBlockTimestamp() >= record.timestamp) {
            expectedError = MemecoinCemetery.WakeEnded.selector;
        } else if (_readFails[i]) {
            expectedError = MemecoinCemetery.TokenUnavailable.selector;
        } else if (_supplies[i] == 0 || _balances[i][j] < (_supplies[i] - 1) / 1000 + 1) {
            expectedError = MemecoinCemetery.InsufficientBalance.selector;
        }

        _call(_actor(j), abi.encodeCall(MemecoinCemetery.itLives, (address(_tokens[i]))), expectedError);
        if (expectedError == bytes4(0)) {
            delete _expected[i];
            _expected[i].nextDigAt = vm.getBlockTimestamp() + 30 days;
        }
    }

    /// @notice Attempts early, mature, absent, and repeated seals from arbitrary modeled actors.
    function seal(uint256 tokenSeed, uint256 actorSeed) external {
        uint256 i = tokenSeed % 3;
        ExpectedGrave storage record = _expected[i];
        bytes4 expectedError;
        if (record.state != MemecoinCemetery.State.Wake) expectedError = MemecoinCemetery.NoWake.selector;
        else if (vm.getBlockTimestamp() < record.timestamp) expectedError = MemecoinCemetery.WakeStillOpen.selector;

        _call(_actor(actorSeed % 3), abi.encodeCall(MemecoinCemetery.seal, (address(_tokens[i]))), expectedError);
        if (expectedError == bytes4(0)) {
            record.state = MemecoinCemetery.State.Buried;
            record.timestamp = vm.getBlockTimestamp();
        }
    }

    /// @notice Advances time by up to 40 days so sequences cross wakes and cooldowns.
    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + secondsSeed % (40 days + 1));
    }

    /// @notice Changes current supply and one holder's balance, emphasizing both threshold edges.
    function setHoldings(uint256 tokenSeed, uint256 actorSeed, uint256 supply, uint256 balanceSeed) external {
        uint256 i = tokenSeed % 3;
        uint256 j = actorSeed % 3;
        uint256 threshold = supply == 0 ? 0 : (supply - 1) / 1000 + 1;
        uint256 balance;
        if (balanceSeed % 3 == 0) balance = threshold;
        else if (balanceSeed % 3 == 1) balance = threshold == 0 ? 0 : threshold - 1;
        else balance = supply == type(uint256).max ? balanceSeed : balanceSeed % (supply + 1);
        _supplies[i] = supply;
        _balances[i][j] = balance;
        _tokens[i].setSupply(supply);
        _tokens[i].setBalance(_actor(j), balance);
    }

    /// @notice Enables and disables supply and balance failures during arbitrary lifecycle stages.
    function setReadFailures(uint256 tokenSeed, bool supplyFails, bool balanceFails) external {
        uint256 i = tokenSeed % 3;
        _readFails[i] = supplyFails || balanceFails;
        _tokens[i].setReadModes(supplyFails ? 1 : 0, balanceFails ? 1 : 0);
    }

    /// @notice Checks all records, permanent grave contents, aggregate count, and lack of collected ETH.
    function assertModel() external view {
        uint256 buried;
        for (uint256 i; i < 3; ++i) {
            ExpectedGrave storage record = _expected[i];
            _assertGrave(_cemetery, address(_tokens[i]), record.state, record.digger, record.epitaph, record.timestamp);
            if (record.state == MemecoinCemetery.State.Buried) ++buried;
        }
        require(_cemetery.graveCount() == buried, "grave count differs from model");
        require(address(_cemetery).balance == 0, "cemetery collected ETH");
    }

    /// @dev Executes a modeled call and verifies both success and the exact expected failure.
    function _call(address caller, bytes memory data, bytes4 expectedError) private {
        vm.prank(caller);
        (bool success, bytes memory result) = address(_cemetery).call(data);
        if (expectedError == bytes4(0)) {
            require(success, "valid model action unexpectedly reverted");
        } else {
            require(!success, "invalid model action unexpectedly succeeded");
            require(result.length == 4 && bytes4(result) == expectedError, "wrong model action error");
        }
    }

    /// @dev Returns a distinct nonzero local actor for each bounded index.
    function _actor(uint256 index) private pure returns (address) {
        return address(uint160(0xA100 + index));
    }
}

/// @notice Random call sequences must agree with the lifecycle model after every operation.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract MemecoinCemeteryInvariantTest is CemeteryTestSupport {
    /// @dev Model handler; direct calls to mocks are excluded from the fuzz targets.
    CemeteryLifecycleHandler private _handler;

    /// @notice Initializes isolated state for the lifecycle campaign.
    function setUp() public {
        vm.warp(1_700_000_000);
        _handler = new CemeteryLifecycleHandler(new MemecoinCemetery());
    }

    /// @notice Supplies Foundry's invariant target hook without requiring forge-std.
    /// @return targets Only the lifecycle handler may receive random calls.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(_handler);
    }

    /// @notice No random sequence may reopen a grave, corrupt a record, or miscount burials.
    function invariant_recordsAndCountsMatchLifecycleModel() public view {
        _handler.assertModel();
    }
}
