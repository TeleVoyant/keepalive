# Orca CLI JSON reader for hosts without jq.
#
# lib/orca.sh runs this program when jq is not installed, or when KEEPALIVE_ORCA_PARSER=awk,
# so the Orca backend works out of the box. It reproduces the jq programs in lib/orca.sh
# exactly - the same gates and the same output bytes - and the two must change together;
# the Orca adapter tests run against both parsers.
#
# Portability: POSIX awk only, so gawk, mawk, and BusyBox awk all run it: no gawk
# extensions, no arrays of arrays, no regular expressions on provider data. The caller sets
# LC_ALL=C, so strings are bytes; every length jq counts in characters is counted here in
# UTF-8 code points explicitly.
#
# Safety: anything not fully understood is refused, never guessed, so a divergence from jq
# can only reject a response, not accept a different identity. Refusals jq does not make:
# raw bytes that are not well-formed UTF-8, which Orca's JSON encoder never emits. Nesting
# is limited exactly as jq 1.7 limits it.
#
# Cost: lib/orca.sh caps the response size and runs this under the Orca deadline. Within
# that, the input is walked one line at a time: no JSON token can span a line break, and
# BusyBox awk's per-character access costs time proportional to the string it indexes, so
# Orca's pretty-printed output parses in time linear in its size. Strings are copied in
# runs, not byte by byte, and only their first KEEP code points are retained - every check
# and output needs at most that many - while their full length is still counted.
#
# Operations, selected with -v op=...:
#   list    discovery rows, then an optional #SKIPPED line, then #COMPLETE; or one
#           "#SCHEMA<TAB>gate" line. Exits 2 when the input is not JSON.
#   show    one validated terminal row; exits 22 for anything else.
#   send    exits 0 only for exactly one accepted send receipt.
#   status  exits 0 only for exactly one reachable runtime status.
#   error   prints the error code of a failed envelope, or "unknown".

BEGIN {
    for (i = 1; i < 256; i++) BYTE[sprintf("%c", i)] = i
    # jq's parser refuses to open an array or object once its stack holds 256 entries, and
    # an object member's value sits above both the object and its key. STACK mirrors that.
    MAX_DEPTH = 256
    # Every check and projection needs at most 4096 code points of a string. An error code
    # is printed whole, as jq prints it, so op=error keeps everything within the size cap.
    KEEP = op == "error" ? 4194304 : 4096
    # Stands in for an escaped U+0000, which awk strings cannot hold portably. It is a
    # control byte, so it is treated exactly as jq treats the NUL itself.
    NUL_MARK = sprintf("%c", 1)
    BINDING = "handle ptyId incarnationId worktreeId worktreePath executionHostId tabId leafId agentIdentity"
}

{ LINES[++line_count] = $0 }

END {
    line = 1; json = line_count ? LINES[1] "\n" : ""
    n = length(json); pos = 1; nodes = 0; roots = 0; STACK = 0
    parsed = parse_stream()
    if (op == "list") {
        if (!parsed) exit 2
        list_op()
    } else if (op == "show") {
        if (!parsed || !show_op()) exit 22
    } else if (op == "send") {
        if (!parsed || !send_op()) exit 1
    } else if (op == "status") {
        if (!parsed || !status_op()) exit 1
    } else if (op == "error") {
        print (parsed ? error_op() : "unknown")
    } else {
        exit 2
    }
}

# --- JSON parsing ------------------------------------------------------------------------

# Parse every whitespace-separated document; succeed only if all of them parse.
function parse_stream() {
    while (1) {
        skip_ws()
        if (pos > n) return 1
        if (!parse_value()) return 0
        ROOT[++roots] = ret
    }
}

# Skip whitespace, moving on to the next input line at the end of this one. Only here may
# parsing cross a line: inside a token, the line's final newline ends or refuses it.
function skip_ws(    c) {
    while (1) {
        while (pos <= n) {
            c = substr(json, pos, 1)
            if (c != " " && c != "\t" && c != "\n" && c != "\r") return
            pos++
        }
        if (line >= line_count) return
        json = LINES[++line] "\n"; n = length(json); pos = 1
    }
}

function new_node(type) {
    TYPE[++nodes] = type; STR[nodes] = ""; CPS[nodes] = 0; CTL[nodes] = 0
    ret = nodes
}

function parse_value(    c) {
    skip_ws()
    if (pos > n) return 0
    c = substr(json, pos, 1)
    if (c == "\"") return parse_string()
    if (c == "{") return parse_object()
    if (c == "[") return parse_array()
    if (c == "t") return parse_literal("true", "boolean")
    if (c == "f") return parse_literal("false", "boolean")
    if (c == "n") return parse_literal("null", "null")
    if (c == "-" || index("0123456789", c) > 0) return parse_number()
    return 0
}

