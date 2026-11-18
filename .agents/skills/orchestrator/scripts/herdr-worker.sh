#!/usr/bin/env bash
# Orchestrator workers in Herdr: one labelled tab per worker, in one workspace per run.
#
#   herdr-worker.sh launch --run DIR --id ID --label TEXT --cwd DIR --harness claude|codex|deepseek|agy|plain
#                          --cmd-file FILE [--workspace-label TEXT]
#   herdr-worker.sh start  --run DIR --id ID --label TEXT --cwd DIR --kind claude|codex|pi|agy --args-file FILE
#                          --report FILE [--env KEY=VALUE]... [--timeout MS] [--workspace-label TEXT]
#   herdr-worker.sh ready  --run DIR --id ID [--timeout MS]
#   herdr-worker.sh keys   --run DIR --id ID --keys "KEY [KEY]..."
#   herdr-worker.sh prompt --run DIR --id ID --text-file FILE [--timeout MS]
#   herdr-worker.sh mcp    --run DIR --id ID [--timeout MS]
#   herdr-worker.sh wait   --run DIR --id ID [--timeout MS]
#   herdr-worker.sh status --run DIR [--id ID]
#   herdr-worker.sh state  --run DIR --id ID --state working|blocked|idle [--message TEXT]
#   herdr-worker.sh close  --run DIR (--id ID | --all)
#
# launch (mode A) runs the command line in --cmd-file headless, in its own session and process group
#   (setsid), with HERDR_ENV and HERDR_PANE_ID unset, so Herdr's agent detection leaves the pane to this
#   script's report. stdout goes to out/<id>.log; stderr to out/<id>.err, or into the log for codex and
#   plain. The pane's runner out/<id>.sh shows the log (claude and deepseek through stream.jq) and starts
#   the worker's supervisor out/<id>.sup.sh in a session of its own, since Herdr kills what runs in the
#   pane moments after the pane closes. The supervisor reaps the worker, clears what is left of its
#   process group, then writes the exit record out/<id>.exit: that record, not any line of output, says
#   the worker ended. A closed pane, Ctrl+C or TERM in the pane stops the whole group: TERM, then KILL
#   after 5 s.
# start (mode B) starts an interactive agent with `herdr agent start`. It is ready for its first prompt
#   when start (or a later ready) exits 0. Each prompt is one turn; the turn is done when the agent has
#   settled and the --report file was written during that turn; start creates the report's folder. An
#   args file holds one argument per line, passed as is: each line is exactly the characters the agent
#   receives (no shell quoting or expansion; quotes stay); empty lines are skipped.
#   prompt's JSON says whether the text was delivered: a prompt refused at a dialog, or at a screen
#   that is not ready for it, opens no turn, and wait refuses until a prompt is delivered (ready, then
#   the same prompt again).
#   Codex: only its empty composer, with focus and no popup, takes a prompt; codex_screen reads that
#   from the bottom of the screen, read anew just before sending. Herdr shows Codex's hooks review as
#   idle, so the screen decides: a Codex dialog there is 5, anything else that is not the empty
#   composer (a draft, the history search, a menu, a pane too narrow for the footer hints, a failed
#   read) is 3, and nothing is sent. After a dialog Codex shows idle, then working while it finishes
#   starting, so start and ready count the composer once Herdr has shown no work for 3 s and a fresh
#   read still finds it. They count a dialog once a read a full second later, with no other read
#   between, still shows it (a read right after keys can still show the dialog they answered); that
#   read is the result's screen. Mode B Codex runs no
#   companion, so close gives no codex_cleanup for it. Session id: Herdr's (the agent's own hook in
#   its pane); without it, at the end of a turn, the id of the checkout's only Codex rollout written
#   since the agent started (to the millisecond); two such rollouts leave it null with
#   session_ambiguous true.
#   Time: --timeout is the call's whole time; for start it runs from `herdr agent start`, after the tab
#   and its shell prompt (up to 10 s more). Each confirmation must fit in what is left, with 250 ms for
#   its last read: the composer's 3 s of no work, a dialog's 1 s, and the 3 s allowed for a blocked
#   state to change (start, ready, prompt, wait). One that can't fit ends the call with 3 at once. So
#   ready on Codex needs --timeout 3500 or more to return 0 (1500 to confirm a dialog), and start needs
#   Codex's own start-up time on top.
# mcp (mode B Codex) sends `/mcp verbose` under prompt's last-moment check (only Codex's empty composer
#   takes it; a dialog is 5, anything else 3, nothing sent), then reads the list Codex prints into its
#   transcript: no turn opens, the composer is empty again, and the lifecycle state never changes. 0:
#   {id, agent_name, state, servers: [{name, status, tools, tool_names}], connected: {NAME: [TOOL...]}},
#   tool_names for connected servers only; connected maps each connected server to its tool names. 1
#   mcp_unreadable (error.detail: reason, screen): no new, complete list above an empty composer in time
#   (default 15000 ms): no heading, a list clipped at the top, rows it can't read, a tool count that
#   doesn't match the names, or a screen unchanged since the call began (a second mcp on a screen that
#   shows only repeats of one list can't tell its list from the last; it fails, never reads the old one).
#   64 agent_working or turn_open while a turn runs; 4 gone, with no change recorded.
# keys sends keys (Herdr key names) to a mode B agent's pane, to answer a dialog.
# wait blocks until the worker's outcome is known. Mode A: the exit record. Mode B: the delivered turn
#   settles. It never stops a worker, except a mode A worker whose pane and supervisor are both gone.
# close marks the worker closing, closes its pane and stops the worker, and only once both are
#   verified marks it closed; a close that failed or was cut short leaves closing, and runs again.
#   Mode A: its verified process group (TERM, KILL after 5 s). Mode B: through Herdr only, never by
#   signal: ctrl+c to the agent by name, then the pane close ends what runs in the pane; a pane no
#   longer hosting the agent is closed and nothing is signalled. A pane the user split off in the same
#   tab stays. Herdr removes a tab with its last pane and a workspace with its last tab; this script
#   never closes a tab or a workspace itself.
#
# Ownership. The registry <run>/workers.json records the canonical run path; a registry whose path is
# not --run is refused. A stored pane is the worker's only while Herdr shows it with the recorded
# terminal_id in the recorded workspace, and a mode B pane only while it hosts the recorded agent; a
# process group is the worker's only while its leader has the recorded start time, checked again
# before every delayed signal. Agent names carry the run: <run slug>-<4 hex of the run path>-<id>-<harness>,
# at most 32 characters.
#
# Lifecycle (the registry's state). Mode A: starting, running, then finished (exit record, no stop
# signal), stopped (exit record after a closed pane, Ctrl+C or TERM) or lost (the supervisor died
# without a record). Mode B: starting, ready, working, reported (this turn's report is in), settled (the turn
# ended without it), blocked (a dialog), gone. Then closing, then closed. closed is final; closing,
# finished, stopped, lost and gone change only to closing or closed. `state` sets the mark Herdr shows
# (registry: shown), not the lifecycle.
#
# Known limits (one developer's tool on one machine; no service manager, no cgroups):
# - A supervisor killed by hand, then its pane closed while no wait runs: the worker runs on until the
#   next wait or close on it stops its group (status shows it running, supervisor_alive false,
#   pane_present false). Its group is the pgid in out/<id>.started.
# - Herdr doesn't reuse closed pane ids, so a stored pane is trusted once it exists with its terminal.
# - An exit record that can't be written (a full disk) makes a finished worker lost; its log still
#   holds the result. A worker that exits in the same instant its pane closes may be recorded stopped.
# - One conductor prompts a mode B agent at a time; concurrent prompt calls for one worker aren't supported.
#
# Every call prints exactly one JSON object on stdout; "ok" is true exactly when the exit status is 0.
# Exit status:
#   0  done. wait: the worker finished (mode A: its own status is exit_code; mode B: the turn's report).
#   1  Herdr or internal error (error.detail holds Herdr's error), close could not stop a worker, or
#      mcp could not read a new, complete list (mcp_unreadable).
#   2  not inside Herdr (HERDR_ENV is not 1) or a tool missing: dispatch with background Bash instead.
#   3  timeout, nothing changed; start/ready: not ready within the time, or no time left to confirm
#      what it shows (a dialog seen once); prompt with delivered false, or mcp: nothing sent, the
#      agent's input is not ready for it (the screen in the JSON).
#   4  gone or stopped: the pane or agent is gone, the mode A worker was stopped by a signal, or the
#      worker is closing.
#   5  mode B agent at a dialog: the JSON holds the visible screen.
#   6  mode B agent settled without writing this turn's report.
#   7  mode A worker lost: its supervisor died without an exit record; the exit code is unknown.
#   64 usage error, unknown or duplicate id, closed worker, a wait after an undelivered prompt, or a
#      registry from another run.
set -Eeuo pipefail

if [ "${HERDR_ENV:-}" != 1 ]; then
  printf '%s\n' '{"ok":false,"error":{"code":"not_in_herdr","message":"HERDR_ENV is not 1: dispatch with background Bash instead"}}'
  exit 2
fi
for tool in jq herdr flock setsid pgrep sha1sum; do
  command -v "$tool" > /dev/null || {
    printf '{"ok":false,"error":{"code":"missing_tool","message":"%s is not on PATH"}}\n' "$tool"
    exit 2
  }
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
HERDR_BIN=$(command -v herdr)
SOURCE=custom:orchestrator
MARK=WORKER_DONE_
GRACE=5   # seconds between TERM and KILL

# ---- output and errors
#
# A call ends in emit (its result) or fail (its error). fail inside a command substitution writes its
# object to FAILF and leaves only that subshell; the main shell then reports that first error, so a
# subshell's error is never lost and never printed twice.

MAINPID=$BASHPID
FAILF="" EMITTED=0 HCALL_EF=""
CLEANUP_PANE=""   # a pane this call created and has not handed over yet: closed on failure
CREATING=0        # a create call is under way: on failure, its pane is read from HOUT
CLEANUP_PGID="" CLEANUP_LSTART=""

on_exit() {
  [ "$EMITTED" = 1 ] || printf '%s\n' '{"ok":false,"error":{"code":"internal","message":"exited without a result"}}'
  [ -z "$FAILF" ] || rm -f "$FAILF"
  [ -z "$HCALL_EF" ] || rm -f "$HCALL_EF"   # a Herdr call cut short by a signal
}
trap on_exit EXIT
FAILF=$(mktemp "${TMPDIR:-/tmp}/herdr-worker.XXXXXX" 2> /dev/null) || {
  jq -cn --arg d "${TMPDIR:-/tmp}" '{ok: false, error: {code: "tmp_unwritable", message: ("cannot create a temp file in " + $d)}}' &&
    EMITTED=1
  exit 1
}

