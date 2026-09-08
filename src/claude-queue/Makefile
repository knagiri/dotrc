.PHONY: build install test clean fmt fmt-check vet

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

# `gofmt -l` exits 0 even when it lists unformatted files, so the gate is the
# emptiness of its output, not its exit status. Names the offending files so the
# fix is `gofmt -w` on exactly those.
fmt-check:
	@out="$$(gofmt -l .)"; \
	if [ -n "$$out" ]; then \
		echo "gofmt would rewrite these files:" >&2; \
		echo "$$out" >&2; \
		exit 1; \
	fi

vet:
	go vet ./...
