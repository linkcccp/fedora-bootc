# fedora-bootc

基于 [Aurora](https://github.com/ublue-os/aurora) 的个人 KDE 桌面镜像。

`Containerfile` 只是在官方 aurora 之上加一层薄定制，桌面环境、内核、显卡驱动全部跟随上游，
不再自己维护。

```dockerfile
ARG BASE_IMAGE=ghcr.io/ublue-os/aurora-nvidia-open:stable
FROM ${BASE_IMAGE}
```

| 由 aurora 提供 | 由本仓库提供 |
| --- | --- |
| KDE Plasma（Kinoite 基础） | 中文语言包 + fcitx5 输入法 |
| NVIDIA 驱动、内核参数、akmods | Clash Verge Rev（GUI + TUN） |
| ffmpeg / mesa / libva 覆盖 | v2rayA（Web UI + 内置 v2raya_core） |
| Flathub、Bazaar、flatpak 预装 | NVIDIA 插电锁频服务 |
| podman / flatpak / distrobox / fish | Maple Mono、JetBrains Nerd Font |
| Secure Boot 签名、内核跟随 Fedora | Fluent Light 主题 + Fluent11 图标 |

> 非 NVIDIA 机器把 `ARG BASE_IMAGE` 改成 `ghcr.io/ublue-os/aurora:stable` 即可。

## 镜像里加了什么

### 1. 中文

- `langpacks-zh_CN`（带 `glibc-langpack-zh`，bootc 上无法用 PackageKit 事后补装）
- `fcitx5` + `fcitx5-autostart` + `fcitx5-chinese-addons` + `fcitx5-configtool` + `fcitx5-gtk` + `fcitx5-qt`
- **关掉 fcitx5 的 XDG 自启动**（`Hidden=true`），改由 KWin 的 `[Wayland] InputMethod` 拉起：
  两个实例会抢 D-Bus 名字，后启动的那个抢不到就把 addon 全卸载，表现为「输入法在但打不出字」
- XDG 用户目录固定英文名（`/etc/skel` 预置 + `user-dirs.conf` 关闭自动翻译）

### 2. 代理

- **Clash Verge Rev**：Tauri GUI；TUN 用的 `clash-verge-service` 不随镜像启用——
  上游 2.5.x 起由 `clash-verge-service-install` 在首次开 TUN 时装进
  `/etc/systemd/system` 与 `/var/lib/clash-verge-service`（可写层，升级不丢）
- **v2rayA**：官方 redhat rpm（`v2raya` + 配套 `v2raya_core` + geo 数据 +
  `v2raya.service`），`v2raya.service` 已 enable，Web UI 在 `http://127.0.0.1:2017`，
  支持 `vmess://` / `vless://` / base64 订阅。2.5.x 起核心版本必须与主程序严格一致，
  所以核心**不要**换成本机的 xray；改用新版只需改 rpm 地址（CI 自动取 latest）

> 两个客户端**不要同时开 TUN**，会互相抢路由。

### 3. NVIDIA 插电锁频

- `/usr/libexec/nvidia-clock-ac` + `/usr/lib/udev/rules.d/90-nvidia-ac-clock.rules`
- 电源状态变化时由 udev 拉起 oneshot：插电 `nvidia-smi -lgc 900,max`，电池切回 `-rgc`
- 关闭：`sudo systemctl disable --now nvidia-clock-ac.service`

### 4. 外观（系统级，装进 `/usr/share`）

- 字体：`/usr/share/fonts/maple-mono`、`/usr/share/fonts/nerd-fonts/JetBrainsMono`
- 主题：Fluent Light（Aurorae 装饰 / Plasma 主题 / 配色方案）+ Fluent11 图标
- `/etc/xdg/{kdeglobals,plasmarc,kwinrc}` 写入系统级默认值，用户 `~/.config` 仍可覆盖

## 构建

```sh
podman build -f Containerfile -t ghcr.io/linkcccp/fedora-bootc:latest .
```

CI 会传入 `--build-arg CLASH_VERGE_RPM_URL=...`（经认证 API 解析的最新 rpm）；
本地不传时容器内回退到公开 GitHub API。

## 切换到该镜像

```sh
sudo bootc switch ghcr.io/linkcccp/fedora-bootc:latest
sudo systemctl reboot
```

回滚：

```sh
sudo bootc rollback
```

## 开机后要做的三件事

这三项属于用户状态，镜像不预置：

1. **输入法**：系统设置 → 输入法 → 添加「拼音（Fcitx 5）」
2. **Clash**：打开 Clash Verge Rev → 导入订阅 → 开启 TUN 时按提示点一次「安装服务」
   （`clash-verge-service` 由 GUI 装进 `/etc/systemd/system` 与 `/var/lib`，只需一次）
3. **v2rayA**：浏览器打开 `http://127.0.0.1:2017` → 创建管理员账号 → 导入订阅

自检命令：

```sh
systemctl status v2raya nvidia-clock-ac
systemctl status clash-verge-service   # 首次开过 TUN 之后才会有
rpm -q fcitx5 fcitx5-chinese-addons langpacks-zh_CN
fc-match "Maple Mono Normal NF CN"
ls /usr/share/plasma/desktoptheme/Fluent-light
```

## 工作流

| 工作流 | 触发 | 产物 |
| --- | --- | --- |
| `dev.yml` | 推送 `dev-*` / `Dev-*` 标签；每 3 天 21:00 UTC（北京时间 05:00） | 容器镜像 + GitHub Release（含软件包差异、下载脚本） |
| `iso.yml` | 推送 `release-*` / `Release-*` 标签；每周一 03:00 UTC（北京时间 11:00）；手动 | 容器镜像 + 内嵌镜像的可离线安装 ISO（分卷发布） |

两者都会更新 `ghcr.io/linkcccp/fedora-bootc:latest`。

ISO 通过 `bootc-image-builder` 的 `bootc-generic-iso` 从 `iso/Containerfile` 构建，
安装器环境自行定义（Fedora 45 把仓库配置移到了 `/usr/share/dnf5/repos.d`，
legacy anaconda-iso 读不到仓库，详见 `iso/Containerfile` 顶部注释）。

## 目录

```
Containerfile                 # 全部定制（中文 / 代理 / 服务 / 外观）
files/nvidia-clock/           # 锁频脚本、systemd 单元、udev 规则
iso/Containerfile             # ISO 安装器容器
.github/workflows/dev.yml     # 容器镜像构建
.github/workflows/iso.yml     # ISO 构建与发布
.github/scripts/iso/          # ISO 分卷下载脚本（sh / ps1 / cmd）
.github/scripts/diff-packages.sh
```

## 说明

- **`/opt` 与 `/var`**：bootc 里 `/opt` 指向 `/var/opt`，而构建阶段 `/var` 是 tmpfs，
  所以先把 `/opt` 换成真实目录，避免第三方包写进会被丢弃的路径。
- **不再内置**：VS Code / Edge / Chrome、gh / neovim / kitty 等开发工具、tuna 镜像覆盖。
  aurora 自带 Homebrew，CLI 工具用 `brew install` 即可；GUI 应用用 Flatpak
  （`flatpak install flathub com.visualstudio.code` 等）。
- **更新方式**：`uupd` 会按当前 ref 自动 `bootc upgrade`
- **层分块**：构建完会用 [chunkah](https://github.com/coreos/chunkah) 重新切层
  （与 aurora 上游同工具同参数），定制层从整块变成 ~2–5 MiB 的小块，
  `bootc upgrade` 只需下载变化的部分。
