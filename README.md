# npclient

Manjaro/Arch 打包工作区，把 NetPad 的 NPclient 官方 Ubuntu `.deb` 转成 pacman 包。

## 目录内容

| 文件 | 说明 |
|---|---|
| `PKGBUILD` | 构建脚本（deb → Arch 包） |
| `npclient.install` | pacman 钩子脚本（安装/升级/卸载提示） |
| `update.sh` | 从上游 deb 的 control 同步 `pkgver`/`pkgrel`/`epoch`/两个架构的 sha256 |
| `.SRCINFO` | AUR 需要，`makepkg --printsrcinfo > .SRCINFO` 生成 |
| `linux-install.sh` | 上游 Ubuntu 安装脚本存档（与上游逐字节一致），**不要运行** |
| `npclient-0.1.12-3-x86_64.pkg.tar.zst` | 已构建好的包 |

## 构建与安装

```bash
makepkg -fci          # 构建并安装
makepkg --printsrcinfo > .SRCINFO   # 改动后重新生成
```

安装后需手动完成首次配置：

```bash
sudo usermod -aG npclient "$USER"        # 1. 重新登录后生效（访问 npd socket）
sudo systemctl enable --now npd.service  # 2. 守护进程 + 开机自启
npctl login                              # 3. 浏览器授权，凭据由 npd 长期保存
sudo npctl start --persist               # 4. 以 root 身份启动隧道
sudo npctl boot on                       # 5. 开机自动恢复隧道（强烈建议）
```

> **为什么是 `--persist`？** 纯 CLI 环境没有常驻客户端持有隧道所需的 owner 会话：
> `npctl login` 是短命进程，退出后会话即消失，非 root 的 `npctl start` 会报
> `error=NoActiveSession`（账号/节点查询却正常，容易误判成网络问题）。
> `--persist` 把隧道所有权交给系统（root），这是无 GUI 场景的正解；
> 代价是 `npctl status/tun/connections` 等查询需要 `sudo`，或改用
> `npctl web open` 的 Web 控制台（独立只读会话）。

验证：`sudo npctl doctor` 应显示 `running:true`、`mixedPort` 非 0、`tunEnabled:true`。
代理入口为 `http://127.0.0.1:<mixedPort>`（通常 7891）。

## 与上游 deb 的差异

| 项 | 上游 deb | 本包 | 原因 |
|---|---|---|---|
| 包名 | `npd` | `npclient` | 非自由软件且不提供源码，按 Nonfree guidelines 不加 `-bin`；用 `replaces`/`conflicts` 迁移旧名 `npclient-bin` |
| 预编译二进制 | 无 | `options=('!strip' '!debug')` | 上游已 strip，避免重复处理并跳过空 `-debug` 包 |
| 用户/组创建 | `postinst` 里 `useradd`/`groupadd` | `usr/lib/sysusers.d/npd.conf` | Arch 由 `20-systemd-sysusers.hook` 自动应用，声明式、可重复 |
| 自动启动 | `systemctl enable --now npd` | **不自动启用** | Arch 惯例：启停由用户决定 |
| polkit 规则 | 含 `manage-unit-files`（无单元过滤） | **移除该条**，只留 `resolve1` | 见下 |
| 自动加组 | `postinst` 扫描会话用户并入组 | 不自动，打印指引 | 避免脚本猜错用户 |
| SBOM / 许可证 | `/usr/share/doc/npd/*.json` | `/usr/share/licenses/npclient/` | Arch 路径规范；已验证运行时**不读取**这些文件 |
| 打包 | `dpkg -i` | `makepkg`（`.PKGINFO`/`.BUILDINFO`/`.MTREE` 齐全） | 合规 |
| 校验 | 脚本内 sha256 + `dpkg-deb -f` | `sha256sums_x86_64` | 同级别，但在构建期 |

> 早期包名是 `npclient-bin`；非自由软件、没有源码时不应使用 `-bin` 后缀，
> 因此改为 `npclient`，并用 `replaces`/`conflicts` 处理旧名迁移。

