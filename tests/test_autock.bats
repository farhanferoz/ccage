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
    unset CCAGE_SLOT CCAGE_AUTOCK CCAGE_AUTOCK_WINDOW
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

@test "default thresholds are 35%% soft / 55%% hard" {
    write_transcript 100000
    run status
    [[ "$output" == *"soft / hard  : 35% / 55%"* ]]
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
    [[ "$output" == *"soft / hard  : 35% / 55%"* ]]
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
buf = b""
confirmed = False
deadline = time.time() + 30
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
