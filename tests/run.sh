#!/bin/zsh
# Builds and runs the Raycast add-in's tests. The end-to-end part needs a Raycast 2 app:
#   RAYCAST_V2_APP=/Volumes/Raycast/Raycast.app tests/run.sh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
swiftc -swift-version 5 -parse-as-library raycastcore.swift tests/raycast-tests.swift -o build/raycast-tests
# The v2 helper must parse under Node.
if command -v node >/dev/null; then
  build/raycast-tests --helper > build/raycast-v2-helper.cjs
  node --check build/raycast-v2-helper.cjs && echo "helper parses"
fi
exec build/raycast-tests
