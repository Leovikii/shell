#!/usr/bin/env bash
# frp.sh - 安装/升级/管理/卸载 frp（已修复 BusyBox find -quit，取消 /etc/frp 备份）
set -euo pipefail
IFS=$'\n\t'

PROG_NAME="frp.sh"
ARCH_WANTED="linux_amd64"
GITHUB_API="https://api.github.com/repos/fatedier/frp/releases/latest"
BIN_DEST="/usr/bin"
ETC_DIR="/etc/frp"
SYSTEM=""
DOWNLOADER=""
TMPDIR=""

# 颜色
c_reset="\033[0m"
c_info="\033[1;34m"
c_warn="\033[1;33m"
c_err="\033[1;31m"
c_prompt="\033[1;32m"

echoinfo(){ printf "%b[INFO]%b %s\n" "$c_info" "$c_reset" "$*"; }
echowarn(){ printf "%b[WARN]%b %s\n" "$c_warn" "$c_reset" "$*"; }
echoerr(){ printf "%b[ERROR]%b %s\n" "$c_err" "$c_reset" "$*" >&2; }

cleanup(){ [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR" || true; }
trap cleanup EXIT

### 基本检测函数（保持兼容性）
detect_system(){
  if [ -f /etc/openwrt_release ] || ( [ -f /etc/os-release ] && grep -qi "openwrt" /etc/os-release ); then
    SYSTEM="openwrt"
  elif command -v systemctl >/dev/null 2>&1 && ( [ -f /etc/debian_version ] || ( [ -f /etc/os-release ] && grep -qiE "debian|ubuntu" /etc/os-release ) ); then
    SYSTEM="debian"
  else
    if command -v opkg >/dev/null 2>&1; then SYSTEM="openwrt"
    elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then SYSTEM="debian"
    else
      while true; do
        clear
        echo "无法自动识别系统，请选择："
        echo "  1) debian/ubuntu (systemd)"
        echo "  2) openwrt"
        echo "  0) 退出"
        read -rp $'\n请选择: ' choice
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
  arch=$(uname -m || echo unknown)
  echoinfo "检测到架构: $arch"
  if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
    echowarn "当前不是 x86_64 架构，本脚本将下载 linux_amd64 版本，可能无法执行。"
    read -rp $'\n继续吗？(yes/ no): ' goon
    if [ "$goon" != "yes" ]; then echoinfo "操作已取消"; exit 1; fi
  fi
}

get_latest_release_info(){
  echoinfo "查询 GitHub latest release..."
  if [ "$DOWNLOADER" = "curl" ]; then json=$(curl -fsSL "$GITHUB_API"); else json=$(wget -qO- "$GITHUB_API"); fi
  tag=$(echo "$json" | grep -Eo '"tag_name":[^,]+' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -n1 || true)
  if [ -n "${tag:-}" ]; then LATEST_TAG="$tag"; LATEST_VERSION=$(echo "$tag" | sed -E 's/^[vV]//'); else LATEST_TAG=""; LATEST_VERSION=""; fi
  asset_url=$(echo "$json" | grep -Eo '"browser_download_url":[^,]+' \
    | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
    | grep "$ARCH_WANTED" | grep -E "\.tar\.gz$" | head -n1 || true)
  ASSET_URL="$asset_url"
  echoinfo "Latest release: ${LATEST_TAG:-unknown}, asset: ${ASSET_URL:-(none)}"
}

get_installed_version(){
  binpath="$1"
  ver="unknown"
  if [ ! -x "$binpath" ]; then echo "$ver"; return; fi
  out=$("$binpath" -v 2>&1 || true)
  if [ -z "$out" ]; then out=$("$binpath" -V 2>&1 || true); fi
  if [ -z "$out" ]; then out=$("$binpath" --version 2>&1 || true); fi
  vernum=$(echo "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  if [ -n "$vernum" ]; then ver="$vernum"; fi
  echo "$ver"
}

ver_gt(){
  a="$1"; b="$2"
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" = "unknown" ] || [ "$b" = "unknown" ]; then return 1; fi
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  for i in 0 1 2; do
    ai=${A[i]:-0}; bi=${B[i]:-0}
    if ((10#$ai > 10#$bi)); then return 0; fi
    if ((10#$ai < 10#$bi)); then return 1; fi
  done
  return 1
}

### 兼容 BusyBox 的下载与解压（避免使用 -quit 等非标准选项）
download_and_extract(){
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"
  archive_name="${ASSET_URL##*/}"
  echoinfo "下载 $archive_name 到 $TMPDIR ..."
  if [ "$DOWNLOADER" = "curl" ]; then curl -L -o "$archive_name" "$ASSET_URL"
  else wget -q -O "$archive_name" "$ASSET_URL"; fi
  echoinfo "解压..."
  mkdir -p extracted
  tar -xzf "$archive_name" -C extracted
  # 更可靠地取得解压出来的第一个目录（不用 find -maxdepth 或 -quit）
  extracted_dir=$(ls -1d extracted/* 2>/dev/null | head -n1 || true)
  if [ -z "$extracted_dir" ]; then echoerr "解压后未找到目录，可能解压失败"; exit 1; fi
  echoinfo "解压目录: $extracted_dir"
}

### 仅安装/替换二进制（升级场景使用），确保写入 /usr/bin
install_bins_only_from_extracted(){
  mkdir -p "$BIN_DEST"
  # 用兼容方式查找二进制
  frpc_src=$(find "$extracted_dir" -type f -name frpc 2>/dev/null | head -n1 || true)
  frps_src=$(find "$extracted_dir" -type f -name frps 2>/dev/null | head -n1 || true)

  if [ -n "$frpc_src" ]; then
    # 使用 install 以确保权限
    if install -m 0755 "$frpc_src" "$BIN_DEST/frpc"; then
      echoinfo "frpc 已写入 $BIN_DEST/frpc"
    else
      echoerr "写入 $BIN_DEST/frpc 失败：请检查 /usr/bin 是否可写（是否以 root 运行）"
      return 1
    fi
  else echowarn "未在 release 中找到 frpc"; fi

  if [ -n "$frps_src" ]; then
    if install -m 0755 "$frps_src" "$BIN_DEST/frps"; then
      echoinfo "frps 已写入 $BIN_DEST/frps"
    else
      echoerr "写入 $BIN_DEST/frps 失败：请检查 /usr/bin 是否可写（是否以 root 运行）"
      return 1
    fi
  else echowarn "未在 release 中找到 frps"; fi
}

### 完整安装流程：重建 /etc/frp（不备份），并保证目录**最终仅含** frpc.toml & frps.toml
install_full_flow_from_extracted(){
  mkdir -p "$BIN_DEST"
  frpc_src=$(find "$extracted_dir" -type f -name frpc 2>/dev/null | head -n1 || true)
  frps_src=$(find "$extracted_dir" -type f -name frps 2>/dev/null | head -n1 || true)

  if [ -n "$frpc_src" ]; then
    install -m 0755 "$frpc_src" "$BIN_DEST/frpc" || { echoerr "无法写入 $BIN_DEST/frpc"; exit 1; }
    echoinfo "frpc 安装到 $BIN_DEST/frpc"
  else echowarn "未找到 frpc 二进制"; fi

  if [ -n "$frps_src" ]; then
    install -m 0755 "$frps_src" "$BIN_DEST/frps" || { echoerr "无法写入 $BIN_DEST/frps"; exit 1; }
    echoinfo "frps 安装到 $BIN_DEST/frps"
  else echowarn "未找到 frps 二进制"; fi

  # 处理 /etc/frp：不备份，直接重建（确保最终只有两个 toml）
  if [ -d "$ETC_DIR" ]; then
    # 直接删除并重建（用户要求：不备份）
    rm -rf "$ETC_DIR" || true
  fi
  mkdir -p "$ETC_DIR"

  frpc_toml_src=$(find "$extracted_dir" -type f -iname "frpc.toml" 2>/dev/null | head -n1 || true)
  frps_toml_src=$(find "$extracted_dir" -type f -iname "frps.toml" 2>/dev/null | head -n1 || true)

  if [ -n "$frpc_toml_src" ]; then
    install -m 0644 "$frpc_toml_src" "$ETC_DIR/frpc.toml"
    echoinfo "已复制示例 frpc.toml -> $ETC_DIR/frpc.toml"
  else
    cat >"$ETC_DIR/frpc.toml" <<'EOF'
# frpc.toml (占位)
# 请根据需要填写客户端配置
# [common]
# server_addr = "1.2.3.4"
# server_port = 7000
EOF
    chmod 0644 "$ETC_DIR/frpc.toml"
    echowarn "release 中未包含 frpc.toml，已创建占位 $ETC_DIR/frpc.toml，请编辑"
  fi

  if [ -n "$frps_toml_src" ]; then
    install -m 0644 "$frps_toml_src" "$ETC_DIR/frps.toml"
    echoinfo "已复制示例 frps.toml -> $ETC_DIR/frps.toml"
  else
    cat >"$ETC_DIR/frps.toml" <<'EOF'
# frps.toml (占位)
# 请根据需要填写服务端配置
# [common]
# bind_port = 7000
EOF
    chmod 0644 "$ETC_DIR/frps.toml"
    echowarn "release 中未包含 frps.toml，已创建占位 $ETC_DIR/frps.toml，请编辑"
  fi

  # 删除 /etc/frp 中所有非 frpc.toml/frps.toml 项（保险）
  for f in "$ETC_DIR"/*; do
    [ -e "$f" ] || continue
    bn=$(basename "$f")
    if [ "$bn" != "frpc.toml" ] && [ "$bn" != "frps.toml" ]; then
      rm -rf "$f" || true
    fi
  done
  echoinfo "/etc/frp 现仅包含 frpc.toml 与 frps.toml（其它已删除）"
}

### systemd / openwrt init 脚本创建（不自动启用/启动）
create_systemd_unit_files(){
  echoinfo "创建 systemd 单元（但不启用/启动）..."
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
  echowarn "systemd 服务文件已创建，但未启用/未启动。请在确认配置后手动启用并启动。"
  systemctl daemon-reload || true
}

create_openwrt_init_scripts(){
  echoinfo "创建 OpenWrt init 脚本（但不 enable/start）..."
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
  echowarn "OpenWrt init 脚本已创建，但未 enable/start。请在确认配置后手动启用启动。"
}

deploy_self_and_cleanup(){
  if [ "$SYSTEM" = "openwrt" ]; then target="/usr/sbin/$PROG_NAME"; else target="/usr/local/bin/$PROG_NAME"; fi
  echoinfo "尝试复制脚本到 $target ..."
  mkdir -p "$(dirname "$target")"
  if [ -f "$0" ]; then cp -f "$0" "$target" && chmod +x "$target" && echoinfo "脚本已复制到 $target"
  elif [ -f "/root/$PROG_NAME" ]; then cp -f "/root/$PROG_NAME" "$target" && chmod +x "$target" && rm -f "/root/$PROG_NAME" || true && echoinfo "脚本已复制到 $target (from /root)"
  else echowarn "无法自动复制脚本到 $target，请手动复制并 chmod +x"; fi
}

### 安装逻辑（保留版本检测/升级提示逻辑，调用上面改良函数）
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

  echoinfo "本地已安装版本 frps=$inst_frps_ver frpc=$inst_frpc_ver"
  echoinfo "最新 release: ${LATEST_TAG:-(unknown)} -> 版本号 ${LATEST_VERSION:-(unknown)}"

  should_prompt_update="no"
  if [ "$have_frps" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frps_ver"; then should_prompt_update="yes"; fi
  if [ "$have_frpc" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frpc_ver"; then should_prompt_update="yes"; fi

  if [ "$should_prompt_update" = "yes" ]; then
    echo
    echo "检测到已有安装且存在可用更新："
    [ "$have_frps" = "yes" ] && echo "  frps: $inst_frps_ver -> $LATEST_VERSION"
    [ "$have_frpc" = "yes" ] && echo "  frpc: $inst_frpc_ver -> $LATEST_VERSION"
    read -rp $'\n是否仅更新二进制（不会更改 /etc/frp 下 toml，也不会修改/创建服务文件）？(yes/[no]) ' update_choice
    if [ "$update_choice" = "yes" ]; then
      if [ -z "${ASSET_URL:-}" ]; then echoerr "未获取到下载地址，无法更新"; return; fi
      download_and_extract
      install_bins_only_from_extracted
      echoinfo "二进制更新完成。请在确认后重启服务（若有）。"
      deploy_self_and_cleanup
      return
    fi
  fi

  if [ "$have_frps" = "no" ] || [ "$have_frpc" = "no" ]; then
    echo
    echo "检测到系统上缺少 frps 或 frpc。将进行完整安装（此操作会重建 /etc/frp 并确保目录仅包含 frpc.toml 与 frps.toml）"
    read -rp $'\n继续完整安装吗？(yes/[no]) ' cont
    if [ "$cont" != "yes" ]; then echoinfo "已取消安装"; return; fi
    if [ -z "${ASSET_URL:-}" ]; then echoerr "未获取到下载地址，无法安装"; return; fi
    download_and_extract
    install_full_flow_from_extracted
    if [ "$SYSTEM" = "debian" ]; then create_systemd_unit_files; else create_openwrt_init_scripts; fi
    deploy_self_and_cleanup
    echoinfo "完整安装完成。注意：服务未自动启用/启动，请先编辑 /etc/frp/frps.toml 或 /etc/frp/frpc.toml 后再启用启动。"
    return
  fi

  all_up_to_date="yes"
  if [ "$have_frps" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frps_ver"; then all_up_to_date="no"; fi
  if [ "$have_frpc" = "yes" ] && ver_gt "$LATEST_VERSION" "$inst_frpc_ver"; then all_up_to_date="no"; fi

  if [ "$all_up_to_date" = "yes" ]; then
    echoinfo "检测到本地 frps/frpc 版本与最新 release 相同或无法检测版本，跳过下载/安装。"
    echowarn "如需强制重新安装，请先卸载再重新运行安装选项。"
    return
  else
    echo
    echowarn "存在版本差异或无法确定版本，建议更新二进制。"
    read -rp $'\n是否下载并替换二进制（不会覆盖 /etc/frp）？(yes/[no]) ' c2
    if [ "$c2" = "yes" ]; then
      if [ -z "${ASSET_URL:-}" ]; then echoerr "未获取到下载地址，无法更新"; return; fi
      download_and_extract
      install_bins_only_from_extracted
      echoinfo "二进制替换完成。"
      deploy_self_and_cleanup
      return
    else
      echoinfo "已取消更新。"
      return
    fi
  fi
}

# 管理/卸载/菜单（保持不变，略）
# 为简洁起见，此处仅保留 main_menu 的简短实现，真实脚本请保留你之前的完整菜单/管理实现
service_manage(){ 
  name="$1"
  while true; do
    clear
    printf "%b FRP 服务管理：%s %b\n" "$c_prompt" "$name" "$c_reset"
    echo "1) 启动  2) 停止  3) 重启  4) 状态  5) 日志  0) 返回"
    read -rp $'\n请选择: ' op
    case "$op" in
      1) if [ "$SYSTEM" = "debian" ]; then systemctl start "${name}.service" || echowarn "启动可能失败"; else /etc/init.d/"$name" start || echowarn "启动可能失败"; fi; sleep 1;;
      2) if [ "$SYSTEM" = "debian" ]; then systemctl stop "${name}.service" || true; else /etc/init.d/"$name" stop || true; fi; sleep 1;;
      3) if [ "$SYSTEM" = "debian" ]; then systemctl restart "${name}.service" || echowarn "重启失败"; else /etc/init.d/"$name" restart || echowarn "重启失败"; fi; sleep 1;;
      4) if [ "$SYSTEM" = "debian" ]; then systemctl status "${name}.service" --no-pager || true; else ps aux | grep "$name" | grep -v grep || echo "未检测到进程"; fi; read -rp $'\n按回车返回...' dum || true;;
      5) if [ "$SYSTEM" = "debian" ]; then journalctl -u "${name}.service" -n 200 --no-pager || true; else logread | tail -n 200 || true; fi; read -rp $'\n按回车返回...' dum || true;;
      0) break;;
      *) echowarn "无效输入"; sleep 1;;
    esac
  done
}

manage_menu(){
  while true; do
    clear
    echo "1) 管理 frps  2) 管理 frpc  0) 返回"
    read -rp $'\n请选择: ' sel
    case "$sel" in
      1) service_manage "frps";;
      2) service_manage "frpc";;
      0) break;;
      *) echowarn "无效输入"; sleep 1;;
    esac
  done
}

uninstall_all(){
  clear
  echo "警告：此操作将删除 frp 二进制、配置、服务文件及脚本本体！"
  read -rp $'\n确认卸载并删除所有 frp 文件？（输入 yes 确认）: ' confirm
  if [ "$confirm" != "yes" ]; then echoinfo "已取消卸载。"; read -rp $'\n按回车返回...' dum || true; return; fi

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
  read -rp $'\n按回车返回...' dum || true
}

main_menu(){
  while true; do
    clear
    printf "%b frp 安装/管理/卸载 脚本 %b\n" "$c_prompt" "$c_reset"
    echo "1) 安装 / 升级 frp"
    echo "2) 管理 frp"
    echo "3) 卸载 frp"
    echo "0) 退出"
    read -rp $'\n请选择: ' opt
    case "$opt" in
      1) install_flow; read -rp $'\n按回车返回主菜单...' dum || true;;
      2) if [ -z "${SYSTEM:-}" ]; then detect_system; fi; manage_menu;;
      3) if [ -z "${SYSTEM:-}" ]; then detect_system; fi; uninstall_all;;
      0) echoinfo "退出"; exit 0;;
      *) echowarn "无效选择"; sleep 1;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main_menu; fi
