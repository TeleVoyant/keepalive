#!/usr/bin/env bash
# Update-reload manifests, daemon recovery, installer diagnostics, and TUI re-exec guards.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

TEST_TMP=${TEST_TMP:?}
declare -a STARTED_PIDS=()
declare -gA STARTED_PID_SET=()

# Role: Remember only processes this test starts so cleanup never targets an unrelated PID.
record_started_pid() {
    local pid=$1
    [[ $pid =~ ^[0-9]+$ ]] || return 0
    [[ -n ${STARTED_PID_SET[$pid]+x} ]] && return 0
    STARTED_PID_SET[$pid]=1
    STARTED_PIDS+=("$pid")
}

# Role: Stop every explicitly recorded helper, daemon wrapper, and child process at exit.
cleanup_started_processes() {
    local pid
    for pid in "${STARTED_PIDS[@]-}"; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${STARTED_PIDS[@]-}"; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup_started_processes EXIT

# Role: Execute a command as the isolated unprivileged account in root-based CI.
run_test_user() {
    if ((EUID == 0)); then
        runuser -u nobody -- "$@"
    else
        "$@"
    fi
}

# Role: Poll a private fixture path with a bounded deadline instead of racing a fixed sleep.
wait_for_file() {
    local path=$1
    local tries=0
    while ((tries < 150)); do
        [[ -s $path ]] && return 0
        sleep 0.02
        ((tries += 1))
    done
    return 1
}

# Role: Read one key/value field from a data-only TSV file without collapsing empty values.
read_tsv_field() {
    local file=$1
    local wanted=$2
    local key value extra
    REPLY=''
    [[ -r $file ]] || return 1
    while IFS=$'\t' read -r key value extra; do
        [[ $key == "$wanted" ]] || continue
        REPLY=$value
        return 0
    done <"$file" || true
    return 1
}

# Role: Read one positional field from a published index row while preserving empty columns.
read_index_field() {
    local file=$1
    local wanted_uuid=$2
    local wanted_field=$3
    local line field rest index
    REPLY=''
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        field=${line%%$'\t'*}
        rest=$line
        if [[ $field != "$wanted_uuid" ]]; then
            continue
        fi
        for ((index = 1; index < wanted_field; index += 1)); do
            [[ $rest == *$'\t'* ]] || return 1
            rest=${rest#*$'\t'}
        done
        if [[ $rest == *$'\t'* ]]; then
            REPLY=${rest%%$'\t'*}
        else
            REPLY=$rest
        fi
        return 0
    done <"$file"
    return 1
}

# Role: Write a minimal target checkpoint used only by installer manifest/report probes.
seed_manifest_target() {
    local runtime=$1
    local uuid=$2
    local status=$3
    local dir="$runtime/targets/$uuid"
    mkdir -p "$dir"
    chmod 700 "$dir"
    printf 'uuid\t%s\nstatus\t%s\nname\t\ndirectory\t\n' "$uuid" "$status" >"$dir/state.tsv"
    chmod 600 "$dir/state.tsv"
}

# Role: Write one complete index row with caller-selected name, directory, and status.
write_index_row() {
    local runtime=$1
    local uuid=$2
    local name=$3
    local directory=$4
    local status=$5
    printf '%s\tClaude\t%s\t%s\t%s\t10\t12\t0\t0\t600\tMESSAGE_ENTER\t0\t\t\tkonsole\n' \
        "$uuid" "$name" "$directory" "$status" >>"$runtime/index.tsv"
}

# Role: Create the persistent stub that proves daemon ownership by holding manager.lock open.
write_daemon_stub() {
    DAEMON_STUB="$TEST_TMP/keepalive-daemon-stub"
    cat >"$DAEMON_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ -n ${FAKE_DAEMON_RUNTIME:-} ]]; then
    exec 9>>"$FAKE_DAEMON_RUNTIME/manager.lock"
fi
if [[ -n ${FAKE_HELPER_PID_FILE:-} ]]; then
    printf '%s\n' "$$" >"$FAKE_HELPER_PID_FILE"
fi
exec 8<> <(:)
while :; do
    read -r -t 30 -u 8 _ || :
done
STUB
    chmod +x "$DAEMON_STUB"
}

# Role: Build a two-session qdbus fixture for the real daemon/CLI integration path.
write_qdbus_fixture() {
    QDBUS_FIXTURE="$TEST_TMP/qdbus-two-session"
    cat >"$QDBUS_FIXTURE" <<'QDBUS'
#!/usr/bin/env bash
set -Eeuo pipefail
if (($# == 0)); then
    printf 'org.kde.konsole-100\n'
    exit 0
fi
if [[ $1 == org.kde.konsole-100 && $# == 1 ]]; then
    printf '/Sessions/1\n/Sessions/2\n'
    exit 0
fi
service=$1
path=$2
method=${3-}
[[ $service == org.kde.konsole-100 ]] || exit 1
case $path in
    /Sessions/1) uuid=${FAKE_UUID_1:?}; pid_file=${FAKE_PID_FILE_1:?} ;;
    /Sessions/2) uuid=${FAKE_UUID_2:?}; pid_file=${FAKE_PID_FILE_2:?} ;;
    *) exit 1 ;;
esac
pid=$(<"$pid_file")
case $method in
    org.kde.konsole.Session.shellSessionId) printf '%s\n' "$uuid" ;;
    org.kde.konsole.Session.processId) printf '%s\n' "$pid" ;;
    org.kde.konsole.Session.foregroundProcessId) printf '%s\n' "$pid" ;;
    org.kde.konsole.Session.sendText)
        if [[ -n ${FAKE_SEND_LOG:-} ]]; then printf '%s\n' "${4-}" >>"$FAKE_SEND_LOG"; fi
        ;;
    *) exit 1 ;;
esac
QDBUS
    chmod +x "$QDBUS_FIXTURE"
}

# Role: Build the isolated environment assignments shared by the real daemon and public CLI.
service_environment() {
    printf '%s\0' \
        "HOME=$HOME" "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
        "XDG_STATE_HOME=$XDG_STATE_HOME" "KEEPALIVE_QDBUS=$QDBUS_FIXTURE" \
        "FAKE_UUID_1=$UUID_ONE" "FAKE_UUID_2=$UUID_TWO" \
        "FAKE_PID_FILE_1=$AI_PID_FILE_ONE" "FAKE_PID_FILE_2=$AI_PID_FILE_TWO" \
        "FAKE_SEND_LOG=$SEND_LOG" "KEEPALIVE_MONOTONIC_FILE=$MONOTONIC_FILE" \
        'KEEPALIVE_KONSOLE_ENABLED=1' 'KEEPALIVE_ORCA_ENABLED=0' \
        'KEEPALIVE_QDBUS_TIMEOUT=1' 'KEEPALIVE_DISCOVERY_INTERVAL=1' \
        'KEEPALIVE_IDLE_DISCOVERY_INTERVAL=1' 'KEEPALIVE_HEALTH_INTERVAL=1' \
        'KEEPALIVE_STATUS_INTERVAL=1' 'KEEPALIVE_SUSPEND_GAP=10' \
        'KEEPALIVE_SEND_GAP=0' 'KEEPALIVE_RESPONSE_TIMEOUT_MS=4000' \
        'PATH=/usr/bin:/bin'
}

