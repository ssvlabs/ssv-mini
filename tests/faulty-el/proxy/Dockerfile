FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY proxy.go .
RUN CGO_ENABLED=0 go build -o /proxy proxy.go

FROM alpine:3.20
COPY --from=builder /proxy /proxy
ENTRYPOINT ["/proxy"]
