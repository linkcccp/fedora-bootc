# 自定义 Fedora bootc image

## Fedora bootc KDE 桌面镜像

`Containerfile` 基于 `quay.io/fedora/fedora-bootc:45`，在其上安装 KDE Plasma 桌面环境，
并启用 RPM Fusion free/nonfree 及其 updates 仓库，安装 Firefox（Fedora 官方 RPM）、
VS Code、Microsoft Edge、Google Chrome、Fcitx5 中文输入法、Clash Verge Rev、v2rayN、
NVIDIA 驱动（构建时本地编译）、多媒体组件、中文字体、语言包和最新版
JetBrains Mono Nerd Font（安装全部变体），以及一组常用的开发、终端和容器工具
（Git、Kitty、Neovim、Fish、Podman、Distrobox、Toolbox、ripgrep、fzf、bat、eza、fastfetch、
starship、ouch 等）。RPM Fusion 的 release 包默认启用主仓库和 updates 仓库。

镜像默认进入 `graphical.target` 并启用 Plasma Login Manager（`plasmalogin`），
适合直接切换到裸机或虚拟机上的 bootc 系统。Fish 被设为 root 和后续通过 `useradd`
新建用户的默认登录 shell；Kitty 作为终端模拟器安装。

构建：

```sh
podman build -f Containerfile -t localhost/fedora-bootc:latest .
```

在已有 bootc 系统上切换到该镜像：

```sh
sudo bootc switch ghcr.io/linkcccp/fedora-bootc:latest
sudo systemctl reboot
```

GitHub Actions 会在推送到 `main`、手动触发及每周一北京时间 05:00 构建并推送
`ghcr.io/linkcccp/fedora-bootc`。每次构建使用上海时区 `YYYYMMDDHHmm`
版本 tag；默认分支同时更新 `latest`。

每次构建还会导出 RPM 软件包清单，并用 `rpm.vercmp` 与上一个 Release 比较，
生成软件包变更记录。默认分支构建会创建 `build-YYYYMMDDHHmm` Release，附件包含
`packages.tsv`、`packages.json`、`changes.json` 和 `changes.md`。

bootc 镜像自带内核和引导，构建中不执行全量 `dnf upgrade`，系统更新通过
`bootc upgrade` 完成。

构建过程使用 Fedora 官方软件源；最终镜像通过
`/etc/dnf/repos.override.d/99-fedora-mirror.repo` 把 `fedora` 和 `updates` 仓库
切换到清华 TUNA 镜像。Fedora 45 的发行版仓库文件位于 `/usr/share/dnf5/repos.d/`，
因此不直接修改 `/etc/yum.repos.d/`。需要更换镜像时可通过构建参数覆盖：

```sh
podman build \
    --build-arg FEDORA_MIRROR=https://mirrors.ustc.edu.cn/fedora \
    -f Containerfile -t localhost/fedora-bootc:latest .
```

## 第三方桌面软件

镜像还安装了以下第三方 RPM：

- Visual Studio Code：`code`，来自 Microsoft VS Code 仓库
- Microsoft Edge Stable：`microsoft-edge-stable`，来自 Microsoft Edge 仓库
- Google Chrome Stable：`google-chrome-stable`，来自 Google Chrome 仓库

Firefox 保持 Fedora 官方 RPM，不添加 Mozilla 仓库。Edge 和 Chrome 只提供 x86_64
包，因此该镜像按 x86_64 构建；在 aarch64 等架构上构建会失败。

Chrome 和 Edge 会安装到 `/opt`。Containerfile 在安装前会把可能是 `/var/opt`
符号链接的 `/opt` 改为普通目录，使这些文件随镜像生命周期更新，而不是留在不会随
镜像升级的 `/var` 中。

上述第三方仓库在软件安装完成后默认禁用，仓库文件和 GPG key 仍保留。需要临时使用
`dnf` 时，可以重新启用：

```sh
sudo dnf config-manager setopt \
    code.enabled=1 \
    microsoft-edge.enabled=1 \
    google-chrome.enabled=1
```

