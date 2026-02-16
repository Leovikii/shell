#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_PATH=$(realpath "$0")
LINK_NAME="/usr/local/bin/subsync"
VENV_DIR="/opt/ffsubsync-venv"
STATE_FILE="/opt/ffsubsync-venv/.installed_by_subsync"

# 记录脚本安装了哪些 apt 包，卸载时只移除这些
record_apt_installed() {
    local pkg="$1"
    if [ -f "$STATE_FILE" ]; then
        grep -qxF "apt:$pkg" "$STATE_FILE" || echo "apt:$pkg" >> "$STATE_FILE"
    fi
}

install_dependencies() {
    echo -e "${GREEN}正在检查系统环境...${NC}"

    sudo apt-get update -qq

    # 安装 ffmpeg（仅在未安装时）
    local ffmpeg_installed_by_us=false
    if ! command -v ffmpeg &> /dev/null; then
        echo -e "${GREEN}正在安装 FFmpeg...${NC}"
        sudo apt-get install -y ffmpeg
        ffmpeg_installed_by_us=true
    fi

    # 安装 python3-venv（创建虚拟环境必需）
    local venv_installed_by_us=false
    if ! dpkg -s python3-venv &> /dev/null 2>&1; then
        echo -e "${GREEN}正在安装 python3-venv...${NC}"
        sudo apt-get install -y python3-venv
        venv_installed_by_us=true
    fi

    # 创建独立的 Python 虚拟环境（完全隔离，不污染系统）
    if [ ! -d "$VENV_DIR" ]; then
        echo -e "${GREEN}正在创建 Python 虚拟环境...${NC}"
        sudo mkdir -p "$VENV_DIR"
        sudo python3 -m venv "$VENV_DIR"
    fi

    # 写入状态文件，记录哪些 apt 包是脚本安装的
    if [ ! -f "$STATE_FILE" ]; then
        sudo touch "$STATE_FILE"
    fi
    $ffmpeg_installed_by_us && record_apt_installed "ffmpeg"
    $venv_installed_by_us && record_apt_installed "python3-venv"

    echo -e "${GREEN}正在安装预编译 Python 包（在虚拟环境中）...${NC}"

    # 在 venv 中安装，完全不影响系统 Python
    sudo "$VENV_DIR/bin/pip" install --upgrade pip setuptools

    # 关键：auditok 必须锁定 0.1.5（纯 Python），>=0.2.0 会拉入 pyaudio 触发 C 编译
    # webrtcvad-wheels 是 webrtcvad 的预编译版本，避免编译 C 扩展
    sudo "$VENV_DIR/bin/pip" install webrtcvad-wheels "auditok==0.1.5"

    # ffsubsync 0.4.31 的完整依赖列表（全部为纯 Python 或有预编译 wheel）
    sudo "$VENV_DIR/bin/pip" install \
        "numpy>=1.12.0" \
        "srt>=3.0.0" \
        "tqdm" \
        "rich" \
        "pysubs2>=1.2.0" \
        "chardet" \
        "charset-normalizer" \
        "ffmpeg-python" \
        "typing_extensions"

    # Python 3.13 以下需要 faust-cchardet
    local py_minor
    py_minor=$("$VENV_DIR/bin/python" -c "import sys; print(sys.version_info.minor)")
    if [ "$py_minor" -lt 13 ]; then
        sudo "$VENV_DIR/bin/pip" install "faust-cchardet"
    fi

    # 安装 ffsubsync 主程序，--no-deps 防止它自动拉依赖触发编译
    sudo "$VENV_DIR/bin/pip" install ffsubsync --no-deps

    # 验证安装
    if "$VENV_DIR/bin/ffs" --help &>/dev/null; then
        echo -e "${GREEN}ffsubsync 安装成功（虚拟环境模式）。${NC}"
    else
        echo -e "${RED}安装失败，请检查错误信息。${NC}"
        return 1
    fi

    # 创建 ffs 命令的全局包装脚本
    sudo tee /usr/local/bin/ffs > /dev/null << 'WRAPPER'
#!/bin/bash
exec /opt/ffsubsync-venv/bin/ffs "$@"
WRAPPER
    sudo chmod +x /usr/local/bin/ffs

    # 创建 subsync 菜单快捷方式
    if [ ! -L "$LINK_NAME" ] && [ ! -f "$LINK_NAME" ]; then
        echo -e "${GREEN}正在创建快捷命令 'subsync'...${NC}"
        sudo ln -sf "$SCRIPT_PATH" "$LINK_NAME"
    fi

    echo -e "${GREEN}安装完成！可通过 'subsync' 命令启动菜单。${NC}"
}

