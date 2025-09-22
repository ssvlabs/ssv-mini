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


//// script/register-validator/RegisterValidators.s.sol
//// SPDX-License-Identifier: UNLICENSED
//pragma solidity 0.8.24;
//
//import {Script} from "forge-std/Script.sol";
//import "forge-std/StdJson.sol";
//import {SSVNetwork} from "src/SSVNetwork.sol";
//import {ISSVNetworkCore} from "src/interfaces/ISSVNetworkCore.sol";
//import {console2} from "forge-std/console2.sol";
//
//contract RegisterValidator is Script {
//    using stdJson for string;
//
//    uint256 constant DEPOSIT_AMOUNT = 1 ether;
//
//    function run() external {
//        address ssvNetworkAddress = vm.envAddress("SSV_NETWORK_ADDRESS");
//        SSVNetwork ssvNetwork = SSVNetwork(ssvNetworkAddress);
//
//        // Read the three flat arrays produced by the bash script
//        string memory pkJson = vm.readFile(vm.envString("PUBKEYS_JSON"));  // ["0x..","0x..",...]
//        string memory sdJson = vm.readFile(vm.envString("SHARES_JSON"));   // ["0x..","0x..",...]
//        string memory opJson = vm.readFile(vm.envString("OPIDS_JSON"));    // [1,2,3,4]
//
//        bytes[] memory publicKeys  = abi.decode(vm.parseJson(pkJson), (bytes[]));
//        bytes[] memory sharesDatas = abi.decode(vm.parseJson(sdJson), (bytes[]));
//
//        uint256[] memory opWide = abi.decode(vm.parseJson(opJson), (uint256[]));
//        uint64[] memory operatorIds = new uint64[](opWide.length);
//        for (uint256 i = 0; i < opWide.length; i++) {
//            operatorIds[i] = uint64(opWide[i]);
//        }
//
//        ISSVNetworkCore.Cluster memory cluster;
//        cluster.validatorCount = 0;
//        cluster.networkFeeIndex = 0;
//        cluster.index = 0;
//        cluster.active = true;
//        cluster.balance = 0;
//
//        vm.startBroadcast();
//        ssvNetwork.bulkRegisterValidator(
//            publicKeys,
//            operatorIds,
//            sharesDatas,
//            DEPOSIT_AMOUNT,
//            cluster
//        );
//        vm.stopBroadcast();
//
//        console2.log("Successfully registered", uint256(publicKeys.length), "validators");
//    }
//}
