#!/bin/sh
# Install or update the prototype-first OpenSpec schema in the current project.
#
# Remote:
#   curl -fsSL https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.sh | sh
#
# Local (from a clone of this repository):
#   ./scripts/install.sh
#
# The schema is installed into ./openspec/schemas/prototype-first and selected
# in ./openspec/config.yaml. Run from an OpenSpec project root, or pass --dir.

set -eu

SCHEMA_NAME="prototype-first"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/schemas/${SCHEMA_NAME}"
SCHEMA_BASE_URL="${SCHEMA_BASE_URL:-$DEFAULT_BASE_URL}"
TARGET_DIR="${SCHEMA_TARGET_DIR:-$PWD}"
SELECT_SCHEMA=1

FILES="README.md schema.yaml templates/design.md templates/proposal.md templates/prototype.html templates/spec.md templates/tasks.md"

WORKDIR=""
BACKUP=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

usage() {
  cat <<EOF
Install or update the ${SCHEMA_NAME} OpenSpec schema.

Usage:
  scripts/install.sh [options]

Options:
  --dir <path>    Project root to install into (default: current directory)
  --select        Select the schema in openspec/config.yaml (default)
  --no-select     Leave openspec/config.yaml unchanged
  -h, --help      Show this help

Environment:
  SCHEMA_BASE_URL    Base URL to download the schema from
  SCHEMA_TARGET_DIR  Project root (same as --dir)

The script uses the local schemas/${SCHEMA_NAME} directory when run from a
checkout of this repository. Otherwise it downloads the schema from
SCHEMA_BASE_URL.
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

[ -n "$TARGET_DIR" ] || die "target directory is empty"
[ -d "$TARGET_DIR" ] || die "target directory does not exist: $TARGET_DIR"
TARGET_DIR=$(unset CDPATH; cd -- "$TARGET_DIR" && pwd)

OPENSPEC_DIR="${TARGET_DIR}/openspec"
CONFIG="${OPENSPEC_DIR}/config.yaml"
DEST="${OPENSPEC_DIR}/schemas/${SCHEMA_NAME}"

[ -d "$OPENSPEC_DIR" ] || die "no openspec/ directory in ${TARGET_DIR}. Run 'openspec init' first, or pass --dir <project-root>"
if [ "$SELECT_SCHEMA" -eq 1 ] && [ ! -f "$CONFIG" ]; then
  die "openspec/config.yaml not found in ${TARGET_DIR}. Run 'openspec init' first, or pass --no-select"
fi

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

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/${SCHEMA_NAME}.XXXXXX") || die "could not create a temporary directory"
STAGE="${WORKDIR}/${SCHEMA_NAME}"

if [ -n "$LOCAL_SOURCE" ]; then
  info "Installing from ${LOCAL_SOURCE}"
  mkdir -p "$STAGE"
  cp -R "${LOCAL_SOURCE}/." "$STAGE/"
else
  info "Downloading from ${SCHEMA_BASE_URL}"
  mkdir -p "$STAGE/templates"
  for file in $FILES; do
    mkdir -p "${STAGE}/$(dirname "$file")"
    fetch_to "${SCHEMA_BASE_URL}/${file}" "${STAGE}/${file}" ||
      die "could not download ${SCHEMA_BASE_URL}/${file}"
  done
fi

for file in $FILES; do
  [ -s "${STAGE}/${file}" ] || die "downloaded schema is missing ${file}"
done
grep -q "^name: ${SCHEMA_NAME}$" "${STAGE}/schema.yaml" ||
  die "schema.yaml does not declare 'name: ${SCHEMA_NAME}'"

mkdir -p "${OPENSPEC_DIR}/schemas"
if [ -e "$DEST" ]; then
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
info "Installed ${SCHEMA_NAME} at ${DEST}"
if [ "$SELECT_SCHEMA" -eq 0 ]; then
  info "To use it, set 'schema: ${SCHEMA_NAME}' in openspec/config.yaml"
fi
info "Inspect the workflow with: openspec status"
