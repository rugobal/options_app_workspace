#!/usr/bin/env bash
# Orchestrator workers in Herdr: one labelled tab per worker, in one workspace per run.
#
#   herdr-worker.sh launch --run DIR --id ID --label TEXT --cwd DIR --harness claude|codex|deepseek|agy|plain
#                          --cmd-file FILE [--workspace-label TEXT]
#   herdr-worker.sh start  --run DIR --id ID --label TEXT --cwd DIR --kind claude|pi|agy --args-file FILE
#                          --report FILE [--env KEY=VALUE]... [--timeout MS] [--workspace-label TEXT]
#   herdr-worker.sh ready  --run DIR --id ID [--timeout MS]
#   herdr-worker.sh keys   --run DIR --id ID --keys "KEY [KEY]..."
#   herdr-worker.sh prompt --run DIR --id ID --text-file FILE [--timeout MS]
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
#   settled and the --report file was written during that turn. An args file holds one agent argument
#   per line, taken literally (no shell expansion); empty lines are skipped. Codex is refused (1c).
# keys sends keys (Herdr key names) to a mode B agent's pane, to answer a dialog.
# wait blocks until the worker's outcome is known. Mode A: the exit record. Mode B: the delivered turn
#   settles. It never stops a worker, except a mode A worker whose pane and supervisor are both gone.
# close stops the worker (its verified process group: TERM, KILL after 5 s), closes its pane and marks
#   it closed. A pane the user split off in the same tab stays. Herdr removes a tab with its last pane
#   and a workspace with its last tab; this script never closes a tab or a workspace itself.
#
# Ownership. The registry <run>/workers.json records the canonical run path; a registry whose path is
# not --run is refused. Herdr reuses ids, so a stored pane is the worker's only while Herdr shows it with
# the recorded terminal_id in the recorded workspace, and a mode B pane only while it hosts the recorded
# agent; a process group is the worker's only while its leader has the recorded start time. Agent names
# carry the run: <run slug>-<4 hex of the run path>-<id>-<harness>, at most 32 characters.
#
# Lifecycle (the registry's state). Mode A: starting, running, then finished (exit record, no stop
# signal), stopped (exit record after a closed pane, Ctrl+C or TERM) or lost (the supervisor died
# without a record). Mode B: starting, ready, working, reported (this turn's report is in), settled (the turn
# ended without it), blocked (a dialog), gone. Then closed. closed is final; finished, stopped, lost and
# gone change only to closed. `state` sets the mark Herdr shows (registry: shown), not the lifecycle.
#
# Every call prints exactly one JSON object on stdout; "ok" is true exactly when the exit status is 0.
# Exit status:
#   0  done. wait: the worker finished (mode A: its own status is exit_code; mode B: the turn's report).
#   1  Herdr or internal error (error.detail holds Herdr's error), or close could not stop a worker.
#   2  not inside Herdr (HERDR_ENV is not 1) or a tool missing: dispatch with background Bash instead.
#   3  timeout, nothing changed; start/ready: the agent is not ready yet (no dialog).
#   4  gone or stopped: the pane or agent is gone, or the mode A worker was stopped by a signal.
#   5  mode B agent at a dialog: the JSON holds the visible screen.
#   6  mode B agent settled without writing this turn's report.
#   7  mode A worker lost: its supervisor died without an exit record; the exit code is unknown.
#   64 usage error, unknown or duplicate id, closed worker, or a registry from another run.
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
FAILF=$(mktemp "${TMPDIR:-/tmp}/herdr-worker.XXXXXX")
EMITTED=0
CLEANUP_PANE=""   # a pane this call created and has not handed over yet: closed on failure
CREATING=0        # a create call is under way: on failure, its pane is read from HOUT
CLEANUP_PGID="" CLEANUP_LSTART=""

on_exit() {
  [ "$EMITTED" = 1 ] || printf '%s\n' '{"ok":false,"error":{"code":"internal","message":"exited without a result"}}'
  rm -f "$FAILF"
}
trap on_exit EXIT

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
  cleanup_after_failure "$(jq -r '.error.message' <<< "$json")"
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

# ---- Herdr calls

