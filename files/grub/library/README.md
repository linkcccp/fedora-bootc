# grub2-themes 完整资产库

上游：[vinceliuice/grub2-themes](https://github.com/vinceliuice/grub2-themes)
固定 commit：`4c5a77125b93f833edc9bf7b14a899faa8ac79c6`
许可：GPL-3.0（见 `../grub2-themes.LICENSE`）

镜像里安装在 `/usr/share/grub/grub2-themes`。这是**备用资产库**，不参与启动：
正在使用的主题是 `../vimix`（4K 彩色版），由 `grub-theme-sync.service` 同步进 `/boot`。

## 内容

| 目录 | 内容 | 数量 |
| --- | --- | --- |
| `icons/<variant>/<res>/` | 菜单图标 | 3 配色 × 3 分辨率 × 76 = 684 |
| `backgrounds/<res>/` | 背景（stylish / tela / vimix / whitesur） | 5 分辨率 × 4 = 20 |
| `config/` | `theme-*.txt` 布局 | 5 |
| `select/select-<res>/` | 选中框 `select_{c,e,w}.png` | 3 × 3 = 9 |
| `info/` | 信息框 `info-*.png` | 3 |
| `fonts/` | DejaVu / Terminus / Unifont `.pf2` | 13 |

- 配色：`color`（当前使用）、`white`、`whitesur`
- 分辨率：`1080p`、`2k`、`4k`（图标尺寸分别是 32/48/64）
- 背景分辨率：`1080p`、`2k`、`4k`、`ultrawide`、`ultrawide2k`

## 换配色或分辨率

主题目录是扁平的，GRUB 只认 `<theme>/icons/<class>.png`、`<theme>/background.jpg`、
`<theme>/theme.txt`。换一套就是替换这三个（外加 `select_*.png`、`info.png`、字体）：

```sh
# 例：换成 white 配色 + 2K 布局
sudo install -m 0644 /usr/share/grub/grub2-themes/config/theme-2k.txt \
    /boot/grub2/themes/vimix/theme.txt
sudo rm -rf /boot/grub2/themes/vimix/icons
sudo cp -a /usr/share/grub/grub2-themes/icons/white/2k \
    /boot/grub2/themes/vimix/icons
sudo install -m 0644 /usr/share/grub/grub2-themes/backgrounds/2k/background-vimix.jpg \
    /boot/grub2/themes/vimix/background.jpg
sudo cp -a /usr/share/grub/grub2-themes/select/select-2k/. /boot/grub2/themes/vimix/
```

> 注意：`grub-theme-sync.service` 在 `VERSION` 变化时会用镜像里的默认版本覆盖
> `/boot/grub2/themes/vimix`。要长期使用别的配色，改镜像里的 `../vimix`，或在
> 同步后重新覆盖一次。

图标 class 对应关系：`blscfg` 读 BLS 条目里的 `grub_class`（我们的脚本写
`fedora` / `gnu-linux` / `linux`，一行一个）；`os-prober` 取 `LABEL` 第一个单词
并小写（`Windows Boot Manager` → `windows`、`macOS` → `macos`、`Chrome OS` → `chrome`）。