error_json() {  # error_json CODE MESSAGE [DETAIL_JSON]
  jq -cn --arg c "$1" --arg m "$2" --argjson d "${3:-null}" \
    '{ok: false, error: ({code: $c, message: $m} + (if $d == null then {} else {detail: $d} end))}' 2> /dev/null ||
    jq -cn --arg c "$1" --arg m "$2" '{ok: false, error: {code: $c, message: $m}}'
}

fail() {  # fail EXIT CODE MESSAGE [DETAIL_JSON]
  trap - ERR
  set +e
  local st=$1 json
  json=$(error_json "$2" "$3" "${4:-null}")
  if [ "$BASHPID" != "$MAINPID" ]; then
    [ -s "$FAILF" ] || printf '%s %s\n' "$st" "$json" > "$FAILF"
    exit "$st"
  fi
  [ ! -s "$FAILF" ] || read -r st json < "$FAILF"
  ! declare -F cleanup_after_failure > /dev/null || cleanup_after_failure "$(jq -r '.error.message' <<< "$json")"
  EMITTED=1
  printf '%s\n' "$json"
  exit "$st"
}

trap 'fail 1 internal "line $LINENO: $BASH_COMMAND exited $?"' ERR
trap 'fail 1 interrupted "stopped by SIGINT"' INT
trap 'fail 1 interrupted "stopped by SIGTERM"' TERM
trap 'fail 1 interrupted "stopped by SIGHUP"' HUP

emit() {  # emit EXIT OBJECT: print the call's result, with ok set from EXIT, and exit
  local st=$1 json
  [ ! -s "$FAILF" ] || fail 1 internal "an earlier step failed"
  json=$(jq -c --argjson ok "$([ "$st" = 0 ] && echo true || echo false)" '{ok: $ok} + del(.ok)' <<< "$2") ||
    fail 1 internal "result object is not JSON"
  CLEANUP_PANE=""
  EMITTED=1
  printf '%s\n' "$json"
  exit "$st"
}

as_json() { jq -c . <<< "$1" 2> /dev/null || jq -cn --arg t "$1" '$t'; }
now() { date -Iseconds; }
now_ms() { date +%s%3N; }
nap() {  # nap MS DEADLINE_MS: sleep MS, but never past the deadline
  local ms=$1 left=$(($2 - $(now_ms)))
  ((ms <= left)) || ms=$((left > 0 ? left : 0))
  sleep "$((ms / 1000)).$(printf '%03d' $((ms % 1000)))"
}

# ---- Herdr calls

HOUT="" HERR=""
hcall() {  # hcall ARGS...: herdr ARGS; stdout in HOUT, or stderr in HERR and status 1
  local ef
  ef=$(mktemp "${TMPDIR:-/tmp}/herdr-worker.XXXXXX")
  HCALL_EF=$ef
  if HOUT=$("$HERDR_BIN" "$@" 2> "$ef"); then
    HERR=""
    rm -f "$ef"; HCALL_EF=""
    return 0
  fi
  HERR=$(< "$ef")
  rm -f "$ef"; HCALL_EF=""
  [ -n "$HERR" ] || HERR="{\"error\":{\"code\":\"no_output\",\"message\":\"herdr $1 $2 failed\"}}"
  return 1
}
herr_code() { jq -r '.error.code // empty' <<< "$HERR" 2> /dev/null || true; }
herdr_fail() { fail 1 herdr_error "herdr $1 $2 failed" "$(as_json "$HERR")"; }
h() { hcall "$@" || herdr_fail "$@"; }
hlook() {  # hlook ARGS...: 0 when Herdr has the object, 1 when it says not found; any other error fails
  hcall "$@" && return 0
  case $(herr_code) in
    workspace_not_found|tab_not_found|pane_not_found|agent_not_found) return 1 ;;
  esac
  herdr_fail "$@"
}

# ---- arguments

SUB=${1:-}
[ $# -gt 0 ] && shift
RUN="" ID="" LABEL="" CWD="" HARNESS="" CMD_FILE="" KIND="" ARGS_FILE="" REPORT="" TEXT_FILE=""
TIMEOUT="" STATE="" MESSAGE="" WS_LABEL="" KEYS="" ALL=0
ENVS=()
while [ $# -gt 0 ]; do
  case $1 in
    --all) ALL=1; shift; continue ;;
    --run|--id|--label|--cwd|--harness|--cmd-file|--kind|--args-file|--report|--text-file|--timeout|--state|--message|--workspace-label|--env|--keys)
      [ $# -ge 2 ] || fail 64 usage "$1 needs a value" ;;
    *) fail 64 usage "unknown argument: $1" ;;
  esac
  case $1 in
    --run) RUN=$2 ;;
    --id) ID=$2 ;;
    --label) LABEL=$2 ;;
    --cwd) CWD=$2 ;;
    --harness) HARNESS=$2 ;;
    --cmd-file) CMD_FILE=$2 ;;
    --kind) KIND=$2 ;;
    --args-file) ARGS_FILE=$2 ;;
    --report) REPORT=$2 ;;
    --text-file) TEXT_FILE=$2 ;;
    --timeout) TIMEOUT=$2 ;;
    --state) STATE=$2 ;;
    --message) MESSAGE=$2 ;;
    --workspace-label) WS_LABEL=$2 ;;
    --env) ENVS+=("$2") ;;
    --keys) KEYS=$2 ;;
  esac
  shift 2
done

