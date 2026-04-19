// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/FeedlingAppAuth.sol";

/// Deploy FeedlingAppAuth. Set FEEDLING_APP_AUTH_OWNER env var to the EOA
/// that should own the contract (the Feedling release key). If unset, uses
/// the broadcaster itself (fine for localnet / sepolia test runs).
///
/// Usage:
///   forge script script/DeployFeedlingAppAuth.s.sol --rpc-url $RPC --broadcast
contract DeployFeedlingAppAuth is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envOr("FEEDLING_APP_AUTH_OWNER", vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        FeedlingAppAuth auth = new FeedlingAppAuth(owner);
        vm.stopBroadcast();

        console2.log("FeedlingAppAuth deployed at:", address(auth));
        console2.log("Owner:", owner);
    }
}
