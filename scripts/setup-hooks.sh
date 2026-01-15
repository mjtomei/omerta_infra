#!/bin/bash
# Configure git to use the project's hooks directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Configuring git hooks..."
git config core.hooksPath .githooks

echo "Done. Git will now use hooks from .githooks/"
echo ""
echo "Hooks installed:"
ls -la "$ROOT_DIR/.githooks/"
