#!/usr/bin/env bash
# sstate-cache artifact capture and restore helper.
#
# v2 adds OverlayFS-based capture (kernel intercepts writes during install),
# with file-list-based tar as fallback for systems without user namespaces.
#
# Subcommands:
#   check                         Test if OverlayFS capture is supported
#   restore --tarball --dest      Extract cached artifact to destination
#   capture --file-list --output --dest  File-list-based tarball creation
#   overlay --dest --output --script    OverlayFS-based capture
#
# Usage:
#   capture-overlay.sh check
#   capture-overlay.sh restore --tarball <file> --dest <dir>
#   capture-overlay.sh capture --file-list <file> --output <file> --dest <dir>
#   capture-overlay.sh overlay --dest <dir> --output <file> --script <file>

set -e

CMD="$1"
shift

sstate_restore() {
    local tarball="$1" dest="$2"

    if [ ! -f "$tarball" ]; then
        return 1
    fi

    if [ ! -s "$tarball" ]; then
        # Empty tarball: nothing to restore
        return 0
    fi

    mkdir -p "$dest"
    if ! tar xzf "$tarball" -C "$dest"; then
        echo "ERROR: failed to extract sstate tarball: $tarball" >&2
        echo "The cache artifact may be corrupted. Rebuilding package." >&2
        rm -f "$tarball"
        return 1
    fi
}

sstate_capture_filelist() {
    local file_list="$1" output="$2" dest="$3"

    if [ ! -f "$file_list" ] || [ ! -s "$file_list" ]; then
        mkdir -p "$(dirname "$output")"
        tar czf "$output" --files-from /dev/null
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/sstate-filelist.XXXXXX)
    # shellcheck disable=SC2064
    trap 'rm -f "$tmpfile"' EXIT

    sed -n 's/^[^,]*,//p' "$file_list" > "$tmpfile"

    if [ ! -s "$tmpfile" ]; then
        mkdir -p "$(dirname "$output")"
        tar czf "$output" --files-from /dev/null
        return 0
    fi

    # Tar from within DEST so relative paths resolve correctly.
    local output_abs
    output_abs="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
    mkdir -p "$(dirname "$output_abs")"

    if ( cd "$dest" && tar czf "${output_abs}.tmp" --files-from "$tmpfile" ); then
        mv "${output_abs}.tmp" "$output_abs"
    else
        rm -f "${output_abs}.tmp"
        echo "ERROR: failed to create sstate tarball: $output" >&2
        return 1
    fi
    rm -f "$tmpfile"
}

sstate_overlay_capture() {
    local dest="$1" output="$2" script="$3"

    if [ ! -f "$script" ] || [ ! -s "$script" ]; then
        echo "ERROR: install script not found or empty: $script" >&2
        return 1
    fi

    # Create temp dirs for overlay upper and work layers
    local tmpdir upper work
    tmpdir=$(mktemp -d /tmp/sstate-overlay.XXXXXX)
    upper="$tmpdir/upper"
    work="$tmpdir/work"
    mkdir -p "$upper" "$work"

    # The install script runs inside a user+mount namespace where
    # OverlayFS is mounted over $dest, intercepting all writes to $upper.
    local rc=0
    if ! unshare -Urm bash -c "
        mount -t overlay overlay -o lowerdir='$dest',upperdir='$upper',workdir='$work' '$dest' || exit 1
        bash '$script'
        ret=\$?
        umount '$dest' 2>/dev/null || true
        exit \$ret
    "; then
        rc=1
    fi

    # Package the captured files and sync them to the real destination
    if [ "$rc" -eq 0 ]; then
        mkdir -p "$(dirname "$output")"

        # Create tarball from upper layer (atomic via tempfile+rename)
        if ( cd "$upper" && tar czf "${output}.tmp" . ); then
            mv "${output}.tmp" "$output"
        else
            rm -f "${output}.tmp"
            echo "ERROR: failed to create OverlayFS sstate tarball: $output" >&2
            rc=1
        fi

        # Sync captured files to the real destination
        # --no-owner --no-group avoids chown/chgrp failures in user namespaces
        if [ -n "$(ls -A "$upper" 2>/dev/null)" ]; then
            rsync -rlptD --no-owner --no-group "$upper/" "$dest/"
        fi
    fi

    rm -rf "$tmpdir" 2>/dev/null || true
    return $rc
}

case "$CMD" in
check)
    if unshare -Urm true 2>/dev/null; then
        echo "supported"
    else
        echo "unsupported"
    fi
    ;;

restore)
    TARBALL=""
    DEST=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tarball) TARBALL="$2"; shift 2 ;;
            --dest)    DEST="$2"; shift 2 ;;
            *) echo "ERROR: unknown restore arg: $1" >&2; exit 1 ;;
        esac
    done
    [ -z "$TARBALL" ] && { echo "ERROR: --tarball required" >&2; exit 1; }
    [ -z "$DEST" ] && { echo "ERROR: --dest required" >&2; exit 1; }
    sstate_restore "$TARBALL" "$DEST"
    ;;

capture)
    FILE_LIST=""
    OUTPUT=""
    DEST=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file-list) FILE_LIST="$2"; shift 2 ;;
            --output)    OUTPUT="$2"; shift 2 ;;
            --dest)      DEST="$2"; shift 2 ;;
            *) echo "ERROR: unknown capture arg: $1" >&2; exit 1 ;;
        esac
    done
    [ -z "$FILE_LIST" ] && { echo "ERROR: --file-list required" >&2; exit 1; }
    [ -z "$OUTPUT" ] && { echo "ERROR: --output required" >&2; exit 1; }
    [ -z "$DEST" ] && { echo "ERROR: --dest required" >&2; exit 1; }
    sstate_capture_filelist "$FILE_LIST" "$OUTPUT" "$DEST"
    ;;

overlay)
    DEST=""
    OUTPUT=""
    SCRIPT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dest)   DEST="$2"; shift 2 ;;
            --output) OUTPUT="$2"; shift 2 ;;
            --script) SCRIPT="$2"; shift 2 ;;
            *) echo "ERROR: unknown overlay arg: $1" >&2; exit 1 ;;
        esac
    done
    [ -z "$DEST" ] && { echo "ERROR: --dest required" >&2; exit 1; }
    [ -z "$OUTPUT" ] && { echo "ERROR: --output required" >&2; exit 1; }
    [ -z "$SCRIPT" ] && { echo "ERROR: --script required" >&2; exit 1; }
    sstate_overlay_capture "$DEST" "$OUTPUT" "$SCRIPT"
    ;;

*)
    echo "ERROR: unknown subcommand: $CMD" >&2
    echo "Usage: $0 {check|restore|capture|overlay}" >&2
    exit 1
    ;;
esac
