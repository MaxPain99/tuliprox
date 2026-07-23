#!/usr/bin/env python3
"""Flussonic archive fixes for TiviMate (Android) on reverse-proxied M3U.

TiviMate with catchup-type=flussonic appends ?utc=&lutc= to the live proxy stream URL.
It does not follow tuliprox m3u-catchup token routes. Skip catchup rewrite for bare
flussonic metadata and export a query catchup-source template for the player.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("TULIPROX_ROOT", "/tmp/tp-flussonic"))
_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))


def patch_file(rel: str, old: str, new: str, count: int = 1) -> None:
    path = ROOT / rel
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"pattern not found in {rel}")
    updated = text.replace(old, new, count)
    path.write_text(updated, encoding="utf-8")
    print(f"  patched {rel}")

FLUSSONIC_DEFAULT_SOURCE = "?utc={utc}&lutc={lutc}"


def apply_m3u_catchup_skip_flussonic_rewrite() -> None:
    path = ROOT / "backend/src/utils/m3u_catchup.rs"
    text = path.read_text(encoding="utf-8")
    if "fn is_flussonic_catchup(" in text:
        print("  m3u_catchup.rs: flussonic helpers already present")
        return

    patch_file(
        "backend/src/utils/m3u_catchup.rs",
        """fn mode_alias(mode: &str) -> &str {
    if mode.eq_ignore_ascii_case("append") {
        "append"
    } else if mode.eq_ignore_ascii_case("default") {
        "default"
    } else if mode.eq_ignore_ascii_case("shift") {
        "shift"
    } else if mode.eq_ignore_ascii_case("xc") {
        "xc"
    } else if mode.eq_ignore_ascii_case("fs") {
        "fs"
    } else if mode.eq_ignore_ascii_case("vod") {
        "vod"
    } else {
        mode
    }
}""",
        """fn is_flussonic_mode(mode: &str) -> bool {
    matches!(
        mode.trim().to_ascii_lowercase().as_str(),
        "flussonic" | "flussonic-hls" | "flussonic-ts" | "fs"
    )
}

fn is_flussonic_catchup(catchup: &CatchupProperties) -> bool {
    catchup
        .catchup_type
        .as_deref()
        .is_some_and(is_flussonic_mode)
        || catchup.mode.as_deref().is_some_and(is_flussonic_mode)
}

/// Prefer explicit flussonic `catchup-type` over a generic `catchup="append"` from providers.
fn effective_catchup_mode(catchup: &CatchupProperties) -> &str {
    if let Some(ct) = catchup.catchup_type.as_deref().filter(|v| !v.is_empty()) {
        if is_flussonic_mode(ct) {
            return ct;
        }
    }
    catchup.mode.as_deref().unwrap_or("")
}

fn mode_alias(mode: &str) -> &str {
    if mode.eq_ignore_ascii_case("append") {
        "append"
    } else if mode.eq_ignore_ascii_case("default") {
        "default"
    } else if mode.eq_ignore_ascii_case("shift") {
        "shift"
    } else if mode.eq_ignore_ascii_case("xc") {
        "xc"
    } else if mode.eq_ignore_ascii_case("fs") || mode.eq_ignore_ascii_case("flussonic") {
        "flussonic"
    } else if mode.eq_ignore_ascii_case("flussonic-hls") {
        "flussonic"
    } else if mode.eq_ignore_ascii_case("flussonic-ts") {
        "flussonic-ts"
    } else if mode.eq_ignore_ascii_case("vod") {
        "vod"
    } else {
        mode
    }
}""",
    )

    patch_file(
        "backend/src/utils/m3u_catchup.rs",
        """const FLUSSONIC_TEMPLATE: &str = "timeshift_abs-{utc}";""",
        """const FLUSSONIC_TEMPLATE: &str = "timeshift_abs-{utc}";
