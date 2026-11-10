#!/usr/bin/env bash
# update.sh — 从上游 .deb 的 control 同步 PKGBUILD / .SRCINFO
#
# Debian 版本语法：[epoch:]upstream_version[-debian_revision]
#   epoch     -> 只记录，不采用；Arch 侧 epoch 由本地维护，版本回退时自增
#   upstream  -> pkgver（去掉 '~'；: / - 空白在 Arch 中不允许，遇到即报错）
#   revision  -> 不写进 pkgver；上游版本没变、只有修订号变了时 pkgrel+1
#
# 用法:
#   ./update.sh                 检查并更新 PKGBUILD 与 .SRCINFO
#   ./update.sh --check         只显示计划，不写文件
#   ./update.sh --build         更新后执行 makepkg -fc
#   ./update.sh --accept-epoch  确认并允许本地 epoch 自增（不可逆）
#   ./update.sh --parse V       只拆分一个 Debian 版本号（调试用）
#
# 版本基准取 HEAD 可达、版本最高的 v* git tag（即已发布的 PKGBUILD），没有 tag 时才用工作区。
# 候选版本还必须超过工作区当前版本：工作区领先 tag 时，同 pkgver 下提升 pkgrel；
# 工作区 pkgver 更高则拒绝写入，避免复用或降低可能已构建/安装过的版本号。

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
  ./update.sh                 检查并更新 PKGBUILD 与 .SRCINFO
  ./update.sh --check         只显示计划，不写文件
  ./update.sh --build         更新后执行 makepkg -fc
  ./update.sh --accept-epoch  确认并允许本地 epoch 自增（不可逆）
  ./update.sh --parse V       只拆分一个 Debian 版本号（调试用）
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
    # revision 会写进 _debver='...'，必须挡住引号/空白等注入字符。
    if [[ -n $V_REVISION && ! $V_REVISION =~ ^[0-9A-Za-z.+~]+$ ]]; then
        die "debian_revision '$V_REVISION' 含非法字符（只允许字母、数字、. + ~）"
    fi
}

