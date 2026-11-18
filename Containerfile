ARG BASE_IMAGE=quay.io/fedora/fedora-bootc:45

FROM ${BASE_IMAGE} AS base

# 部分 RPM 包安装需要 root 的 home 目录。
# bootc 中 /opt 可能是 /var/opt 的符号链接；改为普通目录，确保第三方软件
# 安装到随镜像更新的 /opt。
RUN mkdir -p /var/roothome; \
    if [ -L /opt ]; then rm /opt; mkdir -p /opt; fi

# 安装 RPM Fusion free/nonfree release 包。
# release 包默认启用主仓库和 updates 仓库。
RUN dnf install -y \
        dnf5-plugins \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
    && dnf clean all

FROM base AS nvidia-builder

# 在独立阶段为目标内核编译 NVIDIA 模块。
# 强制使用 open 模块，避免构建主机 GPU 影响 RPM Fusion 的自动检测。
# 最终镜像只复制编译产物，不包含 gcc、akmods 等构建依赖。
RUN set -eux; \
    dnf makecache --refresh; \
    kver="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"; \
    test -n "$kver"; \
    test "$(printf '%s\n' "$kver" | wc -l)" -eq 1; \
    test -d "/usr/lib/modules/${kver}"; \
    if ! dnf install -y "kernel-devel-${kver}"; then \
        dnf install -y fedora-repos-archive; \
        dnf makecache --refresh --enablerepo='*archive*'; \
        dnf install -y --enablerepo='*archive*' "kernel-devel-${kver}"; \
    fi; \
    dnf install -y \
        akmods \
        gcc gcc-c++ make \
        elfutils-libelf-devel \
        kmodtool pahole pciutils \
        rpm-build redhat-rpm-config \
        xz zstd; \
    chmod 1777 /var/tmp; \
    printf '%%_with_kmod_nvidia_open 1\n' > /etc/rpm/macros.nvidia-open; \
    dnf install -y --setopt=tsflags=noscripts akmod-nvidia; \
    akmods --force --kernels "${kver}"; \
    depmod -a "${kver}"; \
    test -n "$(find "/usr/lib/modules/${kver}" -name 'nvidia.ko*' -print -quit)"; \
    test -n "$(find "/usr/lib/modules/${kver}" -name 'nvidia-drm.ko*' -print -quit)"; \
    install -d /rpms; \
    cp /var/cache/akmods/nvidia/kmod-nvidia-"${kver}"-*.rpm /rpms/; \
    dnf clean all

FROM base

# 安装 KDE Plasma 桌面环境。
# 该环境已包含 base-graphical、fonts、multimedia、hardware-support、
# networkmanager-submodules、printing、guest-desktop-agents、firefox 等组。
# 保留 KDE 环境自带的 IBus 软件包及 KDE 所需的 ibus-libs。
RUN dnf makecache --refresh && dnf environment install -y kde-desktop-environment && dnf clean all

# 安装 Fluent Light Plasma 主题和窗口装饰。
RUN set -eux; \
    install -d /tmp/fluent-kde; \
    curl -fsSL \
        https://github.com/vinceliuice/Fluent-kde/archive/44794f29c89de994b0179aebabd2f5776c90d236.tar.gz \
        | tar -xz --strip-components=1 -C /tmp/fluent-kde; \
    (cd /tmp/fluent-kde && bash ./install.sh --theme default --color light); \
    install -D -m 0644 /tmp/fluent-kde/LICENSE /usr/share/licenses/fluent-kde/LICENSE; \
    install -D -m 0644 /tmp/fluent-kde/README.md /usr/share/doc/fluent-kde/README.md; \
    test -f /usr/share/color-schemes/FluentLight.colors; \
    test -f /usr/share/plasma/desktoptheme/Fluent-light/metadata.desktop; \
    test -f /usr/share/aurorae/themes/Fluent-light/metadata.desktop; \
    rm -rf /tmp/fluent-kde

# 安装 Fluent11 图标主题并保留上游许可证和说明。
RUN set -eux; \
    install -d /tmp/fluent11; \
    curl -fsSL \
        https://github.com/luisrguerra/fluent11-icon-theme/archive/11c74905bc51be17f1e5b65fc46c02d6c6280577.tar.gz \
        | tar -xz --strip-components=1 -C /tmp/fluent11; \
    install -d /usr/share/icons /usr/share/licenses/fluent11-icon-theme /usr/share/doc/fluent11-icon-theme; \
    cp -a /tmp/fluent11/fluent11 /usr/share/icons/; \
    install -m 0644 /tmp/fluent11/LICENSE /usr/share/licenses/fluent11-icon-theme/LICENSE; \
    install -m 0644 /tmp/fluent11/README.md /usr/share/doc/fluent11-icon-theme/README.md; \
    gtk-update-icon-cache -q /usr/share/icons/fluent11; \
    test -f /usr/share/icons/fluent11/index.theme; \
    rm -rf /tmp/fluent11

