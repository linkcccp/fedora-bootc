# 自定义 Fedora bootc image

## Fedora bootc KDE 桌面镜像

`Containerfile` 基于 `quay.io/fedora/fedora-bootc:45`，在其上安装 KDE Plasma 桌面环境，
并启用 RPM Fusion free/nonfree 及其 updates 仓库，安装 Firefox（Fedora 官方 RPM）、
VS Code、Microsoft Edge、Google Chrome、Fcitx5 中文输入法、Clash Verge Rev、v2rayN、
NVIDIA 驱动（构建时本地编译）、多媒体组件、中文字体、语言包和最新版
JetBrains Mono Nerd Font（安装全部变体），以及一组常用的开发、终端和容器工具
（Git、Kitty、Neovim、Fish、Podman、Distrobox、Toolbox、ripgrep、fzf、bat、eza、fastfetch、
starship、ouch 等）。Starship 从 Copr `seaweed/starship` 安装，ouch 从 Copr `boobaa/ouch`
安装；两个仓库都在镜像中保持启用。
RPM Fusion 的 release 包默认启用主仓库和 updates 仓库。

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

GitHub Actions 只响应标签和定时任务，推送到 `main` 不会触发构建。仓库只保留
`dev.yml` 和 `iso.yml` 两个工作流。

### Dev 构建

创建并推送 `dev-*` 或 `Dev-*` 标签（例如 `dev-test1` 或 `Dev-20261118-1`）会构建容器
镜像，镜像 tag 和 GitHub Release tag 都使用完整标签。Dev 构建会更新
`ghcr.io/linkcccp/fedora-bootc:latest`，并创建 GitHub Release；Release 附件包含
`packages.tsv`、`packages.json`、`changes.json`、`changes.md` 和 ISO 下载脚本，但
不包含 ISO。

另有每 3 天北京时间 05:00 的定时 Dev 构建，标签为 `dev-YYYY.MM.DD.HHMM`，例如
`dev-2026.11.18.1514`。

### Release 构建

创建并推送 `release-*` 或 `Release-*` 标签（后缀任意，例如 `release-2026.11.18.1514`）
会完整构建容器镜像和 KDE 桌面安装 ISO。镜像 tag、GitHub Release tag 都使用完整标签；
镜像会更新 `latest`。Release 附件包含 ISO 分卷、校验文件、下载脚本、
`packages.tsv`、`packages.json`、`changes.json` 和 `changes.md`。

另有每 7 天北京时间周一 11:00 的定时 Release 构建，标签为
`release-YYYY.MM.DD.HHMM`，例如 `release-2026.11.18.1514`。

Dev 和 Release 都会把各自成功的镜像推送到 GHCR 的 `latest`，并把 GitHub Release
标记为 latest；因此两个 `latest` 都指向最近一次成功的构建，Dev 构建可能成为 latest。
ISO 是交互式 Anaconda 安装介质，内嵌完整镜像，可以离线安装，适合用 Ventoy U 盘
从零安装。每次构建会根据最近一个包含 `packages.tsv` 的 GitHub Release（不区分
Dev/Release 前缀）生成软件包变更记录；ISO 资产只保留最近 3 个 Release。

## 从 ISO 安装（Ventoy）

GitHub Release 限制单个附件最大 2 GiB，而 ISO 内嵌完整镜像，体积约 10 GB，因此
ISO 以 `.iso.part-*` 分卷发布。Release 会附带下载合并脚本，脚本会自动
找到最新的 `release-*` ISO Release、下载全部分卷、校验并合并成单个 `.iso`。
所有 Release（包括没有 ISO 的 Dev Release）都会附带这些脚本，因此 latest Release
是 Dev 时，`releases/latest/download/download-iso.sh` 仍然可用；脚本会自动跳过
没有 ISO 分卷的 Release。

Linux/macOS：

```sh
curl -fLO https://github.com/linkcccp/fedora-bootc/releases/latest/download/download-iso.sh
bash download-iso.sh
```

Windows：从最新 Release 下载 `download-iso.cmd`，双击运行；如果同目录缺少
`download-iso.ps1`，脚本会自动下载。

脚本默认下载约 10 GB 数据，需要至少约 14 GiB 可用空间；合并完成后会删除分卷。
可用参数：

```sh
# 指定 Release 标签
bash download-iso.sh --version release-2026.11.18.1514
# 也可省略 release- 前缀
bash download-iso.sh --version 2026.11.18.1514
# 保留分卷
bash download-iso.sh --keep-parts
# 指定输出目录
bash download-iso.sh --output-dir /path/to/isos
```

也可以手动下载全部分卷和 `.iso.sha256` 后合并：

```sh
iso_name=$(basename "$(ls fedora-bootc-kde-*.iso.part-00)" .part-00)
cat "$iso_name".part-* > "$iso_name"
sha256sum -c "$iso_name.sha256"
```

把合并后的 ISO 复制到 Ventoy U 盘，启动时选择该 ISO。安装流程：

1. 进入 Anaconda 图形安装界面，选择语言、键盘和时区。
2. 在“安装目的地”选择磁盘；一般使用自动分区即可。自定义分区时必须给 `/boot`
   设置标签 `boot`。
