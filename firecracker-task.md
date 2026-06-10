# Firecracker 内核二次开发：支持 Docker 运行

## 1. 背景与目标

### 1.1 问题描述

基于 Firecracker 的 vmsan microVM 环境中运行 1Panel 面板时，VM 内的 Docker 服务无法正常启动。1Panel 的核心功能依赖 Docker 管理容器，因此需要 Firecracker 内核具备 Docker 运行所需的全部内核功能。

### 1.2 目标

在 Firecracker 官方内核配置基础上，补全 Docker/containerd 运行所需的内核特性，构建一个 **Docker-in-Firecracker** 兼容的 guest 内核。

### 1.3 约束

- 保持 Firecracker microVM 的轻量特性，不引入不必要的模块
- 内核采用 monolithic 编译（`CONFIG_MODULES=n`），所有功能静态编译进内核
- 基于 Firecracker 官方 `microvm-kernel-ci-x86_64-6.1.config` 配置增量修改
- 不修改 Firecracker VMM 本身，仅修改 guest 内核配置

## 2. 现状分析

### 2.1 内核构建架构

```
Firecracker 项目
├── resources/
│   ├── guest_configs/           # 内核 .config 文件（核心）
│   │   ├── microvm-kernel-ci-x86_64-6.1.config  # 主配置（3556行，1238个选项）
│   │   ├── ci.config            # CI 补充配置
│   │   ├── debug.config         # 调试配置
│   │   └── ftrace.config        # 追踪配置
│   ├── rebuild.sh               # 内核构建脚本
│   └── patches/                 # 内核补丁（当前为空）
├── docs/rootfs-and-kernel-setup.md  # 内核构建文档
└── tools/devtool                # CI 构建工具入口
```

**构建流程**：
1. 从 `https://github.com/amazonlinux/linux` clone 内核源码
2. checkout `microvm-kernel-6.1.*.amzn2023` tag
3. 拼接配置：`base_config + ci.config > .config`
4. `make olddefconfig && make -j$(nproc) vmlinux`
5. 产出 `vmlinux-6.1.xxx` 到 `resources/x86_64/`

### 2.2 官方内核已有功能（Docker 相关）

| 功能 | 状态 | 配置项 |
|------|------|--------|
| cgroups v1 (全部子系统) | ✅ 已启用 | `CONFIG_CGROUPS=y`, MEMCG, BLK_CGROUP, CPUSET, DEV, FREEZER, PIDS, HUGETLB, PERF, BPF, NET_PRIO, NET_CLASSID |
| namespaces (全部) | ✅ 已启用 | `CONFIG_NAMESPACES=y`, UTS, TIME, IPC, USER, PID, NET |
| OverlayFS | ✅ 已启用 | `CONFIG_OVERLAY_FS=y` |
| Bridge | ✅ 已启用 | `CONFIG_BRIDGE=y`, `CONFIG_BRIDGE_NETFILTER=y` |
| Netfilter/iptables | ✅ 已启用 | `CONFIG_NETFILTER=y`, XTABLES, NF_NAT, NF_TABLES, IP_NF_* |
| VETH | ✅ 已启用 | `CONFIG_VETH=y` |
| seccomp | ✅ 已启用 | `CONFIG_SECCOMP=y`, `CONFIG_SECCOMP_FILTER=y` |
| devtmpfs | ✅ 已启用 | `CONFIG_DEVTMPFS=y`, `CONFIG_DEVTMPFS_MOUNT=y` |
| tmpfs | ✅ 已启用 | `CONFIG_TMPFS=y` |
| loop device | ✅ 已启用 | `CONFIG_BLK_DEV_LOOP=y` |
| ext4/xfs | ✅ 已启用 | `CONFIG_EXT4_FS=y`, `CONFIG_XFS_FS=y` |
| cgroup CFS bandwidth | ✅ 已启用 | `CONFIG_CFS_BANDWIDTH=y` |

### 2.3 官方内核缺失功能（Docker 相关）

