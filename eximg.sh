#!/bin/bash

# =========================================================
# 脚本名称: eximg.sh
# 功能: OpenWrt 镜像离线扩容 (自动修复GPT，防止卡死)
# 用法: sudo ./eximg.sh <镜像文件名> <目标大小GB>
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 1. 权限与参数检查
if [ "$(id -u)" != "0" ]; then
   echo -e "${RED}[Error] 必须使用 sudo 或 root 权限运行！${NC}"
   exit 1
fi

INPUT_FILE="$1"
TARGET_SIZE_GB="$2"

if [ -z "$INPUT_FILE" ] || [ -z "$TARGET_SIZE_GB" ]; then
    echo "用法: sudo ./eximg.sh <镜像文件名> <目标大小GB>"
    echo "示例: sudo ./eximg.sh openwrt-x86.img.gz 10"
    exit 1
fi

# 2. 依赖检查 (自动安装 gdisk)
REQUIRED_TOOLS="parted losetup gunzip sgdisk"
echo -e "${GREEN}[检查环境] 正在检查依赖工具...${NC}"

for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo -e "${RED}[警告] 未找到 $tool，尝试自动安装...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y gdisk parted
        else
            echo -e "${RED}[错误] 无法自动安装。请手动执行: apt install gdisk parted${NC}"
            exit 1
        fi
    fi
done

# 3. 准备工作文件
WORK_FILE="$INPUT_FILE"

if [[ "$INPUT_FILE" == *.gz ]]; then
    EXTRACTED_NAME="${INPUT_FILE%.gz}-resized.img"
    echo -e "${GREEN}[1/5] 正在解压镜像...${NC}"
    gunzip -c "$INPUT_FILE" > "$EXTRACTED_NAME"
    WORK_FILE="$EXTRACTED_NAME"
else
    WORK_FILE="${INPUT_FILE%.*}-resized.img"
    echo -e "${GREEN}[1/5] 正在创建副本...${NC}"
    cp "$INPUT_FILE" "$WORK_FILE"
fi

# 4. 物理扩容
echo -e "${GREEN}[2/5] 正在扩展文件体积到 ${TARGET_SIZE_GB}GB...${NC}"
truncate -s "${TARGET_SIZE_GB}G" "$WORK_FILE"

# 5. 挂载 Loop 设备
echo -e "${GREEN}[3/5] 正在挂载虚拟磁盘...${NC}"
LOOP_DEV=$(losetup -P -f --show "$WORK_FILE")
if [ -z "$LOOP_DEV" ]; then
    echo -e "${RED}[错误] 挂载失败。${NC}"
    exit 1
fi

# 6. 修复 GPT 表 (使用 sgdisk -e 自动移动备份头，避免交互卡死)
echo -e "${GREEN}[4/5] 正在修复 GPT 分区表 (sgdisk)...${NC}"
sgdisk -e "$LOOP_DEV" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}[错误] GPT 修复失败！${NC}"
    losetup -d "$LOOP_DEV"
    exit 1
fi

# 7. 扩展分区 (将第2分区拉满)
echo -e "${GREEN}[5/5] 正在扩展第 2 分区...${NC}"
parted -s "$LOOP_DEV" resizepart 2 100%

# 8. 清理
losetup -d "$LOOP_DEV"

echo -e "\n======================================================="
echo -e "${GREEN}✅ 扩容成功！${NC}"
echo -e "新文件: ${WORK_FILE}"
echo -e "大小: $(du -h $WORK_FILE | awk '{print $1}')"
echo -e "用法: 使用 dd 或 PhysDiskWrite 将该文件刷入硬盘即可。"
echo -e "======================================================="
