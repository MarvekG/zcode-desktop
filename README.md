# ZCode 桌面容器

面向 x86（amd64）/ ARM（arm64）服务器的双架构桌面环境容器：XFCE + VNC/noVNC，内置 ZCode 桌面版（AppImage 原样保留，不做解包安装）和 **Firefox 浏览器**（Mozilla 官方 deb 版，含中文语言包）。容器内以 **root** 运行。ZCode **不随桌面自动启动**，通过桌面图标双击启动。

## 构建本镜像

```bash
# 分别构建到本地 Docker 镜像存储（不需要 push；--load 一次加载一个架构）
docker buildx build --platform linux/amd64 \
  -t zcode-desktop:amd64 --load .
docker buildx build --platform linux/arm64 \
  -t zcode-desktop:arm64 --load .

# 如果 Docker 使用 containerd 镜像存储，也可以一次生成双架构本地镜像索引：
docker buildx build --platform linux/amd64,linux/arm64 \
  -t zcode-desktop:latest --load .

# 构建期走 MITM 代理：把 MITM 根证书作为单个文件放在构建上下文的 certs/mitm-ca.pem，
# 并用 build-arg 传代理。证书在 apt-get update 之前装入构建期系统信任库（bind 挂载进
# 构建过程，不会拷贝进镜像层），同时烘焙为镜像内的 /mitm-ca.pem 供运行期直接使用
docker buildx build --platform linux/amd64 \
  --build-arg HTTP_PROXY=http://user:pass@proxy.example.com:55666 \
  --build-arg HTTPS_PROXY=http://user:pass@proxy.example.com:55666 \
  --build-arg NO_PROXY=localhost,127.0.0.1 \
  -t zcode-desktop:amd64 --load .

# arm64 同样使用 --platform linux/arm64；BuildKit 会按目标架构下载对应 AppImage
```

## 运行

```bash
docker run -d --name zcode-desktop \
  --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  --shm-size 2g \
  -p 6080:6080 -p 5901:5901 \
  zcode-desktop:amd64
```

- 浏览器访问：`http://<服务器IP>:6080/vnc.html`（无需装 VNC 客户端）
- VNC 客户端：`<服务器IP>:5901`
- VNC 密码：`zcode123`（可用 `-e VNC_PASSWORD=xxx` 修改；分辨率 `-e RESOLUTION=1920x1080`）
- 进入桌面后，双击桌面上的 **ZCode** 图标启动；首次双击如提示"未受信任的应用程序"，选择"允许启动"即可。

## 挂载 ~/.ssh（容器内使用宿主机 SSH 密钥）

容器内是 root，直接挂载即可，没有普通用户镜像的 uid 匹配/密钥权限问题：

```bash
docker run -d --name zcode-desktop \
  --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  --shm-size 2g \
  -p 6080:6080 -p 5901:5901 \
  -v ~/.ssh:/root/.ssh \
  zcode-desktop:amd64
```

- 只读挂载更安全：`-v ~/.ssh:/root/.ssh:ro`（需要在容器里写 known_hosts 时去掉 `:ro`）。
- ZCode 里的终端、git（SSH 协议远程）会直接使用这套密钥；`~/.gitconfig` 同理：`-v ~/.gitconfig:/root/.gitconfig:ro`。

## 代理与 MITM 证书信任

只需要设置 **`ZCODE_HTTP_PROXY`** 一个变量（可选 `ZCODE_HTTP_PROXY_NO_PROXY`），支持 `http://`、`https://`、`socks4://` 和 `socks5://[user:pass@]host:port` 四种上游。`https://` 仍表示明文连接到 HTTP 代理协议的上游；SOCKS 上游由 tinyproxy 转换为容器内应用使用的 HTTP 代理。容器启动时自动完成：

