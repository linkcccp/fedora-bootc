#!/usr/bin/env bash
set -euo pipefail

# Compare two package lists and write a Markdown changelog plus JSON.
#
# Usage:
#   diff-packages.sh <previous.tsv> <current.tsv> <output-dir>
#
# The previous file may be missing or empty for the first build. Both files use
# "name<TAB>version" (whitespace-separated `pacman -Q` or `rpm -qa` output also
# works).
#
# Optional environment:
#   IMAGE_REF, VERSION, DIGEST, PREV_TAG, GENERATED_AT
#   IMAGE_TITLE (default: Arch Distrobox)
#   PACKAGE_MANAGER (arch or rpm, default: arch)

prev_file=${1:-}
curr_file=${2:?missing current package list}
out_dir=${3:?missing output directory}

: "${IMAGE_REF:=unknown}"
: "${VERSION:=unknown}"
: "${DIGEST:=}"
: "${PREV_TAG:=}"
: "${GENERATED_AT:=$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
: "${IMAGE_TITLE:=Arch Distrobox}"
: "${PACKAGE_MANAGER:=arch}"

export LC_ALL=C

compare_versions() {
    local curr=$1
    local prev=$2

    case "$PACKAGE_MANAGER" in
        arch)
            vercmp "$curr" "$prev" || true
            ;;
        rpm)
            rpm --eval "%{lua: print(rpm.vercmp(\"$curr\", \"$prev\"))}"
            ;;
        *)
            printf 'Unsupported PACKAGE_MANAGER: %s\n' "$PACKAGE_MANAGER" >&2
            return 1
            ;;
    esac
}

mkdir -p "$out_dir"

declare -A prev_ver=() curr_ver=()

if [[ -n "$prev_file" && -s "$prev_file" ]]; then
    while read -r name ver; do
        [[ -n "${name:-}" ]] || continue
        prev_ver["$name"]=$ver
    done < "$prev_file"
fi

while read -r name ver; do
    [[ -n "${name:-}" ]] || continue
    curr_ver["$name"]=$ver
done < "$curr_file"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

: > "$tmp_dir/upgraded"
: > "$tmp_dir/downgraded"
: > "$tmp_dir/added"
: > "$tmp_dir/removed"

