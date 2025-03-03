const hre = require("hardhat");
const { ethers } = hre;
const { SSVKeys, KeyShares, EncryptShare } = require("ssv-keys");
import { ClusterScanner, NonceScanner } from "ssv-scanner";

const fs = require("fs");
const path = require("path");

interface Operator {
  id: number;
  operatorKey: string;
}

async function connectContract(
  eth1URL: string,
  contractAddress: string,
  contractFactory: string,
  privateKey: string
) {
  const provider = new ethers.JsonRpcProvider(eth1URL);

  const wallet = new ethers.Wallet(privateKey, provider);
  console.log(`Connected Wallet Address: ${wallet.address}`);

  const factory = await ethers.getContractFactory(contractFactory, wallet);
  const contract = factory.attach(contractAddress);

  return { contract, wallet };
}

// Perform the cluster and nonce scanner functionality
async function getClusterAndNonce(params) {
  const clusterScanner = new ClusterScanner(params);
  const cluster = await clusterScanner.run(params.operatorIds);
  const nonceScanner = new NonceScanner(params);
  const nonce = await nonceScanner.run();
  return { cluster, nonce };
}

export async function registerValidators() {
  if (
    !process.env.SSV_NETWORK_ADDRESS_STAGE ||
    !process.env.OWNER_PRIVATE_KEY ||
    !process.env.RPC_URI ||
    !process.env.OPERATOR_1_PUBLIC_KEY ||
    !process.env.OPERATOR_2_PUBLIC_KEY ||
    !process.env.OPERATOR_3_PUBLIC_KEY ||
    !process.env.OPERATOR_4_PUBLIC_KEY ||
    !process.env.KEYSTORE_PATH ||
    !process.env.PASSWORDS_PATH
  ) {
    console.error("❌ One or more required environment variables are missing.");
    process.exit(1);
  }

  const operators: Operator[] = [
    // TODO: get count from SSV_NODES_COUNT
    { id: 1, operatorKey: process.env.OPERATOR_1_PUBLIC_KEY },
    { id: 2, operatorKey: process.env.OPERATOR_2_PUBLIC_KEY },
    { id: 3, operatorKey: process.env.OPERATOR_3_PUBLIC_KEY },
    { id: 4, operatorKey: process.env.OPERATOR_4_PUBLIC_KEY },
  ];

  const { contract: tokenContract, wallet } = await connectContract(
    process.env.RPC_URI,
    process.env.SSV_TOKEN_ADDRESS,
    "SSVToken",
    process.env.OWNER_PRIVATE_KEY
  );


  console.log("Preparing to approve ssv");


  console.log(`Wallet Address: ${wallet.address}`);

  const amount = ethers.parseUnits("100000000", 18);
  const tx = await tokenContract.approve(wallet.address, amount);
  tx.wait();

  console.log("SSV approved now registering validators");
  

  // Map out operator ids's
  const operatorIds = operators.map((obj) => obj.id);

  // Get cluster and nonce


  const keystorePath = process.env.KEYSTORE_PATH;
  const secretsPath = process.env.PASSWORDS_PATH;

  // Loop through all the keystores and build their payloads
  const dir = await fs.promises.opendir(keystorePath);

  let nonce = 1;

  let podData = {
    validatorCount: Number(0),
    networkFeeIndex: "0",
    index: "0",
    active: true,
    balance: "0",
  };

  for await (const keystoreFile of dir) {
    // Define the shares
    let shares = "";

    // Build the keystore path
    const keystoreData = JSON.parse(
      fs.readFileSync(keystorePath + keystoreFile.name, "utf8")
    );
    const passwordFileName = keystoreFile.name.replace(".json", ".txt");
    const password = fs.readFileSync(secretsPath + passwordFileName, "utf-8");

    // Step 1: read keystore file
    const ssvKeys = new SSVKeys();
    const { publicKey, privateKey } = await ssvKeys.extractKeys(
      keystoreData,
      password
    );

    // Step 2: Build shares from operator IDs and public keys
    const threshold = await ssvKeys.createThreshold(privateKey, operators);
    const encryptedShares = await ssvKeys.encryptShares(
      operators,
      threshold.shares
    );

    // Step 3: Build final web3 transaction payload and update keyshares file with payload data
    const keyShares = new KeyShares();
    const builtPayload = await keyShares.buildPayload(
      {
        publicKey,
        operators,
        encryptedShares,
      },
      {
        ownerAddress: wallet.address,
        ownerNonce: nonce,
        privateKey,
      }
    );
    shares = builtPayload.sharesData;
    nonce += 1;

    // Connect the account to use for contract interaction
    const {contract: ssvNetworkContract, wallet: wallet2} = await connectContract(
        process.env.RPC_URI,
        process.env.SSV_NETWORK_ADDRESS_STAGE,
        'SSVNetwork',
        process.env.OWNER_PRIVATE_KEY
    );

    // await ssvNetworkContract.setRegisterAuth(accounts[0].address, [true, true])

    // Register the validator
    const txResponse = await ssvNetworkContract.registerValidator(
      publicKey,
      operatorIds,
      shares,
      1000,
      podData,
      // {
      //   gasPrice: process.env.GAS_PRICE,
      //   gasLimit: process.env.GAS_LIMIT,
      // }
    );

    try {
      // Get the pod data
      const receipt = await txResponse.wait();
      console.log(`✅  Validator ${publicKey} registered`);
      console.log(receipt);
      // podData = receipt.events[2].args[4]; // TODO: no events are returned but tx works?
    } catch (error) {
      console.log(
        `Failed to register validator ${publicKey} with error: ${error}`
      );
      console.error(error);
      // TODO - handle failed tx
    }
  }
}

registerValidators()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
