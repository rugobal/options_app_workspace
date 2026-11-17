#!/usr/bin/env bash
# Run one headless Antigravity CLI (agy) worker on a Google Gemini model.
#
#   antigravity-worker.sh --brief <file> --cwd <checkout> [--effort low|medium|high|xhigh|max]
#                         [--model <id>] [--resume <conversation-id>]
#                         [--timeout <duration>] [--memory-max <size>]
#
# Prints agy's JSON result on stdout (conversation_id, status, response,
# error, usage); redirect it to the run's out/<task>-<attempt>.json and stderr
# to a separate file. The first stderr line names the worker's systemd scope.
#
# Model: --model, else $ANTIGRAVITY_WORKER_MODEL, default gemini-4-argon (frontier);
# gemini-3.8-flash suits small and mid tasks. `agy models` lists the ids; each
# model offers only some efforts (Argon: low, medium, high). Default effort: high.
# Timeout: agy's print-mode limit, default 3h, so a stuck turn ends.
#
# Cleanup: agy and everything it starts run in a transient systemd user scope.
# When agy exits, or the wrapper gets INT, TERM or HUP, the scope is stopped,
# which ends every leftover process, including ones the worker detached with
# setsid or nohup. If the wrapper itself is killed with SIGKILL, stop the scope
# by the name on the first stderr line: systemctl --user stop <unit>.scope
# Docker containers belong to dockerd, not to the scope; tests must remove their own.
set -uo pipefail

brief="" cwd="" effort="high" model="${ANTIGRAVITY_WORKER_MODEL:-gemini-4-argon}"
resume="" timeout="3h" memory_max=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) brief="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    --effort) effort="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --memory-max) memory_max="$2"; shift 2 ;;
    *) echo "antigravity-worker: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -f "$brief" ] || { echo "antigravity-worker: --brief file missing: $brief" >&2; exit 64; }
[ -d "$cwd" ] || { echo "antigravity-worker: --cwd is not a directory: $cwd" >&2; exit 64; }
case "$effort" in low|medium|high|xhigh|max) ;; *) echo "antigravity-worker: --effort must be low, medium, high, xhigh or max" >&2; exit 64 ;; esac
command -v agy > /dev/null || { echo "antigravity-worker: agy (Antigravity CLI) not on PATH" >&2; exit 65; }
command -v systemd-run > /dev/null || { echo "antigravity-worker: systemd-run missing; cleanup needs a systemd user session" >&2; exit 65; }

cwd="$(cd "$cwd" && pwd -P)"

# agy works in its own scratch folder, silently, when the current folder is
# outside its trusted workspaces. Refuse instead.
if ! python3 - "$cwd" <<'EOF'
import json, os, sys
cwd = sys.argv[1]
path = os.path.expanduser('~/.gemini/antigravity-cli/settings.json')
try:
    trusted = json.load(open(path)).get('trustedWorkspaces') or []
except (OSError, ValueError):
    trusted = []
roots = [os.path.realpath(os.path.expanduser(t)) for t in trusted]
sys.exit(0 if any(cwd == r or cwd.startswith(r.rstrip('/') + '/') for r in roots) else 1)
EOF
then
  echo "antigravity-worker: $cwd is outside agy's trusted workspaces (~/.gemini/antigravity-cli/settings.json); agy would work in its scratch folder instead" >&2
  exit 65
fi

# The brief goes in as the prompt argument: agy's print mode takes no prompt on stdin.
prompt="$(cat "$brief")"
[ "${#prompt}" -lt 120000 ] || { echo "antigravity-worker: brief over 120000 characters; shorten it or point to files" >&2; exit 64; }

args=(--output-format json --model "$model" --effort "$effort"
      --dangerously-skip-permissions --disable-slash-commands
      --print-timeout "$timeout")
[ -n "$resume" ] && args+=(--conversation "$resume")
args+=(-p "$prompt")

name="$(basename "$cwd")"
name="${name//[^A-Za-z0-9_.-]/-}"
unit="antigravity-worker-${name:0:40}-$$"
echo "antigravity-worker: scope $unit.scope" >&2

stop_scope() {
  if systemctl --user is-active --quiet "$unit.scope" 2> /dev/null; then
    local left
    left="$(systemctl --user show -p TasksCurrent --value "$unit.scope" 2> /dev/null)"
    systemctl --user stop "$unit.scope" 2> /dev/null
    echo "antigravity-worker: stopped $unit.scope (${left:-?} leftover tasks)" >&2
  fi
}
trap 'stop_scope; exit 130' INT
trap 'stop_scope; exit 143' TERM HUP

scope_props=(-p TimeoutStopSec=15s)
[ -n "$memory_max" ] && scope_props+=(-p "MemoryMax=$memory_max")

cd "$cwd"
systemd-run --user --scope --quiet --collect --unit "$unit" "${scope_props[@]}" \
  agy "${args[@]}" < /dev/null &
wait $!
status=$?

stop_scope
if systemctl --user is-active --quiet "$unit.scope" 2> /dev/null; then
  echo "antigravity-worker: $unit.scope still active after stop" >&2
  exit 70
fi
exit "$status"
