#!/usr/bin/env bash
# Compute a package state signature (SHA256 hash) for sstate-cache.
#
# This script aggregates the package recipe, patches, a targeted subset
# of Buildroot config variables, source tarball, and dependency hashes
# into a single deterministic hash. The hash is used as the cache key
# for sstate artifacts.
#
# Usage:
#   compute-hash.sh --pkg-dir <dir> --config <file> --hash-dir <dir> \
#       --output <file> [--source <file>] \
#       [--patch <file> ...] [--dep <name> ...]
#
# Outputs:
#   - Writes hex hash to --output file (in package build dir)
#   - Writes hex hash to --hash-dir/<pkg-name>.hash (for dependents)
#   - Echoes hex hash to stdout

set -e

PKG_NAME=""
PKG_DIR=""
CONFIG_FILE=""
HASH_DIR=""
OUTPUT_FILE=""
SOURCE_FILE=""
PATCH_FILES=()
DEPS=()

# Sorted list of BR2_ config key prefixes that affect binary build output.
# Only variables matching these prefixes (followed by =) are hashed.
# This avoids invalidating all caches when an unrelated package is added
# or removed from the config.
#
# Categories:
#   Architecture:   BR2_ARCH, BR2_ENDIAN, BR2_BINFMT, BR2_GCC_TARGET
#   Compiler:       BR2_GCC_VERSION, BR2_BINUTILS_VERSION,
#                   BR2_GCC_ENABLE, BR2_EXTRA_GCC_CONFIG_OPTIONS,
#                   BR2_EXTRA_BINUTILS_CONFIG_OPTIONS
#   C library:      BR2_TOOLCHAIN_BUILDROOT_LIBC, BR2_TOOLCHAIN_USES
#   External TC:    BR2_TOOLCHAIN_EXTERNAL_PATH,
#                   BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX,
#                   BR2_TOOLCHAIN_EXTERNAL_CUSTOM_GLIBC
#   Kernel headers: BR2_TOOLCHAIN_HEADERS_AT_LEAST (resolved version)
#   Optimization:   BR2_OPTIMIZE
#   PIC/SSP/RELRO:  BR2_PIC_PIE, BR2_SSP, BR2_FORTIFY, BR2_RELRO
#   Shared/static:  BR2_SHARED_LIBS, BR2_SHARED_STATIC_LIBS, BR2_STATIC_LIBS
#   Debug/strip:    BR2_ENABLE_DEBUG, BR2_DEBUG, BR2_STRIP
#   Build options:  BR2_REPRODUCIBLE, BR2_PER_PACKAGE_DIRECTORIES,
#                   BR2_TARGET_OPTIMIZATION
#   Global patches: BR2_GLOBAL_PATCH_DIR
#
# NOTE: the trailing '=' in the grep pattern ensures we match the
# resolved value line (e.g. BR2_GCC_VERSION="15.3.0"), not the
# choice menu entry (BR2_GCC_VERSION_15_X=y).
CONFIG_KEY_PREFIXES=(
    "BR2_ARCH="
    "BR2_ENDIAN="
    "BR2_BINFMT_"
    "BR2_GCC_TARGET_"
    "BR2_GCC_VERSION="
    "BR2_GCC_ENABLE_"
    "BR2_EXTRA_GCC_CONFIG_OPTIONS="
    "BR2_BINUTILS_VERSION="
    "BR2_EXTRA_BINUTILS_CONFIG_OPTIONS="
    "BR2_TOOLCHAIN_BUILDROOT_LIBC="
    "BR2_TOOLCHAIN_USES_"
    "BR2_TOOLCHAIN_EXTERNAL_PATH="
    "BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX="
    "BR2_TOOLCHAIN_EXTERNAL_CUSTOM_GLIBC="
    "BR2_TOOLCHAIN_HEADERS_AT_LEAST="
    "BR2_OPTIMIZE_"
    "BR2_PIC_PIE"
    "BR2_SSP_"
    "BR2_FORTIFY_"
    "BR2_RELRO_"
    "BR2_SHARED_LIBS="
    "BR2_SHARED_STATIC_LIBS="
    "BR2_STATIC_LIBS="
    "BR2_ENABLE_DEBUG="
    "BR2_DEBUG_"
    "BR2_STRIP_"
    "BR2_REPRODUCIBLE="
    "BR2_PER_PACKAGE_DIRECTORIES="
    "BR2_TARGET_OPTIMIZATION="
    "BR2_GLOBAL_PATCH_DIR="
)

