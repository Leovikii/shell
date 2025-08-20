#!/usr/bin/env bash
# frp.sh - 安装/管理/卸载 frp (frps/frpc)
# 兼容 Debian 系列 (systemd) 与 OpenWrt (/etc/init.d)
# 目标: 下载 fatedier/frp 最新 linux_amd64 release 并安装
# Author: ChatGPT (adapted)
set -e

PROG_NAME="frp.sh"
TMPDIR=""
GITHUB_API="https://api.github.com/repos/fatedier/frp/releases/latest"
ARCH_WANTED="linux_amd64"
BIN_DEST="/usr/bin"
ETC_DIR="/etc/frp"
SYSTEM=""
SELF_PATH="$0"

# Helper: print
echoinfo(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
echowarn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
echoerr(){ echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# Cleanup tmp on exit
cleanup() {
  [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

# 检测系统类型（debian/systemd 或 openwrt）
detect_system(){
  echoinfo "检测系统类型..."
  if [ -f /etc/openwrt_release ] || grep -qi "OpenWrt" /etc/os-release 2>/dev/null; then
    SYSTEM="openwrt"
  elif command -v systemctl >/dev/null 2>&1 && [ -f /etc/debian_version ] || grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
    SYSTEM="debian"
  else
    # 尝试通过包管理器判断
    if command -v opkg >/dev/null 2>&1; then
      SYSTEM="openwrt"
    elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
      SYSTEM="debian"
    else
      # 让用户选择
      echowarn "无法自动识别系统类型，请手动选择："
      select choice in "debian" "openwrt" "退出"; do
        case $choice in
          debian) SYSTEM="debian"; break;;
          openwrt) SYSTEM="openwrt"; break;;
          "退出") exit 1;;
        esac
      done
    fi
  fi
  echoinfo "检测到系统类型: $SYSTEM"
}

# 检查基础工具 (curl/wget/tar)
check_tools(){
  echoinfo "检查必要工具..."
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    echoerr "未找到 curl 或 wget，请先安装其中一个。"
    exit 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    echoerr "未找到 tar，请先安装 tar。"
    exit 1
  fi
  echoinfo "使用下载器: $DOWNLOADER"
}

# 从 GitHub API 获取最新 release 中的 linux_amd64 资产下载地址
get_latest_asset_url(){
  echoinfo "从 GitHub 获取最新 release 信息..."
  if [ "$DOWNLOADER" = "curl" ]; then
    json=$(curl -sL "$GITHUB_API")
  else
    json=$(wget -qO- "$GITHUB_API")
  fi

  # 尝试提取名包含 linux_amd64 且以 .tar.gz 结尾的 browser_download_url（不依赖 jq）
  asset_url=$(echo "$json" | grep -Eo '"browser_download_url":[^,]+' \
              | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
              | grep "$ARCH_WANTED" | grep -E "\.tar\.gz$" | head -n1 || true)

  if [ -z "$asset_url" ]; then
    echoerr "未能从 GitHub API 获取到 $ARCH_WANTED 的下载地址，请检查网络或 GitHub API 限制。"
    exit 1
  fi
  echoinfo "找到最新资产: $asset_url"
}

# 下载并解压
download_and_extract(){
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"
  echoinfo "下载到临时目录: $TMPDIR"
  archive_name="${asset_url##*/}"
  echoinfo "开始下载 $archive_name ..."
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -L -o "$archive_name" "$asset_url"
  else
    wget -q -O "$archive_name" "$asset_url"
  fi
  echoinfo "下载完成，开始解压..."
  mkdir -p frp_extracted
  tar -xzf "$archive_name" -C frp_extracted
  # 解压通常会创建形如 frp_0.xx_linux_amd64 目录
  extracted_dir=$(find frp_extracted -maxdepth 1 -type d ! -path frp_extracted | head -n1)
  if [ -z "$extracted_dir" ]; then
    # 也可能是直接在当前目录
    extracted_dir=$(find frp_extracted -type d | head -n1)
  fi
  if [ -z "$extracted_dir" ]; then
    echoerr "解压失败或未找到解压目录。"
    exit 1
  fi
  echoinfo "解压目录: $extracted_dir"
}

# 将 frpc、frps 移动至 /usr/bin 并处理配置文件
install_binaries_and_configs(){
  echoinfo "安装二进制文件和配置..."
  mkdir -p "$BIN_DEST"
  # 在解压目录中搜索 frpc 和 frps
  frp_bin_frpc=$(find "$extracted_dir" -type f -name frpc -print -quit || true)
  frp_bin_frps=$(find "$extracted_dir" -type f -name frps -print -quit || true)

  if [ -n "$frp_bin_frpc" ]; then
    cp -f "$frp_bin_frpc" "$BIN_DEST/"
    chmod +x "$BIN_DEST/frpc"
    echoinfo "已安装 frpc -> $BIN_DEST/frpc"
  else
    echowarn "未找到 frpc 二进制，跳过。" 
  fi
  if [ -n "$frp_bin_frps" ]; then
    cp -f "$frp_bin_frps" "$BIN_DEST/"
    chmod +x "$BIN_DEST/frps"
    echoinfo "已安装 frps -> $BIN_DEST/frps"
  else
    echowarn "未找到 frps 二进制，跳过。"
  fi

  # 处理配置：把目录下的 *.ini, *.toml, frpc.ini, frps.ini 移到 /etc/frp
  mkdir -p "$ETC_DIR"
  # 兼容不同文件名
  shopt -s nullglob 2>/dev/null || true
  for cfg in $(find "$extracted_dir" -maxdepth 2 -type f \( -name "*.toml" -o -name "*.ini" -o -name "frps*" -o -name "frpc*" \) -print); do
    # 只移动文件且不覆盖用户已有配置（若不存在则移动）
    base="$(basename "$cfg")"
    if [ ! -f "$ETC_DIR/$base" ]; then
      cp -f "$cfg" "$ETC_DIR/$base"
      echoinfo "已安装配置样例 -> $ETC_DIR/$base"
    else
      echowarn "$ETC_DIR/$base 已存在，保留原文件。"
    fi
  done
  echoinfo "清理下载文件..."
  # 删除 archive 和解压目录
  rm -f "$TMPDIR/$archive_name" || true
}

# 创建 systemd unit 文件
create_systemd_units(){
  echoinfo "创建 systemd 服务单元..."
  # frps.service
  if [ -x "$BIN_DEST/frps" ]; then
    cat >/etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp server (frps)
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    echoinfo "已创建 /etc/systemd/system/frps.service"
    systemctl daemon-reload || true
    systemctl enable --now frps.service || echowarn "启用 frps 服务失败，可能需要手动 systemctl enable --now frps.service"
  fi

  # frpc.service
  if [ -x "$BIN_DEST/frpc" ]; then
    cat >/etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=frp client (frpc)
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    echoinfo "已创建 /etc/systemd/system/frpc.service"
    systemctl daemon-reload || true
    systemctl enable --now frpc.service || echowarn "启用 frpc 服务失败，可能需要手动 systemctl enable --now frpc.service"
  fi
}

# 创建 OpenWrt /etc/init.d 脚本
create_openwrt_inits(){
  echoinfo "创建 OpenWrt init 脚本 (/etc/init.d/...)..."
  # frps
  if [ -x "$BIN_DEST/frps" ]; then
    cat >/etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
# frps init script for OpenWrt
START=99
STOP=10
USE_PROCD=1
PROG=/usr/bin/frps
CONF=/etc/frp/frps.toml
start() {
  [ -x "$PROG" ] || return 1
  echo "Starting frps..."
  start-stop-daemon -S -b -x "$PROG" -- -c "$CONF"
}
stop() {
  echo "Stopping frps..."
  start-stop-daemon -K -x "$PROG"
}
EOF
    chmod +x /etc/init.d/frps
    /etc/init.d/frps enable 2>/dev/null || true
    /etc/init.d/frps start 2>/dev/null || echowarn "启动 frps 失败"
    echoinfo "已创建 /etc/init.d/frps"
  fi

  # frpc
  if [ -x "$BIN_DEST/frpc" ]; then
    cat >/etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
# frpc init script for OpenWrt
START=99
STOP=10
USE_PROCD=1
PROG=/usr/bin/frpc
CONF=/etc/frp/frpc.toml
start() {
  [ -x "$PROG" ] || return 1
  echo "Starting frpc..."
  start-stop-daemon -S -b -x "$PROG" -- -c "$CONF"
}
stop() {
  echo "Stopping frpc..."
  start-stop-daemon -K -x "$PROG"
}
EOF
    chmod +x /etc/init.d/frpc
    /etc/init.d/frpc enable 2>/dev/null || true
    /etc/init.d/frpc start 2>/dev/null || echowarn "启动 frpc 失败"
    echoinfo "已创建 /etc/init.d/frpc"
  fi
}

# 将当前脚本复制到目标可执行路径并删除原始脚本（若可行）
deploy_self_and_cleanup(){
  target=""
  if [ "$SYSTEM" = "openwrt" ]; then
    target="/usr/sbin/$PROG_NAME"
  else
    target="/usr/local/bin/$PROG_NAME"
  fi
  echoinfo "正在将脚本复制到 $target ..."
  if [ ! -d "$(dirname "$target")" ]; then
    mkdir -p "$(dirname "$target")"
  fi

  # 尝试复制当前脚本文件
  # $SELF_PATH 可能为 "-bash" 等（当通过 curl|sh -s 时），因此尽量尝试几种来源
  if [ -f "$SELF_PATH" ] && cp -f "$SELF_PATH" "$target"; then
    chmod +x "$target"
    echoinfo "脚本已复制到 $target"
    # 如果原始位于 /root 或为具体路径，尝试删除
    if [ "$SELF_PATH" != "$target" ] && [ -f "$SELF_PATH" ]; then
      echoinfo "尝试删除原始脚本 $SELF_PATH"
      rm -f "$SELF_PATH" || true
    fi
  else
    # 尝试 /root/frp.sh
    if [ -f "/root/$PROG_NAME" ] && cp -f "/root/$PROG_NAME" "$target"; then
      chmod +x "$target"
      echoinfo "已复制 /root/$PROG_NAME -> $target 并尝试删除原始"
      rm -f "/root/$PROG_NAME" || true
    else
      echowarn "未能复制脚本到 $target。请手动将脚本复制到目标目录并 chmod +x。"
    fi
  fi
}

# 管理菜单（frps/frpc: start/stop/restart/status/logs）
manage_menu(){
  while true; do
    echo
    echo "==== FRP 管理 ===="
    echo "1) 管理 frps"
    echo "2) 管理 frpc"
    echo "0) 返回上级菜单 / 退出"
    read -p "请选择: " m
    case "$m" in
      1) service_manage "frps";;
      2) service_manage "frpc";;
      0) break;;
      *) echowarn "无效输入";;
    esac
  done
}

