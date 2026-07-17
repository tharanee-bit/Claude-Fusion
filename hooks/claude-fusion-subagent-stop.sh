#!/usr/bin/env bash
# Compatibility wrapper. Installers copy or execute the canonical plugin runtime.
_clf_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$_clf_root/plugins/claude-fusion/hooks/claude-fusion-subagent-stop.sh" "$@"
