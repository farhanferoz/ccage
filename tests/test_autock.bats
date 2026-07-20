#!/usr/bin/env bats
# Tests for bin/ccage-auto — the autonomous context manager.
#
# We don't launch a real Claude session here; we exercise the parts that are
# testable in isolation: occupancy measurement from a transcript JSONL, the
# context-window default + override, and flag parsing. The `--status` mode prints
# all of these and exits without spawning anything, so it is the test surface.
#
# Config-dir resolution falls through to the same _ccage_config_dir_for naming
# used everywhere else, which honours CCAGE_ROOT — so by pinning CCAGE_ROOT to a
# temp dir we get a deterministic transcript location regardless of the host's
# shell init.
bats_require_minimum_version 1.5.0

AUTO="$BATS_TEST_DIRNAME/../bin/ccage-auto"

setup() {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    mkdir -p "$BATS_TEST_TMPDIR/repo"
    # Resolve to the PHYSICAL path: ccage-auto derives the transcript slug from
    # os.getcwd() (canonicalised, like real Claude Code), so on macOS — where
    # $TMPDIR is /var -> /private/var — a logical $REPO would slug differently
    # and the watcher would look in the wrong session dir. Match it here.
    REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
    export CCAGE_ROOT="$BATS_TEST_TMPDIR"     # cage dir -> $CCAGE_ROOT/.claude-repo
    # Unset CLAUDE_CONFIG_DIR: when the suite runs inside a real cage it is set in
    # the environment, and resolve_config_dir's fast path would return it instead
    # of the CCAGE_ROOT-derived dir these tests pin. Tests must own the env.
    unset CCAGE_SLOT CCAGE_AUTOCK CCAGE_AUTOCK_WINDOW CLAUDE_CONFIG_DIR CCAGE_AUTOCK_WEEKLY_FLOOR
    # Hermetic even when the suite itself runs inside an autonomous session.
    unset CCAGE_AUTONOMOUS CCAGE_AUTOCK_NO_ASK_GUARD
    CAGE="$CCAGE_ROOT/.claude-repo"
    SLUG="${REPO//\//-}"
    SDIR="$CAGE/projects/$SLUG"
    mkdir -p "$SDIR"
}

# Write a transcript whose latest assistant turn sums to $1 input-side tokens,
# for model $2 (default claude-opus-4-8).
write_transcript() {
    local total="$1" model="${2:-claude-opus-4-8}"
    local inp=$(( total / 2 )) read=$(( total / 2 )) create=0
    {
        printf '%s\n' '{"type":"user","message":{"content":"hello"}}'
        printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d},"content":[{"type":"text","text":"ok"}]}}\n' \
            "$model" "$inp" "$read" "$create"
    } > "$SDIR/sess.jsonl"
}

status() { ( cd "$REPO" && "$AUTO" --status ); }

@test "measures occupancy as input+cache_read+cache_creation over the 1M default window" {
    write_transcript 350000
    run status
    [ "$status" -eq 0 ]
    [[ "$output" == *"window       : 1000000"* ]]
    [[ "$output" == *"35.0% of window"* ]]
}

@test "--window overrides the context window" {
    write_transcript 350000
    run bash -c "cd '$REPO' && '$AUTO' --window 700000 --status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"window       : 700000"* ]]
    [[ "$output" == *"50.0% of window"* ]]
}

@test "CCAGE_AUTOCK_WINDOW env overrides the window too" {
    write_transcript 100000
    CCAGE_AUTOCK_WINDOW=200000 run status
    [ "$status" -eq 0 ]
    [[ "$output" == *"50.0% of window"* ]]
}

@test "default thresholds are 40%% soft / 60%% hard, re-nudge at 55%%" {
    write_transcript 100000
    run status
    [[ "$output" == *"soft / hard  : 40% / 60%"* ]]
    [[ "$output" == *"re-nudge     : 55%"* ]]
}

@test "derivation table: soft=40 -> hard=60, renudge=55 (explicit --soft, default hard)" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 40 --status"
    [[ "$output" == *"soft / hard  : 40% / 60%"* ]]
    [[ "$output" == *"re-nudge     : 55%"* ]]
}

@test "derivation table: soft=45 -> hard=65, renudge=60" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 45 --status"
    [[ "$output" == *"soft / hard  : 45% / 65%"* ]]
    [[ "$output" == *"re-nudge     : 60%"* ]]
}

@test "derivation table: soft=85 -> hard capped at 100, renudge=95, warns on the cap" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 85 --status 2>&1"
    [[ "$output" == *"soft / hard  : 85% / 100%"* ]]
    [[ "$output" == *"re-nudge     : 95%"* ]]
    [[ "$output" == *"derived hard backstop hit the 100% cap"* ]]
}

@test "derivation table: explicit --hard 70 with --soft 40 stays 70 (explicit wins)" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 40 --hard 70 --status"
    [[ "$output" == *"soft / hard  : 40% / 70%"* ]]
    [[ "$output" == *"re-nudge     : 65%"* ]]
}

@test "--soft/--hard override the thresholds" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 30 --hard 50 --status"
    [[ "$output" == *"soft / hard  : 30% / 50%"* ]]
}

@test "enabled by default; --no-autock disables" {
    write_transcript 100000
    run status
    [[ "$output" == *"enabled      : True"* ]]
    run bash -c "cd '$REPO' && '$AUTO' --no-autock --status"
    [[ "$output" == *"enabled      : False"* ]]
}

@test "CCAGE_AUTOCK=0 disables the watcher" {
    write_transcript 100000
    CCAGE_AUTOCK=0 run status
    [[ "$output" == *"enabled      : False"* ]]
}

