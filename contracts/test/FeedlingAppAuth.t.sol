// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeedlingAppAuth.sol";

contract FeedlingAppAuthTest is Test {
    FeedlingAppAuth internal auth;

    address internal deployer = address(0xDEAD);
    address internal stranger = address(0xBEEF);

    bytes32 internal hashA = keccak256("compose-A");
    bytes32 internal hashB = keccak256("compose-B");

    string internal gitA = "abc123";
    string internal gitB = "def456";
    string internal uriA = "https://github.com/Account-Link/feedling-mcp-v1/raw/abc123/deploy/docker-compose.yaml";
    string internal uriB = "https://github.com/Account-Link/feedling-mcp-v1/raw/def456/deploy/docker-compose.yaml";

    event ComposeHashAdded(
        bytes32 indexed composeHash,
        string gitCommit,
        string composeYamlURI,
        uint64 approvedAt
    );

    event ComposeHashRevoked(bytes32 indexed composeHash, uint64 revokedAt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        vm.prank(deployer);
        auth = new FeedlingAppAuth(deployer);
    }

    // ----------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------

    function test_constructor_sets_owner_and_emits() public {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(0), deployer);
        FeedlingAppAuth fresh = new FeedlingAppAuth(deployer);
        assertEq(fresh.owner(), deployer);
    }

    function test_constructor_rejects_zero_owner() public {
        vm.expectRevert(FeedlingAppAuth.ZeroAddress.selector);
        new FeedlingAppAuth(address(0));
    }

    // ----------------------------------------------------------------
    // addComposeHash — happy path
    // ----------------------------------------------------------------

    function test_addComposeHash_marks_approved_and_emits() public {
        vm.warp(1_700_000_000);

        vm.expectEmit(true, false, false, true);
        emit ComposeHashAdded(hashA, gitA, uriA, uint64(1_700_000_000));

        vm.prank(deployer);
        auth.addComposeHash(hashA, gitA, uriA);

        assertTrue(auth.isAppAllowed(hashA));
        (
            bytes32 h,
            bool approved,
            uint64 approvedAt,
            uint64 revokedAt,
            string memory git,
            string memory uri
        ) = auth.getRelease(0);
        assertEq(h, hashA);
        assertTrue(approved);
        assertEq(approvedAt, 1_700_000_000);
        assertEq(revokedAt, 0);
        assertEq(git, gitA);
        assertEq(uri, uriA);
    }

    function test_addComposeHash_appends_to_release_order() public {
        vm.prank(deployer); auth.addComposeHash(hashA, gitA, uriA);
        vm.prank(deployer); auth.addComposeHash(hashB, gitB, uriB);
        assertEq(auth.releaseCount(), 2);
    }

    // ----------------------------------------------------------------
    // addComposeHash — access control
    // ----------------------------------------------------------------

    function test_addComposeHash_reverts_when_not_owner() public {
        vm.prank(stranger);
        vm.expectRevert(FeedlingAppAuth.NotOwner.selector);
        auth.addComposeHash(hashA, gitA, uriA);
    }

    function test_addComposeHash_reverts_on_zero_hash() public {
        vm.prank(deployer);
        vm.expectRevert(FeedlingAppAuth.ZeroHash.selector);
        auth.addComposeHash(bytes32(0), gitA, uriA);
    }

    function test_addComposeHash_reverts_on_empty_gitCommit() public {
        vm.prank(deployer);
        vm.expectRevert(FeedlingAppAuth.EmptyString.selector);
        auth.addComposeHash(hashA, "", uriA);
    }

    function test_addComposeHash_reverts_on_empty_uri() public {
        vm.prank(deployer);
        vm.expectRevert(FeedlingAppAuth.EmptyString.selector);
        auth.addComposeHash(hashA, gitA, "");
    }

    function test_addComposeHash_reverts_on_double_approve() public {
        vm.prank(deployer); auth.addComposeHash(hashA, gitA, uriA);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(FeedlingAppAuth.AlreadyApproved.selector, hashA));
        auth.addComposeHash(hashA, gitA, uriA);
    }

    // ----------------------------------------------------------------
    // revoke
    // ----------------------------------------------------------------

    function test_revoke_flips_isAppAllowed_and_emits() public {
        vm.prank(deployer); auth.addComposeHash(hashA, gitA, uriA);
        vm.warp(1_700_000_500);

        vm.expectEmit(true, false, false, true);
        emit ComposeHashRevoked(hashA, uint64(1_700_000_500));

        vm.prank(deployer); auth.revoke(hashA);
        assertFalse(auth.isAppAllowed(hashA));

        (,bool approved,, uint64 revokedAt,,) = auth.getRelease(0);
        assertFalse(approved);
        assertEq(revokedAt, 1_700_000_500);
    }

    function test_revoke_reverts_when_not_owner() public {
        vm.prank(deployer); auth.addComposeHash(hashA, gitA, uriA);
        vm.prank(stranger);
        vm.expectRevert(FeedlingAppAuth.NotOwner.selector);
        auth.revoke(hashA);
    }

    function test_revoke_reverts_when_not_approved() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(FeedlingAppAuth.NotApproved.selector, hashA));
        auth.revoke(hashA);
    }

    function test_revoke_then_reapprove_keeps_order_slot() public {
        vm.prank(deployer); auth.addComposeHash(hashA, gitA, uriA);
        vm.prank(deployer); auth.addComposeHash(hashB, gitB, uriB);
        vm.prank(deployer); auth.revoke(hashA);

        assertFalse(auth.isAppAllowed(hashA));
        assertEq(auth.releaseCount(), 2);

        // Re-approve the same hash — should not append a duplicate
        vm.prank(deployer); auth.addComposeHash(hashA, gitA, uriA);
        assertTrue(auth.isAppAllowed(hashA));
        assertEq(auth.releaseCount(), 2);
    }

    // ----------------------------------------------------------------
    // Ownership transfer
    // ----------------------------------------------------------------

    function test_transferOwnership_moves_power() public {
        address newOwner = address(0xCAFE);

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(deployer, newOwner);
        vm.prank(deployer); auth.transferOwnership(newOwner);
        assertEq(auth.owner(), newOwner);

        // Old owner loses power
        vm.prank(deployer);
        vm.expectRevert(FeedlingAppAuth.NotOwner.selector);
        auth.addComposeHash(hashA, gitA, uriA);

        // New owner can write
        vm.prank(newOwner);
        auth.addComposeHash(hashA, gitA, uriA);
        assertTrue(auth.isAppAllowed(hashA));
    }

    function test_transferOwnership_rejects_zero() public {
        vm.prank(deployer);
        vm.expectRevert(FeedlingAppAuth.ZeroAddress.selector);
        auth.transferOwnership(address(0));
    }

    function test_transferOwnership_reverts_when_not_owner() public {
        vm.prank(stranger);
        vm.expectRevert(FeedlingAppAuth.NotOwner.selector);
        auth.transferOwnership(address(0xCAFE));
    }

    // ----------------------------------------------------------------
    // Read — unauthorized hashes default to false
    // ----------------------------------------------------------------

    function test_isAppAllowed_false_for_unknown_hash() public view {
        assertFalse(auth.isAppAllowed(hashA));
        assertFalse(auth.isAppAllowed(bytes32(0)));
    }

    // ----------------------------------------------------------------
    // Fuzz
    // ----------------------------------------------------------------

    function testFuzz_arbitrary_hash_not_allowed_unless_added(bytes32 h) public view {
        assertFalse(auth.isAppAllowed(h));
    }

    function testFuzz_addThenCheck(bytes32 h) public {
        vm.assume(h != bytes32(0));
        vm.prank(deployer);
        auth.addComposeHash(h, "commit", "https://example/compose.yaml");
        assertTrue(auth.isAppAllowed(h));
    }
}
