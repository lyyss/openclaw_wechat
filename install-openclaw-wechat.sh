#!/bin/bash
# ============================================================
# OpenClaw + 微信 一键安装脚本
# 适用：Ubuntu 22.04 / 24.04 VPS
# 用法：bash install-openclaw-wechat.sh
# ============================================================

set -e

# -------- 配置区（必须修改）--------
DOMAIN="你的域名"                          # 你的域名，如 rn.958821.xyz
EMAIL="你的邮箱"                            # 申请 SSL 的邮箱
DEEPSEEK_API_KEY="你的DeepSeek API Key"    # DeepSeek API Key
# ------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "======================================"
echo "  OpenClaw + 微信 一键安装脚本"
echo "  域名: $DOMAIN"
echo "======================================"

# 检查配置
if [ "$DOMAIN" = "你的域名" ] || [ "$EMAIL" = "你的邮箱" ] || [ "$DEEPSEEK_API_KEY" = "你的DeepSeek API Key" ]; then
  error "请先修改脚本顶部的配置区（DOMAIN、EMAIL、DEEPSEEK_API_KEY）"
fi

# -------- 1. 安装 Nginx + SSL --------
info "[1/8] 安装 Nginx 并申请 SSL 证书..."
apt update -y
apt install -y nginx certbot python3-certbot-nginx

if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  info "  SSL 证书已存在，跳过"
else
  certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive
  info "  SSL 证书申请完成"
fi

# -------- 2. 配置 Nginx 反代 --------
info "[2/8] 配置 Nginx 反代..."
cat > /etc/nginx/sites-available/openclaw << NGINXEOF
server {
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }
    listen 80;
    server_name $DOMAIN;
    return 404;
}
NGINXEOF

ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
nginx -t && systemctl reload nginx
info "  Nginx 配置完成"

# -------- 3. 安装 Node.js 22 --------
info "[3/8] 安装 Node.js 22..."
if command -v nvm &>/dev/null && nvm ls 22 &>/dev/null; then
  info "  Node.js 22 已安装，跳过"
  nvm use 22
else
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install 22
  nvm use 22
  nvm alias default 22
fi
info "  Node.js 版本: $(node --version)"

# -------- 4. 安装 OpenClaw --------
info "[4/8] 安装 OpenClaw..."
npm install -g openclaw
info "  OpenClaw 版本: $(openclaw --version)"

# -------- 5. 写入基础配置 --------
info "[5/8] 写入基础配置..."
mkdir -p /root/.openclaw

# 先运行 gateway 生成初始配置
openclaw gateway run --allow-unconfigured &
GW_PID=$!
sleep 8
kill $GW_PID 2>/dev/null || true
sleep 2

# 写入配置
python3 - << PYEOF
import json, os, secrets

path = "/root/.openclaw/openclaw.json"

# 读取已有配置或创建新的
if os.path.exists(path):
    with open(path) as f:
        d = json.load(f)
else:
    d = {}

# 设置 DeepSeek 模型
d.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})["primary"] = "deepseek/deepseek-chat"
d.setdefault("models", {}).setdefault("providers", {})["deepseek"] = {
    "baseUrl": "https://api.deepseek.com",
    "api": "openai-completions"
}
d.setdefault("auth", {}).setdefault("profiles", {})["deepseek:default"] = {
    "provider": "deepseek",
    "mode": "api_key",
    "apiKey": "$DEEPSEEK_API_KEY"
}

# 设置 allowedOrigins
d.setdefault("gateway", {}).setdefault("controlUi", {})["allowedOrigins"] = [
    "https://$DOMAIN",
    "http://localhost:18789",
    "http://127.0.0.1:18789"
]
d["gateway"]["bind"] = "lan"

with open(path, "w") as f:
    json.dump(d, f, indent=2)

print("配置写入完成")
PYEOF

# -------- 6. 启动 Gateway 服务 --------
info "[6/8] 启动 Gateway 服务..."
openclaw gateway install
openclaw gateway start
sleep 10
openclaw gateway status | head -5
info "  Gateway 启动完成"

# -------- 7. 安装微信插件 --------
info "[7/8] 安装微信插件..."

# 安装插件
npx -y @tencent-weixin/openclaw-weixin-cli install || true
openclaw plugins update "openclaw-weixin" || true

# 修复 Content-Length bug
PLUGIN_API="/root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin/dist/src/api/api.js"
if [ -f "$PLUGIN_API" ]; then
  sed -i '/"Content-Length"/d' "$PLUGIN_API"
  info "  Content-Length bug 已修复"
else
  warn "  插件文件未找到，跳过 Content-Length 修复"
fi

# 修复 runtime 模块隔离 bug
PLUGIN_RUNTIME="/root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin/dist/src/runtime.js"
if [ -f "$PLUGIN_RUNTIME" ]; then
  node << 'JSEOF'
const fs = require('fs');
const path = '/root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin/dist/src/runtime.js';
let content = fs.readFileSync(path, 'utf8');
if (!content.includes('__weixinPluginRuntime')) {
  content = content.replace(
    'let pluginRuntime = null;',
    'if (!global.__weixinPluginRuntime) global.__weixinPluginRuntime = null;\nObject.defineProperty(globalThis, "pluginRuntime", { get() { return global.__weixinPluginRuntime; }, set(v) { global.__weixinPluginRuntime = v; } });'
  );
  fs.writeFileSync(path, content);
  console.log('runtime.js 修复完成');
} else {
  console.log('runtime.js 已修复，跳过');
}
JSEOF
  info "  runtime 模块隔离 bug 已修复"
else
  warn "  runtime.js 未找到，跳过修复"
fi

# 修复 symlink 方向
rm -f /root/.openclaw/extensions/openclaw-weixin
ln -sf /root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin /root/.openclaw/extensions/openclaw-weixin
info "  symlink 修复完成"

# -------- 8. 重启并扫码登录 --------
info "[8/8] 重启 Gateway..."
openclaw gateway restart
sleep 10

# 获取 token
TOKEN=$(python3 -c "import json; d=json.load(open('/root/.openclaw/openclaw.json')); print(d.get('gateway',{}).get('auth',{}).get('token','未找到'))" 2>/dev/null || echo "未找到")

echo ""
echo "======================================"
echo -e "  ${GREEN}安装完成！${NC}"
echo ""
echo "  网页访问地址："
echo -e "  ${GREEN}https://$DOMAIN/?token=$TOKEN${NC}"
echo ""
echo "  首次登录步骤："
echo "  1. 浏览器打开上面的地址"
echo "  2. 若提示 pairing required，执行："
echo "     openclaw devices list"
echo "     openclaw devices approve <requestId>"
echo ""
echo "  微信登录步骤："
echo "  执行以下命令并用手机微信扫码："
echo -e "  ${GREEN}openclaw channels login --channel openclaw-weixin${NC}"
echo ""
echo "  查看状态："
echo "  openclaw status"
echo "  openclaw logs --follow"
echo "======================================"