HOUT="" HERR=""
hcall() {  # hcall ARGS...: herdr ARGS; stdout in HOUT, or stderr in HERR and status 1
  local ef
  ef=$(mktemp "${TMPDIR:-/tmp}/herdr-worker.XXXXXX")
  if HOUT=$("$HERDR_BIN" "$@" 2> "$ef"); then
    HERR=""
    rm -f "$ef"
    return 0
  fi
  HERR=$(< "$ef")
  rm -f "$ef"
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
transition() {  # transition NEW PATCH [jq options...]: move to state NEW and merge PATCH, if the lifecycle allows
  local new=$1 patch=$2
  shift 2
  reg_apply --arg id "$ID" --arg new "$new" "$@" '
    (.workers[] | select(.id == $id)) |=
      (if .state == "closed"
          or (.state != $new and $new != "closed" and (.state | IN("finished", "stopped", "lost", "gone")))
       then .
       else . + ('"$patch"') + {state: $new} end)'
  reload_worker
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
  [ -z "$CLEANUP_PGID" ] || stop_group "$CLEANUP_PGID" "$CLEANUP_LSTART"
  "$HERDR_BIN" pane close "$pane" > /dev/null 2>&1
  [ -z "${REG:-}" ] || [ -z "$ID" ] ||
    reg_try --arg id "$ID" --arg t "$(now)" --arg m "$1" \
      '(.workers[] | select(.id == $id)) |= (. + {state: "closed", closed_at: $t, error: $m})'
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
w="" sig="" killer="" watcher="" reaped=""
pfield() { awk -v n="$2" '{ sub(/^.*\) /, ""); print $n }' "/proc/$1/stat" 2> /dev/null; }
stop() {
  [ -z "$reaped" ] || return 0
  [ -n "$sig" ] || sig=$1
  [ -n "$w" ] || return 0
  kill -TERM -- "-$w" 2> /dev/null
  if [ -z "$killer" ]; then
    (trap - USR1 TERM HUP; sleep "$grace"; kill -KILL -- "-$w" 2> /dev/null) &
    killer=$!
  fi
}
trap 'stop HUP' HUP
trap 'stop INT' USR1
trap 'stop TERM' TERM
group_left() {  # a member of the worker's group that has not exited
  local p
  for p in $(pgrep -g "$w" -s "$w" 2> /dev/null); do
    [ "$(pfield "$p" 1)" = Z ] || return 0
  done
  return 1
}
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
  kill -HUP $$
) &
watcher=$!
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
kill "$watcher" 2> /dev/null
# What the worker left in its group is stopped too: a finished worker leaves nothing running.
stray=false
if group_left; then
  stray=true
  kill -TERM -- "-$w" 2> /dev/null
  i=0; while group_left && [ $i -lt $((grace * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$w" 2> /dev/null
  i=0; while group_left && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
fi
cleared=true
group_left && cleared=false
[ -z "$killer" ] || kill "$killer" 2> /dev/null
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
s="" w="" t=""
fwd() { [ -z "$s" ] || kill -"$1" "$s" 2> /dev/null; }
trap 'fwd HUP; exit 0' HUP
trap 'fwd USR1' INT
trap 'fwd TERM' TERM
pstart() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2> /dev/null; }
cd "$cwd" || exit 1
: > "$log"
unset HERDR_ENV HERDR_PANE_ID
setsid bash "$sup" "$$" "$(pstart $$)" < /dev/null > "$suplog" 2>&1 &
s=$!
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
    *) ex=4 ;;   # stopped, or closed while this wait ran
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
    case $(wf state) in finished|stopped|lost|closed) emit_outcome ;; esac
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
      sleep "$([ "$marker_seen" = 1 ] && echo 2 || echo 1)"
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
    '{id, agent_name, agent_status: $st, state, turn, report_turn, report,
      report_ready: (.turn > 0 and .report_turn == .turn), session_id}
     + (if $sc == "" then {} else {screen: $sc} end)' <<< "$W")"
}
gone_b() { transition gone '{}'; AGENT_STATUS=gone; emit_b 4; }
blocked_b() { transition blocked '{}'; AGENT_STATUS=blocked; emit_b 5 "$(screen_text)"; }

blocked_grace() {  # Herdr can show blocked for a moment after a dialog is answered: allow 3 s for a change
  [ "$BLOCKED_SEEN" = 0 ] || return 1
  BLOCKED_SEEN=1
  if ! hcall agent wait "$(wf pane_id)" --until idle --until done --until working --timeout 3000; then
    case $(herr_code) in timeout|agent_not_found|pane_not_found) ;; *) herdr_fail agent wait ;; esac
  fi
}
BLOCKED_SEEN=0

