#!/bin/sh
set -eu
IFS='\n\t'

PROG_NAME="frp.sh"
BIN_DEST="/usr/bin"
ETC_DIR="/etc/frp"
GITHUB_API="https://api.github.com/repos/fatedier/frp/releases/latest"
ARCH_WANTED="linux_amd64"

C_RST='\033[0m'
C_INFO='\033[1;34m'
C_WARN='\033[1;33m'
C_ERR='\033[1;31m'
C_PROMPT='\033[1;32m'

echoinfo(){ printf "%b[INFO] %s%b\n" "$C_INFO" "$*" "$C_RST"; }
echowarn(){ printf "%b[WARN] %s%b\n" "$C_WARN" "$*" "$C_RST"; }
echoerr(){ printf "%b[ERROR] %s%b\n" "$C_ERR" "$*" "$C_RST" 1>&2; }

cleanup(){ [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR" || true; }
trap cleanup EXIT

detect_system(){
  if [ -f /etc/openwrt_release ] || ( [ -f /etc/os-release ] && grep -qi openwrt /etc/os-release 2>/dev/null ); then
    SYSTEM="openwrt"
  elif command -v systemctl >/dev/null 2>&1 && ( [ -f /etc/debian_version ] || ( [ -f /etc/os-release ] && grep -qiE "debian|ubuntu" /etc/os-release 2>/dev/null ) ); then
    SYSTEM="debian"
  else
    if command -v opkg >/dev/null 2>&1; then SYSTEM="openwrt"; elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then SYSTEM="debian"; else
      while :; do
        clear
        printf "%b请选择系统类型:%b\n" "$C_INFO" "$C_RST"
        printf "  1) debian/ubuntu (systemd)\n  2) openwrt\n  0) 退出\n\n"
        printf "请选择: "; read choice
        case "$choice" in 1) SYSTEM="debian"; break;; 2) SYSTEM="openwrt"; break;; 0) exit 1;; *) echowarn "无效选择"; sleep 1;; esac
      done
    fi
  fi
  echoinfo "检测到系统: $SYSTEM"
}

check_tools(){
  if command -v curl >/dev/null 2>&1; then DOWNLOADER=curl
  elif command -v wget >/dev/null 2>&1; then DOWNLOADER=wget
  else echoerr "未找到 curl 或 wget"; exit 1; fi
  command -v tar >/dev/null 2>&1 || { echoerr "未找到 tar"; exit 1; }
}

arch_check(){
  arch=$(uname -m 2>/dev/null || echo unknown)
  echoinfo "架构: $arch"
}

get_latest_release_info(){
  if [ "$DOWNLOADER" = "curl" ]; then json=$(curl -fsSL "$GITHUB_API"); else json=$(wget -qO- "$GITHUB_API"); fi
  LATEST_TAG=$(printf "%s" "$json" | grep -Eo '"tag_name":[^,]+' | sed -E 's/.*"tag_name": *"([^\"]+)".*/\1/' | head -n1 || true)
  LATEST_VERSION=$(printf "%s" "$LATEST_TAG" | sed -E 's/^[vV]//')
  ASSET_URL=$(printf "%s" "$json" | grep -Eo '"browser_download_url":[^,]+' \
    | sed -E 's/.*"browser_download_url": *"([^\"]+)".*/\1/' | grep "$ARCH_WANTED" | grep -E "\.tar\.gz$" | head -n1 || true)
}