# compute_prebuild_hash <dep-name>
# Compute a pre-build hash for a dependency that has no cached hash file.
# Hashes the same inputs that would be hashed once the dep is built:
# recipe .mk files, patches, source tarball, and targeted config.
# Dependency hashes are NOT included (the dep's deps are unknown).
# The result is stable across builds and matches the first-build hash.
compute_prebuild_hash() {
    local dep="$1"
    local dep_raw dep_dir dep_source hash_input

    dep_raw="${dep#host-}"
    dep_dir=""
    for d in "package/${dep}" "package/${dep_raw}" \
             "boot/${dep}" "boot/${dep_raw}" \
             "linux" "toolchain/${dep}"; do
        if [ -d "${d}" ] && ls "${d}"/*.mk >/dev/null 2>&1; then
            dep_dir="${d}"
            break
        fi
    done

    # Hash recipe .mk files
    if [ -n "${dep_dir}" ]; then
        find "${dep_dir}" -maxdepth 1 -name '*.mk' -type f | sort | \
            xargs sha256sum
    fi

    # Hash patches
    if [ -n "${dep_dir}" ]; then
        find "${dep_dir}" -maxdepth 1 -name '*.patch' -type f | sort | \
            xargs sha256sum 2>/dev/null
        if [ "${dep_raw}" != "${dep}" ]; then
            # Check versioned patches too
            local dep_ver
            dep_ver=$(grep -m1 "^${dep}_VERSION\s*=\|^${dep_raw}_VERSION\s*=" "${dep_dir}"/*.mk 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '\n')
            if [ -n "${dep_ver}" ] && [ -d "${dep_dir}/${dep_ver}" ]; then
                find "${dep_dir}/${dep_ver}" -name '*.patch' -type f | sort | \
                    xargs sha256sum 2>/dev/null
            fi
        fi
    fi

    # Hash source tarball (look up _SOURCE and _SITE from .mk)
    if [ -n "${dep_dir}" ]; then
        local dep_source dep_dl_dir
        dep_source=$(grep -m1 "^\(${dep^^}\|${dep_raw^^}\)\?_SOURCE\s*=" "${dep_dir}"/*.mk 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '\n')
        if [ -n "${dep_source}" ]; then
            dep_dl_dir="${CONFIG_FILE%/*}/dl/${dep_raw}"
            [ -f "${dep_dl_dir}/${dep_source}" ] && sha256sum "${dep_dl_dir}/${dep_source}" 2>/dev/null
        fi
    fi

    # Hash targeted config (same as the main package would)
    {
        local prefix escaped greplist
        greplist=""
        for prefix in "${CONFIG_KEY_PREFIXES[@]}"; do
            escaped=$(printf '%s' "$prefix" | sed 's/[]\\.*^$[]/\\&/g')
            if [ -z "$greplist" ]; then
                greplist="^(${escaped}"
            else
                greplist="${greplist}|${escaped}"
            fi
        done
        greplist="${greplist})"
        grep -E "$greplist" "$CONFIG_FILE" | LC_ALL=C sort
    }
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --pkg-name)
            PKG_NAME="$2"; shift 2 ;;
        --pkg-dir)
            PKG_DIR="$2"; shift 2 ;;
        --config)
            CONFIG_FILE="$2"; shift 2 ;;
        --hash-dir)
            HASH_DIR="$2"; shift 2 ;;
        --output)
            OUTPUT_FILE="$2"; shift 2 ;;
        --source)
            SOURCE_FILE="$2"; shift 2 ;;
        --patch)
            PATCH_FILES+=("$2"); shift 2 ;;
        --dep)
            DEPS+=("$2"); shift 2 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$PKG_NAME" ] || [ -z "$PKG_DIR" ] || [ -z "$CONFIG_FILE" ] || \
   [ -z "$HASH_DIR" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "ERROR: missing required arguments" >&2
    echo "Usage: $0 --pkg-name <name> --pkg-dir <dir> --config <file> --hash-dir <dir> --output <file> [--source <file>] [--patch <file> ...] [--dep <name> ...]" >&2
    exit 1
fi

# Create temp directory for intermediate files
TMPDIR=$(mktemp -d /tmp/compute-hash.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Collect all input data into a single file for hashing
INPUT_FILE="$TMPDIR/input-data"
>"$INPUT_FILE"  # Create/truncate

# 1. Hash all .mk files in the package directory
echo "=== Recipe: .mk files ===" >> "$INPUT_FILE"
if [ -d "$PKG_DIR" ]; then
    find "$PKG_DIR" -maxdepth 1 -name '*.mk' -type f | sort | while read -r mkfile; do
        sha256sum "$mkfile" | cut -d' ' -f1 >> "$INPUT_FILE"
        echo "  $mkfile" >> "$INPUT_FILE"
    done
fi

# Also include the package's .hash file if present
HASH_FILE_BASE="${PKG_DIR}/${PKG_NAME##*/}.hash"
if [ -f "$HASH_FILE_BASE" ]; then
    sha256sum "$HASH_FILE_BASE" | cut -d' ' -f1 >> "$INPUT_FILE"
    echo "  $HASH_FILE_BASE" >> "$INPUT_FILE"
