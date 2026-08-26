#!/bin/zsh
# Compiles the engine together with the test file and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -parse-as-library Sources/Engine/*.swift Tests/GestureEngineTests.swift -o build/engine-tests
./build/engine-tests
