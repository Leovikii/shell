#!/bin/sh
# frp.sh - Debian & OpenWrt 兼容安装/升级/管理/卸载脚本
# 要点：
#  - 直接复制解压出的 frps/frpc 到 /usr/bin 并 chmod 0755（不使用 install）
#  - 完整安装时重建 /etc/frp（最终仅含 frpc.toml 与 frps.toml）
#  - 升级仅替换二进制，不触及 /etc/frp
#  - 兼容 BusyBox (OpenWrt) 与 Debian sh/bash
set -eu
IFS='
	'

PROG_NAME="frp.sh"
ARCH_WANTED="linux_amd64"
GITHUB_API="https://api.github.com/repos/fatedier/frp/releases/latest"
BIN_DEST="/usr/bin"
ETC_DIR="/etc/frp"
SYSTEM=""
DOWNLOADER=""
TMPDIR=""

# 彩色输出（在某些环境上可能无效，但不影响功能）
C_RST='\033[0m'
C_INFO='\033[1;34m'
C_WARN='\033[1;33m'
C_ERR='\033[1;31m'
C_PROMPT='\033[1;32m'

echoinfo() { printf "%s[INFO] %s%s\n" "$C_INFO" "$*" "$C_RST"; }
echowarn() { printf "%s[WARN] %s%s\n" "$C_WARN" "$*" "$C_RST"; }
echoerr() { printf "%s[ERROR] %s%s\n" "$C_ERR" "$*" "$C_RST" 1>&2; }

cleanup() {
  if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then rm -rf "$TMPDIR" || true; fi
}
trap cleanup EXIT

# 检测系统
detect_system() {
  if [ -f /etc/openwrt_release ] || ( [ -f /etc/os-release ] && grep -qi openwrt /etc/os-release 2>/dev/null ); then
    SYSTEM="openwrt"
  elif command -v systemctl >/dev/null 2>&1 && ( [ -f /etc/debian_version ] || ( [ -f /etc/os-release ] && (grep -qiE "debian|ubuntu" /etc/os-release 2>/dev/null || true) ) ); then
    SYSTEM="debian"
  else
    if command -v opkg >/dev/null 2>&1; then
      SYSTEM="openwrt"
    elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
      SYSTEM="debian"
    else
      while :; do
        clear
        echo "无法自动识别系统，请选择："
        echo "  1) debian/ubuntu (systemd)"
        echo "  2) openwrt"
        echo "  0) 退出"
        printf "\n请选择: "
        read choice
        case "$choice" in
          1) SYSTEM="debian"; break ;;
          2) SYSTEM="openwrt"; break ;;
          0) exit 1 ;;
          *) echowarn "无效选择"; sleep 1 ;;
        esac
      done
    fi
  fi
  echoinfo "检测到系统: $SYSTEM"
}

# 检查工具
check_tools() {
  if command -v curl >/dev/null 2>&1; then DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then DOWNLOADER="wget"
  else echoerr "未找到 curl 或 wget，请先安装。"; exit 1; fi

  if ! command -v tar >/dev/null 2>&1; then
    echoerr "未找到 tar，请先安装。"
    exit 1
  fi
}

arch_check() {
  arch=$(uname -m 2>/dev/null || echo unknown)
  echoinfo "检测到架构: $arch"
  if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
    echowarn "当前不是 x86_64，脚本将下载 linux_amd64 版本，可能无法运行。"
    printf "\n继续吗？(yes/ no): "; read goon
    [ "$goon" = "yes" ] || ( echoinfo "已取消"; exit 1 )
  fi
}

# 获取 latest release info（tag 和 asset url）
get_latest_release_info() {
  echoinfo "查询 GitHub latest release..."
  if [ "$DOWNLOADER" = "curl" ]; then
    json=$(curl -fsSL "$GITHUB_API")
  else
    json=$(wget -qO- "$GITHUB_API")
  fi

  tag=$(echo "$json" | grep -Eo '"tag_name":[^,]+' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -n 1 || true)
  if [ -n "${tag:-}" ]; then
    LATEST_TAG="$tag"
    LATEST_VERSION=$(echo "$tag" | sed -E 's/^[vV]//')
  else
    LATEST_TAG=""
    LATEST_VERSION=""
  fi

  ASSET_URL=$(echo "$json" | grep -Eo '"browser_download_url":[^,]+' \
    | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
    | grep "$ARCH_WANTED" | grep -E "\.tar\.gz$" | head -n 1 || true)

  echoinfo "Latest release: ${LATEST_TAG:-unknown}, asset: ${ASSET_URL:-none}"
}