function parse_literal(word, type) {
    if (substr(json, pos, length(word)) != word) return 0
    pos += length(word)
    new_node(type); STR[ret] = word
    return 1
}

function parse_number(    start, text) {
    start = pos
    if (substr(json, pos, 1) == "-") pos++
    if (substr(json, pos, 1) == "0") pos++
    else if (!skip_digits()) return 0
    if (substr(json, pos, 1) == ".") { pos++; if (!skip_digits()) return 0 }
    if (substr(json, pos, 1) == "e" || substr(json, pos, 1) == "E") {
        pos++
        if (substr(json, pos, 1) == "+" || substr(json, pos, 1) == "-") pos++
        if (!skip_digits()) return 0
    }
    text = substr(json, start, pos - start)
    new_node("number"); STR[ret] = text
    return 1
}

# Advance over one or more decimal digits; fail when there are none.
function skip_digits(    start) {
    start = pos
    while (pos <= n && index("0123456789", substr(json, pos, 1)) > 0) pos++
    return pos > start
}

function parse_object(    obj, count, key, c) {
    if (STACK >= MAX_DEPTH) return 0
    STACK++
    new_node("object"); obj = ret; pos++; count = 0
    skip_ws()
    if (substr(json, pos, 1) == "}") { pos++; OBJN[obj] = 0; STACK--; ret = obj; return 1 }
    while (1) {
        skip_ws()
        if (substr(json, pos, 1) != "\"" || !parse_string()) return 0
        key = ret
        skip_ws()
        if (substr(json, pos, 1) != ":") return 0
        pos++
        # The key occupies its own stack entry while its value is parsed, as in jq.
        STACK++
        if (!parse_value()) return 0
        STACK--
        count++; OKEY[obj, count] = key; OVAL[obj, count] = ret
        skip_ws()
        c = substr(json, pos, 1); pos++
        if (c == "}") { OBJN[obj] = count; STACK--; ret = obj; return 1 }
        if (c != ",") return 0
    }
}

function parse_array(    arr, count, c) {
    if (STACK >= MAX_DEPTH) return 0
    STACK++
    new_node("array"); arr = ret; pos++; count = 0
    skip_ws()
    if (substr(json, pos, 1) == "]") { pos++; ARRN[arr] = 0; STACK--; ret = arr; return 1 }
    while (1) {
        if (!parse_value()) return 0
        count++; AVAL[arr, count] = ret
        skip_ws()
        c = substr(json, pos, 1); pos++
        if (c == "]") { ARRN[arr] = count; STACK--; ret = arr; return 1 }
        if (c != ",") return 0
    }
}

# Decode one string into UTF-8 bytes, counting code points and noting any control
# character (C0, DEL, or C1 - what jq's [[:cntrl:]] matches). Unescaped text is copied in
# runs, and only the first KEEP code points are kept; CPS still holds the full count.
function parse_string(    c, b, b2, e, v, low, cps, ctl, need, i, start, run) {
    pos++; S_OUT = ""; S_KEPT = 0; cps = 0; ctl = 0; start = pos; run = 0
    while (pos <= n) {
        c = substr(json, pos, 1)
        if (c == "\"") {
            keep_text(substr(json, start, pos - start), run)
            pos++
            new_node("string"); STR[ret] = S_OUT; CPS[ret] = cps; CTL[ret] = ctl
            return 1
        }
        if (c == "\\") {
            keep_text(substr(json, start, pos - start), run); run = 0
            e = substr(json, pos + 1, 1); pos += 2
            if (e == "\"" || e == "\\" || e == "/") v = BYTE[e]
            else if (e == "b") v = 8
            else if (e == "f") v = 12
            else if (e == "n") v = 10
            else if (e == "r") v = 13
            else if (e == "t") v = 9
            else if (e == "u") {
                v = hex4()
                if (v < 0) return 0
                if (v >= 55296 && v <= 56319) {
                    # jq refuses a high surrogate that is not followed by a low one.
                    if (substr(json, pos, 2) != "\\u") return 0
                    pos += 2
                    low = hex4()
                    if (low < 56320 || low > 57343) return 0
                    v = 65536 + (v - 55296) * 1024 + (low - 56320)
                } else if (v >= 56320 && v <= 57343) {
                    # ...and replaces a lone low surrogate, as here.
                    v = 65533
                }
            } else {
                return 0
            }
            keep_text(v == 0 ? NUL_MARK : utf8(v), 1)
            if (v < 32 || (v >= 127 && v <= 159)) ctl = 1
            cps++
            start = pos
            continue
        }
        b = BYTE[c]
        # Raw control characters are not JSON; jq refuses them as well.
        if (b < 32) return 0
        pos++
        if (b < 128) { cps++; run++; if (b == 127) ctl = 1; continue }
        # Raw UTF-8: one well-formed sequence is one code point.
        if (b >= 194 && b <= 223) need = 1
        else if (b >= 224 && b <= 239) need = 2
        else if (b >= 240 && b <= 244) need = 3
        else return 0
        for (i = 1; i <= need; i++) {
            b2 = BYTE[substr(json, pos, 1)]
            if (b2 < 128 || b2 > 191) return 0
            if (i == 1) {
                # Overlong forms and encoded surrogates are not well-formed UTF-8.
                if ((b == 224 && b2 < 160) || (b == 237 && b2 > 159)) return 0
                if ((b == 240 && b2 < 144) || (b == 244 && b2 > 143)) return 0
                if (b == 194 && b2 <= 159) ctl = 1
            }
            pos++
        }
        cps++; run++
    }
    return 0
}