require() {  # require --flag VALUE ...
  while [ $# -gt 0 ]; do
    [ -n "$2" ] || fail 64 usage "$SUB needs $1"
    shift 2
  done
}
abs() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

T=0
parse_timeout() {  # parse_timeout DEFAULT_MS: T from --timeout, decimal milliseconds from 100 to 86400000
  local v=${TIMEOUT:-$1}
  [[ $v =~ ^[0-9]{1,9}$ ]] || fail 64 usage "--timeout takes decimal milliseconds"
  T=$((10#$v))
  ((T >= 100 && T <= 86400000)) || fail 64 usage "--timeout must be 100 to 86400000 ms"
}

check_id() {
  [[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || fail 64 usage "--id takes letters, digits, - and _ (e.g. T41-1)"
}

# ---- run and registry: <run>/workers.json, rewritten whole (temp file, check, rename) under a flock

run_slug() {  # the run folder's name without its date, whole words up to 8 characters
  local base slug="" part parts
  base=$(basename "$RUN" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-?//')
  IFS=- read -ra parts <<< "${base:-run}"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    if [ -z "$slug" ]; then
      slug=${part:0:8}
    elif [ $((${#slug} + 1 + ${#part})) -le 8 ]; then
      slug=$slug-$part
    else
      break
    fi
  done
  printf '%s' "${slug:-run}"
}

setup_run() {
  [ -d "$RUN" ] || fail 64 usage "--run is not a directory: $RUN"
  RUN=$(cd "$RUN" && pwd -P)
  REG=$RUN/workers.json LOCK=$RUN/workers.lock OUT=$RUN/out
  SLUG=$(run_slug)
  RUNTAG=$(printf '%s' "$RUN" | sha1sum | cut -c1-4)
  [ -s "$REG" ] || return 0
  local owner
  owner=$(jq -r 'if type == "object" and (.workers | type) == "array" then (.run // "") else error("not a registry") end' "$REG" 2> /dev/null) ||
    fail 1 corrupt_registry "$REG is not a worker registry"
  [ "$owner" = "$RUN" ] ||
    fail 64 foreign_registry "$REG was written for run $owner, not $RUN: a copied registry is refused"
}

LOCKED=0
lock() {
  [ "$LOCKED" = 1 ] && return 0
  exec 9>> "$LOCK"
  flock -w 60 9 || fail 1 lock_timeout "$LOCK stayed locked for 60 s"
  LOCKED=1
}
unlock() {
  [ "$LOCKED" = 1 ] || return 0
  exec 9>&-
  LOCKED=0
}
reg_read() {
  if [ -s "$REG" ]; then cat "$REG"; else jq -cn --arg r "$RUN" '{run: $r, workspace: null, workers: []}'; fi
}
reg_try() {  # reg_try [jq options...] FILTER: rewrite the registry; status 1, file unchanged, on any failure
  local held=$LOCKED tmp=$REG.tmp.$BASHPID st=1
  if [ "$held" = 1 ] || { exec 9>> "$LOCK" && flock -w 60 9 && LOCKED=1; }; then
    if reg_read | jq "$@" > "$tmp" 2> /dev/null &&
      jq -e --arg r "$RUN" 'type == "object" and (.workers | type) == "array" and .run == $r' "$tmp" > /dev/null 2>&1 &&
      mv -f "$tmp" "$REG"; then
      st=0
    fi
    rm -f "$tmp"
    [ "$held" = 1 ] || unlock
  fi
  return "$st"
}
reg_apply() { reg_try "$@" || fail 1 registry_write "could not rewrite $REG; it is unchanged"; }

W=""   # the current worker's registry entry
load_worker() {
  W=$(reg_read | jq -c --arg id "$ID" '.workers[] | select(.id == $id)')
  [ -n "$W" ] || fail 64 unknown_id "no worker $ID in $REG"
}
reload_worker() { W=$(reg_read | jq -c --arg id "$ID" '.workers[] | select(.id == $id)'); }
wf() { jq -r --arg k "$1" '.[$k] // empty | if type == "object" or type == "array" then tojson else . end' <<< "$W"; }
update_worker() {  # update_worker PATCH [jq options...]: merge PATCH (evaluated on the entry) into it
  local patch=$1
  shift
  reg_apply --arg id "$ID" "$@" '(.workers[] | select(.id == $id)) |= (. + ('"$patch"'))'
  reload_worker
}
lifecycle() {  # lifecycle PATCH: the filter moving worker $id to state $new with PATCH, if the lifecycle allows
  printf '%s' '(.workers[] | select(.id == $id)) |=
    (if .state == "closed"
        or (($new | IN("closing", "closed") | not)
            and (.state == "closing" or (.state != $new and (.state | IN("finished", "stopped", "lost", "gone")))))
     then .
     else . + ('"$1"') + {state: $new} end)'
}
transition() {  # transition NEW PATCH [jq options...]: move to state NEW and merge PATCH, if the lifecycle allows
  local new=$1 patch=$2
  shift 2
  reg_apply --arg id "$ID" --arg new "$new" "$@" "$(lifecycle "$patch")"
  reload_worker
}
transition_try() {  # transition_try NEW PATCH [jq options...]: as transition, for failure paths: never fails
  local new=$1 patch=$2
  shift 2
  reg_try --arg id "$ID" --arg new "$new" "$@" "$(lifecycle "$patch")" || true
}
public() { jq -c 'del(.token, .report_snapshot)' <<< "$W"; }

agent_name() {  # agent_name KIND: <run slug>-<run tag>-<id>-<kind>, lower case, at most 32 characters
  local n
  n=$(printf '%s-%s-%s-%s' "$SLUG" "$RUNTAG" "$ID" "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')
  if [ ${#n} -gt 32 ]; then
    n=$(printf '%s-%s-%s-%s' "$SLUG" "$RUNTAG" "$(printf '%s' "$ID" | sha1sum | cut -c1-8)" "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')
  fi
  [[ $n =~ ^[a-z] ]] || n=w$n
  printf '%s' "${n:0:32}"
}

# ---- Herdr objects the registry owns

pane_present() {  # the worker's pane exists with its recorded terminal in its recorded workspace (HOUT: pane get)
  local pane tid ws
  pane=$(wf pane_id) tid=$(wf terminal_id) ws=$(wf workspace_id)
  [ -n "$pane" ] && [ -n "$tid" ] || return 1
  hlook pane get "$pane" || return 1
  jq -e --arg t "$tid" --arg w "$ws" '.result.pane | .terminal_id == $t and .workspace_id == $w' <<< "$HOUT" > /dev/null
}

ws_ours() {  # ws_ours WS: the workspace holds a live pane of one of this run's open workers
  local terms
  hlook pane list --workspace "$1" || return 1
  terms=$(reg_read | jq -c --arg ws "$1" '[.workers[] | select(.workspace_id == $ws and .state != "closed") | .terminal_id]')
  jq -e --argjson t "$terms" '[.result.panes[].terminal_id] as $live | any($t[]; . as $x | $live | index($x) != null)' <<< "$HOUT" > /dev/null
}

open_tab() {  # open_tab CWD ENTRY: a tab for the worker, recorded at once with ENTRY; sets WS TAB PANE. Under the lock.
  local cwd=$1 entry=$2 ws label="" env_args=() e term created_label
  for e in "${ENVS[@]}"; do env_args+=(--env "$e"); done
  ws=$(reg_read | jq -r '.workspace.id // empty')
  CREATING=1
  if [ -n "$ws" ] && ws_ours "$ws"; then
    h tab create --workspace "$ws" --label "$LABEL" --cwd "$cwd" "${env_args[@]}" --no-focus
    WS=$ws
  else
    label=${WS_LABEL:-w-$SLUG}
    h workspace create --label "$label" --cwd "$cwd" "${env_args[@]}" --no-focus
    WS=$(jq -r .result.workspace.workspace_id <<< "$HOUT")
  fi
  PANE=$(jq -r .result.root_pane.pane_id <<< "$HOUT")
  CLEANUP_PANE=$PANE
  CREATING=0
  TAB=$(jq -r .result.tab.tab_id <<< "$HOUT")
  created_label=$(jq -r .result.tab.label <<< "$HOUT")
  term=$(jq -r '.result.root_pane.terminal_id // empty' <<< "$HOUT")
  if [ -z "$term" ]; then
    h pane get "$PANE"
    term=$(jq -r .result.pane.terminal_id <<< "$HOUT")
  fi
  reg_apply --argjson e "$entry" --arg ws "$WS" --arg tab "$TAB" --arg pane "$PANE" --arg term "$term" \
    --arg wl "$label" --arg t "$(now)" '
    (if $wl != "" then .workspace = {id: $ws, label: $wl, created_at: $t} else . end)
    | .workers += [$e + {workspace_id: $ws, tab_id: $tab, pane_id: $pane, terminal_id: $term}]'
  load_worker
  # A new workspace's own first tab becomes this worker's tab.
  [ "$created_label" = "$LABEL" ] || h tab rename "$TAB" "$LABEL"
}

shell_is_foreground() {  # the pane's foreground is its own shell, alone
  hcall pane process-info --pane "$1" &&
    jq -e '.result.process_info | (.foreground_processes | length) == 1
           and .foreground_processes[0].pid == .shell_pid' <<< "$HOUT" > /dev/null
}
wait_shell() {  # wait_shell PANE: the shell at its prompt within 10 s
  local i
  for ((i = 0; i < 40; i++)); do
    if shell_is_foreground "$1"; then return 0; fi
    sleep 0.25
  done
  return 1
}
screen_text() {  # screen_text: the visible screen of the worker's pane (plain text), or ""
  if hcall pane read "$(wf pane_id)" --source visible; then printf '%s\n' "$HOUT"; fi
}

report() {  # report PANE STATE [MESSAGE]: the pane shows STATE under the worker's tab label
  local agent label
  agent=$(wf agent_name) label=$(wf label)
  hcall pane report-agent "$1" --source "$SOURCE" --agent "$agent" --state "$2" ${3:+--message "$3"} &&
    hcall pane report-metadata "$1" --source "$SOURCE" --agent "$agent" --display-agent "$label"
}
report_took() {  # report_took PANE STATE: Herdr shows the worker's agent with STATE (an unseen idle reads "done")
  hcall pane get "$1" &&
    jq -e --arg a "$(wf agent_name)" --arg s "$2" \
      '.result.pane | .agent == $a and (.agent_status == $s or ($s == "idle" and .agent_status == "done"))' \
      <<< "$HOUT" > /dev/null
}

# ---- process groups

proc_field() {  # proc_field PID N: field N of /proc/PID/stat after "pid (comm)" (1 = state, 20 = start time)
  awk -v n="$2" '{ sub(/^.*\) /, ""); print $n }' "/proc/$1/stat" 2> /dev/null || true
}
group_live() {  # group_live PGID: the group's members that have not exited (zombies left out)
  local p
  for p in $(pgrep -g "$1" 2> /dev/null || true); do
    [ "$(proc_field "$p" 1)" = Z ] || printf '%s\n' "$p"
  done
}
group_ours() {  # group_ours PGID LEADER_START: the recorded group still has a member
  local st
  [ -n "$1" ] && [ "$1" != null ] && [ -n "$2" ] || return 1
  st=$(proc_field "$1" 20)
  if [ -n "$st" ] && [ "$st" != "$2" ]; then return 1; fi   # the pid now belongs to another process
  [ -n "$(group_live "$1")" ]
}
STOPPED=""
stop_group() {  # stop_group PGID LEADER_START: STOPPED = not_running, stopped, killed or survived
  local i
  if ! group_ours "$1" "$2"; then STOPPED=not_running; return 0; fi
  kill -TERM -- "-$1" 2> /dev/null || true
  for ((i = 0; i < GRACE * 10; i++)); do
    if ! group_ours "$1" "$2"; then STOPPED=stopped; return 0; fi
    sleep 0.1
  done
  if ! group_ours "$1" "$2"; then STOPPED=stopped; return 0; fi   # checked again just before the delayed KILL
  kill -KILL -- "-$1" 2> /dev/null || true
  for ((i = 0; i < 30; i++)); do
    if ! group_ours "$1" "$2"; then STOPPED=killed; return 0; fi
    sleep 0.1
  done
  STOPPED=survived
}

cleanup_after_failure() {  # a failed launch or start leaves no pane and no worker behind
  local pane=$CLEANUP_PANE
  if [ -z "$pane" ] && [ "$CREATING" = 1 ]; then
    pane=$(jq -r '.result.root_pane.pane_id // empty' <<< "$HOUT" 2> /dev/null || true)
  fi
  [ -n "$pane" ] || return 0
  local closed=0
  STOPPED=""
  [ -z "$CLEANUP_PGID" ] || stop_group "$CLEANUP_PGID" "$CLEANUP_LSTART"
  if "$HERDR_BIN" pane close "$pane" > /dev/null 2>&1; then closed=1; fi
  [ -n "${REG:-}" ] && [ -n "$ID" ] || return 0
  # closed only when the pane is closed and the worker stopped; else closing, which a later close finishes.
  if [ "$closed" = 1 ] && [ "$STOPPED" != survived ]; then
    transition_try closed '{closed_at: $t, error: $m}' --arg t "$(now)" --arg m "$1"
  else
    transition_try closing '{error: $m}' --arg m "$1"
  fi
}

# ---- mode A

write_runner() {  # the pane's runner out/<id>.sh and the worker's supervisor out/<id>.sup.sh
  local view="" carry="" v
  case $HARNESS in claude|deepseek) view=$SCRIPT_DIR/stream.jq ;; esac
  if [ "$HARNESS" = codex ]; then
    # The companion keeps its jobs under CLAUDE_PLUGIN_DATA, tagged with the Claude session; a pane
    # has neither. Carry the conductor's, so its status, result and cancel calls find the job.
    for v in CLAUDE_PLUGIN_DATA CODEX_COMPANION_SESSION_ID; do
      [ -z "${!v:-}" ] || carry+="export $v=$(printf '%q' "${!v}")"$'\n'
    done
  fi
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Supervisor of worker %s of run %s, started by its pane runner %s.\n' "$ID" "$RUN" "$RUNNER"
    printf 'token=%q cwd=%q cmd=%q log=%q errf=%q pidf=%q startf=%q exitf=%q grace=%d\n' \
      "$TOKEN" "$CWD" "$CMD_FILE" "$LOG" "$ERRF" "$PIDF" "$STARTF" "$EXITF" "$GRACE"
    cat << 'BODY'
# Herdr kills what runs in a pane's session moments after it closes the pane, so the worker's parent
# lives here, in a session of its own. It runs the worker in a further session and process group,
# reaps it, stops what is left of its group, and only then writes the exit record: that record, not
# any line of output, says the worker ended. A stop (SIGHUP or SIGTERM here, SIGUSR1 for a Ctrl+C in
# the pane, or the pane runner gone) stops the whole group: TERM, then KILL after $grace s. Started in
# the background of a script, this shell ignores SIGINT and cannot trap it, hence SIGUSR1.
set -u
view_pid=$1 view_start=$2
w="" lstart="" sig="" killer="" kstart="" watcher="" wstart="" reaped=""
pfield() { awk -v n="$2" '{ sub(/^.*\) /, ""); print $n }' "/proc/$1/stat" 2> /dev/null; }
self_start=$(pfield $$ 20)
group_left() {  # a member of the worker's group that has not exited
  local p
  for p in $(pgrep -g "$w" -s "$w" 2> /dev/null); do
    [ "$(pfield "$p" 1)" = Z ] || return 0
  done
  return 1
}
ours() {  # the worker's group is still the one started: its leader, if alive, has the recorded start time
  local st
  st=$(pfield "$w" 20)
  [ -z "$st" ] || [ "$st" = "$lstart" ] || return 1
  group_left
}
kill_own() {  # kill_own PID START: signal one of this shell's helpers only while it is still that process
  [ -n "$1" ] && [ "$(pfield "$1" 20)" = "$2" ] && kill "$1" 2> /dev/null
}
stop() {
  [ -z "$reaped" ] || return 0
  [ -n "$sig" ] || sig=$1
  [ -n "$w" ] && [ -n "$lstart" ] || return 0   # not started yet: the start below sees sig and stops it
  ours && kill -TERM -- "-$w" 2> /dev/null
  if [ -z "$killer" ]; then
    (trap - USR1 TERM HUP; sleep "$grace"; ours && kill -KILL -- "-$w" 2> /dev/null) &
    killer=$!
    kstart=$(pfield "$killer" 20)
  fi
}
trap 'stop HUP' HUP
trap 'stop INT' USR1
trap 'stop TERM' TERM
cd "$cwd" || exit 1
if [ -n "$errf" ]; then
  setsid -w bash "$cmd" < /dev/null >> "$log" 2> "$errf" &
else
  setsid -w bash "$cmd" < /dev/null >> "$log" 2>&1 &
fi
w=$!
lstart=$(pfield "$w" 20)
printf '%s %s\n' "$w" "$lstart" > "$pidf"
printf '{"token":"%s","supervisor_pid":%s,"supervisor_start":"%s","pgid":%s,"leader_start":"%s"}\n' \
  "$token" "$$" "$(pfield $$ 20)" "$w" "$lstart" > "$startf.tmp" && mv -f "$startf.tmp" "$startf"
[ -z "$sig" ] || stop "$sig"
# The pane runner gone (pane closed, runner killed) stops the worker.
(
  trap - USR1 TERM HUP
  while [ "$(pfield "$view_pid" 20)" = "$view_start" ] && [ "$(pfield "$view_pid" 1)" != Z ]; do sleep 1; done
  [ "$(pfield $$ 20)" = "$self_start" ] && kill -HUP $$
) &
watcher=$!
wstart=$(pfield "$watcher" 20)
# Reap the leader. wait -p names the pid that ended; a trapped signal interrupts wait and leaves the
# variable unset, so wait again until the leader itself is reaped.
while :; do
  p=""
  wait -n -p p "$w"
  s=$?
  [ "${p:-}" = "$w" ] && break
  if [ "$s" = 127 ]; then s=""; break; fi   # no longer this shell's child: its status is unknown
done
reaped=1
kill_own "$watcher" "$wstart"
# What the worker left in its group is stopped too: a finished worker leaves nothing running.
stray=false
if ours; then
  stray=true
  kill -TERM -- "-$w" 2> /dev/null
  i=0; while ours && [ $i -lt $((grace * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  ours && kill -KILL -- "-$w" 2> /dev/null
  i=0; while ours && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
fi
cleared=true
ours && cleared=false
kill_own "$killer" "$kstart"
st=null sj=null
[ -z "$s" ] || st=$s
[ -z "$sig" ] || sj="\"$sig\""
printf '{"token":"%s","status":%s,"signal":%s,"pgid":%s,"leader_start":"%s","stray":%s,"group_cleared":%s,"ended_at":"%s"}\n' \
  "$token" "$st" "$sj" "$w" "$lstart" "$stray" "$cleared" "$(date -Iseconds)" > "$exitf.tmp" && mv -f "$exitf.tmp" "$exitf"
BODY
  } > "$SUPF"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Pane runner of worker %s of run %s, written by herdr-worker.sh launch for pane %s.\n' "$ID" "$RUN" "$PANE"
    printf 'pane=%q token=%q id=%q cwd=%q sup=%q suplog=%q\n' "$PANE" "$TOKEN" "$ID" "$CWD" "$SUPF" "$SUPLOG"
    printf 'log=%q view=%q pidf=%q startf=%q exitf=%q\n' "$LOG" "$view" "$PIDF" "$STARTF" "$EXITF"
    printf 'herdr=%q source=%q agent=%q label=%q mark=%q\n' "$HERDR_BIN" "$SOURCE" "$AGENT" "$LABEL" "$MARK"
    printf '%s' "$carry"
    cat << 'BODY'
# Starts the worker's supervisor in a session of its own, shows the worker's log, and once the
# supervisor has written the exit record prints the marker line, which only wakes a waiting
# conductor. Ctrl+C or TERM here stops the worker through the supervisor; a closed pane does too.
set -u
s="" ss="" w="" t=""
pstart() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2> /dev/null; }
fwd() { [ -n "$s" ] && [ "$(pstart "$s")" = "$ss" ] && kill -"$1" "$s" 2> /dev/null; }   # the supervisor only
trap 'fwd HUP; exit 0' HUP
trap 'fwd USR1' INT
trap 'fwd TERM' TERM
cd "$cwd" || exit 1
: > "$log"
unset HERDR_ENV HERDR_PANE_ID
setsid bash "$sup" "$$" "$(pstart $$)" < /dev/null > "$suplog" 2>&1 &
s=$!
ss=$(pstart "$s")
i=0
while [ ! -s "$pidf" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -s "$pidf" ] || read -r w _ < "$pidf"
# The pane shows the log. The worker's status comes from the exit record, never from this view.
if [ -n "$w" ]; then
  if [ -n "$view" ]; then
    tail -n +1 -f --pid="$w" "$log" | jq -rR --unbuffered -f "$view" &
  else
    tail -n +1 -f --pid="$w" "$log" &
  fi
  t=$!
fi
# Wait for the supervisor: it ends after the exit record.
while :; do
  p=""
  wait -n -p p "$s"
  r=$?
  [ "${p:-}" = "$s" ] && break
  [ "$r" != 127 ] || break
done
[ -z "$t" ] || wait "$t" 2> /dev/null
code=lost stopped=""
if [ -s "$exitf" ] && grep -q "\"token\":\"$token\"" "$exitf"; then
  code=$(sed -n 's/.*"status":\([0-9]*\).*/\1/p' "$exitf")
  code=${code:-unknown}
  stopped=$(sed -n 's/.*"signal":"\([A-Z]*\)".*/\1/p' "$exitf")
fi
printf '\n%s%s exit=%s %s\n' "$mark" "$id" "$code" "$token"
# Herdr drops a report once the bare shell is back in the foreground, so stay in the foreground and
# show the worker as finished until the conductor closes the pane. Ctrl+C gives the shell back.
h=""
trap 'kill "$h" 2> /dev/null; exit 0' INT TERM HUP
msg="finished, exit $code"
[ -z "$stopped" ] || msg="stopped by $stopped"
[ "$code" != lost ] || msg="lost: its supervisor ended without an exit record"
"$herdr" pane report-agent "$pane" --source "$source" --agent "$agent" --state idle --message "$msg" > /dev/null 2>&1 &&
  "$herdr" pane report-metadata "$pane" --source "$source" --agent "$agent" --display-agent "$label" > /dev/null 2>&1
while :; do sleep 86400 & h=$!; wait "$h"; done
BODY
  } > "$RUNNER"
}

STARTED=""
read_started() {  # STARTED: the supervisor's start record, when it carries this worker's token
  local f=$OUT/$ID.started tok
  STARTED=""
  [ -s "$f" ] || return 1
  tok=$(wf token)
  STARTED=$(jq -c --arg t "$tok" 'select(type == "object" and .token == $t)' "$f" 2> /dev/null) || STARTED=""
  [ -n "$STARTED" ]
}
EXIT_REC=""
read_exit_record() {  # EXIT_REC: the supervisor's exit record, when valid for this worker
  local f=$OUT/$ID.exit tok
  EXIT_REC=""
  [ -s "$f" ] || return 1
  tok=$(wf token)
  EXIT_REC=$(jq -c --arg t "$tok" \
    'select(type == "object" and .token == $t and ((.status | type) == "number" or .status == null))' "$f" 2> /dev/null) ||
    EXIT_REC=""
  [ -n "$EXIT_REC" ]
}
supervisor_alive() {  # the supervisor of the start record still runs
  local rp rs
  [ -n "$STARTED" ] || return 1
  rp=$(jq -r .supervisor_pid <<< "$STARTED") rs=$(jq -r .supervisor_start <<< "$STARTED")
  [ "$(proc_field "$rp" 20)" = "$rs" ] && [ "$(proc_field "$rp" 1)" != Z ]
}
group_of_worker() {  # PG and LS: the worker's process group, from the registry or the start record
  PG=$(wf pgid) LS=$(wf leader_start)
  if [ -z "$PG" ] && read_started; then
    PG=$(jq -r .pgid <<< "$STARTED") LS=$(jq -r .leader_start <<< "$STARTED")
  fi
}

record_outcome() {  # record what EXIT_REC says, unless the lifecycle has moved on (closed)
  local st sig
  st=$(jq -r '.status // empty' <<< "$EXIT_REC") sig=$(jq -r '.signal // empty' <<< "$EXIT_REC")
  if [ -n "$st" ] && [ -z "$sig" ]; then
    transition finished '{exit_code: $r.status, stop_signal: null, ended_at: $r.ended_at, finished_at: $r.ended_at,
                          stray_stopped: $r.stray, group_cleared: $r.group_cleared}' --argjson r "$EXIT_REC"
  elif [ -n "$sig" ]; then
    transition stopped '{exit_code: $r.status, stop_signal: $r.signal, ended_at: $r.ended_at,
                         stray_stopped: $r.stray, group_cleared: $r.group_cleared}' --argjson r "$EXIT_REC"
  else
    transition lost '{exit_code: null, stop_signal: null, ended_at: $r.ended_at, group_cleared: $r.group_cleared}' \
      --argjson r "$EXIT_REC"
  fi
}

emit_outcome() {  # the worker's recorded outcome as wait's result
  local ex gone=false
  pane_present || gone=true
  case $(wf state) in
    finished) ex=0 ;;
    lost) ex=7 ;;
    *) ex=4 ;;   # stopped, or closing or closed while this wait ran
  esac
  emit "$ex" "$(jq -c --argjson g "$gone" \
    '{id, state, exit_code, stop_signal, timed_out: false, pane_gone: $g, out_log}
     + (if .killed_worker == null then {} else {killed_worker} end)' <<< "$W")"
}

wait_a() {
  local deadline left slice re marker_seen=0
  parse_timeout 7000000
  deadline=$(($(now_ms) + T))
  re="(?m)^${MARK}${ID} exit=\\S+ $(wf token)\$"
  while :; do
    reload_worker
    case $(wf state) in finished|stopped|lost|closing|closed) emit_outcome ;; esac
    if read_exit_record; then record_outcome; emit_outcome; fi
    read_started || true
    local present=0
    pane_present && present=1
    if [ -n "$STARTED" ] && ! supervisor_alive; then
      # The supervisor is gone. Its record may have landed a moment ago.
      if read_exit_record; then record_outcome; emit_outcome; fi
      group_of_worker
      if group_ours "$PG" "$LS"; then
        if [ "$present" = 0 ]; then
          # No pane and no runner: nothing supervises the worker any more, so it stops here.
          stop_group "$PG" "$LS"
          transition lost '{exit_code: null, ended_at: $t, killed_worker: $k}' --arg t "$(now)" --arg k "$STOPPED"
          emit_outcome
        fi
        # The pane is there but the supervisor is not: the worker runs on unreaped; look again.
      else
        transition lost '{exit_code: null, ended_at: $t}' --arg t "$(now)"
        emit_outcome
      fi
    elif [ -z "$STARTED" ] && [ "$present" = 0 ]; then
      # The pane went before the supervisor ever started.
      transition lost '{exit_code: null, ended_at: $t}' --arg t "$(now)"
      emit_outcome
    fi
    left=$((deadline - $(now_ms)))
    if [ "$left" -le 0 ]; then
      emit 3 "$(jq -c '{id, state, exit_code: null, timed_out: true, pane_gone: false, out_log}' <<< "$W")"
    fi
    slice=$((left < 30000 ? left : 30000))
    if [ "$present" = 1 ] && [ -n "$STARTED" ] && [ "$marker_seen" = 0 ] && [ "$slice" -ge 100 ]; then
      # The marker only wakes this loop; the exit record decides. A marker without a record (a worker
      # that printed the line itself) stays in the scrollback and would match at once from now on,
      # so from then on look every 2 s instead.
      if hcall pane wait-output "$(wf pane_id)" --regex "$re" --timeout "$slice"; then
        read_exit_record || marker_seen=1
      else
        case $(herr_code) in timeout|pane_not_found) ;; *) herdr_fail pane wait-output ;; esac
      fi
    else
      nap "$([ "$marker_seen" = 1 ] && echo 2000 || echo 1000)" "$deadline"
    fi
  done
}

cmd_launch() {
  require --run "$RUN" --id "$ID" --label "$LABEL" --cwd "$CWD" --harness "$HARNESS" --cmd-file "$CMD_FILE"
  setup_run
  check_id
  case $HARNESS in claude|codex|deepseek|agy|plain) ;; *) fail 64 usage "--harness must be claude, codex, deepseek, agy or plain" ;; esac
  [ -d "$CWD" ] || fail 64 usage "--cwd is not a directory: $CWD"
  [ -f "$CMD_FILE" ] || fail 64 usage "--cmd-file not found: $CMD_FILE"
  CWD=$(cd "$CWD" && pwd -P)
  CMD_FILE=$(abs "$CMD_FILE")
  mkdir -p "$OUT"
  LOG=$OUT/$ID.log ERRF=$OUT/$ID.err RUNNER=$OUT/$ID.sh SUPF=$OUT/$ID.sup.sh SUPLOG=$OUT/$ID.sup.log
  PIDF=$OUT/$ID.pid STARTF=$OUT/$ID.started EXITF=$OUT/$ID.exit
  case $HARNESS in codex|plain) ERRF="" ;; esac
  AGENT=$(agent_name "$HARNESS")
  TOKEN=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
  local entry
  entry=$(jq -cn --arg id "$ID" --arg label "$LABEL" --arg h "$HARNESS" --arg agent "$AGENT" --arg cwd "$CWD" \
    --arg cmd "$CMD_FILE" --arg runner "$RUNNER" --arg log "$LOG" --arg err "$ERRF" --arg tok "$TOKEN" --arg t "$(now)" \
    '{id: $id, label: $label, harness: $h, mode: "A", agent_name: $agent, checkout: $cwd, cmd_file: $cmd,
      runner: $runner, out_log: $log, out_err: (if $err == "" then null else $err end), token: $tok,
      pgid: null, leader_start: null, state: "starting", exit_code: null, stop_signal: null,
      started_at: $t, ended_at: null, finished_at: null, shown: null}')

  lock
  [ -z "$(reg_read | jq -r --arg id "$ID" '.workers[] | select(.id == $id) | .id')" ] ||
    fail 64 duplicate_id "worker $ID is already in $REG; a retry takes the next attempt number"
  rm -f "$PIDF" "$STARTF" "$EXITF"
  open_tab "$CWD" "$entry"
  write_runner
  unlock

  wait_shell "$PANE" || fail 1 shell_not_ready "the shell in pane $PANE was not at its prompt within 10 s"
  h pane run "$PANE" " bash $(printf '%q' "$RUNNER")"
  local i
  for ((i = 0; i < 60; i++)); do
    if read_started; then break; fi
    sleep 0.25
  done
  [ -n "$STARTED" ] || fail 1 runner_not_started "the worker did not start within 15 s" "$(as_json "$(screen_text)")"
  CLEANUP_PGID=$(jq -r .pgid <<< "$STARTED") CLEANUP_LSTART=$(jq -r .leader_start <<< "$STARTED")
  update_worker '{pgid: $s.pgid, leader_start: $s.leader_start}' --argjson s "$STARTED"
  transition running '{}'

  # The report binds to the pane's foreground process: send it once the runner is up, and again
  # until Herdr shows it.
  local reported=false
  for ((i = 0; i < 20; i++)); do
    [ ! -e "$EXITF" ] || break
    if report "$PANE" working && report_took "$PANE" working; then reported=true; break; fi
    sleep 0.5
  done
  # A worker that ended meanwhile: the runner's "finished" report may have come before ours.
  if read_exit_record; then report "$PANE" idle "finished" || true; fi
  emit 0 "$(public | jq -c --argjson r "$reported" '. + {reported: $r}')"
}

# ---- mode B

AGENT_STATUS="" SESSION_ID=""
agent_check() {  # the worker's pane is present and hosts its recorded agent; sets AGENT_STATUS and SESSION_ID
  # Not hosting it: AGENT_STATUS is gone (no pane, or another agent in it) or absent (no agent in it).
  AGENT_STATUS=gone SESSION_ID=""
  pane_present || return 1
  hlook agent get "$(wf pane_id)" || { AGENT_STATUS=absent; return 1; }
  jq -e --arg n "$(wf agent_name)" --arg t "$(wf terminal_id)" \
    '.result.agent | .name == $n and .terminal_id == $t' <<< "$HOUT" > /dev/null || return 1
  AGENT_STATUS=$(jq -r '.result.agent.agent_status // "unknown"' <<< "$HOUT")
  SESSION_ID=$(jq -r '.result.agent.agent_session.value // empty' <<< "$HOUT")
}

report_sig() {  # the report file's identity now: inode, size, modification time (or "absent")
  local f
  f=$(wf report)
  if [ -e "$f" ]; then stat -c '%i:%s:%.9Y' "$f"; else printf absent; fi
}
report_fresh() {  # the report is non-empty and was written during the current turn
  local f
  f=$(wf report)
  [ "$(wf turn)" -gt 0 ] && [ -s "$f" ] && [ "$(report_sig)" != "$(wf report_snapshot)" ]
}

emit_b() {  # emit_b EXIT [SCREEN]: a mode B worker's state as the call's result
  emit "$1" "$(jq -c --arg st "${AGENT_STATUS:-unknown}" --arg sc "${2:-}" \
    '{id, agent_name, agent_status: $st, state, turn, delivered, report_turn, report,
      report_ready: (.turn > 0 and .report_turn == .turn and .delivered != false), session_id}
     + (if .session_ambiguous then {session_ambiguous: true} else {} end)
     + (if $sc == "" then {} else {screen: $sc} end)' <<< "$W")"
}
gone_b() { transition gone '{}'; AGENT_STATUS=gone; emit_b 4; }
blocked_b() {  # blocked_b [SCREEN]: at a dialog; the result's screen is SCREEN, the read that confirmed it, or a fresh read
  transition blocked '{}'; AGENT_STATUS=blocked; emit_b 5 "${1:-$(screen_text)}"
}

# Codex's screen, read at its bottom: Codex draws its input area (composer, status line, footer) or a
# dialog below the transcript, so words in the transcript never decide. The footer's " for shortcuts"
# and " for agents" hints are Codex's own sign of an empty composer that has focus with no popup (it
# draws them only then: codex-rs/tui/src/bottom_pane/chat_composer/passive_hints.rs); a draft, the
# history search (ctrl+r), a slash or file menu, a dialog, a pane too narrow for both hints and a
# failed read all lack them.
CODEX_SCREEN="" CODEX_TEXT=""
codex_screen() {  # CODEX_SCREEN: composer (0), dialog or other (1); CODEX_TEXT: the screen read
  local -a rows
  local n i comp=-1 last2 last12
  CODEX_SCREEN=other
  CODEX_TEXT=$(screen_text)
  # Every command here and below exits 0 or sits in a condition: the ERR trap would count a non-zero
  # status in a subshell as the call's failure.
  mapfile -t rows < <(sed -e 's/[[:space:]]*$//' -e '/^$/d' <<< "$CODEX_TEXT")
  n=${#rows[@]}
  [ "$n" -gt 0 ] || return 1
  last2=$((n > 2 ? n - 2 : 0)) last12=$((n > 12 ? n - 12 : 0))
  # A dialog ends the screen: its key line ("enter confirm · esc skip", "enter continue · esc back",
  # "Press enter to confirm or esc to cancel") in the last two rows, an option list above it.
  if printf '%s\n' "${rows[@]:last2}" | grep -q -E '^ *(enter [a-z]+ · esc [a-z]+|Press enter to confirm or esc to cancel)'; then
    if printf '%s\n' "${rows[@]:last12}" | grep -q -E '^(›| ) *[0-9]+\. '; then CODEX_SCREEN=dialog; fi
    return 1
  fi
  # The composer is the last row that starts with "›", within the last eight rows; a hint follows it
  # in the last two rows.
  for ((i = n - 1; i >= 0 && i >= n - 8; i--)); do
    if [[ ${rows[i]} == '›'* ]]; then comp=$i; break; fi
  done
  [ "$comp" -ge 0 ] && ! [[ ${rows[comp]} =~ ^›\ *[0-9]+\.\  ]] || return 1
  for ((i = (comp + 1 > last2 ? comp + 1 : last2); i < n; i++)); do
    if [[ ${rows[i]} == *' for shortcuts'* || ${rows[i]} == *' for agents'* ]]; then CODEX_SCREEN=composer; return 0; fi
  done
  return 1
}

codex_rollout_session() {  # the checkout's Codex rollout ids written since the agent started: one id, "many" or nothing
  local dir since ids
  dir=${CODEX_HOME:-$HOME/.codex}/sessions
  since=$(wf started_ms)
  [ -d "$dir" ] && [ -n "$since" ] || return 0
  # Written since the start, to the millisecond: a resumed session appends to its old file.
  # No step may exit non-zero (pipefail and the ERR trap): none found is an empty answer, not an error.
  ids=$({ command find "$dir" -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2> /dev/null || true; } |
    awk -v s="$since" '$1 * 1000 >= s { sub(/^[^ ]+ /, ""); print }' |
    while IFS= read -r f; do
      head -n 1 "$f" 2> /dev/null | jq -r --arg c "$(wf checkout)" \
        'select(.type == "session_meta" and .payload.cwd == $c and .payload.originator == "codex-tui") | .payload.id' 2> /dev/null || true
    done | sed '/^$/d' | sort -u)
  case $ids in
    '') ;;
    *$'\n'*) printf many ;;
    *) printf '%s' "$ids" ;;
  esac
}
session_fill() {  # session_fill [rollout]: record the agent's session id once it is verified as this agent's
  # Herdr's value comes from the agent's own hook in its pane. Without it, a Codex agent whose turn has
  # ended (rollout) takes the id of the checkout's one rollout written since its start; two such
  # rollouts (two Codex agents in one checkout) leave it unset and mark it session_ambiguous.
  local found
  if [ -z "$SESSION_ID" ] && [ "${1:-}" = rollout ] && [ "$(wf harness)" = codex ] &&
    [ -z "$(wf session_id)" ] && [ "$(wf session_ambiguous)" != true ]; then
    found=$(codex_rollout_session)
    case $found in
      '') ;;
      many) update_worker '{session_ambiguous: true}' ;;
      *) SESSION_ID=$found ;;
    esac
  fi
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "$(wf session_id)" ]; then
    update_worker '{session_id: $s} + (if .session_ambiguous then {session_ambiguous: false} else {} end)' --arg s "$SESSION_ID"
  fi
}

