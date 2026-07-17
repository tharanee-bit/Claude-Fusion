#!/usr/bin/env bash
# Compatibility source wrapper for checkout-based callers. The plugin runtime is canonical.
_clf_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$_clf_root/plugins/claude-fusion/hooks/claude-fusion-common.sh"