service_manage(){
  name="$1"
  while true; do
    echo
    echo "---- 管理 $name ----"
    echo "1) 启动"
    echo "2) 停止"
    echo "3) 重启"
    echo "4) 查看状态"
    echo "5) 查看日志 (仅适用于 systemd/journal)"
    echo "0) 返回"
    read -p "请选择: " op
    case "$op" in
      1)
        if [ "$SYSTEM" = "debian" ]; then systemctl start "$name".service || echowarn "启动失败"; else /etc/init.d/"$name" start || echowarn "启动失败"; fi;;
      2)
        if [ "$SYSTEM" = "debian" ]; then systemctl stop "$name".service || echowarn "停止失败"; else /etc/init.d/"$name" stop || echowarn "停止失败"; fi;;
      3)
        if [ "$SYSTEM" = "debian" ]; then systemctl restart "$name".service || echowarn "重启失败"; else /etc/init.d/"$name" restart || echowarn "重启失败"; fi;;
      4)
        if [ "$SYSTEM" = "debian" ]; then systemctl status "$name".service --no-pager || true; else ps aux | grep "$name" | grep -v grep || echo "未检测到进程"; fi;;
      5)
        if [ "$SYSTEM" = "debian" ]; then journalctl -u "$name".service -n 200 --no-pager || true; else
          # OpenWrt: 若存在 /var/log/<name>.log 显示，否则提示
          if [ -f "/var/log/$name.log" ]; then tail -n 200 /var/log/"$name".log; else
            echowarn "OpenWrt 上可能没有独立日志文件。请检查 /var/log 或使用 logread。"; logread | tail -n 200
          fi
        fi;;
      0) break;;
      *) echowarn "无效输入";;
    esac
  done
}

