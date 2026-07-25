#!/bin/bash
# Apply MaxPain tuliprox patches (Flussonic archives + EPG url-tvg).
# Used by .github/workflows/build.yml and local builds.
#
# Usage:
#   ./scripts/apply-maxpain-flussonic.sh [TREE]
#   TULIPROX_ROOT=/path/to/tuliprox ./scripts/apply-maxpain-flussonic.sh
#
# Order matters: Flussonic first, then EPG (EPG only touches TextIterator / tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TREE="$(cd "${1:-${TULIPROX_ROOT:-${ROOT_DIR}}}" && pwd)"

PATCHES=(
  "m3u-flussonic-tivimate.patch"
  "m3u-epg-url-tvg.patch"
)

if [[ ! -d "${TREE}/backend" ]]; then
  echo "ERROR: not a tuliprox tree: ${TREE}" >&2
  exit 1
fi

BODY="$(mktemp)"
trap 'rm -f "${BODY}"' EXIT

apply_with_git() {
  git -C "${TREE}" apply --check --whitespace=nowarn "${BODY}"
  git -C "${TREE}" apply --whitespace=nowarn "${BODY}"
}

apply_with_patch() {
  (cd "${TREE}" && patch -p1 --forward --batch <"${BODY}")
}

# Pure-Python unified-diff applicator (no git/patch required).
apply_with_python() {
  PATCH_BODY="${BODY}" TARGET_TREE="${TREE}" python3 - <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

body_path = Path(os.environ["PATCH_BODY"])
work = Path(os.environ["TARGET_TREE"])
raw = body_path.read_text(encoding="utf-8")
parts = [p for p in re.split(r"(?=^diff --git )", raw, flags=re.M) if p.strip()]


def apply_unified(work: Path, diff_text: str) -> None:
    lines = diff_text.splitlines(keepends=True)
    m = re.search(r"^diff --git a/(.+?) b/(.+)$", lines[0].rstrip("\n"))
    if not m:
        raise RuntimeError(f"bad header: {lines[0]!r}")
    rel = m.group(2)
    i = 1
    while i < len(lines) and not lines[i].startswith("--- "):
        i += 1
    if i >= len(lines):
        raise RuntimeError(f"no --- in {rel}")
    minus = lines[i].rstrip("\n")
    i += 1
    if i >= len(lines) or not lines[i].startswith("+++ "):
        raise RuntimeError(f"no +++ in {rel}")
    i += 1
    target = work / rel

    if minus.startswith("--- /dev/null"):
        content_lines: list[str] = []
        while i < len(lines):
            if lines[i].startswith("@@"):
                i += 1
                while i < len(lines) and not lines[i].startswith("@@") and not lines[i].startswith("diff --git"):
                    line = lines[i]
                    if line.startswith("+"):
                        content_lines.append(line[1:])
                    elif line.startswith(" "):
                        content_lines.append(line[1:])
                    i += 1
            else:
                break
        target.parent.mkdir(parents=True, exist_ok=True)
        text = "".join(content_lines)
        if not text.endswith("\n"):
            text += "\n"
        target.write_text(text, encoding="utf-8", newline="\n")
        print(f"  created {rel}")
        return

    original = target.read_text(encoding="utf-8").replace("\r\n", "\n")
    if not original.endswith("\n"):
        original += "\n"
    src = original.splitlines(keepends=True)
    out: list[str] = []
    pos = 0
    while i < len(lines):
        if not lines[i].startswith("@@"):
            break
        hm = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", lines[i].rstrip("\n"))
        if not hm:
            raise RuntimeError(f"bad hunk in {rel}: {lines[i]!r}")
        old_start = int(hm.group(1))
        if old_start > 0:
            old_start -= 1
        i += 1
        if pos > old_start:
            raise RuntimeError(f"overlap in {rel}")
        out.extend(src[pos:old_start])
        pos = old_start
        while i < len(lines) and not lines[i].startswith("@@") and not lines[i].startswith("diff --git"):
            line = lines[i]
            if line.startswith(" "):
                if pos >= len(src) or src[pos] != line[1:]:
                    raise RuntimeError(f"context mismatch in {rel} at {pos}")
                out.append(src[pos])
                pos += 1
            elif line.startswith("-"):
                if pos >= len(src) or src[pos] != line[1:]:
                    raise RuntimeError(f"delete mismatch in {rel} at {pos}")
                pos += 1
            elif line.startswith("+"):
                out.append(line[1:])
            elif line.startswith("\\"):
                pass
            else:
                raise RuntimeError(f"bad diff line in {rel}: {line!r}")
            i += 1
    out.extend(src[pos:])
    target.write_text("".join(out), encoding="utf-8", newline="\n")
    print(f"  patched {rel}")


for part in parts:
    apply_unified(work, part)
PY
}

apply_one_patch() {
  local patch_file="$1"
  if [[ ! -f "${patch_file}" ]]; then
    echo "ERROR: patch not found: ${patch_file}" >&2
    exit 1
  fi

  echo "==> Applying $(basename "${patch_file}") -> ${TREE}"
  sed -n '/^diff --git /,$p' "${patch_file}" >"${BODY}"
  if [[ ! -s "${BODY}" ]]; then
    echo "ERROR: no diff --git in ${patch_file}" >&2
    exit 1
  fi

  if command -v git >/dev/null 2>&1; then
    apply_with_git
  elif command -v patch >/dev/null 2>&1; then
    apply_with_patch
  elif command -v python3 >/dev/null 2>&1; then
    echo "git/patch missing — using embedded Python applicator"
    apply_with_python
  else
    echo "ERROR: need git, patch, or python3 to apply the patch" >&2
    exit 1
  fi
}

for name in "${PATCHES[@]}"; do
  apply_one_patch "${ROOT_DIR}/patches/${name}"
done

# Sanity checks (must match current patch contents)
test -f "${TREE}/backend/src/utils/m3u_archive.rs"
grep -q 'resolve_nested_m3u_playback' "${TREE}/backend/src/api/endpoints/m3u_api.rs"
grep -q 'M3U_CATCHUP_PARAM_UTC' "${TREE}/backend/src/utils/m3u_catchup.rs"
grep -q 'flussonic_player_mode' "${TREE}/shared/src/model/stream_properties.rs"
grep -q 'build_proxy_xmltv_url_tvg' "${TREE}/backend/src/repository/m3u_playlist_iterator.rs"
grep -q 'xmltv.php' "${TREE}/backend/src/repository/m3u_playlist_iterator.rs"
grep -q 'url-tvg=' "${TREE}/backend/src/repository/m3u_playlist_iterator.rs"
grep -q 'with_archive_playback' "${TREE}/backend/src/api/model/hls_cache/lease.rs"
grep -q 'archive_origin_url' "${TREE}/backend/src/api/model/hls_cache/playback.rs"
grep -q 'build_hls_origin_source_for_playback' "${TREE}/backend/src/api/endpoints/hls_api.rs"
grep -q 'create_archive_aware_hls_user_session_token' "${TREE}/backend/src/api/endpoints/hls_api.rs"
grep -q 'parse_flat_flussonic_rewritten_stream_id' "${TREE}/backend/src/utils/m3u_archive.rs"
grep -q 'playlist_item_allows_flussonic_archive' "${TREE}/backend/src/api/endpoints/m3u_api.rs"

echo "Flussonic + EPG url-tvg patches applied OK"
echo "Rebuild tuliprox and refresh the user M3U playlist."
