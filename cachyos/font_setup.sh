#!/bin/bash

install_fonts() {
    local helper=""
    if command -v paru >/dev/null 2>&1; then
        helper="paru"
    elif command -v yay >/dev/null 2>&1; then
        helper="yay"
    else
        echo -e "\033[1;31m未找到 paru 或 yay，请先安装其中之一。\033[0m"
        return 1
    fi
    $helper -S --needed ttf-sarasa-gothic
    echo -e "\033[1;32m字体安装尝试完成。建议立即选择 [2] 应用优化配置。\033[0m"
}

apply_config() {
    echo -e "\033[1;34m正在检测字体安装情况...\033[0m"
    local missing=0
    fc-list :family | grep -qi "Sarasa UI SC" || missing=1
    fc-list :family | grep -qi "Noto Serif CJK SC" || missing=1
    
    if [ $missing -eq 1 ]; then
        echo -e "\033[1;31m错误：未检测到更纱黑体或思源宋体。请确保系统已包含 Noto CJK 并执行 [1] 安装更纱黑体。\033[0m"
        return 1
    fi

    mkdir -p "$HOME/.config/fontconfig"
    cat << 'EOF' > "$HOME/.config/fontconfig/fonts.conf"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>

  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
  </match>
  <match target="font">
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
  </match>
  <match target="font">
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
  </match>
  <match target="font">
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
  <match target="font">
    <edit name="autohint" mode="assign"><bool>false</bool></edit>
  </match>
  <match target="font">
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>
  <match target="font">
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>

  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Sarasa UI SC</family>
      <family>Sarasa UI TC</family>
      <family>Sarasa UI J</family>
      <family>Sarasa UI K</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif CJK SC</family>
      <family>Noto Serif CJK TC</family>
      <family>Noto Serif CJK JP</family>
      <family>Noto Serif CJK KR</family>
    </prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>Sarasa Term SC</family>
    </prefer>
  </alias>

  <match target="pattern">
    <test name="lang"><string>zh-tw</string></test>
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Sarasa UI TC</string></edit>
  </match>
  <match target="pattern">
    <test name="lang"><string>zh-hk</string></test>
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Sarasa UI TC</string></edit>
  </match>
  <match target="pattern">
    <test name="lang"><string>ja</string></test>
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Sarasa UI J</string></edit>
  </match>
  <match target="pattern">
    <test name="lang"><string>ko</string></test>
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Sarasa UI K</string></edit>
  </match>

  <match target="pattern"><test name="family"><string>Arial</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>
  <match target="pattern"><test name="family"><string>Helvetica</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>
  <match target="pattern"><test name="family" compare="contains"><string>Microsoft YaHei</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>
  <match target="pattern"><test name="family"><string>微软雅黑</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>
  <match target="pattern"><test name="family"><string>SimHei</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>
  <match target="pattern"><test name="family"><string>黑体</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>
  <match target="pattern"><test name="family"><string>PingFang SC</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa UI SC</string></edit></match>

  <match target="pattern"><test name="family"><string>Times New Roman</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family" compare="contains"><string>SimSun</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>宋体</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>FangSong</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>
  <match target="pattern"><test name="family"><string>仿宋</string></test><edit name="family" mode="assign" binding="strong"><string>Noto Serif CJK SC</string></edit></match>

  <match target="pattern"><test name="family"><string>Courier New</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa Term SC</string></edit></match>
  <match target="pattern"><test name="family"><string>Consolas</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa Term SC</string></edit></match>
  <match target="pattern"><test name="family"><string>Source Code Pro</string></test><edit name="family" mode="assign" binding="strong"><string>Sarasa Term SC</string></edit></match>

</fontconfig>
EOF

    local f_reg="Sarasa UI SC,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    local f_mono="Sarasa Term SC,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    local f_small="Sarasa UI SC,8,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"

    kwriteconfig6 --file kdeglobals --group General --key font "$f_reg"
    kwriteconfig6 --file kdeglobals --group General --key fixed "$f_mono"
    kwriteconfig6 --file kdeglobals --group General --key menuFont "$f_reg"
    kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "$f_small"
    kwriteconfig6 --file kdeglobals --group General --key toolBarFont "$f_reg"
    kwriteconfig6 --file kdeglobals --group WM --key activeFont "$f_reg"
    kwriteconfig6 --file kdeglobals --group WM --key inactiveFont "$f_reg"
    
    kwriteconfig6 --file kdeglobals --group General --key Xft-Antialias true
    kwriteconfig6 --file kdeglobals --group General --key Xft-HintStyle hintslight
    kwriteconfig6 --file kdeglobals --group General --key Xft-RGBA rgb
    kwriteconfig6 --file kdeglobals --group General --key Xft-SubPixel rgb
    kwriteconfig6 --file kdeglobals --group General --key XftAntialias true
    kwriteconfig6 --file kdeglobals --group General --key XftHintStyle hintslight
    kwriteconfig6 --file kdeglobals --group General --key XftSubPixel rgb

    fc-cache -fv
    echo -e "\033[1;32m配置已成功应用并同步至 KDE 设置。\033[0m"
    echo -e "\033[1;33m请注销并重新登录以确保全局生效。\033[0m"
}

while true; do
    clear
    echo -e "\033[1;36m=========================================\033[0m"
    echo -e "\033[1;32m         Font Optimizer v0.0.6           \033[0m"
    echo -e "\033[1;36m=========================================\033[0m"
    echo -e " \033[1;33m[1]\033[0m 安装字体 (仅 Sarasa Gothic)       "
    echo -e " \033[1;33m[2]\033[0m 应用 Fontconfig & KDE 优化配置      "
    echo -e " \033[1;33m[0]\033[0m 退出脚本                           "
    echo -e "\033[1;36m=========================================\033[0m"
    read -p " 请选择操作 [0-2]: " option

    case $option in
        1)
            install_fonts
            read -p "按回车键返回主菜单..."
            ;;
        2)
            apply_config
            read -p "按回车键返回主菜单..."
            ;;
        0)
            echo "退出中..."
            exit 0
            ;;
        *)
            echo -e "\033[1;31m 无效选项。\033[0m"
            sleep 1
            ;;
    esac
done