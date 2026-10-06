// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The ERC-20 reads required to open or object to a wake.
interface ICemeteryToken {
    /// @notice Returns the current token supply in its smallest units.
    /// @return supply The current total supply.
    function totalSupply() external view returns (uint256 supply);

    /// @notice Returns an account's current balance in the token's smallest units.
    /// @param account The account to query.
    /// @return balance The account's current balance.
    function balanceOf(address account) external view returns (uint256 balance);
}

/// @title Memecoin Cemetery
/// @notice Anyone may propose a token's burial; a holder of at least 0.1% may object during its wake.
/// @dev Tokenless, fee-free and immutable, with no owner or privileged callers. All entry points
/// are nonpayable, and there is no receive or fallback function. Token reads use STATICCALL,
/// so a token cannot reenter to change cemetery state. Eligibility trusts the token's current
/// reported supply and balance; holdings are neither locked nor checked historically.
contract MemecoinCemetery {
    /// @notice The lifecycle of a token's record, with None also used during a re-dig cooldown.
    enum State {
        None,
        Wake,
        Buried
    }

    /// @notice A wake or permanent grave, keyed by token address.
    struct Grave {
        /// @notice The record's lifecycle state.
        State state;
        /// @notice The account that opened this wake.
        address digger;
        /// @notice The epitaph supplied when the wake opened.
        string epitaph;
        /// @notice The wake deadline in Wake, or the sealing timestamp in Buried.
        uint256 timestamp;
    }

    /// @notice The duration during which holders may object to a burial.
    uint256 public constant WAKE_DURATION = 30 days;

    /// @notice The minimum delay from a successful objection until a new wake may open.
    uint256 public constant REDIG_COOLDOWN = 30 days;

    /// @notice The maximum epitaph length, measured in bytes rather than characters.
    uint256 public constant MAX_EPITAPH_BYTES = 140;

    /// @notice The number of permanently sealed graves; open and canceled wakes do not count.
    uint256 public graveCount;

    /// @dev At most one record exists per token; a Buried record is never modified.
    mapping(address token => Grave grave) private _graves;

    /// @dev Earliest re-dig time after an objection, stored separately from the cleared record.
    mapping(address token => uint256 timestamp) private _nextDigAt;

    /// @notice A token has begun a wake.
    /// @param token The proposed burial's token address.
    /// @param digger The account that opened the wake.
    /// @param epitaph The proposed epitaph.
    /// @param endsAt The first timestamp at which sealing is allowed and objections are closed.
    event WakeOpened(address indexed token, address indexed digger, string epitaph, uint256 endsAt);

    /// @notice An eligible holder canceled a wake and started the re-dig cooldown.
    /// @param token The token whose wake was canceled.
    /// @param holder The account that successfully objected.
    event Resurrected(address indexed token, address indexed holder);

    /// @notice An unopposed wake has become a permanent grave.
    /// @param token The buried token.
    /// @param epitaph The epitaph recorded when the wake opened.
    /// @param digger The account that originally opened the wake.
    /// @param sealedAt The timestamp of sealing, which may be later than the wake deadline.
    event Buried(address indexed token, string epitaph, address indexed digger, uint256 sealedAt);

    /// @notice The token has no deployed code or a required token read reverted.
    error TokenUnavailable();

    /// @notice The epitaph exceeds the maximum byte length.
    error EpitaphTooLong();

    /// @notice This token already has a wake or a permanent grave.
    error GraveExists();

    /// @notice Thirty days have not elapsed since the last successful objection.
    error CooldownActive();

    /// @notice This token has no wake to object to or seal.
    error NoWake();

    /// @notice The objection window has ended.
    error WakeEnded();

    /// @notice The wake deadline has not yet arrived.
    error WakeStillOpen();

    /// @notice The supply is zero or the caller holds less than 0.1% of the current supply.
    error InsufficientBalance();

    /// @notice Opens a 30-day wake for a token that has no wake or grave and is out of cooldown.
    /// @dev Both token reads must succeed, even though the digger need not hold any tokens.
    /// A zero-supply token may be dug. Empty epitaphs are allowed.
    /// @param token The ERC-20 token to commemorate.
    /// @param epitaph The epitaph, limited to 140 bytes.
    function dig(address token, string calldata epitaph) external {
        if (bytes(epitaph).length > MAX_EPITAPH_BYTES) revert EpitaphTooLong();
        if (_graves[token].state != State.None) revert GraveExists();
        if (block.timestamp < _nextDigAt[token]) revert CooldownActive();

        _readToken(token, msg.sender);

        uint256 endsAt = block.timestamp + WAKE_DURATION;
        _graves[token] = Grave(State.Wake, msg.sender, epitaph, endsAt);
        emit WakeOpened(token, msg.sender, epitaph, endsAt);
    }

    /// @notice Cancels a wake when the caller currently holds at least 0.1% of the token supply.
    /// @dev Allowed strictly before the deadline. Uses a rounded-up threshold so a fractional
    /// token unit cannot grant eligibility, without multiplying values that could overflow.
    /// A zero-supply token has no eligible holders. Cancellation clears the record and starts
    /// a fresh 30-day cooldown from this transaction's timestamp.
    /// @param token The token whose burial the caller objects to.
    function itLives(address token) external {
        Grave storage grave = _graves[token];
        if (grave.state != State.Wake) revert NoWake();
        if (block.timestamp >= grave.timestamp) revert WakeEnded();

        (uint256 supply, uint256 balance) = _readToken(token, msg.sender);
        uint256 minimumBalance = supply / 1000 + (supply % 1000 == 0 ? 0 : 1);
        if (supply == 0 || balance < minimumBalance) revert InsufficientBalance();

        delete _graves[token];
        _nextDigAt[token] = block.timestamp + REDIG_COOLDOWN;
        emit Resurrected(token, msg.sender);
    }

    /// @notice Permanently seals an unopposed wake at or after its deadline; anyone may call.
    /// @dev Does not read the token, so later token failures cannot prevent sealing. A sealed
    /// grave cannot be reopened, canceled or sealed again, and is counted exactly once.
    /// @param token The token whose wake is to be sealed.
    function seal(address token) external {
        Grave storage grave = _graves[token];
        if (grave.state != State.Wake) revert NoWake();
        if (block.timestamp < grave.timestamp) revert WakeStillOpen();

        grave.state = State.Buried;
        grave.timestamp = block.timestamp;
        ++graveCount;
        emit Buried(token, grave.epitaph, grave.digger, block.timestamp);
    }

    /// @notice Returns a token's current wake or grave.
    /// @dev A missing or canceled wake returns (None, address(0), "", 0), including in cooldown.
    /// An expired, unsealed wake stays in Wake until someone calls seal.
    /// @param token The token to query.
    /// @return state None, Wake or Buried.
    /// @return digger The account that opened the current wake or grave.
    /// @return epitaph The recorded epitaph.
    /// @return timestamp The wake deadline or actual sealing time, according to state.
    function graveOf(address token)
        external
        view
        returns (State state, address digger, string memory epitaph, uint256 timestamp)
    {
        Grave storage grave = _graves[token];
        return (grave.state, grave.digger, grave.epitaph, grave.timestamp);
    }

    /// @dev Reads both ERC-20 values with try/catch. Invalid ABI responses also revert the call,
    /// leaving cemetery state untouched. View calls enforce read-only execution in the token.
    /// @param token The deployed token contract to query.
    /// @param account The account whose balance should be read.
    /// @return supply The token's current reported supply.
    /// @return balance The account's current reported balance.
    function _readToken(address token, address account) private view returns (uint256 supply, uint256 balance) {
        if (token.code.length == 0) revert TokenUnavailable();
        try ICemeteryToken(token).totalSupply() returns (uint256 value) {
            supply = value;
        } catch {
            revert TokenUnavailable();
        }
        try ICemeteryToken(token).balanceOf(account) returns (uint256 value) {
            balance = value;
        } catch {
            revert TokenUnavailable();
        }
    }
}