# Role: Start one isolated Claude-shaped process and return its real PID through REPLY.
start_fake_ai() {
    local work=$1
    local pid_file=$2
    local wrapper
    rm -f -- "$pid_file"
    if ((EUID == 0)); then
        runuser -u nobody -- env FAKE_HELPER_PID_FILE="$pid_file" bash -c \
            "cd '$work' && exec '$AI_STUB'" >/dev/null 2>&1 &
    else
        env FAKE_HELPER_PID_FILE="$pid_file" bash -c \
            "cd '$work' && exec '$AI_STUB'" >/dev/null 2>&1 &
    fi
    wrapper=$!
    record_started_pid "$wrapper"
    wait_for_file "$pid_file" || return 1
    IFS= read -r REPLY <"$pid_file" || true
    [[ $REPLY =~ ^[0-9]+$ ]] || return 1
    record_started_pid "$REPLY"
    STARTED_WRAPPER=$wrapper
}

# Role: Execute the public keepalive CLI with the exact isolated daemon environment.
run_keepalive() {
    local -a environment=()
    local item
    while IFS= read -r -d '' item; do environment+=("$item"); done < <(service_environment)
    run_test_user env "${environment[@]}" "$TEST_ROOT/keepalive" "$@"
}

# Role: Start the real isolated daemon and retain its shell wrapper PID for cleanup.
start_real_daemon() {
    local log=$1
    local -a environment=()
    local item wrapper
    while IFS= read -r -d '' item; do environment+=("$item"); done < <(service_environment)
    run_test_user env "${environment[@]}" "$TEST_ROOT/keepalive" --service >"$log" 2>&1 &
    wrapper=$!
    record_started_pid "$wrapper"
    REAL_DAEMON_WRAPPER=$wrapper
}

# Role: Wait for a real daemon to publish an online service state and record its PID.
wait_real_daemon_online() {
    local tries=0
    local state pid key value extra
    while ((tries < 200)); do
        state=''
        pid=''
        if [[ -r $KA_SERVICE_STATE_FILE ]]; then
            while IFS=$'\t' read -r key value extra; do
                case $key in
                    state) state=$value ;;
                    pid) pid=$value ;;
                esac
            done <"$KA_SERVICE_STATE_FILE" || true
            if [[ $state == online && $pid =~ ^[0-9]+$ ]]; then
                REAL_DAEMON_PID=$pid
                record_started_pid "$pid"
                return 0
            fi
        fi
        sleep 0.02
        ((tries += 1))
    done
    return 1
}

# Role: Gracefully stop the currently recorded real daemon and wait for its wrapper.
stop_real_daemon() {
    [[ ${REAL_DAEMON_PID:-} =~ ^[0-9]+$ ]] || return 1
    kill "$REAL_DAEMON_PID" 2>/dev/null || true
    [[ ${REAL_DAEMON_WRAPPER:-} =~ ^[0-9]+$ ]] && wait "$REAL_DAEMON_WRAPPER" 2>/dev/null || true
}

# Role: Start an installer-shim daemon and return its published PID through REPLY.
start_install_stub() {
    local case_root=$1
    local pid_file="$case_root/old-daemon.pid"
    local wrapper
    run_install_user env "FAKE_HELPER_PID_FILE=$pid_file" \
        "FAKE_DAEMON_RUNTIME=$case_root/runtime/keepalive" "$DAEMON_STUB" --service \
        >/dev/null 2>&1 &
    wrapper=$!
    record_started_pid "$wrapper"
    wait_for_file "$pid_file" || return 1
    IFS= read -r REPLY <"$pid_file" || true
    [[ $REPLY =~ ^[0-9]+$ ]] || return 1
    record_started_pid "$REPLY"
    INSTALL_OLD_WRAPPER=$wrapper
    INSTALL_OLD_PID=$REPLY
}

# Role: Select fresh isolated XDG and fake-systemd roots for one installer scenario.
new_install_case() {
    local name=$1
    CASE_ROOT="$TEST_TMP/install-$name"
    rm -rf -- "$CASE_ROOT"
    export HOME="$CASE_ROOT/home"
    export XDG_CONFIG_HOME="$CASE_ROOT/config"
    export XDG_RUNTIME_DIR="$CASE_ROOT/runtime"
    export XDG_STATE_HOME="$CASE_ROOT/state"
    export FAKE_MANAGER_CONFIG_HOME="$XDG_CONFIG_HOME"
    export FAKE_SYSTEMD_STATE_DIR="$CASE_ROOT/fake-systemd"
    export FAKE_RESTART_PID_LOG="$CASE_ROOT/restart-pids"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" \
        "$FAKE_SYSTEMD_STATE_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    : >"$FAKE_SYSTEMD_STATE_DIR/calls"
    : >"$FAKE_RESTART_PID_LOG"
}

# Role: Run installer commands with only the existing-style fake systemd shim on PATH.
run_install_user() {
    local command=$1
    shift
    local -a environment=(
        "HOME=$HOME" "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
        "XDG_STATE_HOME=$XDG_STATE_HOME" "FAKE_MANAGER_CONFIG_HOME=$FAKE_MANAGER_CONFIG_HOME"
        "FAKE_SYSTEMD_STATE_DIR=$FAKE_SYSTEMD_STATE_DIR" "FAKE_RESTART_PID_LOG=$FAKE_RESTART_PID_LOG"
        "FAKE_DAEMON_HELPER=$DAEMON_STUB" "FAKE_DAEMON_RUNTIME=$XDG_RUNTIME_DIR/keepalive"
        "PATH=$INSTALL_FAKEBIN:/usr/bin:/bin"
    )
    if ((EUID == 0)); then
        runuser -u nobody -- env "${environment[@]}" "$command" "$@"
    else
        env "${environment[@]}" "$command" "$@"
    fi
}