3. 创建用户并加入 `wheel` 组；安装器不会自动清空磁盘，所有写入都要等确认后开始。
4. 安装完成后重启，系统通过 `bootc upgrade` 跟踪
   `ghcr.io/linkcccp/fedora-bootc:latest`。

ISO 内嵌完整镜像，安装过程不需要联网。启用 Secure Boot 时，NVIDIA 内核模块没有
签名，可能无法加载；需要 NVIDIA 驱动时请关闭 Secure Boot，或自行配置模块签名和
MOK 注册。

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

Google Chrome 仓库由 Fedora 的 `fedora-workstation-repositories` 软件包提供。
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

KDE 自带的 IBus 软件包会保留；镜像已将 Fcitx 5 预设为 Plasma Wayland 虚拟键盘，
`fcitx5-autostart` 负责设置输入法环境变量并随桌面会话启动 Fcitx5。首次进入 KDE 后，
用 `fcitx5-configtool` 添加“拼音”输入法即可。Wayland 原生应用通过该虚拟键盘设置使用输入法。

## KDE 外观与默认配置

镜像预装 [Fluent-kde](https://github.com/vinceliuice/Fluent-kde) 的 `Fluent-light`
Plasma 主题和 Aurorae 窗口装饰，以及 [Fluent11](https://github.com/luisrguerra/fluent11-icon-theme)
图标主题。默认配色为 FluentLight，小部件样式为 Breeze，光标为 Breeze_Light。
等宽字体使用 [Maple Mono Normal NF CN](https://github.com/subframe7536/maple-font)
（Regular、Bold、Italic、Bold Italic）；界面字体使用 Noto Sans。主题资源分别保留
上游许可证，Maple Mono 字体使用 OFL-1.1 许可证。

宿主机的 MiSans 字体未打包进镜像，因为目前没有可核验的再分发授权；界面使用 Fedora
提供的 Noto Sans。宿主机的动态壁纸和完整面板布局属于用户配置，未复制到系统镜像。
Plasma 默认面板模板已设为不悬浮，新用户首次生成默认面板时生效。

KWin 默认启用最小化“神灯”动效，并在鼠标闲置 15 秒后隐藏光标。上述外观和 KWin
选项写入 `/etc/xdg` 作为系统默认值；默认面板模板的禁悬浮设置写入
`/usr/share/plasma/layout-templates`。已有用户配置仍可覆盖这些默认值。

## 代理客户端

镜像安装了以下代理客户端：

- Clash Verge Rev：构建时从 GitHub 最新 release 选择 x86_64 RPM
- v2rayN：构建时从 GitHub 最新 release 选择 RHEL x86_64 RPM

构建过程会调用 GitHub Releases API 获取最新版本，重新构建镜像即可升级，
不需要修改版本参数。GitHub Actions 使用工作流自带的 token 查询 release，避免匿名请求的
API 速率限制；直接本地构建时若匿名 API 被限流，可稍后重试或通过
`CLASH_VERGE_RPM_URL`、`V2RAYN_RPM_URL` build args 传入对应 RPM URL。

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
- 安装 `/usr/libexec/nvidia-clock-ac`、`nvidia-clock-ac.service` 和
  `/usr/lib/udev/rules.d/90-nvidia-ac-clock.rules` 来管理 GPU 频率

`nvidia-clock-ac.service` 在接通电源时将 NVIDIA Graphics Clock 锁定在
`900 MHz` 到该 GPU 的最大频率之间；切换到电池时执行 `nvidia-smi -rgc` 恢复默认。
udev 规则会在任意 `Mains` 电源状态变化时触发服务；没有电池的台式机按接通电源处理。
这是运行时 GPU 时钟设置，不是内核或 CPU 频率参数。

如果旧系统在 `/etc/systemd/system/nvidia-clock-ac.service`、
`/etc/udev/rules.d/90-nvidia-ac-clock.rules` 或 `/usr/local/bin/nvidia-clock-ac`
保留了手工配置，需要先删除这些文件，避免覆盖或重复触发镜像自带配置：

```sh
sudo systemctl disable --now nvidia-clock-ac.service
sudo rm -f /etc/systemd/system/nvidia-clock-ac.service \
  /etc/systemd/system/multi-user.target.wants/nvidia-clock-ac.service \
  /etc/udev/rules.d/90-nvidia-ac-clock.rules \
  /usr/local/bin/nvidia-clock-ac
sudo systemctl daemon-reload
sudo udevadm control --reload
```

最终镜像不安装 `akmod-nvidia`、`akmods` 或编译器，也不在 bootc 系统运行时自动
重编译模块。系统通过 `bootc upgrade` 切换到包含新内核和新模块的新镜像。启用
Secure Boot 时，模块必须使用受固件信任的密钥签名并完成 MOK 注册；本 Containerfile
没有内置签名密钥。未配置签名时请关闭 Secure Boot，或自行配置 akmods 签名和 MOK
注册。若 RPM Fusion 的驱动源码暂时无法匹配 Fedora 内核，构建会在编译阶段失败；
请等待 RPM Fusion 更新后重新构建，不要在构建过程中临时升级内核。