1. **本地免认证中转**：启动 tinyproxy 监听 `127.0.0.1:8118`，统一转发到上游代理，并按 HTTP/SOCKS 协议处理上游认证——容器内任何应用都不感知用户名密码；
2. **shell 环境**：导出 `http_proxy`/`https_proxy`/`no_proxy`（含大写）指向中转，curl/git/wget/apt 开箱即用；
3. **ZCode**：把中转地址写入 `setting.json`（`httpProxy`/`httpProxyNoProxy`）；
4. **Firefox**：Firefox 不读代理环境变量，通过企业策略 mozilla.cfg 写入中转地址。

**无代理模式**：不设置 `ZCODE_HTTP_PROXY`（或显式置空）即全容器直连——不导出任何代理变量（docker run 误传的 `HTTPS_PROXY` 等也会被清掉）、ZCode 删除 `httpProxy` 配置、Firefox 直连。两种模式下 ZCode/Firefox/shell 工具行为始终一致。

支持的运行组合：

| 代理 | `/mitm-ca.pem` | 行为 |
|---|---|---|
| 不设置 | 不挂载 | 全容器直连，使用系统默认 CA；适合无代理网络 |
| 设置 `ZCODE_HTTP_PROXY` | 不挂载 | 经 HTTP/SOCKS 上游转发，使用系统默认 CA；适合普通隧道代理或不拦截 TLS 的代理 |
| 设置 `ZCODE_HTTP_PROXY` | 挂载 | 经上游代理转发，并信任指定 MITM 根 CA；适合会解密并重新签发 HTTPS 证书的企业代理 |

也允许“无代理 + 挂载 CA”，用于直连但仍需信任企业内部证书的环境。

**MITM 证书**：容器内固定识别 `/mitm-ca.pem` 这一个文件，两个来源任选：

- **运行期挂载**（推荐，无需重新构建）：`-v /path/to/mitm-ca.pem:/mitm-ca.pem:ro`；
- **构建期烘焙**：把证书作为单个文件放进构建上下文的 `certs/mitm-ca.pem`，构建时 bind 挂载进构建过程（`RUN --mount=type=bind`，不会拷贝进镜像层），在 `apt-get update` 之前装入系统信任库——配合 `--build-arg HTTPS_PROXY=...`，构建期走 MITM 代理时 apt/wget/curl 全程可信，并烘焙为镜像内 `/mitm-ca.pem`。

PEM 或 DER 自动转换。证书装入：系统信任库（curl/git/Electron/openssl）、NSS 库 + Firefox 企业策略（enterprise roots），并作为 ZCode 的 `httpProxyCaCertPath`，同时通过 `NODE_EXTRA_CA_CERTS` 覆盖 Node 侧 TLS。**文件包含多于一个证书或无法解析时直接启动失败**，避免静默信任错误的 CA；不需要 MITM 时不挂载即可。

### 获取 MITM 根证书

优先从企业网络/代理管理员提供的证书门户下载根 CA，或请管理员直接提供 PEM/CRT/DER 文件。应核对证书的 SHA-256 指纹，避免从不可信渠道取得证书。

如果代理没有下载门户，可以在已正确配置该代理的 Firefox 中访问一个 HTTPS 网站，点击地址栏锁图标，打开“连接安全性”→“更多信息”→“查看证书”。在证书链中选择代理机构的最上层根证书并导出。不要导出网站自己的叶子证书；叶子证书通常只对一个域名有效，也不应作为根 CA 信任。

拿到证书后可先检查内容：

```bash
# PEM/CRT
openssl x509 -in mitm-ca.pem -noout -subject -issuer -fingerprint -sha256

# DER
openssl x509 -inform DER -in mitm-ca.der -noout \
  -subject -issuer -fingerprint -sha256
```

确认指纹后，在运行容器时只读挂载到固定路径：

```bash
-v /absolute/path/mitm-ca.pem:/mitm-ca.pem:ro
```

运行示例（带认证的 MITM 上游 + 证书挂载）：

```bash
docker run -d --name zcode-desktop \
  --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  --shm-size 2g \
  -p 6080:6080 -p 5901:5901 \
  -v /path/to/mitm-ca.pem:/mitm-ca.pem:ro \
  -e ZCODE_HTTP_PROXY=http://user:pass@proxy.example.com:55666 \
  -e ZCODE_HTTP_PROXY_NO_PROXY=localhost,127.0.0.1,.internal.example.com,10.0.0.0/8 \
  zcode-desktop:amd64
```