# Role: Create the fake systemctl shim that expresses installer lifecycle branches hermetically.
write_install_systemctl() {
    INSTALL_FAKEBIN="$TEST_TMP/install-fakebin"
    mkdir -p "$INSTALL_FAKEBIN"
    cat >"$INSTALL_FAKEBIN/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -u
state_dir=${FAKE_SYSTEMD_STATE_DIR:?}
manager_config=${FAKE_MANAGER_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}
unit_root=$(readlink -m -- "$manager_config")/systemd/user
mkdir -p "$state_dir"
printf '%s\n' "$*" >>"$state_dir/calls"
[[ ${1-} == --user ]] && shift
command=${1-}
[[ -z $command ]] || shift
case $command in
    show-environment)
        printf 'HOME=%s\n' "$HOME"
        printf 'XDG_CONFIG_HOME=%s\n' "$manager_config"
        printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR-}"
        ;;
    is-active)
        [[ ${1-} == --quiet ]] && shift
        unit=${1-}
        if [[ -e $state_dir/active.$unit ]]; then printf 'active\n'; else printf 'inactive\n'; exit 3; fi
        ;;
    is-enabled)
        [[ ${1-} == --quiet ]] && shift
        unit=${1-}
        if [[ -r $state_dir/enable-state.$unit ]]; then
            value=$(<"$state_dir/enable-state.$unit")
            printf '%s\n' "$value"
            case $value in enabled|enabled-runtime|static) : ;; *) exit 1 ;; esac
        elif [[ $unit == keepalive.service && -r $unit_root/$unit ]] \
            && ! grep -Fq '[Install]' "$unit_root/$unit"; then
            printf 'static\n'
        else
            printf 'disabled\n'
            exit 1
        fi
        ;;
    disable)
        now=0
        while (($#)); do
            [[ $1 == --now ]] && now=1
            case $1 in keepalive.socket|keepalive.service)
                rm -f -- "$state_dir/enable-state.$1"
                ((now == 0)) || rm -f -- "$state_dir/active.$1"
                ;;
            esac
            shift
        done
        ;;
    enable)
        now=0
        units=()
        while (($#)); do
            [[ $1 == --now ]] && now=1
            [[ $1 == --now ]] || [[ $1 == --runtime ]] || units+=("$1")
            shift
        done
        for unit in "${units[@]}"; do
            printf 'enabled\n' >"$state_dir/enable-state.$unit"
            ((now == 0)) || : >"$state_dir/active.$unit"
            if [[ $unit == keepalive.socket ]]; then
                mkdir -p "$unit_root/sockets.target.wants"
                ln -sfn -- ../keepalive.socket "$unit_root/sockets.target.wants/keepalive.socket"
            fi
        done
        ;;
    daemon-reload)
        ;;
    restart)
        for unit in "$@"; do
            if [[ $unit == keepalive.service && -n ${FAKE_DAEMON_HELPER:-} ]]; then
                "$FAKE_DAEMON_HELPER" --service >/dev/null 2>&1 &
                new_pid=$!
                printf '%s\n' "$new_pid" >>"$FAKE_RESTART_PID_LOG"
                runtime=${XDG_RUNTIME_DIR:?}/keepalive
                printf 'state\tonline\npid\t%s\nversion\ttest\nupdated\ttest\n' "$new_pid" >"$runtime/service.state"
            fi
        done
        ;;
    start)
        for unit in "$@"; do : >"$state_dir/active.$unit"; done
        ;;
esac
SYSTEMCTL
    chmod +x "$INSTALL_FAKEBIN/systemctl"
}

# Role: Build a hermetic systemctl-failed and no-op-sleep shim for wait probes.
write_wait_systemctl() {
    WAIT_FAKEBIN="$TEST_TMP/wait-fakebin"
    WAIT_SYSTEMCTL_CALLS="$TEST_TMP/wait-systemctl.calls"
    mkdir -p "$WAIT_FAKEBIN"
    : >"$WAIT_SYSTEMCTL_CALLS"
    export WAIT_SYSTEMCTL_CALLS
    cat >"$WAIT_FAKEBIN/systemctl" <<'WAITCTL'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${WAIT_SYSTEMCTL_CALLS:?}"
[[ $* == '--user is-failed --quiet keepalive.service' ]]
WAITCTL
    cat >"$WAIT_FAKEBIN/sleep" <<'WAITSLEEP'
#!/usr/bin/env bash
exit 0
WAITSLEEP
    chmod +x "$WAIT_FAKEBIN/systemctl" "$WAIT_FAKEBIN/sleep"
}

# Role: Write one service.state fixture with a selected daemon lifecycle state.
write_service_state() {
    local runtime=$1
    local state=$2
    local pid=$3
    printf 'state\t%s\npid\t%s\nversion\ttest\nupdated\ttest\n' "$state" "$pid" >"$runtime/service.state"
}

# Role: Make a newly-created installer case writable by the unprivileged shim account.
prepare_install_case_owner() {
    if ((EUID == 0)); then
        test_chown_for_unprivileged "$CASE_ROOT"
        chmod 755 "$CASE_ROOT"
    fi
}

# Extract only the contiguous installer manifest/pid/wait/report functions; sourcing the
# installer itself would execute its root-checking main entrypoint.
INSTALL_FUNCTIONS="$TEST_TMP/install-functions.sh"
sed -n '/^# Role: Put the live daemon runtime directory/,/^# Role: Classify a systemd unit/{/^# Role: Classify a systemd unit/!p;}' \
    "$TEST_ROOT/scripts/install.sh" >"$INSTALL_FUNCTIONS"
chmod 644 "$INSTALL_FUNCTIONS"
# Root-based CI runs these probes as nobody so chmod 000 really is unreadable to the probe.
if ((EUID == 0)); then chmod 755 "$TEST_TMP"; fi
INSTALL_PROBE_RUNNER="$TEST_TMP/install-probe-runner.sh"
cat >"$INSTALL_PROBE_RUNNER" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$1"
case $2 in
    manifest) install_target_manifest "$3" ;;
    report) install_report_reload "$3" "$4" ;;
    *) exit 2 ;;
esac
PROBE
chmod 755 "$INSTALL_PROBE_RUNNER"
# shellcheck source=/dev/null
source "$INSTALL_FUNCTIONS"

# Role: Run one extracted installer helper as the isolated test account when necessary.
run_install_probe() {
    local mode=$1
    local runtime=$2
    local manifest=${3-}
    if ((EUID == 0)); then
        runuser -u nobody -- "$INSTALL_PROBE_RUNNER" "$INSTALL_FUNCTIONS" "$mode" "$runtime" "$manifest"
    else
        "$INSTALL_PROBE_RUNNER" "$INSTALL_FUNCTIONS" "$mode" "$runtime" "$manifest"
    fi
}

write_daemon_stub

# ----- Installer helper unit probes ------------------------------------------------------
UNIT_RUNTIME="$TEST_TMP/install-unit-runtime"
mkdir -p "$UNIT_RUNTIME/targets" "$UNIT_RUNTIME/logs"
chmod 700 "$UNIT_RUNTIME" "$UNIT_RUNTIME/targets"
: >"$UNIT_RUNTIME/manager.lock"
chmod 600 "$UNIT_RUNTIME/manager.lock"
UNIT_UUID_ONE='11111111-1111-4111-8111-111111111111'
UNIT_UUID_TWO='22222222-2222-4222-8222-222222222222'
UNIT_UUID_THREE='33333333-3333-4333-8333-333333333333'
UNIT_UUID_FOUR='44444444-4444-4444-8444-444444444444'
seed_manifest_target "$UNIT_RUNTIME" "$UNIT_UUID_ONE" ACTIVE
seed_manifest_target "$UNIT_RUNTIME" "$UNIT_UUID_TWO" PAUSED
seed_manifest_target "$UNIT_RUNTIME" "$UNIT_UUID_THREE" ACTIVE
seed_manifest_target "$UNIT_RUNTIME" "$UNIT_UUID_FOUR" PAUSED
mkdir -p "$UNIT_RUNTIME/targets/symlink-target" "$UNIT_RUNTIME/targets/symlink-state"
ln -s "$UNIT_RUNTIME/targets/$UNIT_UUID_ONE/state.tsv" "$UNIT_RUNTIME/targets/symlink-state/state.tsv"
ln -s "$UNIT_RUNTIME/targets/$UNIT_UUID_ONE" "$UNIT_RUNTIME/targets/symlink-target/record"
if ((EUID == 0)) && id nobody >/dev/null 2>&1; then
    chown nobody:"$(id -g nobody)" "$UNIT_RUNTIME/targets/$UNIT_UUID_THREE/state.tsv"
    FOREIGN_MANIFEST_SUPPORTED=1