| 功能 | 状态 | 影响 | 需要启用的配置项 |
|------|------|------|------------------|
| TUN/TAP 设备 | ❌ 未启用 | Docker 网络无法创建 tap 设备 | `CONFIG_TUN=y` |
| DUMMY 网卡 | ❌ 未启用 | Docker 网络桥接需要 | `CONFIG_DUMMY=y` |
| MACVLAN | ❌ 未启用 | Docker macvlan 网络驱动需要 | `CONFIG_MACVLAN=y` |
| IPVLAN | ❌ 未启用 | Docker ipvlan 网络驱动需要 | `CONFIG_IPVLAN=y` |
| VXLAN | ❌ 未启用 | Docker overlay 网络需要（跨主机） | `CONFIG_VXLAN=y` |
| IPVS | ❌ 未启用 | Docker Swarm / Kubernetes 负载均衡需要 | `CONFIG_IP_VS=y`, `CONFIG_IP_VS_RR=y`, `CONFIG_IP_VS_NFCT=y` |
| Netfilter MARK target | ❌ 未启用 | Docker 网络标记需要 | `CONFIG_NETFILTER_XT_TARGET_MARK=y` |
| Netfilter MARK match | ❌ 未启用 | Docker 网络规则匹配需要 | `CONFIG_NETFILTER_XT_MATCH_MARK=y` |
| Netfilter connmark | ❌ 未启用 | Docker 连接跟踪标记需要 | `CONFIG_NETFILTER_XT_TARGET_CONNMARK=y`, `CONFIG_NETFILTER_XT_MATCH_CONNMARK=y` |
| Netfilter LOG | ❌ 未启用 | iptables 调试需要 | `CONFIG_NETFILTER_XT_TARGET_LOG=y` |
| Netfilter NFLOG | ❌ 未启用 | iptables 日志需要 | `CONFIG_NETFILTER_XT_TARGET_NFLOG=y` |
| Netfilter NFQUEUE | ❌ 未启用 | 高级网络策略需要 | `CONFIG_NETFILTER_XT_TARGET_NFQUEUE=y` |
| Netfilter physdev | ❌ 未启用 | Docker bridge 防火墙需要 | `CONFIG_NETFILTER_XT_MATCH_PHYSDEV=y` |
| Netfilter multiport | ❌ 未启用 | Docker 端口规则需要 | `CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y` |
| Netfilter comment | ❌ 未启用 | iptables 规则注释需要 | `CONFIG_NETFILTER_XT_MATCH_COMMENT=y` |
| Netfilter limit | ❌ 未启用 | iptables 限速规则需要 | `CONFIG_NETFILTER_XT_MATCH_LIMIT=y` |
| Netfilter recent | ❌ 未启用 | 连接速率限制需要 | `CONFIG_NETFILTER_XT_MATCH_RECENT=y` |
| Netfilter BPF | ❌ 未启用 | Cilium/eBPF 网络策略需要 | `CONFIG_NETFILTER_XT_MATCH_BPF=y` |
| eBPF netfilter | ❌ 未启用 | Docker 网络策略需要 | `CONFIG_NETFILTER_XT_MATCH_SOCKET=y` |
| CHECKPOINT_RESTORE | ❌ 未启用 | Docker 容器迁移/检查点需要（非必需） | `CONFIG_CHECKPOINT_RESTORE=y` |

## 3. 方案设计

### 3.1 总体方案

创建一个新的内核配置叠加文件 `docker.config`，在 Firecracker 官方内核配置基础上增量启用 Docker 所需的全部内核特性。

**核心原则**：
- **不修改** `microvm-kernel-ci-x86_64-6.1.config`，保持官方配置不变
- **增量叠加**：新建 `docker.config`，构建时拼接到配置链末尾
- **最小化影响**：只启用 Docker 必需的配置项，不引入无关模块

### 3.2 配置叠加架构

```
官方构建：base_config + ci.config > .config
Docker 构建：base_config + ci.config + docker.config > .config
                                        ^^^^^^^^^^^^
                                        新增文件
```

### 3.3 文件变更清单

```
resources/guest_configs/
├── docker.config                    # [新增] Docker 内核配置叠加文件
├── microvm-kernel-ci-x86_64-6.1.config  # [不变] 官方基础配置
└── ci.config                        # [不变] CI 配置

resources/
└── rebuild.sh                       # [修改] 支持 --docker 参数和新的配置层

scripts/
└── build-docker-kernel.sh           # [新增] 独立的 Docker 内核构建脚本
```

