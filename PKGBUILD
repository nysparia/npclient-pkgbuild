# Maintainer: Your Name <you at example dot com>

pkgname=npclient
_pkgname=npd
pkgver=0.1.12
pkgrel=3
# 上一次构建所用 deb 的完整 Version 字段（含 epoch / Debian 修订号）。
# update.sh 靠它判断“上游发版”还是“仅 Debian 重新打包”。
_debver='0.1.12'
_debfile="${_debver//:/_}-${pkgrel}"
pkgdesc="TUN proxy daemon and command line client (prebuilt binaries)"
arch=('x86_64' 'aarch64')
url="https://netpad.pro"
license=('LicenseRef-NPclient-Proprietary')
depends=('glibc' 'gcc-libs' 'systemd' 'iproute2' 'iana-etc' 'polkit')
optdepends=(
    'systemd-resolvconf: DNS takeover via resolvectl'
    'networkmanager: keep NetworkManager from managing np-tun0'
)
provides=("npd=${pkgver}")
conflicts=('npd' 'npclient-bin')
replaces=('npclient-bin')
options=('!strip' '!debug')  # upstream binaries ship pre-stripped; don't re-strip or build -debug
install="${pkgname}.install"
backup=('etc/npclient/npd.toml')

# NOTE: upstream publishes no immutable versioned URL for current releases.
# `npd_latest_*` is a moving target; ?v= is only a CDN cache buster (verified:
# with and without it the payload is byte-identical). Only 0.1.2 has a pinned
# URL (npd_0.1.2_amd64.deb). Consequence: every upstream release makes the
# checksum below stale and this PKGBUILD must be bumped in lockstep.
# 本地文件名与 ?v= 同时带 deb 版本和 pkgrel：只要包内容或打包修订变化，
# 缓存键就会变，makepkg 不会复用同名旧 deb（revision 变化、同版本重打包都覆盖）。
_base="https://assets.netpad.pro/download/Linux"
source_x86_64=("${pkgname}-${_debfile}-x86_64.deb::${_base}/npd_latest_amd64.deb?v=${_debfile}")
source_aarch64=("${pkgname}-${_debfile}-aarch64.deb::${_base}/npd_latest_arm64.deb?v=${_debfile}")
sha256sums_x86_64=('1ac7863421cb88e6de486629ea2b0527333f7966b9f0fba4146bbf7e80a4746e')
sha256sums_aarch64=('2e78c21ec7f3aa3d4b6f6252d32d21141ac734aca04def4ad2e4ccd18fdea2e8')

package() {
  # The .deb is an ar archive; makepkg already extracted it into $srcdir,
  # leaving data.tar.* (zstd) side by side.
  bsdtar -xf data.tar.* -C "${pkgdir}/" --no-same-owner

  # Debian layout -> Arch layout
  if [[ -d "${pkgdir}/lib/systemd/system" ]]; then
    install -d "${pkgdir}/usr/lib/systemd/system"
    mv "${pkgdir}/lib/systemd/system/"* "${pkgdir}/usr/lib/systemd/system/"
    # 只删掉 /lib/systemd；若 /lib 下还有别的内容，保留并让文件列表暴露出来，
    # 而不是一把 rm -rf /lib 把上游文件悄悄删掉。
    rm -rf "${pkgdir}/lib/systemd"
    rmdir "${pkgdir}/lib" 2>/dev/null || true
  fi

  # Upstream postinst does `useradd -r -M -d /var/lib/npd -s /usr/sbin/nologin -G npclient npd`.
  # On Arch that belongs in sysusers.d, applied by 20-systemd-sysusers.hook.
  install -Dm644 /dev/stdin "${pkgdir}/usr/lib/sysusers.d/npd.conf" <<'EOF'
g npclient -
u npd - "NPclient daemon" /var/lib/npd /usr/bin/nologin
m npd npclient
EOF

  # Deliberately drop the upstream polkit action allowing user npd to manage
  # *arbitrary* systemd unit files: the rule matches the generic action id
  # org.freedesktop.systemd1.manage-unit-files with no unit filter, so a
  # compromised npd (it listens on 127.0.0.1:9090) could enable a malicious
  # unit and escalate to root. Only the resolve1 rule is kept; npctl's
  # `boot on|off` then needs root, which is the Arch-conventional behaviour.
  install -Dm644 /dev/stdin "${pkgdir}/usr/share/polkit-1/rules.d/50-npclient.rules" <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.resolve1.") === 0 &&
        subject.user == "npd") { return polkit.Result.YES; }
});
EOF

  # Debian conffile location is already /etc/npclient/npd.toml - nothing to move.

  # SBOM / third-party licence texts: docs, not read at runtime
  # (verified: neither npd nor npctl references /usr/share/doc).
  install -d "${pkgdir}/usr/share/licenses/${pkgname}"
  if [[ -d "${pkgdir}/usr/share/doc/npd" ]]; then
    mv "${pkgdir}/usr/share/doc/npd/"*.json "${pkgdir}/usr/share/licenses/${pkgname}/"
    rm -rf "${pkgdir}/usr/share/doc"
  fi
  mv "${pkgdir}/usr/share/npclient/GEOIP-NOTICE.txt" \
    "${pkgdir}/usr/share/licenses/${pkgname}/GEOIP-NOTICE.txt"

  # Nothing else upstream-specific, but stay defensive about Debian remnants.
  rm -rf "${pkgdir}/usr/share/lintian"

  # Sanity: upstream ships pre-stripped PIE binaries; make sure we did not
  # lose the symlinked entry points.
  [[ -L "${pkgdir}/usr/bin/npon" ]]  || ln -s npctl "${pkgdir}/usr/bin/npon"
  [[ -L "${pkgdir}/usr/bin/npoff" ]] || ln -s npctl "${pkgdir}/usr/bin/npoff"
}

# vim:set ft=sh:
