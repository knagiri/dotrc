.PHONY: build install test clean fmt vet

REPO_ROOT := $(shell git rev-parse --show-toplevel)
BIN := $(REPO_ROOT)/bin/claude-queue
VERSION := $(shell git describe --tags --dirty --always 2>/dev/null || echo dev)
LDFLAGS := -X main.version=$(VERSION)

build:
	go build -ldflags "$(LDFLAGS)" -o $(BIN) ./cmd/claude-queue
	@echo "built: $(BIN)"

install: build
	@echo "installed: $(BIN) (bin/ is already on PATH via rc/bashrc)"

test:
	go test ./...

clean:
	rm -f $(BIN)

fmt:
	go fmt ./...

vet:
	go vet ./...