else
    FOREIGN_MANIFEST_SUPPORTED=0
fi
manifest=$(install_target_manifest "$UNIT_RUNTIME")
if ((FOREIGN_MANIFEST_SUPPORTED == 1)); then
    expected_manifest=$'11111111-1111-4111-8111-111111111111\tACTIVE\n22222222-2222-4222-8222-222222222222\tPAUSED\n44444444-4444-4444-8444-444444444444\tPAUSED'
else
    expected_manifest=$'11111111-1111-4111-8111-111111111111\tACTIVE\n22222222-2222-4222-8222-222222222222\tPAUSED\n33333333-3333-4333-8333-333333333333\tACTIVE\n44444444-4444-4444-8444-444444444444\tPAUSED'
fi
assert_eq "$expected_manifest" "$manifest" \
    'manifest reads only owned real state.tsv files and keeps empty fields harmless'
if ((FOREIGN_MANIFEST_SUPPORTED == 1)); then
    assert_false 'foreign-owned state.tsv is excluded from the manifest' grep -Fq "$UNIT_UUID_THREE" <<<"$manifest"
else
    test_skip 'foreign-owned state.tsv is excluded from the manifest' 'non-root test account cannot create a foreign-owned file'
fi

: >"$UNIT_RUNTIME/index.tsv"
write_index_row "$UNIT_RUNTIME" "$UNIT_UUID_ONE" '' '' ACTIVE
write_index_row "$UNIT_RUNTIME" "$UNIT_UUID_TWO" 'Paused' '/paused' ACTIVE
write_index_row "$UNIT_RUNTIME" "$UNIT_UUID_FOUR" 'Available' '/available' AVAILABLE
report_out="$TEST_TMP/install-report.out"
report_err="$TEST_TMP/install-report.err"
report_rc=0
install_report_reload "$UNIT_RUNTIME" "$manifest" >"$report_out" 2>"$report_err" || report_rc=$?
assert_eq 0 "$report_rc" 'reload report completes even with empty index name and directory columns'
assert_contains "$report_out" 'Reloaded 2 running keep-alive(s)' \
    'reload report counts only restored non-AVAILABLE targets'
assert_contains "$report_out" "Keep-alive $UNIT_UUID_TWO was PAUSED and is now ACTIVE" \
    'reload report counts and describes changed statuses'
assert_contains "$report_err" '2 keep-alive(s) did not come back' \
    'reload report counts both absent and AVAILABLE-only rows as missing'
assert_contains "$report_err" "$UNIT_UUID_FOUR (PAUSED)" \
    'reload report identifies an AVAILABLE row as missing'

EDGE_RUNTIME="$TEST_TMP/install-manifest-edge"
mkdir -p "$EDGE_RUNTIME/targets/missing-fields" "$EDGE_RUNTIME/targets/unreadable-target"
printf 'name\tmissing identity\n' >"$EDGE_RUNTIME/targets/missing-fields/state.tsv"
printf 'uuid\tignored\nstatus\tACTIVE\n' >"$EDGE_RUNTIME/targets/unreadable-target/state.tsv"
if ((EUID == 0)); then test_chown_for_unprivileged "$EDGE_RUNTIME"; fi
chmod 000 "$EDGE_RUNTIME/targets/unreadable-target/state.tsv"
EDGE_MANIFEST=$(run_install_probe manifest "$EDGE_RUNTIME")
printf '%s\n' "$EDGE_MANIFEST" >"$TEST_TMP/edge-manifest.out"
expected_edge_manifest=$'missing-fields\tUNREADABLE\nunreadable-target\tUNREADABLE'
assert_eq "$expected_edge_manifest" "$EDGE_MANIFEST" \
    'manifest marks unreadable and identity-incomplete checkpoints by directory name'
assert_contains "$TEST_TMP/edge-manifest.out" $'missing-fields\tUNREADABLE' \
    'manifest reports a readable checkpoint without uuid/status as UNREADABLE'
assert_contains "$TEST_TMP/edge-manifest.out" $'unreadable-target\tUNREADABLE' \
    'manifest reports an unreadable checkpoint as UNREADABLE'
: >"$EDGE_RUNTIME/index.tsv"
chmod 000 "$EDGE_RUNTIME/index.tsv"
edge_report_rc=0
run_install_probe report "$EDGE_RUNTIME" "$EDGE_MANIFEST" \
    >"$TEST_TMP/edge-report.out" 2>"$TEST_TMP/edge-report.err" || edge_report_rc=$?
assert_eq 0 "$edge_report_rc" 'reload reporting remains successful with an unreadable index'
assert_contains "$TEST_TMP/edge-report.out" 'Reloaded 0 running keep-alive(s)' \
    'reload reporting treats every manifest target as missing when index.tsv is unreadable'
assert_contains "$TEST_TMP/edge-report.err" '2 keep-alive(s) did not come back' \
    'reload reporting warns for unreadable-index targets'
assert_contains "$TEST_TMP/edge-report.err" 'unreadable-target (UNREADABLE)' \
    'reload reporting names the unreadable checkpoint as missing'
chmod 600 "$EDGE_RUNTIME/index.tsv" "$EDGE_RUNTIME/targets/unreadable-target/state.tsv"

UNIT_DAEMON_ONE_FILE="$TEST_TMP/unit-daemon-one.pid"
rm -f -- "$UNIT_DAEMON_ONE_FILE"
FAKE_DAEMON_RUNTIME="$UNIT_RUNTIME" FAKE_HELPER_PID_FILE="$UNIT_DAEMON_ONE_FILE" \
    "$DAEMON_STUB" --service >/dev/null 2>&1 &
UNIT_DAEMON_ONE_WRAPPER=$!
record_started_pid "$UNIT_DAEMON_ONE_WRAPPER"
wait_for_file "$UNIT_DAEMON_ONE_FILE"
IFS= read -r UNIT_DAEMON_ONE <"$UNIT_DAEMON_ONE_FILE" || true
record_started_pid "$UNIT_DAEMON_ONE"
write_service_state "$UNIT_RUNTIME" online "$UNIT_DAEMON_ONE"
install_running_daemon_pid "$UNIT_RUNTIME"
assert_eq "$UNIT_DAEMON_ONE" "$REPLY" 'running-daemon probe accepts an online process holding manager.lock'

