# List available recipes
default:
    @just --list

# Compile the project with warnings as errors and build the plugin escript
build:
    mix compile --warnings-as-errors
    mix escript.build

# Run all Elixir unit and integration tests
test:
    mix test

# Lint Protobuf schemas and regenerate Tier 1 Elixir code via protoc-gen-omnibuf-elixir
proto:
    buf lint
    mix escript.build
    buf generate
    mix format

# Build conformance-elixir and run the cross-language conformance suite across all 4 tiers
conformance:
    #!/usr/bin/env bash
    set -euo pipefail
    OMNIBUF_ESCRIPT=conformance MIX_ENV=prod mix escript.build
    if [[ -n "${CONFORMANCE_RUNNER:-}" ]]; then
        RUNNER="$CONFORMANCE_RUNNER"
    elif [[ -x "../omnibuf-go/bin/conformance-runner" ]]; then
        RUNNER="../omnibuf-go/bin/conformance-runner"
    elif command -v conformance-runner >/dev/null 2>&1; then
        RUNNER="conformance-runner"
    else
        echo "conformance-runner binary not found; set CONFORMANCE_RUNNER or install conformance-runner" >&2
        exit 1
    fi
    "$RUNNER" ./conformance-elixir

# Run the 6-category PeerUpdate benchmark suite and write testdata/benchmarks.json
bench:
    OMNIBUF_ESCRIPT=conformance MIX_ENV=prod mix run bench/peer_bench.exs

# Run static compilation checks and buf lint
lint:
    mix compile --warnings-as-errors
    buf lint

# Format Elixir and Protobuf files in place
fmt:
    mix format
    buf format -w

# Check Elixir and Protobuf formatting without modifying files
fmt-check:
    mix format --check-formatted
    buf format -d --exit-code

# Run the complete CI verification pipeline
ci: fmt-check lint build test conformance