# 卸载操作
uninstall_all(){
  echo
  echowarn "！！将要执行卸载：这会停止并删除 frp 二进制、配置、服务单元以及脚本本体。"
  read -p "确认卸载并删除所有 frp 文件？(yes/[no]) " confirm
  if [ "$confirm" != "yes" ]; then
    echoinfo "已取消卸载。"
    return
  fi

  # 停止服务
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

  # 删除二进制
  rm -f "$BIN_DEST/frps" "$BIN_DEST/frpc"
  # 删除配置目录
  rm -rf "$ETC_DIR"
  # 删除可能的日志
  rm -f /var/log/frps.log /var/log/frpc.log /var/log/frp.log

  # 删除自带脚本
  if [ "$SYSTEM" = "openwrt" ]; then
    target="/usr/sbin/$PROG_NAME"
  else
    target="/usr/local/bin/$PROG_NAME"
  fi
  echoinfo "尝试删除脚本 $target ..."
  rm -f "$target" || true
  # 尝试删除 /root 下的拷贝
  rm -f /root/"$PROG_NAME" || true

  echoinfo "卸载完成。"
}

# 主菜单
main_menu(){
  while true; do
    echo
    echo "====== frp 安装/管理脚本 ======"
    echo "1) 安装 frp (下载最新 $ARCH_WANTED 并创建服务)"
    echo "2) 管理 frp (启动/停止/重启/日志)"
    echo "3) 卸载 frp (包括二进制、配置、服务、脚本)"
    echo "0) 退出"
    read -p "请选择: " opt
    case "$opt" in
      1)
        detect_system
        check_tools
        get_latest_asset_url
        download_and_extract
        install_binaries_and_configs
        if [ "$SYSTEM" = "debian" ]; then
          create_systemd_units
        else
          create_openwrt_inits
        fi
        deploy_self_and_cleanup
        echoinfo "安装完成。请检查并编辑配置文件位于 $ETC_DIR（例如 frps.toml / frpc.toml）后再启动服务。"
        ;;
      2)
        if [ -z "$SYSTEM" ]; then detect_system; fi
        manage_menu
        ;;
      3)
        if [ -z "$SYSTEM" ]; then detect_system; fi
        uninstall_all
        ;;
      0) echoinfo "退出"; exit 0;;
      *) echowarn "无效输入";;
    esac
  done
}

# 自动检测 arch 并提示
arch_check(){
  arch=$(uname -m || echo "unknown")
  echoinfo "检测到机器架构: $arch"
  if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
    echowarn "你当前机器并不是 x86_64 (amd64)，但脚本将下载 linux_amd64 构建。该二进制可能无法运行。"
    read -p "仍要继续下载并安装 linux_amd64 吗？(yes/[no]) " c
    if [ "$c" != "yes" ]; then
      echoinfo "取消操作。"
      exit 1
    fi
  fi
}

# 如果通过直接运行脚本（非交互）也能执行主菜单
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # 被 source 时不自动运行
  return 0 2>/dev/null || true
fi

# 开始
arch_check
main_menu
