#!/bin/sh
# Install, check, or update the prototype-first OpenSpec schema in a project.
#
# Remote install:
#   curl -fsSL https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.sh | sh
#
# Remote check (exit 0 = current, 1 = update available or not installed):
#   curl -fsSL https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.sh | sh -s -- --check
#
# Local (from a clone of this repository):
#   ./scripts/install.sh
#
# The schema is installed into ./openspec/schemas/prototype-first and selected
# in ./openspec/config.yaml. Run from an OpenSpec project root, or pass --dir.
#
# Design notes:
# - Installs are pinned to a release tag (DEFAULT_REF) rather than the tip of
#   main, so recurring installs are reproducible.
# - Every install writes openspec/schemas/prototype-first/.install.json with the
#   version, ref, source, timestamp, and a SHA-256 per file. The stamp is how
#   --check and --upgrade know what is installed and whether a file was edited.
# - The script is intentionally POSIX sh only: it runs through `sh -s` when
#   piped from curl, so bashisms, jq, and GNU-only flags are not available.

set -eu

SCHEMA_NAME="prototype-first"
# Release tag installed by default. release-please rewrites the version on this
# exact line when it prepares a release, so keep the annotation and the
# `DEFAULT_REF="vX.Y.Z"` shape intact.
DEFAULT_REF="v1.2.0" # x-release-please-version
DEFAULT_REPO_URL="https://raw.githubusercontent.com/tiagosantini/openspec-schemas"

TARGET_DIR="${SCHEMA_TARGET_DIR:-$PWD}"
SELECT_SCHEMA=1
ACTION=install
FORCE=0

# Track whether the ref came from the caller: with an explicit ref the version
# is read from that ref, otherwise from the repository root (default branch,
# which only moves when a release PR is merged).
REF_SET=0
if [ -n "${SCHEMA_REF:-}" ]; then
  REF_SET=1
else
  SCHEMA_REF=$DEFAULT_REF
fi

# The repository URL is tracked separately from the schema base URL so version
# lookups still work when only SCHEMA_BASE_URL is overridden (tests, mirrors).
REPO_SET=0
if [ -n "${SCHEMA_REPO_URL:-}" ]; then
  REPO_SET=1
else
  SCHEMA_REPO_URL=$DEFAULT_REPO_URL
fi

# Test hook: record a version without downloading version.txt.
TARGET_VERSION_OVERRIDE="${SCHEMA_VERSION:-}"

# Files that make up the installed schema. The stamp is deliberately absent:
# it is generated after the copy and must never be hashed or downloaded.
FILES="README.md schema.yaml templates/design.md templates/proposal.md templates/prototype.html templates/spec.md templates/tasks.md"

WORKDIR=""
BACKUP=""
HASHER=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

usage() {
  cat <<EOF
Install, check, or update the ${SCHEMA_NAME} OpenSpec schema.

Usage:
  scripts/install.sh [options]

Options:
  --dir <path>    Project root to install into (default: current directory)
  --ref <ref>     Release tag or branch to install (default: ${DEFAULT_REF})
  --check         Report whether the installed schema is up to date
  --upgrade       Update an existing installation, refusing local changes
  --force         Overwrite local changes and reinstall even when up to date
  --version       Print the installed schema version
  --select        Select the schema in openspec/config.yaml (default)
  --no-select     Leave openspec/config.yaml unchanged
  -h, --help      Show this help

Exit codes for --check:
  0  installed version is current
  1  update available, or the schema is not installed
  2  the latest version could not be determined

Environment:
  SCHEMA_REF         Release tag or branch to install
  SCHEMA_REPO_URL    Repository raw URL (default: ${DEFAULT_REPO_URL})
  SCHEMA_BASE_URL    Full schema base URL, overriding SCHEMA_REF and SCHEMA_REPO_URL
  SCHEMA_VERSION     Record this version instead of reading version.txt
  SCHEMA_TARGET_DIR  Project root (same as --dir)

The script uses the local schemas/${SCHEMA_NAME} directory when run from a
checkout of this repository. Otherwise it downloads the schema from the ref.
EOF
}

cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}

trap cleanup 0
trap 'exit 1' 1 2 3 15

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -ge 2 ] || die "--dir requires a path"
      TARGET_DIR=$2
      shift 2
      ;;
    --dir=*)
      TARGET_DIR=${1#--dir=}
      shift
      ;;
    --ref)
      [ $# -ge 2 ] || die "--ref requires a tag or branch"
      SCHEMA_REF=$2
      REF_SET=1
      shift 2
      ;;
    --ref=*)
      SCHEMA_REF=${1#--ref=}
      REF_SET=1
      shift
      ;;
    --check)
      ACTION=check
      shift
      ;;
    --upgrade)
      ACTION=upgrade
      shift
      ;;
    --version)
      ACTION=version
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --select)
      SELECT_SCHEMA=1
      shift
      ;;
    --no-select)
      SELECT_SCHEMA=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

# Refs are interpolated into raw URLs, so reject anything that is not a plain
# tag or branch name. `..`, a leading dot, and leading/trailing slashes would
# otherwise let the value escape the intended path.
case "$SCHEMA_REF" in
  ""|-*|.*|*..*|/*|*/|*[!A-Za-z0-9._/-]*)
    die "invalid ref: ${SCHEMA_REF}"
    ;;
esac

# SCHEMA_BASE_URL wins for compatibility with mirrors and the CI HTTP server.
# When it is used, recover the repository root by stripping the schema path so
# version.txt can still be fetched.
if [ -n "${SCHEMA_BASE_URL:-}" ]; then
  BASE_URL=$SCHEMA_BASE_URL
  if [ "$REPO_SET" -eq 0 ]; then
    case "$BASE_URL" in
      */schemas/"$SCHEMA_NAME") SCHEMA_REPO_URL=${BASE_URL%/schemas/"$SCHEMA_NAME"} ;;
    esac
  fi
else
  BASE_URL="$SCHEMA_REPO_URL/$SCHEMA_REF/schemas/$SCHEMA_NAME"
fi

[ -n "$TARGET_DIR" ] || die "target directory is empty"
[ -d "$TARGET_DIR" ] || die "target directory does not exist: $TARGET_DIR"
TARGET_DIR=$(unset CDPATH; cd -- "$TARGET_DIR" && pwd)

OPENSPEC_DIR="${TARGET_DIR}/openspec"
CONFIG="${OPENSPEC_DIR}/config.yaml"
DEST="${OPENSPEC_DIR}/schemas/${SCHEMA_NAME}"
STAMP="${DEST}/.install.json"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/${SCHEMA_NAME}.XXXXXX") || die "could not create a temporary directory"

# Prefer the checkout this script belongs to. When piped, $0 is "sh" and this
# check is skipped, so the schema is downloaded instead.
LOCAL_SOURCE=""
if [ -f "$0" ]; then
  SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
  REPO_ROOT=$(unset CDPATH; cd -- "${SCRIPT_DIR}/.." && pwd)
  if [ -f "${REPO_ROOT}/schemas/${SCHEMA_NAME}/schema.yaml" ]; then
    LOCAL_SOURCE="${REPO_ROOT}/schemas/${SCHEMA_NAME}"
  fi
fi

# SHA-256 tool detection. sha256sum is Linux, shasum is macOS, openssl is the
# last resort. Without one of them drift detection is skipped and the stamp
# records no hashes.
if command -v sha256sum >/dev/null 2>&1; then
  HASHER=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASHER=shasum
elif command -v openssl >/dev/null 2>&1; then
  HASHER=openssl
fi

hash_file() {
  case "$HASHER" in
    sha256sum) sha256sum "$1" | awk '{print $1}' ;;
    shasum) shasum -a 256 "$1" | awk '{print $1}' ;;
    openssl) openssl dgst -sha256 -r "$1" | awk '{print $1}' ;;
    *) printf '' ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