sleep 30 &
UNIT_IMPOSTOR_PID=$!
record_started_pid "$UNIT_IMPOSTOR_PID"
write_service_state "$UNIT_RUNTIME" online "$UNIT_IMPOSTOR_PID"
assert_false 'running-daemon probe rejects a published PID that does not hold manager.lock' \
    install_running_daemon_pid "$UNIT_RUNTIME"

DAEMON_ALIAS="$TEST_TMP/keepalive-renamed-alias"
ln -sfn -- "$DAEMON_STUB" "$DAEMON_ALIAS"
ALIAS_PID_FILE="$TEST_TMP/alias-daemon.pid"
FAKE_DAEMON_RUNTIME="$UNIT_RUNTIME" FAKE_HELPER_PID_FILE="$ALIAS_PID_FILE" \
    "$DAEMON_ALIAS" --service >/dev/null 2>&1 &
UNIT_ALIAS_WRAPPER=$!
record_started_pid "$UNIT_ALIAS_WRAPPER"
wait_for_file "$ALIAS_PID_FILE"
IFS= read -r UNIT_ALIAS_PID <"$ALIAS_PID_FILE" || true
record_started_pid "$UNIT_ALIAS_PID"
write_service_state "$UNIT_RUNTIME" online "$UNIT_ALIAS_PID"
assert_true 'running-daemon probe accepts a differently named daemon holding manager.lock' \
    install_running_daemon_pid "$UNIT_RUNTIME"
assert_eq "$UNIT_ALIAS_PID" "$REPLY" 'lock ownership, not argv naming, identifies the daemon'

UNIT_DAEMON_TWO_FILE="$TEST_TMP/unit-daemon-two.pid"
rm -f -- "$UNIT_DAEMON_TWO_FILE"
FAKE_DAEMON_RUNTIME="$UNIT_RUNTIME" FAKE_HELPER_PID_FILE="$UNIT_DAEMON_TWO_FILE" \
    "$DAEMON_STUB" --service >/dev/null 2>&1 &
UNIT_DAEMON_TWO_WRAPPER=$!
record_started_pid "$UNIT_DAEMON_TWO_WRAPPER"
wait_for_file "$UNIT_DAEMON_TWO_FILE"
IFS= read -r UNIT_DAEMON_TWO <"$UNIT_DAEMON_TWO_FILE" || true
record_started_pid "$UNIT_DAEMON_TWO"
write_service_state "$UNIT_RUNTIME" online "$UNIT_DAEMON_TWO"
assert_true 'the replacement daemon fixture receives a distinct PID' test "$UNIT_DAEMON_TWO" -ne "$UNIT_DAEMON_ONE"
assert_true 'wait-for-new-daemon accepts a newly published online PID' \
    install_wait_for_new_daemon "$UNIT_RUNTIME" "$UNIT_DAEMON_ONE"
write_service_state "$UNIT_RUNTIME" stopped "$UNIT_DAEMON_TWO"
assert_false 'running-daemon probe rejects a non-online service state' install_running_daemon_pid "$UNIT_RUNTIME"
kill "$UNIT_ALIAS_PID" 2>/dev/null || true
wait "$UNIT_ALIAS_PID" 2>/dev/null || true
write_service_state "$UNIT_RUNTIME" online "$UNIT_ALIAS_PID"
assert_false 'running-daemon probe rejects a stale published PID' install_running_daemon_pid "$UNIT_RUNTIME"
kill "$UNIT_IMPOSTOR_PID" 2>/dev/null || true
kill "$UNIT_DAEMON_ONE" 2>/dev/null || true
kill "$UNIT_DAEMON_TWO" 2>/dev/null || true
wait "$UNIT_IMPOSTOR_PID" 2>/dev/null || true
wait "$UNIT_DAEMON_ONE" 2>/dev/null || true
wait "$UNIT_DAEMON_TWO" 2>/dev/null || true

WAIT_RUNTIME="$TEST_TMP/install-wait-runtime"
mkdir -p "$WAIT_RUNTIME"
: >"$WAIT_RUNTIME/manager.lock"
write_service_state "$WAIT_RUNTIME" online 999991
write_wait_systemctl
old_path=$PATH
PATH="$WAIT_FAKEBIN:/usr/bin:/bin"
wait_started=$SECONDS
wait_rc=0
install_wait_for_new_daemon "$WAIT_RUNTIME" 999991 || wait_rc=$?
wait_elapsed=$((SECONDS - wait_started))
PATH=$old_path
assert_eq 1 "$wait_rc" 'wait-for-new-daemon returns failure when systemctl reports the unit failed'
assert_eq 1 "$(wc -l <"$WAIT_SYSTEMCTL_CALLS")" \
    'wait-for-new-daemon checks systemctl failure after its bounded polling interval'
assert_true 'systemctl failure short-circuits the nominal 60-second wait' test "$wait_elapsed" -lt 10

WAIT_PUBLISH_PID_FILE="$TEST_TMP/wait-published.pid"
write_service_state "$WAIT_RUNTIME" online 999992
(
    sleep 0.4
    FAKE_DAEMON_RUNTIME="$WAIT_RUNTIME" FAKE_HELPER_PID_FILE="$WAIT_PUBLISH_PID_FILE" \
        "$DAEMON_STUB" --service >/dev/null 2>&1 &
    wait_published_pid=$!
    printf 'state\tonline\npid\t%s\nversion\ttest\nupdated\ttest\n' "$wait_published_pid" \
        >"$WAIT_RUNTIME/service.state"
    wait "$wait_published_pid" 2>/dev/null || true
) &
WAIT_PUBLISHER=$!
record_started_pid "$WAIT_PUBLISHER"
wait_rc=0
PATH="$old_path"
install_wait_for_new_daemon "$WAIT_RUNTIME" 999992 || wait_rc=$?
assert_eq 0 "$wait_rc" 'wait-for-new-daemon accepts a new online PID published after polling begins'
wait_for_file "$WAIT_PUBLISH_PID_FILE"
IFS= read -r WAIT_PUBLISHED_PID <"$WAIT_PUBLISH_PID_FILE" || true
record_started_pid "$WAIT_PUBLISHED_PID"
kill "$WAIT_PUBLISHED_PID" 2>/dev/null || true
wait "$WAIT_PUBLISHED_PID" 2>/dev/null || true
wait "$WAIT_PUBLISHER" 2>/dev/null || true

