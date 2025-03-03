from web3 import Web3

el_url = "http://127.0.0.1:57430"
web3 = Web3(Web3.HTTPProvider(el_url))

key = "bcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31"
account_1 = "0x8943545177806ED17B9F23F0a21ee5948eCaa776"
account_2 = "0x90F8bf6A479f320ead074411a4B0e7944Ea8c9C1"
nonce = web3.eth.get_transaction_count(account_1)

tx = {
    "nonce": nonce,
    # prevents from sending a transaction twice on ethereum
    "to": account_2,
    "value": web3.to_wei(1, "ether"),
    "gas": 2000000,
    "gasPrice": web3.to_wei(50, "gwei"),
}

#sign the transaction
signed_tx = web3.eth.account.sign_transaction(tx, key)
#send the transaction
tx_hash = web3.eth.send_raw_transaction(signed_tx.rawTransaction)