fetch_to() {
  fetch_url=$1
  fetch_dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "$fetch_url" -o "$fetch_dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=15 -O "$fetch_dest" "$fetch_url"
  else
    die "curl or wget is required to download the schema"
  fi
}

read_version_file() {
  [ -s "$1" ] || return 0
  tr -d '[:space:]' < "$1"
}

# Prints the trimmed contents of a remote version.txt, or nothing when the URL
# is unavailable. Unavailable is a normal outcome here (mirrors, offline), so
# callers decide what to do instead of aborting.
fetch_version() {
  version_tmp="${WORKDIR}/version.$$"
  if fetch_to "$1" "$version_tmp" >/dev/null 2>&1; then
    read_version_file "$version_tmp"
  fi
  rm -f "$version_tmp"
  return 0
}

# Prints the tag_name from a GitHub releases API response, or nothing when the
# endpoint is unreachable, rate-limited, or the repository has no releases.
fetch_latest_tag() {
  tag_tmp="${WORKDIR}/latest.$$"
  if fetch_to "$1" "$tag_tmp" >/dev/null 2>&1; then
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$tag_tmp" | head -n 1
  fi
  rm -f "$tag_tmp"
  return 0
}

# Latest known version for the selected ref. Local checkouts compare against
# their own version.txt. Remote installs read version.txt at the ref they are
# installing, falling back to the repository root for mirrors and the CI server
# that serve the tree without ref directories.
resolve_install_version() {
  if [ "$TARGET_VERSION_OVERRIDE" != "" ]; then
    TARGET_VERSION=$TARGET_VERSION_OVERRIDE
    return 0
  fi

  if [ -n "$LOCAL_SOURCE" ] && [ -f "${REPO_ROOT}/version.txt" ]; then
    TARGET_VERSION=$(read_version_file "${REPO_ROOT}/version.txt")
    return 0
  fi

  TARGET_VERSION=$(fetch_version "$SCHEMA_REPO_URL/$SCHEMA_REF/version.txt")
  if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(fetch_version "$SCHEMA_REPO_URL/version.txt")
  fi
}