## 安全处理：移除了一条 polkit 规则

上游 `50-npclient.rules` 内容：

```javascript
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.resolve1.") === 0 &&
        subject.user == "npd") { return polkit.Result.YES; }
    if (action.id == "org.freedesktop.systemd1.manage-unit-files" &&
        subject.user == "npd") { return polkit.Result.YES; }
});
```

第二条规则匹配的是 `org.freedesktop.systemd1.manage-unit-files` 这个**通用动作 id**，且**没有任何单元名过滤**。这意味着用户 `npd` 可以写入/启用**系统上任意** systemd 单元文件。

而 `npd` 本身监听 `127.0.0.1:9090` 的 web 控制面（`npd.toml` 里 `web.enabled = true`）。一旦该面被攻破（或本地任意用户直接连），攻击者就能以 `npd` 身份落一个恶意 unit 并启用它，从 `CAP_NET_ADMIN` 升级到 root。

本包只保留 `resolve1` 那条（DNS 接管确实需要）。代价是 `npctl boot on|off` 需要 root——这本来就是 Arch 的常规做法。

> 如果你想保留原样，把 `package()` 里 polkit 那段的 heredoc 换回上游内容即可。

## 已知限制

1. **没有版本恒定 URL**。上游只提供 `npd_latest_amd64.deb`（移动目标），`?v=` 只是 CDN 缓存键——我验证过带与不带 `?v=` 载荷字节完全一致。历史版本中仅 `0.1.2` 有固定地址 `npd_0.1.2_amd64.deb`。
   → 后果：**上游一发版，`sha256sums` 立刻失效**，PKGBUILD 必须同步更新。这也是为什么它不该进 AUR 后放着不管。
2. **许可证不明**。deb 里没有 LICENSE/EULA 文件，`control` 也没有 `License:` 字段，只有第三方组件的 SBOM。所以用 `LicenseRef-NPclient-Proprietary`；包内 `/usr/share/licenses/npclient/` 只有 SBOM 和 GeoIP 声明，没有上游许可正文，AUR 提交前需要向上游确认并补齐。
3. **DNS 接管依赖 systemd-resolved**。上游 `Recommends: systemd-resolved`。Arch 上 `resolvectl` 由 `systemd` 提供，但 `systemd-resolved.service` 需启用；`systemd-resolvconf` 只在需要接管 `/etc/resolv.conf` 时才是必需——因此列为 `optdepends` 而非 `depends`。
4. **依赖是从 ELF 反推的**，不是抄 deb 的 `Depends:`：
   - `glibc` / `gcc-libs`：`NEEDED` 只有 `libc.so.6` 和 `libgcc_s.so.1`，最高符号版本 `GLIBC_2.34`（deb 声明 `>= 2.35`，实际要求更低）
   - `iproute2`：二进制会 `exec` `ip`（字符串里有 `ip addr json`、`ip route get`、`starting ip failed`）
   - `polkit`：polkit 规则文件生效所需
   - `iana-etc`：`getaddrinfo` 走服务名解析时需要 `/etc/services`
   - 未依赖 `iptables`/`nft` 可执行文件：只引用 netlink 常量，不 spawn 外部命令
5. **AUR 提交前的仓库元数据**：`# Maintainer:` 仍是占位名；仓库根目录已有 `LICENSE`
   （专有 / All rights reserved，见该文件对第三方内容的例外说明），但还没有 AUR 要求的
   `REUSE.toml`。这两项不影响本地构建。

## 上游地址

