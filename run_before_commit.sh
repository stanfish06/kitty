#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

for f in linux.conf macos.conf; do
    if git status --porcelain -- "$f" | grep -qE '^( D|D )'; then
        git checkout HEAD -- "$f"
        echo "Restored $f"
    fi
done
