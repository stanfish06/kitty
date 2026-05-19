#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

case "$(uname -s)" in
    Darwin)
        rm -f linux.conf
        echo "macOS detected: removed linux.conf"
        ;;
    Linux)
        rm -f macos.conf
        echo "Linux detected: removed macos.conf"
        ;;
    *)
        echo "Unsupported OS: $(uname -s)" >&2
        exit 1
        ;;
esac
