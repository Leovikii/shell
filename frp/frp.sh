#!/bin/sh
# frp.sh - Debian & OpenWrt 兼容的 frp 安装/管理/卸载 脚本（完整版）
# 说明：写 /usr/bin 与 /etc 需要 root 权限。若从 Windows 上传，请先去除 CRLF。
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

# 颜色（在终端支持时有效）
C_RST='\033[0m'
C_HDR='\033[1;36m'
C_INFO='\033[1;34m'
C_WARN='\033[1;33m'
C_ERR='\033[1;31m'
C_PROMPT='\033[1;32m'

echoinfo()  { printf "%b[INFO] %s%b\n"  "$C_INFO" "$*" "$C_RST"; }
echowarn()  { printf "%b[WARN] %s%b\n"  "$C_WARN" "$*" "$C_RST"; }
echoerr()   { printf "%b[ERROR] %s%b\n" "$C_ERR" "$*" "$C_RST" 1>&2; }

cleanup() {
  if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then rm -rf "$TMPDIR" || true; fi
}
trap cleanup EXIT

# ---------- 基础检测与版本工具 ----------
detect_system() {
  if [ -f /etc/openwrt_release ] || ( [ -f /etc/os-release ] && grep -qi openwrt /etc/os-release 2>/dev/null ); then
    SYSTEM="openwrt"
  elif command -v systemctl >/dev/null 2>&1 && ( [ -f /etc/debian_version ] || ( [ -f /etc/os-release ] && grep -qiE "debian|ubuntu" /etc/os-release 2>/dev/null || true ) ); then
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
    printf "继续吗？(yes/ no): "; read goon
    [ "$goon" = "yes" ] || ( echoinfo "已取消"; exit 1 )
  fi
}

get_latest_release_info() {
  echoinfo "从 GitHub 获取 latest release..."
  if [ "$DOWNLOADER" = "curl" ]; then json=$(curl -fsSL "$GITHUB_API"); else json=$(wget -qO- "$GITHUB_API"); fi
  tag=$(echo "$json" | grep -Eo '"tag_name":[^,]+' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -n1 || true)
  if [ -n "${tag:-}" ]; then
    LATEST_TAG="$tag"
    LATEST_VERSION=$(echo "$tag" | sed -E 's/^[vV]//')
  else
    LATEST_TAG=""; LATEST_VERSION=""
  fi
  ASSET_URL=$(echo "$json" | grep -Eo '"browser_download_url":[^,]+' \
    | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
    | grep "$ARCH_WANTED" | grep -E "\.tar\.gz$" | head -n1 || true)
  echoinfo "Latest release: ${LATEST_TAG:-unknown}, asset: ${ASSET_URL:-none}"
}

