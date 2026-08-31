#!/usr/bin/env bash
# relocate.bash -- make macOS binaries self-contained by copying their
# /nix/store dylib closure into a bundle and rewriting install names.
#
# Usage: relocate.bash --out <bundle_root> [--dry-run] <binary>...
#
# Layout produced:
#   <bundle_root>/bin/<binary>     (inputs; executables or loadable dylibs)
#   <bundle_root>/lib/<name>.dylib (closure, referenced via @executable_path
#                                   from bin/ and @loader_path from lib/)
#
# Exit codes: 0 ok, 1 input error, 3 verification found leftover store refs.
set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

DRY_RUN=0
OUT=""
INPUTS=()

usage() {
    cat <<'EOF'
Usage: relocate.bash --out <bundle_root> [--dry-run] <binary>...

Copies each <binary> to <bundle_root>/bin, copies its transitive
/nix/store dylib closure to <bundle_root>/lib, rewrites install names
(@executable_path/../lib from bin, @loader_path from lib), and ad-hoc
re-signs everything. Verifies no /nix/store references remain.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="${2:?--out needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) printf 'unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
        *) INPUTS+=("$1"); shift ;;
    esac
done

[[ -n "$OUT" ]] || { printf -- '--out is required\n' >&2; exit 1; }
(( ${#INPUTS[@]} > 0 )) || { printf 'no input binaries given\n' >&2; exit 1; }
[[ "$OUT" != / && "$OUT" != "$HOME" ]] || { printf 'refusing OUT=%s\n' "$OUT" >&2; exit 1; }

run() {
    if (( DRY_RUN )); then
        printf 'DRY-RUN: '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# List non-system dylib dependencies of a Mach-O file (skips the id line).
# Anything that isn't an OS library or already-relative reference gets bundled.
store_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -Ev '^(/usr/lib/|/System/|@)' || true
}

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
QUEUE="$WORK/queue"
SEEN="$WORK/seen"
SRCMAP="$WORK/srcmap"   # tab-separated lines: <source_path>\t<dest_name>
: > "$QUEUE"; : > "$SEEN"; : > "$SRCMAP"

run mkdir -p -- "$OUT/bin" "$OUT/lib"

# Dest name for a source dylib path. Usually the basename; when two
# different sources share a basename (e.g. two libiconv builds), the
# later one is disambiguated with its store-hash prefix.
dest_name() {
    local dep="$1" mapped base
    mapped="$(awk -F'\t' -v p="$dep" '$1==p {print $2}' "$SRCMAP")"
    if [[ -n "$mapped" ]]; then
        printf '%s\n' "$mapped"
        return
    fi
    base="$(basename -- "$dep")"
    if awk -F'\t' '{print $2}' "$SRCMAP" | grep -Fxq -- "$base"; then
        local hash
        hash="$(printf '%s' "$dep" | sed -n 's|^/nix/store/\([a-z0-9]\{8\}\).*|\1|p')"
        [[ -n "$hash" ]] || hash="alt"
        base="$hash-$base"
    fi
    printf '%s\t%s\n' "$dep" "$base" >> "$SRCMAP"
    printf '%s\n' "$base"
}

enqueue() {
    local dep
    while IFS= read -r dep; do
        grep -Fxq -- "$dep" "$SEEN" 2>/dev/null && continue
        printf '%s\n' "$dep" >> "$SEEN"
        printf '%s\n' "$dep" >> "$QUEUE"
        dest_name "$dep" > /dev/null
    done < <(store_deps "$1")
}

# Rewrite the bundled-library references inside a copied file.
rewrite() {
    local file="$1" prefix="$2" dep name
    while IFS= read -r dep; do
        name="$(dest_name "$dep")"
        run install_name_tool -change "$dep" "$prefix/$name" "$file"
    done < <(store_deps "$file")
}

# 1. Copy inputs into bin/ and seed the queue from them.
for src in "${INPUTS[@]}"; do
    [[ -f "$src" ]] || { printf 'no such file: %s\n' "$src" >&2; exit 1; }
    dst="$OUT/bin/$(basename -- "$src")"
    run cp -- "$src" "$dst"
    run chmod u+w "$dst"
    enqueue "$src"
done

# 2. Drain the queue: copy each dylib into lib/, discovering new deps.
while [[ -s "$QUEUE" ]]; do
    dep="$(head -n1 -- "$QUEUE")"
    tail -n +2 -- "$QUEUE" > "$QUEUE.tmp" && mv -- "$QUEUE.tmp" "$QUEUE"
    dst="$OUT/lib/$(dest_name "$dep")"
    run cp -- "$dep" "$dst"
    run chmod u+w "$dst"
    enqueue "$dep"
done

# 3. Rewrite references, set ids, re-sign.
for src in "${INPUTS[@]}"; do
    dst="$OUT/bin/$(basename -- "$src")"
    rewrite "$dst" '@executable_path/../lib'
    run codesign --force -s - -- "$dst"
done
for dst in "$OUT/lib/"*.dylib; do
    run install_name_tool -id "@loader_path/$(basename -- "$dst")" "$dst"
    rewrite "$dst" '@loader_path'
    run codesign --force -s - -- "$dst"
done

# 4. Verify: no non-system absolute reference may survive in the bundle.
if (( ! DRY_RUN )); then
    bad=0
    for f in "$OUT/bin/"* "$OUT/lib/"*; do
        if [[ -n "$(store_deps "$f")" ]]; then
            printf 'LEFTOVER non-system ref in %s\n' "$f" >&2
            store_deps "$f" >&2
            bad=1
        fi
    done
    (( bad )) && exit 3
    count="$(find "$OUT/lib" -name '*.dylib' | wc -l | tr -d ' ')"
    printf 'OK: %s inputs, %s dylibs bundled, no store references remain\n' \
        "${#INPUTS[@]}" "$count"
fi
