FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY proxy.go .
RUN CGO_ENABLED=0 go build -o /blindspot-proxy .

FROM alpine:3.20
COPY --from=builder /blindspot-proxy /blindspot-proxy
ENTRYPOINT ["/blindspot-proxy"]