# Confirmations take time, and each must fit in the call's own time (DEADLINE_MS) with READ_MS left for
# the read that ends it; one that can't fit ends the call with 3 at once, never after its deadline.
READ_MS=250
blocked_grace() {  # blocked_grace DEADLINE_MS: 0 waited, 1 already used in this call, 2 no room for it
  # Herdr can show blocked for a moment after a dialog is answered: allow 3 s for a change, once.
  [ "$BLOCKED_SEEN" = 0 ] || return 1
  [ "$(($1 - $(now_ms)))" -ge "$((3000 + READ_MS))" ] || return 2
  BLOCKED_SEEN=1
  if ! hcall agent wait "$(wf pane_id)" --until idle --until done --until working --timeout 3000; then
    case $(herr_code) in timeout|agent_not_found|pane_not_found) ;; *) herdr_fail agent wait ;; esac
  fi
}
BLOCKED_SEEN=0

not_ready_b() {  # start or ready ends with 3: not ready within the time, or no room left to confirm what it shows
  [ "$(wf turn)" != 0 ] || transition starting '{}'
  emit_b 3 "$(screen_text | tail -n 25)"
}

startup_settle() {  # startup_settle DEADLINE_MS: classify a starting agent as ready, at a dialog, or not ready yet
  local left splash=0 look quiet=0 was_quiet dialog=0 was_dialog g
  while :; do
    # Every pass starts unconfirmed: only a dialog read on the pass right after one confirms it.
    look=wait was_quiet=$quiet quiet=0 was_dialog=$dialog dialog=0
    if ! agent_check && [ "$AGENT_STATUS" = gone ]; then
      transition gone '{}'
      emit_b 4 "$(screen_text)"
    fi
    if [ "$AGENT_STATUS" != absent ] && [ "$(wf harness)" = pi ] && [ "$splash" -lt 10 ] && screen_text | grep -q 'Press any key'; then
      # Pi can show a splash while Herdr already reports it idle.
      splash=$((splash + 1))
      hcall pane send-keys "$(wf pane_id)" esc || true
      sleep 0.5
      continue
    fi
    session_fill
    case $AGENT_STATUS in
      blocked)
        g=0; blocked_grace "$1" || g=$?
        case $g in 0) continue ;; 2) not_ready_b ;; *) blocked_b ;; esac ;;
      idle|done)
        if [ "$(wf harness)" != codex ]; then transition ready '{}'; emit_b 0; fi
        # Herdr shows Codex's hooks review as idle, so only Codex's empty composer means ready. After a
        # dialog Codex shows idle, then working while it finishes starting: ready when Herdr has shown
        # no work for 3 s and a fresh look (Herdr's state and the screen, read after them) still finds
        # the composer.
        if codex_screen; then
          if [ "$was_quiet" = 1 ]; then transition ready '{}'; emit_b 0; fi
          [ "$((${1} - $(now_ms)))" -ge "$((3000 + READ_MS))" ] || not_ready_b
          if hcall agent wait "$(wf pane_id)" --until working --until blocked --timeout 3000; then continue; fi
          case $(herr_code) in timeout) quiet=1 ;; agent_not_found|pane_not_found) ;; *) herdr_fail agent wait ;; esac
          continue
        fi
        # A dialog counts once a read a full second later, with no other read between, still shows it:
        # right after keys answer one, the first read can still show it, before Codex has drawn what
        # follows. The result's screen is the confirming read.
        if [ "$CODEX_SCREEN" = dialog ]; then
          [ "$was_dialog" = 0 ] || blocked_b "$CODEX_TEXT"
          [ "$((${1} - $(now_ms)))" -ge "$((1000 + READ_MS))" ] || not_ready_b
          dialog=1
          nap 1000 "$1"
          continue
        fi
        look=nap ;;
    esac
    left=$((${1} - $(now_ms)))
    [ "$left" -ge 100 ] || not_ready_b
    if [ "$AGENT_STATUS" = absent ] || [ "$look" = nap ]; then
      nap 1000 "$1"   # Herdr has not seen the agent in its pane yet, or Codex's screen is not settled
    elif ! hcall agent wait "$(wf pane_id)" --until idle --until done --until blocked --timeout "$((left < 30000 ? left : 30000))"; then
      case $(herr_code) in timeout|agent_not_found|pane_not_found) ;; *) herdr_fail agent wait ;; esac
    fi
  done
}

