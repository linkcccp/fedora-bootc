# fedora-bootc —— 现在只是 aurora 之上的一层薄定制
#
# 基座：ghcr.io/ublue-os/aurora-nvidia-open:stable
#   已经自带：Kinoite/KDE、NVIDIA 驱动与 kargs、ffmpeg/mesa 覆盖、Flathub、Bazaar、
#   podman/flatpak/distrobox/fish 等常用工具。
#
# 这里只加这几样东西：
#   1. 中文：langpacks-zh_CN + fcitx5 全套 + KDE Wayland 输入法默认值
#   2. 代理：Clash Verge Rev（GUI/TUN）+ v2rayA（Web UI + 内置 v2raya_core）
#   3. 服务：NVIDIA 插电锁频（udev 触发的 oneshot，已 enable）
#   4. 外观：Maple Mono / JetBrains Nerd Font + Fluent Light 主题与 Fluent11 图标
#
# 构建：
#   podman build -f Containerfile -t ghcr.io/linkcccp/fedora-bootc:latest .
# 切换：
#   sudo bootc switch ghcr.io/linkcccp/fedora-bootc:latest

ARG BASE_IMAGE=ghcr.io/ublue-os/aurora-nvidia-open:stable
FROM ${BASE_IMAGE}

# bootc 里 /opt 指向 /var/opt，而构建阶段 /var 是 tmpfs：
# 换成真实目录，避免第三方包把内容写进会被丢弃的 /var。
RUN set -eux; \
    mkdir -p /var/roothome; \
    if [ -L /opt ]; then rm /opt; mkdir -p /opt; fi

# ---------------------------------------------------------------------------
# 1. 中文环境
# ---------------------------------------------------------------------------
# bootc 上没法用 PackageKit 事后补语言包，glibc 的 zh_CN locale 和中文本地化
# 必须在构建期装进 /usr。
RUN set -eux; \
    dnf install -y \
        langpacks-zh_CN \
        fcitx5 \
        fcitx5-autostart \
        fcitx5-chinese-addons \
        fcitx5-configtool \
        fcitx5-gtk \
        fcitx5-qt; \
    if ! dnf -y install glibc-langpack-zh; then \
        echo "glibc-langpack-zh 不存在，回退到 glibc-all-langpacks"; \
        dnf -y install glibc-all-langpacks; \
    fi; \
    dnf clean all; \
    locale -a | grep -qx 'zh_CN.utf8'

# fcitx5-autostart 提供 /etc/profile.d/fcitx5.sh（GTK_IM_MODULE / QT_IM_MODULE /
# XMODIFIERS），要保留；但它的 XDG 自启动会和 kwinrc 的 [Wayland] InputMethod
# 重复拉起 fcitx5，后启动的实例抢不到 D-Bus 名字会卸载全部 addon，故关掉自启动。
# kwinrc 的 InputMethod 是 Plasma 6 启用 text-input-v3 的条件，否则原生 Wayland
# 应用（Plasma 本体、KRunner）打不出中文。
RUN set -eux; \
    printf '%s\n' \
        '[Desktop Entry]' \
        'Type=Application' \
        'Name=Fcitx 5' \
        'Hidden=true' \
        > /etc/xdg/autostart/org.fcitx.Fcitx5.desktop; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group Wayland --key InputMethod \
        /usr/share/applications/org.fcitx.Fcitx5.desktop

# 中文 locale 下 xdg-user-dirs 会把 $HOME 目录翻译成「下载/文档/桌面」，
# 统一固定为英文名。
RUN set -eux; \
    printf 'enabled=False\n' > /etc/xdg/user-dirs.conf; \
    install -d -m 0755 /etc/skel/.config; \
    printf '%s\n' \
        'XDG_DESKTOP_DIR="$HOME/Desktop"' \
        'XDG_DOWNLOAD_DIR="$HOME/Downloads"' \
        'XDG_TEMPLATES_DIR="$HOME/Templates"' \
        'XDG_PUBLICSHARE_DIR="$HOME/Public"' \
        'XDG_DOCUMENTS_DIR="$HOME/Documents"' \
        'XDG_MUSIC_DIR="$HOME/Music"' \
        'XDG_PICTURES_DIR="$HOME/Pictures"' \
        'XDG_VIDEOS_DIR="$HOME/Videos"' \
        'XDG_PROJECTS_DIR="$HOME/Projects"' \
        > /etc/skel/.config/user-dirs.dirs; \
    install -d -m 0755 \
        /etc/skel/Desktop /etc/skel/Downloads /etc/skel/Templates \
        /etc/skel/Public /etc/skel/Documents /etc/skel/Music \
        /etc/skel/Pictures /etc/skel/Videos /etc/skel/Projects