# ----- Real daemon/CLI recovery ----------------------------------------------------------
source_core
UUID_ONE='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
UUID_TWO='bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
AI_STUB="$TEST_TMP/claude"
AI_WORK_ONE="$TEST_TMP/work-one"
AI_WORK_TWO="$TEST_TMP/work-two"
AI_PID_FILE_ONE="$TEST_TMP/ai-one.pid"
AI_PID_FILE_TWO="$TEST_TMP/ai-two.pid"
SEND_LOG="$TEST_TMP/send.log"
MONOTONIC_FILE="$TEST_TMP/monotonic"
mkdir -p "$AI_WORK_ONE" "$AI_WORK_TWO"
cat >"$AI_STUB" <<'AI'
#!/usr/bin/env bash
printf '%s\n' "$$" >"${FAKE_HELPER_PID_FILE:?}"
exec 9<> <(:)
while :; do
    read -r -t 30 -u 9 _ || :
done
AI
chmod +x "$AI_STUB"
write_qdbus_fixture
: >"$SEND_LOG"
printf '1000\n' >"$MONOTONIC_FILE"
ka_profile_init_defaults
ka_write_scalar "$KA_PROFILE_DIR/main_interval" 12
ka_write_scalar "$KA_PROFILE_DIR/secondary_enabled" 0
rm -f -- "$KA_PROFILE_DIR/messages"/[0-9][0-9][0-9]
ka_write_scalar "$KA_PROFILE_DIR/messages/001" ping
ka_write_scalar "$KA_PROFILE_DIR/messages/002" pong
if ((EUID == 0)); then
    test_chown_for_unprivileged "$TEST_TMP"
    chmod 755 "$TEST_TMP"
fi

start_fake_ai "$AI_WORK_ONE" "$AI_PID_FILE_ONE"
AI_ONE_PID=$REPLY
AI_ONE_WRAPPER=$STARTED_WRAPPER
start_fake_ai "$AI_WORK_TWO" "$AI_PID_FILE_TWO"
AI_TWO_PID=$REPLY
AI_TWO_WRAPPER=$STARTED_WRAPPER
assert_true 'two isolated recognized AI processes start for the real daemon fixture' \
    test -r "$AI_PID_FILE_ONE" -a -r "$AI_PID_FILE_TWO"

REAL_SERVICE_LOG="$TEST_TMP/real-service.log"
start_real_daemon "$REAL_SERVICE_LOG"
if wait_real_daemon_online; then
    assert_true 'real qdbus-backed daemon publishes an online service state' true
else
    assert_true 'real qdbus-backed daemon publishes an online service state' false
    assert_contains "$REAL_SERVICE_LOG" 'keepalive' 'daemon failure leaves a diagnostic log'
    test_finish
    exit
fi

INITIAL_LIST="$TEST_TMP/initial-list"
run_keepalive list >"$INITIAL_LIST"
assert_contains "$INITIAL_LIST" 'work-one' 'public list reaches the first isolated discovered session'
assert_contains "$INITIAL_LIST" 'work-two' 'public list exposes the second isolated discovered session'
assert_eq ok "$(run_keepalive create "$UUID_ONE")" 'public CLI creates the ACTIVE keep-alive'
assert_eq ok "$(run_keepalive create "$UUID_TWO")" 'public CLI creates the second keep-alive'
assert_eq ok "$(run_keepalive pause "$UUID_TWO")" 'public CLI pauses the second keep-alive'
assert_eq ok "$(run_keepalive send "$UUID_ONE")" 'public CLI sends the first rotation message'

run_keepalive list --json >"$TEST_TMP/pre-tick.json"
read_index_field "$KA_INDEX_FILE" "$UUID_ONE" 5; assert_eq ACTIVE "$REPLY" 'ACTIVE target status is published before restart'
read_index_field "$KA_INDEX_FILE" "$UUID_TWO" 5; assert_eq PAUSED "$REPLY" 'PAUSED target status is published before restart'
read_index_field "$KA_INDEX_FILE" "$UUID_ONE" 6; ACTIVE_BEFORE=$REPLY
read_index_field "$KA_INDEX_FILE" "$UUID_TWO" 6; PAUSED_BEFORE=$REPLY
read_tsv_field "$KA_RUNTIME_DIR/targets/$UUID_ONE/state.tsv" main_index; ROTATION_BEFORE=$REPLY
assert_eq 12 "$ACTIVE_BEFORE" 'manual send resets the active countdown to its configured interval'
assert_eq 12 "$PAUSED_BEFORE" 'pause preserves the configured countdown'
assert_eq 1 "$ROTATION_BEFORE" 'manual message delivery advances the persisted rotation index'

printf '1003\n' >"$MONOTONIC_FILE"
run_keepalive status >/dev/null
run_keepalive status >/dev/null
run_keepalive list --json >"$TEST_TMP/post-tick.json"
read_index_field "$KA_INDEX_FILE" "$UUID_ONE" 6; ACTIVE_AFTER=$REPLY
read_index_field "$KA_INDEX_FILE" "$UUID_TWO" 6; PAUSED_AFTER=$REPLY
assert_true 'ACTIVE countdown advances under the injected monotonic clock' test "$ACTIVE_AFTER" -lt "$ACTIVE_BEFORE"
assert_true 'ACTIVE countdown remains positive before graceful stop' test "$ACTIVE_AFTER" -gt 0
assert_eq "$PAUSED_BEFORE" "$PAUSED_AFTER" 'PAUSED countdown does not advance while the daemon ticks'

ACTIVE_STATE_FILE="$KA_RUNTIME_DIR/targets/$UUID_ONE/state.tsv"
PAUSED_STATE_FILE="$KA_RUNTIME_DIR/targets/$UUID_TWO/state.tsv"
stop_real_daemon
read_tsv_field "$ACTIVE_STATE_FILE" main_remaining; ACTIVE_SAVED=$REPLY
read_tsv_field "$PAUSED_STATE_FILE" main_remaining; PAUSED_SAVED=$REPLY
read_tsv_field "$ACTIVE_STATE_FILE" main_index; ROTATION_SAVED=$REPLY
assert_eq "$ACTIVE_AFTER" "$ACTIVE_SAVED" 'graceful TERM flushes the advanced ACTIVE countdown'
assert_eq "$PAUSED_AFTER" "$PAUSED_SAVED" 'graceful TERM preserves the PAUSED countdown'
assert_eq 1 "$ROTATION_SAVED" 'graceful TERM flushes the advanced rotation index'

start_real_daemon "$TEST_TMP/real-service-restarted.log"
if wait_real_daemon_online; then
    assert_true 'new daemon starts from the same isolated runtime tree' true
else
    assert_true 'new daemon starts from the same isolated runtime tree' false
    assert_contains "$TEST_TMP/real-service-restarted.log" 'keepalive' 'restart failure leaves a diagnostic log'
    test_finish
    exit