| 用途 | 地址 | 状态（2026-11-10 实测） |
|---|---|---|
| 官网 / 产品页 | <https://netpad.pro> | 200 |
| 官方 Linux 安装命令 | `curl -fsSL https://1net.netpad.pro/api/v2/public/linux-install \| sudo sh` | 200，`text/x-shellscript` |
| 安装脚本直链 | <https://1net.netpad.pro/api/v2/public/linux-install> | 200，3075 B，sha256 `c11f57f2…0c19e9` |
| deb（x86_64） | <https://assets.netpad.pro/download/Linux/npd_latest_amd64.deb> | 200，12 638 650 B |
| deb（aarch64） | <https://assets.netpad.pro/download/Linux/npd_latest_arm64.deb> | 200，12 103 498 B |
| deb 备用源 | `https://download.netpad.xyz/d/np/root/download/Linux/npd_latest_*.deb` | **连接被重置**（脚本里的 fallback，当前不可用） |
| GeoIP 资源 | `https://assets.netpad.pro/cool/tfeng/geoip/country.mmdb` | **404**（由 npd 运行时自行下载，非打包必需） |

`linux-install.sh` 与本仓库存档的副本**逐字节一致**（sha256 相同），说明存档没有过期。
deb 的 `control` 里 `Homepage: https://netpad.pro`、`Maintainer: NPclient <support@netpad.pro>`，
与上表一致。

> 上游没有公开的 Linux 文档页（`/docs`、`/docs/linux` 均 404），安装方式只有上面那条
> `curl | sudo sh` 管道命令；`netpad.pro/download` 是 SPA 路由，返回的是首页外壳。
> 因此本仓库的 `linux-install.sh` 存档 + 上表就是目前能拿到的最完整上游信息。

## 升级流程

上游只发布 `npd_latest_*.deb` 这个移动地址，没有版本化 URL——**每次上游发版，
`sha256sums` 必然失效**，所以下面的步骤要成套做。

### 自动：update.sh（推荐）

```bash
cd npclient-source
./update.sh --check     # 只预览：打印 deb Version 与 pkgver/pkgrel 计划
./update.sh             # 写 PKGBUILD 与 .SRCINFO
./update.sh --build     # 需要的话顺手 makepkg -fc
sudo pacman -U npclient-<新版本>-<pkgrel>-x86_64.pkg.tar.zst
```

两个安全约束：

- **`--accept-epoch` 闸门**：需要本地 epoch 自增、或要采纳工作区里更高的 epoch 时，
  默认只打印计划并退出，不写文件；确认无误后加 `--accept-epoch` 重跑。
- **以 git tag 为版本基准，但不允许低于工作区**：比较的是 HEAD 可达、版本最高的
  `v*` tag 里的 PKGBUILD（用户真正装过的那版），而不是可能被手工改过的工作区；没有
  tag 时才退回工作区并告警。如果工作区版本已经领先 tag（改了但还没打 tag），候选版本必须超过
  工作区：同 `pkgver` 时自动提升 `pkgrel`，工作区 `pkgver` 更高时直接拒绝写入。

所以每次发布、验证通过后要打 tag（tag 名不能带 `:`，epoch 从 tag 内的
PKGBUILD 读取）：

```bash
git add -A
git commit -m "npclient <pkgver>-<pkgrel>"
git tag "v<pkgver>-<pkgrel>"
```

它负责处理 Debian 的 `[epoch:]upstream_version[-debian_revision]`：

| Debian 部分 | 落到哪里 |
|---|---|
| `epoch:` | **不采用上游值**；本地维护的“排序修复计数器”，版本回退时 +1 |
| `upstream_version` | `pkgver`；`~` 会被去掉并告警（pacman 对 `~` 的排序与 Debian 相反） |
| `-debian_revision` | 不进 `pkgver`；上游版本没变、只有修订号变了时 `pkgrel+1` |
| 完整 Version | 记进 `_debver=`，下次用来判断“上游发版”还是“Debian 重打包” |

`epoch` 由我们在本地维护，不照抄上游 deb 的值：上游 epoch 只记录在 `_debver=`
里，变化时打印提示。新版本若没有超过当前 `epoch:pkgver-pkgrel`（典型是上游回退），
脚本把本地 epoch +1、`pkgrel` 归 1。这是不可逆操作，建议先 `./update.sh --check` 确认。