startup_settle() {  # startup_settle DEADLINE_MS: classify a starting agent as ready, at a dialog, or not ready yet
  local left splash=0
  while :; do
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
    [ -z "$SESSION_ID" ] || update_worker '{session_id: $s}' --arg s "$SESSION_ID"
    case $AGENT_STATUS in
      blocked) if blocked_grace; then continue; fi; blocked_b ;;
      idle|done) transition ready '{}'; emit_b 0 ;;
    esac
    left=$((${1} - $(now_ms)))
    if [ "$left" -lt 100 ]; then
      transition starting '{}'
      emit_b 3 "$(screen_text | tail -n 25)"
    fi
    if [ "$AGENT_STATUS" = absent ]; then
      sleep 1   # Herdr has not seen the agent in its pane yet
    elif ! hcall agent wait "$(wf pane_id)" --until idle --until done --until blocked --timeout "$((left < 30000 ? left : 30000))"; then
      case $(herr_code) in timeout|agent_not_found|pane_not_found) ;; *) herdr_fail agent wait ;; esac
    fi
  done
}

settle_b() {  # settle_b DEADLINE_MS: after a delivered prompt, until the turn ends or time is up
  local rechecked=0 left
  while :; do
    agent_check || gone_b
    [ -z "$SESSION_ID" ] || update_worker '{session_id: $s}' --arg s "$SESSION_ID"
    case $AGENT_STATUS in
      blocked) if blocked_grace; then continue; fi; blocked_b ;;
      idle|done)
        if report_fresh; then transition reported '{report_turn: .turn}'; emit_b 0; fi
        # An early idle can come before the turn's work: look once more after a pause.
        if [ "$rechecked" = 0 ]; then rechecked=1; sleep 3; continue; fi
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
read_args() {  # one argument per line, taken literally; empty lines are skipped, a trailing CR dropped
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
  parse_timeout 60000
  case $KIND in
    claude|pi|agy) ;;
    codex) fail 64 codex_mode_a_only "Codex workers run in mode A only (decision 1c): interactive Codex stops at a trust dialog in every new worktree" ;;
    *) fail 64 usage "--kind must be claude, pi or agy" ;;
  esac
  [ -d "$CWD" ] || fail 64 usage "--cwd is not a directory: $CWD"
  [ -f "$ARGS_FILE" ] || fail 64 usage "--args-file not found: $ARGS_FILE"
  local e
  for e in "${ENVS[@]}"; do [[ $e =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || fail 64 usage "--env takes KEY=VALUE: $e"; done
  CWD=$(cd "$CWD" && pwd -P)
  REPORT=$(abs "$REPORT")
  read_args
  local name deadline entry
  name=$(agent_name "$KIND")
  ! hlook agent get "$name" || fail 1 agent_name_taken "an agent named $name already runs in Herdr"
  entry=$(jq -cn --arg id "$ID" --arg label "$LABEL" --arg k "$KIND" --arg name "$name" --arg cwd "$CWD" \
    --arg report "$REPORT" --arg t "$(now)" \
    '{id: $id, label: $label, harness: $k, mode: "B", agent_name: $name, checkout: $cwd, report: $report,
      session_id: null, state: "starting", turn: 0, report_turn: null, report_snapshot: null,
      prompted_at: null, started_at: $t}')

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
  startup_settle "$((deadline > $(now_ms) + 3000 ? deadline : $(now_ms) + 3000))"
}

mode_b_worker() {  # the current worker is an open mode B worker
  [ "$(wf mode)" = B ] || fail 64 usage "$SUB is for mode B workers; $ID is mode A"
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  [ "$(wf state)" != gone ] || { AGENT_STATUS=gone; emit_b 4; }
}

cmd_ready() {
  require --run "$RUN" --id "$ID"
  setup_run
  parse_timeout 60000
  load_worker
  mode_b_worker
  [ "$(wf turn)" = 0 ] || fail 64 usage "ready is for the first prompt; after a delivered prompt use wait"
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
  h pane send-keys "$(wf pane_id)" "${keys[@]}"
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
  case $AGENT_STATUS in
    blocked) blocked_b ;;
    working) fail 64 agent_working "agent $(wf agent_name) is still working: wait for its turn to end first" ;;
  esac
  local deadline before
  deadline=$(($(now_ms) + T))
  before=$(jq -c '{turn, report_snapshot, prompted_at}' <<< "$W")
  # The turn starts before the prompt goes out, so a report written by this turn always counts.
  transition working '{turn: (.turn + 1), report_snapshot: $s, prompted_at: $t}' --arg s "$(report_sig)" --arg t "$(now)"
  if ! hcall agent prompt "$(wf pane_id)" "$(< "$TEXT_FILE")" --wait --timeout "$T"; then
    case $(herr_code) in
      agent_blocked|agent_not_ready)  # refused before it was sent: the turn did not start
        transition blocked '$b' --argjson b "$before"
        AGENT_STATUS=blocked
        emit_b 5 "$(screen_text)" ;;
      timeout) agent_check || true; emit_b 3 ;;
      agent_not_found|pane_not_found) gone_b ;;
      agent_prompt_stalled) ;;   # sent, but no work seen yet: settle_b looks
      *) herdr_fail agent prompt ;;
    esac
  fi
  settle_b "$deadline"
}