# ---------------------------------------------------------------------------
# 2. 代理
# ---------------------------------------------------------------------------
# Clash Verge Rev：Tauri GUI + clash-verge-service（TUN 模式的特权 helper）。
# 上游只有 GitHub Release 的 rpm；CI 传入 URL，本地构建回退到 GitHub API。
#
# 注意：2.5.x 起 rpm **不再自带 systemd 单元**，只带 clash-verge-service-install。
# 该安装器会把服务二进制复制到 /var/lib/clash-verge-service/ 并把单元写进
# /etc/systemd/system/，两者在构建阶段（/var 是 tmpfs）都必须避免，
# 所以这里只做安装、不 enable：首次在 GUI 里开 TUN 时它会提示安装服务，
# 点一次即可，装出来的东西落在可写层，bootc 升级不会丢。
ARG CLASH_VERGE_RPM_URL
RUN set -eux; \
    url="${CLASH_VERGE_RPM_URL:-}"; \
    if [ -z "$url" ]; then \
        url="$(curl -fsSL --retry 3 --retry-all-errors \
            -H 'Accept: application/vnd.github+json' \
            https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest \
            | jq -er '[.assets[] | select(.name | test("\\.(x86_64|amd64|x64)\\.rpm$"; "i"))][0].browser_download_url')"; \
    fi; \
    dnf install -y "$url"; \
    dnf clean all; \
    test -x /usr/bin/clash-verge-service; \
    test -x /usr/bin/clash-verge-service-install; \
    ls /usr/share/applications | grep -qi clash

# v2rayA：Web UI + 系统服务，支持 vmess/vless/trojan/ss，订阅可直接导入。
# 2.5.x 起核心私有化为 v2raya_core（xray fork），版本必须与主程序完全一致，
# 否则启动即报 CORE_VERSION_MISMATCH。官方 redhat rpm 里主程序、配套核心、
# systemd 单元和 /usr/share/v2raya/{geoip,geosite}.dat 齐全，且依赖只有
# rpmlib(...)，不需要 Fedora 仓库里没有的 v2ray/xray 包，所以直接装它。
# CI 传入经认证 API 解析出的 rpm 地址；本地构建回退到公开 API（可能撞限流）。
ARG V2RAYA_RPM_URL
RUN set -eux; \
    dnf install -y nftables iproute; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
        case "$(uname -m)" in \
            x86_64) arch=amd64 ;; \
            aarch64) arch=arm64 ;; \
            *) arch="$(uname -m)" ;; \
        esac; \
    fi; \
    case "$arch" in \
        amd64) rpmarch=x64 ;; \
        arm64) rpmarch=arm64 ;; \
        *) echo "unsupported arch for v2rayA rpm: $arch" >&2; exit 1 ;; \
    esac; \
    url="${V2RAYA_RPM_URL:-}"; \
    if [ -z "$url" ]; then \
        tag="$(curl -fsSL --retry 3 --retry-all-errors \
            -H 'Accept: application/vnd.github+json' \
            https://api.github.com/repos/v2rayA/v2rayA/releases/latest | jq -er .tag_name)"; \
        ver="${tag#v}"; \
        url="https://github.com/v2rayA/v2rayA/releases/download/${tag}/installer_redhat_${rpmarch}_${ver}.rpm"; \
    fi; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/v2raya.rpm "$url"; \
    dnf install -y /tmp/v2raya.rpm; \
    rm -f /tmp/v2raya.rpm; \
    test -x /usr/bin/v2raya; \
    test -x /usr/bin/v2raya_core; \
    test -f /usr/share/v2raya/geoip.dat; \
    test -f /usr/lib/systemd/system/v2raya.service; \
    install -d -m 0755 /etc/systemd/system/v2raya.service.d; \
    printf '%s\n' \
        '[Service]' \
        'LogsDirectory=v2raya' \
        > /etc/systemd/system/v2raya.service.d/logs.conf; \
    dnf clean all; \
    systemctl enable v2raya.service

# ---------------------------------------------------------------------------
# 3. NVIDIA 插电锁频（已启用）
# ---------------------------------------------------------------------------
# udev 规则在电源状态变化时拉起这个 oneshot：插电时把核心频率下限固定为当前
# 最大值（nvidia-smi -lgc），切到电池时恢复默认（nvidia-smi -rgc）。
# nvidia-powerd 由 aurora 的 nvidia 变体提供，这里只补服务本身。
COPY files/nvidia-clock/nvidia-clock-ac /usr/libexec/nvidia-clock-ac
COPY files/nvidia-clock/nvidia-clock-ac.service /usr/lib/systemd/system/nvidia-clock-ac.service
COPY files/nvidia-clock/90-nvidia-ac-clock.rules /usr/lib/udev/rules.d/90-nvidia-ac-clock.rules
RUN set -eux; \
    chmod 0755 /usr/libexec/nvidia-clock-ac; \
    systemctl enable nvidia-clock-ac.service; \
    udevadm verify /usr/lib/udev/rules.d/90-nvidia-ac-clock.rules; \
    test -x /usr/libexec/nvidia-clock-ac; \
    test -L /etc/systemd/system/multi-user.target.wants/nvidia-clock-ac.service