@test "reports a missing transcript without error" {
    rm -f "$SDIR"/*.jsonl
    run status
    [ "$status" -eq 0 ]
    [[ "$output" == *"transcript   : none found"* ]]
}

@test "per-model window map (CCAGE_AUTOCK_WINDOWS) resolves by model-id substring" {
    write_transcript 350000 claude-opus-4-8
    CCAGE_AUTOCK_WINDOWS="opus=500000,haiku=200000" run status
    [ "$status" -eq 0 ]
    [[ "$output" == *"window       : 500000"* ]]
    [[ "$output" == *"70.0% of window"* ]]
}

@test "--window-map sets per-model windows from the CLI" {
    write_transcript 350000 claude-opus-4-8
    run bash -c "cd '$REPO' && '$AUTO' --window-map 'opus=700000' --status"
    [[ "$output" == *"window       : 700000"* ]]
    [[ "$output" == *"50.0% of window"* ]]
}

@test "haiku is auto-detected as a 200K built-in family" {
    write_transcript 100000 claude-haiku-4-5
    run status
    [[ "$output" == *"window       : 200000"* ]]
    [[ "$output" == *"50.0% of window"* ]]
}

@test "an explicit [1m] marker in the model id resolves to 1M" {
    write_transcript 100000 "claude-haiku-4-5[1m]"
    run status
    [[ "$output" == *"window       : 1000000"* ]]
    [[ "$output" == *"10.0% of window"* ]]
}

@test "--window force beats the per-model map" {
    write_transcript 100000 claude-opus-4-8
    CCAGE_AUTOCK_WINDOWS="opus=500000" run bash -c "cd '$REPO' && '$AUTO' --window 200000 --status"
    [[ "$output" == *"window       : 200000"* ]]
}

@test "nonsensical thresholds are clamped (soft >= hard raises hard)" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 60 --hard 40 --status 2>&1"
    [[ "$output" == *"soft (60%) >= hard (40%); raising hard to 70%"* ]]
    [[ "$output" == *"soft / hard  : 60% / 70%"* ]]
}

@test "out-of-range thresholds fall back to defaults" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --soft 0 --hard 150 --status 2>&1"
    [[ "$output" == *"soft=0 out of range (0,100); using 40"* ]]
    [[ "$output" == *"hard=150 out of range (0,100]; deriving from soft instead"* ]]
    [[ "$output" == *"soft / hard  : 40% / 60%"* ]]
}

@test "picks the newest transcript when /clear has rotated the file" {
    write_transcript 900000                       # old, near-full session
    sleep 1
    # newer file = freshly-cleared session, small occupancy
    printf '{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":5000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"ok"}]}}\n' \
        > "$SDIR/sess2.jsonl"
    run status
    [[ "$output" == *"1.0% of window"* ]]
}

@test "active_jsonl: since filters out a transcript that predates session start (unit)" {
    run python3 - "$AUTO" "$SDIR" <<'PY'
import importlib.util, importlib.machinery, os, sys
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sdir = sys.argv[2]

stale = os.path.join(sdir, "stale.jsonl")
open(stale, "w").write("old\n")
os.utime(stale, (100, 100))

# Without `since` the stale file (the only one) is still "newest" and wins —
# the pre-fix behavior, kept for the --status caller that has no session
# start time to filter against.
assert m.active_jsonl(sdir) == stale

# A previous session's leftover transcript must never look like the current
# session's, even though it is the newest file on disk until this session
# writes its own.
assert m.active_jsonl(sdir, since=200) is None, "stale transcript must be excluded"

fresh = os.path.join(sdir, "fresh.jsonl")
open(fresh, "w").write("new\n")
os.utime(fresh, (300, 300))
assert m.active_jsonl(sdir, since=200) == fresh
assert m.active_jsonl(sdir) == fresh   # still picks the newest by mtime overall
print("UNIT_OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *UNIT_OK* ]]
}

# --- End-to-end driving tests ----------------------------------------------
#
# These two exercise the watcher's DRIVE path (not just measurement) through the
# real pty proxy. CCAGE_AUTOCK_EXEC swaps the cage `claude` for a fake that grows
# a transcript past the thresholds and records every byte the watcher injects, so
# we can assert on the actual keystrokes without a real model. They cover the two
# previously stub-only paths: the hard-threshold Escape-interrupt, and a session
# self-triggering off its own occupancy through checkpoint -> /clear -> resume.

# Write a fake `claude` to $1 (a python3 script). Reads bytes the watcher types on
# stdin into $FAKE_CAPTURE; grows $FAKE_SDIR/sess.jsonl past the soft/hard line.
#   FAKE_MODE=hard    : never checkpoints -> watcher must Escape-interrupt.
#   FAKE_MODE=confirm : on the nudge, echoes the sentinel + touches RESUME.md so
#                       the watcher confirms, clears, and types the resume nudge.
make_fake_claude() {
    cat > "$1" <<'PY'
import json, os, select, sys, time

sdir = os.environ["FAKE_SDIR"]
mode = os.environ.get("FAKE_MODE", "hard")
sentinel = os.environ.get("FAKE_SENTINEL", "CHECKPOINTED")
tokens0 = int(os.environ.get("FAKE_TOKENS", "300000"))   # opening occupancy
exit_on = os.environ.get("FAKE_EXIT_ON", "").encode()    # break when this is seen
jsonl = os.path.join(sdir, "sess.jsonl")

def append_turn(tokens, text="working"):
    half = tokens // 2
    obj = {"type": "assistant", "message": {
        "model": "claude-opus-4-8",
        "usage": {"input_tokens": half,
                  "cache_read_input_tokens": tokens - half,
                  "cache_creation_input_tokens": 0},
        "content": [{"type": "text", "text": text}]}}
    with open(jsonl, "a") as f:
        f.write(json.dumps(obj) + "\n")

# Open at the configured occupancy (default: above the soft+hard line so the
# watcher engages on poll #1; a low value keeps it idle for kickoff-only tests).
append_turn(tokens0)

cap = open(os.environ["FAKE_CAPTURE"], "ab", buffering=0)
# Record the autonomous marker the proxy exports, so tests can assert the
# launched child actually inherits it (not just that the parent set it).
cap.write(("ENV_CCAGE_AUTONOMOUS=%s\n"
           % os.environ.get("CCAGE_AUTONOMOUS", "unset")).encode())
buf = b""
confirmed = False
deadline = time.time() + float(os.environ.get("FAKE_DEADLINE", "30"))
while time.time() < deadline:
    r, _, _ = select.select([0], [], [], 0.5)
    if 0 in r:
        try:
            d = os.read(0, 65536)
        except OSError:
            break
        if not d:
            break
        cap.write(d)
        buf += d
    if exit_on and exit_on in buf:   # generic exit hook (e.g. init-prompt marker)
        time.sleep(0.3)
        break
    if mode == "hard":
        if b"\x1b" in buf:           # watcher Escape-interrupted at the hard line
            time.sleep(0.3)
            break
    elif mode == "confirm":
        if not confirmed and len(buf) > 20:
            # Play the model: echo the sentinel into the transcript and refresh
            # RESUME.md so the watcher's on-disk confirmation passes.
            append_turn(300000, text=sentinel + " done")
            with open(os.path.join(os.getcwd(), "RESUME.md"), "a") as f:
                f.write("checkpoint\n")
            confirmed = True
        if b"Resume the task" in buf:  # watcher cleared and typed the resume nudge
            break
    elif mode == "done":
        # Play the model running `/checkpoint --final`: drop the completion
        # marker after the first injected byte (the soft nudge), so it is newer
        # than the watcher's start time. Then give the watcher a couple of polls
        # to notice and stand down, and exit.
        if not confirmed and len(buf) > 0:
            with open(os.path.join(os.getcwd(), ".ccage-session-done"), "w") as f:
                f.write("done\n")
            confirmed = True
            deadline = time.time() + 3
    elif mode == "confirm_then_raise":
        # Play the incident: the model checkpoints (sentinel + RESUME), and a
        # live `--set soft=N` raises the threshold above the session's current
        # occupancy. Both must land inside ONE poll interval so the watcher
        # sees them together -- written back to back with no sleep between,
        # against a 1s poll, so the tick cannot fall in the gap. (Pausing to
        # stage them is not an option: un-pausing deliberately re-arms from
        # NORMAL, which destroys the very state under test.)
        if not confirmed and len(buf) > 20:
            append_turn(300000, text=sentinel + " done")
            with open(os.path.join(os.getcwd(), "RESUME.md"), "a") as f:
                f.write("checkpoint\n")
            with open(os.path.join(os.getcwd(), ".ccage-autock.conf"), "w") as f:
                f.write("soft=50\n")             # 50% > the fixture's 30% occupancy
            confirmed = True
        if b"Resume the task" in buf:
            break
    elif mode == "manual_clear":
        # Play a user-driven /clear (not the watcher's own): a fresh,
        # low-occupancy transcript appears under a new name, never through the
        # watcher's checkpoint/clear flow. Never emit the sentinel or touch
        # RESUME.md, so the only way the watcher can react correctly is to
        # notice pct fell below soft and cancel back to NORMAL on its own.
        if not confirmed and len(buf) > 20:
            tokens = 20000   # well under a 10% soft line on the 1M default window
            half = tokens // 2
            obj = {"type": "assistant", "message": {
                "model": "claude-opus-4-8",
                "usage": {"input_tokens": half, "cache_read_input_tokens": half,
                          "cache_creation_input_tokens": 0},
                "content": [{"type": "text", "text": "fresh"}]}}
            with open(os.path.join(sdir, "sess2.jsonl"), "w") as f:
                f.write(json.dumps(obj) + "\n")
            confirmed = True
        logpath = os.path.join(os.path.dirname(os.path.dirname(sdir)), "ccage-autock.log")
        if confirmed and os.path.exists(logpath) and "cancelling nudge cycle" in open(logpath).read():
            time.sleep(0.3)
            break
sys.exit(0)
PY
}

cap_has() {  # cap_has <python-bytes-literal> -> 0 if present in $CAP
    python3 -c "import sys; sys.exit(0 if $1 in open('$CAP','rb').read() else 1)"
}

# Drive the full proxy with a fake claude. $1 = FAKE_MODE, $2 = ccage-auto flags.
drive() {
    STUB="$BATS_TEST_TMPDIR/fakeclaude.py"
    CAP="$BATS_TEST_TMPDIR/capture.bin"
    make_fake_claude "$STUB"
    : > "$CAP"
    run bash -c "cd '$REPO' && \
        CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1 \
        CCAGE_AUTOCK_EXEC='python3 \"$STUB\"' \
        FAKE_SDIR='$SDIR' FAKE_CAPTURE='$CAP' FAKE_MODE='$1' \
        '$AUTO' $2 </dev/null"
}

@test "hard threshold Escape-interrupts a session that won't checkpoint" {
    drive hard "--soft 10 --hard 20 --poll 1"
    [ "$status" -eq 0 ]
    cap_has "b'\x1b'"                              # ESC was injected
    cap_has "b'auto-checkpoint'"                   # nudged first
    grep -q "HARD threshold" "$CAGE/ccage-autock.log"
}

@test "re-nudge is occupancy-anchored (hard - 5), fires without an Escape interrupt" {
    # soft=10, hard=30 -> re-nudge=25. Pin occupancy at 28% (above soft and the
    # re-nudge line, below hard) so the soft nudge fires, then the SAME
    # occupancy crosses the re-nudge line on the next poll -- well before the
    # 600s timeout fallback could ever fire in a 6s test. Never reaches hard,
    # so this isolates the occupancy trigger from both the timeout fallback
    # and the hard escalation (neither of which types this message or skips
    # the Escape interrupt).
    export FAKE_TOKENS=280000 FAKE_DEADLINE=6
    drive hard "--soft 10 --hard 30 --poll 1"
    unset FAKE_TOKENS FAKE_DEADLINE
    [ "$status" -eq 0 ]
    grep -q "reached the re-nudge line (25%)" "$CAGE/ccage-autock.log"
    ! grep -q "HARD threshold" "$CAGE/ccage-autock.log"   # never escalated -- occupancy stayed under hard
    ! cap_has "b'\x1b'"                                    # re-nudge never interrupts
}

@test "NUDGED state cancels rather than re-nudges when occupancy drops below soft mid-cycle" {
    # A manual /clear rotates the transcript to a fresh, low-occupancy file
    # while the watcher is mid-nudge (soft crossed, not yet confirmed). It must
    # stand down to NORMAL instead of re-nudging or hard-escalating off the
    # stale high pct.
    drive manual_clear "--soft 10 --hard 90 --poll 1"
    [ "$status" -eq 0 ]
    cap_has "b'auto-checkpoint'"                          # nudged once, at the old high pct
    grep -q "cancelling nudge cycle; back to NORMAL" "$CAGE/ccage-autock.log"
    ! cap_has "b'/clear'"                                 # never auto-cleared
    ! grep -q "HARD threshold" "$CAGE/ccage-autock.log"   # never hard-escalated
}

@test "a confirmed checkpoint still clears when a live --set raises soft above the current occupancy" {
    # Live incident, v0.13.1: nudge at 35.1%, the model checkpointed, then
    # `--set soft=45` landed while occupancy read 38.2%. The NUDGED state
    # tested `pct < soft` BEFORE `_confirmed()`, so it cancelled the cycle,
    # threw away a checkpoint that had already been written, and left the
    # session parked -- the model had printed the sentinel and stopped, so no
    # clear was ever coming. The confirmation must win over the raise.
    drive confirm_then_raise "--soft 10 --hard 90 --poll 1"
    [ "$status" -eq 0 ]
    cap_has "b'auto-checkpoint'"                           # nudged at the low soft
    grep -q "control update: soft=50%" "$CAGE/ccage-autock.log"   # the raise landed
    grep -q "checkpoint confirmed" "$CAGE/ccage-autock.log"
    cap_has "b'/clear'"                                    # ...and the clear followed
    ! grep -q "cancelling nudge cycle" "$CAGE/ccage-autock.log"
}

@test "self-triggers off own occupancy: checkpoint -> /clear -> resume" {
    drive confirm "--soft 10 --hard 90 --poll 1"
    [ "$status" -eq 0 ]
    cap_has "b'auto-checkpoint'"                   # soft nudge typed
    cap_has "b'/clear'"                            # watcher cleared
    cap_has "b'Resume the task from RESUME.md'"    # resume nudge typed
    [ -f "$REPO/RESUME.md" ]                       # model refreshed RESUME
    grep -q "checkpoint confirmed" "$CAGE/ccage-autock.log"
    grep -q "soft threshold hit"   "$CAGE/ccage-autock.log"
}

@test "--no-autock is a transparent pass-through that propagates the exit code" {
    # Disabled: no pty proxy, no watcher — just exec the launch command and
    # return its status. A regression here (swallowed code, double-launch) is
    # silent, so pin it.
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_EXEC='exit 42' '$AUTO' --no-autock </dev/null"
    [ "$status" -eq 42 ]
    [[ "$output" == *"disabled — launching normally"* ]]
    [ ! -f "$CAGE/ccage-autock.log" ]             # watcher never ran
}

@test "session_done_mtime: 0 when the marker is absent, >0 when it exists" {
    run python3 - "$AUTO" "$REPO" <<'PY'
import importlib.util, importlib.machinery, os, sys
# ccage-auto has no .py suffix, so load it via an explicit source loader.
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
d = sys.argv[2]
assert m.session_done_mtime(d) == 0.0, "absent must be 0"
p = os.path.join(d, ".ccage-session-done"); open(p, "w").write("x")
assert m.session_done_mtime(d) > 0, "present must be >0"
os.remove(p); assert m.session_done_mtime(d) == 0.0, "removed must be 0"
print("UNIT_OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *UNIT_OK* ]]
}

@test "watcher pidfiles are per-pid: teardown removes only its own, dead ones are swept" {
    # W1: one shared .ccage-autock.pid was last-writer-wins and was removed
    # unconditionally, so a second watcher starting (and then exiting) in the
    # same directory erased a LIVE watcher's ownership — after which the next
    # session's SessionStart hook deleted the conf/done state that watcher was
    # still using. Each watcher now writes and removes ONLY its own record.
    git init -q "$REPO" >/dev/null 2>&1 || skip "git unavailable"
    run python3 - "$AUTO" "$REPO" <<'PY'
import importlib.util, importlib.machinery, os, subprocess, sys
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
d = sys.argv[2]
rec = lambda pid: os.path.join(d, ".ccage-autock.pid.%d" % pid)
me = os.getpid()
sib = subprocess.Popen(["sleep", "30"])          # a real, live sibling watcher

m.write_watcher_pidfile(d, me)
m.write_watcher_pidfile(d, sib.pid)              # must not clobber mine
assert os.path.isfile(rec(me)), "sibling's write clobbered this watcher's record"
assert os.path.isfile(rec(sib.pid))
assert open(rec(me)).read().startswith("pid=%d\n" % me)

m.remove_watcher_pidfile(d, me)                  # my teardown
assert not os.path.exists(rec(me))
assert os.path.isfile(rec(sib.pid)), "teardown removed a LIVE sibling's record"

sib.kill(); sib.wait()                           # SIGKILL: no teardown of its own
m.write_watcher_pidfile(d, me)
assert os.path.isfile(rec(me))
assert not os.path.exists(rec(sib.pid)), "dead sibling's record was not swept"
left = sorted(n for n in os.listdir(d) if n.startswith(".ccage-autock.pid"))
assert left == [os.path.basename(rec(me))], "unexpected pidfile litter: %r" % left
print("UNIT_OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *UNIT_OK* ]]
    grep -q '^\.ccage-autock\.pid\*$' "$REPO/.git/info/exclude"
}

@test "a --final completion marker stands the watcher down before any /clear" {
    # The model marks the session done mid-run (writes .ccage-session-done). The
    # watcher must stop its state machine on the next poll — nudge already fired,
    # but no /clear or resume nudge should follow.
    drive done "--soft 10 --hard 90 --poll 1"
    [ "$status" -eq 0 ]
    cap_has "b'auto-checkpoint'"                    # soft nudge fired first
    [ -f "$REPO/.ccage-session-done" ]              # marker was written
    grep -q "standing down" "$CAGE/ccage-autock.log"
    ! cap_has "b'/clear'"                           # stood down before clearing
    ! cap_has "b'Resume the task from RESUME.md'"   # ...and before resuming
}

# --- Live control file (/checkpoint-threshold) --------------------------------

conf() { ( cd "$REPO" && "$AUTO" "$@" ); }

# --- Control-plane dispatch (Task 6: recognised anywhere in argv) -----------

@test "--set found after other flags (the ccage-auto-yolo alias shape) still writes the control file and exits" {
    run bash -c "cd '$REPO' && '$AUTO' --dangerously-skip-permissions --set soft=40"
    [ "$status" -eq 0 ]
    [[ "$output" == *"control file updated — soft=40%"* ]]
    grep -q '^soft=40$' "$REPO/.ccage-autock.conf"
}

@test "--pause/--reset found after other flags also dispatch, not just --set" {
    run bash -c "cd '$REPO' && '$AUTO' --dangerously-skip-permissions --pause"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PAUSED"* ]]
    grep -q '^paused=1$' "$REPO/.ccage-autock.conf"

    run bash -c "cd '$REPO' && '$AUTO' --dangerously-skip-permissions --reset"
    [ "$status" -eq 0 ]
    [ ! -f "$REPO/.ccage-autock.conf" ]
}

@test "a control token after a literal -- belongs to claude, not ccage-auto" {
    # -- is the documented hard boundary: anything after it is claude's
    # verbatim, even if it happens to spell --set.
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_EXEC='printf %s \"\$*\"' '$AUTO' -- --set soft=40 </dev/null"
    [ "$status" -eq 0 ]
    [ ! -f "$REPO/.ccage-autock.conf" ]
    [[ "$output" == *"--set soft=40"* ]]
}

@test "a typo'd ccage-auto-shaped flag warns before being forwarded to claude" {
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_EXEC='exit 0' '$AUTO' --hardd 70 </dev/null"
    [[ "$output" == *"'--hardd' looks like a ccage-auto flag but wasn't recognised"* ]]
}

@test "--set soft writes the control file and --status shows it" {
    write_transcript 100000
    run conf --set soft=50
    [ "$status" -eq 0 ]
    [ -f "$REPO/.ccage-autock.conf" ]
    grep -q '^soft=50$' "$REPO/.ccage-autock.conf"
    run status
    [[ "$output" == *"overrides    : soft=50%"* ]]
    # No hard/CCAGE_AUTOCK_HARD was ever named, so hard re-derives from the
    # new soft (min(soft + 20, 100)) instead of falling back to the old flat
    # launch default: 50 + 20 = 70, re-nudge 70 - 5 = 65.
    [[ "$output" == *"effective    : 50% / 70% (re-nudge 65%)"* ]]
}

@test "--set soft+hard writes both thresholds" {
    run conf --set soft=45 hard=62
    [ "$status" -eq 0 ]
    grep -q '^soft=45$' "$REPO/.ccage-autock.conf"
    grep -q '^hard=62$' "$REPO/.ccage-autock.conf"
}

@test "--set clamps a soft >= hard pair when both are given" {
    run bash -c "cd '$REPO' && '$AUTO' --set soft=80 hard=40 2>&1"
    [[ "$output" == *"soft (80%) >= hard (40%); raising hard to 90%"* ]]
    grep -q '^soft=80$' "$REPO/.ccage-autock.conf"
    grep -q '^hard=90$' "$REPO/.ccage-autock.conf"
}

@test "--set soft=85 (no hard) warns that the derived hard hit the 100% cap" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --set soft=85 2>&1"
    [[ "$output" == *"derived hard backstop hit the 100% cap"* ]]
    grep -q '^soft=85$' "$REPO/.ccage-autock.conf"
    ! grep -q '^hard=' "$REPO/.ccage-autock.conf"   # derived, not persisted -- stays dynamic
    run status
    [[ "$output" == *"effective    : 85% / 100% (re-nudge 95%)"* ]]
}

@test "a live --set soft=N with no hard re-derives hard from the new soft (launch hard was default)" {
    write_transcript 100000
    run conf --set soft=50
    run status
    [[ "$output" == *"effective    : 50% / 70% (re-nudge 65%)"* ]]
}

@test "print_status: an explicit launch --hard stays sticky when the control file only overrides soft" {
    write_transcript 100000
    printf 'soft=50\n' > "$REPO/.ccage-autock.conf"
    # CCAGE_AUTOCK_HARD makes THIS --status invocation's own cfg.hard_explicit
    # True, standing in for "the running watcher was launched with an explicit
    # hard" -- effective hard must stay 55 (explicit), not re-derive to 70 from
    # the control file's soft=50.
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_HARD=55 '$AUTO' --status"
    [[ "$output" == *"overrides    : soft=50%"* ]]
    [[ "$output" == *"effective    : 50% / 55% (re-nudge 50%)"* ]]
}

@test "Watcher._refresh_control: a live soft-only override re-derives hard when the launch hard was NOT explicit, but stays sticky when it WAS (unit)" {
    run python3 - "$AUTO" "$REPO" "$SDIR" <<'PY'
import importlib.util, importlib.machinery, os, sys, threading
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
cwd, sdir = sys.argv[2], sys.argv[3]

# Case 1: launch hard was NOT explicit (soft-only launch) -> a live soft-only
# override re-derives hard from the new soft.
cfg = m.Config(["--soft", "40"]); cfg.validate()
assert (cfg.soft, cfg.hard, cfg.hard_explicit) == (40.0, 60.0, False), (cfg.soft, cfg.hard, cfg.hard_explicit)
r, w = os.pipe()
wat = m.Watcher(cfg, w, threading.Lock(), cwd, sdir, open(os.devnull, "w"))
m.write_control_file(cwd, {"soft": 50.0})
wat.conf_mtime = -1; wat._refresh_control()
assert (wat.cfg.soft, wat.cfg.hard, wat.cfg.renudge) == (50.0, 70.0, 65.0), \
    (wat.cfg.soft, wat.cfg.hard, wat.cfg.renudge)
os.remove(m.control_path(cwd))

# Case 2: launch hard WAS explicit -> the same soft-only override leaves hard
# untouched.
cfg2 = m.Config(["--soft", "35", "--hard", "55"]); cfg2.validate()
assert (cfg2.soft, cfg2.hard, cfg2.hard_explicit) == (35.0, 55.0, True), (cfg2.soft, cfg2.hard, cfg2.hard_explicit)
wat2 = m.Watcher(cfg2, w, threading.Lock(), cwd, sdir, open(os.devnull, "w"))
m.write_control_file(cwd, {"soft": 50.0})
wat2.conf_mtime = -1; wat2._refresh_control()
assert (wat2.cfg.soft, wat2.cfg.hard) == (50.0, 55.0), (wat2.cfg.soft, wat2.cfg.hard)
os.remove(m.control_path(cwd))
print("UNIT_OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *UNIT_OK* ]]
}

@test "_process_start_epoch uses ps -o etime= (portable) and correctly parses a BSD-shaped elapsed string, not etimes= (Linux/procps-only, absent on BSD/Darwin) (unit)" {
    # Regression for a real macOS defect: ps -o etimes= is a Linux/procps
    # extension, confirmed absent from the BSD/Darwin ps keyword table (only
    # `etime`, singular, elapsed-time-as-a-string, is common to both). Using
    # etimes= there produces empty output that fails SILENTLY -- no error, no
    # start token, the pid-reuse guard just never engages. This test does not
    # depend on the host's real ps output (which is Linux-shaped on CI and
    # would not by itself catch a regression back to etimes=): it mocks
    # subprocess.run to return a captured BSD-format `[[DD-]hh:]mm:ss` string
    # ("1-02:00:15" = 1 day, 2h, 0m, 15s = 93615s) regardless of platform, and
    # asserts both (a) the exact argv passed to ps names etime=, not etimes=,
    # and (b) that string parses to the correct elapsed seconds.
    run python3 - "$AUTO" <<'PY'
import importlib.util, importlib.machinery, subprocess, sys, time
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)

calls = []
class FakeResult:
    stdout = "1-02:00:15\n"
def fake_run(args, **kwargs):
    calls.append(args)
    return FakeResult()

real_run = subprocess.run
subprocess.run = fake_run
try:
    before = time.time()
    epoch = m._process_start_epoch(12345)
finally:
    subprocess.run = real_run

assert calls, "ps was never invoked"
assert calls[0][:3] == ["ps", "-o", "etime="], \
    "must request etime=, not etimes= (Linux/procps-only): %r" % (calls[0],)
assert epoch is not None
assert abs((before - epoch) - 93615) < 2, (before, epoch)

# Direct parser tests, independent of the ps invocation.
assert m._parse_etime("00:05") == 5
assert m._parse_etime("01:30") == 90
assert m._parse_etime("02:00:15") == 7215
assert m._parse_etime("1-02:00:15") == 93615
assert m._parse_etime("10-00:00:00") == 864000
assert m._parse_etime("garbage") is None
assert m._parse_etime("") is None
print("UNIT_OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *UNIT_OK* ]]
}

@test "--pause then --resume toggles the paused flag" {
    run conf --pause
    [ "$status" -eq 0 ]
    grep -q '^paused=1$' "$REPO/.ccage-autock.conf"
    run conf --resume
    [ "$status" -eq 0 ]
    grep -q '^paused=0$' "$REPO/.ccage-autock.conf"
}

@test "--reset removes the control file" {
    conf --set soft=50
    [ -f "$REPO/.ccage-autock.conf" ]
    run conf --reset
    [ "$status" -eq 0 ]
    [ ! -f "$REPO/.ccage-autock.conf" ]
}

@test "--set is git-excluded (never shows as untracked)" {
    ( cd "$REPO" && git init -q )
    conf --set soft=50
    run bash -c "cd '$REPO' && git check-ignore .ccage-autock.conf"
    [ "$status" -eq 0 ]
}

@test "control file: read/write/refresh apply over the launch baseline (unit)" {
    run python3 - "$AUTO" "$REPO" "$SDIR" <<'PY'
import importlib.util, importlib.machinery, os, sys, threading
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
cwd, sdir = sys.argv[2], sys.argv[3]

# malformed lines and unknown keys are ignored; good values parse.
open(m.control_path(cwd), "w").write("soft=50\n# c\ngarbage\nhard=oops\npaused=1\n")
ov = m.read_control_file(cwd)
assert ov == {"soft": 50.0, "paused": True}, ov
os.remove(m.control_path(cwd))   # start the apply section from a clean slate

# a watcher applies the file over its launch baseline, then reverts on removal.
cfg = m.Config(["--soft", "35", "--hard", "55"]); cfg.validate()
r, w = os.pipe()
wat = m.Watcher(cfg, w, threading.Lock(), cwd, sdir, open(os.devnull, "w"))
m.write_control_file(cwd, {"soft": 50.0, "hard": 66.0})
wat.conf_mtime = -1; wat._refresh_control()
assert (wat.cfg.soft, wat.cfg.hard, wat.paused) == (50.0, 66.0, False), \
    (wat.cfg.soft, wat.cfg.hard, wat.paused)
m.write_control_file(cwd, {"paused": True})
wat.conf_mtime = -1; wat._refresh_control()
assert wat.paused is True and wat.cfg.soft == 50.0
os.remove(m.control_path(cwd))
wat.conf_mtime = -1; wat._refresh_control()
assert (wat.cfg.soft, wat.cfg.hard, wat.paused) == (35.0, 55.0, False), \
    "removal must revert to launch baseline"
print("UNIT_OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *UNIT_OK* ]]
}

@test "a paused control file suppresses nudges over the pty" {
    printf 'paused=1\n' > "$REPO/.ccage-autock.conf"
    STUB="$BATS_TEST_TMPDIR/fakeclaude.py"
    CAP="$BATS_TEST_TMPDIR/capture.bin"
    make_fake_claude "$STUB"
    : > "$CAP"
    run bash -c "cd '$REPO' && \
        CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1 \
        CCAGE_AUTOCK_EXEC='python3 \"$STUB\"' \
        FAKE_SDIR='$SDIR' FAKE_CAPTURE='$CAP' FAKE_MODE=hard FAKE_DEADLINE=4 \
        '$AUTO' --soft 10 --hard 20 --poll 1 </dev/null"
    [ "$status" -eq 0 ]
    ! cap_has "b'auto-checkpoint'"                 # paused -> nothing typed
    grep -q "paused=True" "$CAGE/ccage-autock.log"
}

@test "CCAGE_AUTOCK_INIT_PROMPT kicks off the task unattended" {
    # Below the soft line so no nudge fires; the only injected keystrokes are the
    # autonomous kickoff prompt. Without this an unattended session idles forever.
    STUB="$BATS_TEST_TMPDIR/fakeclaude.py"
    CAP="$BATS_TEST_TMPDIR/capture.bin"
    make_fake_claude "$STUB"
    : > "$CAP"
    run bash -c "cd '$REPO' && \
        CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1 \
        CCAGE_AUTOCK_EXEC='python3 \"$STUB\"' \
        FAKE_SDIR='$SDIR' FAKE_CAPTURE='$CAP' FAKE_MODE=idle \
        FAKE_TOKENS=50000 FAKE_EXIT_ON=KICKOFF_MARKER \
        CCAGE_AUTOCK_INIT_PROMPT='KICKOFF_MARKER' CCAGE_AUTOCK_INIT_DELAY=1 \
        '$AUTO' --soft 90 --poll 1 </dev/null"
    [ "$status" -eq 0 ]
    cap_has "b'KICKOFF_MARKER'"                    # task prompt was typed in
    ! grep -q "soft threshold hit" "$CAGE/ccage-autock.log" 2>/dev/null
}

@test "status: launch command includes --no-chrome by default" {
    run bash -c "cd '$REPO' && '$AUTO' --status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-chrome"* ]]
}

@test "status: CCAGE_AUTOCK_CHROME=1 keeps chrome (no --no-chrome)" {
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_CHROME=1 '$AUTO' --status"
    [ "$status" -eq 0 ]
    [[ "$output" != *"--no-chrome"* ]]
}

@test "status: CCAGE_AUTOCK_EXEC overrides launch verbatim (no injection)" {
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_EXEC='mycustom \"\$@\"' '$AUTO' --status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mycustom"* ]]
    [[ "$output" != *"--no-chrome"* ]]
}

@test "status: ready marker default is ❯ with 20s ceiling" {
    run bash -c "cd '$REPO' && '$AUTO' --status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready marker"* ]]
    [[ "$output" == *"❯"* ]]
    [[ "$output" == *"20"* ]]
}

@test "status: CCAGE_AUTOCK_READY_MARKER and CCAGE_AUTOCK_INIT_DELAY override" {
    run bash -c "cd '$REPO' && CCAGE_AUTOCK_READY_MARKER='>>' CCAGE_AUTOCK_INIT_DELAY=9 '$AUTO' --status"
    [ "$status" -eq 0 ]
    [[ "$output" == *">>"* ]]
    [[ "$output" == *"9"* ]]
}

# ---- AskUserQuestion guard (autonomous runs) --------------------------------
# The watched launch exports CCAGE_AUTONOMOUS=1 and registers a per-run
# PreToolUse hook via a generated --settings file; the hook blocks
# AskUserQuestion (exit 2) only when the marker is set.

GUARD="$BATS_TEST_DIRNAME/../share/hooks/autonomous_ask_guard.sh"

@test "ask-guard: blocks (exit 2) with batching guidance when CCAGE_AUTONOMOUS=1" {
    run -2 bash -c "echo '{}' | CCAGE_AUTONOMOUS=1 bash '$GUARD'"
    [[ "$output" == *"AskUserQuestion must"* ]]
    [[ "$output" == *"ask them in prose instead"* ]]
    [[ "$output" == *"### Decisions"* ]]
    [[ "$output" == *"reversible default"* ]]
}

@test "ask-guard: inert (exit 0, silent) without the autonomous marker" {
    run bash -c "echo '{}' | env -u CCAGE_AUTONOMOUS bash '$GUARD'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "unit: write_guard_settings emits the AskUserQuestion matcher + a real hook path" {
    run python3 - "$AUTO" "$SDIR" <<'PY'
import importlib.util, importlib.machinery, json, os, sys
loader = importlib.machinery.SourceFileLoader("ccageauto", sys.argv[1])
spec = importlib.util.spec_from_loader("ccageauto", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
p = m.write_guard_settings(sys.argv[2])
assert p and os.path.isfile(p), p
assert os.path.dirname(p) == sys.argv[2], p
entry = json.load(open(p))["hooks"]["PreToolUse"][0]
assert entry["matcher"] == "AskUserQuestion", entry
cmd = entry["hooks"][0]["command"]
assert cmd.startswith("bash "), cmd
hook = cmd[5:].strip().strip("'")
assert hook.endswith("autonomous_ask_guard.sh") and os.path.isfile(hook), hook
print("OK")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "e2e: watched launch exports CCAGE_AUTONOMOUS=1 and registers the ask-guard" {
    drive hard "--soft 10 --hard 20 --poll 1"
    [ "$status" -eq 0 ]
    cap_has "b'ENV_CCAGE_AUTONOMOUS=1'"
    [ -f "$SDIR/autonomous-settings.json" ]
    grep -q '"matcher": "AskUserQuestion"' "$SDIR/autonomous-settings.json"
    grep -q 'autonomous_ask_guard.sh' "$SDIR/autonomous-settings.json"
}

@test "e2e: CCAGE_AUTOCK_NO_ASK_GUARD=1 skips registration but still marks the run" {
    CCAGE_AUTOCK_NO_ASK_GUARD=1 drive hard "--soft 10 --hard 20 --poll 1"
    [ "$status" -eq 0 ]
    [ ! -f "$SDIR/autonomous-settings.json" ]
    cap_has "b'ENV_CCAGE_AUTONOMOUS=1'"
}

# ---- Circuit-breaker live-fire (Task 17: scripted) --------------------------
# Drives the REAL ccage-auto process with a fake claude that (a) renders the
# ready-marker, (b) keeps the parent transcript at low occupancy AND marks it a
# teams session (a teammate-message), and (c) plants a stuck teammate transcript.
# The SubagentWatcher thread must then inject a Tier-A nudge over the real pty —
# the one seam the pure run_tick unit tests can't reach (run_proxy wiring the
# master_fd / write_lock / ready_event / pid into the watcher, the thread, and a
# real pty write). Context thresholds are pinned high so the ONLY injection is
# the breaker's.

make_cb_fake_claude() {
    cat > "$1" <<'PY'
import json, os, select, sys, time
from datetime import datetime, timezone

sdir = os.environ["FAKE_SDIR"]
parent = os.path.join(sdir, "sess.jsonl")
# Real layout: subagents/ nests under the session-id dir (the active parent
# transcript's own stem, "sess" here) -- not directly under sdir.
subs = os.path.join(sdir, "sess", "subagents")
os.makedirs(subs, exist_ok=True)
now = time.time()

def write_parent():
    # Low occupancy (context watcher stays idle) + a teammate-message so the CB
    # sees a teams session. Re-written each loop so its mtime stays newer than the
    # watcher's start_time (active_jsonl's `since` filter).
    low = 20000; half = low // 2
    turn = {"type": "assistant", "message": {
        "model": "claude-opus-4-8",
        "usage": {"input_tokens": half, "cache_read_input_tokens": low - half,
                  "cache_creation_input_tokens": 0},
        "content": [{"type": "text", "text": "orchestrating"}]}}
    tm = {"type": "user", "message": {"role": "user",
          "content": '<teammate-message teammate_id="cb-stuck">status?</teammate-message>'}}
    with open(parent, "a") as f:
        f.write(json.dumps(turn) + "\n")
        f.write(json.dumps(tm) + "\n")

write_parent()

# One stuck teammate: first line 10 min old (elapsed), transcript quiet 10 min
# (staleness) — breaches CCB_T_SOFT_MIN/CCB_T_STALE_MIN=1. Never touched again.
stuck = os.path.join(subs, "agent-cb-stuck.jsonl")
old_iso = datetime.fromtimestamp(now - 600, timezone.utc).isoformat()
with open(stuck, "w") as f:
    f.write(json.dumps({"type": "assistant", "timestamp": old_iso}) + "\n")
with open(os.path.join(subs, "agent-cb-stuck.meta.json"), "w") as f:
    f.write(json.dumps({"name": "cb-stuck", "teamName": "session-fake1234",
                        "taskKind": "in_process_teammate"}))
os.utime(stuck, (now - 600, now - 600))

# Render the TUI ready-marker so the watcher's tui_ready gate opens (a real TUI
# prints it; the CB injector refuses to type before it does).
sys.stdout.write("❯ ")
sys.stdout.flush()

cap = open(os.environ["FAKE_CAPTURE"], "ab", buffering=0)
buf = b""
deadline = time.time() + float(os.environ.get("FAKE_DEADLINE", "30"))
while time.time() < deadline:
    r, _, _ = select.select([0], [], [], 0.3)
    if 0 in r:
        try:
            d = os.read(0, 65536)
        except OSError:
            break
        if not d:
            break
        cap.write(d); buf += d
    if b"ccage circuit-breaker" in buf:      # the Tier-A nudge landed
        time.sleep(0.3)
        break
    write_parent()                            # keep the parent transcript live
sys.exit(0)
PY
}

@test "cb live-fire: a stuck teammate gets a Tier-A nudge injected over the real pty" {
    STUB="$BATS_TEST_TMPDIR/cbfake.py"
    CAP="$BATS_TEST_TMPDIR/cbcapture.bin"
    LEDGER="$BATS_TEST_TMPDIR/ccb-ledger.jsonl"
    make_cb_fake_claude "$STUB"
    : > "$CAP"
    run bash -c "cd '$REPO' && \
        CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1 \
        CCAGE_AUTOCK_EXEC='python3 \"$STUB\"' \
        FAKE_SDIR='$SDIR' FAKE_CAPTURE='$CAP' FAKE_DEADLINE=25 \
        CCB_MAX_TIER=nudge CCB_T_SOFT_MIN=1 CCB_T_STALE_MIN=1 \
        CCB_LEDGER='$LEDGER' \
        '$AUTO' --soft 90 --hard 95 --poll 1 </dev/null"
    [ "$status" -eq 0 ]
    # The breaker's nudge bytes reached the child's pty, carrying the vouch grammar.
    cap_has "b'ccage circuit-breaker'"
    cap_has "b'CCB-VOUCH agent=cb-stuck'"
    ! cap_has "b'auto-checkpoint'"                       # context watcher stayed idle
    grep -q "\[ccb\] injected nudge" "$CAGE/ccage-autock.log"
    # Ledger telemetry: the alert + nudge for this teammate are recorded.
    grep -q '"event": "nudge"' "$LEDGER"
    grep -q '"teammate_id": "cb-stuck"' "$LEDGER"
}

@test "cb live-fire: observe tier alerts but never injects a nudge" {
    STUB="$BATS_TEST_TMPDIR/cbfake.py"
    CAP="$BATS_TEST_TMPDIR/cbcapture.bin"
    LEDGER="$BATS_TEST_TMPDIR/ccb-ledger.jsonl"
    make_cb_fake_claude "$STUB"
    : > "$CAP"
    run bash -c "cd '$REPO' && \
        CCAGE_AUTOCK_NO_BYPASS_ACCEPT=1 \
        CCAGE_AUTOCK_EXEC='python3 \"$STUB\"' \
        FAKE_SDIR='$SDIR' FAKE_CAPTURE='$CAP' FAKE_DEADLINE=8 \
        CCB_MAX_TIER=observe CCB_T_SOFT_MIN=1 CCB_T_STALE_MIN=1 \
        CCB_LEDGER='$LEDGER' \
        '$AUTO' --soft 90 --hard 95 --poll 1 </dev/null"
    [ "$status" -eq 0 ]
    ! cap_has "b'ccage circuit-breaker'"                 # observe = alert-only, no pty write
    grep -q '"event": "alert"' "$LEDGER"                 # but the alert IS recorded
    ! grep -q '"event": "nudge"' "$LEDGER"
}

# ---- Weekly-limit floor (--status) ------------------------------------------
# See docs/WEEKLY-LIMIT-GUARD.md and tests/test_weekly_floor.py (the Watcher
# state-machine unit tests). These cover only what --status surfaces.

@test "--status shows 'weekly floor : off' by default" {
    write_transcript 100000
    run status
    [[ "$output" == *"weekly floor : off"* ]]
}

@test "CCAGE_AUTOCK_WEEKLY_FLOOR env arms the weekly floor" {
    write_transcript 100000
    CCAGE_AUTOCK_WEEKLY_FLOOR=20 run status
    [[ "$output" == *"weekly floor : 20% remaining (armed)"* ]]
}

@test "--weekly-floor flag arms the weekly floor" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --weekly-floor 20 --status"
    [[ "$output" == *"weekly floor : 20% remaining (armed)"* ]]
}

@test "out-of-range weekly floor is disabled with a warning" {
    write_transcript 100000
    run bash -c "cd '$REPO' && '$AUTO' --weekly-floor 150 --status 2>&1"
    [[ "$output" == *"weekly floor 150 out of range (0,100); disabling"* ]]
    [[ "$output" == *"weekly floor : off"* ]]
}

@test "--status reads the rate-limits sensor state and shows remaining percent" {
    write_transcript 100000
    printf '{"seven_day":{"used_percentage":81.5},"ts":%d}\n' "$(date +%s)" \
        > "$CAGE/rate-limits-state.json"
    run bash -c "cd '$REPO' && '$AUTO' --weekly-floor 20 --status"
    [[ "$output" == *"18.5% remaining"* ]]
}