# 获取已安装版本（从 frps/frpc 输出中提取第一个 x.y.z）
get_installed_version() {
  bin="$1"
  ver="unknown"
  if [ ! -x "$bin" ]; then
    echo "$ver"
    return
  fi
  out=$("$bin" -v 2>&1 || true)
  [ -z "$out" ] && out=$("$bin" -V 2>&1 || true)
  [ -z "$out" ] && out=$("$bin" --version 2>&1 || true)
  vernum=$(echo "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
  [ -n "$vernum" ] && ver="$vernum"
  echo "$ver"
}

# a > b ? 返回 0 : 返回 1 （纯 shell 实现）
ver_gt() {
  a="$1"; b="$2"
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" = "unknown" ] || [ "$b" = "unknown" ]; then
    return 1
  fi

  # 保存 IFS 并解析
  oldIFS=$IFS
  IFS=.
  set -- $a; a1=${1:-0}; a2=${2:-0}; a3=${3:-0}
  set -- $b; b1=${1:-0}; b2=${2:-0}; b3=${3:-0}
  IFS=$oldIFS

  # 比较
  if [ "$a1" -gt "$b1" ] 2>/dev/null; then return 0; fi
  if [ "$a1" -lt "$b1" ] 2>/dev/null; then return 1; fi
  if [ "$a2" -gt "$b2" ] 2>/dev/null; then return 0; fi
  if [ "$a2" -lt "$b2" ] 2>/dev/null; then return 1; fi
  if [ "$a3" -gt "$b3" ] 2>/dev/null; then return 0; fi
  return 1
}

# 下载并解压（兼容 BusyBox）
download_and_extract() {
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR" || exit 1
  archive="${ASSET_URL##*/}"
  echoinfo "下载 $archive ..."
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -L -o "$archive" "$ASSET_URL"
  else
    wget -q -O "$archive" "$ASSET_URL"
  fi

  echoinfo "解压..."
  mkdir -p extracted
  tar -xzf "$archive" -C extracted
  extracted_dir=$(ls -1d extracted/* 2>/dev/null | head -n 1 || true)
  if [ -z "$extracted_dir" ]; then
    echoerr "解压后未找到目录，可能解压失败"
    return 1
  fi
  echoinfo "解压目录: $extracted_dir"
}

# 确认 /usr/bin 可写
ensure_usrbin_writable() {
  if [ ! -d "$BIN_DEST" ]; then
    mkdir -p "$BIN_DEST" 2>/dev/null || true
  fi
  tmpf="$BIN_DEST/.frp_write_test.$$"
  if printf x > "$tmpf" 2>/dev/null; then
    rm -f "$tmpf" 2>/dev/null || true
    return 0
  fi
  echoerr "无法写入 $BIN_DEST，请以 root/sudo 运行脚本并确保 $BIN_DEST 可写"
  return 1
}

# 直接把解压出的 frpc/frps 移动到 /usr/bin 并 chmod（不使用 install）
write_bins_to_usrbin() {
  # 使用 find 的兼容写法
  frpc_src=$(find "$extracted_dir" -type f -name frpc 2>/dev/null | head -n 1 || true)
  frps_src=$(find "$extracted_dir" -type f -name frps 2>/dev/null | head -n 1 || true)

  if [ -n "$frpc_src" ]; then
    if cp -f "$frpc_src" "$BIN_DEST/frpc" 2>/dev/null; then
      chmod 0755 "$BIN_DEST/frpc" 2>/dev/null || true
      echoinfo "已写入 $BIN_DEST/frpc"
    else
      echoerr "写入 $BIN_DEST/frpc 失败（权限问题）"; return 1
    fi
  else
    echowarn "release 包中未找到 frpc"
  fi

  if [ -n "$frps_src" ]; then
    if cp -f "$frps_src" "$BIN_DEST/frps" 2>/dev/null; then
      chmod 0755 "$BIN_DEST/frps" 2>/dev/null || true
      echoinfo "已写入 $BIN_DEST/frps"
    else
      echoerr "写入 $BIN_DEST/frps 失败（权限问题）"; return 1
    fi
  else
    echowarn "release 包中未找到 frps"
  fi
  return 0
}

install_bins_only_from_extracted() {
  ensure_usrbin_writable || return 1
  write_bins_to_usrbin || return 1
}

# 完整安装：重建 /etc/frp（不备份），并确保目录最终只含两个 toml
install_full_flow_from_extracted() {
  ensure_usrbin_writable || return 1
  write_bins_to_usrbin || return 1

  # 重建 /etc/frp（不备份）
  if [ -d "$ETC_DIR" ]; then rm -rf "$ETC_DIR" || true; fi
  mkdir -p "$ETC_DIR" || { echoerr "无法创建 $ETC_DIR"; return 1; }

  frpc_toml_src=$(find "$extracted_dir" -type f -iname "frpc.toml" 2>/dev/null | head -n 1 || true)
  frps_toml_src=$(find "$extracted_dir" -type f -iname "frps.toml" 2>/dev/null | head -n 1 || true)

  if [ -n "$frpc_toml_src" ]; then
    cp -f "$frpc_toml_src" "$ETC_DIR/frpc.toml"
    chmod 0644 "$ETC_DIR/frpc.toml" || true
    echoinfo "复制示例 frpc.toml -> $ETC_DIR/frpc.toml"
  else
    cat >"$ETC_DIR/frpc.toml" <<'EOF'
# frpc.toml (占位)
# 请根据需要填写客户端配置
# [common]
# server_addr = "1.2.3.4"
# server_port = 7000
EOF
    chmod 0644 "$ETC_DIR/frpc.toml" || true
    echowarn "未找到示例 frpc.toml，已创建占位 $ETC_DIR/frpc.toml"
  fi

  if [ -n "$frps_toml_src" ]; then
    cp -f "$frps_toml_src" "$ETC_DIR/frps.toml"
    chmod 0644 "$ETC_DIR/frps.toml" || true
    echoinfo "复制示例 frps.toml -> $ETC_DIR/frps.toml"
  else
    cat >"$ETC_DIR/frps.toml" <<'EOF'
# frps.toml (占位)
# 请根据需要填写服务端配置
# [common]
# bind_port = 7000
EOF
    chmod 0644 "$ETC_DIR/frps.toml" || true
    echowarn "未找到示例 frps.toml，已创建占位 $ETC_DIR/frps.toml"
  fi

  # 删除 /etc/frp 下的其余文件（确保只剩两个 toml）
  for f in "$ETC_DIR"/*; do
    [ -e "$f" ] || continue
    bn=$(basename "$f")
    if [ "$bn" != "frpc.toml" ] && [ "$bn" != "frps.toml" ]; then
      rm -rf "$f" || true
    fi
  done
  echoinfo "/etc/frp 已重建并仅包含 frpc.toml 与 frps.toml"
}

# systemd / openwrt init scripts (不自动启用/启动)
create_systemd_unit_files() {
  echoinfo "生成 systemd unit（不启用/不启动）..."
  if [ -x "$BIN_DEST/frps" ]; then
    cat >/etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp Server (frps)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    echoinfo "/etc/systemd/system/frps.service 已生成"
  fi

  if [ -x "$BIN_DEST/frpc" ]; then
    cat >/etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=frp Client (frpc)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    echoinfo "/etc/systemd/system/frpc.service 已生成"
  fi
  echowarn "systemd unit 已创建，但未启用/未启动，请在编辑好 toml 后手动启用/启动"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
}

create_openwrt_init_scripts() {
  echoinfo "生成 OpenWrt /etc/init.d 脚本（不 enable/start）..."
  if [ -x "$BIN_DEST/frps" ]; then
    cat >/etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
# frps for OpenWrt
START=99
STOP=10
PROG=/usr/bin/frps
CONF=/etc/frp/frps.toml
start() {
  [ -x "$PROG" ] || return 1
  start-stop-daemon -S -b -x "$PROG" -- -c "$CONF"
}
stop() {
  start-stop-daemon -K -x "$PROG"
}
EOF
    chmod +x /etc/init.d/frps || true
    echoinfo "/etc/init.d/frps 已生成"
  fi

  if [ -x "$BIN_DEST/frpc" ]; then
    cat >/etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
# frpc for OpenWrt
START=99
STOP=10
PROG=/usr/bin/frpc
CONF=/etc/frp/frpc.toml
start() {
  [ -x "$PROG" ] || return 1
  start-stop-daemon -S -b -x "$PROG" -- -c "$CONF"
}
stop() {
  start-stop-daemon -K -x "$PROG"
}
EOF
    chmod +x /etc/init.d/frpc || true
    echoinfo "/etc/init.d/frpc 已生成"
  fi
  echowarn "init 脚本已生成，但未 enable/start，请在编辑好配置后手动启用 && 启动"
}

deploy_self() {
  if [ "$SYSTEM" = "openwrt" ]; then
    target="/usr/sbin/$PROG_NAME"
  else
    target="/usr/local/bin/$PROG_NAME"
  fi
  echoinfo "尝试把脚本复制到 $target ..."
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  if [ -f "$0" ]; then
    if cp -f "$0" "$target" 2>/dev/null; then
      chmod +x "$target" 2>/dev/null || true
      echoinfo "脚本已复制到 $target"
    else
      echowarn "复制脚本到 $target 失败（权限），你可以手动复制并 chmod +x"
    fi
  fi
}

# 安装/升级 主流程（版本检测/提示逻辑）
install_flow() {
  clear
  detect_system
  check_tools
  arch_check
  get_latest_release_info

  have_frps="no"; have_frpc="no"
  [ -x "$BIN_DEST/frps" ] && have_frps="yes"
  [ -x "$BIN_DEST/frpc" ] && have_frpc="yes"

  inst_frps_ver="unknown"; inst_frpc_ver="unknown"
  if [ "$have_frps" = "yes" ]; then inst_frps_ver=$(get_installed_version "$BIN_DEST/frps"); fi
  if [ "$have_frpc" = "yes" ]; then inst_frpc_ver=$(get_installed_version "$BIN_DEST/frpc"); fi

  echoinfo "本地版本 frps=$inst_frps_ver frpc=$inst_frpc_ver"
  echoinfo "最新 release: ${LATEST_TAG:-unknown} -> ${LATEST_VERSION:-unknown}"

  should_prompt_update="no"
  if [ "$have_frps" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frps_ver"; then should_prompt_update="yes"; fi
  if [ "$have_frpc" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frpc_ver"; then should_prompt_update="yes"; fi

  if [ "$should_prompt_update" = "yes" ]; then
    echo
    echo "检测到可用更新："
    [ "$have_frps" = "yes" ] && echo "  frps: $inst_frps_ver -> $LATEST_VERSION"
    [ "$have_frpc" = "yes" ] && echo "  frpc: $inst_frpc_ver -> $LATEST_VERSION"
    printf "\n是否仅更新二进制（不会更改 /etc/frp 下 toml）？(yes/[no]) "
    read ans
    if [ "$ans" = "yes" ]; then
      [ -n "${ASSET_URL:-}" ] || { echoerr "未获取到下载地址"; return 1; }
      download_and_extract || return 1
      install_bins_only_from_extracted || return 1
      echoinfo "二进制更新完成。请根据需要重启服务"
      deploy_self
      return 0
    fi
  fi

  if [ "$have_frps" = "no" ] || [ "$have_frpc" = "no" ]; then
    echo
    echo "检测到缺少 frps 或 frpc，将进行完整安装（会重建 /etc/frp，仅保留 frpc.toml 与 frps.toml）"
    printf "\n继续吗？(yes/[no]) "
    read cont
    [ "$cont" = "yes" ] || { echoinfo "已取消安装"; return 0; }
    [ -n "${ASSET_URL:-}" ] || { echoerr "未获取下载地址"; return 1; }
    download_and_extract || return 1
    install_full_flow_from_extracted || return 1
    if [ "$SYSTEM" = "debian" ]; then create_systemd_unit_files; else create_openwrt_init_scripts; fi
    deploy_self
    echoinfo "完整安装完成。请编辑 /etc/frp/*.toml 后手动启用并启动服务。"
    return 0
  fi

  echoinfo "本地 frps/frpc 版本与最新相同或无法判断，跳过下载/安装。"
  echowarn "如需强制重装请先卸载后重新安装。"
  return 0
}

# 服务管理、卸载、菜单（简洁实现）
service_manage() {
  name="$1"
  while :; do
    clear
    printf "%s FRP 管理: %s %s\n" "$C_PROMPT" "$name" "$C_RST"
    echo "1) 启动  2) 停止  3) 重启  4) 状态  5) 日志  0) 返回"
    printf "\n请选择: "
    read op
    case "$op" in
      1)
        if [ "$SYSTEM" = "debian" ]; then systemctl start "${name}.service" || echowarn "启动可能失败"; else /etc/init.d/"$name" start || echowarn "启动可能失败"; fi
        ;;
      2)
        if [ "$SYSTEM" = "debian" ]; then systemctl stop "${name}.service" || true; else /etc/init.d/"$name" stop || true; fi
        ;;
      3)
        if [ "$SYSTEM" = "debian" ]; then systemctl restart "${name}.service" || echowarn "重启失败"; else /etc/init.d/"$name" restart || echowarn "重启失败"; fi
        ;;
      4)
        if [ "$SYSTEM" = "debian" ]; then systemctl status "${name}.service" --no-pager || true; else ps aux | grep "$name" | grep -v grep || echo "未检测到进程"; fi
        printf "\n按回车返回..."; read dum || true
        ;;
      5)
        if [ "$SYSTEM" = "debian" ]; then journalctl -u "${name}.service" -n 200 --no-pager || true; else logread | tail -n 200 || true; fi
        printf "\n按回车返回..."; read dum || true
        ;;
      0) break ;;
      *) echowarn "无效输入"; sleep 1 ;;
    esac
  done
}

manage_menu() {
  while :; do
    clear
    echo "1) 管理 frps  2) 管理 frpc  0) 返回"
    printf "\n请选择: "
    read sel
    case "$sel" in
      1) service_manage "frps" ;;
      2) service_manage "frpc" ;;
      0) break ;;
      *) echowarn "无效输入"; sleep 1 ;;
    esac
  done
}

uninstall_all() {
  clear
  echo "警告：将删除 frp 二进制、/etc/frp、服务文件与本脚本（若已部署）！"
  printf "\n确认卸载并删除所有 frp 文件？（输入 yes 确认）: "
  read confirm
  [ "$confirm" = "yes" ] || { echoinfo "已取消卸载"; return 0; }

  if [ "$SYSTEM" = "debian" ]; then
    systemctl stop frps.service 2>/dev/null || true
    systemctl stop frpc.service 2>/dev/null || true
    systemctl disable frps.service 2>/dev/null || true
    systemctl disable frpc.service 2>/dev/null || true
    rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
    systemctl daemon-reload || true
  else
    /etc/init.d/frps stop 2>/dev/null || true
    /etc/init.d/frpc stop 2>/dev/null || true
    /etc/init.d/frps disable 2>/dev/null || true
    /etc/init.d/frpc disable 2>/dev/null || true
    rm -f /etc/init.d/frps /etc/init.d/frpc
  fi

  rm -f "$BIN_DEST/frps" "$BIN_DEST/frpc" || true
  rm -rf "$ETC_DIR" || true
  rm -f /var/log/frps.log /var/log/frpc.log /var/log/frp.log || true

  if [ "$SYSTEM" = "openwrt" ]; then target="/usr/sbin/$PROG_NAME"; else target="/usr/local/bin/$PROG_NAME"; fi
  rm -f "$target" || true
  rm -f /root/"$PROG_NAME" || true

  echoinfo "卸载完成。"
  printf "\n按回车返回..."; read dum || true
}

main_menu() {
  while :; do
    clear
    printf "%s frp 安装/管理/卸载 脚本 %s\n" "$C_PROMPT" "$C_RST"
    echo "----------------------------------------"
    echo "1) 安装 / 升级 frp"
    echo "2) 管理 frp"
    echo "3) 卸载 frp"
    echo "0) 退出"
    printf "\n请选择: "
    read opt
    case "$opt" in
      1) install_flow; printf "\n按回车返回主菜单..."; read dum || true ;;
      2) [ -z "${SYSTEM:-}" ] && detect_system; manage_menu ;;
      3) [ -z "${SYSTEM:-}" ] && detect_system; uninstall_all ;;
      0) echoinfo "退出"; exit 0 ;;
      *) echowarn "无效选择"; sleep 1 ;;
    esac
  done
}

# 入口
if [ "$(basename "$0")" = "$PROG_NAME" ] || [ "${0##*/}" = "$PROG_NAME" ]; then
  main_menu
fi