# ---------------------------------------------------------------------------
# 4. 字体与主题（系统级，装进 /usr/share，所有用户共享，无需手动执行）
# ---------------------------------------------------------------------------
# Maple Mono Normal NF CN：等宽 + 中文字形（OFL）。
RUN set -eux; \
    dnf install -y unzip gtk-update-icon-cache; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/maple.zip \
        https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMonoNormal-NF-CN.zip; \
    printf '%s  %s\n' \
        24aeb14ed756d78b112e6692ea02c669e16afaa0f01e7bfdbb37d2e63fa45fa7 \
        /tmp/maple.zip | sha256sum -c -; \
    install -d /usr/share/fonts/maple-mono /usr/share/licenses/maple-font; \
    unzip -q -j /tmp/maple.zip \
        MapleMonoNormal-NF-CN-Regular.ttf \
        MapleMonoNormal-NF-CN-Bold.ttf \
        MapleMonoNormal-NF-CN-Italic.ttf \
        MapleMonoNormal-NF-CN-BoldItalic.ttf \
        -d /usr/share/fonts/maple-mono; \
    unzip -p /tmp/maple.zip LICENSE.txt > /usr/share/licenses/maple-font/LICENSE.txt; \
    rm -f /tmp/maple.zip

# JetBrains Mono Nerd Font：全部变体。
RUN set -eux; \
    install -d /usr/share/fonts/nerd-fonts/JetBrainsMono; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/jbmono.zip \
        https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip; \
    unzip -q -j -o /tmp/jbmono.zip '*.ttf' -d /usr/share/fonts/nerd-fonts/JetBrainsMono; \
    rm -f /tmp/jbmono.zip; \
    fc-cache -f /usr/share/fonts

# Fluent Light Plasma 主题 + Fluent11 图标。
# install.sh 检测到 root 时会自动装进 /usr/share/{aurorae,plasma,color-schemes}，
# 正是我们要的系统级位置，不需要额外的 --dest。
RUN set -eux; \
    install -d /tmp/fluent-kde; \
    curl -fsSL --retry 3 --retry-all-errors \
        https://github.com/vinceliuice/Fluent-kde/archive/44794f29c89de994b0179aebabd2f5776c90d236.tar.gz \
        | tar -xz --strip-components=1 -C /tmp/fluent-kde; \
    (cd /tmp/fluent-kde && bash ./install.sh --theme default --color light); \
    install -D -m 0644 /tmp/fluent-kde/LICENSE /usr/share/licenses/fluent-kde/LICENSE; \
    rm -rf /tmp/fluent-kde /root/.config/Kvantum; \
    rm -f /root/.Xresources; \
    install -d /tmp/fluent11; \
    curl -fsSL --retry 3 --retry-all-errors \
        https://github.com/luisrguerra/fluent11-icon-theme/archive/11c74905bc51be17f1e5b65fc46c02d6c6280577.tar.gz \
        | tar -xz --strip-components=1 -C /tmp/fluent11; \
    cp -a /tmp/fluent11/fluent11 /usr/share/icons/; \
    install -D -m 0644 /tmp/fluent11/LICENSE /usr/share/licenses/fluent11-icon-theme/LICENSE; \
    rm -rf /tmp/fluent11; \
    gtk-update-icon-cache -q -f /usr/share/icons/fluent11

# 系统级 KDE 默认值（用户仍可在自己 ~/.config 里覆盖）。
# 注意：这里只追加 kwinrc 的装饰相关键，不会覆盖上面写入的 [Wayland] InputMethod。
RUN set -eux; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key ColorScheme FluentLight; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group General --key fixed \
        'Maple Mono Normal NF CN,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,,0,0'; \
    kwriteconfig6 --file /etc/xdg/kdeglobals --group Icons --key Theme fluent11; \
    kwriteconfig6 --file /etc/xdg/plasmarc --group Theme --key name Fluent-light; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group org.kde.kdecoration2 --key library \
        org.kde.kwin.aurorae.v2; \
    kwriteconfig6 --file /etc/xdg/kwinrc --group org.kde.kdecoration2 --key theme \
        __aurorae__svg__Fluent-light

