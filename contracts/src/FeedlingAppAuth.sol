// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FeedlingAppAuth
/// @notice On-chain whitelist of authorized compose_hash values for the
/// Feedling TDX enclave. Queried by dstack's KMS at key-release time; also
/// read by iOS for audit-card enrichment.
///
/// Design reference: docs/DESIGN_E2E.md §7.3, §12.10, §12.14
/// Pattern lifted from: amiller/dstack-tutorial/05-onchain-authorization
///
/// v1: single-EOA owner, no timelock, no multisig. Upgrade paths are
/// deliberately left open — a later contract revision can add
/// `activatesAt` for timelocks or swap `owner` for a multisig address.
contract FeedlingAppAuth {
    // ----------------------------------------------------------------
    // Types
    // ----------------------------------------------------------------

    /// One record per deployment. `approved=false` marks a revoked hash;
    /// we keep the row around so history is reconstructable from state
    /// alone (events are the primary audit trail, state is belt-and-suspenders).
    struct ReleaseEntry {
        bool approved;
        uint64 approvedAt;
        uint64 revokedAt;          // 0 while still approved
        string gitCommit;
        string composeYamlURI;     // github.com raw URL pinned to gitCommit
    }

    // ----------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------

    address public owner;
    mapping(bytes32 => ReleaseEntry) public releases;

    // Ordered list so iOS can walk history without scanning all logs if it
    // wants a simpler code path. Events remain the canonical source of truth.
    bytes32[] public releaseOrder;

    // ----------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------

    event ComposeHashAdded(
        bytes32 indexed composeHash,
        string gitCommit,
        string composeYamlURI,
        uint64 approvedAt
    );

    event ComposeHashRevoked(
        bytes32 indexed composeHash,
        uint64 revokedAt
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ----------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------

    error NotOwner();
    error AlreadyApproved(bytes32 composeHash);
    error NotApproved(bytes32 composeHash);
    error ZeroHash();
    error ZeroAddress();
    error EmptyString();

    // ----------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ----------------------------------------------------------------
    // Write path (owner only)
    // ----------------------------------------------------------------

    /// Authorize a new compose_hash. DstackKms will begin releasing keys
    /// to CVMs running this hash on next query.
    function addComposeHash(
        bytes32 composeHash,
        string calldata gitCommit,
        string calldata composeYamlURI
    ) external onlyOwner {
        if (composeHash == bytes32(0)) revert ZeroHash();
        if (bytes(gitCommit).length == 0) revert EmptyString();
        if (bytes(composeYamlURI).length == 0) revert EmptyString();

        ReleaseEntry storage entry = releases[composeHash];
        if (entry.approved) revert AlreadyApproved(composeHash);

        // Fresh approval — whether or not this hash was seen before.
        entry.approved = true;
        entry.approvedAt = uint64(block.timestamp);
        entry.revokedAt = 0;
        entry.gitCommit = gitCommit;
        entry.composeYamlURI = composeYamlURI;

        // Append to order list only the first time we see this hash; re-approval
        // of a previously-revoked hash keeps its original position.
        if (!_inOrderList(composeHash)) {
            releaseOrder.push(composeHash);
        }

        emit ComposeHashAdded(composeHash, gitCommit, composeYamlURI, entry.approvedAt);
    }

    /// Revoke a compose_hash. DstackKms will stop releasing keys to CVMs
    /// running it. Existing running CVMs keep their previously-derived keys
    /// until they restart.
    function revoke(bytes32 composeHash) external onlyOwner {
        ReleaseEntry storage entry = releases[composeHash];
        if (!entry.approved) revert NotApproved(composeHash);
        entry.approved = false;
        entry.revokedAt = uint64(block.timestamp);
        emit ComposeHashRevoked(composeHash, entry.revokedAt);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    // ----------------------------------------------------------------
    // Read path (anyone — DstackKms, iOS, any auditor)
    // ----------------------------------------------------------------

    /// Called by DstackKms before releasing keys to a CVM whose quote
    /// contains `composeHash` in RTMR3. Must be cheap; this is on the hot
    /// path for enclave startup.
    function isAppAllowed(bytes32 composeHash) external view returns (bool) {
        return releases[composeHash].approved;
    }

    function releaseCount() external view returns (uint256) {
        return releaseOrder.length;
    }

    /// Returns the entries in the order they were first added.
    function getRelease(uint256 index) external view returns (
        bytes32 composeHash,
        bool approved,
        uint64 approvedAt,
        uint64 revokedAt,
        string memory gitCommit,
        string memory composeYamlURI
    ) {
        composeHash = releaseOrder[index];
        ReleaseEntry storage e = releases[composeHash];
        return (composeHash, e.approved, e.approvedAt, e.revokedAt, e.gitCommit, e.composeYamlURI);
    }

    // ----------------------------------------------------------------
    // Internals
    // ----------------------------------------------------------------

    function _inOrderList(bytes32 composeHash) internal view returns (bool) {
        // Linear scan is fine — the order list grows by 1 per release and we
        // only hit this path inside addComposeHash (owner-gated, rare).
        uint256 len = releaseOrder.length;
        for (uint256 i = 0; i < len; i++) {
            if (releaseOrder[i] == composeHash) return true;
        }
        return false;
    }
}