has_prev=false
if [[ ${#prev_ver[@]} -gt 0 ]]; then
    has_prev=true
fi

if [[ "$has_prev" == true ]]; then
    for name in "${!curr_ver[@]}"; do
        if [[ -z "${prev_ver[$name]+x}" ]]; then
            printf '%s\t%s\n' "$name" "${curr_ver[$name]}" >> "$tmp_dir/added"
            continue
        fi

        prev=${prev_ver[$name]}
        curr=${curr_ver[$name]}
        [[ "$prev" == "$curr" ]] && continue

        result=$(compare_versions "$curr" "$prev")
        [[ "$result" == "0" ]] && continue
        if [[ "$result" == "-1" ]]; then
            printf '%s\t%s\t%s\n' "$name" "$prev" "$curr" >> "$tmp_dir/downgraded"
        else
            printf '%s\t%s\t%s\n' "$name" "$prev" "$curr" >> "$tmp_dir/upgraded"
        fi
    done

    for name in "${!prev_ver[@]}"; do
        if [[ -z "${curr_ver[$name]+x}" ]]; then
            printf '%s\t%s\n' "$name" "${prev_ver[$name]}" >> "$tmp_dir/removed"
        fi
    done
fi

sort -o "$tmp_dir/upgraded" "$tmp_dir/upgraded"
sort -o "$tmp_dir/downgraded" "$tmp_dir/downgraded"
sort -o "$tmp_dir/added" "$tmp_dir/added"
sort -o "$tmp_dir/removed" "$tmp_dir/removed"

upgraded_count=$(wc -l < "$tmp_dir/upgraded")
downgraded_count=$(wc -l < "$tmp_dir/downgraded")
added_count=$(wc -l < "$tmp_dir/added")
removed_count=$(wc -l < "$tmp_dir/removed")
current_total=${#curr_ver[@]}
previous_total=${#prev_ver[@]}

json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

write_changes_md() {
    printf '# %s %s\n\n' "$IMAGE_TITLE" "$VERSION"
    printf -- '- 镜像：`%s`\n' "$IMAGE_REF"
    if [[ -n "$DIGEST" ]]; then
        printf -- '- Digest：`%s`\n' "$DIGEST"
    fi
    if [[ "$has_prev" == true && -n "$PREV_TAG" ]]; then
        printf -- '- 对比基线：`%s`\n' "$PREV_TAG"
    else
        printf -- '- 对比基线：首次构建（无对比基线）\n'
    fi
    printf -- '- 生成时间：%s\n\n' "$GENERATED_AT"

    printf '## 变更摘要\n\n'
    printf '| 类型 | 数量 |\n| --- | ---: |\n'
    printf '| 升级 | %s |\n' "$upgraded_count"
    printf '| 降级 | %s |\n' "$downgraded_count"
    printf '| 新增 | %s |\n' "$added_count"
    printf '| 删除 | %s |\n' "$removed_count"
    printf '| 当前包总数 | %s |\n\n' "$current_total"

    if [[ "$has_prev" != true ]]; then
        printf '首次构建，没有可对比的历史清单。\n\n'
    elif [[ "$upgraded_count" == 0 && "$downgraded_count" == 0 && "$added_count" == 0 && "$removed_count" == 0 ]]; then
        printf '没有检测到软件包变化。\n\n'
    fi

    if [[ "$upgraded_count" -gt 0 ]]; then
        printf '## 升级\n\n| 软件包 | 旧版本 | 新版本 |\n| --- | --- | --- |\n'
        while IFS=$'\t' read -r name prev curr; do
            printf '| `%s` | %s | %s |\n' "$name" "$prev" "$curr"
        done < "$tmp_dir/upgraded"
        printf '\n'
    fi

    if [[ "$downgraded_count" -gt 0 ]]; then
        printf '## 降级\n\n| 软件包 | 旧版本 | 新版本 |\n| --- | --- | --- |\n'
        while IFS=$'\t' read -r name prev curr; do
            printf '| `%s` | %s | %s |\n' "$name" "$prev" "$curr"
        done < "$tmp_dir/downgraded"
        printf '\n'
    fi

    if [[ "$added_count" -gt 0 ]]; then
        printf '## 新增\n\n| 软件包 | 版本 |\n| --- | --- |\n'
        while IFS=$'\t' read -r name ver; do
            printf '| `%s` | %s |\n' "$name" "$ver"
        done < "$tmp_dir/added"
        printf '\n'
    fi

    if [[ "$removed_count" -gt 0 ]]; then
        printf '## 删除\n\n| 软件包 | 版本 |\n| --- | --- |\n'
        while IFS=$'\t' read -r name ver; do
            printf '| `%s` | %s |\n' "$name" "$ver"
        done < "$tmp_dir/removed"
        printf '\n'
    fi

    printf '<details>\n<summary>当前完整软件包清单（%s 个）</summary>\n\n' "$current_total"
    printf '| 软件包 | 版本 |\n| --- | --- |\n'
    while read -r name ver; do
        [[ -n "${name:-}" ]] || continue
        printf '| `%s` | %s |\n' "$name" "$ver"
    done < <(sort "$curr_file")
    printf '\n</details>\n'
}

write_changes_json() {
    printf '{\n'
    printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
    printf '  "image": "%s",\n' "$(json_escape "$IMAGE_REF")"
    printf '  "digest": "%s",\n' "$(json_escape "$DIGEST")"
    printf '  "previous_release": "%s",\n' "$(json_escape "$PREV_TAG")"
    printf '  "generated_at": "%s",\n' "$(json_escape "$GENERATED_AT")"
    printf '  "has_previous": %s,\n' "$has_prev"
    printf '  "previous_total": %s,\n' "$previous_total"
    printf '  "current_total": %s,\n' "$current_total"
    printf '  "summary": {\n'
    printf '    "upgraded": %s,\n' "$upgraded_count"
    printf '    "downgraded": %s,\n' "$downgraded_count"
    printf '    "added": %s,\n' "$added_count"
    printf '    "removed": %s\n' "$removed_count"
    printf '  },\n'

    write_json_version_list() {
        local key=$1 file=$2 trailing=${3-}
        printf '  "%s": [' "$key"
        local first=1
        while IFS=$'\t' read -r name prev curr; do
            [[ -n "${name:-}" ]] || continue
            if [[ "$first" == 1 ]]; then
                printf '\n'
                first=0
            else
                printf ',\n'
            fi
            printf '    {"name": "%s", "previous": "%s", "current": "%s"}' \
                "$(json_escape "$name")" "$(json_escape "$prev")" "$(json_escape "$curr")"
        done < "$file"
        if [[ "$first" == 0 ]]; then
            printf '\n  '
        fi
        printf ']'
        [[ "$trailing" == "," ]] && printf ','
        printf '\n'
    }

    write_json_single_list() {
        local key=$1 file=$2 trailing=${3-}
        printf '  "%s": [' "$key"
        local first=1
        while IFS=$'\t' read -r name ver; do
            [[ -n "${name:-}" ]] || continue
            if [[ "$first" == 1 ]]; then
                printf '\n'
                first=0
            else
                printf ',\n'
            fi
            printf '    {"name": "%s", "version": "%s"}' \
                "$(json_escape "$name")" "$(json_escape "$ver")"
        done < "$file"
        if [[ "$first" == 0 ]]; then
            printf '\n  '
        fi
        printf ']'
        [[ "$trailing" == "," ]] && printf ','
        printf '\n'
    }

    write_json_version_list "upgraded" "$tmp_dir/upgraded" ","
    write_json_version_list "downgraded" "$tmp_dir/downgraded" ","
    write_json_single_list "added" "$tmp_dir/added" ","
    write_json_single_list "removed" "$tmp_dir/removed"
    printf '}\n'
}

write_packages_json() {
    printf '{\n'
    printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
    printf '  "image": "%s",\n' "$(json_escape "$IMAGE_REF")"
    printf '  "generated_at": "%s",\n' "$(json_escape "$GENERATED_AT")"
    printf '  "total": %s,\n' "$current_total"
    printf '  "packages": ['
    local first=1
    while read -r name ver; do
        [[ -n "${name:-}" ]] || continue
        if [[ "$first" == 1 ]]; then
            printf '\n'
            first=0
        else
            printf ',\n'
        fi
        printf '    {"name": "%s", "version": "%s"}' \
            "$(json_escape "$name")" "$(json_escape "$ver")"
    done < <(sort "$curr_file")
    if [[ "$first" == 0 ]]; then
        printf '\n  '
    fi
    printf ']\n}\n'
}

write_changes_md > "$out_dir/changes.md"
write_changes_json > "$out_dir/changes.json"
write_packages_json > "$out_dir/packages.json"
sort "$curr_file" > "$out_dir/packages.tsv"

printf 'Diff: %s upgraded, %s downgraded, %s added, %s removed (%s packages)\n' \
    "$upgraded_count" "$downgraded_count" "$added_count" "$removed_count" "$current_total"