# Latest release, used only by --check. raw.githubusercontent.com requires a
# ref, so the repository root is not a valid URL there: query the GitHub
# release API first, then HEAD (the default branch), then mirror layouts.
resolve_latest_version() {
  if [ "$TARGET_VERSION_OVERRIDE" != "" ]; then
    TARGET_VERSION=$TARGET_VERSION_OVERRIDE
    return 0
  fi

  if [ -n "$LOCAL_SOURCE" ] && [ -f "${REPO_ROOT}/version.txt" ]; then
    TARGET_VERSION=$(read_version_file "${REPO_ROOT}/version.txt")
    return 0
  fi

  if [ "$REF_SET" -eq 1 ]; then
    TARGET_VERSION=$(fetch_version "$SCHEMA_REPO_URL/$SCHEMA_REF/version.txt")
    return 0
  fi

  TARGET_VERSION=""
  repo_path=${SCHEMA_REPO_URL#https://raw.githubusercontent.com/}
  if [ "$repo_path" != "$SCHEMA_REPO_URL" ]; then
    latest_tag=$(fetch_latest_tag "https://api.github.com/repos/${repo_path}/releases/latest")
    if [ -n "$latest_tag" ]; then
      TARGET_VERSION=${latest_tag#v}
      return 0
    fi
  fi

  TARGET_VERSION=$(fetch_version "$SCHEMA_REPO_URL/HEAD/version.txt")
  if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(fetch_version "$SCHEMA_REPO_URL/version.txt")
  fi
  if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(fetch_version "$SCHEMA_REPO_URL/$SCHEMA_REF/version.txt")
  fi
}

normalize_version() {
  printf '%s' "$1" | sed 's/^v//; s/[-+].*$//'
}

version_gt() {
  awk -v a="$(normalize_version "$1")" -v b="$(normalize_version "$2")" 'BEGIN {
    n = split(a, av, ".");
    m = split(b, bv, ".");
    k = (n > m) ? n : m;
    for (i = 1; i <= k; i++) {
      x = (i <= n) ? av[i] + 0 : 0;
      y = (i <= m) ? bv[i] + 0 : 0;
      if (x > y) { print 1; exit }
      if (x < y) { print 0; exit }
    }
    print 0;
  }'
}

stamp_field() {
  # Reads a top-level string field from .install.json. The leading whitespace
  # pattern accepts both the 2-space JSON this script writes and the 4-space
  # output of PowerShell's ConvertTo-Json.
  [ -f "$STAMP" ] || return 0
  sed -n "s/^[[:space:]]*\"$1\": \"\\([^\"]*\\)\".*/\\1/p" "$STAMP" | head -n 1
}

stamp_hash() {
  # Extracts `"path": "<sha256>"` from the files object. grep -F avoids having
  # to escape dots and slashes in paths; the first match is enough because the
  # files list has unique keys.
  [ -f "$STAMP" ] || return 0
  line=$(grep -F "\"$1\": \"" "$STAMP" | head -n 1) || true
  [ -n "$line" ] || return 0
  value=${line#*\": \"}
  printf '%s' "${value%%\"*}"
}

INSTALLED_VERSION=""
if [ -f "$STAMP" ]; then
  INSTALLED_VERSION=$(stamp_field version)
fi

# Drift = files whose current hash differs from the hash recorded at install
# time. A stamp is required: without it there is no baseline, so the script
# cannot tell an older version from a local edit and backs up instead of
# blocking (see the persistent backup below).
DRIFT=""
if [ -f "$STAMP" ] && [ -n "$HASHER" ]; then
  for file in $FILES; do
    expected=$(stamp_hash "$file")
    [ -n "$expected" ] || continue
    if [ ! -f "${DEST}/${file}" ]; then
      DRIFT="${DRIFT}
  deleted: ${file}"
    elif [ "$(hash_file "${DEST}/${file}")" != "$expected" ]; then
      DRIFT="${DRIFT}
  modified: ${file}"
    fi
  done
fi

case "$ACTION" in
  check)
    resolve_latest_version
    ;;
  version)
    ;;
  *)
    resolve_install_version
    ;;
esac

# --version is read-only and always exits 0: it reports what is installed,
# including the "unknown" case for installations made before stamping.
if [ "$ACTION" = "version" ]; then
  if [ -f "$STAMP" ]; then
    info "Installed: ${INSTALLED_VERSION:-unknown} (ref $(stamp_field ref))"
    info "Path: ${DEST}"
  elif [ -d "$DEST" ]; then
    info "Installed: unknown (no version stamp; reinstall to start tracking)"
    info "Path: ${DEST}"
  else
    info "Not installed in ${TARGET_DIR}"
  fi
  exit 0
fi

# --check never modifies the project. Exit codes are part of the interface:
# 0 current, 1 outdated/not installed, 2 cannot determine the latest version.
if [ "$ACTION" = "check" ]; then
  if [ ! -d "$DEST" ]; then
    info "Not installed in ${TARGET_DIR}"
    info "Install it with: scripts/install.sh"
    exit 1
  fi
  if [ -z "$INSTALLED_VERSION" ]; then
    info "Installed: unknown (no version stamp; reinstall to start tracking)"
    exit 1
  fi
  if [ -z "$TARGET_VERSION" ]; then
    info "Installed: ${INSTALLED_VERSION}"
    info "error: could not determine the latest version" >&2
    exit 2
  fi
  if [ "$(normalize_version "$INSTALLED_VERSION")" = "$(normalize_version "$TARGET_VERSION")" ]; then
    info "Up to date: ${INSTALLED_VERSION}"
    exit 0
  fi
  if [ "$(version_gt "$INSTALLED_VERSION" "$TARGET_VERSION")" = "1" ]; then
    info "Installed ${INSTALLED_VERSION} is newer than ${TARGET_VERSION}"
    exit 0
  fi
  info "Update available: ${INSTALLED_VERSION} -> ${TARGET_VERSION}"
  info "Run with --upgrade to apply it"
  exit 1
