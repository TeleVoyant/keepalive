#!/usr/bin/env bash
# Orca CLI discovery, identity validation, and input delivery adapter.
#
# Orca's command and JSON contracts are intentionally isolated in this module. Orca is
# evolving quickly; the state machine and scheduler consume only the normalized rows and
# return codes documented below, so a future CLI schema change should stop here.

# The normalized contract consumed by state.sh. This is deliberately independent of the
# Orca application version: compatible CLI releases can change without touching callers.
KA_ORCA_ADAPTER_CONTRACT='terminal-v1'

# Orca answers in JSON only. jq reads it when installed; otherwise the POSIX awk program
# beside this module does, so the backend needs nothing beyond a base system. Made absolute
# here because the daemon and tests may change directory after sourcing.
KA_ORCA_AWK_PROGRAM=${BASH_SOURCE[0]%/*}/orca.awk
[[ $KA_ORCA_AWK_PROGRAM == /* ]] || KA_ORCA_AWK_PROGRAM=$PWD/$KA_ORCA_AWK_PROGRAM

# Largest CLI response either reader is given, in characters. A real five-terminal list is
# about 8 KB and the request is capped at 1000 rows; anything far beyond that is refused
# like any other unusable response rather than parsed for seconds.
KA_ORCA_MAX_RESPONSE=4194304

# Role: Resolve the Orca CLI path into REPLY without ever selecting GNOME's orca.
# Shared by the adapter and `doctor`, which reports the CLI and jq separately.
ka_orca_locate_cli() {
    local candidate
    REPLY=''
    if [[ -n ${KEEPALIVE_ORCA_CLI:-} ]]; then
        [[ -f $KEEPALIVE_ORCA_CLI && -x $KEEPALIVE_ORCA_CLI ]] || return 1
        REPLY=$KEEPALIVE_ORCA_CLI
        return 0
    fi
    # Linux installs use orca-ide: bare orca is commonly the GNOME screen reader.
    # Keep the candidate list here, rather than scattered through service/doctor code.
    for candidate in orca-ide "${HOME:+$HOME/.local/bin/orca-ide}" /usr/local/bin/orca-ide; do
        [[ -n $candidate ]] || continue
        if command -v "$candidate" >/dev/null 2>&1; then
            REPLY=$(command -v "$candidate")
            return 0
        fi
    done
    return 1
}

# Role: Resolve the jq JSON parser the adapter depends on into REPLY.
ka_orca_locate_jq() {
    REPLY=''
    if [[ -n ${KEEPALIVE_JQ:-} ]]; then
        [[ -f $KEEPALIVE_JQ && -x $KEEPALIVE_JQ ]] || return 1
        REPLY=$KEEPALIVE_JQ
        return 0
    fi
    command -v jq >/dev/null 2>&1 || return 1
    REPLY=$(command -v jq)
}

# Role: Resolve the awk interpreter for the jq-free reader into REPLY.
# KEEPALIVE_AWK pins one (the tests use it to run gawk, mawk, and BusyBox awk alike).
ka_orca_locate_awk() {
    REPLY=''
    [[ -f $KA_ORCA_AWK_PROGRAM && -r $KA_ORCA_AWK_PROGRAM ]] || return 1
    if [[ -n ${KEEPALIVE_AWK:-} ]]; then
        [[ -f $KEEPALIVE_AWK && -x $KEEPALIVE_AWK ]] || return 1
        REPLY=$KEEPALIVE_AWK
        return 0
    fi
    command -v awk >/dev/null 2>&1 || return 1
    REPLY=$(command -v awk)
}

# Role: Choose the JSON reader, setting KA_ORCA_PARSER plus KA_ORCA_JQ or KA_ORCA_AWK.
# KEEPALIVE_ORCA_PARSER is auto (jq when installed, awk otherwise), jq, or awk. An explicit
# KEEPALIVE_JQ that is unusable stays an error rather than quietly switching readers.
ka_orca_select_parser() {
    KA_ORCA_PARSER=''
    KA_ORCA_JQ=''
    KA_ORCA_AWK=''
    case ${KEEPALIVE_ORCA_PARSER:-auto} in
        jq)
            ka_orca_locate_jq || return 1
            KA_ORCA_JQ=$REPLY
            KA_ORCA_PARSER='jq'
            ;;
        awk)
            ka_orca_locate_awk || return 1
            KA_ORCA_AWK=$REPLY
            KA_ORCA_PARSER='awk'
            ;;
        auto)
            if ka_orca_locate_jq; then
                KA_ORCA_JQ=$REPLY
                KA_ORCA_PARSER='jq'
            elif [[ -z ${KEEPALIVE_JQ:-} ]] && ka_orca_locate_awk; then
                KA_ORCA_AWK=$REPLY
                KA_ORCA_PARSER='awk'
            else
                return 1
            fi
            ;;
        # A typo must not quietly pick a reader; doctor names the knob to check.
        *) return 1 ;;
    esac
}

# Role: Locate the optional Orca CLI and a JSON reader, enabling the adapter only with both.
ka_orca_find() {
    KA_ORCA_CLI=''
    [[ ${KEEPALIVE_ORCA_ENABLED:-auto} != 0 ]] || return 1
    ka_orca_locate_cli || return 1
    KA_ORCA_CLI=$REPLY
    ka_orca_select_parser || { KA_ORCA_CLI=''; return 1; }
    return 0
}

# Role: Run one operation of the jq-free reader on stdin, with byte semantics.
# Bounded by the Orca deadline like the CLI call it follows: BusyBox awk is several times
# slower than jq, so a large response must not hold the daemon loop.
ka_orca_awk() {
    ka_orca_timeout_resolve
    LC_ALL=C timeout --kill-after=1s "${KA_ORCA_TIMEOUT}s" \
        "$KA_ORCA_AWK" -v op="$1" -f "$KA_ORCA_AWK_PROGRAM"
}

# Role: Report whether the selected Orca runtime answers as reachable, for diagnostics only.
ka_orca_runtime_reachable() {
    local output
    output=$(ka_orca_exec status --json 2>/dev/null) || return 1
    ((${#output} <= KA_ORCA_MAX_RESPONSE)) || return 1
    if [[ $KA_ORCA_PARSER == awk ]]; then
        ka_orca_awk status >/dev/null 2>&1 <<<"$output"
        return
    fi
    # Exactly one document: with several, -e would judge only the last one.
    "$KA_ORCA_JQ" -n -e '
        [inputs] as $documents |
        ($documents | length) == 1 and
        ($documents[0] | type) == "object" and
        $documents[0].ok == true and
        $documents[0].result.runtime.reachable == true
    ' >/dev/null 2>&1 <<<"$output"
}

# Role: Resolve the deadline for one Orca CLI operation without trusting raw arithmetic input.
ka_orca_timeout_resolve() {
    ka_tunable KEEPALIVE_ORCA_TIMEOUT 3
    KA_ORCA_TIMEOUT=$REPLY
}

# Role: Run one Orca CLI command under a hard deadline.
ka_orca_exec() {
    # A caller that set only KA_ORCA_JQ, as older code and tests do, has chosen jq.
    [[ -n ${KA_ORCA_PARSER:-} || -z ${KA_ORCA_JQ:-} ]] || KA_ORCA_PARSER=jq
    [[ -n ${KA_ORCA_CLI:-} && -n ${KA_ORCA_PARSER:-} ]] || ka_orca_find || return 127
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
# #COMPLETE is printed only after a structurally complete, non-truncated response. Before
# it, an optional `#SKIPPED<TAB>count<TAB>detail` line counts agent rows left out of the
# snapshot. A failed pass prints one `#INCOMPLETE<TAB>reason` line and no rows, where the
# reason is `command-<status>` or `schema:<detail>`; the detail names the failed gate
# without echoing any terminal value.
ka_orca_discover() {
    local output rc rows agent name directory handle pty incarnation worktree runtime host tab leaf
    local complete=0
    if output=$(ka_orca_exec terminal list --limit 1000 --json 2>/dev/null); then
        :
    else
        rc=$?
        printf '#INCOMPLETE\tcommand-%s\n' "$rc"
        return 0
    fi

    # Validation and projection are one jq run over a `-n` read of every input document,
    # so a stream of several documents is refused whole and input that is not JSON fails
    # jq itself; nothing is printed until the single response has passed the envelope gate.
    #
    # The gate separates a response the adapter does not understand from rows it merely
    # cannot use. Orca 1.4.241 legitimately emits rows that are not deliverable targets: a
    # pane whose PTY exited or is not attached yet carries ptyId/incarnationId null, a
    # foreign or SSH route omits executionHostId, and split or mirrored panes onto one PTY
    # share its incarnation. One such row used to fail every pass and freeze the whole Orca
    # snapshot, for as long as the pane stayed open. Now a wrong JSON type, which no
    # current Orca emits, still fails the pass closed; an agent row whose binding is merely
    # absent or out of bounds is skipped and counted; and rows that would share one manager
    # ID with different bindings are all skipped, because choosing one would silently bind
    # to an arbitrary pane. Skipping is safe: a monitored target missing from the snapshot
    # falls back to a live exact check, and every send is validated live regardless.
    #
    # Without jq, lib/orca.awk applies the same gates and prints the same bytes; the two
    # programs must change together.
    if ((${#output} > KA_ORCA_MAX_RESPONSE)); then
        printf '#INCOMPLETE\tschema:oversize\n'
        return 0
    fi
    rc=0
    if [[ ${KA_ORCA_PARSER:-} == awk ]]; then
        rows=$(ka_orca_awk list 2>/dev/null <<<"$output") || rc=$?
    else
        rows=$("$KA_ORCA_JQ" -n -r '
        # Keep these limits in step with ka_orca_checkpoint_binding_valid: discovery is
        # the first place untrusted provider fields enter the manager arrays.
        def text_ok($maximum):
            type == "string" and length > 0 and length <= $maximum and
            (test("[[:cntrl:]]") | not);
        def nullable_text: type == "null" or type == "string";
        # Types every row must have, deliverable or not. Ordinary shell rows omit
        # agentIdentity entirely, which reads as null.
        def base_ok:
            type == "object" and
            (.handle | type) == "string" and
            (.connected | type) == "boolean" and
            (.writable | type) == "boolean" and
            (.orphaned | type) == "boolean" and
            (.agentIdentity | nullable_text);
        def candidate:
            .connected and .writable and (.orphaned | not) and
            (.agentIdentity | type) == "string" and (.agentIdentity | length) > 0;
        def binding_types_ok:
            all(.ptyId, .incarnationId, .worktreeId, .worktreePath, .executionHostId,
                .tabId, .leafId, .title; nullable_text);
        def binding_complete:
            (.handle | text_ok(512)) and
            (.ptyId | text_ok(4096)) and
            (.incarnationId | text_ok(256)) and
            (.worktreeId | text_ok(4096)) and
            (.worktreePath | text_ok(4096)) and
            (.executionHostId | text_ok(256)) and
            (.tabId | text_ok(256)) and
            (.leafId | text_ok(256)) and
            # The agent leads each projected row, where a leading "#" would read as a marker.
            # The title is not checked here: it is display text set by the program in the
            # terminal, never identity, so any string is cleaned and truncated below.
            (.agentIdentity | text_ok(128) and (startswith("#") | not));
        def binding_key:
            [.handle, .ptyId, .incarnationId, .worktreeId, .worktreePath,
             .executionHostId, .tabId, .leafId, .agentIdentity];
        # Orca builds the list as the first --limit rows of totalCount candidates and sets
        # truncated when there were more, so a complete response has exactly totalCount
        # rows, never more than the 1000 requested. Anything else is not that builder.
        def envelope_failure:
            if type != "object" then "not-object"
            elif .ok != true then "not-ok"
            elif (._meta | type) != "object" or (._meta.runtimeId | text_ok(256) | not) then "runtime-id"
            elif (.result | type) != "object" or (.result.terminals | type) != "array" then "terminals"
            elif (.result.truncated | type) != "boolean" then "truncation-marker"
            elif .result.truncated then "truncated"
            elif (.result.totalCount | type) != "number"
                or .result.totalCount != (.result.terminals | length)
                or (.result.terminals | length) > 1000 then "total-count"
            elif any(.result.terminals[]; base_ok | not) then "row-type"
            elif any(.result.terminals[] | select(candidate); binding_types_ok | not) then "binding-type"
            else "" end;
        [inputs] as $documents |
        if ($documents | length) != 1 then "#SCHEMA\tdocument-count"
        else $documents[0] |
            (try envelope_failure catch "shape") as $failure |
            if $failure != "" then "#SCHEMA\t" + $failure
            else
                ._meta.runtimeId as $runtime |
                [.result.terminals[] | select(candidate)] as $candidates |
                [$candidates[] | select(binding_complete)] as $usable |
                # The legacy manager ID is intentionally unchanged for checkpoint
                # compatibility, and it is unique within one response exactly when the
                # incarnation is. Collisions are judged over every candidate carrying an
                # incarnation, before incomplete ones are dropped: the incomplete row may
                # be the very pane a monitored target names. An exact duplicate of a
                # complete row is that row; any other sharing makes the ID unusable.
                ([$candidates[] | select(.incarnationId | text_ok(256))] | group_by(.incarnationId) |
                    map(select(length > 1 and
                        (any(.[]; binding_complete | not) or (map(binding_key) | unique | length) > 1))
                        | {(.[0].incarnationId): true}) |
                    add // {}) as $ambiguous |
                def contested: (.incarnationId | text_ok(256)) and $ambiguous[.incarnationId];
                ($usable | reduce .[] as $row ({seen: {}, rows: []};
                    if ($row | contested) or .seen[$row.incarnationId] then .
                    else .seen[$row.incarnationId] = true | .rows += [$row] end) | .rows) as $rows |
                ([$candidates[] | select(contested)] | length) as $conflicting |
                ([$candidates[] | select((binding_complete or contested) | not)] | length) as $incomplete |
                ($rows[] | [
                    .agentIdentity,
                    # Sliced before cleaning so an enormous title costs no more than a
                    # short one; the cleaned text is what the 256-character cut applies to.
                    ((if (.title | type) == "string" then .title else "" end)
                        | .[0:1024] | gsub("[[:cntrl:]]"; "") | .[0:256]) as $title |
                    # Never emit an empty field: the shell reads these rows with IFS=tab,
                    # which collapses adjacent tabs and would shift every later field
                    # (including the ID). A trailing-slash path has an empty last segment.
                    (if ($title | length) > 0 then $title
                     else (([.worktreePath | split("/")[] | select(length > 0)] | last) // "orca") end),
                    .worktreePath,
                    .handle,
                    .ptyId,
                    .incarnationId,
                    .worktreeId,
                    $runtime,
                    .executionHostId,
                    .tabId,
                    .leafId
                ] | @tsv),
                (if $incomplete + $conflicting > 0 then
                    "#SKIPPED\t\($incomplete + $conflicting)\t" +
                    ([(if $incomplete > 0 then "incomplete-binding=\($incomplete)" else empty end),
                      (if $conflicting > 0 then "ambiguous-incarnation=\($conflicting)" else empty end)]
                     | join(","))
                 else empty end),
                "#COMPLETE"
            end
        end
    ' 2>/dev/null <<<"$output") || rc=$?
    fi
    if ka_orca_status_is_timeout "$rc"; then
        printf '#INCOMPLETE\tschema:parse-timeout\n'
        return 0
    elif ((rc != 0)); then
        printf '#INCOMPLETE\tschema:not-json\n'
        return 0
    fi
    while IFS=$'\t' read -r agent name directory handle pty incarnation worktree runtime host tab leaf; do
        case $agent in
            '#SCHEMA')
                printf '#INCOMPLETE\tschema:%s\n' "$name"
                return 0
                ;;
            '#SKIPPED')
                printf '#SKIPPED\t%s\t%s\n' "$name" "$directory"
                continue
                ;;
            '#COMPLETE')
                complete=1
                continue
                ;;
            '') continue ;;
        esac
        ka_orca_manager_id "$runtime" "$incarnation"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$REPLY" "$agent" "$name" "$directory" "$handle" "$pty" "$incarnation" \
            "$worktree" "$runtime" "$host" "$tab" "$leaf"
    done <<<"$rows"
    if ((complete == 1)); then
        printf '#COMPLETE\n'
    else
        printf '#INCOMPLETE\tschema:no-marker\n'
    fi
}

# Role: Extract an Orca error code from a failed JSON envelope into REPLY.
ka_orca_error_code() {
    local json=$1
    REPLY=unknown
    ((${#json} <= KA_ORCA_MAX_RESPONSE)) || return 0
    if [[ ${KA_ORCA_PARSER:-} == awk ]]; then
        REPLY=$(ka_orca_awk error 2>/dev/null <<<"$json" || printf unknown)
        return 0
    fi
    # One document only, as everywhere else: several would print several codes.
    REPLY=$("$KA_ORCA_JQ" -n -r '
        [inputs] as $documents |
        if ($documents | length) == 1 and ($documents[0] | type) == "object" and
            ($documents[0].error | type) == "object" and
            ($documents[0].error.code | type) == "string"
        then $documents[0].error.code else "unknown" end
    ' 2>/dev/null <<<"$json" || printf unknown)
}

# Role: Verify that a handle still names the exact recorded Orca terminal incarnation.
ka_orca_validate_target() {
    local handle=$1 expected_pty=$2 expected_incarnation=$3 expected_worktree=$4
    local expected_runtime=$5 expected_host=$6 expected_tab=$7 expected_leaf=$8 expected_agent=$9
    local output rc row actual_handle pty_present pty incarnation worktree runtime host tab leaf
    local agent_present agent connected writable orphaned

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
    # live health check. Any unfamiliar response - unparseable, not an object, a missing
    # runtime fence or pane binding, or a wrong type - is the schema result and stays
    # transient. The field bounds are the ones discovery and the checkpoint loader use: a
    # value outside them (or carrying a control character, which would also shift the
    # tab-separated fields) violates the adapter contract, so it must not be mistaken for a
    # definitive identity change.
    #
    # Two fields may legitimately be absent from an understood response, and absence is
    # projected as its own flag rather than compared, because it proves no other identity.
    # Orca reports ptyId/incarnationId null while a pane has no attached PTY (exited, or
    # not yet spawned), and it omits agentIdentity both for plain shells and when its
    # agent evidence conflicts. Each becomes its own transient result below, which still
    # consumes the strike budget: a pane that stays that way ends UNAVAILABLE, a momentary
    # gap does not. A different non-empty value remains definitive.
    #
    # Exactly one document is accepted: with several, the first row would be read and the
    # rest ignored. lib/orca.awk is the same program for hosts without jq.
    ((${#output} <= KA_ORCA_MAX_RESPONSE)) || return 22
    rc=0
    if [[ ${KA_ORCA_PARSER:-} == awk ]]; then
        row=$(ka_orca_awk show 2>/dev/null <<<"$output") || rc=$?
    else
        row=$("$KA_ORCA_JQ" -n -r '
        def text_ok($maximum):
            (type == "string") and length > 0 and length <= $maximum and
            (test("[[:cntrl:]]") | not);
        def absent_or_text($maximum): type == "null" or . == "" or text_ok($maximum);
        def present: type == "string" and length > 0;
        def valid:
            .ok == true and
            (._meta.runtimeId | text_ok(256)) and
            (.result.terminal | type == "object") and
            (.result.terminal |
                (.handle | text_ok(512)) and
                (.ptyId | absent_or_text(4096)) and
                (.incarnationId | absent_or_text(256)) and
                (.worktreeId | text_ok(4096)) and
                (.executionHostId | text_ok(256)) and
                (.tabId | text_ok(256)) and
                (.leafId | text_ok(256)) and
                (.connected | type == "boolean") and
                (.writable | type == "boolean") and
                (.orphaned | type == "boolean") and
                (.agentIdentity | absent_or_text(128)));
        [inputs] as $documents |
        if ($documents | length) == 1 and ($documents[0] | try valid catch false) then
            $documents[0] |
            ._meta.runtimeId as $runtime |
            .result.terminal |
            [
                .handle,
                # "-" only fills a column the flag says is absent: IFS=tab collapses empty
                # fields, and "-" itself is never compared as an identity.
                (if (.ptyId | present) and (.incarnationId | present) then "1" else "0" end),
                (if .ptyId | present then .ptyId else "-" end),
                (if .incarnationId | present then .incarnationId else "-" end),
                .worktreeId, $runtime,
                .executionHostId, .tabId, .leafId,
                (if .agentIdentity | present then "1" else "0" end),
                (if .agentIdentity | present then .agentIdentity else "-" end),
                (.connected | tostring), (.writable | tostring), (.orphaned | tostring)
            ] | @tsv
        else
            error("unsupported Orca terminal show schema")
        end
    ' 2>/dev/null <<<"$output") || rc=$?
    fi
    ((rc == 0)) || return 22
    [[ -n $row ]] || return 21
    IFS=$'\t' read -r actual_handle pty_present pty incarnation worktree runtime host tab leaf \
        agent_present agent connected writable orphaned <<<"$row"

    [[ $runtime == "$expected_runtime" ]] || return 11
    [[ $actual_handle == "$handle" ]] || return 10
    [[ $pty_present == 1 ]] || return 24
    [[ $incarnation == "$expected_incarnation" ]] || return 12
    [[ $pty == "$expected_pty" ]] || return 13
    [[ $worktree == "$expected_worktree" && $host == "$expected_host" ]] || return 14
    [[ $tab == "$expected_tab" && $leaf == "$expected_leaf" ]] || return 16
    [[ $agent_present == 1 ]] || return 23
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
        23) printf 'Orca terminal reports no agent identity right now' ;;
        24) printf 'Orca terminal has no attached PTY right now' ;;
        *) printf 'Orca target validation failed' ;;
    esac
}

# Role: Identify Orca validation results that do not prove target identity loss.
ka_orca_validation_is_transient() {
    case ${1-} in
        20 | 21 | 22 | 23 | 24) return 0 ;;
        *) return 1 ;;
    esac
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
    # Exactly one accepted receipt; with several documents -e would judge only the last.
    ((${#output} <= KA_ORCA_MAX_RESPONSE)) || return 1
    if [[ ${KA_ORCA_PARSER:-} == awk ]]; then
        ka_orca_awk send >/dev/null 2>&1 <<<"$output" || return 1
        return 0
    fi
    "$KA_ORCA_JQ" -n -e '
        [inputs] as $documents |
        ($documents | length) == 1 and
        ($documents[0] | .ok == true and .result.send.accepted == true)
    ' >/dev/null 2>&1 <<<"$output" || return 1
    return 0
}
