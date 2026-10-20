FROM golang:1.26 AS builder
WORKDIR /app
COPY go.mod ./
COPY proxy.go .
RUN CGO_ENABLED=0 go build -o /cl-proxy .

# alpine, not scratch: busybox wget lets `kurtosis service exec` reach the control API from inside.
FROM alpine:3.20
COPY --from=builder /cl-proxy /cl-proxy
ENTRYPOINT ["/cl-proxy"]
