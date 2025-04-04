# SSV-Mini
Kurtosis devnet for running local SSV networks.

## Setup
- Docker
- Kurtosis
- Build local client images
```bash
git clone https://github.com/ssvlabs/ssv.git
git checkout origin/override-spec-beacon-config
docker build -t ssv-node:custom-config . 
```
```bash
git clone https://github.com/sigp/anchor.git
git checkout origin/unstable
docker build -f Dockerfile.devnet -t anchor/anchor-unstable . 
```


### Running 

```bash
./run.sh
```

View the logs of the nodes
```
kurtosis service logs -f my-testnet {service-name}
```

### Starting Over

Use this if you want to shutdown previous network and start one from genesis

```bash
./reset.sh
```

### Goals 

- Anyone can run a SSV network on their pc
- Running any SSV commit on local testnet is easy and fast
- Local setup is similar to actual testnet
- Possible to scale by adding resources