## 4. 详细设计

### 4.1 `docker.config` — Docker 内核配置叠加

```ini
# =============================================================================
# docker.config — Docker-in-Firecracker 内核配置叠加
# 基于 microvm-kernel-ci-x86_64-6.1.config 增量启用 Docker 所需特性
# =============================================================================

# --- 网络设备 ---
# Docker 网络核心：TUN/TAP 设备（容器网络数据面）
CONFIG_TUN=y
# Docker 网络辅助：dummy 网卡（网络桥接/测试）
CONFIG_DUMMY=y
# Docker macvlan 网络驱动
CONFIG_MACVLAN=y
# Docker ipvlan 网络驱动
CONFIG_IPVLAN=y
# Docker overlay 网络驱动（VXLAN 隧道）
CONFIG_VXLAN=y
# IPVLAN 支持 L3/S 模式
CONFIG_IPVLAN_L3S=y

# --- IPVS 负载均衡 ---
# Docker Swarm / Kubernetes 服务负载均衡
CONFIG_IP_VS=y
CONFIG_IP_VS_IPV6=y
CONFIG_IP_VS_RR=y
CONFIG_IP_VS_WRR=y
CONFIG_IP_VS_LC=y
CONFIG_IP_VS_WLC=y
CONFIG_IP_VS_FO=y
CONFIG_IP_VS_OVF=y
CONFIG_IP_VS_LBLC=y
CONFIG_IP_VS_LBLCR=y
CONFIG_IP_VS_DH=y
CONFIG_IP_VS_SH=y
CONFIG_IP_VS_MH=y
CONFIG_IP_VS_SED=y
CONFIG_IP_VS_NQ=y
CONFIG_IP_VS_NFCT=y
# IPVS 基于 netfilter conntrack
CONFIG_NETFILTER_XT_MATCH_IPVS=y

# --- Netfilter 补全 ---
# Docker bridge 防火墙（physdev 匹配）
CONFIG_NETFILTER_XT_MATCH_PHYSDEV=y
# iptables MARK target/match（Docker 网络标记）
CONFIG_NETFILTER_XT_TARGET_MARK=y
CONFIG_NETFILTER_XT_MATCH_MARK=y
# connmark（连接跟踪标记）
CONFIG_NETFILTER_XT_TARGET_CONNMARK=y
CONFIG_NETFILTER_XT_MATCH_CONNMARK=y
# iptables LOG/NFLOG（网络调试日志）
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_TARGET_NFLOG=y
# NFQUEUE（用户态网络包处理）
CONFIG_NETFILTER_XT_TARGET_NFQUEUE=y
# 多端口匹配
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
# 规则注释
CONFIG_NETFILTER_XT_MATCH_COMMENT=y
# 限速匹配
CONFIG_NETFILTER_XT_MATCH_LIMIT=y
# recent 匹配（连接速率限制）
CONFIG_NETFILTER_XT_MATCH_RECENT=y
# eBPF 匹配
CONFIG_NETFILTER_XT_MATCH_BPF=y
# socket 匹配
CONFIG_NETFILTER_XT_MATCH_SOCKET=y
# connbytes 匹配
CONFIG_NETFILTER_XT_MATCH_CONNBYTES=y
# state 匹配（简化 iptables 规则）
CONFIG_NETFILTER_XT_MATCH_STATE=y
# statistic 匹配
CONFIG_NETFILTER_XT_MATCH_STATISTIC=y
# string 匹配
CONFIG_NETFILTER_XT_MATCH_STRING=y
# time 匹配
CONFIG_NETFILTER_XT_MATCH_TIME=y
# NFLOG（netfilter 日志）
CONFIG_NETFILTER_NETLINK_LOG=y
# NFQUEUE（netfilter 队列）
CONFIG_NETFILTER_NETLINK_QUEUE=y
# NFACCT（网络记账）
CONFIG_NETFILTER_XT_MATCH_NFACCT=y
# NETLINK_ACCT（用户态记账接口）
CONFIG_NETFILTER_NETLINK_ACCT=y
# NETLINK_HOOK（netfilter hook 查询）
CONFIG_NETFILTER_NETLINK_HOOK=y

# --- 容器高级特性 ---
# 容器检查点/恢复（Docker checkpoint）
CONFIG_CHECKPOINT_RESTORE=y

# --- 网络诊断 ---
# UNIX_DIAG（Unix socket 诊断）
CONFIG_UNIX_DIAG=y
# NETFILTER_EGRESS（出口过滤）
CONFIG_NETFILTER_EGRESS=y
```

