#!/bin/sh
#
# depz installer
#
#   curl -fsSL https://raw.githubusercontent.com/depz-org/depz-cli/main/install.sh | sh
#
# Environment:
#   DEPZ_VERSION      release tag to install  (default: latest)
#   DEPZ_INSTALL_DIR  install directory       (default: $HOME/.local/bin)

set -eu

REPO="depz-org/depz-cli"
BIN="depz"

err() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

download() {
	# download <url> <dest>
	if have curl; then
		curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$2"
	elif have wget; then
		wget -qO "$2" "$1"
	else
		err "curl or wget is required"
	fi
}

sha256() {
	if have sha256sum; then
		sha256sum "$1" | cut -d' ' -f1
	elif have shasum; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		err "sha256sum or shasum is required"
	fi
}

main() {
	install_dir="${DEPZ_INSTALL_DIR:-$HOME/.local/bin}"

	os=$(uname -s)
	arch=$(uname -m)

	case "$os" in
	Linux) os=linux ;;
	Darwin) os=macos ;;
	*) err "unsupported operating system: $os" ;;
	esac

	case "$arch" in
	x86_64 | amd64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) err "unsupported architecture: $arch" ;;
	esac

	# NOTE: must match the asset names produced by .github/workflows/release.yml
	asset="${BIN}-${arch}-${os}"

	if [ -n "${DEPZ_VERSION:-}" ]; then
		base="https://github.com/${REPO}/releases/download/${DEPZ_VERSION}"
	else
		base="https://github.com/${REPO}/releases/latest/download"
	fi

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM

	printf 'downloading %s\n' "$asset"
	download "${base}/${asset}" "${tmp}/${asset}" ||
		err "no release asset named ${asset}"

	download "${base}/${asset}.sha256" "${tmp}/${asset}.sha256" ||
		err "could not fetch ${asset}.sha256"

	want=$(cut -d' ' -f1 <"${tmp}/${asset}.sha256")
	[ -n "$want" ] || err "empty checksum in ${asset}.sha256"

	got=$(sha256 "${tmp}/${asset}")
	[ "$want" = "$got" ] || err "checksum mismatch for ${asset}
  expected ${want}
  actual   ${got}"

	mkdir -p "$install_dir"
	install_dir=$(cd "$install_dir" && pwd)

	chmod +x "${tmp}/${asset}"
	mv "${tmp}/${asset}" "${install_dir}/${BIN}"

	printf 'installed %s\n' "${install_dir}/${BIN}"
	"${install_dir}/${BIN}" version || true

	case ":${PATH}:" in
	*":${install_dir}:"*) ;;
	*)
		printf '\n%s is not on your PATH.\n' "$install_dir"
		printf 'Run it as %s/%s, or add the directory to your PATH:\n\n' "$install_dir" "$BIN"
		printf '  export PATH="%s:$PATH"\n\n' "$install_dir"
		;;
	esac
}

main "$@"