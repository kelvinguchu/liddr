# syntax=docker/dockerfile:1
# The Liddr API: one static binary that serves (`serve`, the default) and
# applies migrations (`migrate`, run as its own deploy step). It runs as an
# unprivileged user on a base image with CA certificates and nothing else.
FROM golang:1.27.3-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-trimpath
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -ldflags="-s -w" -o /out/api ./cmd/api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/api"]
CMD ["serve"]