### 4.2 构建脚本修改 — `resources/rebuild.sh`

在 `build_al_kernel` 函数中，支持叠加 `docker.config`：

**修改点**：在 `cat "$@" >.config` 后面，支持新的参数模式。

当前代码（第 156 行）：
```bash
cat "$@" >.config
```

这个函数接收参数为配置文件列表，所以构建 Docker 内核时只需在参数末尾加上 `docker.config`：

```bash
# 原有构建（CI 用）
build_al_kernel microvm-kernel-ci-x86_64-6.1.config ci.config

# Docker 构建（新增）
build_al_kernel microvm-kernel-ci-x86_64-6.1.config ci.config docker.config
```

### 4.3 独立构建脚本 — `scripts/build-docker-kernel.sh`

```bash
#!/bin/bash
# build-docker-kernel.sh
# 从 Firecracker 官方内核源码构建支持 Docker 的 guest 内核
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$FC_ROOT/resources/guest_configs"
KERNEL_SRC="${KERNEL_SRC:-$FC_ROOT/resources/linux}"
OUTPUT_DIR="${OUTPUT_DIR:-$FC_ROOT/resources/x86_64}"
KERNEL_VERSION="${KERNEL_VERSION:-6.1}"
JOBS="${JOBS:-$(nproc)}"

info()  { printf '[info] %s\n' "$*"; }
error() { printf '[error] %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || error "需要安装: $1"; }
need_cmd make
need_cmd gcc

# 1. 获取内核源码
if [ ! -d "$KERNEL_SRC" ]; then
    info "克隆 Amazon Linux 内核源码..."
    git clone --no-checkout --filter=tree:0 \
        https://github.com/amazonlinux/linux "$KERNEL_SRC"
fi

cd "$KERNEL_SRC"

# 2. 选择 tag
TAG=$(git --no-pager tag -l --sort=-v:refname \
    | grep "microvm-kernel-$KERNEL_VERSION\..*\.amzn2" \
    | head -n1)
[ -z "$TAG" ] && error "找不到内核版本 $KERNEL_VERSION 的 tag"
info "使用内核 tag: $TAG"

make distclean || true
git checkout "$TAG"
git checkout -B "docker-$TAG"

# 3. 拼接配置
info "拼接内核配置: base + ci + docker"
cat \
    "$CONFIG_DIR/microvm-kernel-ci-x86_64-$KERNEL_VERSION.config" \
    "$CONFIG_DIR/ci.config" \
    "$CONFIG_DIR/docker.config" \
    > .config

# 4. 编译
info "开始编译内核 (jobs=$JOBS)..."
make olddefconfig
make -j"$JOBS" vmlinux

# 5. 输出
LATEST_VERSION=$(cat include/config/kernel.release)
OUTPUT_FILE="$OUTPUT_DIR/vmlinux-${LATEST_VERSION}-docker"
mkdir -p "$OUTPUT_DIR"
cp -v vmlinux "$OUTPUT_FILE"
cp -v .config "$OUTPUT_FILE.config"

info "内核构建完成: $OUTPUT_FILE"
info "大小: $(du -sh "$OUTPUT_FILE" | cut -f1)"

# 清理临时分支
git reset --hard HEAD
git clean -f -d
git checkout -
```

### 4.4 验证方案

构建完成后，需要验证内核的 Docker 支持情况：

**验证脚本** — `scripts/verify-docker-kernel.sh`：