这些软件通过重建镜像并切换或升级 bootc 镜像更新，不在系统内用 `dnf upgrade`
更新。

## Flatpak 与 Flathub

镜像安装 Flatpak，并通过 `/usr/share/flatpak/remotes.d/flathub.flatpakrepo`
预配置系统级 Flathub 源。该配置随镜像更新，不需要首次启动后手动执行
`flatpak remote-add`。可以用以下命令确认并安装应用：

```sh
flatpak remotes --system
flatpak install flathub org.mozilla.firefox
```

系统级 Flatpak 应用和运行时位于 `/var/lib/flatpak`，属于持久化系统状态，
不会写入镜像的 `/usr`。

## 中文输入法

镜像安装了 Fcitx5 及中文拼音支持：

- `fcitx5`
- `fcitx5-autostart`
- `fcitx5-chinese-addons`
- `fcitx5-configtool`
- `fcitx5-gtk`
- `fcitx5-qt`
- `kcm-fcitx5`

KDE 环境默认安装的 IBus 已在构建时排除，避免与 Fcitx5 同时启动。
`fcitx5-autostart` 负责设置输入法环境变量并随桌面会话启动 Fcitx5。首次进入 KDE 后，
在“系统设置 → 键盘 → 虚拟键盘”中选择 Fcitx 5，然后用 `fcitx5-configtool`
添加“拼音”输入法。Wayland 原生应用还需要该虚拟键盘设置才能使用输入法。

## 代理客户端

镜像安装了以下代理客户端：

- Clash Verge Rev：构建时从 GitHub 最新 release 选择 x86_64 RPM
- v2rayN：构建时从 GitHub 最新 release 选择 RHEL x86_64 RPM

构建过程会调用 GitHub Releases API 获取最新版本，重新构建镜像即可升级，
不需要修改版本参数。GitHub API 对未认证请求有速率限制；如果构建时被限流，
稍后重试即可。

## NVIDIA 驱动

镜像使用 RPM Fusion 的 `akmod-nvidia` 在独立的 builder 阶段为目标内核本地编译
NVIDIA 内核模块。构建时通过 RPM macro 强制使用 open 内核模块，避免构建主机 GPU
影响 RPM Fusion 的自动检测；RTX 3050 等受支持的 GPU 使用 open 模块。

Containerfile 会：

- 从 `kernel-core` 读取唯一的目标内核版本，而不是使用容器的 `uname -r`
- 安装匹配的 `kernel-devel-<版本>`；若普通仓库缺失，会尝试 Fedora archive 仓库
- 在 builder 阶段安装 `gcc`、`gcc-c++`、`make` 等编译依赖
- 通过 RPM macro 强制 RPM Fusion 的 `nvidia-kmod` 使用 `kernel-open`
- 使用 `akmods --force --kernels <版本>` 编译 NVIDIA 模块
- 把生成的 `kmod-nvidia` RPM 复制到最终镜像，并安装匹配的
  `xorg-x11-drv-nvidia`、`xorg-x11-drv-nvidia-cuda`、
  `xorg-x11-drv-nvidia-power` 和 `nvidia-settings`
- 校验 kmod 与用户态驱动版本一致
- 黑名单 `nouveau`
- 通过 `/usr/lib/bootc/kargs.d/00-nvidia.toml` 设置
  `rd.driver.blacklist=nouveau`、`modprobe.blacklist=nouveau` 和
  `nvidia-drm.modeset=1`

最终镜像不安装 `akmod-nvidia`、`akmods` 或编译器，也不在 bootc 系统运行时自动
重编译模块。系统通过 `bootc upgrade` 切换到包含新内核和新模块的新镜像。启用
Secure Boot 时，模块必须使用受固件信任的密钥签名并完成 MOK 注册；本 Containerfile
没有内置签名密钥。未配置签名时请关闭 Secure Boot，或自行配置 akmods 签名和 MOK
注册。若 RPM Fusion 的驱动源码暂时无法匹配 Fedora 内核，构建会在编译阶段失败；
请等待 RPM Fusion 更新后重新构建，不要在构建过程中临时升级内核。
