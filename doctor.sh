#!/usr/bin/env bash
# Compatibility wrapper for the canonical plugin doctor.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/plugins/claude-fusion/scripts/doctor.sh" "$@"