# 优先使用 RPM Fusion 的完整 ffmpeg；未安装 ffmpeg-free 时直接安装。
RUN set -eux; \
    dnf makecache --refresh; \
    if rpm -q ffmpeg-free >/dev/null 2>&1; then \
        dnf swap -y ffmpeg-free ffmpeg --allowerasing; \
    else \
        dnf install -y ffmpeg; \
    fi; \
    dnf clean all

# 安装简体中文语言包和 GTK 图标缓存工具；CJK 字体由 KDE 环境的 @fonts 组提供。
RUN dnf makecache --refresh && dnf install -y langpacks-zh_CN gtk-update-icon-cache && dnf clean all

# 安装 Fcitx5 中文输入法和配置工具。
RUN dnf makecache --refresh && dnf install -y fcitx5 && dnf clean all
RUN dnf makecache --refresh && dnf install -y fcitx5-autostart && dnf clean all
RUN dnf makecache --refresh && dnf install -y fcitx5-chinese-addons && dnf clean all
RUN dnf makecache --refresh && dnf install -y fcitx5-configtool && dnf clean all
RUN dnf makecache --refresh && dnf install -y fcitx5-gtk && dnf clean all
RUN dnf makecache --refresh && dnf install -y fcitx5-qt && dnf clean all
# 写入 KDE/KWin 系统级默认值，用户配置可覆盖。
# 默认使用 Fcitx5 虚拟键盘、启用神灯效果，并在鼠标闲置 15 秒后隐藏光标。
RUN set -eux; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key ColorScheme FluentLight; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key font \
        'Noto Sans,10,-1,5,50,0,0,0,0,0'; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key fixed \
        'Maple Mono Normal NF CN,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,,0,0'; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group KDE --key widgetStyle Breeze; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group Icons --key Theme fluent11; \
    kwriteconfig6 --file /etc/xdg/plasmarc --group Theme --key name Fluent-light; \
    kwriteconfig6 --file /etc/xdg/kcminputrc --group Mouse --key cursorTheme Breeze_Light; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group Wayland --key InputMethod \
        /usr/share/applications/org.fcitx.Fcitx5.desktop; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group org.kde.kdecoration2 --key library \
        org.kde.kwin.aurorae.v2; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group org.kde.kdecoration2 --key theme \
        __aurorae__svg__Fluent-light; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group Plugins --key magiclampEnabled true; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group Plugins --key hidecursorEnabled true; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group Effect-hidecursor --key InactivityDuration 15

# 复制 builder 阶段编译出的 kmod，并在最终镜像安装匹配的用户态驱动。
# 排除 kmod-nvidia 元包和 akmod-nvidia，避免把编译工具链带入最终镜像。
COPY --from=nvidia-builder /rpms/ /rpms/

RUN set -eux; \
    kver="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"; \
    test -n "$kver"; \
    dnf makecache --refresh; \
    dnf install -y \
        --exclude='kmod-nvidia' \
        --exclude='akmod-nvidia' \
        /rpms/kmod-nvidia-"${kver}"-*.rpm \
        xorg-x11-drv-nvidia \
        xorg-x11-drv-nvidia-cuda \
        xorg-x11-drv-nvidia-power \
        nvidia-settings; \
    test -n "$(find "/usr/lib/modules/${kver}/extra/nvidia" -name 'nvidia.ko*' -print -quit)"; \
    test -n "$(find "/usr/lib/modules/${kver}/extra/nvidia" -name 'nvidia-drm.ko*' -print -quit)"; \
    test "$(rpm -q --queryformat '%{VERSION}' "kmod-nvidia-${kver}")" = "$(rpm -q --queryformat '%{VERSION}' xorg-x11-drv-nvidia)"; \
    ! rpm -q akmod-nvidia >/dev/null 2>&1; \
    printf '%s\n' \
        'blacklist nouveau' \
        'options nouveau modeset=0' \
        > /etc/modprobe.d/blacklist-nouveau.conf; \
    printf '%s\n' 'options nvidia-drm modeset=1' \
        > /etc/modprobe.d/nvidia.conf; \
    install -d /usr/lib/bootc/kargs.d; \
    printf '%s\n' \
        'kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]' \
        > /usr/lib/bootc/kargs.d/00-nvidia.toml; \
    rm -rf /rpms; \
    dnf clean all

