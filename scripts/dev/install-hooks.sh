#!/usr/bin/env bash
# Symlink versioned hook scripts into .git/hooks.
# Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_SRC="$REPO_ROOT/scripts/dev/pre-commit.sh"
HOOK_DST="$REPO_ROOT/.git/hooks/pre-commit"

chmod +x "$HOOK_SRC"
ln -sf "$HOOK_SRC" "$HOOK_DST"

echo "Installed pre-commit hook → $HOOK_DST"
