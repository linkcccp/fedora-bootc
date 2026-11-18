#!/usr/bin/env bash
set -euo pipefail

# Download, verify and merge the split bootc installer ISO from GitHub Releases.
#
# Usage:
#   download-iso.sh [--version <tag>] [--output-dir <dir>] [--keep-parts] [--force]
#
# The release stores the ISO as <name>.iso.part-NN files because GitHub Release
# assets are limited to 2 GiB each. This script downloads all parts, verifies
# every part, streams them into a single ISO and then verifies the ISO checksum.
#
# Environment:
#   REPO      GitHub repository (default: linkcccp/fedora-bootc)
#   GH_TOKEN  Optional token for GitHub API rate limits

REPO="${REPO:-linkcccp/fedora-bootc}"
VERSION=""
OUTPUT_DIR="."
KEEP_PARTS=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: download-iso.sh [options]

Options:
  --version <tag>      Release tag or version, e.g. build-202611181257 or 202611181257
  --output-dir <dir>   Directory for the parts and final ISO (default: .)
  --keep-parts         Keep the downloaded .part-* files
  --force              Continue even if free disk space looks insufficient
  --repo <owner/repo>  GitHub repository (default: linkcccp/fedora-bootc)
  -h, --help           Show this help

The script finds the newest release that contains an ISO part by default.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="${2:?missing value for --version}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:?missing value for --output-dir}"
            shift 2
            ;;
        --keep-parts)
            KEEP_PARTS=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --repo)
            REPO="${2:?missing value for --repo}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (use --help)"
            ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v grep >/dev/null 2>&1 || die "grep is required"

api_headers=(
    -H 'Accept: application/vnd.github+json'
    -H 'User-Agent: fedora-bootc-iso-downloader'
)
if [ -n "${GH_TOKEN:-}" ]; then
    api_headers+=(-H "Authorization: Bearer $GH_TOKEN")
fi

api_get() {
    curl -fsSL --retry 5 "${api_headers[@]}" "$1"
}

extract_urls() {
    printf '%s' "$1" |
        grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
        sed -E 's/^.*"([^"]+)"$/\1/' || true
}

download() {
    local url=$1
    local dest=$2

    if [ -s "$dest" ]; then
        if ! curl -fL --retry 5 -C - -o "$dest" "$url"; then
            printf 'Resume failed for %s; downloading again.\n' "$dest" >&2
            rm -f "$dest"
            curl -fL --retry 5 -o "$dest" "$url"
        fi
    else
        curl -fL --retry 5 -o "$dest" "$url"
    fi
}

verify_checksums() {
    local dir=$1
    local file=$2

    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$dir" && sha256sum -c "$file")
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$dir" && shasum -a 256 -c "$file")
    else
        die "sha256sum or shasum is required to verify downloads"
    fi
}

mkdir -p "$OUTPUT_DIR"
out=$(cd "$OUTPUT_DIR" && pwd)

if [ -n "$VERSION" ]; then
    case "$VERSION" in
        build-*) tag=$VERSION ;;
        *) tag="build-$VERSION" ;;
    esac
    release_json=$(api_get "https://api.github.com/repos/$REPO/releases/tags/$tag")
else
    release_json=""
    page=1
    while [ "$page" -le 5 ]; do
        releases_json=$(api_get "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page")
        part00_url=$(extract_urls "$releases_json" |
            grep -E '\.iso\.part-00$' |
            head -n 1 || true)
        if [ -n "$part00_url" ]; then
            tag=$(printf '%s' "$part00_url" | sed -E 's#.*/download/([^/]+)/.*#\1#')
            release_json=$(api_get "https://api.github.com/repos/$REPO/releases/tags/$tag")
            break
        fi
        page=$((page + 1))
    done
    [ -n "$release_json" ] || die "no release with ISO parts found in $REPO"
fi

release_urls=$(extract_urls "$release_json")
part_urls=$(printf '%s\n' "$release_urls" | grep -E '\.iso\.part-[0-9]+$' | sort || true)
part00_url=$(printf '%s\n' "$release_urls" | grep -E '\.iso\.part-00$' | head -n 1 || true)
parts_sha_url=$(printf '%s\n' "$release_urls" | grep -E '/parts\.sha256$' | head -n 1 || true)
iso_sha_url=$(printf '%s\n' "$release_urls" | grep -E '\.iso\.sha256$' | head -n 1 || true)

[ -n "$part_urls" ] || die "release $tag has no ISO parts"
[ -n "$part00_url" ] || die "release $tag has no .iso.part-00"
[ -n "$parts_sha_url" ] || die "release $tag has no parts.sha256"
[ -n "$iso_sha_url" ] || die "release $tag has no ISO checksum"

part00_name=$(basename "$part00_url")
iso_name=${part00_name%.part-00}
iso_sha_name="$iso_name.sha256"

printf 'Release: %s\n' "$tag"
printf 'ISO:     %s\n' "$iso_name"
printf 'Parts:   %s\n' "$(printf '%s\n' "$part_urls" | wc -l | tr -d ' ')"

total_bytes=0
for url in $part_urls; do
    len=$(curl -fsSIL --retry 3 "$url" |
        tr -d '\r' |
        awk 'tolower($1) == "content-length:" { value = $2 } END { print value }' || true)
    case "$len" in
        ''|*[!0-9]*)
            total_bytes=0
            break
            ;;
    esac
    total_bytes=$((total_bytes + len))
done

if [ "$total_bytes" -gt 0 ]; then
    slack=$((1024 * 1024 * 1024))
    if [ "$KEEP_PARTS" -eq 1 ]; then
        need_bytes=$((total_bytes * 2 + slack))
    else
        need_bytes=$((total_bytes + slack))
    fi
    need_label="$((need_bytes / 1024 / 1024 / 1024)) GiB"
else
    if [ "$KEEP_PARTS" -eq 1 ]; then
        need_bytes=$((26 * 1024 * 1024 * 1024))
    else
        need_bytes=$((14 * 1024 * 1024 * 1024))
    fi
    need_label="$((need_bytes / 1024 / 1024 / 1024)) GiB (estimated)"
fi

avail_kb=$(df -Pk "$out" | awk 'NR == 2 { print $4 }')
avail_bytes=$((avail_kb * 1024))
if [ "$avail_bytes" -lt "$need_bytes" ] && [ "$FORCE" -eq 0 ]; then
    die "need about $need_label free in $out, only $((avail_bytes / 1024 / 1024 / 1024)) GiB available (use --force to continue)"
fi

download "$parts_sha_url" "$out/parts.sha256"
download "$iso_sha_url" "$out/$iso_sha_name"

while IFS= read -r url; do
    name=$(basename "$url")
    printf 'Downloading %s\n' "$name"
    download "$url" "$out/$name"
done <<< "$part_urls"

verify_checksums "$out" parts.sha256

iso_path="$out/$iso_name"
rm -f "$iso_path"
: > "$iso_path"

while IFS= read -r url; do
    name=$(basename "$url")
    cat "$out/$name" >> "$iso_path"
    if [ "$KEEP_PARTS" -eq 0 ]; then
        rm -f "$out/$name"
    fi
done <<< "$part_urls"

verify_checksums "$out" "$iso_sha_name"

printf '\nISO ready: %s\n' "$iso_path"
printf 'Size:      %s\n' "$(du -h "$iso_path" | awk '{ print $1 }')"
if [ "$KEEP_PARTS" -eq 0 ]; then
    printf 'Parts were deleted; use --keep-parts to keep them.\n'
fi