# 安装 OFL 授权的 Maple Mono Normal NF CN 常用字形。
RUN set -eux; \
    curl -fsSL -o /tmp/MapleMonoNormal-NF-CN.zip \
        https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMonoNormal-NF-CN.zip; \
    printf '%s  %s\n' \
        24aeb14ed756d78b112e6692ea02c669e16afaa0f01e7bfdbb37d2e63fa45fa7 \
        /tmp/MapleMonoNormal-NF-CN.zip \
        | sha256sum -c -; \
    install -d /usr/share/fonts/maple-mono /usr/share/licenses/maple-font; \
    unzip -j /tmp/MapleMonoNormal-NF-CN.zip \
        MapleMonoNormal-NF-CN-Regular.ttf \
        MapleMonoNormal-NF-CN-Bold.ttf \
        MapleMonoNormal-NF-CN-Italic.ttf \
        MapleMonoNormal-NF-CN-BoldItalic.ttf \
        -d /usr/share/fonts/maple-mono; \
    unzip -p /tmp/MapleMonoNormal-NF-CN.zip LICENSE.txt \
        > /usr/share/licenses/maple-font/LICENSE.txt; \
    fc-cache -f /usr/share/fonts/maple-mono; \
    rm -f /tmp/MapleMonoNormal-NF-CN.zip

# 安装最新版 JetBrains Mono Nerd Font，并解压全部变体。
RUN set -eux; \
    font_dir=/usr/share/fonts/nerd-fonts/JetBrainsMono; \
    install -d "$font_dir"; \
    curl -fsSL -o /tmp/JetBrainsMono.zip \
        "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"; \
    unzip -j /tmp/JetBrainsMono.zip '*.ttf' -d "$font_dir"; \
    rm -f /tmp/JetBrainsMono.zip; \
    fc-cache -f "$font_dir"

# 开发、终端与容器工具。每个软件单独一层，避免更新一个包时重建整组。
# curl、unzip、rsync、wget 和 toolbox 已由 KDE 环境的 core、standard、
# kde-desktop 组提供，这里不再重复安装。
RUN dnf makecache --refresh && dnf install -y git && dnf clean all
RUN dnf makecache --refresh && dnf install -y git-lfs && dnf clean all
RUN dnf makecache --refresh && dnf install -y gh && dnf clean all
RUN dnf makecache --refresh && dnf install -y neovim && dnf clean all
RUN dnf makecache --refresh && dnf install -y kitty && dnf clean all
RUN dnf makecache --refresh && dnf install -y fish && dnf clean all
RUN dnf makecache --refresh && dnf install -y podman && dnf clean all
RUN dnf makecache --refresh && dnf install -y podman-compose && dnf clean all
RUN dnf makecache --refresh && dnf install -y buildah && dnf clean all
RUN dnf makecache --refresh && dnf install -y skopeo && dnf clean all
RUN dnf makecache --refresh && dnf install -y distrobox && dnf clean all
RUN dnf makecache --refresh && dnf install -y ripgrep && dnf clean all
RUN dnf makecache --refresh && dnf install -y fd-find && dnf clean all
RUN dnf makecache --refresh && dnf install -y fzf && dnf clean all
RUN dnf makecache --refresh && dnf install -y bat && dnf clean all
RUN dnf makecache --refresh && dnf install -y eza && dnf clean all
RUN dnf makecache --refresh && dnf install -y fastfetch && dnf clean all
RUN dnf copr enable -y seaweed/starship \
    && dnf makecache --refresh \
    && dnf install -y starship \
    && dnf clean all
RUN dnf makecache --refresh && dnf install -y htop && dnf clean all
RUN dnf makecache --refresh && dnf install -y btop && dnf clean all
RUN dnf makecache --refresh && dnf install -y jq && dnf clean all
RUN dnf makecache --refresh && dnf install -y yq && dnf clean all
RUN dnf makecache --refresh && dnf install -y p7zip && dnf clean all
RUN dnf makecache --refresh && dnf install -y ouch && dnf clean all

# 安装 Flatpak，并通过系统级 remotes.d 预配置 Flathub 源。
RUN dnf makecache --refresh && dnf install -y flatpak && dnf clean all
RUN set -eux; \
    install -d /usr/share/flatpak/remotes.d; \
    curl -fsSL --retry 3 --retry-all-errors \
        -o /usr/share/flatpak/remotes.d/flathub.flatpakrepo \
        https://flathub.org/repo/flathub.flatpakrepo; \
    grep -q '^\[Flatpak Repo\]' /usr/share/flatpak/remotes.d/flathub.flatpakrepo; \
    grep -q '^GPGKey=' /usr/share/flatpak/remotes.d/flathub.flatpakrepo

