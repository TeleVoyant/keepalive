#!/usr/bin/env bash
# Orca CLI discovery, identity validation, and input delivery adapter.
#
# Orca's command and JSON contracts are intentionally isolated in this module. Orca is
# evolving quickly; the state machine and scheduler consume only the normalized rows and
# return codes documented below, so a future CLI schema change should stop here.

# The normalized contract consumed by state.sh. This is deliberately independent of the
# Orca application version: compatible CLI releases can change without touching callers.
KA_ORCA_ADAPTER_CONTRACT='terminal-v1'

# Role: Locate the optional Orca CLI and jq JSON parser without ever selecting GNOME's orca.
ka_orca_find() {
    local candidate
    KA_ORCA_CLI=''
    KA_ORCA_JQ=''
    [[ ${KEEPALIVE_ORCA_ENABLED:-auto} != 0 ]] || return 1

    if [[ -n ${KEEPALIVE_ORCA_CLI:-} ]]; then
        [[ -f $KEEPALIVE_ORCA_CLI && -x $KEEPALIVE_ORCA_CLI ]] || return 1
        KA_ORCA_CLI=$KEEPALIVE_ORCA_CLI
    else
        # Linux installs use orca-ide: bare orca is commonly the GNOME screen reader.
        # Keep the candidate list here, rather than scattered through service/doctor code.
        for candidate in orca-ide "${HOME:+$HOME/.local/bin/orca-ide}" /usr/local/bin/orca-ide; do
            [[ -n $candidate ]] || continue
            if command -v "$candidate" >/dev/null 2>&1; then
                KA_ORCA_CLI=$(command -v "$candidate")
                break
            fi
        done
    fi
    [[ -n $KA_ORCA_CLI ]] || return 1

    if [[ -n ${KEEPALIVE_JQ:-} ]]; then
        [[ -f $KEEPALIVE_JQ && -x $KEEPALIVE_JQ ]] || { KA_ORCA_CLI=''; return 1; }
        KA_ORCA_JQ=$KEEPALIVE_JQ
    elif command -v jq >/dev/null 2>&1; then
        KA_ORCA_JQ=$(command -v jq)
    else
        KA_ORCA_CLI=''
        return 1
    fi
    return 0
}

# Role: Resolve the deadline for one Orca CLI operation without trusting raw arithmetic input.
ka_orca_timeout_resolve() {
    ka_tunable KEEPALIVE_ORCA_TIMEOUT 3
    KA_ORCA_TIMEOUT=$REPLY
}

# Role: Run one Orca CLI command under a hard deadline.
ka_orca_exec() {
    [[ -n ${KA_ORCA_CLI:-} && -n ${KA_ORCA_JQ:-} ]] || ka_orca_find || return 127
    command -v timeout >/dev/null 2>&1 || return 127
    ka_orca_timeout_resolve
    timeout --kill-after=1s "${KA_ORCA_TIMEOUT}s" "$KA_ORCA_CLI" "$@"
}

# Role: Identify bounded Orca subprocess expiry statuses.
ka_orca_status_is_timeout() {
    [[ ${1-} == 124 || ${1-} == 137 ]]
}

# Role: Convert an Orca agent identity into a stable human-readable family label.
ka_orca_agent_label() {
    local identity=${1,,}
    case $identity in
        claude) REPLY='Claude' ;;
        codex) REPLY='Codex' ;;
        kimi) REPLY='Kimi' ;;
        gemini) REPLY='Gemini' ;;
        qwen) REPLY='Qwen' ;;
        pi) REPLY='Pi' ;;
        omp) REPLY='OMP' ;;
        grok) REPLY='Grok' ;;
        *)
            REPLY=${identity^}
            [[ -n $REPLY ]] || REPLY='Agent'
            ;;
    esac
}

# Role: Build the manager-owned target ID for one Orca runtime and terminal incarnation.
ka_orca_manager_id() {
    local runtime=$1 incarnation=$2
    REPLY="orca-$runtime-$incarnation"
}

