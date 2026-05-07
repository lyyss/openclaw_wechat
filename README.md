# OpenClaw + 微信接入 完整安装教程

## 环境说明

- 系统：Ubuntu 22.04 / 24.04 (VPS)
- 域名：需要提前解析好 DNS
- 已申请 DeepSeek API Key

---

## 一、安装 Nginx 并申请 SSL 证书

```bash
# 安装 Nginx
apt update -y
apt install -y nginx certbot python3-certbot-nginx

# 申请 SSL 证书（替换成你自己的域名和邮箱）
certbot --nginx -d 你的域名 --email 你的邮箱 --agree-tos --non-interactive
```

---

## 二、配置 Nginx 反代 OpenClaw

```bash
cat > /etc/nginx/sites-available/openclaw << 'NGINXEOF'
server {
    server_name 你的域名;
    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/你的域名/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/你的域名/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if ($host = 你的域名) {
        return 301 https://$host$request_uri;
    }
    listen 80;
    server_name 你的域名;
    return 404;
}
NGINXEOF

ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
nginx -t && systemctl reload nginx
```

---

## 三、安装 Node.js 22（通过 nvm）

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
source ~/.bashrc
nvm install 22
nvm use 22
nvm alias default 22
node --version
```

---

## 四、安装 OpenClaw

```bash
npm install -g openclaw
openclaw --version
```

---

## 五、初始化配置（onboard）

```bash
openclaw onboard --install-daemon
```

按照提示操作：

| 提示 | 选择 |
|------|------|
| Continue? | Yes |
| Setup mode | QuickStart |
| Existing config detected → Config handling | Use existing values（首次安装选 Update values）|
| Model/auth provider | DeepSeek |
| Enter DeepSeek API key | 填入你的 API Key |
| Default model | 选 Enter model，填 `deepseek-chat` |
| Search provider | DuckDuckGo Search |
| Install missing skill dependencies | Skip for now |
| Configure skills now | Yes → Skip for now |
| Enable hooks | Skip for now |
| Show Homebrew install command | No |
| How do you want to hatch your bot | Do this later |

---

## 六、修改 allowedOrigins 配置

```bash
# 修改配置，允许你的域名访问
python3 - << 'EOF'
import json

path = "/root/.openclaw/openclaw.json"
with open(path) as f:
    d = json.load(f)

d.setdefault("gateway", {}).setdefault("controlUi", {})["allowedOrigins"] = [
    "https://你的域名",
    "http://localhost:18789",
    "http://127.0.0.1:18789"
]

with open(path, "w") as f:
    json.dump(d, f, indent=2)

print("完成")
EOF
```

---

## 七、启动 Gateway 服务

```bash
openclaw gateway install
openclaw gateway start
sleep 5
openclaw gateway status
```

---

## 八、首次登录网页控制台

浏览器访问（token 从配置文件获取）：

```bash
# 查看 token
cat /root/.openclaw/openclaw.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['gateway']['auth']['token'])"
```

访问地址：
```
https://你的域名/?token=上面获取的token
```

首次登录出现 `pairing required`，执行：

```bash
# 查看待审批设备
openclaw devices list

# 审批设备（替换 requestId）
openclaw devices approve <requestId>
```

---

## 九、安装微信插件并修复兼容问题

### 9.1 安装插件

```bash
npx -y @tencent-weixin/openclaw-weixin-cli install
openclaw plugins update "openclaw-weixin"
openclaw gateway restart
sleep 5
```

### 9.2 修复 Content-Length bug（必须执行）

OpenClaw 内置的 undici 对 Content-Length 校验严格，需要删除插件里错误的 header：

```bash
sed -i '/"Content-Length"/d' /root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin/dist/src/api/api.js

# 确认删除成功（应该没有输出）
grep "Content-Length" /root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin/dist/src/api/api.js
```

### 9.3 修复 runtime 模块隔离 bug（必须执行）

插件被加载两次导致 runtime 变量不共享，需要将变量挂载到 global：

```bash
node << 'EOF'
const fs = require('fs');
const path = '/root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin/dist/src/runtime.js';
let content = fs.readFileSync(path, 'utf8');

content = content.replace(
  'let pluginRuntime = null;',
  'if (!global.__weixinPluginRuntime) global.__weixinPluginRuntime = null;\nObject.defineProperty(globalThis, "pluginRuntime", { get() { return global.__weixinPluginRuntime; }, set(v) { global.__weixinPluginRuntime = v; } });'
);

fs.writeFileSync(path, content);
console.log('runtime.js 修复完成');
EOF
```

### 9.4 修复 symlink 方向

```bash
rm -f /root/.openclaw/extensions/openclaw-weixin
ln -sf /root/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin /root/.openclaw/extensions/openclaw-weixin
ls -la /root/.openclaw/extensions/openclaw-weixin
```

---

## 十、微信扫码登录

```bash
openclaw gateway restart
sleep 10
openclaw channels login --channel openclaw-weixin
```

终端会显示二维码，用手机微信扫码，然后点确认授权。

出现以下提示说明成功：
```
已将此 OpenClaw 连接到微信。
```

重启 gateway 让微信频道生效：

```bash
openclaw gateway restart
sleep 10
openclaw status
```

确认状态：
```
│ openclaw-weixin │ ON │ OK │ configured │
```

---

## 十一、微信白名单配置（可选）

如果想限制只有特定人可以使用，编辑配置：

```bash
vi /root/.openclaw/openclaw.json
```

在 `channels.openclaw-weixin` 下添加 `allowFrom`（用户的微信 openid）：

```json
"channels": {
  "openclaw-weixin": {
    "allowFrom": ["用户openid1", "用户openid2"],
    "dmPolicy": "open"
  }
}
```

---

## 十二、常用维护命令

```bash
# 查看状态
openclaw status

# 查看实时日志
openclaw logs --follow

# 重启 gateway
openclaw gateway restart

# 更新 OpenClaw
openclaw update

# 查看设备列表
openclaw devices list

# 重新登录微信（token 过期时）
openclaw channels login --channel openclaw-weixin
```

---

## 十三、常见报错对照表

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `origin not allowed` | allowedOrigins 未包含当前域名 | 修改 openclaw.json 加入域名，重启 |
| `control ui requires device identity` | 用 http 访问 | 改用 https:// 访问 |
| `gateway token mismatch` | URL 中 token 错误 | 用 openclaw.json 中的 token |
| `pairing required` | 新浏览器首次访问 | 执行 `devices approve` |
| `TypeError: fetch failed` | Content-Length header bug | 执行第 9.2 步修复 |
| `Weixin runtime initialization timeout` | 模块隔离 bug | 执行第 9.3 步修复 |
| `502 Bad Gateway` | nginx 反代配置丢失 | 重新配置 nginx |
| `暂无法链接到 OpenClaw` | 微信频道未正常启动 | 重启 gateway，检查日志 |