fi
POST_RESTART_LIST="$TEST_TMP/post-restart-list"
run_keepalive list >"$POST_RESTART_LIST"
assert_contains "$POST_RESTART_LIST" 'ACTIVE' 'restarted daemon restores the ACTIVE target status'
assert_contains "$POST_RESTART_LIST" 'PAUSED' 'restarted daemon restores the PAUSED target status'
read_tsv_field "$ACTIVE_STATE_FILE" status; assert_eq ACTIVE "$REPLY" 'recovery checkpoint keeps the ACTIVE status'
read_tsv_field "$PAUSED_STATE_FILE" status; assert_eq PAUSED "$REPLY" 'recovery checkpoint keeps the PAUSED status'
read_tsv_field "$ACTIVE_STATE_FILE" main_remaining; assert_eq "$ACTIVE_SAVED" "$REPLY" 'restarted daemon does not reset the ACTIVE countdown to its full interval'
read_tsv_field "$PAUSED_STATE_FILE" main_remaining; assert_eq "$PAUSED_SAVED" "$REPLY" 'restarted daemon keeps the PAUSED countdown unchanged'
read_tsv_field "$ACTIVE_STATE_FILE" main_index; assert_eq "$ROTATION_SAVED" "$REPLY" 'restarted daemon preserves the message rotation index'
assert_contains "$KA_RUNTIME_DIR/logs/$UUID_ONE.log" 'SERVICE' 'recovery writes a SERVICE event'
assert_contains "$KA_RUNTIME_DIR/logs/$UUID_ONE.log" 'daemon recovered; countdown preserved' \
    'recovery SERVICE event records preserved countdown semantics'
stop_real_daemon

# Role: Capture Konsole delivery calls while probing KEEPALIVE_SEND_GAP validation.
ka_konsole_send_raw() {
    DELIVER_RAW+=("$3")
    return 0
}

# Role: Replace the external delay with a recorded no-op for the gap-validation probe.
sleep() {
    DELIVER_SLEEPS+=("$1")
    return 0
}

DELIVER_RAW=()
DELIVER_SLEEPS=()
KEEPALIVE_SEND_GAP='12.5'
gap_rc=0
ka_konsole_deliver service path MESSAGE_ENTER 'hello' > /dev/null 2>"$TEST_TMP/gap-too-long.err" || gap_rc=$?
assert_eq 0 "$gap_rc" 'Konsole delivery succeeds after clamping an excessive send gap'
assert_eq 10 "${DELIVER_SLEEPS[0]}" 'Konsole delivery clamps a ten-second-or-longer gap to ten seconds'
assert_contains "$TEST_TMP/gap-too-long.err" 'too long' \
    'Konsole delivery warns when KEEPALIVE_SEND_GAP is clamped'
KEEPALIVE_SEND_GAP='not-a-duration'
DELIVER_SLEEPS=()
gap_rc=0
ka_konsole_deliver service path MESSAGE_ENTER 'hello' > /dev/null 2>"$TEST_TMP/gap-invalid.err" || gap_rc=$?
assert_eq 0 "$gap_rc" 'Konsole delivery succeeds after replacing a malformed send gap'
assert_eq 0.15 "${DELIVER_SLEEPS[0]}" 'Konsole delivery falls back to 0.15 seconds for a malformed send gap'
assert_contains "$TEST_TMP/gap-invalid.err" 'not a duration' \
    'Konsole delivery warns when KEEPALIVE_SEND_GAP is malformed'
unset -f sleep ka_konsole_send_raw

# Source the entrypoint in informational mode so its invocation variable is observable
# without opening a TUI or touching a real service.
INVOKED_AS_CAPTURE="$TEST_TMP/invoked-as.capture"
(
    cd "$TEST_ROOT"
    source ./keepalive --version >/dev/null
    printf '%s\n' "$KA_INVOKED_AS"
) >"$INVOKED_AS_CAPTURE"
IFS= read -r INVOKED_AS_VALUE <"$INVOKED_AS_CAPTURE" || true
assert_eq "$TEST_ROOT/./keepalive" "$INVOKED_AS_VALUE" \
    'relative entrypoint invocation is made absolute before TUI update watching'

# ----- TUI install watching and selection ------------------------------------------------
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
source "$TEST_ROOT/lib/tui/tui.sh"

ENTRYPOINT_A="$TEST_TMP/entrypoint-a"
ENTRYPOINT_B="$TEST_TMP/entrypoint-b"
INVOKED_LINK="$TEST_TMP/invoked-keepalive"
cp -f "$TEST_ROOT/keepalive" "$ENTRYPOINT_A"
cp -f "$TEST_ROOT/keepalive" "$ENTRYPOINT_B"
chmod +x "$ENTRYPOINT_A" "$ENTRYPOINT_B"
ln -sfn -- "$ENTRYPOINT_A" "$INVOKED_LINK"
KA_ENTRYPOINT="$ENTRYPOINT_A"
KA_INVOKED_AS="$INVOKED_LINK"
write_service_state "$KA_RUNTIME_DIR" online 71001
ka_tui_watch_install
assert_false 'TUI update guard stays false when the held entrypoint is unchanged' ka_tui_update_ready
ln -sfn -- "$ENTRYPOINT_B" "$INVOKED_LINK"
assert_false 'TUI update guard ignores a retargeted symlink while the daemon PID is unchanged' ka_tui_update_ready
write_service_state "$KA_RUNTIME_DIR" offline 71002
assert_false 'TUI update guard waits while service.state is not online' ka_tui_update_ready
write_service_state "$KA_RUNTIME_DIR" online 71002
assert_true 'TUI update guard becomes ready only for a new online daemon PID' ka_tui_update_ready
if [[ -n ${KA_TUI_SELF_FD:-} ]]; then
    TUI_FD=$KA_TUI_SELF_FD
    exec {TUI_FD}<&-
fi

# Role: Stub TUI terminal cleanup so a failed update preflight never touches a real PTY.
ka_tui_leave() { return 0; }

TUI_REEXEC_BAD="$TEST_TMP/tui-reexec-bad"
TUI_REEXEC_CALL_LOG="$TEST_TMP/tui-reexec.calls"
cat >"$TUI_REEXEC_BAD" <<'BADREEXEC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TUI_REEXEC_CALL_LOG:?}"
exit 77
BADREEXEC
chmod +x "$TUI_REEXEC_BAD"
: >"$TUI_REEXEC_CALL_LOG"
export TUI_REEXEC_CALL_LOG
KA_INVOKED_AS="$TUI_REEXEC_BAD"
exec {REEXEC_FD}<"$ENTRYPOINT_A"
KA_TUI_SELF_FD=$REEXEC_FD
KA_TUI_TOAST=''
KA_TUI_TOAST_UNTIL=''
reexec_rc=0
ka_tui_reexec 'selected-uuid' || reexec_rc=$?
assert_eq 0 "$reexec_rc" 'TUI re-exec returns normally when the replacement fails its version preflight'
assert_contains "$TUI_REEXEC_CALL_LOG" '--version' \
    'TUI re-exec preflights the replacement entrypoint before leaving the old client'
assert_eq '' "$KA_TUI_SELF_FD" 'failed TUI re-exec clears the watched entrypoint descriptor'
assert_false 'failed TUI re-exec closes the watched descriptor' test -e "/proc/$$/fd/$REEXEC_FD"
assert_eq 'an update was installed, but it does not start; restart keepalive later' "$KA_TUI_TOAST" \
    'failed TUI re-exec sets a restart toast'
