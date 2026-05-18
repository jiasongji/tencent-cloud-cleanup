#!/bin/bash
# ================================================================
# 一键远程清理腾讯云服务器
# ================================================================
# 用途：从本地一键清理远程腾讯云服务器上的所有云盾组件
# 使用：bash remote_cleanup.sh <IP> [SSH端口] [用户名]
# 示例：bash remote_cleanup.sh 81.70.248.191
#       bash remote_cleanup.sh 81.70.248.191 22 root
# ================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

HOST="${1:?用法: $0 <IP> [SSH端口] [用户名]}"
PORT="${2:-22}"
USER="${3:-root}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${GREEN}=== 远程清理腾讯云服务器 ===${NC}"
echo "目标: ${USER}@${HOST}:${PORT}"
echo ""

# 检查依赖
for cmd in ssh scp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}错误: 需要安装 $cmd${NC}"
        exit 1
    fi
done

# 检查脚本是否存在
if [ ! -f "$SCRIPT_DIR/remove_tencent_cloud.sh" ]; then
    echo -e "${RED}错误: 找不到 remove_tencent_cloud.sh${NC}"
    echo "请确保该文件与 $0 在同一目录下"
    exit 1
fi

# 测试连接
echo "测试 SSH 连接..."
if ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$PORT" "${USER}@${HOST}" "echo ok" >/dev/null 2>&1; then
    echo -e "${RED}错误: 无法连接到 ${USER}@${HOST}:${PORT}${NC}"
    echo "请检查 IP、端口、用户名和密码/密钥是否正确"
    exit 1
fi
echo -e "${GREEN}连接成功${NC}"
echo ""

# 上传脚本
echo "上传清理脚本..."
scp -o StrictHostKeyChecking=accept-new -P "$PORT" "$SCRIPT_DIR/remove_tencent_cloud.sh" "${USER}@${HOST}:/tmp/remove_tencent_cloud.sh"
echo -e "${GREEN}上传完成${NC}"
echo ""

# 执行
echo "执行清理脚本..."
echo "------------------------------------------------------------"
ssh -o StrictHostKeyChecking=accept-new -p "$PORT" -t "${USER}@${HOST}" "bash /tmp/remove_tencent_cloud.sh"
echo "------------------------------------------------------------"
echo ""
echo -e "${GREEN}完成！${NC}"

# 可选：上传并运行验证脚本
if [ -f "$SCRIPT_DIR/verify_cleanup.sh" ]; then
    read -p "是否上传并运行验证脚本？(y/n): " verify
    if [ "$verify" = "y" ]; then
        scp -P "$PORT" "$SCRIPT_DIR/verify_cleanup.sh" "${USER}@${HOST}:/tmp/verify_cleanup.sh"
        ssh -p "$PORT" "${USER}@${HOST}" "bash /tmp/verify_cleanup.sh"
    fi
fi

# 清理远程临时文件
ssh -p "$PORT" "${USER}@${HOST}" "rm -f /tmp/remove_tencent_cloud.sh /tmp/verify_cleanup.sh" 2>/dev/null || true