# Append text holding count code points to the string being decoded, up to KEEP of them.
# Only the needed prefix is examined: a code point is at most four bytes, and walking a
# whole megabyte run here byte by byte is what made a huge title take minutes.
function keep_text(text, count) {
    if (count <= 0 || S_KEPT >= KEEP) return
    if (S_KEPT + count <= KEEP) { S_OUT = S_OUT text; S_KEPT += count; return }
    S_OUT = S_OUT cp_head(substr(text, 1, (KEEP - S_KEPT) * 4), KEEP - S_KEPT)
    S_KEPT = KEEP
}

# Read four hex digits at pos into a code unit, or return -1.
function hex4(    i, c, d, v) {
    v = 0
    for (i = 0; i < 4; i++) {
        c = tolower(substr(json, pos + i, 1))
        if (c == "") return -1
        d = index("0123456789abcdef", c)
        if (d == 0) return -1
        v = v * 16 + d - 1
    }
    pos += 4
    return v
}

function utf8(v) {
    if (v < 128) return sprintf("%c", v)
    if (v < 2048) return sprintf("%c%c", 192 + int(v / 64), 128 + v % 64)
    if (v < 65536)
        return sprintf("%c%c%c", 224 + int(v / 4096), 128 + int(v / 64) % 64, 128 + v % 64)
    return sprintf("%c%c%c%c", 240 + int(v / 262144), 128 + int(v / 4096) % 64,
        128 + int(v / 64) % 64, 128 + v % 64)
}

# --- Value access, mirroring the jq predicates in lib/orca.sh ----------------------------

# The node 0 stands for an absent member, which jq reads as null.
function kind(id) { return id ? TYPE[id] : "null" }

# The value of a member, the last one when a key repeats (as jq does), or 0.
function member(obj, name,    i) {
    if (kind(obj) != "object") return 0
    for (i = OBJN[obj]; i >= 1; i--)
        if (STR[OKEY[obj, i]] == name) return OVAL[obj, i]
    return 0
}

function is_bool(id) { return kind(id) == "boolean" }
function is_true(id) { return kind(id) == "boolean" && STR[id] == "true" }
function nullable_text(id) { return kind(id) == "null" || kind(id) == "string" }
function present(id) { return kind(id) == "string" && CPS[id] > 0 }

function text_ok(id, maximum) {
    return kind(id) == "string" && CPS[id] > 0 && CPS[id] <= maximum && !CTL[id]
}

function absent_or_text(id, maximum) {
    return kind(id) == "null" || (kind(id) == "string" && (CPS[id] == 0 || text_ok(id, maximum)))
}

# The prefix of s holding at most count code points.
function cp_head(s, count,    i, len, b, seen) {
    len = length(s); seen = 0
    for (i = 1; i <= len; i++) {
        b = BYTE[substr(s, i, 1)]
        if ((b < 128 || b > 191) && ++seen > count) return substr(s, 1, i - 1)
    }
    return s
}

# s without control characters: C0, DEL, and the two-byte C1 sequences.
function strip_controls(s,    i, len, c, b, out) {
    len = length(s); out = ""
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1); b = BYTE[c]
        if (b < 32 || b == 127) continue
        if (b == 194 && i < len) {
            b = BYTE[substr(s, i + 1, 1)]
            if (b >= 128 && b <= 159) { i++; continue }
        }
        out = out c
    }
    return out
}

