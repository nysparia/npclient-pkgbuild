#!/bin/sh
# ============================================================================
#  警告：这是 NetPad 上游的 Ubuntu 安装脚本，本仓库仅作参考存档，不要运行。
#  WARNING: This is NetPad's UPSTREAM Ubuntu installer, archived here for
#  reference only. DO NOT RUN IT.
#
#  它做的是 `dpkg -i`，只适用于 Debian/Ubuntu。在 Arch/Manjaro 上请用本目录的
#  PKGBUILD（`makepkg -fci`），不要执行本文件。
#
#  上游原文（upstream source, 逐字节一致 / byte-identical）:
#    curl -fsSL https://1net.netpad.pro/api/v2/public/linux-install | sudo sh
#  sha256: c11f57f2572831f6c95c0a194fca32bfc6398c8788907492ac3a1a56be0c19e9
#  抓取日期 / fetched: 2026-11-10，对应 npd 0.1.12
#
#  注意：`curl ... | sudo sh` 这种管道执行方式本身就有风险——你执行的是远端
#  随时可变的脚本，且以 root 身份。要装的话请先下载、读一遍、核对 sha256。
# ============================================================================
set -eu

die() { printf 'NPclient install: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || die "root required; use: curl -fsSL https://1net.netpad.pro/api/v2/public/linux-install | sudo sh"
for tool in dpkg dpkg-deb sha256sum mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required command: $tool"
done

architecture="$(dpkg --print-architecture 2>/dev/null)" || die "cannot detect Debian architecture"
case "$architecture" in
    amd64)
        package_url='https://assets.netpad.pro/download/Linux/npd_latest_amd64.deb?v=0.1.12'
        package_url_backup='https://download.netpad.xyz/d/np/root/download/Linux/npd_latest_amd64.deb?v=0.1.12'
        expected_sha256='1ac7863421cb88e6de486629ea2b0527333f7966b9f0fba4146bbf7e80a4746e'
        expected_version='0.1.12'
        ;;
    arm64)
        package_url='https://assets.netpad.pro/download/Linux/npd_latest_arm64.deb?v=0.1.12'
        package_url_backup='https://download.netpad.xyz/d/np/root/download/Linux/npd_latest_arm64.deb?v=0.1.12'
        expected_sha256='2e78c21ec7f3aa3d4b6f6252d32d21141ac734aca04def4ad2e4ccd18fdea2e8'
        expected_version='0.1.12'
        ;;
    *) die "unsupported architecture: $architecture (supported: amd64, arm64)" ;;
esac
[ -n "$package_url" ] || die "no CLI release published for $architecture"

install_tmp="$(mktemp -d "${TMPDIR:-/tmp}/npclient-install.XXXXXX")" || die "cannot create temporary directory"
trap 'rm -rf "$install_tmp"' EXIT HUP INT TERM
package_file="$install_tmp/npd.deb"

download_one() {
    source_url="$1"
    [ -n "$source_url" ] || return 1
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 "$source_url" -o "$package_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only -O "$package_file" "$source_url"
    else
        die "curl or wget is required"
    fi
}

printf 'Downloading NPclient CLI %s for %s...\n' "$expected_version" "$architecture"
if ! download_one "$package_url"; then
    rm -f "$package_file"
    download_one "$package_url_backup" || die "primary and backup downloads failed"
fi
printf '%s  %s\n' "$expected_sha256" "$package_file" | sha256sum -c - >/dev/null \
    || die "SHA-256 verification failed"

actual_package="$(dpkg-deb -f "$package_file" Package 2>/dev/null)" || die "invalid Debian package"
actual_version="$(dpkg-deb -f "$package_file" Version 2>/dev/null)" || die "missing package version"
actual_architecture="$(dpkg-deb -f "$package_file" Architecture 2>/dev/null)" || die "missing package architecture"
[ "$actual_package" = "npd" ] || die "unexpected Debian package: $actual_package"
[ "$actual_version" = "$expected_version" ] || die "version mismatch: expected $expected_version, got $actual_version"
[ "$actual_architecture" = "$architecture" ] || die "architecture mismatch: expected $architecture, got $actual_architecture"

dpkg -i "$package_file" || die "dpkg install failed"
printf 'NPclient CLI %s installed for %s.\n' "$actual_version" "$actual_architecture"
