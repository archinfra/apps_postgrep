# apps_postgre

PostgreSQL Kubernetes 离线 `.run` 安装包。

## 交付目标

- 构建端在线拉取 PostgreSQL 镜像，按架构打包为 `.run`。
- 现场离线执行 `.run install`，完成镜像 `docker load`、`tag`、`push` 和 Helm 安装。
- 支持 `amd64`、`arm64` 和 `all` 双架构构建。
- 支持目标仓库已预置镜像时使用 `--skip-image-prepare`。
- 卸载默认保留 PVC，只有显式 `--delete-pvc` 才删除数据盘。

## 构建依赖

构建机需要：

- bash
- docker
- jq
- tar/gzip
- sha256sum

构建：

```bash
bash -n build.sh install.sh
jq empty images/image.json
bash build.sh --arch amd64
bash build.sh --arch arm64
ls -lh dist/
sha256sum -c dist/*.sha256
```

完整构建：

```bash
bash build.sh --arch all
```

## 构建产物

```text
dist/apps_postgre-installer-amd64.run
dist/apps_postgre-installer-amd64.run.sha256
dist/apps_postgre-installer-arm64.run
dist/apps_postgre-installer-arm64.run.sha256
```

## 现场安装依赖

目标机器需要：

- bash
- docker，可以访问现场镜像仓库
- helm
- kubectl，已配置目标 Kubernetes 集群权限

## 现场安装

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

参数说明：

| 参数 | 说明 |
| --- | --- |
| `--registry` | 现场镜像仓库前缀，例如 `sealos.hub:5000/kube4` |
| `--skip-image-prepare` | 跳过 `docker load/tag/push`，但仍将 Helm 镜像地址渲染到目标仓库 |
| `-n, --namespace` | Kubernetes 命名空间，默认 `apps-postgre` |
| `--release` | Helm release 名称，默认 `apps-postgre` |
| `--postgres-user` | PostgreSQL 用户，默认 `postgres` |
| `--postgres-password` | PostgreSQL 密码，生产必须显式指定 |
| `--postgres-db` | 默认数据库，默认 `appdb` |
| `--storage-class` | PVC StorageClass，空值使用集群默认 |
| `--size` | PVC 大小，默认 `20Gi` |
| `--values` | 额外 Helm values 文件 |
| `--delete-pvc` | 卸载时删除 PVC，默认不删除 |

## 现场验证

```bash
./apps_postgre-installer-amd64.run status -n apps-postgre
kubectl get pods,svc,statefulset,pvc -n apps-postgre
```

临时端口转发：

```bash
kubectl port-forward -n apps-postgre svc/apps-postgre 5432:5432
```

获取密码：

```bash
kubectl get secret apps-postgre -n apps-postgre -o jsonpath='{.data.password}' | base64 -d; echo
```

连接测试：

```bash
psql -h 127.0.0.1 -p 5432 -U postgres -d appdb
```

## 卸载

默认保留 PVC：

```bash
./apps_postgre-installer-amd64.run uninstall -n apps-postgre -y
```

删除 PVC，慎用：

```bash
./apps_postgre-installer-amd64.run uninstall -n apps-postgre --delete-pvc -y
```

## 修改镜像版本

编辑 `images/image.json` 和 `charts/postgre/values.yaml`：

```json
[
  {
    "name": "postgres",
    "source": "docker.io/library/postgres:16.6-bookworm",
    "target": "library/postgres:16.6-bookworm",
    "platforms": ["linux/amd64", "linux/arm64"]
  }
]
```

`source` 是构建机拉取的上游镜像，`target` 是现场仓库内的目标路径。安装时若传入：

```bash
--registry sealos.hub:5000/kube4
```

最终镜像会变成：

```text
sealos.hub:5000/kube4/library/postgres:16.6-bookworm
```
