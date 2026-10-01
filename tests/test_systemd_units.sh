#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

socket_unit="$TEST_ROOT/systemd/keepalive.socket"
service_unit="$TEST_ROOT/systemd/keepalive.service"

assert_contains "$socket_unit" 'WantedBy=sockets.target' \
    'socket installs under the desktop-neutral user sockets target'
assert_false 'socket has no graphical-session dependency' \
    grep -Fq graphical-session.target "$socket_unit"
assert_contains "$service_unit" 'BindsTo=keepalive.socket' \
    'service stops when its activation endpoint disappears'
assert_contains "$service_unit" 'PartOf=keepalive.socket' \
    'socket stop and restart operations propagate to the service'
assert_contains "$service_unit" 'After=keepalive.socket' \
    'service ordering keeps the socket endpoint available first'
assert_false 'static service has no install section' grep -Fq '[Install]' "$service_unit"
assert_false 'service has no graphical-session dependency' \
    grep -Fq graphical-session.target "$service_unit"
assert_false 'systemd 242-only RestrictSUIDSGID is absent for the systemd 235 floor' \
    grep -Fq RestrictSUIDSGID "$service_unit"
assert_contains "$service_unit" 'Nice=10' 'daemon runs at a lowered CPU priority'
assert_contains "$service_unit" 'CPUSchedulingPolicy=batch' \
    'daemon uses the batch policy, which still bounds send latency under load'
assert_false 'daemon never uses SCHED_IDLE, which can starve a due send' \
    grep -Eq '^CPUSchedulingPolicy=idle' "$service_unit"
assert_contains "$service_unit" 'IOSchedulingClass=idle' 'daemon block I/O yields to other work'
assert_contains "$service_unit" 'TimerSlackNSec=50ms' 'second-granularity wakeups may coalesce'
assert_contains "$service_unit" 'KillMode=mixed' \
    'stop signals only the daemon, so an in-flight delivery helper is not killed mid-send'
assert_false 'resource caps that need cgroup delegation are not assumed' \
    grep -Eq '^(CPUWeight|CPUQuota|MemoryHigh|MemoryMax|TasksMax)=' "$service_unit"
assert_false 'service has no mount-namespace directive' \
    grep -Eq '^(PrivateTmp|PrivateDevices|ProtectSystem|ProtectHome|ProtectProc|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs)=' "$service_unit"

test_finish