# 从文件名中提取集数编号（支持 S01E03, EP03, E03, 第03集, [03], - 03 等常见格式）
extract_episode() {
    local name="$1"
    local ep=""
    # S01E03 / S1E3
    ep=$(echo "$name" | grep -oiP 'S\d+E(\d+)' | grep -oiP 'E\d+' | grep -oP '\d+' | head -1)
    [ -n "$ep" ] && printf '%d' "$ep" 2>/dev/null && return
    # EP03 / Ep3
    ep=$(echo "$name" | grep -oiP 'EP(\d+)' | grep -oP '\d+' | head -1)
    [ -n "$ep" ] && printf '%d' "$ep" 2>/dev/null && return
    # 第03集 / 第3话
    ep=$(echo "$name" | grep -oP '第(\d+)[集话期回]' | grep -oP '\d+' | head -1)
    [ -n "$ep" ] && printf '%d' "$ep" 2>/dev/null && return
    # [03] / [3]
    ep=$(echo "$name" | grep -oP '\[(\d{1,4})\]' | grep -oP '\d+' | head -1)
    [ -n "$ep" ] && printf '%d' "$ep" 2>/dev/null && return
    # " - 03" / " - 3"（常见于 "Show - 03.mkv" 格式）
    ep=$(echo "$name" | grep -oP '[\s_-]+(\d{1,4})[\s_.\[\]]*(\.|$)' | grep -oP '\d+' | head -1)
    [ -n "$ep" ] && printf '%d' "$ep" 2>/dev/null && return
    return 1
}

