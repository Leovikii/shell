#!/bin/bash

clean_legacy() {
    systemctl disable --now disable-usb-wakeup.service disable-all-wakeup.service wol.service > /dev/null 2>&1
    rm -f /etc/systemd/system/disable-usb-wakeup.service
    rm -f /etc/systemd/system/disable-all-wakeup.service
    rm -f /etc/systemd/system/wol.service
}

clean_all() {
    clean_legacy
    systemctl disable --now acpi-wakeup.service > /dev/null 2>&1
    rm -f /etc/systemd/system/acpi-wakeup.service
    rm -f /etc/udev/rules.d/90-usb-wakeup.rules
    rm -f /etc/udev/rules.d/81-wol.rules
    systemctl daemon-reload
    udevadm control --reload-rules
    udevadm trigger
    echo "所有相关规则和残留服务已彻底清理，系统恢复默认状态。"
    echo ""
}

setup_usb() {
    clean_legacy
    mapfile -t usb_devices < <(lsusb)

    echo "================================="
    for i in "${!usb_devices[@]}"; do
        echo "[$i] ${usb_devices[$i]}"
    done
    echo "================================="

    read -p "请输入需要允许唤醒系统的设备序号 (直接回车留空则禁用所有外设唤醒): " target_idx

    if [ -z "$target_idx" ]; then
        echo "已留空，将彻底禁用所有 USB 及外设唤醒。"

        cat << EOF > /etc/udev/rules.d/90-usb-wakeup.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/wakeup}="disabled"
EOF

        cat << 'EOF' > /etc/systemd/system/acpi-wakeup.service
[Unit]
Description=Disable ALL ACPI wakeups

[Service]
Type=oneshot
ExecStart=/bin/sh -c "awk '/enabled/ {print \$\$1}' /proc/acpi/wakeup | while read dev; do echo \$\$dev > /proc/acpi/wakeup; done"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    else
        target_line="${usb_devices[$target_idx]}"
        TARGET_VID=$(echo "$target_line" | awk '{print $6}' | cut -d: -f1)
        TARGET_PID=$(echo "$target_line" | awk '{print $6}' | cut -d: -f2)

        echo "将仅允许设备 ${TARGET_VID}:${TARGET_PID} 唤醒系统。"

        cat << EOF > /etc/udev/rules.d/90-usb-wakeup.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}!="09", ATTR{power/wakeup}="disabled"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${TARGET_VID}", ATTR{idProduct}=="${TARGET_PID}", ATTR{power/wakeup}="enabled"
EOF

        cat << 'EOF' > /etc/systemd/system/acpi-wakeup.service
[Unit]
Description=Disable ACPI wakeups except USB

[Service]
Type=oneshot
ExecStart=/bin/sh -c "awk '/enabled/ {print \$\$1}' /proc/acpi/wakeup | grep -v 'XH' | while read dev; do echo \$\$dev > /proc/acpi/wakeup; done"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable acpi-wakeup.service
    systemctl restart acpi-wakeup.service

    udevadm control --reload-rules
    udevadm trigger

    echo "外设唤醒设置已更新并应用。"
    echo ""
}

setup_wol() {
    mapfile -t net_interfaces < <(ip -br link | awk '$1 !~ "^(lo|vir|wl|docker|br|veth)" {print $1}')

    if [ ${#net_interfaces[@]} -eq 0 ]; then
        echo "未检测到符合条件的物理有线网卡接口。"
        echo ""
        return
    fi

    echo "================================="
    for i in "${!net_interfaces[@]}"; do
        echo "[$i] ${net_interfaces[$i]}"
    done
    echo "================================="

    read -p "请输入需要开启 WOL 的有线网卡序号: " iface_idx
    INTERFACE="${net_interfaces[$iface_idx]}"

    if [ -z "$INTERFACE" ]; then
        echo "无效的网卡选择。"
        echo ""
        return
    fi

    if [ -f "/etc/udev/rules.d/81-wol.rules" ]; then
        if grep -q "NAME==\"${INTERFACE}\"" /etc/udev/rules.d/81-wol.rules && grep -q "wol g" /etc/udev/rules.d/81-wol.rules; then
            echo "检测到接口 ${INTERFACE} 的 WOL 已经配置，无需重复设置。"
            echo ""
            return
        fi
    fi

    pacman -S --noconfirm ethtool > /dev/null 2>&1

    cat << EOF > /etc/udev/rules.d/81-wol.rules
ACTION=="add", SUBSYSTEM=="net", NAME=="${INTERFACE}", RUN+="/usr/bin/ethtool -s ${INTERFACE} wol g"
EOF

    udevadm control --reload-rules
    udevadm trigger

    echo "WOL 唤醒设置已启用 (接口: ${INTERFACE})。"
    echo ""
}

while true; do
    echo "================================="
    echo "      系统唤醒管理工具           "
    echo "================================="
    echo "1. 外设唤醒开关 (选择允许唤醒的设备或全禁)"
    echo "2. 网络唤醒开关 (WOL 接口检测与配置)"
    echo "3. 清理所有规则与历史残留 (恢复系统默认)"
    echo "4. 退出"
    echo "================================="
    read -p "请输入选项 [1-4]: " choice

    case $choice in
        1) setup_usb ;;
        2) setup_wol ;;
        3) clean_all ;;
        4) exit 0 ;;
        *) echo "无效输入，请重新选择。" ;;
    esac
done
