#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p build

echo "[1/2] Resolving dependencies"
dart pub get

echo "[2/2] Building AOT executable"
case "$(uname -s)" in
  Darwin)
    OUTPUT="build/pocketbase_mcp_macos"
    ;;
  Linux)
    OUTPUT="build/pocketbase_mcp_linux"
    ;;
  *)
    echo "Unsupported host OS for this script: $(uname -s)"
    exit 1
    ;;
esac

dart compile exe bin/server.dart -o "$OUTPUT"
echo "Built: $OUTPUT"