settle_b() {  # settle_b DEADLINE_MS: after a delivered prompt, until the turn ends or time is up
  local rechecked=0 left g
  while :; do
    agent_check || gone_b
    session_fill
    case $AGENT_STATUS in
      blocked)
        g=0; blocked_grace "$1" || g=$?
        case $g in 0) continue ;; 2) emit_b 3 ;; *) blocked_b ;; esac ;;
      idle|done)
        if report_fresh; then session_fill rollout; transition reported '{report_turn: .turn}'; emit_b 0; fi
        # An early idle can come before the turn's work: look once more after a pause.
        if [ "$rechecked" = 0 ]; then rechecked=1; nap 3000 "$1"; continue; fi
        session_fill rollout
        transition settled '{}'
        emit_b 6 "$(screen_text | tail -n 25)" ;;
    esac
    left=$((${1} - $(now_ms)))
    [ "$left" -ge 100 ] || emit_b 3
    if ! hcall agent wait "$(wf pane_id)" --until idle --until done --until blocked --timeout "$((left < 30000 ? left : 30000))"; then
      case $(herr_code) in timeout|agent_not_found|pane_not_found) ;; *) herdr_fail agent wait ;; esac
    fi
  done
}

NATIVE=()
read_args() {  # one argument per line, passed as is; empty lines are skipped, a trailing CR dropped
  local line
  NATIVE=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -z "$line" ] || NATIVE+=("$line")
  done < "$ARGS_FILE"
}

