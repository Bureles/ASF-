#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行： sudo bash install_asf.sh"
  exit 1
fi

ASF_VERSION="6.1.7.3"
ASF_URL="https://github.com/JustArchiNET/ArchiSteamFarm/releases/download/${ASF_VERSION}/ASF-linux-x64.zip"
INSTALL_DIR="/root/ArchiSteamFarm"

echo "[1/5] 安装依赖..."
apt-get update -qq
apt-get install -y -qq wget unzip openssl

echo "[2/5] 下载 ASF ${ASF_VERSION}..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
wget -q --show-progress "$ASF_URL" -O ASF-linux-x64.zip

echo "[3/5] 解压并赋权..."
unzip -qo ASF-linux-x64.zip
rm -f ASF-linux-x64.zip
chmod +x ArchiSteamFarm

echo "[4/5] 生成配置..."
IPC_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

mkdir -p config

cat > config/IPC.config <<'EOF'
{
  "Kestrel": {
    "Endpoints": {
      "HTTP": {
        "Url": "http://*:1242"
      }
    }
  }
}
EOF

cat > config/ASF.json <<EOF
{
  "Headless": true,
  "WebServer": true,
  "IP": "0.0.0.0",
  "Port": 1242,
  "IPCPassword": "${IPC_PASSWORD}"
}
EOF

echo "[5/5] 注册 systemd 服务..."
cat > /etc/systemd/system/asf.service <<EOF
[Unit]
Description=ArchiSteamFarm service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/ArchiSteamFarm
Restart=on-failure
RestartSec=5
KillMode=process
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asf.service
systemctl start asf.service

echo "==================================="
echo "ASF ${ASF_VERSION} 安装完成"
echo "IPC 密码: ${IPC_PASSWORD}"
echo "访问地址: http://服务器IP:1242"
echo "查看日志: journalctl -u asf -f"
echo "==================================="