# jq's @tsv field escaping.
function tsv(s,    i, len, c, out) {
    len = length(s); out = ""
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\t") out = out "\\t"
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else out = out c
    }
    return out
}

# --- op=list: terminal list discovery ----------------------------------------------------

function base_ok(row,    agent) {
    agent = member(row, "agentIdentity")
    return kind(row) == "object" && kind(member(row, "handle")) == "string" &&
        is_bool(member(row, "connected")) && is_bool(member(row, "writable")) &&
        is_bool(member(row, "orphaned")) && nullable_text(agent)
}

function candidate(row,    agent) {
    agent = member(row, "agentIdentity")
    return is_true(member(row, "connected")) && is_true(member(row, "writable")) &&
        !is_true(member(row, "orphaned")) && kind(agent) == "string" && CPS[agent] > 0
}

function binding_types_ok(row,    names, count, i) {
    count = split("ptyId incarnationId worktreeId worktreePath executionHostId tabId leafId title", names, " ")
    for (i = 1; i <= count; i++)
        if (!nullable_text(member(row, names[i]))) return 0
    return 1
}

function binding_complete(row,    agent) {
    agent = member(row, "agentIdentity")
    return text_ok(member(row, "handle"), 512) && text_ok(member(row, "ptyId"), 4096) &&
        text_ok(member(row, "incarnationId"), 256) && text_ok(member(row, "worktreeId"), 4096) &&
        text_ok(member(row, "worktreePath"), 4096) && text_ok(member(row, "executionHostId"), 256) &&
        text_ok(member(row, "tabId"), 256) && text_ok(member(row, "leafId"), 256) &&
        text_ok(agent, 128) && substr(STR[agent], 1, 1) != "#"
}

# The complete binding as one comparable string; only used on complete, control-free rows.
function binding_key(row,    names, count, i, key) {
    count = split(BINDING, names, " "); key = ""
    for (i = 1; i <= count; i++) key = key "\t" STR[member(row, names[i])]
    return key
}

function envelope_failure(root,    meta, result, flag, total, i, count) {
    if (kind(root) != "object") return "not-object"
    if (!is_true(member(root, "ok"))) return "not-ok"
    meta = member(root, "_meta")
    if (kind(meta) != "object" || !text_ok(member(meta, "runtimeId"), 256)) return "runtime-id"
    result = member(root, "result"); TERMINALS = member(result, "terminals")
    if (kind(result) != "object" || kind(TERMINALS) != "array") return "terminals"
    flag = member(result, "truncated")
    if (!is_bool(flag)) return "truncation-marker"
    if (is_true(flag)) return "truncated"
    count = ARRN[TERMINALS]; total = member(result, "totalCount")
    if (kind(total) != "number" || STR[total] + 0 != count || count > 1000) return "total-count"
    for (i = 1; i <= count; i++)
        if (!base_ok(AVAL[TERMINALS, i])) return "row-type"
    for (i = 1; i <= count; i++)
        if (candidate(AVAL[TERMINALS, i]) && !binding_types_ok(AVAL[TERMINALS, i])) return "binding-type"
    return ""
}

function list_op(    root, gate, runtime, count, nc, i, row, inc, group, contested, incomplete, conflicting, detail) {
    if (roots != 1) { print "#SCHEMA\tdocument-count"; return }
    root = ROOT[1]
    gate = envelope_failure(root)
    if (gate != "") { print "#SCHEMA\t" gate; return }
    runtime = STR[member(member(root, "_meta"), "runtimeId")]
    count = ARRN[TERMINALS]; nc = 0
    for (i = 1; i <= count; i++) {
        row = AVAL[TERMINALS, i]
        if (candidate(row)) CAND[++nc] = row
    }
    for (i = 1; i <= nc; i++) {
        row = CAND[i]
        COMPLETE[i] = binding_complete(row)
        inc = member(row, "incarnationId")
        HAS_INC[i] = text_ok(inc, 256)
        INC[i] = HAS_INC[i] ? STR[inc] : ""
        KEY[i] = COMPLETE[i] ? binding_key(row) : ""
    }
    # Collisions are judged over every candidate carrying an incarnation, before
    # incomplete ones are dropped; see the jq program in ka_orca_discover.
    for (i = 1; i <= nc; i++) {
        if (!HAS_INC[i]) continue
        group = INC[i]
        if (group in FIRST) {
            if (!COMPLETE[i] || !COMPLETE[FIRST[group]] || KEY[i] != KEY[FIRST[group]]) AMBIGUOUS[group] = 1
        } else {
            FIRST[group] = i
        }
    }
    for (i = 1; i <= nc; i++) {
        if (!COMPLETE[i] || (INC[i] in AMBIGUOUS) || (INC[i] in SEEN)) continue
        SEEN[INC[i]] = 1
        emit_row(CAND[i], runtime)
    }
    incomplete = 0; conflicting = 0
    for (i = 1; i <= nc; i++) {
        contested = HAS_INC[i] && (INC[i] in AMBIGUOUS)
        if (contested) conflicting++
        else if (!COMPLETE[i]) incomplete++
    }
    if (incomplete + conflicting > 0) {
        detail = ""
        if (incomplete > 0) detail = "incomplete-binding=" incomplete
        if (conflicting > 0) detail = detail (detail == "" ? "" : ",") "ambiguous-incarnation=" conflicting
        print "#SKIPPED\t" (incomplete + conflicting) "\t" detail
    }
    print "#COMPLETE"
}

