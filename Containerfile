# fedora-bootc —— 现在只是 aurora 之上的一层薄定制
#
# 基座：ghcr.io/ublue-os/aurora-nvidia-open:stable
#   已经自带：Kinoite/KDE、NVIDIA 驱动与 kargs、ffmpeg/mesa 覆盖、Flathub、Bazaar、
#   podman/flatpak/distrobox/fish 等常用工具。
#
# 这里只加这几样东西：
#   1. 中文：langpacks-zh_CN + fcitx5 全套 + KDE Wayland 输入法默认值
#   2. 代理：Clash Verge Rev（GUI/TUN）+ v2rayA（Web UI + Xray 内核）
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
    dnf clean all

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
    systemctl enable clash-verge-service.service

# v2rayA：Web UI + 系统服务，支持 vmess/vless/trojan/ss，订阅可直接导入。
# 上游 rpm 依赖 Fedora 仓库里没有的 v2ray/xray 包，所以直接装静态二进制；
# 前端已 go:embed 进二进制，不需要额外 web 资源。
RUN set -eux; \
    dnf install -y nftables iproute unzip; \
    tag="$(curl -fsSL --retry 3 --retry-all-errors \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/v2rayA/v2rayA/releases/latest | jq -er .tag_name)"; \
    ver="${tag#v}"; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/v2raya \
        "https://github.com/v2rayA/v2rayA/releases/download/${tag}/v2raya_linux_x64_${ver}"; \
    install -D -m 0755 /tmp/v2raya /usr/bin/v2raya; \
    rm -f /tmp/v2raya; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip; \
    install -d /usr/share/xray; \
    unzip -o -j /tmp/xray.zip xray -d /usr/bin; \
    unzip -o -j /tmp/xray.zip geoip.dat geosite.dat -d /usr/share/xray; \
    chmod 0755 /usr/bin/xray; \
    rm -f /tmp/xray.zip; \
    install -d -m 0755 /etc/v2raya; \
    printf '%s\n' \
        '[Unit]' \
        'Description=v2rayA Service' \
        'After=network.target network-online.target nss-lookup.target nftables.service' \
        'Wants=network.target' \
        '' \
        '[Service]' \
        'Type=simple' \
        'User=root' \
        'LimitNPROC=500' \
        'LimitNOFILE=1000000' \
        'ExecStart=/usr/bin/v2raya --log-disable-timestamp' \
        'Environment=V2RAYA_LOG_FILE=/var/log/v2raya/v2raya.log' \
        'Environment=XRAY_LOCATION_ASSET=/usr/share/xray' \
        'LogsDirectory=v2raya' \
        'KillMode=mixed' \
        'Restart=on-failure' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' \
        > /usr/lib/systemd/system/v2raya.service; \
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
# 自检
# ---------------------------------------------------------------------------
RUN set -eux; \
    rpm -q fcitx5 fcitx5-chinese-addons fcitx5-qt fcitx5-gtk langpacks-zh_CN glibc-langpack-zh; \
    locale -a | grep -qx 'zh_CN.utf8'; \
    test -f /usr/share/applications/org.fcitx.Fcitx5.desktop; \
    grep -qx 'InputMethod=/usr/share/applications/org.fcitx.Fcitx5.desktop' /etc/xdg/kwinrc; \
    test -x /usr/bin/v2raya; \
    test -x /usr/bin/xray; \
    test -f /usr/share/xray/geoip.dat; \
    test -L /etc/systemd/system/multi-user.target.wants/v2raya.service; \
    test -L /etc/systemd/system/multi-user.target.wants/clash-verge-service.service; \
    test -L /etc/systemd/system/multi-user.target.wants/nvidia-clock-ac.service; \
    test -f /usr/share/fonts/maple-mono/MapleMonoNormal-NF-CN-Regular.ttf; \
    test -n "$(find /usr/share/fonts/nerd-fonts/JetBrainsMono -name '*.ttf' -print -quit)"; \
    test -f /usr/share/color-schemes/FluentLight.colors; \
    test -d /usr/share/plasma/desktoptheme/Fluent-light; \
    test -d /usr/share/aurorae/themes/Fluent-light; \
    test -f /usr/share/icons/fluent11/index.theme; \
    grep -qx 'ColorScheme=FluentLight' /etc/xdg/kdeglobals; \
    bootc container lint
