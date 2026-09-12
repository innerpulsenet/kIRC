#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Sync every version string in the tree to one release version.
#
#   packaging/set-version.sh 0.7.0
#
# Used by the RPM release workflow (and handy by hand) so the spec, the AppStream
# metadata, the crate manifests and the application's own --version can never
# disagree about which release is being built.  Idempotent: running it twice with
# the same version changes nothing the second time, except that it will not add a
# duplicate changelog entry.
set -euo pipefail

version="${1:-}"
# Cargo requires exactly three components (major.minor.patch): a manifest
# carrying `version = "0.8"` fails to parse with "unexpected end of input while
# parsing minor version number". Normalise here rather than writing a version
# the crate manifests cannot read, so `set-version.sh 0.8` is equivalent to
# `set-version.sh 0.8.0`.
if [[ ! "$version" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    echo "usage: $0 <version>   (e.g. $0 0.8 or $0 0.8.0 — both mean 0.8.0)" >&2
    exit 2
fi
version="${BASH_REMATCH[1]}.${BASH_REMATCH[3]:-0}.${BASH_REMATCH[5]:-0}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

spec="packaging/kirc.spec"
metainfo="packaging/org.kde.kirc.metainfo.xml"

# Date formats: RPM changelog wants "Wed Jun 10 2026" (C locale, day first with
# padding), AppStream wants ISO 8601.
rpm_date="$(LC_ALL=C date -u '+%a %b %d %Y')"
iso_date="$(date -u '+%Y-%m-%d')"

# --- Rust crate manifests ---------------------------------------------------
# Only the first column-0 `version = ` is the package's own version; dependency
# versions are indented or inline tables, so this cannot hit them.
for manifest in rust/Cargo.toml rust/core/Cargo.toml; do
    [[ -f "$manifest" ]] || continue
    sed -i -E "0,/^version = \"[^\"]*\"/s//version = \"${version}\"/" "$manifest"
done

# --- CMake / application version reported by the About pane -----------------
sed -i -E "0,/^[[:space:]]*VERSION +[0-9]+\.[0-9]+\.[0-9]+/s//    VERSION ${version}/" CMakeLists.txt

# --- AppStream: newest release entry carries this version -------------------
python3 - "$metainfo" "$version" "$iso_date" <<'PY'
import re, sys
path, version, date = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
# Rewrite the first <release ...> element (the newest one).
src, n = re.subn(
    r'(<release version=")[^"]*(" date=")[^"]*(")',
    lambda m: f"{m.group(1)}{version}{m.group(2)}{date}{m.group(3)}",
    src, count=1)
if n != 1:
    sys.exit(f"set-version: no <release version=... date=...> entry found in {path}")
open(path, "w", encoding="utf-8").write(src)
PY

# --- RPM spec: Version, and a changelog entry for this release ---------------
sed -i -E "s/^Version: +[^ ]+/Version:        ${version}/" "$spec"

entry="* ${rpm_date} The kIRC Authors <kirc@innerpulse.net> - ${version}-1
- Release ${version}"

# Insert directly under the %changelog marker unless the top entry is already
# this version (keeps re-runs and rebuilds of the same tag idempotent).
python3 - "$spec" "$version" "$entry" <<'PY'
import sys
path, version, entry = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
try:
    start = next(i for i, l in enumerate(lines) if l.strip() == "%changelog") + 1
except StopIteration:
    sys.exit(f"set-version: no %%changelog section in {path}")

# First non-blank changelog line is the newest entry.
n = start
while n < len(lines) and not lines[n].strip():
    n += 1
already = n < len(lines) and lines[n].startswith("*") and f"- {version}-1" in lines[n]
if not already:
    lines[start:start] = [entry + "\n", "\n"]
    open(path, "w", encoding="utf-8").write("".join(lines))
    print(f"set-version: added changelog entry for {version}")
PY

echo "kIRC version set to ${version}"