function emit_row(row, runtime,    title, name, path, parts, count, i) {
    title = member(row, "title")
    name = kind(title) == "string" ? STR[title] : ""
    name = cp_head(strip_controls(cp_head(name, 1024)), 256)
    path = STR[member(row, "worktreePath")]
    if (name == "") {
        name = "orca"
        count = split(path, parts, "/")
        for (i = count; i >= 1; i--) if (parts[i] != "") { name = parts[i]; break }
    }
    print tsv(STR[member(row, "agentIdentity")]) "\t" tsv(name) "\t" tsv(path) "\t" \
        tsv(STR[member(row, "handle")]) "\t" tsv(STR[member(row, "ptyId")]) "\t" \
        tsv(STR[member(row, "incarnationId")]) "\t" tsv(STR[member(row, "worktreeId")]) "\t" \
        tsv(runtime) "\t" tsv(STR[member(row, "executionHostId")]) "\t" \
        tsv(STR[member(row, "tabId")]) "\t" tsv(STR[member(row, "leafId")])
}

# --- op=show, send, status, error --------------------------------------------------------

function show_op(    root, runtime, term, handle, pty, inc, agent, connected, writable, orphaned) {
    if (roots != 1) return 0
    root = ROOT[1]
    if (kind(root) != "object" || !is_true(member(root, "ok"))) return 0
    runtime = member(member(root, "_meta"), "runtimeId")
    if (!text_ok(runtime, 256)) return 0
    term = member(member(root, "result"), "terminal")
    if (kind(term) != "object") return 0
    handle = member(term, "handle"); pty = member(term, "ptyId"); inc = member(term, "incarnationId")
    agent = member(term, "agentIdentity")
    connected = member(term, "connected"); writable = member(term, "writable")
    orphaned = member(term, "orphaned")
    if (!text_ok(handle, 512) || !absent_or_text(pty, 4096) || !absent_or_text(inc, 256)) return 0
    if (!text_ok(member(term, "worktreeId"), 4096) || !text_ok(member(term, "executionHostId"), 256)) return 0
    if (!text_ok(member(term, "tabId"), 256) || !text_ok(member(term, "leafId"), 256)) return 0
    if (!is_bool(connected) || !is_bool(writable) || !is_bool(orphaned)) return 0
    if (!absent_or_text(agent, 128)) return 0
    print tsv(STR[handle]) "\t" ((present(pty) && present(inc)) ? "1" : "0") "\t" \
        (present(pty) ? tsv(STR[pty]) : "-") "\t" (present(inc) ? tsv(STR[inc]) : "-") "\t" \
        tsv(STR[member(term, "worktreeId")]) "\t" tsv(STR[runtime]) "\t" \
        tsv(STR[member(term, "executionHostId")]) "\t" tsv(STR[member(term, "tabId")]) "\t" \
        tsv(STR[member(term, "leafId")]) "\t" (present(agent) ? "1" : "0") "\t" \
        (present(agent) ? tsv(STR[agent]) : "-") "\t" \
        STR[connected] "\t" STR[writable] "\t" STR[orphaned]
    return 1
}

function send_op(    root) {
    if (roots != 1) return 0
    root = ROOT[1]
    return kind(root) == "object" && is_true(member(root, "ok")) &&
        is_true(member(member(member(root, "result"), "send"), "accepted"))
}

function status_op(    root) {
    if (roots != 1) return 0
    root = ROOT[1]
    return kind(root) == "object" && is_true(member(root, "ok")) &&
        is_true(member(member(member(root, "result"), "runtime"), "reachable"))
}

function error_op(    code) {
    if (roots != 1) return "unknown"
    code = member(member(ROOT[1], "error"), "code")
    return kind(code) == "string" ? STR[code] : "unknown"
}