# ---------------------------------------------------------------------------
# 5. GRUB 主题（Vimix，4K 资源，随仓库分发）
# ---------------------------------------------------------------------------
# 主题文件直接放在 files/grub/vimix，构建时不访问 GitHub：
# 不走 api.github.com 的匿名配额，也不用把 token 塞进镜像 history。
# bootc 的 /boot 在运行时是独立分区，镜像里 /boot 的内容会被 mask
# （bootc lint 的 nonempty-boot），所以主题装进 /usr/share，
# 由 grub-theme-sync.service 在每次启动时同步到 /boot。
COPY files/grub/vimix /usr/share/grub/themes/vimix
# 上游完整资产库（3 配色 × 3 分辨率图标、20 张背景、13 个字体、5 套布局）。
# 只作为备用，不参与启动；换配色/分辨率的方法见 library/README.md。
COPY files/grub/library /usr/share/grub/grub2-themes
COPY files/grub/default-grub /etc/default/grub
COPY files/grub/grub-theme-sync /usr/libexec/grub-theme-sync
COPY files/grub/grub-theme-sync.service /usr/lib/systemd/system/grub-theme-sync.service
COPY files/grub/grub2-themes.LICENSE /usr/share/licenses/grub2-themes/LICENSE
RUN set -eux; \
    theme=/usr/share/grub/themes/vimix; \
    lib=/usr/share/grub/grub2-themes; \
    chmod 0755 /usr/libexec/grub-theme-sync; \
    bash -n /usr/libexec/grub-theme-sync; \
    test -s "$theme/theme.txt"; \
    test -s "$theme/background.jpg"; \
    test "$(head -c 3 "$theme/background.jpg" | od -An -tx1 | tr -d ' \n')" = ffd8ff; \
    test "$(head -c 4 "$theme/icons/fedora.png" | od -An -tx1 | tr -d ' \n')" = 89504e47; \
    test -s "$theme/dejavu_sans_32.pf2"; \
    test -s "$theme/terminus-18.pf2"; \
    test -s "$theme/icons/fedora.png"; \
    test -s "$theme/icons/windows.png"; \
    test -s "$theme/icons/macosx.png"; \
    test -s "$theme/icons/macos.png"; \
    test -s "$theme/icons/chromeos.png"; \
    test -s "$theme/icons/chrome.png"; \
    test "$(find "$lib/icons" -name '*.png' | wc -l)" -eq 684; \
    test "$(find "$lib/backgrounds" -name '*.jpg' | wc -l)" -eq 20; \
    test "$(find "$lib/fonts" -name '*.pf2' | wc -l)" -eq 13; \
    test "$(find "$lib/config" -name 'theme-*.txt' | wc -l)" -eq 5; \
    test "$(find "$lib/select" -name 'select_*.png' | wc -l)" -eq 9; \
    test -s "$lib/info/info-4k.png"; \
    systemctl enable grub-theme-sync.service; \
    test -L /etc/systemd/system/multi-user.target.wants/grub-theme-sync.service

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
RUN set -eux; \
    rpm -q fcitx5 fcitx5-chinese-addons fcitx5-qt fcitx5-gtk langpacks-zh_CN; \
    locale -a | grep -qx 'zh_CN.utf8'; \
    test -f /usr/share/applications/org.fcitx.Fcitx5.desktop; \
    grep -qx 'InputMethod=/usr/share/applications/org.fcitx.Fcitx5.desktop' /etc/xdg/kwinrc; \
    rpm -q v2raya; \
    test -x /usr/bin/v2raya; \
    test -x /usr/bin/v2raya_core; \
    test -f /usr/share/v2raya/geoip.dat; \
    test -L /etc/systemd/system/multi-user.target.wants/v2raya.service; \
    test -L /etc/systemd/system/multi-user.target.wants/nvidia-clock-ac.service; \
    test -x /usr/bin/clash-verge-service-install; \
    test -f /usr/share/fonts/maple-mono/MapleMonoNormal-NF-CN-Regular.ttf; \
    test -n "$(find /usr/share/fonts/nerd-fonts/JetBrainsMono -name '*.ttf' -print -quit)"; \
    test -f /usr/share/color-schemes/FluentLight.colors; \
    test -d /usr/share/plasma/desktoptheme/Fluent-light; \
    test -d /usr/share/aurorae/themes/Fluent-light; \
    test -f /usr/share/icons/fluent11/index.theme; \
    grep -qx 'ColorScheme=FluentLight' /etc/xdg/kdeglobals; \
    grep -qx 'GRUB_THEME="/boot/grub2/themes/vimix/theme.txt"' /etc/default/grub; \
    grep -qx 'GRUB_GRUBENV_UPDATE=no' /etc/default/grub; \
    test -L /etc/systemd/system/multi-user.target.wants/grub-theme-sync.service; \
    test ! -e /boot/grub2/themes; \
    bootc container lint