fi

if [ "$ACTION" = "upgrade" ] && [ ! -d "$DEST" ]; then
  die "no installation found at ${DEST}; run without --upgrade to install"
fi

# Refuse to destroy work. Without --force, any edited file aborts the upgrade
# before anything is downloaded or replaced.
if [ -n "$DRIFT" ] && [ "$FORCE" -eq 0 ]; then
  printf 'error: local changes detected in the installed schema; nothing was replaced.\n' >&2
  printf 'These files differ from the installed version:%s\n' "$DRIFT" >&2
  printf 'Review them, then re-run with --force to overwrite.\n' >&2
  exit 1
fi

# Idempotent re-runs: same version with no drift is a no-op. --force bypasses
# this to repair a damaged or partially deleted installation.
if [ "$FORCE" -eq 0 ] && [ -n "$INSTALLED_VERSION" ] && [ -n "$TARGET_VERSION" ] &&
  [ "$(normalize_version "$INSTALLED_VERSION")" = "$(normalize_version "$TARGET_VERSION")" ] &&
  [ -z "$DRIFT" ]; then
  info "Already up to date: ${INSTALLED_VERSION} at ${DEST}"
  exit 0
fi

[ -d "$OPENSPEC_DIR" ] || die "no openspec/ directory in ${TARGET_DIR}. Run 'openspec init' first, or pass a project root with --dir"
if [ "$SELECT_SCHEMA" -eq 1 ] && [ ! -f "$CONFIG" ]; then
  die "openspec/config.yaml not found in ${TARGET_DIR}. Run 'openspec init' first, or pass --no-select"
fi

STAGE="${WORKDIR}/${SCHEMA_NAME}"

# Build the complete schema in the staging directory first. Nothing in the
# project is touched until every file has arrived and the schema name checks
# out, so a failed download leaves the current installation intact.
if [ -n "$LOCAL_SOURCE" ]; then
  info "Installing from ${LOCAL_SOURCE}"
  mkdir -p "$STAGE"
  cp -R "${LOCAL_SOURCE}/." "$STAGE/"
  SOURCE_DESCRIPTION=$LOCAL_SOURCE
  TARGET_REF=local
else
  info "Downloading ${SCHEMA_REF} from ${BASE_URL}"
  mkdir -p "$STAGE/templates"
  for file in $FILES; do
    mkdir -p "${STAGE}/$(dirname "$file")"
    fetch_to "${BASE_URL}/${file}" "${STAGE}/${file}" ||
      die "could not download ${BASE_URL}/${file}"
  done
  SOURCE_DESCRIPTION=$BASE_URL
  TARGET_REF=$SCHEMA_REF
fi

for file in $FILES; do
  [ -s "${STAGE}/${file}" ] || die "installed schema is missing ${file}"
done
grep -q "^name: ${SCHEMA_NAME}$" "${STAGE}/schema.yaml" ||
  die "schema.yaml does not declare 'name: ${SCHEMA_NAME}'"

mkdir -p "${OPENSPEC_DIR}/schemas"
if [ -e "$DEST" ]; then
  # When there is no stamp (legacy install) or drift was forced, keep a durable
  # copy under openspec/.schema-backups/. A path outside schemas/ is used so
  # OpenSpec's schema discovery never mistakes the backup for a schema. Clean
  # reinstallations rely on the temporary rollback below instead.
  if [ ! -f "$STAMP" ] || [ -n "$DRIFT" ]; then
    PERSISTENT_BACKUP="${OPENSPEC_DIR}/.schema-backups/${SCHEMA_NAME}-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$(dirname -- "$PERSISTENT_BACKUP")"
    cp -R "$DEST" "$PERSISTENT_BACKUP" ||
      die "could not back up the current installation"
    info "Saved the previous installation to ${PERSISTENT_BACKUP}"
  fi
  # Temporary backup used to roll back if validation fails. It lives in the
  # work directory and is removed by the exit trap on success.
  BACKUP="${WORKDIR}/previous"
  info "Replacing existing installation at ${DEST}"
  mv "$DEST" "$BACKUP" || die "could not move the existing installation aside"