cmd_start() {
  require --run "$RUN" --id "$ID" --label "$LABEL" --cwd "$CWD" --kind "$KIND" --args-file "$ARGS_FILE" --report "$REPORT"
  setup_run
  check_id
  case $KIND in
    claude|pi|agy) parse_timeout 60000 ;;
    codex) parse_timeout 120000 ;;   # Codex starts its MCP servers first; Herdr shows it working meanwhile
    *) fail 64 usage "--kind must be claude, codex, pi or agy" ;;
  esac
  [ -d "$CWD" ] || fail 64 usage "--cwd is not a directory: $CWD"
  [ -f "$ARGS_FILE" ] || fail 64 usage "--args-file not found: $ARGS_FILE"
  local e
  for e in "${ENVS[@]}"; do [[ $e =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || fail 64 usage "--env takes KEY=VALUE: $e"; done
  CWD=$(cd "$CWD" && pwd -P)
  REPORT=$(abs "$REPORT")
  mkdir -p "$(dirname "$REPORT")" || fail 64 usage "cannot create the report's folder: $(dirname "$REPORT")"
  read_args
  local name deadline entry
  name=$(agent_name "$KIND")
  ! hlook agent get "$name" || fail 1 agent_name_taken "an agent named $name already runs in Herdr"
  entry=$(jq -cn --arg id "$ID" --arg label "$LABEL" --arg k "$KIND" --arg name "$name" --arg cwd "$CWD" \
    --arg report "$REPORT" --arg t "$(now)" --argjson ms "$(now_ms)" \
    '{id: $id, label: $label, harness: $k, mode: "B", agent_name: $name, checkout: $cwd, report: $report,
      session_id: null, state: "starting", turn: 0, delivered: null, report_turn: null, report_snapshot: null,
      prompted_at: null, started_at: $t, started_ms: $ms}')

  lock
  [ -z "$(reg_read | jq -r --arg id "$ID" '.workers[] | select(.id == $id) | .id')" ] ||
    fail 64 duplicate_id "worker $ID is already in $REG; a retry takes the next attempt number"
  open_tab "$CWD" "$entry"
  unlock

  wait_shell "$PANE" || fail 1 shell_not_ready "the shell in pane $PANE was not at its prompt within 10 s"
  deadline=$(($(now_ms) + T))
  if ! hcall agent start "$name" --kind "$KIND" --pane "$PANE" --timeout "$T" -- "${NATIVE[@]}"; then
    # Not ready within the time: at a dialog, or still starting. startup_settle tells which.
    case $(herr_code) in agent_not_ready|timeout) ;; *) herdr_fail agent start ;; esac
  fi
  CLEANUP_PANE=""
  startup_settle "$deadline"
}

