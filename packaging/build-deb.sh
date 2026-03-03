#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/dist}"
VERSION="${MPWRD_MENU_DEB_VERSION:-$(dpkg-parsechangelog -S Version)}"
CHANGELOG_PATH="${ROOT_DIR}/debian/changelog"
CHANGELOG_BACKUP="$(mktemp)"

cleanup() {
  cp "${CHANGELOG_BACKUP}" "${CHANGELOG_PATH}"
  rm -f "${CHANGELOG_BACKUP}"
}

cp "${CHANGELOG_PATH}" "${CHANGELOG_BACKUP}"
trap cleanup EXIT

python3 "${ROOT_DIR}/packaging/set-debian-version.py" "${VERSION}" "${CHANGELOG_PATH}"

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}"/*
rm -f "${ROOT_DIR}"/../mpwrd-menu_"${VERSION}"_*

(
  cd "${ROOT_DIR}"
  dpkg-buildpackage -us -uc -b
)

find "${ROOT_DIR}/.." -maxdepth 1 -type f -name "mpwrd-menu_${VERSION}_*" -exec cp -f {} "${OUTPUT_DIR}/" \;