# 导入第三方仓库 key，并写入 VS Code、Microsoft Edge 仓库配置。
# Google Chrome 仓库由 fedora-workstation-repositories 提供。
# 所有第三方仓库保持禁用，安装时临时启用。
RUN set -eux; \
    install -d /etc/yum.repos.d; \
    rpm --import https://packages.microsoft.com/keys/microsoft.asc; \
    rpm --import https://dl.google.com/linux/linux_signing_key.pub; \
    printf '%s\n' \
        '[code]' \
        'name=Visual Studio Code' \
        'baseurl=https://packages.microsoft.com/yumrepos/vscode' \
        'enabled=0' \
        'gpgcheck=1' \
        'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' \
        > /etc/yum.repos.d/vscode.repo; \
    printf '%s\n' \
        '[microsoft-edge]' \
        'name=Microsoft Edge' \
        'baseurl=https://packages.microsoft.com/yumrepos/edge' \
        'enabled=0' \
        'gpgcheck=1' \
        'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' \
        > /etc/yum.repos.d/microsoft-edge.repo

# 安装 VS Code、Microsoft Edge 和 Google Chrome。
RUN dnf makecache --refresh --enablerepo=code && dnf install -y --enablerepo=code code && dnf clean all
RUN dnf makecache --refresh --enablerepo=microsoft-edge && dnf install -y --enablerepo=microsoft-edge microsoft-edge-stable && dnf clean all
RUN dnf makecache --refresh --enablerepo=google-chrome && dnf install -y --enablerepo=google-chrome google-chrome-stable && dnf clean all

# 安装最新版 Clash Verge Rev，使用上游提供的 x86_64 RPM。
RUN set -eux; \
    clash_url="$(curl -fsSL --retry 3 --retry-all-errors \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest \
        | jq -er '[.assets[] | select(.name | endswith(".x86_64.rpm"))][0].browser_download_url')"; \
    dnf makecache --refresh; \
    dnf install -y "$clash_url"; \
    dnf clean all

# 安装最新版 v2rayN，使用上游提供的 RHEL x86_64 RPM。
RUN set -eux; \
    v2rayn_url="$(curl -fsSL --retry 3 --retry-all-errors \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/2dust/v2rayN/releases/latest \
        | jq -er '[.assets[] | select(.name == "v2rayN-linux-rhel-64.rpm")][0].browser_download_url')"; \
    dnf makecache --refresh; \
    dnf install -y "$v2rayn_url"; \
    dnf clean all

# 默认进入图形界面，并启用 Plasma Login Manager。
RUN systemctl set-default graphical.target \
    && systemctl enable plasmalogin

# 构建过程使用官方源；最终镜像通过 dnf5 仓库覆盖配置改为中国大陆 Fedora 镜像。
# Fedora 45 的发行版仓库位于 /usr/share/dnf5/repos.d/，因此不直接修改
# /etc/yum.repos.d/，而是写入 /etc/dnf/repos.override.d/99-fedora-mirror.repo。
ARG FEDORA_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/fedora
RUN set -eux; \
    FEDORA_MIRROR="${FEDORA_MIRROR%/}"; \
    install -d /etc/dnf/repos.override.d; \
    printf '%s\n' \
        '[fedora]' \
        'metalink=' \
        "baseurl=${FEDORA_MIRROR}/releases/\$releasever/Everything/\$basearch/os/" \
        '' \
        '[updates]' \
        'metalink=' \
        "baseurl=${FEDORA_MIRROR}/updates/\$releasever/Everything/\$basearch/" \
        > /etc/dnf/repos.override.d/99-fedora-mirror.repo; \
    dnf clean all

# 将 Fish 设为默认登录 shell：root 和后续新建用户。
ENV SHELL=/usr/bin/fish
RUN set -eux; \
    grep -qx '/usr/bin/fish' /etc/shells || printf '%s\n' '/usr/bin/fish' >> /etc/shells; \
    if [ -f /etc/default/useradd ]; then \
        if grep -q '^SHELL=' /etc/default/useradd; then \
            sed -i 's|^SHELL=.*|SHELL=/usr/bin/fish|' /etc/default/useradd; \
        else \
            printf '%s\n' 'SHELL=/usr/bin/fish' >> /etc/default/useradd; \
        fi; \
    else \
        printf '%s\n' 'SHELL=/usr/bin/fish' > /etc/default/useradd; \
    fi; \
    usermod -s /usr/bin/fish root

# 禁用 Plasma 默认面板的悬浮效果，新用户首次创建面板时生效。
RUN set -eux; \
    layout=/usr/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js; \
    test -f "$layout"; \
    if ! grep -Fxq 'panel.floating = false' "$layout"; then \
        sed -i '/^var panel = new Panel$/a panel.floating = false' "$layout"; \
    fi; \
    grep -Fxq 'panel.floating = false' "$layout"

# 校验最终镜像是否符合 bootc 规范。
RUN bootc container lint