```bash
#!/bin/bash
# 验证 Firecracker guest 内核的 Docker 支持情况
set -euo pipefail

KERNEL_CONFIG="${1:?用法: $0 <kernel.config 文件>}"

echo "=== 验证内核 Docker 支持: $KERNEL_CONFIG ==="

check() {
    local name="$1"
    local config="$2"
    local expected="$3"

    actual=$(grep "^$config=" "$KERNEL_CONFIG" 2>/dev/null | cut -d= -f2 || echo "missing")
    if [ "$actual" = "$expected" ]; then
        printf "  ✅ %-45s %s=%s\n" "$name" "$config" "$expected"
    else
        printf "  ❌ %-45s %s=%s (实际: %s)\n" "$name" "$config" "$expected" "$actual"
    fi
}

echo ""
echo "--- cgroups ---"
check "cgroups"        "CONFIG_CGROUPS"          "y"
check "cgroup memory"  "CONFIG_MEMCG"            "y"
check "cgroup devices" "CONFIG_CGROUP_DEVICE"    "y"
check "cgroup freezer" "CONFIG_CGROUP_FREEZER"   "y"
check "cgroup pids"    "CONFIG_CGROUP_PIDS"      "y"
check "blk cgroup"     "CONFIG_BLK_CGROUP"       "y"
check "cgroup net prio" "CONFIG_CGROUP_NET_PRIO" "y"

echo ""
echo "--- namespaces ---"
check "namespaces"     "CONFIG_NAMESPACES"       "y"
check "user ns"        "CONFIG_USER_NS"          "y"
check "pid ns"         "CONFIG_PID_NS"           "y"
check "net ns"         "CONFIG_NET_NS"           "y"
check "ipc ns"         "CONFIG_IPC_NS"           "y"
check "uts ns"         "CONFIG_UTS_NS"           "y"

echo ""
echo "--- 网络设备 ---"
check "veth"           "CONFIG_VETH"             "y"
check "bridge"         "CONFIG_BRIDGE"           "y"
check "TUN/TAP"        "CONFIG_TUN"              "y"
check "dummy"          "CONFIG_DUMMY"            "y"
check "macvlan"        "CONFIG_MACVLAN"          "y"
check "ipvlan"         "CONFIG_IPVLAN"           "y"
check "vxlan"          "CONFIG_VXLAN"            "y"

echo ""
echo "--- 存储驱动 ---"
check "overlayfs"      "CONFIG_OVERLAY_FS"       "y"
check "ext4"           "CONFIG_EXT4_FS"          "y"
check "loop device"    "CONFIG_BLK_DEV_LOOP"     "y"

echo ""
echo "--- netfilter/iptables ---"
check "netfilter"      "CONFIG_NETFILTER"        "y"
check "iptables"       "CONFIG_IP_NF_IPTABLES"   "y"
check "ip6tables"      "CONFIG_IP6_NF_IPTABLES"  "y"
check "nat"            "CONFIG_NF_NAT"           "y"
check "MARK target"    "CONFIG_NETFILTER_XT_TARGET_MARK"       "y"
check "MARK match"     "CONFIG_NETFILTER_XT_MATCH_MARK"        "y"
check "physdev match"  "CONFIG_NETFILTER_XT_MATCH_PHYSDEV"     "y"
check "connmark tgt"   "CONFIG_NETFILTER_XT_TARGET_CONNMARK"   "y"
check "connmark match" "CONFIG_NETFILTER_XT_MATCH_CONNMARK"    "y"
check "LOG target"     "CONFIG_NETFILTER_XT_TARGET_LOG"        "y"
check "NFLOG target"   "CONFIG_NETFILTER_XT_TARGET_NFLOG"      "y"
check "comment match"  "CONFIG_NETFILTER_XT_MATCH_COMMENT"     "y"
check "multiport"      "CONFIG_NETFILTER_XT_MATCH_MULTIPORT"   "y"
check "limit match"    "CONFIG_NETFILTER_XT_MATCH_LIMIT"       "y"

echo ""
echo "--- 安全/容器 ---"
check "seccomp"              "CONFIG_SECCOMP"                "y"
check "seccomp filter"       "CONFIG_SESCOMP_FILTER"         "y"
check "checkpoint/restore"   "CONFIG_CHECKPOINT_RESTORE"     "y"
check "cgroup bpf"           "CONFIG_CGROUP_BPF"             "y"
check "bpf syscall"          "CONFIG_BPF_SYSCALL"            "y"

echo ""
echo "=== 验证完成 ==="
```

## 5. 集成到 vmsan 构建流水线

### 5.1 内核替换

构建出 `vmlinux-6.1.xxx-docker` 后，需要让 vmsan 使用这个内核：