get_installed_version() {
  bin="$1"
  ver="unknown"
  if [ ! -x "$bin" ]; then
    echo "$ver"; return
  fi
  out=$("$bin" -v 2>&1 || true)
  [ -z "$out" ] && out=$("$bin" -V 2>&1 || true)
  [ -z "$out" ] && out=$("$bin" --version 2>&1 || true)
  vernum=$(echo "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  [ -n "$vernum" ] && ver="$vernum"
  echo "$ver"
}

ver_gt() {
  a="$1"; b="$2"
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" = "unknown" ] || [ "$b" = "unknown" ]; then return 1; fi
  oldIFS=$IFS; IFS=.
  set -- $a; a1=${1:-0}; a2=${2:-0}; a3=${3:-0}
  set -- $b; b1=${1:-0}; b2=${2:-0}; b3=${3:-0}
  IFS=$oldIFS
  if [ "$a1" -gt "$b1" ] 2>/dev/null; then return 0; fi
  if [ "$a1" -lt "$b1" ] 2>/dev/null; then return 1; fi
  if [ "$a2" -gt "$b2" ] 2>/dev/null; then return 0; fi
  if [ "$a2" -lt "$b2" ] 2>/dev/null; then return 1; fi
  if [ "$a3" -gt "$b3" ] 2>/dev/null; then return 0; fi
  return 1
}

# ---------- 下载/解压/写入 ----------
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
  extracted_dir=$(ls -1d extracted/* 2>/dev/null | head -n1 || true)
  if [ -z "$extracted_dir" ]; then echoerr "解压后未找到目录"; return 1; fi
  echoinfo "解压目录: $extracted_dir"
}

ensure_usrbin_writable() {
  if [ ! -d "$BIN_DEST" ]; then mkdir -p "$BIN_DEST" 2>/dev/null || true; fi
  tmpf="$BIN_DEST/.frp_write_test.$$"
  if printf x > "$tmpf" 2>/dev/null; then rm -f "$tmpf" 2>/dev/null || true; return 0; fi
  echoerr "无法写入 $BIN_DEST，请以 root/sudo 运行脚本并确保 $BIN_DEST 可写"
  return 1
}

write_bins_to_usrbin() {
  frpc_src=$(find "$extracted_dir" -type f -name frpc 2>/dev/null | head -n1 || true)
  frps_src=$(find "$extracted_dir" -type f -name frps 2>/dev/null | head -n1 || true)

  if [ -n "$frpc_src" ]; then
    if cp -f "$frpc_src" "$BIN_DEST/frpc" 2>/dev/null; then chmod 0755 "$BIN_DEST/frpc" 2>/dev/null || true; echoinfo "已写入 $BIN_DEST/frpc"; else echoerr "写入 $BIN_DEST/frpc 失败"; return 1; fi
  else echowarn "未找到 frpc"; fi

  if [ -n "$frps_src" ]; then
    if cp -f "$frps_src" "$BIN_DEST/frps" 2>/dev/null; then chmod 0755 "$BIN_DEST/frps" 2>/dev/null || true; echoinfo "已写入 $BIN_DEST/frps"; else echoerr "写入 $BIN_DEST/frps 失败"; return 1; fi
  else echowarn "未找到 frps"; fi
  return 0
}

install_bins_only_from_extracted() {
  ensure_usrbin_writable || return 1
  write_bins_to_usrbin || return 1
}

install_full_flow_from_extracted() {
  ensure_usrbin_writable || return 1
  write_bins_to_usrbin || return 1

  # 重建 /etc/frp (不备份)，确保目录中仅有两个 toml
  if [ -d "$ETC_DIR" ]; then rm -rf "$ETC_DIR" || true; fi
  mkdir -p "$ETC_DIR" || { echoerr "无法创建 $ETC_DIR"; return 1; }

  frpc_toml_src=$(find "$extracted_dir" -type f -iname "frpc.toml" 2>/dev/null | head -n1 || true)
  frps_toml_src=$(find "$extracted_dir" -type f -iname "frps.toml" 2>/dev/null | head -n1 || true)

  if [ -n "$frpc_toml_src" ]; then cp -f "$frpc_toml_src" "$ETC_DIR/frpc.toml" && chmod 0644 "$ETC_DIR/frpc.toml" || true; echoinfo "复制 frpc.toml -> $ETC_DIR/frpc.toml"
  else
    cat >"$ETC_DIR/frpc.toml" <<'EOF'
# frpc.toml (占位)
# 请填写客户端配置
EOF
    chmod 0644 "$ETC_DIR/frpc.toml" || true
    echowarn "未找到示例 frpc.toml，已创建占位 $ETC_DIR/frpc.toml"
  fi

  if [ -n "$frps_toml_src" ]; then cp -f "$frps_toml_src" "$ETC_DIR/frps.toml" && chmod 0644 "$ETC_DIR/frps.toml" || true; echoinfo "复制 frps.toml -> $ETC_DIR/frps.toml"
  else
    cat >"$ETC_DIR/frps.toml" <<'EOF'
# frps.toml (占位)
# 请填写服务端配置
EOF
    chmod 0644 "$ETC_DIR/frps.toml" || true
    echowarn "未找到示例 frps.toml，已创建占位 $ETC_DIR/frps.toml"
  fi

  # 删除 /etc/frp 下其它文件，确保只剩 frpc.toml 和 frps.toml
  for f in "$ETC_DIR"/*; do
    [ -e "$f" ] || continue
    bn=$(basename "$f")
    if [ "$bn" != "frpc.toml" ] && [ "$bn" != "frps.toml" ]; then rm -rf "$f" || true; fi
  done
  echoinfo "/etc/frp 已重建并仅包含 frpc.toml 与 frps.toml"
}

# ---------- systemd/unit & openwrt init 创建 ----------
create_systemd_unit_files() {
  echoinfo "创建 systemd unit（不启用/启动）..."
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
  echowarn "systemd unit 已创建，但未启用/启动。请编辑配置后手动启用并启动。"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
}

create_openwrt_init_scripts() {
  echoinfo "创建 OpenWrt init 脚本（procd 版本，若系统无 procd 则回退至兼容脚本）..."

  if command -v procd >/dev/null 2>&1 || [ -e /sbin/procd ]; then
    # frps - procd 脚本
    cat >/etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
# frps - frp 服务端 (procd)
USE_PROCD=1
START=99
STOP=10

config() {
  config_load frp 2>/dev/null || true
}

start() {
  config
  local enabled conf log_stderr
  config_get_bool enabled "main" "enabled" "0"
  [ "$enabled" -eq 1 ] || return 0

  config_get conf "main" "frps_conf" "/etc/frp/frps.toml"
  config_get log_stderr "main" "log_stderr" "/var/log/frps.log"

  procd_open_instance
  procd_set_param command /usr/bin/frps -c "$conf"
  procd_set_param file "$conf"
  procd_set_param stderr "$log_stderr"
  procd_set_param limits core="unlimited"
  procd_set_param limits nofile="1000000 1000000"
  procd_set_param respawn
  procd_close_instance
}

stop() {
  procd_killall frps 2>/dev/null || true
}

service_triggers() {
  procd_add_reload_trigger frp
}
EOF
    chmod +x /etc/init.d/frps || true
    echoinfo "/etc/init.d/frps (procd) 已生成"

    # frpc - procd 脚本
    cat >/etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
# frpc - frp 客户端 (procd)
USE_PROCD=1
START=99
STOP=10

config() {
  config_load frp 2>/dev/null || true
}

start() {
  config
  local enabled conf log_stderr
  config_get_bool enabled "client" "enabled" "0"
  [ "$enabled" -eq 1 ] || return 0

  config_get conf "client" "frpc_conf" "/etc/frp/frpc.toml"
  config_get log_stderr "client" "log_stderr" "/var/log/frpc.log"

  procd_open_instance
  procd_set_param command /usr/bin/frpc -c "$conf"
  procd_set_param file "$conf"
  procd_set_param stderr "$log_stderr"
  procd_set_param limits core="unlimited"
  procd_set_param limits nofile="1000000 1000000"
  procd_set_param respawn
  procd_close_instance
}

stop() {
  procd_killall frpc 2>/dev/null || true
}

service_triggers() {
  procd_add_reload_trigger frp
}
EOF
    chmod +x /etc/init.d/frpc || true
    echoinfo "/etc/init.d/frpc (procd) 已生成"

  else
    # 回退：传统 start-stop-daemon 脚本
    cat >/etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
# frps - fallback init
START=99
STOP=10
PROG=/usr/bin/frps
CONF=/etc/frp/frps.toml

start() {
  [ -x "$PROG" ] || return 1
  [ -f "$CONF" ] || return 1
  start-stop-daemon -S -b -x "$PROG" -- -c "$CONF"
}

stop() {
  start-stop-daemon -K -x "$PROG"
}
EOF
    chmod +x /etc/init.d/frps || true
    echoinfo "/etc/init.d/frps (fallback) 已生成"

    cat >/etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
# frpc - fallback init
START=99
STOP=10
PROG=/usr/bin/frpc
CONF=/etc/frp/frpc.toml

start() {
  [ -x "$PROG" ] || return 1
  [ -f "$CONF" ] || return 1
  start-stop-daemon -S -b -x "$PROG" -- -c "$CONF"
}

stop() {
  start-stop-daemon -K -x "$PROG"
}
EOF
    chmod +x /etc/init.d/frpc || true
    echoinfo "/etc/init.d/frpc (fallback) 已生成"
  fi

  echowarn "init 脚本已生成（未启用/未启动）。启用示例："
  echoinfo "  /etc/init.d/frps enable"
  echoinfo "  /etc/init.d/frps start"
  echoinfo "  /etc/init.d/frpc enable"
  echoinfo "  /etc/init.d/frpc start"
}

deploy_self() {
  if [ "$SYSTEM" = "openwrt" ]; then target="/usr/sbin/$PROG_NAME"; else target="/usr/local/bin/$PROG_NAME"; fi
  echoinfo "尝试复制脚本到 $target ..."
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  if [ -f "$0" ]; then
    if cp -f "$0" "$target" 2>/dev/null; then chmod +x "$target" 2>/dev/null || true; echoinfo "脚本已复制到 $target"; else echowarn "复制脚本到 $target 失败（权限）"; fi
  fi
}

# ---------- 安装/升级流程（含版本检测/提示） ----------
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

  echoinfo "本地版本: frps=$inst_frps_ver frpc=$inst_frpc_ver"
  echoinfo "最新 release: ${LATEST_TAG:-unknown} -> ${LATEST_VERSION:-unknown}"

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
      install_bins_only_from_extracted || return 1
      echoinfo "二进制更新完成。请按需重启服务。"
      deploy_self
      return 0
    fi
  fi

  if [ "$have_frps" = "no" ] || [ "$have_frpc" = "no" ]; then
    printf "\n检测到缺少 frps 或 frpc，将进行完整安装（会重建 /etc/frp，仅保留 frpc.toml 与 frps.toml）\n"
    printf "继续吗？(yes/[no]) "; read cont
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
  echowarn "如需强制重装请先卸载再安装。"
  return 0
}

# ---------- 管理/卸载/菜单（美化） ----------
service_manage() {
  name="$1"
  while :; do
    clear
    printf "%b========================================%b\n" "$C_HDR" "$C_RST"
    printf "%b  FRP 服务管理：%s  %b\n" "$C_PROMPT" "$name" "$C_RST"
    printf "%b========================================%b\n\n" "$C_HDR" "$C_RST"

    printf "  %-4s %-12s  %-4s %-12s\n" "1)" "启动"   "2)" "停止"
    printf "  %-4s %-12s  %-4s %-12s\n" "3)" "重启"   "4)" "状态"
    printf "  %-4s %-12s  %-4s %-12s\n\n" "5)" "查看日志" "0)" "返回"

    printf "请选择: "; read op
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
    printf "%b========================================%b\n" "$C_HDR" "$C_RST"
    printf "%b  FRP 管理菜单  %b\n" "$C_PROMPT" "$C_RST"
    printf "%b========================================%b\n\n" "$C_HDR" "$C_RST"

    printf "  %-4s %-20s  %-4s %-20s\n" "1)" "管理 frps (服务端)" "2)" "管理 frpc (客户端)"
    printf "\n  %-4s %-20s\n\n" "0)" "返回主菜单"

    printf "请选择: "; read sel
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
  printf "%b警告：此操作将删除 frp 二进制、/etc/frp、服务文件与脚本（若已部署）！%b\n\n" "$C_WARN" "$C_RST"
  printf "确认卸载并删除所有 frp 文件？（输入 yes 确认）: "; read confirm
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
    printf "%b========================================%b\n" "$C_HDR" "$C_RST"
    printf "%b  frp 安装 / 管理 / 卸载  %b\n" "$C_PROMPT" "$C_RST"
    printf "%b========================================%b\n\n" "$C_HDR" "$C_RST"

    printf "  %-4s %-30s  %-4s %-30s\n" "1)" "安装 / 升级 frp" "2)" "管理 frp (启动/停止/重启/日志)"
    printf "\n  %-4s %-30s\n\n" "3)" "卸载 frp"
    printf "  %-4s %-30s\n\n" "0)" "退出"

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

# 入口
if [ "$(basename "$0")" = "$PROG_NAME" ] || [ "${0##*/}" = "$PROG_NAME" ]; then
  main_menu
fi