mode_b_worker() {  # the current worker is an open mode B worker
  [ "$(wf mode)" = B ] || fail 64 usage "$SUB is for mode B workers; $ID is mode A"
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  case $(wf state) in gone|closing) AGENT_STATUS=gone; emit_b 4 ;; esac
}
delivered() { jq -r .delivered <<< "$W"; }   # true, false (the last prompt was refused) or null (none yet)

cmd_ready() {
  require --run "$RUN" --id "$ID"
  setup_run
  parse_timeout 60000
  load_worker
  mode_b_worker
  [ "$(delivered)" != true ] ||
    fail 64 usage "ready is for an agent with no delivered prompt (the first, or one refused at a dialog); after a delivered prompt use wait"
  startup_settle "$(($(now_ms) + T))"
}

cmd_keys() {
  require --run "$RUN" --id "$ID" --keys "$KEYS"
  setup_run
  load_worker
  mode_b_worker
  agent_check || gone_b
  local keys
  read -ra keys <<< "$KEYS"
  h agent send-keys "$(wf agent_name)" "${keys[@]}"   # by name: only the recorded agent gets them
  emit 0 "$(jq -c --arg k "$KEYS" '{id, agent_name, state, keys: $k}' <<< "$W")"
}

cmd_prompt() {
  require --run "$RUN" --id "$ID" --text-file "$TEXT_FILE"
  setup_run
  parse_timeout 7000000
  load_worker
  mode_b_worker
  [ -f "$TEXT_FILE" ] || fail 64 usage "--text-file not found: $TEXT_FILE"
  agent_check || gone_b
  local deadline before
  # A prompt refused before it is sent opens no turn: the turn, its snapshot and its time go back to
  # before, with delivered false, so no wait can take an earlier turn's report for this prompt's.
  before=$(jq -c '{turn, report_snapshot, prompted_at} + {delivered: false}' <<< "$W")
  case $AGENT_STATUS in
    blocked)
      if [ "$(delivered)" = true ] && [[ $(wf state) =~ ^(working|blocked)$ ]]; then
        fail 64 turn_open "turn $(wf turn) is still open, at a dialog: answer it, then wait"
      fi
      transition blocked '$b' --argjson b "$before"; AGENT_STATUS=blocked; emit_b 5 "$(screen_text)" ;;
    working) fail 64 agent_working "agent $(wf agent_name) is still working: wait for its turn to end first" ;;
  esac
  if [ "$(wf harness)" = codex ] && ! codex_screen; then
    # Only Codex's empty composer takes a prompt. A dialog (Herdr shows the hooks review as idle) is 5;
    # a draft, the history search, a menu or a screen it can't read is 3. Neither sends anything.
    if [ "$CODEX_SCREEN" = dialog ]; then
      transition blocked '$b' --argjson b "$before"; AGENT_STATUS=blocked; emit_b 5 "$CODEX_TEXT"
    fi
    update_worker '$b' --argjson b "$before"; emit_b 3 "$CODEX_TEXT"
  fi
  deadline=$(($(now_ms) + T))
  # The turn starts before the prompt goes out, so a report written by this turn always counts.
  transition working '{turn: (.turn + 1), delivered: true, report_snapshot: $s, prompted_at: $t}' \
    --arg s "$(report_sig)" --arg t "$(now)"
  if ! hcall agent prompt "$(wf agent_name)" "$(< "$TEXT_FILE")" --wait --timeout "$T"; then
    case $(herr_code) in
      agent_blocked|agent_not_ready)  # refused before it was sent
        transition blocked '$b' --argjson b "$before"
        AGENT_STATUS=blocked
        emit_b 5 "$(screen_text)" ;;
      timeout) agent_check || true; emit_b 3 ;;
      agent_not_found|pane_not_found) transition gone '$b' --argjson b "$before"; AGENT_STATUS=gone; emit_b 4 ;;
      agent_prompt_stalled) ;;   # sent, but no work seen yet: settle_b looks
      *) herdr_fail agent prompt ;;
    esac
  fi
  settle_b "$deadline"
}

# Codex's `/mcp verbose` prints its list into the transcript and leaves the composer empty; it opens no
# turn. The pane holds only the visible screen, so a list taller than the screen loses its heading. The
# list read is the last "🔌  MCP Tools" heading on screen, with nothing but Codex's input area below it,
# and it is new only when the screen gained a heading or the rows above the last heading changed (an
# unchanged screen still shows the previous list). A server row is "  • NAME: STATUS (N tools)", its
# detail rows "    • KEY: VALUE", and a long Tools value wraps onto rows of its own, which start with a name.
MCP_JQ='
def rows: split("\n") | map(sub("\\s+$"; ""));
def heads: [to_entries[] | select(.value | test("^🔌\\s+MCP Tools$")) | .key];
def above: heads as $h | if $h == [] then . else .[:$h[-1]] end;
def server_row: [capture("^  • (?<name>[^:\\s]+): (?<status>[^()]+) \\((?<tools>[0-9]+) tools?\\)$")];
def detail_row: [capture("^    • (?<k>[^:]+): (?<v>.*)$")];
def tail_row($row):
  if $row == "" or ($row | test("^\\s")) then .at = "tail"
  elif ($row | startswith("›")) then .at = "done"
  else .reason = "list_not_last" end;
($b | rows) as $b | ($s | rows) as $r | ($r | heads) as $h
| if $h == [] then {reason: "no_heading"}
  elif ($h | length) <= ($b | heads | length) and ($r | above) == ($b | above) then {reason: "not_new"}
  else
    reduce $r[$h[-1] + 1:][] as $row ({at: "lead", groups: [], key: null, reason: null};
      if .reason != null or .at == "done" then .
      elif .at == "tail" then tail_row($row)
      elif $row == "" then (if .at == "group" then .at = "gap" elif .at == "gap" then .at = "tail" else . end)
      else ($row | server_row) as $g | ($row | detail_row) as $kv
        | if $g != [] then .groups += [$g[0] + {tools: ($g[0].tools | tonumber), rows: {}}] | .at = "group" | .key = null
          elif .at == "gap" then tail_row($row)
          elif .at == "lead" then .reason = "unexpected_row"
          elif $kv != [] then .groups[-1].rows[$kv[0].k] = $kv[0].v | .key = $kv[0].k
          elif .key != null and ($row | test("^[•›⚠■]") | not) then .groups[-1].rows[.key] += $row
          else .reason = "unexpected_row" end
      end)
    | if .reason != null then {reason}
      elif .groups == [] then {reason: "no_servers"}
      elif .at != "done" then {reason: "no_composer_below"}
      else
        [.groups[] | {name, status, tools}
          + if .status != "connected" then {}
            elif .rows.Tools == null then {bad: true}
            elif .rows.Tools == "(none)" then {tool_names: []}
            else {tool_names: (.rows.Tools | split(",") | map(sub("^\\s+"; "") | sub("\\s+$"; "")))} end] as $sv
        | if any($sv[]; .bad or (.tool_names != null and (
              (.tool_names | length) != .tools or any(.tool_names[]; test("^[^\\s,]+$") | not))))
          then {reason: "tools_unreadable"}
          else {servers: $sv, connected: ([$sv[] | select(.status == "connected") | {(.name): .tool_names}] | add // {})} end
      end
  end'

cmd_mcp() {
  require --run "$RUN" --id "$ID"
  setup_run
  parse_timeout 15000
  load_worker
  mode_b_worker
  [ "$(wf harness)" = codex ] || fail 64 usage "mcp is for mode B Codex workers; $ID runs $(wf harness)"
  # No path here changes the lifecycle: a refusal or a gone agent leaves the registry as it was.
  agent_check || emit_b 4
  if [ "$(delivered)" = true ] && [[ $(wf state) =~ ^(working|blocked)$ ]]; then
    fail 64 turn_open "turn $(wf turn) is still open: wait for it to end first"
  fi
  case $AGENT_STATUS in
    blocked) emit_b 5 "$(screen_text)" ;;
    working) fail 64 agent_working "agent $(wf agent_name) is working: wait for it to settle first" ;;
  esac
  # The same last-moment check as prompt: only Codex's empty composer takes the command; a dialog is 5,
  # anything else 3, and nothing is sent.
  if ! codex_screen; then
    [ "$CODEX_SCREEN" != dialog ] || { AGENT_STATUS=blocked; emit_b 5 "$CODEX_TEXT"; }
    emit_b 3 "$CODEX_TEXT"
  fi
  local before deadline res reason=""
  before=$CODEX_TEXT
  deadline=$(($(now_ms) + T))
  if ! hcall agent prompt "$(wf agent_name)" "/mcp verbose"; then
    case $(herr_code) in
      agent_blocked) AGENT_STATUS=blocked; emit_b 5 "$(screen_text)" ;;
      agent_not_ready) emit_b 3 "$(screen_text)" ;;
      agent_not_found|pane_not_found) AGENT_STATUS=gone; emit_b 4 ;;
      *) herdr_fail agent prompt ;;
    esac
  fi
  while :; do
    codex_screen || true
    res=$(jq -cn --arg b "$before" --arg s "$CODEX_TEXT" "$MCP_JQ") || fail 1 internal "the MCP list parser failed"
    reason=$(jq -r '.reason // empty' <<< "$res")
    [ -n "$reason" ] || [ "$CODEX_SCREEN" = composer ] || reason=composer_not_empty
    if [ -z "$reason" ]; then
      agent_check || emit_b 4
      [ "$AGENT_STATUS" != working ] || fail 1 mcp_turn_opened "agent $(wf agent_name) is working after /mcp"
      emit 0 "$(jq -c --argjson r "$res" '{id, agent_name, state} + $r' <<< "$W")"
    fi
    [ "$((deadline - $(now_ms)))" -ge "$READ_MS" ] ||
      fail 1 mcp_unreadable "no new, complete MCP list above an empty composer within $T ms ($reason)" \
        "$(jq -cn --arg r "$reason" --arg s "$CODEX_TEXT" '{reason: $r, screen: $s}')"
    nap "$READ_MS" "$deadline"
  done
}