# Debian upstream -> Arch pkgver
sanitize_pkgver() {
    local raw=$1 v
    v=${raw//\~}
    if [[ -z $v ]]; then
        die "上游版本 '$raw' 去掉 '~' 后为空，需要人工决定映射"
    fi
    # 白名单只放行 Debian upstream 合法且能安全写入 PKGBUILD 的字符。
    if [[ ! $v =~ ^[0-9A-Za-z._+~]+$ ]]; then
        die "上游版本 '$raw' 含无法安全映射的字符（只允许字母、数字、. _ + ~）"
    fi
    if [[ $v != "$raw" ]]; then
        warn "pkgver 已清洗: '$raw' -> '$v'（'~' 在 pacman 中的排序与 Debian 相反）"
    fi
    printf '%s' "$v"
}

# pkgrel 允许 Arch 的整数或小数形式（例如 2、2.1）
is_valid_pkgrel() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# pkgrel 比较：A > B 返回真
pkgrel_gt() {
    [[ $(vercmp "0-$1" "0-$2") == 1 ]]
}

# 递增 pkgrel：2 -> 3，2.1 -> 2.2，2.9 -> 2.10
pkgrel_bump() {
    local r=$1 major minor
    if [[ $r == *.* ]]; then
        major=${r%%.*}
        minor=${r#*.}
        printf '%s.%s' "$major" "$((10#$minor + 1))"
    else
        printf '%s' "$((10#$r + 1))"
    fi
}

# 从 deb 中取出 control 文本
control_text() {
    local deb=$1 member
    member=$(bsdtar -tf "$deb" | awk '/^control\.tar($|\.)/ { print; exit }')
    [[ -n $member ]] || die "在 $deb 中找不到 control.tar[.*]"
    bsdtar -xOf "$deb" "$member" | bsdtar -xOf - ./control \
        || die "$deb: 读取 control 失败"
}

# 取单行字段（Version/Package/Architecture 都是单行）
control_field() {
    local key=$1 text=$2
    awk -v k="$key" '
        tolower($0) ~ ("^" tolower(k) ":") {
            sub(/^[^:]*:[ \t]*/, "")
            sub(/\r$/, "")
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
        sed -i -E "s|^_debver=.*|_debver='${debver}'|" PKGBUILD
    elif grep -q '^epoch=' PKGBUILD; then
        sed -i "/^epoch=/a _debver='${debver}'" PKGBUILD
    else
        sed -i "/^pkgrel=/a _debver='${debver}'" PKGBUILD
    fi
    sed -i -E "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('${sha_x}')/" PKGBUILD
    sed -i -E "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('${sha_a}')/" PKGBUILD

    # sed 匹配不到时仍然退出 0（GNU sed 手册 2.3：只有非法脚本、打不开输入、
    # I/O 错误才返回非零），所以「改没改中」必须自己回读确认。
    # 不回读的后果是静默的：pkgver 更新了而 sha256sums 还是旧的。
    # 后面的 makepkg --printsrcinfo 只检查 PKGBUILD 能否解析，不做
    # --verifysource 那样的完整性检查，所以这道闸门兜不住旧哈希；
    # 脚本会照常打印“已更新”，把旧的 sha256 写进 .SRCINFO。
    #
    # 失败时 return 1 而不是 die：die 会直接退出，main() 就没机会恢复备份。
    local item key want got
    for item in "pkgver=$pkgver" "pkgrel=$pkgrel" \
                "sha256sums_x86_64=('$sha_x')" "sha256sums_aarch64=('$sha_a')"; do
        key=${item%%=*}
        want=${item#*=}
        got=$(sed -n "s/^${key}=//p" PKGBUILD | head -n1)
        if [[ $got != "$want" ]]; then
            warn "PKGBUILD 回读校验失败：${key} 期望 ${want}，实际 ${got:-<缺失>}"
            return 1
        fi
    done
    if [[ -n $epoch ]]; then
        got=$(sed -n 's/^epoch=//p' PKGBUILD | head -n1)
        if [[ $got != "$epoch" ]]; then
            warn "PKGBUILD 回读校验失败：epoch 期望 ${epoch}，实际 ${got:-<缺失>}"
            return 1
        fi
    fi
    got=$(sed -n 's/^_debver=//p' PKGBUILD | head -n1 | tr -d "\"'")
    if [[ $got != "$debver" ]]; then
        warn "PKGBUILD 回读校验失败：_debver 期望 ${debver}，实际 ${got:-<缺失>}"
        return 1
    fi
}

main() {
    local mode=update do_build=0 accept_epoch=0
    while (($#)); do
        case $1 in
            --check) mode=check ;;
            --build) do_build=1 ;;
            --accept-epoch) accept_epoch=1 ;;
            --parse)
                (($# >= 2)) || die "--parse 需要一个版本号参数"
                split_version "$2"
                local pv
                pv=$(sanitize_pkgver "$V_UPSTREAM")
                printf 'epoch=%s\nupstream=%s\nrevision=%s\npkgver=%s\n' \
                    "$V_EPOCH" "$V_UPSTREAM" "$V_REVISION" "$pv"
                return 0
                ;;
            -h|--help) usage; return 0 ;;
            *) die "未知参数: $1" ;;
        esac
        shift
    done

    cd "$HERE"

    local cmd
    for cmd in curl bsdtar makepkg sha256sum awk sed vercmp tar; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
    done
    [[ -f PKGBUILD ]] || die "当前目录没有 PKGBUILD"

    local work_srcinfo work_pkgver work_rel work_epoch work_debver work_sha_x work_sha_a
    work_srcinfo=$(makepkg --printsrcinfo) || die "makepkg --printsrcinfo 失败，请先修好 PKGBUILD"
    work_pkgver=$(srcinfo_field pkgver "$work_srcinfo")
    work_rel=$(srcinfo_field pkgrel "$work_srcinfo")
    work_epoch=$(srcinfo_field epoch "$work_srcinfo")
    work_debver=$(sed -n 's/^_debver=//p' PKGBUILD | head -n1 | tr -d "\"'")
    work_sha_x=$(srcinfo_field sha256sums_x86_64 "$work_srcinfo")
    work_sha_a=$(srcinfo_field sha256sums_aarch64 "$work_srcinfo")
    [[ -n $work_pkgver ]] || die "PKGBUILD 里没有 pkgver"
    is_valid_pkgrel "$work_rel" || die "工作区 pkgrel '$work_rel' 不是整数或小数"
    if [[ -n $work_epoch && ! $work_epoch =~ ^[0-9]+$ ]]; then
        die "工作区 epoch '$work_epoch' 不是非负整数"
    fi
    [[ $work_epoch == 0 ]] && work_epoch=''

    WORKDIR=$(mktemp -d)

    # ---- 版本基准：HEAD 可达、版本最高的 v* tag；没有 tag 才退回工作区 ----
    local git_repo=0 baseline_tag='' prefix='' repo_root='' base_srcinfo='' base_pkgbuild=''
    if command -v git >/dev/null 2>&1 && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
        git_repo=1
        repo_root=$(git -C "$HERE" rev-parse --show-toplevel)
        # 不用 describe：它选“距离最近”的 tag；多分支合并/乱序 tag 时会选到
        # 版本更低的那个。取所有可达 tag 里版本最高的一个更稳。
        baseline_tag=$(git -C "$HERE" tag --merged HEAD --list 'v[0-9]*' \
            --sort=-v:refname 2>/dev/null | sed -n '1p' || true)
    fi

    local base_dir="$WORKDIR/base"
    if [[ -n $baseline_tag ]]; then
        mkdir -p "$base_dir"
        if ! git -C "$repo_root" archive "$baseline_tag" | tar -xf - -C "$base_dir"; then
            die "无法从 tag $baseline_tag 导出基准树"
        fi
        prefix=$(git -C "$HERE" rev-parse --show-prefix)
        base_pkgbuild="$base_dir/${prefix}PKGBUILD"
        if [[ -f $base_pkgbuild ]]; then
            base_srcinfo=$( cd "$base_dir/${prefix}" && makepkg --printsrcinfo 2>/dev/null ) \
                || die "tag $baseline_tag 的 PKGBUILD 无法解析"
        else
            warn "tag $baseline_tag 里没有 PKGBUILD，改用工作区基准"
            baseline_tag=''
        fi
    fi

    if [[ -z $baseline_tag ]]; then
        warn "没有可用的 v* tag；以工作区 PKGBUILD 为基准（发版后请 git tag v<pkgver>-<pkgrel>）"
        base_srcinfo=$work_srcinfo
        base_pkgbuild="$HERE/PKGBUILD"
    fi

    local cur_pkgver cur_rel cur_epoch cur_debver cur_sha_x cur_sha_a
    cur_pkgver=$(srcinfo_field pkgver "$base_srcinfo")
    cur_rel=$(srcinfo_field pkgrel "$base_srcinfo")
    cur_epoch=$(srcinfo_field epoch "$base_srcinfo")
    cur_sha_x=$(srcinfo_field sha256sums_x86_64 "$base_srcinfo")
    cur_sha_a=$(srcinfo_field sha256sums_aarch64 "$base_srcinfo")
    cur_debver=$(sed -n 's/^_debver=//p' "$base_pkgbuild" | head -n1 | tr -d "\"'")

    [[ -n $cur_pkgver ]] || die "基准 PKGBUILD 里没有 pkgver"
    [[ -n $cur_debver ]] || die "基准 PKGBUILD 缺少 _debver=<当前 deb 的 Version>"
    is_valid_pkgrel "$cur_rel" || die "基准 pkgrel '$cur_rel' 不是整数或小数"
    if [[ -n $cur_epoch && ! $cur_epoch =~ ^[0-9]+$ ]]; then
        die "基准 epoch '$cur_epoch' 不是非负整数"
    fi
    [[ $cur_epoch == 0 ]] && cur_epoch=''

    local base_str="${cur_epoch:+$cur_epoch:}${cur_pkgver}-${cur_rel}"
    local work_str="${work_epoch:+$work_epoch:}${work_pkgver}-${work_rel}"
    say "发布基准: ${baseline_tag:-工作区 PKGBUILD} = $base_str"
    if [[ -n $baseline_tag && $work_str != "$base_str" ]]; then
        local wcmp
        wcmp=$(vercmp "$work_str" "$base_str" || true)
        if (( ${wcmp:-0} > 0 )); then
            warn "工作区版本 $work_str 领先基准 $base_str；候选版本必须超过它"
        else
            warn "工作区版本 $work_str 低于基准 $base_str；以 tag 为准"
        fi
    fi

    local cachebust
    cachebust=$(date +%s)
    say "下载 x86_64 deb ..."
    curl -fSL --retry 3 --retry-delay 2 "${DEB_X86_64_URL}?v=${cachebust}" -o "$WORKDIR/x86_64.deb" \
        || die "下载失败: $DEB_X86_64_URL"
    say "下载 aarch64 deb ..."
    curl -fSL --retry 3 --retry-delay 2 "${DEB_AARCH64_URL}?v=${cachebust}" -o "$WORKDIR/aarch64.deb" \
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

    # epoch 由我们在本地维护，不照抄上游 deb 的值；上游值只记录在 _debver 里。
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
        say "上游无变化: deb $debver，基准包 $base_str"
        local cmpw
        cmpw=$(vercmp "$work_str" "$base_str" || true)
        if ((cmpw > 0)); then
            say "工作区已是 $work_str，尚未打 tag；发布后请: git tag v${work_pkgver}-${work_rel}"
        elif ((cmpw < 0)); then
            warn "工作区版本 $work_str 低于基准；是否有 epoch/pkgver 被误改？"
        fi
        return 0
    fi

    # 工作区已经包含这个 deb（通常是上一次更新后还没打 tag）：
    # 不要再 bump pkgrel，否则每次重跑都会把版本越推越高。
    if [[ $debver == "$work_debver" && $pkgver == "$work_pkgver" \
          && $sha_x == "$work_sha_x" && $sha_a == "$work_sha_a" ]]; then
        say "工作区已包含该 deb: $debver（pkgver=$pkgver, pkgrel=$work_rel）"
        local wcmp_work
        wcmp_work=$(vercmp "$work_str" "$base_str" || true)
        if (( ${wcmp_work:-0} < 0 )); then
            warn "工作区版本 $work_str 低于已发布基准 $base_str"
        elif [[ -n $baseline_tag && $work_str != "$base_str" ]]; then
            say "尚未打 tag；发布后请: git tag v${work_pkgver}-${work_rel}"
        fi
        return 0
    fi


    # 以已发布基准为参照；工作区若被手工改高，只取它的 pkgrel/epoch 作为下限，
    # 避免复用可能已经构建过的版本号。
    local max_rel=$cur_rel
    # 只有工作区和基准在同一条 pkgver 线上时，它的 pkgrel 才是有意义的下限；
    # 否则会把另一条版本线的高 pkgrel 带过来，造成无谓的跳号。
    if [[ $work_pkgver == "$cur_pkgver" ]] && pkgrel_gt "$work_rel" "$max_rel"; then
        max_rel=$work_rel
    fi
    local epoch=$cur_epoch epoch_from_work=0
    if [[ -n $work_epoch ]]; then
        if [[ -z $epoch ]] || ((10#$work_epoch > 10#$epoch)); then
            epoch=$work_epoch
            epoch_from_work=1
        fi
    fi

    local new_rel reason
    if [[ $debver == "$cur_debver" ]]; then
        new_rel=$(pkgrel_bump "$max_rel")
        reason='同版本内容变化（上游重打包），pkgrel+1'
    elif [[ $pkgver != "$cur_pkgver" ]]; then
        new_rel=1
        reason='上游版本变化，pkgrel 归 1'
    else
        new_rel=$(pkgrel_bump "$max_rel")
        reason='仅 Debian 修订号变化，pkgrel+1'
    fi

    local new_str="${epoch:+$epoch:}${pkgver}-${new_rel}"
    local cmp epoch_bumped=0 old_epoch=''
    cmp=$(vercmp "$new_str" "$base_str" || true)
    if ((cmp <= 0)); then
        # 上游版本回退（或基准高于候选）：本地 epoch 自增。
        # 这是让 pacman 接受“更旧的上游版本”的唯一手段。
        epoch_bumped=1
        old_epoch=${epoch:-0}
        epoch=$((old_epoch + 1))
        new_rel=1
        new_str="${epoch}:${pkgver}-${new_rel}"
        reason="版本未前进（$base_str），本地 epoch 自增 ${old_epoch} -> ${epoch}，pkgrel 归 1"
        cmp=$(vercmp "$new_str" "$base_str" || true)
        if ((cmp <= 0)); then
            die "epoch 自增后仍无法超过 $base_str，拒绝继续"
        fi
    fi

    # 工作区可能领先 tag（改过但未打 tag）。候选版本必须超过它，
    # 否则会复用、甚至降低一个可能已经构建/安装过的版本号。
    local work_ahead
    work_ahead=$(vercmp "$work_str" "$base_str" || true)
    if (( ${work_ahead:-0} > 0 )); then
        local cw
        cw=$(vercmp "$new_str" "$work_str" || true)
        if (( ${cw:-0} <= 0 )); then
            if [[ $pkgver == "$work_pkgver" ]]; then
                new_rel=$(pkgrel_bump "$work_rel")
                new_str="${epoch:+$epoch:}${pkgver}-${new_rel}"
                reason="工作区已领先基准（$work_str），pkgrel 提升到 $new_rel 以避免复用"
                cw=$(vercmp "$new_str" "$work_str" || true)
            fi
            if (( ${cw:-0} <= 0 )); then
                die "工作区版本 $work_str 不低于候选 $new_str，拒绝写入。
请先给工作区版本打 tag，或把工作区恢复到不高于 $base_str。"
            fi
        fi
    fi

    say "计划: $base_str -> $new_str"
    say "原因: $reason"
    say "sha256 x86_64: $sha_x"
    say "sha256 aarch64: $sha_a"
    if ((epoch_bumped)); then
        say "注意: 本地 epoch ${old_epoch:-0} -> ${epoch} 是不可逆操作"
    elif ((epoch_from_work)); then
        say "注意: 采纳工作区 epoch ${cur_epoch:-0} -> ${epoch} 是不可逆操作"
    fi

    if [[ $mode == check ]]; then
        if ((epoch_bumped || epoch_from_work)); then
            say "（需要 --accept-epoch 才会写入）"
        fi
        return 0
    fi

    # ---- epoch 闸门 ----
    if (( (epoch_bumped || epoch_from_work) && ! accept_epoch )); then
        if ((epoch_bumped)); then
            warn "检测到需要本地 epoch 自增，但未提供 --accept-epoch；PKGBUILD 未改动"
        else
            warn "工作区 epoch 高于基准，采纳它需要 --accept-epoch；PKGBUILD 未改动"
        fi
        warn "确认 deb $debver 确实要发布后，重跑: ./update.sh --accept-epoch"
        return 1
    fi

    local backup="$WORKDIR/PKGBUILD.bak" srcinfo_tmp=".SRCINFO.tmp.$$"
    cp PKGBUILD "$backup"
    # 必须在 if 里调用：write_pkgbuild 回读失败返回 1，直接调用时 set -e 会
    # 立刻退出，下面的回滚就成了死代码。
    if ! write_pkgbuild "$pkgver" "$new_rel" "$epoch" "$debver" "$sha_x" "$sha_a"; then
        cp "$backup" PKGBUILD
        die "PKGBUILD 回读校验失败，已回滚（.SRCINFO 未改动）"
    fi
    if ! makepkg --printsrcinfo > "$srcinfo_tmp"; then
        rm -f "$srcinfo_tmp"
        cp "$backup" PKGBUILD
        die "新 PKGBUILD 校验失败，已回滚 PKGBUILD（.SRCINFO 未改动）"
    fi
    mv "$srcinfo_tmp" .SRCINFO
    say "已更新 PKGBUILD 与 .SRCINFO"
    if ((git_repo)); then
        say "发布后请打 tag: git add -A && git commit -m \"${pkgname} ${pkgver}-${new_rel}\" && git tag v${pkgver}-${new_rel}"
    fi

    if ((do_build)); then
        say "开始构建 ..."
        makepkg -fc
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
