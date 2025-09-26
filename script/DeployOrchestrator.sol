// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Orchestrator} from "../src/Orchestrator.sol";

contract DeployOrchestrator is Script {
    function run() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("HEDERA_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        Orchestrator orchestrator = new Orchestrator();

        vm.stopBroadcast();

        console.log("Orchestrator deployed to:", address(orchestrator));

        return address(orchestrator);
    }
}
