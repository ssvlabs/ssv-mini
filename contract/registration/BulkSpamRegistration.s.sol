pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {SSVNetwork} from "src/SSVNetwork.sol";
import {ISSVNetworkCore} from "src/interfaces/ISSVNetworkCore.sol";
import {console2} from "forge-std/console2.sol";

contract BulkSpamRegistration is Script {

    SSVNetwork public ssvNetwork;
    
    // Minimal deposit amount for spam registration
    uint256 constant SPAM_DEPOSIT_AMOUNT = 0.1 ether;

    function run(
        address ssvNetworkAddress, 
        bytes[] memory publicKeys, 
        uint64[] memory operatorIds,
        uint256 batchNumber,
        uint256 targetEventsPerBlock
    ) external {
        ssvNetwork = SSVNetwork(ssvNetworkAddress);
        
        vm.startBroadcast();
        
        uint256 startTime = block.timestamp;
        uint256 startBlock = block.number;
        
        console2.log("=== BULK SPAM REGISTRATION BATCH", batchNumber, "===");
        console2.log("Starting at block:", startBlock);
        console2.log("Timestamp:", startTime);
        console2.log("Registering", publicKeys.length, "fake validators");
        console2.log("Target events per block:", targetEventsPerBlock);
        
        // Create fake shares data for each validator
        bytes[] memory fakeSharesData = new bytes[](publicKeys.length);
        for (uint256 i = 0; i < publicKeys.length; i++) {
            // Generate minimal fake shares data (this won't be used for actual validation)
            fakeSharesData[i] = abi.encodePacked(
                bytes32(uint256(keccak256(abi.encodePacked(publicKeys[i], block.timestamp, i)))),
                bytes32(uint256(keccak256(abi.encodePacked(publicKeys[i], block.number, i))))
            );
        }
        
        // Create an empty cluster for spam registration
        ISSVNetworkCore.Cluster memory cluster;
        cluster.validatorCount = 0;
        cluster.networkFeeIndex = 0;
        cluster.index = 0;
        cluster.active = true;
        cluster.balance = 0;
        
        // Register validators in batches to control events per block
        uint256 validatorsPerTx = targetEventsPerBlock > 0 ? targetEventsPerBlock : publicKeys.length;
        uint256 totalProcessed = 0;
        
        while (totalProcessed < publicKeys.length) {
            uint256 batchSize = validatorsPerTx;
            if (totalProcessed + batchSize > publicKeys.length) {
                batchSize = publicKeys.length - totalProcessed;
            }
            
            // Create arrays for this batch
            bytes[] memory batchPublicKeys = new bytes[](batchSize);
            bytes[] memory batchSharesData = new bytes[](batchSize);
            
            for (uint256 i = 0; i < batchSize; i++) {
                batchPublicKeys[i] = publicKeys[totalProcessed + i];
                batchSharesData[i] = fakeSharesData[totalProcessed + i];
            }
            
            try ssvNetwork.bulkRegisterValidator(
                batchPublicKeys,
                operatorIds,
                batchSharesData,
                SPAM_DEPOSIT_AMOUNT,
                cluster
            ) {
                console2.log("Successfully registered batch of", batchSize, "validators at block", block.number);
                totalProcessed += batchSize;
            } catch Error(string memory reason) {
                console2.log("Batch registration failed:", reason);
                console2.log("Continuing with reduced batch size...");
                
                // Try with smaller batch size
                if (batchSize > 1) {
                    validatorsPerTx = batchSize / 2;
                } else {
                    console2.log("Cannot register validator at index:", totalProcessed);
                    totalProcessed += 1; // Skip this validator
                }
            }
        }
        
        uint256 endTime = block.timestamp;
        uint256 endBlock = block.number;
        uint256 blocksUsed = endBlock - startBlock;
        uint256 timeElapsed = endTime - startTime;
        
        console2.log("=== BATCH", batchNumber, "COMPLETION STATS ===");
        console2.log("End block:", endBlock);
        console2.log("Blocks used:", blocksUsed);
        console2.log("Time elapsed (seconds):", timeElapsed);
        console2.log("Total validators registered:", publicKeys.length);
        
        if (blocksUsed > 0) {
            console2.log("Average events per block:", publicKeys.length / blocksUsed);
        }
        
        vm.stopBroadcast();
    }
} 