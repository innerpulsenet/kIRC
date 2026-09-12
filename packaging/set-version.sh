#!/usr/bin/env sh
# SPDX-License-Identifier: MIT OR Apache-2.0
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$here/set-version.py" "$@"
