#!/usr/bin/env bash
# Pre-commit hook for the Minecraft Alpha Clone repo.
# Installed via scripts/dev/install-hooks.sh.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "→ gdformat --check"
gdformat --check scripts/ tests/

echo "→ gdlint"
gdlint scripts/ tests/

echo "✓ pre-commit passed"