assert_false 'TUI update readiness is disabled after a failed replacement preflight' ka_tui_update_ready

# Role: Stub only the TUI IPC call so selection restoration can run without a real terminal.
ka_ipc_call() {
    case ${1-} in
        PING) printf 'OK\tservice online' ;;
        REFRESH) printf 'OK\trefreshed' ;;
        *) printf 'OK\tok' ;;
    esac
}

# Role: Stub TUI entry/exit so the manager loop can execute one deterministic key cycle.
ka_tui_enter() { return 0; }

# Role: Stub stale wizard cleanup for the unit-level TUI selection probe.
ka_wizard_cleanup_stale() { return 0; }

# Role: Stub install watching because selection restoration is tested independently of re-exec.
ka_tui_watch_install() { return 0; }

# Role: Keep the hermetic TUI loop from attempting an exec while recording its chosen row.
ka_tui_update_ready() { return 1; }

# Role: Capture the row selected by KEEPALIVE_TUI_SELECT in the one-cycle TUI probe.
ka_tui_render_manager() {
    TUI_RENDER_SELECTED=$1
}

# Role: End the one-cycle TUI manager probe with a quit key.
ka_tui_read_key() {
    KA_KEY=q
    return 0
}

SELECT_UUID='dddddddd-4444-4444-8444-dddddddddddd'
OTHER_UUID='eeeeeeee-5555-4555-8555-eeeeeeeeeeee'
: >"$KA_INDEX_FILE"
write_index_row "$KA_RUNTIME_DIR" "$OTHER_UUID" 'Other' '/other' ACTIVE
write_index_row "$KA_RUNTIME_DIR" "$SELECT_UUID" 'Selected' '/selected' PAUSED
KA_TUI_INDEX_CACHE=''
KA_TUI_SORT_ORDER=()
KA_TUI_SORT_KEYS=()
TUI_RENDER_SELECTED=''
KEEPALIVE_TUI_SELECT="$SELECT_UUID"
tui_rc=0
ka_tui_main || tui_rc=$?
assert_eq 0 "$tui_rc" 'unit-level TUI manager cycle exits normally after restoring selection'
assert_eq 1 "$TUI_RENDER_SELECTED" 'KEEPALIVE_TUI_SELECT restores the selected UUID after ka_tui_load_index'
assert_eq '' "${KEEPALIVE_TUI_SELECT-}" 'selection handoff variable is consumed after restoration'

# ----- Installer lifecycle shims ---------------------------------------------------------
write_install_systemctl
new_install_case active-reload
install_runtime="$XDG_RUNTIME_DIR/keepalive"
mkdir -p "$install_runtime/targets"
chmod 700 "$install_runtime" "$install_runtime/targets"
INSTALL_UUID='ffffffff-6666-4666-8666-ffffffffffff'
seed_manifest_target "$install_runtime" "$INSTALL_UUID" ACTIVE
write_index_row "$install_runtime" "$INSTALL_UUID" 'Reloaded' '/reload' ACTIVE
: >"$FAKE_SYSTEMD_STATE_DIR/active.keepalive.service"
printf 'enabled\n' >"$FAKE_SYSTEMD_STATE_DIR/enable-state.keepalive.socket"
prepare_install_case_owner
start_install_stub "$CASE_ROOT"
write_service_state "$install_runtime" online "$INSTALL_OLD_PID"
install_rc=0
run_install_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || install_rc=$?
assert_eq 0 "$install_rc" 'installer update with an active fake service succeeds'
assert_contains "$CASE_ROOT/out" 'Reloaded 1 running keep-alive(s)' \
    'active installer update reports reloaded running keep-alives'
while IFS= read -r restart_pid; do
    [[ $restart_pid =~ ^[0-9]+$ ]] || continue
    record_started_pid "$restart_pid"
done <"$FAKE_RESTART_PID_LOG"

new_install_case unreadable-index
install_runtime="$XDG_RUNTIME_DIR/keepalive"
mkdir -p "$install_runtime/targets"
chmod 700 "$install_runtime" "$install_runtime/targets"
INSTALL_UUID='abababab-6666-4666-8666-abababababab'
seed_manifest_target "$install_runtime" "$INSTALL_UUID" ACTIVE
write_index_row "$install_runtime" "$INSTALL_UUID" 'Unreadable' '/unreadable' ACTIVE
chmod 000 "$install_runtime/index.tsv"
: >"$FAKE_SYSTEMD_STATE_DIR/active.keepalive.service"
printf 'enabled\n' >"$FAKE_SYSTEMD_STATE_DIR/enable-state.keepalive.socket"
prepare_install_case_owner
start_install_stub "$CASE_ROOT"
write_service_state "$install_runtime" online "$INSTALL_OLD_PID"
install_rc=0
run_install_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || install_rc=$?
assert_eq 0 "$install_rc" 'full installer update succeeds when the post-swap index is unreadable'
assert_true 'full installer update leaves the new source tree live after unreadable-index reporting' \
    test -f "$CASE_ROOT/home/.local/share/keepalive-manager/keepalive"
while IFS= read -r restart_pid; do
    [[ $restart_pid =~ ^[0-9]+$ ]] || continue
    record_started_pid "$restart_pid"
done <"$FAKE_RESTART_PID_LOG"

new_install_case non-systemd-daemon
install_runtime="$XDG_RUNTIME_DIR/keepalive"
mkdir -p "$install_runtime/targets"
chmod 700 "$install_runtime" "$install_runtime/targets"
INSTALL_UUID='99999999-7777-4777-8777-999999999999'
seed_manifest_target "$install_runtime" "$INSTALL_UUID" ACTIVE
write_index_row "$install_runtime" "$INSTALL_UUID" 'Manual' '/manual' ACTIVE
prepare_install_case_owner
start_install_stub "$CASE_ROOT"
write_service_state "$install_runtime" online "$INSTALL_OLD_PID"
install_rc=0
run_install_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || install_rc=$?
assert_eq 0 "$install_rc" 'installer update with a non-systemd daemon succeeds'
assert_contains "$CASE_ROOT/err" 'not started by systemd' \
    'installer warns when a live daemon was not started by systemd'

new_install_case no-daemon
install_runtime="$XDG_RUNTIME_DIR/keepalive"
mkdir -p "$install_runtime/targets"
chmod 700 "$install_runtime" "$install_runtime/targets"
INSTALL_UUID='88888888-8888-4888-8888-888888888888'
seed_manifest_target "$install_runtime" "$INSTALL_UUID" ACTIVE
write_index_row "$install_runtime" "$INSTALL_UUID" 'Dormant' '/dormant' ACTIVE
prepare_install_case_owner
install_rc=0
run_install_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || install_rc=$?
assert_eq 0 "$install_rc" 'installer update with configured targets and no daemon succeeds'
assert_contains "$CASE_ROOT/out" 'no daemon is running' \
    'installer notices configured targets when no daemon is running'

# Stop all recorded processes before the final assertion/cleanup path.
cleanup_started_processes
trap - EXIT
test_finish
