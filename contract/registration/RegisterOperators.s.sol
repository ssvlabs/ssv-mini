pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {SSVNetwork} from "src/SSVNetwork.sol";
import {ISSVOperators} from "src/interfaces/ISSVOperators.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract RegisterOperators is Script {

  uint256 constant OPERATOR_FEE = 1_000_000_000; // 1 SSV (in smallest unit)
  uint64 constant MAX_OPERATOR_FEE = 76_528_650_000_000; // Maximum fee limit
  bool constant SET_AS_PRIVATE = false; // Whether to set operators as private

  SSVNetwork public ssvNetwork;

  function run(address ssvNetworkAddress) external {

    ssvNetwork = SSVNetwork(ssvNetworkAddress);

    string[] memory publicKeys = getOperatorPublicKeys();
    uint64[] memory operatorIds = new uint64[](publicKeys.length);

    vm.startBroadcast();

    ssvNetwork.updateMaximumOperatorFee(MAX_OPERATOR_FEE);

    for (uint256 i = 0; i < publicKeys.length; i++) {
      bytes memory encodedPublicKey = abi.encode(publicKeys[i]);
      uint64 id = ssvNetwork.registerOperator(
        encodedPublicKey,
        OPERATOR_FEE,
        SET_AS_PRIVATE
      );
      operatorIds[i] = id;
      console2.log("Successfully registered operator ID:", id);
      console2.log("Public key:", publicKeys[i]);
    }

    vm.stopBroadcast();
    
    // Write operators data to JSON file
    writeOperatorsToFile(publicKeys, operatorIds);
  }

  function getOperatorPublicKeys() internal view returns (string[] memory) {
    string memory publicKeysFile = "operator_keys.json";

    // Read from JSON file
    string memory json = vm.readFile(publicKeysFile);
    string[] memory keys = stdJson.readStringArray(json, "$.publicKeys");
    return keys;
  }

  function writeOperatorsToFile(string[] memory publicKeys, uint64[] memory operatorIds) internal {
    string memory outputPath = "./operator_data.json";
    
    // Start building JSON string
    string memory json = '{"operators":[';
    
    for (uint256 i = 0; i < publicKeys.length; i++) {
      // Add each operator as a JSON object
      json = string.concat(
        json,
        i > 0 ? ',' : '',
        '{"id":',
        vm.toString(operatorIds[i]),
        ',"publicKey":"',
        publicKeys[i],
        '"}'
      );
    }
    
    // Close the JSON array and object
    json = string.concat(json, ']}');
    
    // Write to file
    vm.writeFile(outputPath, json);
    console2.log("Operator data written to:", outputPath);
  }
}
