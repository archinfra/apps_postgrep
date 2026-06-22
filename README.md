# apps_postgrep

本仓库用于维护 PostgreSQL 的 Kubernetes 离线 `.run` 交付包。

> 包目录采用 `apps_postgre/`，仓库名沿用当前 GitHub 仓库 `apps_postgrep`。

## 快速构建

```bash
cd apps_postgre
bash -n build.sh install.sh
jq empty images/image.json
bash build.sh --arch amd64
bash build.sh --arch arm64
ls -lh dist/
sha256sum -c dist/*.sha256
```

完整双架构构建：

```bash
cd apps_postgre
bash build.sh --arch all
```

## 现场安装示例

```bash
sha256sum -c apps_postgre-installer-amd64.run.sha256
chmod +x apps_postgre-installer-amd64.run
./apps_postgre-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n apps-postgre \
  --postgres-password 'ChangeMe_StrongPassword' \
  -y
```

目标仓库已经预置镜像时：

```bash
./apps_postgre-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n apps-postgre \
  --postgres-password 'ChangeMe_StrongPassword' \
  -y
```

## 目录说明

```text
apps_postgre/
  build.sh                 # 离线 .run 构建脚本
  install.sh               # .run 自解压安装器主体
  images/image.json        # 镜像清单
  charts/postgre/          # 内置 Helm Chart
  README.md                # 包级使用文档
.github/workflows/
  offline-run-packages.yml # GitHub Actions 双架构构建模板
```
