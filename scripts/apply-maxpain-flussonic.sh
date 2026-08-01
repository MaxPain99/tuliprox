#!/bin/bash
# Apply MaxPain tuliprox patches for Release/Docker builds.
#
# Upstream euzu/tuliprox#807 landed Flussonic/BitTV archive catchup + Streams sticky panel.
# This script applies:
#   1) zap-close-old-sessions — terminate other-channel soft-preserved sessions on Activate
#   2) user-hide-adult — per-user adult filtering
# The flussonic patch file is kept as a stub (do not apply).
#
# Usage:
#   ./scripts/apply-maxpain-flussonic.sh [TREE]
#   TULIPROX_ROOT=/path/to/tuliprox ./scripts/apply-maxpain-flussonic.sh
#
# Note: EPG url-tvg, EXTVLCOPT, Windows #806, and Flussonic/Streams sticky (#807) are upstream.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TREE="$(cd "${1:-${TULIPROX_ROOT:-${ROOT_DIR}}}" && pwd)"

PATCHES=(
  "zap-close-old-sessions.patch"
  "user-hide-adult.patch"
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
    echo "git/patch missing - using embedded Python applicator"
    apply_with_python
  else
    echo "ERROR: need git, patch, or python3 to apply the patch" >&2
    exit 1
  fi
}

for name in "${PATCHES[@]}"; do
  apply_one_patch "${ROOT_DIR}/patches/${name}"
done

# Sanity: #807 Flussonic/Streams sticky is upstream (do not re-apply).
grep -q 'ProcessHandle' "${TREE}/backend/src/api/sys_usage.rs"
grep -q 'M3U_APPEND_MODE_DEFAULT_TEMPLATE' "${TREE}/backend/src/iptv/m3u/catchup.rs"
grep -q 'append_unified_catchup_type_attributes' "${TREE}/shared/src/model/playlist.rs"
grep -q 'Prefer `catchup-type` when both are set' "${TREE}/shared/src/model/stream_properties.rs"
grep -q 'resolve_leaked_hls_relative_origin' "${TREE}/backend/src/api/endpoints/hls_api.rs"
grep -q 'panel_streams' "${TREE}/backend/src/api/model/active_user_manager.rs"
grep -q 'panel_streams' "${TREE}/backend/src/api/endpoints/v1_api.rs"
grep -q 'is_sticky_session_stream' "${TREE}/frontend/src/hooks/use_server_status.rs"
grep -q 'prune_zapped_preserved_streams' "${TREE}/frontend/src/hooks/use_server_status.rs"
grep -q 'overflow-y: auto' "${TREE}/frontend/scss/app/components/dashboard/_streams_view.scss"

# Sanity: Hide Adult patch applied.
grep -q 'hide_adult' "${TREE}/shared/src/model/config/api_user.rs"
grep -q 'is_adult_group' "${TREE}/backend/src/model/config/api_user.rs"
grep -q 'StoredApiUserV7' "${TREE}/backend/src/repository/bplustree/migration.rs"
grep -q 'adult_epg_id_blocklist' "${TREE}/backend/src/repository/adult_epg_ids.rs"
grep -q 'HIDE_ADULT' "${TREE}/frontend/src/app/components/userlist/proxy_user_credentials_form.rs"
grep -q 'adult_epg_id_blocklist' "${TREE}/backend/src/api/endpoints/xmltv_api.rs"
grep -q 'let hide_adult = user.hide_adult' "${TREE}/backend/src/repository/m3u_playlist_iterator.rs"

# Sanity: zap-close-old-sessions applied.
grep -q 'terminate_other_channel_sessions_for_client_ip' "${TREE}/backend/src/api/model/active_user_manager.rs"
grep -q 'terminate_other_channel_sessions_for_client' "${TREE}/backend/src/api/model/connection_manager.rs"
grep -q 'zap_close_other_channel_playback' "${TREE}/backend/src/api/api_utils.rs"
grep -q 'terminate_other_channel_hls_for_client' "${TREE}/backend/src/api/model/hls_cache/manager.rs"
grep -q 'other_active_by_client' "${TREE}/backend/src/api/model/active_user_manager.rs"
grep -q 'normalize_client_ip' "${TREE}/backend/src/api/model/active_user_manager.rs"
grep -q 'Channel zap / dual-open' "${TREE}/backend/src/api/model/connection_manager.rs"
grep -q 'X-Forwarded-For may be a chain' "${TREE}/backend/src/auth/fingerprint.rs"
grep -q 'Backend DisconnectedStream is a hard remove' "${TREE}/frontend/src/hooks/use_server_status.rs"

echo "MaxPain patches applied OK (zap-close-old-sessions + Hide Adult; Flussonic/Streams #807 is upstream)"
echo "Rebuild tuliprox and refresh playlists."