download_and_extract(){
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR" || return 1
  file="${ASSET_URL##*/}"
  if [ "$DOWNLOADER" = "curl" ]; then curl -L -o "$file" "$ASSET_URL"; else wget -q -O "$file" "$ASSET_URL"; fi
  mkdir -p extracted
  tar -xzf "$file" -C extracted
  extracted_dir=$(ls -1d extracted/* 2>/dev/null | head -n1 || true)
  [ -n "$extracted_dir" ] || return 1
}

ensure_usrbin_writable(){ [ -d "$BIN_DEST" ] || mkdir -p "$BIN_DEST" 2>/dev/null || true; tmpf="$BIN_DEST/.frp_write_test.$$"; if printf x > "$tmpf" 2>/dev/null; then rm -f "$tmpf"; return 0; fi; echoerr "无法写入 $BIN_DEST"; return 1; }

install_from_extracted(){
  sel="$1"
  ensure_usrbin_writable || return 1
  frpc_src=$(find "$extracted_dir" -type f -name frpc 2>/dev/null | head -n1 || true)
  frps_src=$(find "$extracted_dir" -type f -name frps 2>/dev/null | head -n1 || true)
  [ "$sel" = "frpc" ] || [ "$sel" = "all" ] && [ -n "$frpc_src" ] && { cp -f "$frpc_src" "$BIN_DEST/frpc" && chmod 755 "$BIN_DEST/frpc"; echoinfo "安装 frpc 到 $BIN_DEST"; }
  [ "$sel" = "frps" ] || [ "$sel" = "all" ] && [ -n "$frps_src" ] && { cp -f "$frps_src" "$BIN_DEST/frps" && chmod 755 "$BIN_DEST/frps"; echoinfo "安装 frps 到 $BIN_DEST"; }
  [ -d "$ETC_DIR" ] && rm -rf "$ETC_DIR" || true
  mkdir -p "$ETC_DIR"
  frpc_toml=$(find "$extracted_dir" -type f -iname "frpc.toml" 2>/dev/null | head -n1 || true)
  frps_toml=$(find "$extracted_dir" -type f -iname "frps.toml" 2>/dev/null | head -n1 || true)
  [ "$sel" = "frpc" ] || [ "$sel" = "all" ] && { if [ -n "$frpc_toml" ]; then cp -f "$frpc_toml" "$ETC_DIR/frpc.toml"; else printf "# frpc.toml\n" > "$ETC_DIR/frpc.toml"; fi }
  [ "$sel" = "frps" ] || [ "$sel" = "all" ] && { if [ -n "$frps_toml" ]; then cp -f "$frps_toml" "$ETC_DIR/frps.toml"; else printf "# frps.toml\n" > "$ETC_DIR/frps.toml"; fi }
}

create_systemd_unit_files(){
  sel="$1"
  [ "$sel" = "frps" ] || [ "$sel" = "all" ] && [ -x "$BIN_DEST/frps" ] && cat >/etc/systemd/system/frps.service <<'UNIT'
[Unit]
Description=frp Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  [ "$sel" = "frpc" ] || [ "$sel" = "all" ] && [ -x "$BIN_DEST/frpc" ] && cat >/etc/systemd/system/frpc.service <<'UNIT'
[Unit]
Description=frp Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
}

create_openwrt_init_scripts(){
  sel="$1"
  if command -v procd >/dev/null 2>&1 || [ -e /sbin/procd ]; then
    [ "$sel" = "frps" ] || [ "$sel" = "all" ] && cat >/etc/init.d/frps <<'INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
start(){
  config_load frp 2>/dev/null || true
  config_get_bool enabled main enabled 0
  [ "$enabled" -eq 1 ] || return 0
  procd_open_instance
  procd_set_param command /bin/sh -c 'cmd=$(command -v /usr/bin/frps || command -v frps); [ -n "$cmd" ] || exit 1; cd /etc/frp && exec "$cmd" -c frps.toml'
  procd_set_param respawn
  procd_close_instance
}
stop(){ procd_killall frps 2>/dev/null || true; }
INIT
    [ "$sel" = "frpc" ] || [ "$sel" = "all" ] && cat >/etc/init.d/frpc <<'INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
start(){
  config_load frp 2>/dev/null || true
  config_get_bool enabled client enabled 0
  [ "$enabled" -eq 1 ] || return 0
  procd_open_instance
  procd_set_param command /bin/sh -c 'cmd=$(command -v /usr/bin/frpc || command -v frpc); [ -n "$cmd" ] || exit 1; cd /etc/frp && exec "$cmd" -c frpc.toml'
  procd_set_param respawn
  procd_close_instance
}
stop(){ procd_killall frpc 2>/dev/null || true; }
INIT
  else
    [ "$sel" = "frps" ] || [ "$sel" = "all" ] && cat >/etc/init.d/frps <<'INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
start(){
  cmd=$(command -v /usr/bin/frps || command -v frps || true)
  [ -n "$cmd" ] || return 1
  [ -f /etc/frp/frps.toml ] || return 1
  cd /etc/frp || return 1
  sh -c 'exec "$cmd" -c frps.toml 2>>/var/log/frps.log &' || true
}
stop(){ pkill -f "-c frps.toml" 2>/dev/null || true; }
INIT
    [ "$sel" = "frpc" ] || [ "$sel" = "all" ] && cat >/etc/init.d/frpc <<'INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
start(){
  cmd=$(command -v /usr/bin/frpc || command -v frpc || true)
  [ -n "$cmd" ] || return 1
  [ -f /etc/frp/frpc.toml ] || return 1
  cd /etc/frp || return 1
  sh -c 'exec "$cmd" -c frpc.toml 2>>/var/log/frpc.log &' || true
}
stop(){ pkill -f "-c frpc.toml" 2>/dev/null || true; }
INIT
  fi
}

deploy_self(){
  if [ "${SYSTEM:-}" = "openwrt" ]; then target="/usr/sbin/$PROG_NAME"; else target="/usr/local/bin/$PROG_NAME"; fi
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  [ -f "$0" ] && cp -f "$0" "$target" 2>/dev/null && chmod +x "$target" || true
}

install_flow(){
  clear; detect_system; check_tools; arch_check; get_latest_release_info
  have_frps=no; have_frpc=no
  [ -x "$BIN_DEST/frps" ] && have_frps=yes; [ -x "$BIN_DEST/frpc" ] && have_frpc=yes
  if [ "$have_frps" = no ] || [ "$have_frpc" = no ]; then
    printf "\n请选择安装目标：\n 1) frps\n 2) frpc\n 3) all\n 0) 取消\n请选择: "; read choice
    case "$choice" in 1) INSTALL_TARGET=frps ;; 2) INSTALL_TARGET=frpc ;; 3) INSTALL_TARGET=all ;; 0) echoinfo "已取消"; return 0 ;; *) echowarn "无效选择"; return 0 ;; esac
    [ -n "${ASSET_URL:-}" ] || get_latest_release_info
    [ -n "${ASSET_URL:-}" ] || { echoerr "未找到下载地址"; return 1; }
    download_and_extract || return 1
    install_from_extracted "$INSTALL_TARGET" || return 1
    if [ "$SYSTEM" = "debian" ]; then create_systemd_unit_files "$INSTALL_TARGET"; else create_openwrt_init_scripts "$INSTALL_TARGET"; fi
    deploy_self; echoinfo "安装完成"; return 0
  fi
  echoinfo "无需安装"; return 0
}

service_manage(){ name="$1"
  while :; do
    clear; printf "%b+----------------------+%b\n" "$C_INFO" "$C_RST"
    printf "%b FRP 管理: %s\n" "$C_PROMPT" "$name"; printf "%b+----------------------+%b\n\n" "$C_INFO" "$C_RST"
    printf "1) 启动  2) 停止  3) 重启  4) 状态  5) 日志  0) 返回\n"
    printf "请选择: "; read op
    case "$op" in
      1) if [ "${SYSTEM:-}" = "debian" ]; then systemctl start "$name".service || true; else /etc/init.d/"$name" start || true; fi ;;
      2) if [ "${SYSTEM:-}" = "debian" ]; then systemctl stop "$name".service || true; else /etc/init.d/"$name" stop || true; fi ;;
      3) if [ "${SYSTEM:-}" = "debian" ]; then systemctl restart "$name".service || true; else /etc/init.d/"$name" restart || true; fi ;;
      4) if [ "${SYSTEM:-}" = "debian" ]; then systemctl status "$name".service --no-pager || true; else ps aux | grep "$name" | grep -v grep || echo "未检测到进程"; fi; printf "\n回车返回"; read _ || true ;;
      5) if [ "${SYSTEM:-}" = "debian" ]; then journalctl -u "$name".service -n200 --no-pager || true; else logread | tail -n200 || true; fi; printf "\n回车返回"; read _ || true ;;
      0) break ;; *) echowarn "无效"; sleep 1 ;;
    esac
  done
}

manage_menu(){
  while :; do
    clear; printf "1) 管理 frps  2) 管理 frpc  0) 返回\n"
    printf "请选择: "; read s
    case "$s" in 1) service_manage frps ;; 2) service_manage frpc ;; 0) break ;; *) echowarn "无效"; sleep 1 ;; esac
  done
}

uninstall_all(){
  printf "确认卸载并删除所有 frp 文件？输入 yes 确认: "; read c
  [ "$c" = "yes" ] || return 0
  detect_system || true
  if [ "${SYSTEM:-}" = "debian" ]; then systemctl stop frps.service frpc.service 2>/dev/null || true; systemctl disable frps.service frpc.service 2>/dev/null || true; rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service; systemctl daemon-reload || true; else /etc/init.d/frps stop 2>/dev/null || true; /etc/init.d/frpc stop 2>/dev/null || true; rm -f /etc/init.d/frps /etc/init.d/frpc; fi
  rm -f "$BIN_DEST/frps" "$BIN_DEST/frpc" || true; rm -rf "$ETC_DIR" || true; rm -f /var/log/frps.log /var/log/frpc.log || true
  echoinfo "已卸载"
}

main_menu(){
  while :; do
    clear; printf "1) 安装/升级  2) 管理  3) 卸载  0) 退出\n"
    printf "请选择: "; read o
    case "$o" in 1) install_flow ;; 2) detect_system; manage_menu ;; 3) detect_system; uninstall_all ;; 0) exit 0 ;; *) echowarn "无效"; sleep 1 ;; esac
  done
}

if [ "$(basename "$0")" = "$PROG_NAME" ] || [ "${0##*/}" = "$PROG_NAME" ]; then main_menu; fi
