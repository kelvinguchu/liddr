CONTRACT := ../../packages/contract/openapi.yaml
SQLC_IMAGE := sqlc/sqlc:1.31.1
SQLC := docker run --rm --user "$$(id -u):$$(id -g)" -v "$(CURDIR):/src" -w /src $(SQLC_IMAGE)
GOLANGCI_LINT_VERSION := v2.15.0

export TEST_DATABASE_URL ?= postgres://liddr:liddr@127.0.0.1:55432/liddr?sslmode=disable

.PHONY: generate generated-check check fmt-check lint vet test race vuln install-lint db-up db-down seed-test-prices

generate:
	go tool oapi-codegen -config oapi-codegen.yaml $(CONTRACT)
	$(SQLC) vet
	$(SQLC) generate

# Fails if generated code is out of step with the contract or queries.
generated-check:
	go tool oapi-codegen -config oapi-codegen.yaml $(CONTRACT)
	git diff --exit-code -- internal/httpapi/api.gen.go
	$(SQLC) vet
	$(SQLC) diff

check: fmt-check lint vet race

fmt-check:
	@test -z "$$(gofmt -l .)" || (gofmt -l . && exit 1)

lint:
	golangci-lint run ./...

vet:
	go vet ./...

test:
	go test ./...

race:
	go test -race ./...

vuln:
	govulncheck ./...

install-lint:
	go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

db-up:
	docker compose up --detach --wait

db-down:
	docker compose down --volumes

# Applies real-money test prices to the database named by DATABASE_URL.
seed-test-prices:
	@test -n "$$DATABASE_URL" || (echo "DATABASE_URL is required" && exit 1)
	docker run --rm -i --network host -e DATABASE_URL postgres:18-alpine \
		sh -c 'psql "$$DATABASE_URL" -v ON_ERROR_STOP=1' < seeds/test_prices.sql
