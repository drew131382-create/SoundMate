#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
test_target="$(uname -m)-apple-macos14.2"

swiftc -O -target "$test_target" Tests/CommunicationRoutingTests.swift \
  Sources/CommunicationRoutingPolicy.swift -o build/tests/CommunicationRoutingTests
./build/tests/CommunicationRoutingTests

swiftc -O -target "$test_target" Tests/AudioRouteRecoveryTests.swift \
  Sources/AudioRouteCoordinator.swift -o build/tests/AudioRouteRecoveryTests
./build/tests/AudioRouteRecoveryTests

swiftc -O -target "$test_target" Tests/AudioBufferRendererTests.swift \
  Sources/AudioBufferRenderer.swift -o build/tests/AudioBufferRendererTests
./build/tests/AudioBufferRendererTests

swiftc -O -target "$test_target" Tests/AudioSignalTests.swift \
  Sources/ProcessTapController.swift Sources/AudioRouteCoordinator.swift \
  Sources/AudioBufferRenderer.swift Sources/Extensions/*.swift -o build/tests/AudioSignalTests
./build/tests/AudioSignalTests