环境变量说明：

| 变量 | 作用 |
|---|---|
| `ZCODE_HTTP_PROXY` | 唯一的代理配置入口，格式 `http(s)://[user:pass@]host:port` 或 `socks4://[user:pass@]host:port` / `socks5://[user:pass@]host:port`；`https://` 对上游仍走明文 HTTP 代理协议，不做 TLS；端口缺省按 HTTP 80、HTTPS 443、SOCKS 1080；未设置或为空 = 全容器无代理直连 |
| `ZCODE_HTTP_PROXY_NO_PROXY` | 不走代理的目标列表（域名、IP、CIDR），逗号分隔；写入中转例外规则、`no_proxy` 环境变量、Firefox 与 ZCode；`localhost,127.0.0.1,::1` 始终自动包含 |
| `/mitm-ca.pem`（固定路径，非环境变量） | MITM 根证书：运行期 `-v` 挂载，或构建时烘焙（`certs/mitm-ca.pem`）；必须恰好一个证书，否则启动失败；不需要 MITM 时不提供 |

注意：

- 中转注入的 Basic 认证按**字面字节**发送（全程不做百分号解码）：`ZCODE_HTTP_PROXY` 里直接写凭据原文即可，含 `%` 的密码也原样写，**不要**做 URL 转义。仅 `@`、`/`（破坏地址解析）和 `"`、空格（破坏 tinyproxy 配置行）不能出现在凭据中；
- HTTP 上游需支持标准 HTTP 代理协议（CONNECT + 绝对地址 GET）；SOCKS 上游支持 SOCKS4/SOCKS5。对 `https://` 形态的 HTTP 上游不做 TLS。
- SOCKS5 用户名密码认证取决于镜像中的 tinyproxy 版本；如果认证握手失败，先使用无认证 SOCKS5 或升级 tinyproxy。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VNC_PASSWORD` | `zcode123` | VNC/noVNC 密码 |
| `RESOLUTION` | `1920x1080` | 桌面分辨率，需要更高可设 `2560x1440`、`3840x2160` 等；浏览器端 noVNC 会自动缩放适配 |
| `NOVNC_PORT` | `6080` | noVNC 端口 |

## 说明

- **AppImage 运行方式**：完整保留在 `/opt/ZCode.AppImage`，由 `/usr/local/bin/zcode` 包装脚本以 FUSE 挂载方式直接运行，**没有解包分支**。因此运行容器必须带 `--device /dev/fuse --cap-add SYS_ADMIN`；宿主机启用 AppArmor 时（如 Ubuntu 24.04）还需 `--security-opt apparmor=unconfined`，否则 FUSE 挂载报 `mount failed: Permission denied`。无 AppArmor 的主机加该参数也无副作用。
- ZCode 启动方式：桌面双击图标（`/root/Desktop/zcode.desktop`，`Exec=/usr/local/bin/zcode`），或桌面终端里执行 `zcode`。
- **在 x86 机器上仅能做构建与模拟冒烟测试**：QEMU binfmt 对 AppImage 头部 AI 魔数会报 `Exec format error`，且 qemu 不支持 ptrace（crashpad、GPU 子进程受限），这些都只在模拟环境出现，原生 ARM 服务器上不存在。

## 导出镜像

```bash
# 方式一：docker save 传输（无需镜像仓库）
docker save zcode-desktop:amd64 | gzip > zcode-desktop-amd64.tar.gz
# arm64 版同理
docker save zcode-desktop:arm64 | gzip > zcode-desktop-arm64.tar.gz

# 方式二：推送到仓库
docker buildx build --platform linux/amd64 \
  -t <registry>/zcode-desktop:amd64 --push .
# arm64 版同理：--platform linux/arm64 -t <registry>/zcode-desktop:arm64
```
