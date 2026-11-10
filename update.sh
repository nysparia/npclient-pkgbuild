#!/usr/bin/env bash
# update.sh — 从上游 .deb 的 control 同步 PKGBUILD / .SRCINFO
#
# Debian 版本语法：[epoch:]upstream_version[-debian_revision]
#   epoch     -> 只记录，不采用；Arch 侧 epoch 由本地维护，版本回退时自增
#   upstream  -> pkgver（去掉 '~'；: / - 空白在 Arch 中不允许，遇到即报错）
#   revision  -> 不写进 pkgver；上游版本没变、只有修订号变了时 pkgrel+1
#
# 用法:
#   ./update.sh            检查并更新 PKGBUILD 与 .SRCINFO
#   ./update.sh --check    只显示计划，不写文件
#   ./update.sh --build    更新后执行 makepkg -fc
#   ./update.sh --parse V  只拆分一个 Debian 版本号（调试用）

set -euo pipefail

BASE_URL='https://assets.netpad.pro/download/Linux'
DEB_X86_64_URL="$BASE_URL/npd_latest_amd64.deb"
DEB_AARCH64_URL="$BASE_URL/npd_latest_arm64.deb"

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKDIR=''

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'update.sh: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

trap 'if [[ -n $WORKDIR ]]; then rm -rf "$WORKDIR"; fi' EXIT

usage() {
    cat <<'EOF'
用法:
  ./update.sh            检查并更新 PKGBUILD 与 .SRCINFO
  ./update.sh --check    只显示计划，不写文件
  ./update.sh --build    更新后执行 makepkg -fc
  ./update.sh --parse V  只拆分一个 Debian 版本号（调试用）
EOF
}