wait_b() {
  [ "$(wf turn)" -gt 0 ] || fail 64 not_prompted "wait follows a delivered prompt; before the first prompt use ready"
  [ "$(delivered)" != false ] ||
    fail 64 not_delivered "the last prompt was not delivered (a dialog, or an input not ready for it): answer the dialog or leave the input to its owner, run ready, then send the same prompt again"
  parse_timeout 7000000
  settle_b "$(($(now_ms) + T))"
}

# ---- both modes

cmd_wait() {
  require --run "$RUN" --id "$ID"
  setup_run
  load_worker
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  if [ "$(wf mode)" = B ]; then
    mode_b_worker
    wait_b
  else
    wait_a
  fi
}

LIVE=null
live_json() {  # LIVE: what Herdr and the process table say now about the current worker
  local present=false agent=null fresh=false ra=false
  LIVE=null
  [ "$(wf state)" != closed ] || return 0
  if pane_present; then
    present=true
    agent=$(jq -c '.result.pane | {agent, agent_status, display_agent}' <<< "$HOUT")
  fi
  if [ "$(wf mode)" = A ]; then
    read_started || true
    supervisor_alive && ra=true
    read_exit_record || true
    LIVE=$(jq -cn --argjson p "$present" --argjson a "$agent" --argjson r "$ra" --arg x "$EXIT_REC" \
      '{pane_present: $p} + ($a // {}) + {supervisor_alive: $r, exit_record: (if $x == "" then null else ($x | fromjson | del(.token)) end)}')
  else
    report_fresh && fresh=true
    LIVE=$(jq -cn --argjson p "$present" --argjson a "$agent" --argjson f "$fresh" \
      '{pane_present: $p} + ($a // {}) + {report_written_this_turn: $f}')
  fi
}

cmd_status() {
  require --run "$RUN"
  setup_run
  local ids id items=() ws ws_open=false
  if [ -n "$ID" ]; then load_worker; ids=$ID; else ids=$(reg_read | jq -r '.workers[].id'); fi
  for id in $ids; do
    ID=$id
    load_worker
    live_json
    items+=("$(public | jq -c --argjson l "$LIVE" '. + {live: $l}')")
  done
  ws=$(reg_read | jq -r '.workspace.id // empty')
  if [ -n "$ws" ] && ws_ours "$ws"; then ws_open=true; fi
  emit 0 "$(printf '%s\n' "${items[@]}" | jq -cs --argjson reg "$(reg_read)" --argjson wo "$ws_open" \
    '{run: $reg.run, workspace: (if $reg.workspace == null then null else $reg.workspace + {holds_open_workers: $wo} end),
      workers: map(select(. != null))}')"
}

cmd_state() {
  require --run "$RUN" --id "$ID" --state "$STATE"
  setup_run
  case $STATE in working|blocked|idle) ;; *) fail 64 usage "--state must be working, blocked or idle" ;; esac
  load_worker
  [ "$(wf mode)" = A ] || fail 64 usage "a mode B agent reports its own state to Herdr"
  case $(wf state) in closed|closing) fail 64 closed "worker $ID is $(wf state)" ;; esac
  pane_present || emit 4 "$(jq -c '{id, state, pane_gone: true}' <<< "$W")"
  report "$(wf pane_id)" "$STATE" "$MESSAGE" || herdr_fail pane report-agent
  update_worker '{shown: {state: $s, message: $m, at: $t}}' --arg s "$STATE" --arg m "$MESSAGE" --arg t "$(now)"
  emit 0 "$(jq -c '{id, state, shown}' <<< "$W")"
}

CLOSE_RESULT=""
close_pane() {  # close the worker's pane if Herdr still shows it, and confirm it is gone; PANE_CLOSED
  local i
  PANE_CLOSED=false
  pane_present || return 0
  if hcall pane close "$(wf pane_id)"; then
    PANE_CLOSED=true
  else
    [ "$(herr_code)" = pane_not_found ] || herdr_fail pane close
  fi
  for ((i = 0; i < 20; i++)); do pane_present || return 0; sleep 0.1; done
  fail 1 pane_not_closed "pane $(wf pane_id) is still open after pane close; the worker stays closing"
}
close_one() {  # stop and close the current worker; CLOSE_RESULT holds its result object
  local worker=not_running pg="" ls="" note=null was_live=0 already=false i
  PANE_CLOSED=false
  if [ "$(wf state)" = closed ]; then
    already=true
  else
    # closing first: a wait that sees the worker end from here on reports the close, not a finish, and a
    # close that fails or is cut short leaves closing, so the next close runs all of this again.
    transition closing '{closing_at: $t}' --arg t "$(now)"
    if [ "$(wf mode)" = A ]; then
      group_of_worker
      if [ -z "$PG" ] && [ ! -s "$OUT/$ID.exit" ] && pane_present; then
        # Still starting: its supervisor records the group moments after the runner starts.
        for ((i = 0; i < 50; i++)); do read_started && break; sleep 0.1; done
        group_of_worker
      fi
      group_ours "$PG" "$LS" && was_live=1
      close_pane
      # The supervisor may have recorded the group just now. The closed pane stops the worker through
      # it; stop_group checks the group, and finishes the stop if needed.
      [ -n "$PG" ] || group_of_worker
      stop_group "$PG" "$LS"
      worker=$STOPPED
      [ "$worker" != not_running ] || [ "$was_live" = 0 ] || worker=stopped
    else
      # Mode B: never a signal. While the pane hosts the recorded agent, note its process group (to
      # check, not to signal), send ctrl+c to the agent by name, and close the pane, which ends what
      # runs there. A pane no longer hosting it is closed with nothing signalled.
      worker=agent_gone
      if agent_check; then
        worker=stopped
        if hcall pane process-info --pane "$(wf pane_id)"; then
          pg=$(jq -r '.result.process_info | if .foreground_process_group_id == .shell_pid then empty
                      else .foreground_process_group_id end' <<< "$HOUT")
          [ -z "$pg" ] || ls=$(proc_field "$pg" 20)
        fi
        hcall agent send-keys "$(wf agent_name)" ctrl+c ctrl+c || true
        for ((i = 0; i < 30; i++)); do group_ours "$pg" "$ls" || break; sleep 0.1; done
      fi
      close_pane
      for ((i = 0; i < 50; i++)); do group_ours "$pg" "$ls" || break; sleep 0.1; done
      ! group_ours "$pg" "$ls" || worker=survived
    fi
    if [ "$worker" = survived ]; then
      update_worker '{close: {pane_closed: $p, worker: $w}}' --argjson p "$PANE_CLOSED" --arg w "$worker"
    else
      transition closed '{closed_at: $t, close: {pane_closed: $p, worker: $w}}' \
        --arg t "$(now)" --argjson p "$PANE_CLOSED" --arg w "$worker"
    fi
  fi
  if [ "$(wf harness)" = codex ] && [ "$(wf mode)" = A ]; then   # mode B Codex runs no companion
    note=$(jq -cn --arg py "$SCRIPT_DIR/cleanup-codex-companion.py" --arg ws "$(wf checkout)" \
      '{argv: ["python3", $py, "--workspace", $ws, "--execute"],
        note: "its companion runtime outlives the pane: run this once its result is collected"}')
  fi
  CLOSE_RESULT=$(jq -c --argjson p "$PANE_CLOSED" --arg w "$worker" --argjson n "$note" --argjson a "$already" \
    '{id, state, pane_id, pane_closed: $p, worker: $w} + (if $a then {already_closed: true} else {} end)
     + (if $n == null then {} else {codex_cleanup: $n} end)' <<< "$W")
}

cmd_close() {
  require --run "$RUN"
  setup_run
  if [ "$ALL" = 0 ]; then
    require --id "$ID"
    load_worker
    close_one
    if [ "$(jq -r .worker <<< "$CLOSE_RESULT")" = survived ]; then
      emit 1 "$(jq -c '{error: {code: "worker_survived", message: "the worker process group outlived TERM and KILL"}} + .' <<< "$CLOSE_RESULT")"
    fi
    emit 0 "$CLOSE_RESULT"
  fi
  [ -z "$ID" ] || fail 64 usage "close takes --id or --all, not both"
  local items=() id ws wlabel ws_closed=true others="[]" survived=0
  for id in $(reg_read | jq -r '.workers[].id'); do
    ID=$id
    load_worker
    close_one
    items+=("$CLOSE_RESULT")
    [ "$(jq -r .worker <<< "$CLOSE_RESULT")" != survived ] || survived=1
  done
  # Herdr removes the workspace with its last pane. Panes left in it are not this run's: report them.
  ws=$(reg_read | jq -r '.workspace.id // empty') wlabel=$(reg_read | jq -r '.workspace.label // empty')
  local i
  for ((i = 0; i < 10; i++)); do
    { [ -n "$ws" ] && hlook workspace get "$ws"; } || break
    sleep 0.2
  done
  if [ -n "$ws" ] && hlook workspace get "$ws" && [ "$(jq -r .result.workspace.label <<< "$HOUT")" = "$wlabel" ]; then
    ws_closed=false
    if hlook pane list --workspace "$ws"; then
      others=$(jq -c --argjson reg "$(reg_read)" \
        '[.result.panes[] | select(.terminal_id as $t | $reg.workers | map(.terminal_id) | index($t) | not) | .pane_id]' <<< "$HOUT")
    fi
  fi
  [ "$ws_closed" = false ] || reg_apply --arg t "$(now)" 'if .workspace == null then . else .workspace += {closed_at: $t} end'
  local result
  result=$(printf '%s\n' "${items[@]}" | jq -cs --argjson wc "$ws_closed" --argjson o "$others" \
    '{workers: map(select(. != null)), workspace_closed: $wc} + (if $o == [] then {} else {panes_not_in_registry: $o} end)')
  if [ "$survived" = 1 ]; then
    emit 1 "$(jq -c '{error: {code: "worker_survived", message: "a worker process group outlived TERM and KILL"}} + .' <<< "$result")"
  fi
  emit 0 "$result"
}

case $SUB in
  launch) cmd_launch ;;
  start) cmd_start ;;
  ready) cmd_ready ;;
  keys) cmd_keys ;;
  prompt) cmd_prompt ;;
  mcp) cmd_mcp ;;
  wait) cmd_wait ;;
  status) cmd_status ;;
  state) cmd_state ;;
  close) cmd_close ;;
  *) fail 64 usage "subcommand must be launch, start, ready, keys, prompt, mcp, wait, status, state or close (see the header of $0)" ;;
esac
