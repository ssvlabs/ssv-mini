# ssv simulator: the Go test driver plus the genesis tooling it runs in-process.
ARG GENESIS_GENERATOR=ethpandaops/ethereum-genesis-generator:6.2.4

FROM golang:1.24 AS builder
WORKDIR /source
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /ssv-sim .

# The genesis generator image already ships eth-genesis-state-generator and eth2-val-tools.
FROM ${GENESIS_GENERATOR}
ARG SSV_SLOT_SECONDS=12
ARG SSV_GENESIS_DELAY=15
ARG SSV_TIMEOUT=900
ARG SSV_CHAIN=premined
ENV SSV_SLOT_SECONDS=${SSV_SLOT_SECONDS} SSV_GENESIS_DELAY=${SSV_GENESIS_DELAY} SSV_TIMEOUT=${SSV_TIMEOUT} SSV_CHAIN=${SSV_CHAIN}
COPY fixtures /fixtures
COPY --from=builder /ssv-sim /ssv-sim
ENTRYPOINT ["/ssv-sim"]
