// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/FeedlingAppAuth.sol";

/// Publish a new compose_hash authorization on an already-deployed
/// FeedlingAppAuth contract. Used as part of every release — the new hash
/// must be authorized on-chain before the CVM can derive its keys.
///
/// Env:
///   PRIVATE_KEY                 — owner key, broadcasts
///   FEEDLING_APP_AUTH_CONTRACT  — already-deployed contract address
///   FEEDLING_COMPOSE_HASH       — 0x-prefixed 32-byte hex of the compose_hash
///   FEEDLING_GIT_COMMIT         — source git commit for this release
///   FEEDLING_COMPOSE_YAML_URL   — github raw URL pinned to that commit
///
/// Usage (see deploy/publish-compose-hash.sh for the wrapping helper):
///   forge script script/AddComposeHash.s.sol --rpc-url $RPC --broadcast
contract AddComposeHash is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address contractAddr = vm.envAddress("FEEDLING_APP_AUTH_CONTRACT");
        bytes32 composeHash = vm.envBytes32("FEEDLING_COMPOSE_HASH");
        string memory gitCommit = vm.envString("FEEDLING_GIT_COMMIT");
        string memory yamlUrl = vm.envString("FEEDLING_COMPOSE_YAML_URL");

        FeedlingAppAuth auth = FeedlingAppAuth(contractAddr);

        // Idempotency: if already approved, log and exit successfully. Makes
        // the publish workflow safe to retry.
        if (auth.isAppAllowed(composeHash)) {
            console2.log("compose_hash already approved, nothing to do:");
            console2.logBytes32(composeHash);
            return;
        }

        vm.startBroadcast(deployerKey);
        auth.addComposeHash(composeHash, gitCommit, yamlUrl);
        vm.stopBroadcast();

        console2.log("compose_hash added:");
        console2.logBytes32(composeHash);
        console2.log("git_commit:", gitCommit);
        console2.log("compose_yaml_url:", yamlUrl);
    }
}
