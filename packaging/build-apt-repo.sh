#!/bin/bash
set -euo pipefail

if (( $# < 4 )); then
  printf 'usage: %s <suite> <repo-dir> <public-key> <deb> [deb ...]\n' "${0##*/}" >&2
  exit 1
fi

SUITE="$1"
REPO_DIR="$2"
PUBLIC_KEY_PATH="$3"
shift 3
DEB_FILES=("$@")

COMPONENT="${APT_REPO_COMPONENT:-main}"
ORIGIN="${APT_REPO_ORIGIN:-mPWRD-OS}"
LABEL="${APT_REPO_LABEL:-mPWRD-OS}"
ARCHITECTURES="${APT_REPO_ARCHITECTURES:-all}"
KEY_ID="${GPG_SIGNING_KEY_ID:-$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
REL_POOL_DIR="pool/${SUITE}/${COMPONENT}/m/mpwrd-menu"
REL_BINARY_DIR="dists/${SUITE}/${COMPONENT}/binary-all"
REL_RELEASE_DIR="dists/${SUITE}"
POOL_DIR="${REPO_DIR}/${REL_POOL_DIR}"
BINARY_DIR="${REPO_DIR}/${REL_BINARY_DIR}"
RELEASE_DIR="${REPO_DIR}/${REL_RELEASE_DIR}"

mkdir -p "${POOL_DIR}" "${BINARY_DIR}"
touch "${REPO_DIR}/.nojekyll"
cp -f "${PUBLIC_KEY_PATH}" "${REPO_DIR}/mpwrd-archive-keyring.gpg"

rm -f "${POOL_DIR}"/*.deb
cp -f "${DEB_FILES[@]}" "${POOL_DIR}/"

(
  cd "${REPO_DIR}"

  dpkg-scanpackages --arch all "${REL_POOL_DIR}" /dev/null > "${REL_BINARY_DIR}/Packages"
  gzip -9nkf "${REL_BINARY_DIR}/Packages"
  xz -9efk "${REL_BINARY_DIR}/Packages"

  apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=${ORIGIN}" \
    -o "APT::FTPArchive::Release::Label=${LABEL}" \
    -o "APT::FTPArchive::Release::Suite=${SUITE}" \
    -o "APT::FTPArchive::Release::Codename=${SUITE}" \
    -o "APT::FTPArchive::Release::Architectures=${ARCHITECTURES}" \
    -o "APT::FTPArchive::Release::Components=${COMPONENT}" \
    release "${REL_RELEASE_DIR}" > "${REL_RELEASE_DIR}/Release"
)

GPG_ARGS=(--batch --yes --pinentry-mode loopback --default-key "${KEY_ID}")
if [[ -n "${GPG_PASSPHRASE}" ]]; then
  GPG_ARGS+=(--passphrase "${GPG_PASSPHRASE}")
fi

gpg "${GPG_ARGS[@]}" --detach-sign --output "${RELEASE_DIR}/Release.gpg" "${RELEASE_DIR}/Release"
gpg "${GPG_ARGS[@]}" --clearsign --output "${RELEASE_DIR}/InRelease" "${RELEASE_DIR}/Release"
