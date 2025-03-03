### ❗NOTE
This repo is still WIP and is not by any means ready to run. Checkout the Components and progress section.

## Setup

### Pre-requirements

- Docker
- Kurtosis
- Build E2M locally ( `git clone https://github.com/ssvlabs/ethereum2-monitor --branch v2 && cd ethereum2-monitor && docker build -t local/ethereum2-monitor`)
- Local image of SSV supporting custom config (currently here - https://github.com/ssvlabs/ssv/pull/1308) `docker build -t ssv-node:custom-config .`
```bash
chmod +x ./run.sh
chmod +x ./reset.sh
```


### Running 

```bash
./run.sh
```

*NOTE*: Kurtosis is incremental deployment framework, so if you change something or add some new code, it will compare current environment and only deploy the changes. this way we can test new stuff fast without needed to redeploy the whole eth/ssv network.

### Starting Over

Use this if you want to shutdown previous network and start one from genesis

```bash
./reset.sh
```


## Status

### Goals 

- Anyone can run a SSV network on their pc
- Running any SSV commit on local testnet is easy and fast
- Local setup is similar to actual testnet
- Possible to scale by adding resources

### Design

##### Components and progress

- Kurtosis - Orchestrator, used to deploy different packages, takes care of network connectivity, packaging and more.
- [x] - Kurtosis Eth Package - Ethereum network base (EL, CL, validator keys)
- [x] - SSV Contract Deployer (`/src/contract`)
	- [x] - Deploys Token,  SSV Contracts
 	- [x] - Verify contract with blockscout

- [ ] State manager
  - [ ] Take some prefunded keys from network genesis (make sure no validators running them)
  - [ ] Deposits SSV token
  - [ ] Adds operators
  - [ ] register validators.
- [ ] - SSV Operator Runner
  - [x] Create different operators configs based on network and contract data (cl/el urls, keys, etc..)
  - [x] run go-ssv operator node
  - [ ] run anchor node
- [ ] - E2M (should work but needs testing and code to configure validator tracking)
- [ ] - Metrics and observability
  - [ ] - EL/CL
  - [ ] - SSV
- [ ] - Test Runner - 
	- Sanity network
	- TBD
