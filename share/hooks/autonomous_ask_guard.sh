#!/usr/bin/env bash
# PreToolUse guard — blocks AskUserQuestion during autonomous runs.
#
# Registered per-run by `ccage-auto`, which generates a small settings file and
# passes it to the launched session via `claude --settings <file>` (verified:
# hooks registered through --settings fire, and PreToolUse exit 2 blocks the
# call with stderr fed back to the model). Nothing is ever seeded into a cage's
# settings.json for this — the registration lives and dies with the run.
#
# Armed by the CCAGE_AUTONOMOUS=1 marker `ccage-auto` exports into the launched
# session, so even if the generated settings file is ever reused outside an
# autonomous run, the guard stays inert and the tool works normally.
#
# Exit codes: 0 = allow the tool call; 2 = block it (stderr becomes model
# guidance). Portable: bash 3.2, no jq/timeout (macOS-safe).

# Drain the hook payload so the harness's stdin write completes cleanly; the
# guard's decision doesn't depend on its content.
cat > /dev/null 2>&1 || true

case "${CCAGE_AUTONOMOUS:-}" in
    1|true|yes)
        cat >&2 <<'MSG'
Autonomous run: AskUserQuestion is disabled — the user is away, and a blocking
question stalls the entire run. Instead:
1. Check the ratified plan/design doc first (grep it by keyword) — it usually
   already decides this question.
2. Otherwise take the reversible default and log the decision + rationale in
   RESUME.md under '### Decisions' for the user to review later.
3. Batch genuinely user-only questions and present them at the END of the run,
   after completing all work that does not depend on the answers.
Halt mid-run only for irreversible / destructive / outward-facing actions.
MSG
        exit 2
        ;;
esac
exit 0
