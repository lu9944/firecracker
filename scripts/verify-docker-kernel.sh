#!/bin/bash
# Copyright 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# verify-docker-kernel.sh
# Verify that a kernel .config file has all required Docker support options
set -euo pipefail

KERNEL_CONFIG="${1:?Usage: $0 <kernel.config file>}"

if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "Error: File not found: $KERNEL_CONFIG" >&2
    exit 1
fi

PASS=0
FAIL=0

check() {
    local name="$1"
    local config="$2"
    local expected="$3"

    actual=$(grep "^$config=" "$KERNEL_CONFIG" 2>/dev/null | cut -d= -f2 || true)
    if [ "$actual" = "$expected" ]; then
        printf "  \u2705 %-45s %s=%s\n" "$name" "$config" "$expected"
        PASS=$((PASS + 1))
    else
        printf "  \u274c %-45s %s=%s (actual: %s)\n" "$name" "$config" "$expected" "${actual:-missing}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Verifying kernel Docker support: $KERNEL_CONFIG ==="

echo ""
echo "--- cgroups ---"
check "cgroups"          "CONFIG_CGROUPS"          "y"
check "cgroup memory"    "CONFIG_MEMCG"            "y"
check "cgroup devices"   "CONFIG_CGROUP_DEVICE"    "y"
check "cgroup freezer"   "CONFIG_CGROUP_FREEZER"   "y"
check "cgroup pids"      "CONFIG_CGROUP_PIDS"      "y"
check "blk cgroup"       "CONFIG_BLK_CGROUP"       "y"
check "cgroup net prio"  "CONFIG_CGROUP_NET_PRIO"  "y"

echo ""
echo "--- namespaces ---"
check "namespaces"       "CONFIG_NAMESPACES"       "y"
check "user ns"          "CONFIG_USER_NS"          "y"
check "pid ns"           "CONFIG_PID_NS"           "y"
check "net ns"           "CONFIG_NET_NS"           "y"
check "ipc ns"           "CONFIG_IPC_NS"           "y"
check "uts ns"           "CONFIG_UTS_NS"           "y"

echo ""
echo "--- network devices ---"
check "veth"             "CONFIG_VETH"             "y"
check "bridge"           "CONFIG_BRIDGE"           "y"
check "TUN/TAP"          "CONFIG_TUN"              "y"
check "dummy"            "CONFIG_DUMMY"            "y"
check "macvlan"          "CONFIG_MACVLAN"          "y"
check "ipvlan"           "CONFIG_IPVLAN"           "y"
check "vxlan"            "CONFIG_VXLAN"            "y"

echo ""
echo "--- storage drivers ---"
check "overlayfs"        "CONFIG_OVERLAY_FS"       "y"
check "ext4"             "CONFIG_EXT4_FS"          "y"
check "loop device"      "CONFIG_BLK_DEV_LOOP"     "y"

echo ""
echo "--- netfilter/iptables ---"
check "netfilter"        "CONFIG_NETFILTER"        "y"
check "iptables"         "CONFIG_IP_NF_IPTABLES"   "y"
check "ip6tables"        "CONFIG_IP6_NF_IPTABLES"  "y"
check "nat"              "CONFIG_NF_NAT"           "y"
check "MARK target"      "CONFIG_NETFILTER_XT_TARGET_MARK"     "y"
check "MARK match"       "CONFIG_NETFILTER_XT_MATCH_MARK"      "y"
check "physdev match"    "CONFIG_NETFILTER_XT_MATCH_PHYSDEV"   "y"
check "connmark tgt"     "CONFIG_NETFILTER_XT_TARGET_CONNMARK" "y"
check "connmark match"   "CONFIG_NETFILTER_XT_MATCH_CONNMARK"  "y"
check "LOG target"       "CONFIG_NETFILTER_XT_TARGET_LOG"      "y"
check "NFLOG target"     "CONFIG_NETFILTER_XT_TARGET_NFLOG"    "y"
check "comment match"    "CONFIG_NETFILTER_XT_MATCH_COMMENT"   "y"
check "multiport"        "CONFIG_NETFILTER_XT_MATCH_MULTIPORT" "y"
check "limit match"      "CONFIG_NETFILTER_XT_MATCH_LIMIT"     "y"

echo ""
echo "--- IPVS ---"
check "IPVS"             "CONFIG_IP_VS"            "y"
check "IPVS RR"          "CONFIG_IP_VS_RR"         "y"
check "IPVS NFCT"        "CONFIG_IP_VS_NFCT"       "y"

echo ""
echo "--- security/container ---"
check "seccomp"          "CONFIG_SECCOMP"          "y"
check "seccomp filter"   "CONFIG_SECCOMP_FILTER"   "y"
check "checkpoint/restore" "CONFIG_CHECKPOINT_RESTORE" "y"
check "cgroup bpf"       "CONFIG_CGROUP_BPF"       "y"
check "bpf syscall"      "CONFIG_BPF_SYSCALL"      "y"

echo ""
echo "=== Verification complete: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