```bash
# 将构建好的 Docker 内核复制到 vmsan 内核目录
cp vmlinux-6.1.*-docker ~/.vmsan/kernels/vmlinux-6.1

# 或者在 vmsan create 时指定内核路径（如果支持）
sudo env "PATH=$PATH" vmsan create \
    --rootfs ./1panel-rootfs.ext4 \
    --kernel ./vmlinux-6.1-docker \
    --vcpus 2 \
    --memory 2048 \
    --publish-port 8888
```

### 5.2 CI 集成

在 `build-1panel.yml` 中增加 Docker 内核构建和使用步骤：

```yaml
- name: Build Docker-capable kernel
  run: |
    cd /tmp
    git clone --no-checkout --filter=tree:0 https://github.com/amazonlinux/linux
    cd linux
    TAG=$(git tag -l --sort=-v:refname | grep "microvm-kernel-6.1\..*\.amzn2" | head -n1)
    git checkout $TAG
    cat /path/to/base.config /path/to/ci.config /path/to/docker.config > .config
    make olddefconfig
    make -j$(nproc) vmlinux
    cp vmlinux /tmp/vmlinux-docker

- name: Test VM with Docker kernel
  run: |
    sudo env "PATH=$PATH" vmsan create \
      --rootfs ./1panel-rootfs.ext4 \
      --kernel /tmp/vmlinux-docker \
      --memory 2048 \
      --vcpus 2 \
      --publish-port 8888
```

### 5.3 rootfs 调整

1Panel rootfs 中需要确保 Docker 配置正确：

- `containerd` 和 `docker.io` 已安装
- systemd 启用 `docker.service` 和 `containerd.service`
- Docker 数据目录使用 overlay2 存储驱动
- 确保 Docker socket 权限正确

## 6. 实施计划

| 阶段 | 任务 | 预估时间 |
|------|------|----------|
| P1 | 创建 `docker.config` 配置叠加文件 | 0.5h |
| P2 | 编写 `scripts/build-docker-kernel.sh` 构建脚本 | 1h |
| P3 | 本地构建 Docker 内核并验证配置 | 1-2h（含编译时间） |
| P4 | 使用新内核启动 1Panel VM，验证 Docker 服务 | 1h |
| P5 | 修复运行时问题（如果有） | 1-2h |
| P6 | 集成到 CI 流水线 | 1h |

## 7. 风险与注意事项

### 7.1 内核体积增长

启用额外配置会增加内核二进制大小。官方 microvm 内核约 30-40MB，Docker 增强版预计增加 5-10MB。由于内核在 VM 启动时加载到内存，需要注意内存分配。

### 7.2 编译时间

在 GitHub Actions runner（4核）上，内核完整编译约需 10-15 分钟。可考虑缓存编译产物。

### 7.3 overlay2 存储驱动

`CONFIG_OVERLAY_FS=y` 已在官方配置中启用，Docker 默认使用 overlay2 驱动，应该可以直接工作。但需确保没有启用 `OVERLAY_FS_REDIRECT_DIR`（官方已禁用），因为这可能导致 Docker 兼容性问题。

### 7.4 cgroup 初始化

VM 内 systemd 需要正确挂载 cgroups。确保 rootfs 中的 systemd 配置包含 cgroup 挂载：
- `/sys/fs/cgroup/` 由 systemd 自动挂载
- 可能需要在内核命令行传递 `cgroup_no_v1=all`（如果使用 cgroup v2）或保持 v1

### 7.5 Docker 存储

Firecracker VM 使用 ext4 rootfs 作为块设备，Docker 的 overlay2 层将在 ext4 之上工作。需要确保 rootfs 有足够空间（建议 4GB+）。

### 7.6 网络限制

Firecracker VM 只有 1 个 virtio-net 网卡。Docker 容器通过 bridge + NAT + veth 访问外部网络。`--publish-port` 映射的是宿主机到 VM 的端口，VM 内 Docker 容器的端口需要再经过一次 NAT。网络拓扑为：

```
Host → [publish-port 8888] → VM eth0 (198.19.0.2)
  VM 内部: docker0 bridge (172.17.0.1) → vethXXX → container (172.17.0.x)
  Docker 容器端口需映射到 VM eth0 才能从外部访问
```