其他保证：两个架构的 deb 都下载并核对 `Package`/`Architecture`/`Version` 一致；
两个 `sha256sums_*` 直接用本地下载的 deb 计算（不依赖 `updpkgsums`）；下载带时间戳
查询参数，避免 CDN 缓存导致误判“无变化”；`source_*` 的文件名与 `?v=` 用完整
`_debver` + `pkgrel`，revision 变化或同版本重打包都不会复用旧 deb；`.SRCINFO` 先写临时文件，校验失败时
PKGBUILD 与 `.SRCINFO` 都不会被破坏。`pkgrel` 支持 Arch 的整数和小数形式（2、2.1）。
如果工作区已经包含上游这个 deb（通常是更新后还没打 tag），脚本只提示打 tag，不会
重复 bump `pkgrel`。

想单独看某个版本号怎么拆：`./update.sh --parse '1:0.1.13-2ubuntu1'`。

### 手工流程（等价做法）

```bash
cd npclient-source

# 1. 看有没有新版（不需要 root，也会打印更新说明）
npctl update --check

# 2. 下载并核对远端 deb 的版本与架构（两个架构都要看）
curl -fSL 'https://assets.netpad.pro/download/Linux/npd_latest_amd64.deb' -o .npchk-amd64.deb
bsdtar -xOf .npchk-amd64.deb control.tar.zst | bsdtar -xOf - ./control \
  | grep -E '^(Package|Version|Architecture):'

# 3. 改 PKGBUILD：pkgver 只填 upstream 部分；
#    上游版本变 → pkgrel=1；只有 Debian 修订号变 → pkgrel+1；
#    版本回退需要本地 epoch 自增时才写 epoch=N；_debver 填完整 Version

# 4. 重算校验和。updpkgsums 会同时处理 source_x86_64 与 source_aarch64
#    （它内部调用 makepkg --geninteg；命令来自 pacman-contrib，未装则先
#     sudo pacman -S pacman-contrib）
updpkgsums

# 5. 同步 AUR 元数据并构建（-c 顺手清掉 src/、pkg/）
makepkg --printsrcinfo > .SRCINFO
makepkg -fc

# 6. 检查产物：安装脚本有没有被带进去、文件列表有无异常
bsdtar -tf npclient-<新版本>-<pkgrel>-x86_64.pkg.tar.zst | grep -E '^\.(INSTALL|PKGINFO)$'
bsdtar -xOf npclient-<新版本>-<pkgrel>-x86_64.pkg.tar.zst .INSTALL | diff - npclient.install

# 7. 升级、重启守护进程、验证
sudo pacman -U npclient-<新版本>-<pkgrel>-x86_64.pkg.tar.zst
sudo systemctl restart npd.service     # post_upgrade 会提示
sudo npctl doctor                      # running=true、mixedPort 非 0
```

升级时还要顺手核对这几项，否则容易“版本号对了但包坏了”：

- **安装脚本**：上游 `postinst` 若新增动作（建目录、迁移配置、加 polkit 规则），
  `package()` 与 `npclient.install` 要跟着改；只改版本号会漏掉。
- **文件布局**：`bsdtar -tf 新包` 对比 `sudo pacman -Ql npclient`，确认没有
  `/lib/systemd/...`、`/usr/share/doc/...` 这类 Debian 残留重新混进来。
- **依赖**：`depends` 是从 ELF 的 `NEEDED` 反推的，不是抄 deb 的 `Depends:`。
  新版若链了新库，`readelf -d /usr/bin/npd` 一看就要补。
- **两个架构的 sha256 都要对**：`updpkgsums` 会处理两个架构的 source 数组；
  若没有它（`pacman-contrib` 未安装），就对两个 deb 各跑一次 `sha256sum`。

发布到 AUR 时只提交 `PKGBUILD` 与 `.SRCINFO`；二进制包、`.deb` 都不要进仓库。
本地仓库发版后记得提交并打 tag，否则下一次 `update.sh` 会继续以旧 tag 为基准。

## 卸载

```bash
sudo systemctl disable --now npd.service
sudo pacman -Rn npclient
# 彻底清除（本包有意保留这些）：
sudo rm -rf /var/lib/npd /etc/npclient
sudo userdel npd && sudo groupdel npclient
```
