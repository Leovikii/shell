#!/bin/sh
set -eu
IFS='
\t'

PROG_NAME="frp.sh"
ARCH_WANTED="linux_amd64"
GITHUB_API="https://api.github.com/repos/fatedier/frp/releases/latest"
BIN_DEST="/usr/bin"
ETC_DIR="/etc/frp"
TMPDIR=""
DOWNLOADER=""
SYSTEM=""

C_RST='\033[0m'
C_HDR='\033[1;36m'
C_INFO='\033[1;34m'
C_WARN='\033[1;33m'
C_ERR='\033[1;31m'
C_PROMPT='\033[1;32m'

echoinfo(){ printf "%b[INFO] %s%b\n" "$C_INFO" "$*" "$C_RST"; }
echowarn(){ printf "%b[WARN] %s%b\n" "$C_WARN" "$*" "$C_RST"; }
echoerr(){ printf "%b[ERROR] %s%b\n" "$C_ERR" "$*" "$C_RST" 1>&2; }

cleanup(){
  if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then rm -rf "$TMPDIR" || true; fi
}
trap cleanup EXIT

detect_system(){
  if [ -f /etc/openwrt_release ] || ( [ -f /etc/os-release ] && grep -qi openwrt /etc/os-release 2>/dev/null ); then
    SYSTEM="openwrt"
  elif command -v systemctl >/dev/null 2>&1 && ( [ -f /etc/debian_version ] || { [ -f /etc/os-release ] && grep -qiE "debian|ubuntu" /etc/os-release 2>/dev/null || true; } ); then
    SYSTEM="debian"
  else
    if command -v opkg >/dev/null 2>&1; then
      SYSTEM="openwrt"
    elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
      SYSTEM="debian"
    else
      while :; do
        clear
        printf "%b请选择系统类型:%b\n" "$C_HDR" "$C_RST"
        printf "  1) debian/ubuntu (systemd)\n"
        printf "  2) openwrt\n"
        printf "  0) 退出\n\n"
        printf "请选择: "; read choice
        case "$choice" in
          1) SYSTEM="debian"; break;;
          2) SYSTEM="openwrt"; break;;
          0) exit 1;;
          *) echowarn "无效选择"; sleep 1;;
        esac
      done
    fi
  fi
  echoinfo "检测到系统: $SYSTEM"
}

check_tools(){
  if command -v curl >/dev/null 2>&1; then DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then DOWNLOADER="wget"
  else echoerr "未找到 curl 或 wget，请先安装。"; exit 1; fi

  if ! command -v tar >/dev/null 2>&1; then echoerr "未找到 tar，请先安装。"; exit 1; fi
}

arch_check(){
  arch=$(uname -m 2>/dev/null || echo unknown)
  echoinfo "检测到架构: $arch"
  if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
    echowarn "当前不是 x86_64，脚本将尝试下载 linux_amd64 版本，可能无法运行。"
    printf "继续吗？(yes/ no): "; read goon
    [ "$goon" = "yes" ] || ( echoinfo "已取消"; exit 1 )
  fi
}

get_latest_release_info(){
  echoinfo "获取 GitHub latest release..."
  if [ "$DOWNLOADER" = "curl" ]; then json=$(curl -fsSL "$GITHUB_API"); else json=$(wget -qO- "$GITHUB_API"); fi
  tag=$(echo "$json" | grep -Eo '"tag_name":[^,]+' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -n1 || true)
  LATEST_TAG=${tag:-}
  LATEST_VERSION=$(printf "%s" "$LATEST_TAG" | sed -E 's/^[vV]//')
  ASSET_URL=$(echo "$json" | grep -Eo '"browser_download_url":[^,]+' \
    | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
    | grep "$ARCH_WANTED" | grep -E "\.tar\.gz$" | head -n1 || true)
  echoinfo "release: ${LATEST_TAG:-unknown}, asset: ${ASSET_URL:-none}"
}

