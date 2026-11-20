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
| ffmpeg / mesa / libva 覆盖 | v2rayA（Web UI + Xray 内核） |
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

- **Clash Verge Rev**：Tauri GUI + `clash-verge-service`（TUN 模式的特权 helper，已 enable）
- **v2rayA**：静态二进制 + Xray 内核 + geo 数据，`v2raya.service` 已 enable，
  Web UI 在 `http://127.0.0.1:2017`，支持 `vmess://` / `vless://` / base64 订阅

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
2. **Clash**：打开 Clash Verge Rev → 导入订阅 → 按需开启 TUN
3. **v2rayA**：浏览器打开 `http://127.0.0.1:2017` → 创建管理员账号 → 导入订阅

自检命令：

```sh
systemctl status v2raya clash-verge-service nvidia-clock-ac
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
- **更新方式**：`uupd` 会按当前 ref 自动 `bootc upgrade`，不需要本仓库的定时构建。