# 拆 [epoch:]upstream[-revision]，结果放进 V_EPOCH / V_UPSTREAM / V_REVISION。
# 注意不要用 `IFS=$'\t' read`：tab 属于 IFS 空白，开头的空字段会被吃掉。
split_version() {
    local v=$1 rest
    V_EPOCH=''
    V_UPSTREAM=''
    V_REVISION=''
    if [[ $v =~ ^([0-9]+):(.*)$ ]]; then
        V_EPOCH=${BASH_REMATCH[1]}
        rest=${BASH_REMATCH[2]}
    else
        rest=$v
    fi
    if [[ $rest == *-* ]]; then
        V_REVISION=${rest##*-}
        V_UPSTREAM=${rest%-*}
    else
        V_UPSTREAM=$rest
    fi
    [[ -n $V_UPSTREAM ]] || die "无法解析版本号: '$v'"
}

# Debian upstream -> Arch pkgver
sanitize_pkgver() {
    local raw=$1 v
    v=${raw//\~}
    if [[ -z $v ]]; then
        die "上游版本 '$raw' 去掉 '~' 后为空，需要人工决定映射"
    fi
    if [[ $v == *[[:space:]:/-]* ]]; then
        die "上游版本 '$raw' 含 Arch pkgver 不允许的字符（空白、:、/、-），需要人工决定映射"
    fi
    if [[ $v != "$raw" ]]; then
        warn "pkgver 已清洗: '$raw' -> '$v'（'~' 在 pacman 中的排序与 Debian 相反）"
    fi
    printf '%s' "$v"
}

# 从 deb 中取出 control 文本
control_text() {
    local deb=$1 member
    member=$(bsdtar -tf "$deb" | awk '/^control\.tar\./ { print; exit }')
    [[ -n $member ]] || die "在 $deb 中找不到 control.tar.*"
    bsdtar -xOf "$deb" "$member" | bsdtar -xOf - ./control
}

# 取单行字段（Version/Package/Architecture 都是单行）
control_field() {
    local key=$1 text=$2
    awk -v k="$key" '
        tolower($0) ~ ("^" tolower(k) ":") {
            sub(/^[^:]*:[ \t]*/, "")
            print
            exit
        }' <<<"$text"
}

# 从 makepkg --printsrcinfo 的输出里取字段
srcinfo_field() {
    local key=$1 text=$2
    awk -F' = ' -v k="$key" '$1 == "\t" k { print $2; exit }' <<<"$text"
}

# 只改写必要的行，保持 PKGBUILD 其余部分（注释、数组缩进）不动
write_pkgbuild() {
    local pkgver=$1 pkgrel=$2 epoch=$3 debver=$4 sha_x=$5 sha_a=$6
    sed -i -E "s/^pkgver=.*/pkgver=${pkgver}/" PKGBUILD
    sed -i -E "s/^pkgrel=.*/pkgrel=${pkgrel}/" PKGBUILD
    if [[ -n $epoch ]]; then
        if grep -q '^epoch=' PKGBUILD; then
            sed -i -E "s/^epoch=.*/epoch=${epoch}/" PKGBUILD
        else
            sed -i "/^pkgrel=/a epoch=${epoch}" PKGBUILD
        fi
    fi
    if grep -q '^_debver=' PKGBUILD; then
        sed -i -E "s/^_debver=.*/_debver=${debver}/" PKGBUILD
    elif grep -q '^epoch=' PKGBUILD; then
        sed -i "/^epoch=/a _debver=${debver}" PKGBUILD
    else
        sed -i "/^pkgrel=/a _debver=${debver}" PKGBUILD
    fi
    sed -i -E "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('${sha_x}')/" PKGBUILD
    sed -i -E "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('${sha_a}')/" PKGBUILD
}

main() {
    local mode=update do_build=0
    while (($#)); do
        case $1 in
            --check) mode=check ;;
            --build) do_build=1 ;;
            --parse)
                (($# >= 2)) || die "--parse 需要一个版本号参数"
                split_version "$2"
                printf 'epoch=%s\nupstream=%s\nrevision=%s\n' \
                    "$V_EPOCH" "$V_UPSTREAM" "$V_REVISION"
                return 0
                ;;
            -h|--help) usage; return 0 ;;
            *) die "未知参数: $1" ;;
        esac
        shift
    done

    cd "$HERE"

    local cmd
    for cmd in curl bsdtar makepkg sha256sum awk sed vercmp; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
    done
    [[ -f PKGBUILD ]] || die "当前目录没有 PKGBUILD"

    local srcinfo
    srcinfo=$(makepkg --printsrcinfo) || die "makepkg --printsrcinfo 失败，请先修好 PKGBUILD"

    local cur_pkgver cur_rel cur_epoch cur_debver cur_sha_x cur_sha_a
    cur_pkgver=$(srcinfo_field pkgver "$srcinfo")
    cur_rel=$(srcinfo_field pkgrel "$srcinfo")
    cur_epoch=$(srcinfo_field epoch "$srcinfo")
    cur_sha_x=$(srcinfo_field sha256sums_x86_64 "$srcinfo")
    cur_sha_a=$(srcinfo_field sha256sums_aarch64 "$srcinfo")
    cur_debver=$(sed -n 's/^_debver=//p' PKGBUILD | head -n1 | tr -d "\"'")

    if [[ -z $cur_debver ]]; then
        die "PKGBUILD 缺少 _debver=<当前 deb 的 Version>；请先补一行，例如 _debver=0.1.12"
    fi
    if [[ ! $cur_rel =~ ^[0-9]+$ ]]; then
        die "现有 pkgrel '$cur_rel' 不是整数，本脚本不处理"
    fi
    [[ -n $cur_pkgver ]] || die "PKGBUILD 里没有 pkgver"

    WORKDIR=$(mktemp -d)
    say "下载 x86_64 deb ..."
    curl -fSL --retry 3 --retry-delay 2 "$DEB_X86_64_URL" -o "$WORKDIR/x86_64.deb" \
        || die "下载失败: $DEB_X86_64_URL"
    say "下载 aarch64 deb ..."
    curl -fSL --retry 3 --retry-delay 2 "$DEB_AARCH64_URL" -o "$WORKDIR/aarch64.deb" \
        || die "下载失败: $DEB_AARCH64_URL"

    local ctl_x ctl_a ver_x ver_a
    ctl_x=$(control_text "$WORKDIR/x86_64.deb")
    ctl_a=$(control_text "$WORKDIR/aarch64.deb")
    [[ $(control_field Package "$ctl_x") == npd ]] || die "x86_64 deb 的 Package 不是 npd"
    [[ $(control_field Package "$ctl_a") == npd ]] || die "aarch64 deb 的 Package 不是 npd"
    [[ $(control_field Architecture "$ctl_x") == amd64 ]] || die "x86_64 deb 的 Architecture 不是 amd64"
    [[ $(control_field Architecture "$ctl_a") == arm64 ]] || die "aarch64 deb 的 Architecture 不是 arm64"
    ver_x=$(control_field Version "$ctl_x")
    ver_a=$(control_field Version "$ctl_a")
    [[ -n $ver_x ]] || die "control 里没有 Version 字段"
    [[ $ver_x == "$ver_a" ]] || die "两个架构的 Version 不一致: $ver_x vs $ver_a"
    say "上游 deb Version: $ver_x"

    local deb_epoch upstream revision pkgver debver
    split_version "$ver_x"
    deb_epoch=$V_EPOCH
    upstream=$V_UPSTREAM
    revision=$V_REVISION
    [[ $deb_epoch == 0 ]] && deb_epoch=''
    pkgver=$(sanitize_pkgver "$upstream")
    debver=$ver_x

    if [[ -n $cur_epoch && ! $cur_epoch =~ ^[0-9]+$ ]]; then
        die "PKGBUILD 的 epoch '$cur_epoch' 不是非负整数"
    fi
    [[ $cur_epoch == 0 ]] && cur_epoch=''

    # epoch 由我们在本地维护，是“版本排序修复计数器”，不照抄上游 deb 的值。
    # 上游 epoch 只作为记录（含在 _debver 里），变化时提示一下。
    local epoch=$cur_epoch
    local prev_vendor_epoch=''
    split_version "$cur_debver"
    prev_vendor_epoch=$V_EPOCH
    [[ $prev_vendor_epoch == 0 ]] && prev_vendor_epoch=''
    if [[ $deb_epoch != "$prev_vendor_epoch" ]]; then
        if [[ -n $deb_epoch ]]; then
            say "上游 deb 的 epoch: ${prev_vendor_epoch:-无} -> $deb_epoch（仅记录，不采用）"
        else
            say "上游 deb 去掉了 epoch（仅记录，本地 epoch 为 ${cur_epoch:-无}）"
        fi
    fi

    local sha_x sha_a
    sha_x=$(sha256sum "$WORKDIR/x86_64.deb" | cut -d' ' -f1)
    sha_a=$(sha256sum "$WORKDIR/aarch64.deb" | cut -d' ' -f1)

    if [[ $debver == "$cur_debver" && $sha_x == "$cur_sha_x" && $sha_a == "$cur_sha_a" ]]; then
        say "已是最新: deb $debver，包 $cur_pkgver-$cur_rel"
        return 0
    fi

    local new_rel reason
    if [[ $debver == "$cur_debver" ]]; then
        new_rel=$((cur_rel + 1))
        reason='同版本内容变化（上游重打包），pkgrel+1'
    elif [[ $pkgver != "$cur_pkgver" ]]; then
        new_rel=1
        reason='上游版本变化，pkgrel 归 1'
    else
        new_rel=$((cur_rel + 1))
        reason='仅 Debian 修订号变化，pkgrel+1'
    fi

    local cur_str new_str cmp
    cur_str="${cur_epoch:+$cur_epoch:}${cur_pkgver}-${cur_rel}"
    new_str="${epoch:+$epoch:}${pkgver}-${new_rel}"
    cmp=$(vercmp "$new_str" "$cur_str" || true)
    if ((cmp <= 0)); then
        # 上游版本回退（或打包起点低于已发布版本）：本地 epoch 自增。
        # 这是让 pacman 接受“更旧的上游版本”的唯一手段。
        local old_epoch=${epoch:-0}
        epoch=$((old_epoch + 1))
        new_rel=1
        new_str="${epoch}:${pkgver}-${new_rel}"
        reason="版本未前进（$cur_str），本地 epoch 自增 ${old_epoch} -> ${epoch}，pkgrel 归 1"
        warn "本地 epoch 自增 ${old_epoch} -> ${epoch}，不可逆；建议先跑 ./update.sh --check 确认"
        cmp=$(vercmp "$new_str" "$cur_str" || true)
        if ((cmp <= 0)); then
            die "epoch 自增后仍无法超过 $cur_str，拒绝继续"
        fi
    fi

    say "计划: $cur_str -> $new_str"
    say "原因: $reason"
    say "sha256 x86_64: $sha_x"
    say "sha256 aarch64: $sha_a"

    if [[ $mode == check ]]; then
        return 0
    fi

    local backup="$WORKDIR/PKGBUILD.bak"
    cp PKGBUILD "$backup"
    write_pkgbuild "$pkgver" "$new_rel" "$epoch" "$debver" "$sha_x" "$sha_a"
    if ! makepkg --printsrcinfo > .SRCINFO; then
        cp "$backup" PKGBUILD
        die "新 PKGBUILD 校验失败，已回滚 PKGBUILD"
    fi
    say "已更新 PKGBUILD 与 .SRCINFO"

    if ((do_build)); then
        say "开始构建 ..."
        makepkg -fc
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