# Role: Accept a bounded opaque Orca binding value without assuming its future format.
ka_orca_binding_value_valid() {
    local value=${1-} maximum=${2:-4096}
    [[ -n $value && ${#value} -le maximum ]] || return 1
    [[ $value != *$'\t'* && $value != *$'\n'* && $value != *$'\r'* ]]
}

# Role: Validate a persisted normalized Orca binding and expose a precise rejection reason.
ka_orca_checkpoint_binding_valid() {
    local uuid=$1 handle=$2 pty=$3 incarnation=$4 worktree=$5 runtime=$6
    local host=$7 tab=$8 leaf=$9 agent=${10}
    KA_ORCA_BINDING_ERROR=''
    ka_orca_binding_value_valid "$handle" 512 || {
        KA_ORCA_BINDING_ERROR='invalid Orca terminal handle'; return 1;
    }
    ka_orca_binding_value_valid "$pty" 4096 || {
        KA_ORCA_BINDING_ERROR='invalid Orca PTY identity'; return 1;
    }
    ka_orca_binding_value_valid "$incarnation" 256 || {
        KA_ORCA_BINDING_ERROR='invalid Orca incarnation identity'; return 1;
    }
    ka_orca_binding_value_valid "$worktree" 4096 || {
        KA_ORCA_BINDING_ERROR='invalid Orca worktree identity'; return 1;
    }
    ka_orca_binding_value_valid "$runtime" 256 || {
        KA_ORCA_BINDING_ERROR='invalid Orca runtime identity'; return 1;
    }
    ka_orca_binding_value_valid "$host" 256 || {
        KA_ORCA_BINDING_ERROR='invalid Orca execution-host identity'; return 1;
    }
    ka_orca_binding_value_valid "$tab" 256 || {
        KA_ORCA_BINDING_ERROR='invalid Orca tab identity'; return 1;
    }
    ka_orca_binding_value_valid "$leaf" 256 || {
        KA_ORCA_BINDING_ERROR='invalid Orca leaf identity'; return 1;
    }
    ka_orca_binding_value_valid "$agent" 128 || {
        KA_ORCA_BINDING_ERROR='invalid Orca agent identity'; return 1;
    }
    ka_orca_manager_id "$runtime" "$incarnation"
    [[ $uuid == "$REPLY" ]] || {
        KA_ORCA_BINDING_ERROR='Orca target ID does not match its runtime/incarnation binding'
        return 1
    }
    return 0
}

# Role: Print one normalized Orca discovery pass from the current CLI JSON contract.
#
# Output columns are all non-empty and TSV-escaped by jq:
# manager ID, agent identity, display name, worktree path, handle, PTY ID,
# incarnation ID, worktree ID, runtime ID, execution host, tab ID, leaf ID.
# #COMPLETE is printed only after a structurally complete, non-truncated response.
ka_orca_discover() {
    local output rc rows agent name directory handle pty incarnation worktree runtime host tab leaf
    if output=$(ka_orca_exec terminal list --limit 1000 --json 2>/dev/null); then
        :
    else
        rc=$?
        printf '#INCOMPLETE\tcommand-%s\n' "$rc"
        return 0
    fi

    # Current Orca omits agentIdentity entirely for ordinary shell terminals. That field
    # is therefore optional on ignored rows, but every eligible agent row must carry the
    # full binding below or the pass is rejected.
    # Validation and projection are one jq run (they used to be two), and the program can
    # only emit rows after the whole response validated. Anything unexpected - a response
    # that is not an object, input that is not JSON, or any invalid document in a stream
    # of several - raises a jq error, so the exit status alone fails the pass closed even
    # when an earlier document already printed rows.
    if ! rows=$("$KA_ORCA_JQ" -r '
        def valid:
            .ok == true and
            (.result.terminals | type == "array") and
            (.result.truncated | type == "boolean") and
            (.result.truncated == false) and
            (._meta.runtimeId | type == "string" and length > 0) and
            all(.result.terminals[];
                (.handle | type == "string") and
                (.connected | type == "boolean") and
                (.writable | type == "boolean") and
                (.orphaned | type == "boolean") and
                ((.agentIdentity | type) == "null" or (.agentIdentity | type) == "string") and
                ((.connected != true or .writable != true or .orphaned == true or
                  (.agentIdentity | type) != "string" or (.agentIdentity | length) == 0) or
                    ((.ptyId | type == "string" and length > 0) and
                     (.incarnationId | type == "string" and length > 0) and
                     (.worktreeId | type == "string" and length > 0) and
                     (.worktreePath | type == "string" and length > 0) and
                     (.executionHostId | type == "string" and length > 0) and
                     (.tabId | type == "string" and length > 0) and
                     (.leafId | type == "string" and length > 0))));
        if (try valid catch false) then
            ._meta.runtimeId as $runtime |
            .result.terminals[] |
            select(.connected == true and .writable == true and .orphaned != true) |
            select(.agentIdentity | type == "string" and length > 0) |
            [
                .agentIdentity,
                (if (.title | type == "string" and length > 0) then .title else (.worktreePath | split("/") | last) end),
                .worktreePath,
                .handle,
                .ptyId,
                .incarnationId,
                .worktreeId,
                $runtime,
                .executionHostId,
                .tabId,
                .leafId
            ] | @tsv
        else
            error("unsupported Orca terminal list schema")
        end
    ' 2>/dev/null <<<"$output"); then
        printf '#INCOMPLETE\tschema\n'
        return 0
    fi
    while IFS=$'\t' read -r agent name directory handle pty incarnation worktree runtime host tab leaf; do
        [[ -n $agent ]] || continue
        ka_orca_manager_id "$runtime" "$incarnation"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$REPLY" "$agent" "$name" "$directory" "$handle" "$pty" "$incarnation" \
            "$worktree" "$runtime" "$host" "$tab" "$leaf"
    done <<<"$rows"
    printf '#COMPLETE\n'
}

# Role: Extract an Orca error code from a failed JSON envelope into REPLY.
ka_orca_error_code() {
    local json=$1
    REPLY=$("$KA_ORCA_JQ" -r 'if (.error.code | type) == "string" then .error.code else "unknown" end' \
        2>/dev/null <<<"$json" || printf unknown)
}

# Role: Verify that a handle still names the exact recorded Orca terminal incarnation.
ka_orca_validate_target() {
    local handle=$1 expected_pty=$2 expected_incarnation=$3 expected_worktree=$4
    local expected_runtime=$5 expected_host=$6 expected_tab=$7 expected_leaf=$8 expected_agent=$9
    local output rc row actual_handle pty incarnation worktree runtime host tab leaf agent connected writable orphaned

    if output=$(ka_orca_exec terminal show --terminal "$handle" --json 2>/dev/null); then
        :
    else
        rc=$?
        ka_orca_status_is_timeout "$rc" && return 20
        if [[ -n $output ]]; then
            ka_orca_error_code "$output"
            case $REPLY in
                terminal_handle_stale|terminal_gone|selector_not_found) return 10 ;;
            esac
        fi
        return 21
    fi

    # One jq run validates and extracts; it used to take two, before every send and every
    # live health check. Any unfamiliar response - unparseable, not an object, or missing
    # a field - is the schema result: a successful command with an unfamiliar response
    # proves no identity change, so it stays transient and an Orca 0.x schema drift
    # cannot make targets sticky.
    if ! row=$("$KA_ORCA_JQ" -r '
        def valid:
            .ok == true and
            (._meta.runtimeId | type == "string" and length > 0) and
            (.result.terminal | type == "object") and
            (.result.terminal |
                (.handle | type == "string" and length > 0) and
                (.ptyId | type == "string" and length > 0) and
                (.incarnationId | type == "string" and length > 0) and
                (.worktreeId | type == "string" and length > 0) and
                (.executionHostId | type == "string" and length > 0) and
                (.tabId | type == "string" and length > 0) and
                (.leafId | type == "string" and length > 0) and
                (.connected | type == "boolean") and
                (.writable | type == "boolean") and
                (.orphaned | type == "boolean") and
                has("agentIdentity") and
                ((.agentIdentity | type) == "string" or (.agentIdentity | type) == "null"));
        if (try valid catch false) then
            ._meta.runtimeId as $runtime |
            .result.terminal |
            [
                .handle, .ptyId, .incarnationId, .worktreeId, $runtime,
                .executionHostId, .tabId, .leafId,
                (if (.agentIdentity | type) == "string" then .agentIdentity else "-" end),
                (.connected | tostring), (.writable | tostring), (.orphaned | tostring)
            ] | @tsv
        else
            error("unsupported Orca terminal show schema")
        end
    ' 2>/dev/null <<<"$output"); then
        return 22
    fi
    [[ -n $row ]] || return 21
    IFS=$'\t' read -r actual_handle pty incarnation worktree runtime host tab leaf agent connected writable orphaned <<<"$row"

    [[ $runtime == "$expected_runtime" ]] || return 11
    [[ $actual_handle == "$handle" ]] || return 10
    [[ $incarnation == "$expected_incarnation" ]] || return 12
    [[ $pty == "$expected_pty" ]] || return 13
    [[ $worktree == "$expected_worktree" && $host == "$expected_host" ]] || return 14
    [[ $tab == "$expected_tab" && $leaf == "$expected_leaf" ]] || return 16
    [[ $agent == "$expected_agent" ]] || return 15
    [[ $connected == true && $writable == true && $orphaned != true ]] || return 21
    return 0
}

# Role: Translate Orca validation return codes into operator-facing reason text.
ka_orca_validation_reason() {
    case ${1:-1} in
        10) printf 'Orca terminal handle is stale or gone' ;;
        11) printf 'Orca runtime instance changed' ;;
        12) printf 'Orca terminal process incarnation changed' ;;
        13) printf 'Orca PTY identity changed' ;;
        14) printf 'Orca worktree or execution host changed' ;;
        15) printf 'Orca terminal no longer hosts the recorded agent' ;;
        16) printf 'Orca terminal pane identity changed' ;;
        20) printf 'Orca CLI validation timed out' ;;
        21) printf 'Orca terminal could not be reached or is not writable' ;;
        22) printf 'Orca CLI response schema is unsupported' ;;
        *) printf 'Orca target validation failed' ;;
    esac
}