wait_b() {
  [ "$(wf turn)" -gt 0 ] || fail 64 not_prompted "wait follows a delivered prompt; before the first prompt use ready"
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
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  pane_present || emit 4 "$(jq -c '{id, state, pane_gone: true}' <<< "$W")"
  report "$(wf pane_id)" "$STATE" "$MESSAGE" || herdr_fail pane report-agent
  update_worker '{shown: {state: $s, message: $m, at: $t}}' --arg s "$STATE" --arg m "$MESSAGE" --arg t "$(now)"
  emit 0 "$(jq -c '{id, state, shown}' <<< "$W")"
}

CLOSE_RESULT=""
close_one() {  # stop and close the current worker; CLOSE_RESULT holds its result object
  local pane_closed=false worker=not_running present=0 pg="" ls="" note=null was_live=0 already=false
  if [ "$(wf state)" = closed ]; then
    already=true
  else
    pane_present && present=1
    if [ "$(wf mode)" = A ]; then
      group_of_worker
      pg=$PG ls=$LS
    elif [ "$present" = 1 ] && hcall pane process-info --pane "$(wf pane_id)"; then
      # A mode B agent runs as the shell's foreground job, in a group of its own.
      pg=$(jq -r '.result.process_info | if .foreground_process_group_id == .shell_pid then empty
                  else .foreground_process_group_id end' <<< "$HOUT")
      [ -z "$pg" ] || ls=$(proc_field "$pg" 20)
    fi
    group_ours "$pg" "$ls" && was_live=1
    # Closed first: a wait that sees the worker end from here on reports the close, not a finish.
    transition closed '{closed_at: $t}' --arg t "$(now)"
    if [ "$present" = 1 ]; then
      if hcall pane close "$(wf pane_id)"; then
        pane_closed=true
      else
        [ "$(herr_code)" = pane_not_found ] || herdr_fail pane close
      fi
    fi
    # The closed pane stops the worker through its supervisor; stop_group checks, and finishes it.
    stop_group "$pg" "$ls"
    worker=$STOPPED
    [ "$worker" != not_running ] || [ "$was_live" = 0 ] || worker=stopped
    update_worker '{close: {pane_closed: $p, worker: $w}}' --argjson p "$pane_closed" --arg w "$worker"
  fi
  if [ "$(wf harness)" = codex ]; then
    note=$(jq -cn --arg py "$SCRIPT_DIR/cleanup-codex-companion.py" --arg ws "$(wf checkout)" \
      '{argv: ["python3", $py, "--workspace", $ws, "--execute"],
        note: "its companion runtime outlives the pane: run this once its result is collected"}')
  fi
  CLOSE_RESULT=$(jq -c --argjson p "$pane_closed" --arg w "$worker" --argjson n "$note" --argjson a "$already" \
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
  wait) cmd_wait ;;
  status) cmd_status ;;
  state) cmd_state ;;
  close) cmd_close ;;
  *) fail 64 usage "subcommand must be launch, start, ready, keys, prompt, wait, status, state or close (see the header of $0)" ;;
esac