const FLUSSONIC_HLS_ARCHIVE_TEMPLATE: &str = "archive-{utc}-{duration}";""",
    )

    patch_file(
        "backend/src/utils/m3u_catchup.rs",
        """fn derive_flussonic_template(source_url: &str) -> Option<String> {
    let mut parsed = Url::parse(source_url).ok()?;
    let mut segments = parsed
        .path_segments()
        .map(|it| it.map(ToString::to_string).collect::<Vec<_>>())?;
    let file_name = segments.pop()?;
    segments.push(format!("{FLUSSONIC_TEMPLATE}{}", extract_suffix_from_filename(&file_name)));
    parsed.set_path(&format!("/{}", segments.join("/")));
    Some(parsed.into())
}""",
        """fn derive_flussonic_template(source_url: &str) -> Option<String> {
    derive_flussonic_path_template(source_url, FLUSSONIC_TEMPLATE)
}

fn derive_flussonic_hls_archive_template(source_url: &str) -> Option<String> {
    derive_flussonic_path_template(source_url, FLUSSONIC_HLS_ARCHIVE_TEMPLATE)
}

fn derive_flussonic_path_template(source_url: &str, stem_template: &str) -> Option<String> {
    let mut parsed = Url::parse(source_url).ok()?;
    let mut segments = parsed
        .path_segments()
        .map(|it| it.map(ToString::to_string).collect::<Vec<_>>())?;
    let file_name = segments.pop()?;
    segments.push(format!("{stem_template}{}", extract_suffix_from_filename(&file_name)));
    parsed.set_path(&format!("/{}", segments.join("/")));
    Some(parsed.into())
}""",
    )

    patch_file(
        "backend/src/utils/m3u_catchup.rs",
        """fn derived_template_for_mode<'a>(source_url: &'a str, catchup: &'a CatchupProperties) -> Option<Cow<'a, str>> {
    let mode = catchup.mode.as_deref().unwrap_or_default();
    if let Some(source) = catchup.source.as_deref().filter(|source| !source.is_empty()) {
        return Some(if is_append_like_query_source(mode, source) {
            append_query_template(source_url, source).map(Cow::Owned)?
        } else {
            Cow::Borrowed(source)
        });
    }

    match mode_alias(mode) {
        "shift" => Some(Cow::Owned(format!("{source_url}{}", append_siptv_template(source_url)))),
        "xc" => derive_xc_template(source_url).map(Cow::Owned),
        "fs" => derive_flussonic_template(source_url).map(Cow::Owned),
        "vod" => Some(Cow::Borrowed("{catchup-id}")),
        _ => None,
    }
}""",
        """fn derived_template_for_mode<'a>(source_url: &'a str, catchup: &'a CatchupProperties) -> Option<Cow<'a, str>> {
    let mode = effective_catchup_mode(catchup);
    if let Some(source) = catchup.source.as_deref().filter(|source| !source.is_empty()) {
        return Some(if is_append_like_query_source(mode, source) {
            append_query_template(source_url, source).map(Cow::Owned)?
        } else {
            Cow::Borrowed(source)
        });
    }

    match mode_alias(mode) {
        "shift" => Some(Cow::Owned(format!("{source_url}{}", append_siptv_template(source_url)))),
        "xc" => derive_xc_template(source_url).map(Cow::Owned),
        "flussonic" | "fs" => derive_flussonic_hls_archive_template(source_url)
            .or_else(|| derive_flussonic_template(source_url))
            .map(Cow::Owned),
        "flussonic-ts" => derive_flussonic_template(source_url).map(Cow::Owned),
        "vod" => Some(Cow::Borrowed("{catchup-id}")),
        _ => None,
    }
}""",
    )

    patch_file(
        "backend/src/utils/m3u_catchup.rs",
        """pub fn build_m3u_catchup_rewrite(
    secret: &[u8; 16],
    base_url: &str,
    username: &str,
    target_id: u16,
    virtual_id: u32,
    source_url: &str,
    catchup: &CatchupProperties,
) -> Result<Option<M3uCatchupRewrite>, TuliproxError> {
    let Some(template) = derived_template_for_mode(source_url, catchup) else {
        return Ok(None);
    };""",
        """pub fn build_m3u_catchup_rewrite(
    secret: &[u8; 16],
    base_url: &str,
    username: &str,
    target_id: u16,
    virtual_id: u32,
    source_url: &str,
    catchup: &CatchupProperties,
) -> Result<Option<M3uCatchupRewrite>, TuliproxError> {
    // TiviMate flussonic: keep the live proxy URL and append ?utc=&lutc= itself.
    if is_flussonic_catchup(catchup)
        && catchup.source.as_deref().filter(|source| !source.is_empty()).is_none()
    {
        return Ok(None);
    }
    let Some(template) = derived_template_for_mode(source_url, catchup) else {
        return Ok(None);
    };""",
    )

    if "fn flussonic_rewrite_skipped_for_bare_metadata" not in text:
        patch_file(
            "backend/src/utils/m3u_catchup.rs",
            """    fn catchup_marker_detection_is_explicit() {
        assert!(has_m3u_catchup_marker(Some(&format!("{M3U_CATCHUP_MARKER}=abc&v0=1"))));
        assert!(!has_m3u_catchup_marker(Some("v0=1")));
        assert!(!has_m3u_catchup_marker(None));
    }
}""",
            """    fn catchup_marker_detection_is_explicit() {
        assert!(has_m3u_catchup_marker(Some(&format!("{M3U_CATCHUP_MARKER}=abc&v0=1"))));
        assert!(!has_m3u_catchup_marker(Some("v0=1")));
        assert!(!has_m3u_catchup_marker(None));
    }

    #[test]
    fn flussonic_rewrite_skipped_for_bare_metadata() {
        let rewrite = build_m3u_catchup_rewrite(
            &[7u8; 16],
            "http://proxy.example",
            "alice",
            7,
            42,
            "http://provider.example/live/42.m3u8",
            &CatchupProperties {
                catchup_type: Some("flussonic".intern()),
                days: Some("3".intern()),
                ..CatchupProperties::default()
            },
        )
        .unwrap();
        assert!(rewrite.is_none());
    }

    #[test]
    fn flussonic_hls_archive_template_uses_archive_segment() {
        let resolved = resolve_m3u_catchup_url(
            "http://provider.example/live/42.m3u8",
            &CatchupProperties {
                mode: Some("flussonic".intern()),
                ..CatchupProperties::default()
            },
            Some("v0=1700000000&v1=3600"),
        )
        .unwrap()
        .unwrap();
        assert!(resolved.url.contains("/archive-1700000000-3600.m3u8"));
    }
}""",
        )


def apply_playlist_flussonic_export() -> None:
    path = ROOT / "backend/src/utils/m3u_catchup.rs"
    # playlist.rs lives in shared
    path = ROOT / "shared/src/model/playlist.rs"
    text = path.read_text(encoding="utf-8")
    if "default_flussonic_catchup_source" in text:
        print("  playlist.rs: flussonic export defaults already present")
        return

    patch_file(
        "shared/src/model/playlist.rs",
        """pub fn m3u_playlist_item_export_archive_attrs(item: &M3uPlaylistItem) -> BTreeMap<String, String> {""",
        f"""const FLUSSONIC_TIVIMATE_CATCHUP_SOURCE: &str = "{FLUSSONIC_DEFAULT_SOURCE}";

pub fn m3u_playlist_item_export_archive_attrs(item: &M3uPlaylistItem) -> BTreeMap<String, String> {{""",
    )

    patch_file(
        "shared/src/model/playlist.rs",
        """    canonicalize_m3u_archive_attrs(&mut export_attrs);
    export_attrs
}""",
        """    canonicalize_m3u_archive_attrs(&mut export_attrs);
    if m3u_effective_catchup_type(&export_attrs).eq_ignore_ascii_case("flussonic")
        && m3u_archive_attr(&export_attrs, "catchup-source").is_none()
    {
        export_attrs.insert(
            "catchup-source".to_string(),
            FLUSSONIC_TIVIMATE_CATCHUP_SOURCE.to_string(),
        );
    }
    if m3u_effective_catchup_type(&export_attrs).eq_ignore_ascii_case("flussonic") {
        export_attrs
            .entry("catchup-type".to_string())
            .or_insert_with(|| "flussonic".to_string());
        export_attrs
            .entry("catchup".to_string())
            .or_insert_with(|| "flussonic".to_string());
    }
    export_attrs
}""",
    )


def apply_m3u_api_discriminator_api_req() -> None:
    path = ROOT / "backend/src/api/endpoints/m3u_api.rs"
    text = path.read_text(encoding="utf-8")
    if "m3u_catchup_session_discriminator(" not in text:
        print("  m3u_api.rs: skip discriminator api_req (compat helpers missing)")
        return

    if "api_req: &UserApiRequest" in text.split("fn m3u_catchup_session_discriminator", 1)[1].split("{", 1)[0]:
        print("  m3u_api.rs: discriminator api_req already present")
        return

    patch_file(
        "backend/src/api/endpoints/m3u_api.rs",
        """fn m3u_catchup_session_discriminator(
    archive_discriminator: Option<&str>,
    raw_query: Option<&str>,
    stream_url: &str,
) -> String {
    let base = archive_discriminator.unwrap_or("live");
    if let Some(utc) = raw_query
        .and_then(m3u_archive_epg_reference_from_query)
        .or_else(|| m3u_archive_epg_reference_unix(stream_url))
    {
        return format!("{base}|{utc}");
    }
    base.to_string()
}""",
        """fn m3u_catchup_session_discriminator(
    archive_discriminator: Option<&str>,
    raw_query: Option<&str>,
    api_req: &UserApiRequest,
    stream_url: &str,
) -> String {
    let base = archive_discriminator.unwrap_or("live");
    let synthetic = m3u_archive_query_from_request(raw_query, api_req);
    let utc = synthetic
        .as_deref()
        .and_then(m3u_archive_epg_reference_from_query)
        .or_else(|| raw_query.and_then(m3u_archive_epg_reference_from_query))
        .or_else(|| m3u_archive_epg_reference_unix(stream_url));
    if let Some(utc) = utc {
        return format!("{base}|{utc}");
    }
    base.to_string()
}""",
    )

    text = path.read_text(encoding="utf-8")
    text = re.sub(
        r"m3u_catchup_session_discriminator\(\s*archive_discriminator\.as_deref\(\),\s*raw_query,\s*pli\.url\.as_ref\(\),\s*\)",
        "m3u_catchup_session_discriminator(archive_discriminator.as_deref(), raw_query, api_req, pli.url.as_ref())",
        text,
    )
    path.write_text(text, encoding="utf-8")


def apply_flussonic_archive_url_fallback() -> None:
    path = ROOT / "shared/src/model/playlist.rs"
    text = path.read_text(encoding="utf-8")
    if "flussonic_timeshift_abs_path" in text and "or_else(|| flussonic_timeshift_abs_path" in text:
        print("  playlist.rs: flussonic archive fallback already present")
        return
    if "flussonic_hls_archive_path" not in text:
        print("  playlist.rs: skip flussonic fallback (archive helpers missing)")
        return

    patch_file(
        "shared/src/model/playlist.rs",
        """        "flussonic" | "flussonic-hls" | "fs" => {
            if let Some(start) = times.start_unix() {
                if let Some(url) = flussonic_hls_archive_path(provider_url, start, &duration) {
                    return url;
                }
            }
            if let Some(offset) = times.offset.as_deref() {
                if let Some(url) = flussonic_timeshift_rel_path(provider_url, offset) {
                    return url;
                }
            }
            merge_url_query(provider_url, &client_query)
        }""",
        """        "flussonic" | "flussonic-hls" | "fs" => {
            if let Some(start) = times.start_unix() {
                if let Some(url) = flussonic_hls_archive_path(provider_url, start, &duration) {
                    return url;
                }
                if let Some(url) = flussonic_timeshift_abs_path(provider_url, start) {
                    return url;
                }
            }
            if let Some(offset) = times.offset.as_deref() {
                if let Some(url) = flussonic_timeshift_rel_path(provider_url, offset) {
                    return url;
                }
            }
            merge_url_query(provider_url, &client_query)
        }""",
    )


def main() -> None:
    print("Applying TiviMate / Flussonic archive fixes...")
    apply_m3u_catchup_skip_flussonic_rewrite()
    apply_playlist_flussonic_export()
    apply_m3u_api_discriminator_api_req()
    apply_flussonic_archive_url_fallback()
    print("Flussonic TiviMate fixes done.")


if __name__ == "__main__":
    main()