fi

if ! mv "$STAGE" "$DEST"; then
  if [ -d "$BACKUP" ]; then
    mv "$BACKUP" "$DEST"
  fi
  die "could not install the schema at ${DEST}"
fi

# Validate in the project itself, because resolution depends on the project
# layout. On failure the new copy is discarded and the temporary backup is
# restored, keeping the previous version usable.
if command -v openspec >/dev/null 2>&1; then
  if ! (unset CDPATH; cd -- "$TARGET_DIR" && openspec schema validate "$SCHEMA_NAME" >/dev/null 2>&1); then
    rm -rf "$DEST"
    if [ -d "$BACKUP" ]; then
      mv "$BACKUP" "$DEST"
    fi
    die "schema validation failed; previous installation restored"
  fi
  info "Validated schema '${SCHEMA_NAME}'"
else
  info "warning: openspec CLI not found; skipped validation" >&2
fi

if [ -z "$TARGET_VERSION" ]; then
  TARGET_VERSION="unknown"
fi

# Stamp format is intentionally small and hand-written rather than produced by
# a JSON tool, because only POSIX sh is guaranteed when piped from curl.
# .install.json is a dotfile inside the schema directory: OpenSpec's schema
# discovery and validation ignore it, and both installers can read it.
{
  printf '{\n'
  printf '  "schema": "%s",\n' "$SCHEMA_NAME"
  printf '  "version": "%s",\n' "$(json_escape "$TARGET_VERSION")"
  printf '  "ref": "%s",\n' "$(json_escape "$TARGET_REF")"
  printf '  "source": "%s",\n' "$(json_escape "$SOURCE_DESCRIPTION")"
  printf '  "installedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # With no hasher, an empty object disables drift detection instead of
  # failing the whole installation.
  if [ -z "$HASHER" ]; then
    printf '  "files": {}\n'
  else
    printf '  "files": {\n'
    first=1
    for file in $FILES; do
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ',\n'
      fi
      printf '    "%s": "%s"' "$file" "$(hash_file "${DEST}/${file}")"
    done
    printf '\n  }\n'
  fi
  printf '}\n'
} > "$STAMP" || info "warning: could not write ${STAMP}" >&2

# Selection is a single `schema:` key in openspec/config.yaml. Rewriting it with
# sed keeps comments and the rest of the file untouched, and makes repeated
# installs idempotent.
if [ "$SELECT_SCHEMA" -eq 1 ]; then
  CONFIG_TMP="${WORKDIR}/config.yaml"
  if grep -q '^schema:' "$CONFIG"; then
    sed "s/^schema:.*/schema: ${SCHEMA_NAME}/" "$CONFIG" > "$CONFIG_TMP"
  else
    {
      printf 'schema: %s\n' "$SCHEMA_NAME"
      cat "$CONFIG"
    } > "$CONFIG_TMP"
  fi
  cat "$CONFIG_TMP" > "$CONFIG"
  info "Selected schema '${SCHEMA_NAME}' in openspec/config.yaml"
fi

info ""
info "Installed ${SCHEMA_NAME} ${TARGET_VERSION} (${TARGET_REF}) at ${DEST}"
if [ "$SELECT_SCHEMA" -eq 0 ]; then
  info "To use it, set 'schema: ${SCHEMA_NAME}' in openspec/config.yaml"
fi
info "Inspect the workflow with: openspec status"