fi

# 2. Hash all patch files (sorted for determinism)
echo "=== Patches ===" >> "$INPUT_FILE"
if [ ${#PATCH_FILES[@]} -gt 0 ]; then
    # Sort patches by filename
    IFS=$'\n' sorted_patches=($(sort <<<"${PATCH_FILES[*]}"))
    unset IFS
    for patch in "${sorted_patches[@]}"; do
        if [ -f "$patch" ]; then
            sha256sum "$patch" | cut -d' ' -f1 >> "$INPUT_FILE"
            echo "  $patch" >> "$INPUT_FILE"
        fi
    done
fi

# 3. Hash only the config variables that affect binary build output.
#    This is a targeted subset rather than the entire .config, so that
#    adding or removing unrelated packages does not invalidate the cache.
echo "=== Buildroot config (targeted) ===" >> "$INPUT_FILE"
if [ -f "$CONFIG_FILE" ]; then
    # Build a grep pattern from the key prefixes
    GREP_PATTERN="^("
    for prefix in "${CONFIG_KEY_PREFIXES[@]}"; do
        # Escape regex metacharacters in the prefix
        escaped=$(printf '%s' "$prefix" | sed 's/[]\\.*^$[]/\\&/g')
        if [ "$GREP_PATTERN" = "^(" ]; then
            GREP_PATTERN="${GREP_PATTERN}${escaped}"
        else
            GREP_PATTERN="${GREP_PATTERN}|${escaped}"
        fi
    done
    GREP_PATTERN="${GREP_PATTERN})"

    # Extract matching lines, sort for determinism, and hash
    grep -E "$GREP_PATTERN" "$CONFIG_FILE" | LC_ALL=C sort > "$TMPDIR/config-filtered"
    if [ -s "$TMPDIR/config-filtered" ]; then
        cat "$TMPDIR/config-filtered" >> "$INPUT_FILE"
        echo "  ($(wc -l < "$TMPDIR/config-filtered") config variables)" >> "$INPUT_FILE"
    else
        echo "EMPTY_TARGETED_CONFIG" >> "$INPUT_FILE"
    fi
else
    echo "WARNING: config file not found: $CONFIG_FILE" >&2
    echo "NO_CONFIG" >> "$INPUT_FILE"
fi

# 4. Hash source tarball if provided
echo "=== Source ===" >> "$INPUT_FILE"
if [ -n "$SOURCE_FILE" ] && [ -f "$SOURCE_FILE" ]; then
    sha256sum "$SOURCE_FILE" | cut -d' ' -f1 >> "$INPUT_FILE"
    echo "  $SOURCE_FILE" >> "$INPUT_FILE"
else
    echo "NO_SOURCE" >> "$INPUT_FILE"
fi

# 5. Hash dependency states (cascading invalidation)
echo "=== Dependencies ===" >> "$INPUT_FILE"
if [ ${#DEPS[@]} -gt 0 ]; then
    # Sort deps for determinism
    IFS=$'\n' sorted_deps=($(sort <<<"${DEPS[*]}"))
    unset IFS
    for dep in "${sorted_deps[@]}"; do
        # Read all hash files for this dependency. Multiple revisions
        # can coexist (e.g. host-libzlib-ABC.hash, host-libzlib-DEF.hash).
        # Sorting ensures deterministic hashing regardless of directory order.
        DEP_FILES=$(ls "$HASH_DIR/${dep}-"*.hash 2>/dev/null | sort)
        if [ -n "$DEP_FILES" ]; then
            cat $DEP_FILES >> "$INPUT_FILE"
            echo "  $dep = $(echo $DEP_FILES | wc -w) revision(s)" >> "$INPUT_FILE"
        else
            # Use a pre-build hash that mirrors what the dep will hash
            # once built: recipe .mk files + patches + source tarball +
            # targeted config. This is slower than a cached hash file
            # but ensures the hash is stable from build 1 (no RECIPE
            # fallback that changes to a different value on build 2).
            compute_prebuild_hash "$dep" >> "$INPUT_FILE"
            echo "  $dep = prebuild" >> "$INPUT_FILE"
        fi
    done
else
    echo "NO_DEPENDENCIES" >> "$INPUT_FILE"
fi

# Compute final SHA256 hash
FINAL_HASH=$(sha256sum "$INPUT_FILE" | cut -d' ' -f1)

# Write hash to output file (atomic: write to tmp, then rename)
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"
echo "$FINAL_HASH" > "${OUTPUT_FILE}.tmp"
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

# Save debug log: the full input data used to compute this hash.
# Written to <pkg>-<hash>.log for troubleshooting hash mismatches.
mkdir -p "$HASH_DIR"
cp "$INPUT_FILE" "${HASH_DIR}/${PKG_NAME}-${FINAL_HASH}.log"

echo "$FINAL_HASH"
