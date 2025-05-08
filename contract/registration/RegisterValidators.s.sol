pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {SSVNetwork} from "src/SSVNetwork.sol";
import {ISSVNetworkCore} from "src/interfaces/ISSVNetworkCore.sol";
import {console2} from "forge-std/console2.sol";

contract RegisterValidator is Script {

  SSVNetwork public ssvNetwork;
  
  // Initial deposit amount (adjust as needed)
  uint256 constant DEPOSIT_AMOUNT = 1 ether;

  function run(address ssvNetworkAddress, bytes[] memory publicKeys, bytes[] memory sharesDatas, uint64[] memory operatorIds) external {
    ssvNetwork = SSVNetwork(ssvNetworkAddress);
    
    vm.startBroadcast();
    
    // Create an empty cluster
    ISSVNetworkCore.Cluster memory cluster;
    cluster.validatorCount = 0;
    cluster.networkFeeIndex = 0;
    cluster.index = 0;
    cluster.active = true;
    cluster.balance = 0;
    
    ssvNetwork.bulkRegisterValidator(
      publicKeys,
      operatorIds,
      sharesDatas,
      DEPOSIT_AMOUNT,
      cluster
    );
    
    console2.log("Successfully registered validator");
    
    vm.stopBroadcast();
  }
}
