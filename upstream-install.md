# Upstream 服务端手动安装（Ubuntu 22.04 LTS）

这是新系统的总控安装器。客户侧私有化后端使用另一份 client-server 安装器。

## 1. 准备镜像

在已安装 Docker、并具有 PuzzleUpstream 源码的构建机器上运行。以下命令从 PuzzleUpstream 的上级目录执行，为常见的 x86_64 Ubuntu 服务器构建镜像：

```bash
docker buildx build --platform linux/amd64 \
  -f PuzzleUpstream/server/Dockerfile \
  -t puzzle-upstream:latest --load PuzzleUpstream
docker save -o upstream-image.tar puzzle-upstream:latest
shasum -a 256 upstream-image.tar > upstream-image.tar.sha256
scp upstream-image.tar upstream-image.tar.sha256 ubuntu@SERVER_IP:~/
```

将 `SERVER_IP` 替换为目标服务器地址。ARM64 服务器改用 `linux/arm64`。

如果仅在原服务器重装现有版本，可直接在该服务器执行 `sudo docker save -o "$HOME/upstream-image.tar" puzzle-upstream:latest`，然后继续下面的步骤；这不会构建新版本。

## 2. 在服务器执行安装

```bash
cd "$HOME"
curl --fail --location --show-error \
  https://carlamccoy1975-hash.github.io/cloud.github.io/install-upstream-ubuntu22.sh \
  -o install-upstream-ubuntu22.sh
# 使用步骤 1 上传的校验文件时执行：
sha256sum -c upstream-image.tar.sha256

sudo env \
  UPSTREAM_IMAGE=puzzle-upstream:latest \
  UPSTREAM_IMAGE_TAR_PATH="$PWD/upstream-image.tar" \
  UPSTREAM_PUBLIC_URL="http://SERVER_IP:11080" \
  UPSTREAM_BOOTSTRAP_ADMIN_EMAIL="admin@example.com" \
  UPSTREAM_PUBLIC_PORT=11080 \
  UPSTREAM_ENABLE_CADDY=false \
  LETSENCRYPT_EMAIL="YOUR_ACME_EMAIL" \
  SWAP_SIZE_GB=2 \
  DB_MAX_OPEN_CONNS=20 \
  DB_MAX_IDLE_CONNS=5 \
  bash ./install-upstream-ubuntu22.sh
```

替换 `SERVER_IP`、管理员邮箱及 `YOUR_ACME_EMAIL`。原服务器自行导出镜像且没有校验文件时，跳过 `sha256sum -c`；不要下载或加载来源不明的镜像。

首次安装会生成管理员密码并在终端显示，配置写入 `/opt/puzzle/upstream/.env`（仅管理员可读）。后台地址为 `http://SERVER_IP:11080/admin/`。数据库和下载资源使用独立 Docker volumes 保存。

域名 HTTPS 部署时，将 `UPSTREAM_PUBLIC_URL` 改为实际 HTTPS 域名，并设置 `UPSTREAM_ENABLE_CADDY=true`，确保域名解析和 80/443 端口可用；Caddy 使用 `LETSENCRYPT_EMAIL` 申请和续期证书。

## 3. 验证与重复安装

```bash
curl --fail http://127.0.0.1:11080/healthz
sudo docker compose --project-name puzzle-upstream \
  --env-file /opt/puzzle/upstream/.env \
  -f /opt/puzzle/upstream/docker-compose.yml ps
```

重复安装会保留已有密码，并备份原配置。迁移或恢复同一套总控时，需要保留或恢复原数据库、下载资源及 `.env`；只启动一个空数据库会生成新的授权签名密钥，已经发布的客户端不能直接沿用，需要重新发布与新总控匹配的客户端。

总控首次安装成功后，还需要运行项目的 release 发布流程上传客户端、客户侧后端和实时服务资源，桌面端的一键私有化部署才有对应安装包可用。