# Role: Identify Orca validation results that do not prove target identity loss.
ka_orca_validation_is_transient() {
    [[ ${1-} == 20 || ${1-} == 21 || ${1-} == 22 ]]
}

# Role: Decide whether a transient Orca result should consume the reachability strike budget.
ka_orca_validation_consumes_strike() {
    # Schema incompatibility says nothing about liveness. Repeated health checks must not
    # turn it into sticky identity loss while an evolving Orca adapter is being updated.
    [[ ${1-} != 22 ]]
}

# Role: Deliver one keep-alive through Orca's atomic terminal-send command.
#
# Orca accepts text plus Enter as one durable prompt request, so this adapter never returns
# the Konsole-only partial-submit code 3. Accepted input is success; observing a model turn
# is not required, matching Konsole sendText semantics and avoiding a blocking wait.
ka_orca_deliver() {
    local handle=$1 mode=$2 message=${3-} submit_only=${4:-0} output rc
    local -a args=(terminal send --terminal "$handle")
    case $mode in
        ENTER_ONLY)
            args+=(--enter --json)
            ;;
        MESSAGE_ENTER)
            if ((submit_only == 1)); then
                args+=(--enter --json)
            else
                args+=(--text "$message" --enter --json)
            fi
            ;;
        *)
            ka_error "unknown delivery mode: $mode"
            return 2
            ;;
    esac

    if output=$(ka_orca_exec "${args[@]}" 2>/dev/null); then
        :
    else
        rc=$?
        KA_ORCA_LAST_SEND_STATUS=$rc
        return 1
    fi
    "$KA_ORCA_JQ" -e '.ok == true and .result.send.accepted == true' \
        >/dev/null 2>&1 <<<"$output" || return 1
    return 0
}