# 模糊匹配：为视频找到最佳字幕
# 策略：1.精确前缀匹配 -> 2.集数匹配 -> 3.仅一个字幕时自动配对
find_subtitle() {
    local video_path="$1"
    local dir
    dir=$(dirname "$video_path")
    local video_name
    video_name=$(basename "$video_path")
    local video_base="${video_name%.*}"

    # 收集目录下所有字幕文件
    local -a subs=()
    while IFS= read -r -d '' s; do
        subs+=("$s")
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.srt' -o -iname '*.ass' \) -print0)

    [ ${#subs[@]} -eq 0 ] && return 1

    # 策略1：精确前缀匹配（视频名是字幕名的前缀，或反过来）
    for s in "${subs[@]}"; do
        local sub_name
        sub_name=$(basename "$s")
        local sub_base="${sub_name%.*}"
        if [[ "$sub_base" == "$video_base"* ]] || [[ "$video_base" == "$sub_base"* ]]; then
            echo "$s"
            return 0
        fi
    done

    # 策略2：集数匹配
    local video_ep
    video_ep=$(extract_episode "$video_base") || true
    if [ -n "$video_ep" ]; then
        local -a ep_matches=()
        for s in "${subs[@]}"; do
            local sub_name
            sub_name=$(basename "$s")
            local sub_base="${sub_name%.*}"
            local sub_ep
            sub_ep=$(extract_episode "$sub_base") || true
            if [ -n "$sub_ep" ] && [ "$video_ep" -eq "$sub_ep" ]; then
                ep_matches+=("$s")
            fi
        done
        # 集数唯一匹配
        if [ ${#ep_matches[@]} -eq 1 ]; then
            echo "${ep_matches[0]}"
            return 0
        fi
    fi

    # 策略3：目录下只有一个字幕且只有一个视频时自动配对
    if [ ${#subs[@]} -eq 1 ]; then
        local vid_count
        vid_count=$(find "$dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \) | wc -l)
        if [ "$vid_count" -eq 1 ]; then
            echo "${subs[0]}"
            return 0
        fi
    fi

    return 1
}

process_directory() {
    # 检查是否已安装
    if [ ! -x /usr/local/bin/ffs ]; then
        echo -e "${RED}ffsubsync 尚未安装，请先执行安装。${NC}"
        return
    fi

    echo -e "${GREEN}请输入包含视频和字幕的目录路径：${NC}"
    read -r WORK_DIR
    WORK_DIR="${WORK_DIR/#\~/$HOME}"

    if [ ! -d "$WORK_DIR" ]; then
        echo -e "${RED}目录不存在！${NC}"
        return
    fi

    # ---- 阶段1：扫描并生成匹配列表 ----
    echo ""
    echo -e "${GREEN}正在扫描并匹配文件...${NC}"
    echo ""

    local -a video_list=()
    local -a sub_list=()
    local -a unmatched=()
    local idx=0

    while IFS= read -r -d '' video; do
        local filename
        filename=$(basename "$video")
        local matched_sub
        if matched_sub=$(find_subtitle "$video"); then
            video_list+=("$video")
            sub_list+=("$matched_sub")
            ((idx++))
            printf "  ${GREEN}%2d.${NC} %s\n" "$idx" "$filename"
            printf "      <- %s\n" "$(basename "$matched_sub")"
        else
            unmatched+=("$filename")
        fi
    done < <(find "$WORK_DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \) -print0 | sort -z)

    # 显示未匹配的
    if [ ${#unmatched[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}未匹配到字幕的视频：${NC}"
        for u in "${unmatched[@]}"; do
            echo -e "  ${YELLOW}--${NC} $u"
        done
    fi

    if [ ${#video_list[@]} -eq 0 ]; then
        echo -e "${RED}没有找到可匹配的视频-字幕对。${NC}"
        return
    fi

    # ---- 阶段2：用户确认 ----
    echo ""
    echo "================================================"
    echo -e "共匹配 ${GREEN}${#video_list[@]}${NC} 对，未匹配 ${YELLOW}${#unmatched[@]}${NC} 个"
    echo "================================================"
    echo -e "${YELLOW}确认开始同步？(y/N)${NC}"
    read -r confirm
    [[ "$confirm" != [yY] ]] && echo "已取消。" && return

    # ---- 阶段3：执行同步（带进度条和 ETA） ----
    local count=0
    local fail=0
    local total=${#video_list[@]}
    local start_time
    start_time=$(date +%s)

    for i in "${!video_list[@]}"; do
        local video="${video_list[$i]}"
        local subtitle="${sub_list[$i]}"
        local video_name
        video_name=$(basename "$video")
        local sub_ext="${subtitle##*.}"
        local video_base="${video_name%.*}"
        local dir
        dir=$(dirname "$video")

        local temp_sub="${dir}/${video_base}.temp.${sub_ext}"
        local output_sub="${dir}/${video_base}.${sub_ext}"

        # 计算进度
        local done_count=$((i + 1))
        local pct=$((done_count * 100 / total))
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        # 计算 ETA
        local eta_str="--"
        if [ "$total" -eq 1 ]; then
            eta_str="--"
        elif [ "$i" -gt 0 ] && [ "$elapsed" -gt 0 ]; then
            local avg=$((elapsed / i))
            local remaining=$(( avg * (total - i) ))
            if [ "$remaining" -ge 60 ]; then
                eta_str="$((remaining / 60))分$((remaining % 60))秒"
            else
                eta_str="${remaining}秒"
            fi
        fi

        # 绘制进度条（宽度30字符）
        local bar_width=30
        local filled=$((pct * bar_width / 100))
        local empty=$((bar_width - filled))
        local bar=""
        for ((b=0; b<filled; b++)); do bar+="█"; done
        for ((b=0; b<empty; b++)); do bar+="░"; done

        # 输出进度行（覆盖式）+ 文件名（换行）
        printf "\r  ${GREEN}%s${NC} %3d%% [%d/%d] 剩余: %s" "$bar" "$pct" "$done_count" "$total" "$eta_str"
        echo ""
        echo -e "  处理: ${GREEN}${video_name}${NC}"

        if ffs "$video" -i "$subtitle" -o "$temp_sub"; then
            mv "$temp_sub" "$output_sub"
            echo -e "  ${GREEN}-> 同步成功${NC}"
            ((count++))
        else
            rm -f "$temp_sub"
            echo -e "  ${RED}-> 同步失败${NC}"
            ((fail++))
        fi
    done

    # 最终耗时
    local end_time
    end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    local time_str
    if [ "$total_time" -ge 60 ]; then
        time_str="$((total_time / 60))分$((total_time % 60))秒"
    else
        time_str="${total_time}秒"
    fi

    echo ""
    echo "================================================"
    echo -e "${GREEN}批量处理完成。成功: ${count}，失败: ${fail}，耗时: ${time_str}${NC}"
}

uninstall_tool() {
    echo -e "${YELLOW}确定要卸载 ffsubsync 及其相关组件吗？(y/N)${NC}"
    read -r confirm
    [[ "$confirm" != [yY] ]] && echo "已取消。" && return

    echo -e "${RED}正在卸载...${NC}"

    # 1. 删除整个虚拟环境目录（所有 pip 包一次性清除，不影响系统）
    if [ -d "$VENV_DIR" ]; then
        # 读取状态文件，确定哪些 apt 包需要卸载
        local apt_pkgs_to_remove=()
        if [ -f "$STATE_FILE" ]; then
            while IFS= read -r line; do
                if [[ "$line" == apt:* ]]; then
                    apt_pkgs_to_remove+=("${line#apt:}")
                fi
            done < "$STATE_FILE"
        fi

        sudo rm -rf "$VENV_DIR"
        echo -e "${GREEN}已删除虚拟环境。${NC}"

        # 2. 仅卸载由本脚本安装的 apt 包
        if [ ${#apt_pkgs_to_remove[@]} -gt 0 ]; then
            echo -e "${GREEN}正在卸载由本脚本安装的系统包: ${apt_pkgs_to_remove[*]}${NC}"
            sudo apt-get remove -y "${apt_pkgs_to_remove[@]}"
            sudo apt-get autoremove -y
        fi
    fi

    # 3. 删除 ffs 包装脚本
    [ -f /usr/local/bin/ffs ] && sudo rm /usr/local/bin/ffs && echo "已删除 ffs 命令。"

    # 4. 删除 subsync 快捷方式
    [ -L "$LINK_NAME" ] && sudo rm "$LINK_NAME" && echo "已删除 subsync 快捷方式。"

    # 5. 清理 pip 缓存
    sudo rm -rf /root/.cache/pip 2>/dev/null

    echo -e "${GREEN}卸载完成。系统已恢复干净状态。${NC}"
}

show_menu() {
    while true; do
        clear
        echo "========================================"
        echo "   字幕自动同步工具 (免编译版)"
        echo "========================================"
        echo "1. 安装 ffsubsync（预编译模式）"
        echo "2. 批量同步字幕（指定目录）"
        echo "3. 卸载"
        echo "4. 退出"
        echo "========================================"
        read -rp "请选择 [1-4]: " choice

        case $choice in
            1)
                install_dependencies
                read -rp "按回车键继续..."
                ;;
            2)
                process_directory
                read -rp "按回车键继续..."
                ;;
            3)
                uninstall_tool
                read -rp "按回车键继续..."
                ;;
            4)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 命令行参数支持
case "${1:-}" in
    install)   install_dependencies ;;
    uninstall) uninstall_tool ;;
    sync)      process_directory ;;
    *)         show_menu ;;
esac
