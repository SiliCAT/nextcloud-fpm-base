# Codex 云环境初始化：rootless Podman

本目录保存开发测试环境的初始化文件，供审查、重建和后续适配使用。
项目部署脚本应遵循 rootless Podman 与 Nextcloud 的目录、权限和运行契约；
云环境特有的代理、证书和嵌套运行条件集中在本目录维护。

## 文件

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 构建 Debian 13 测试工具镜像，安装 Podman、systemd、UID 映射、网络及检查工具 |
| `install.sh` | 调用当前目录的 `setup.py`，不再内嵌另一套文件副本 |
| `setup.py` | 创建或启动独立测试环境，恢复设备、证书、用户服务及 cgroup 设置 |
| `run.py` | 以普通用户执行整个命令或脚本，保留标准输入和退出码 |
| `validate.sh` | 检查 rootless 身份、内存限制、镜像构建与运行、pasta 网络及端口 |
| `README.md` | 记录前提、边界、操作方式和验证范围 |

## 运行边界与依赖

当前已验证的结构：

```text
Codex 云环境
  └─ 特权 Docker 测试容器（systemd）
       └─ tester，UID 1000，真正的 rootless Podman
            └─ 待测业务容器
```

需要具备以下条件：

- Linux amd64 宿主、Python 3、可访问的 Docker 服务；首次构建需要 Buildx。
- 允许创建特权 Docker 容器，以及用户命名空间和 UID/GID 映射。
- cgroup v2、systemd 用户会话及资源控制器委派。
- FUSE 和 TUN；初始化会在独立测试容器内准备对应设备。
- 下载 Debian 软件包、镜像所需的网络访问和证书信任。

外层特权容器用于提供运行条件，内层 Podman 必须以 tester 运行并报告 `rootless=true`。
本环境用于可信项目的开发测试，不作为运行不可信代码的安全边界。
不安装 Incus，也不将 Docker 或 rootful Podman 的结果当作 rootless 验证结果。

## 平台演进与可复现性

**云环境的权限、内核、工具或网络机制发生变化，仍可能让以前的重建脚本失效。**
GitHub 保存文件和历史，快照保存某次环境状态；可运行性需要在目标环境中实际验证。
当前实测可用的特权和内核能力，不代表平台长期承诺持续提供。

| 变化 | 可能的处理方式 |
| --- | --- |
| Podman、Debian 软件包、命令参数或默认行为变化 | 记录版本，检查兼容性，通过 PR 更新并重新验收 |
| 代理、证书或环境恢复方式变化 | 修改云环境适配步骤，保持 TLS 和包签名验证 |
| 特权 Docker、用户命名空间或必要内核能力被取消 | 清楚报告缺失前提，改用具备同等契约的 SSH 测试机或自托管运行环境 |

应定期做不依赖镜像缓存的重建，区分环境问题和项目问题。
固定关键版本可减少漂移，仍需跟进安全更新；不应为获得通过结果而关闭检查、
跳过失败断言或悄悄替换容器技术。

## 安装与使用

在现有项目 checkout 中执行，无需额外创建 Git worktree：

```sh
bash codex-env.init/install.sh
python3 codex-env.init/run.py podman info
```

首次缺少工具镜像时会构建；已有环境会优先启动和复用。
`bash codex-env.init/install.sh --refresh-image` 可重建工具镜像，但会保留现有测试容器和数据；
已运行的容器不会自动切换到新镜像。
如需切换，先确认测试任务已停止、需保留的文件位于命名卷或已备份，
再停止并仅删除 `codex-rootless-podman` 容器，保留命名卷，然后重新执行安装入口。

初始化文件从自身位置确定 checkout 路径，不要求固定的仓库目录名。
Docker 客户端状态默认放在 checkout 上级的 `.environment/rootless-podman/`，
也可通过 `PODMAN_LAB_STATE_DIR` 指定可写位置；已有 `DOCKER_CONFIG` 保持有效。
生成的 Docker 配置、镜像、日志和缓存不应提交到仓库。

在使用网络代理时，复用当前 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY` 及小写变量；
如存在平台提供的 `CODEX_PROXY_CERT` 文件，则通过 BuildKit secret 和启动时的信任更新使用。
不在本目录保存凭据、代理变量值或平台证书。运行时环境变量和认证不应依赖快照保留。

## 目录与生命周期

- 独立测试容器：`codex-rootless-podman`；工具镜像：`localhost/codex-rootless-podman:debian13`。
- 内层工作目录：`/home/tester/work`；当前 checkout 只读映射为 `/project`。
- 镜像存储和工作文件保存在 Docker 卷 `codex-rootless-podman-home`。
- `/run`、`/tmp` 和运行中的进程不能假定跨重启保留；再次运行初始化入口以恢复服务。
- 同名容器若属于其他工作流，或挂载了其他 checkout，初始化会停止并提示检查。

整个待测脚本应在测试环境内执行，避免宿主与测试容器对临时路径的理解不同：

```sh
python3 codex-env.init/run.py bash /project/路径/脚本.sh
```

停止并保留数据：

```sh
docker stop --timeout 20 codex-rootless-podman
```

不要为了修复启动问题而直接删除命名卷；其中可能有工作文件。
快照能否恢复 Docker 缓存和命名卷需要实测确认，不能仅凭脚本存在作保证。

## 环境验收

先准备测试镜像。可拉取已发布的 PHP-FPM 镜像：

```sh
python3 codex-env.init/run.py podman pull docker.io/library/alpine:3.23
python3 codex-env.init/run.py podman pull ghcr.io/silicat/nextcloud-fpm-base:8.5-alpine3.23
bash codex-env.init/validate.sh ghcr.io/silicat/nextcloud-fpm-base:8.5-alpine3.23
```

也可以使用当前云机器已有的 Docker 缓存：

```sh
set -o pipefail
docker image save localhost/nextcloud-fpm-base:ci | python3 codex-env.init/run.py podman load
bash codex-env.init/validate.sh
```

验收会创建并清理本轮临时对象；测试端口随机分配，仅绑定独立测试环境的 loopback。
PHP-FPM 测试镜像需包含 Supervisor 使用的 `/usr/bin/python3`，用于最小 HTTP 请求检查。
这里是开发环境能力验收，不代替 Nextcloud 安装、数据库或第三方应用的集成测试。

## 已有验证记录

整理本目录前，已在当前 Codex 环境验证 Podman 5.4.2、crun、cgroup v2 + systemd、
overlay + fuse-overlayfs；rootless 拉取、构建、运行、网络和内存限制通过。
上传的底座验收脚本针对本地缓存镜像的 13 项检查通过。
发布后重新连接的实例中，文件与缓存恢复，启动与上述检查再次通过。

这些记录不等于所有未来平台版本均兼容，也不等于已验证无缓存的全新任务恢复。
上传验收脚本尚未收录到本目录；本 PR 仅保存环境初始化文件。

合并后，云环境设置中的安装脚本可调用 `bash <checkout>/codex-env.init/install.sh`，
启动说明引用同一目录的入口和验收步骤，从而减少配置草稿与仓库代码之间的副本漂移。
保存环境设置、发布快照和向 GitHub 推送代码是独立操作。