get_installed_version(){
  bin="$1"
  ver="unknown"
  if [ ! -x "$bin" ]; then
    printf "%s\n" "$ver"; return
  fi
  out=$("$bin" -v 2>&1 || true)
  [ -z "$out" ] && out=$("$bin" -V 2>&1 || true)
  [ -z "$out" ] && out=$("$bin" --version 2>&1 || true)
  vernum=$(printf "%s" "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  [ -n "$vernum" ] && ver="$vernum"
  printf "%s\n" "$ver"
}

ver_gt(){
  a="$1"; b="$2"
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" = "unknown" ] || [ "$b" = "unknown" ]; then return 1; fi
  IFS=.; set -- $a; a1=${1:-0}; a2=${2:-0}; a3=${3:-0}
  set -- $b; b1=${1:-0}; b2=${2:-0}; b3=${3:-0}
  IFS='
\t'
  if [ "$a1" -gt "$b1" ] 2>/dev/null; then return 0; fi
  if [ "$a1" -lt "$b1" ] 2>/dev/null; then return 1; fi
  if [ "$a2" -gt "$b2" ] 2>/dev/null; then return 0; fi
  if [ "$a2" -lt "$b2" ] 2>/dev/null; then return 1; fi
  if [ "$a3" -gt "$b3" ] 2>/dev/null; then return 0; fi
  return 1
}

download_and_extract(){
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR" || return 1
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
  extracted_dir=$(ls -1d extracted/* 2>/dev/null | head -n1 || true)
  [ -z "$extracted_dir" ] && { echoerr "解压后未找到目录"; return 1; }
  echoinfo "解压目录: $extracted_dir"
}

ensure_usrbin_writable(){
  if [ ! -d "$BIN_DEST" ]; then mkdir -p "$BIN_DEST" 2>/dev/null || true; fi
  tmpf="$BIN_DEST/.frp_write_test.$$"
  if printf x > "$tmpf" 2>/dev/null; then rm -f "$tmpf" 2>/dev/null || true; return 0; fi
  echoerr "无法写入 $BIN_DEST，请以 root/sudo 运行脚本并确保 $BIN_DEST 可写"
  return 1
}

install_from_extracted(){
  sel="$1"
  ensure_usrbin_writable || return 1

  frpc_src=$(find "$extracted_dir" -type f -name frpc 2>/dev/null | head -n1 || true)
  frps_src=$(find "$extracted_dir" -type f -name frps 2>/dev/null | head -n1 || true)

  if [ "$sel" = "frpc" ] || [ "$sel" = "all" ]; then
    if [ -n "$frpc_src" ]; then
      cp -f "$frpc_src" "$BIN_DEST/frpc" 2>/dev/null && chmod 0755 "$BIN_DEST/frpc" 2>/dev/null || { echoerr "写入 $BIN_DEST/frpc 失败"; return 1; }
      echoinfo "已写入 $BIN_DEST/frpc"
    else
      echowarn "未找到 frpc 二进制"
    fi
  fi

  if [ "$sel" = "frps" ] || [ "$sel" = "all" ]; then
    if [ -n "$frps_src" ]; then
      cp -f "$frps_src" "$BIN_DEST/frps" 2>/dev/null && chmod 0755 "$BIN_DEST/frps" 2>/dev/null || { echoerr "写入 $BIN_DEST/frps 失败"; return 1; }
      echoinfo "已写入 $BIN_DEST/frps"
    else
      echowarn "未找到 frps 二进制"
    fi
  fi

  if [ -d "$ETC_DIR" ]; then rm -rf "$ETC_DIR" || true; fi
  mkdir -p "$ETC_DIR" || { echoerr "无法创建 $ETC_DIR"; return 1; }

  frpc_toml_src=$(find "$extracted_dir" -type f -iname "frpc.toml" 2>/dev/null | head -n1 || true)
  frps_toml_src=$(find "$extracted_dir" -type f -iname "frps.toml" 2>/dev/null | head -n1 || true)

  if [ "$sel" = "frpc" ] || [ "$sel" = "all" ]; then
    if [ -n "$frpc_toml_src" ]; then
      cp -f "$frpc_toml_src" "$ETC_DIR/frpc.toml" && chmod 0644 "$ETC_DIR/frpc.toml" || true
      echoinfo "复制 frpc.toml -> $ETC_DIR/frpc.toml"
    else
      cat >"$ETC_DIR/frpc.toml" <<'EOF'
# frpc.toml 示例（占位）
# 请填写客户端配置
EOF
      chmod 0644 "$ETC_DIR/frpc.toml" || true
      echowarn "已创建占位 $ETC_DIR/frpc.toml"
    fi
  fi

  if [ "$sel" = "frps" ] || [ "$sel" = "all" ]; then
    if [ -n "$frps_toml_src" ]; then
      cp -f "$frps_toml_src" "$ETC_DIR/frps.toml" && chmod 0644 "$ETC_DIR/frps.toml" || true
      echoinfo "复制 frps.toml -> $ETC_DIR/frps.toml"
    else
      cat >"$ETC_DIR/frps.toml" <<'EOF'
# frps.toml 示例（占位）
# 请填写服务端配置
EOF
      chmod 0644 "$ETC_DIR/frps.toml" || true
      echowarn "已创建占位 $ETC_DIR/frps.toml"
    fi
  fi

  if [ "$SYSTEM" = "openwrt" ]; then
    echoinfo "OpenWrt 环境：不复制二进制到 $ETC_DIR。init 脚本将使用系统中的 frps/frpc 并读取 /etc/frp/*.toml"
  fi

  echoinfo "/etc/frp 已重建并包含所选配置文件"
}

create_systemd_unit_files(){
  echoinfo "创建 systemd unit（不自动启用）..."
  if [ -x "$BIN_DEST/frps" ]; then
    cat > /etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp Server (frps)
After=network.target

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
    cat > /etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=frp Client (frpc)
After=network.target

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
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
}

create_openwrt_init_scripts(){
  echoinfo "创建 OpenWrt init 脚本..."
  if command -v procd >/dev/null 2>&1 || [ -e /sbin/procd ]; then
    cat > /etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start() {
  config_load frp 2>/dev/null || true
  config_get_bool enabled main enabled 0
  [ "$enabled" -eq 1 ] || return 0
  config_get frps_conf main frps_conf /etc/frp/frps.toml
  config_get log_stderr main log_stderr /var/log/frps.log
  procd_open_instance
  procd_set_param command /bin/sh -c 'frps -c /etc/frp/frps.toml'
  procd_set_param stderr "$log_stderr"
  procd_set_param respawn
  procd_close_instance
}

stop() {
  procd_killall frps 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/frps || true
    echoinfo "/etc/init.d/frps (procd) 已生成"

    cat > /etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start() {
  config_load frp 2>/dev/null || true
  config_get_bool enabled client enabled 0
  [ "$enabled" -eq 1 ] || return 0
  config_get frpc_conf client frpc_conf /etc/frp/frpc.toml
  config_get log_stderr client log_stderr /var/log/frpc.log
  procd_open_instance
  procd_set_param command /bin/sh -c 'frpc -c /etc/frp/frpc.toml'
  procd_set_param stderr "$log_stderr"
  procd_set_param respawn
  procd_close_instance
}

stop() {
  procd_killall frpc 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/frpc || true
    echoinfo "/etc/init.d/frpc (procd) 已生成"
  else
    cat > /etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
  command -v frps >/dev/null 2>&1 || return 1
  [ -f /etc/frp/frps.toml ] || return 1
  sh -c 'frps -c /etc/frp/frps.toml 2>>/var/log/frps.log &' || true
}

stop() {
  pkill -f "frps -c /etc/frp/frps.toml" 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/frps || true
    echoinfo "/etc/init.d/frps (fallback) 已生成"

    cat > /etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
  command -v frpc >/dev/null 2>&1 || return 1
  [ -f /etc/frp/frpc.toml ] || return 1
  sh -c 'frpc -c /etc/frp/frpc.toml 2>>/var/log/frpc.log &' || true
}

stop() {
  pkill -f "frpc -c /etc/frp/frpc.toml" 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/frpc || true
    echoinfo "/etc/init.d/frpc (fallback) 已生成"
  fi
}

deploy_self(){
  if [ "$SYSTEM" = "openwrt" ]; then target="/usr/sbin/$PROG_NAME"; else target="/usr/local/bin/$PROG_NAME"; fi
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  if [ -f "$0" ]; then
    cp -f "$0" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null && echoinfo "脚本已复制到 $target" || echowarn "复制脚本到 $target 失败（可能无权限）"
  fi
}

install_flow(){
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

  echoinfo "本地版本: frps=$inst_frps_ver frpc=$inst_frpc_ver"
  echoinfo "远端 release: ${LATEST_TAG:-unknown}"

  should_prompt_update="no"
  if [ "$have_frps" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frps_ver"; then should_prompt_update="yes"; fi
  if [ "$have_frpc" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frpc_ver"; then should_prompt_update="yes"; fi

  if [ "$should_prompt_update" = "yes" ]; then
    printf "\n检测到可用更新：\n"
    [ "$have_frps" = "yes" ] && printf "  frps: %s -> %s\n" "$inst_frps_ver" "$LATEST_VERSION"
    [ "$have_frpc" = "yes" ] && printf "  frpc: %s -> %s\n" "$inst_frpc_ver" "$LATEST_VERSION"
    printf "\n是否仅更新二进制（不会更改 /etc/frp 下 toml）？(yes/[no]) "; read ans
    if [ "$ans" = "yes" ]; then
      [ -n "${ASSET_URL:-}" ] || { echoerr "未获取下载地址"; return 1; }
      download_and_extract || return 1
      sel="none"
      [ "$have_frpc" = "yes" ] && sel="frpc"
      [ "$have_frps" = "yes" ] && sel="frps"
      if [ "$have_frpc" = "yes" ] && [ "$have_frps" = "yes" ]; then sel="all"; fi
      install_from_extracted "$sel" || return 1
      echoinfo "二进制更新完成。"
      deploy_self
      return 0
    fi
  fi

  if [ "$have_frps" = "no" ] || [ "$have_frpc" = "no" ]; then
    printf "\n请选择安装目标：\n"
    printf "  1) 安装 frps（服务端）\n"
    printf "  2) 安装 frpc（客户端）\n"
    printf "  3) 全部（frps + frpc）\n"
    printf "  0) 取消\n"
    printf "请选择: "; read choice
    case "$choice" in
      1) INSTALL_TARGET="frps" ;;
      2) INSTALL_TARGET="frpc" ;;
      3) INSTALL_TARGET="all" ;;
      0) echoinfo "已取消安装"; return 0 ;;
      *) echowarn "无效选择"; return 0 ;;
    esac

    [ -n "${ASSET_URL:-}" ] || { echoerr "未获取下载地址"; return 1; }
    download_and_extract || return 1
    install_from_extracted "$INSTALL_TARGET" || return 1

    if [ "$SYSTEM" = "debian" ]; then create_systemd_unit_files; else create_openwrt_init_scripts; fi
    deploy_self
    echoinfo "安装完成。请编辑 /etc/frp/*.toml 后启用/启动服务。"
    return 0
  fi

  echoinfo "本地 frps/frpc 可能为最新或无法判断，跳过下载/安装。"
  echowarn "如需强制重装请先卸载再安装。"
  return 0
}

service_manage(){
  name="$1"
  while :; do
    clear
    printf "%b+----------------------------------------------+%b\n" "$C_HDR" "$C_RST"
    printf "%b|   FRP 服务管理： %s\n" "$C_PROMPT" "$name"
    printf "%b+----------------------------------------------+%b\n\n" "$C_HDR" "$C_RST"

    printf "  %-4s %-14s  %-4s %-14s\n" "1)" "启动"   "2)" "停止"
    printf "  %-4s %-14s  %-4s %-14s\n" "3)" "重启"   "4)" "状态"
    printf "  %-4s %-14s  %-4s %-14s\n\n" "5)" "查看日志" "0)" "返回"

    printf "请选择: "; read op
    case "$op" in
      1) if [ "$SYSTEM" = "debian" ]; then systemctl start "${name}.service" || echowarn "启动可能失败"; else /etc/init.d/"$name" start || echowarn "启动可能失败"; fi ;;
      2) if [ "$SYSTEM" = "debian" ]; then systemctl stop "${name}.service" || true; else /etc/init.d/"$name" stop || true; fi ;;
      3) if [ "$SYSTEM" = "debian" ]; then systemctl restart "${name}.service" || echowarn "重启失败"; else /etc/init.d/"$name" restart || echowarn "重启失败"; fi ;;
      4) if [ "$SYSTEM" = "debian" ]; then systemctl status "${name}.service" --no-pager || true; else ps aux | grep "$name" | grep -v grep || echo "未检测到进程"; fi; printf "\n按回车返回..."; read dum || true ;;
      5) if [ "$SYSTEM" = "debian" ]; then journalctl -u "${name}.service" -n 200 --no-pager || true; else logread | tail -n 200 || true; fi; printf "\n按回车返回..."; read dum || true ;;
      0) break ;;
      *) echowarn "无效输入"; sleep 1 ;;
    esac
  done
}

manage_menu(){
  while :; do
    clear
    printf "%b+----------------------------------------------+%b\n" "$C_HDR" "$C_RST"
    printf "%b|   FRP 管理菜单\n" "$C_PROMPT"
    printf "%b+----------------------------------------------+%b\n\n" "$C_HDR" "$C_RST"

    printf "  %-4s %-22s  %-4s %-22s\n" "1)" "管理 frps (服务端)" "2)" "管理 frpc (客户端)"
    printf "\n  %-4s %-22s\n\n" "0)" "返回主菜单"

    printf "请选择: "; read sel
    case "$sel" in
      1) service_manage "frps" ;;
      2) service_manage "frpc" ;;
      0) break ;;
      *) echowarn "无效输入"; sleep 1 ;;
    esac
  done
}

uninstall_all(){
  clear
  printf "%b警告：此操作将删除 frp 二进制、/etc/frp、服务文件与脚本！%b\n\n" "$C_WARN" "$C_RST"
  printf "确认卸载并删除所有 frp 文件？（输入 yes 确认）: "; read confirm
  [ "$confirm" = "yes" ] || { echoinfo "已取消卸载"; return 0; }

  detect_system || true
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

  echoinfo "卸载完成。"
  printf "\n按回车返回..."; read dum || true
}

main_menu(){
  while :; do
    clear
    printf "%b==============================================%b\n" "$C_HDR" "$C_RST"
    printf "%b  frp 安装 / 管理 / 卸载  %b\n" "$C_PROMPT" "$C_RST"
    printf "%b==============================================%b\n\n" "$C_HDR" "$C_RST"

    printf "  %-4s %-36s  %-4s %-36s\n" "1)" "安装 / 升级 frp (选择 客户端/服务端/全部)" "2)" "管理 frp (启动/停止/重启/日志)"
    printf "\n  %-4s %-36s\n\n" "3)" "卸载 frp"
    printf "  %-4s %-36s\n\n" "0)" "退出"

    printf "请选择: "; read opt
    case "$opt" in
      1) install_flow; printf "\n按回车返回主菜单..."; read dum || true ;;
      2) [ -z "${SYSTEM:-}" ] && detect_system; manage_menu ;;
      3) [ -z "${SYSTEM:-}" ] && detect_system; uninstall_all ;;
      0) echoinfo "退出"; exit 0 ;;
      *) echowarn "无效选择"; sleep 1 ;;
    esac
  done
}

if [ "$(basename "$0")" = "$PROG_NAME" ] || [ "${0##*/}" = "$PROG_NAME" ]; then
  main_menu
fi
