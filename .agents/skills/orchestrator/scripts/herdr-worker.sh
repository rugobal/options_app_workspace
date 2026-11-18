#!/usr/bin/env bash
# Orchestrator workers in Herdr: one labelled tab per worker, in one workspace per run.
#
#   herdr-worker.sh launch --run DIR --id ID --label TEXT --cwd DIR --harness claude|codex|deepseek|agy|plain
#                          --cmd-file FILE [--workspace-label TEXT]
#   herdr-worker.sh start  --run DIR --id ID --label TEXT --cwd DIR --kind claude|pi|agy --args-file FILE
#                          --report FILE [--name NAME] [--env KEY=VALUE]... [--timeout MS] [--workspace-label TEXT]
#   herdr-worker.sh prompt --run DIR --id ID --text-file FILE [--timeout MS]
#   herdr-worker.sh wait   --run DIR --id ID [--timeout MS]
#   herdr-worker.sh status --run DIR [--id ID]
#   herdr-worker.sh state  --run DIR --id ID --state working|blocked|idle [--message TEXT]
#   herdr-worker.sh close  --run DIR (--id ID | --all)
#
# launch (mode A): runs the shell command line in --cmd-file headless, as a background job in its own
#   session, with HERDR_ENV and HERDR_PANE_ID unset, so Herdr's own agent detection leaves the pane to
#   this script's report. stdout goes to out/<id>.log; stderr to out/<id>.err, or into the log for codex
#   and plain. The pane tails the log (claude and deepseek through stream.jq). At the end the runner
#   writes out/<id>.exit and prints the marker line "WORKER_DONE_<id> exit=<n>".
# start (mode B): an interactive agent started with `herdr agent start`, told what to do by `prompt`,
#   done when it has written the --report file. Codex is refused (decision 1c).
# wait: blocks until the worker is done. Mode A: the marker or the exit file. Mode B: the agent settles.
#
# The registry <run>/workers.json lists every worker; wait, status, state and close need only it, so a
# new conductor session adopts the workers of an earlier one. Herdr ids come from Herdr's JSON. The
# script only closes or sends keys to tabs and panes recorded in that registry.
#
# Every call prints one JSON object on stdout; "ok" is true exactly when the exit status is 0.
# Exit status:
#   0  done (wait: the worker finished, whatever its own exit_code; prompt: report written)
#   1  Herdr or internal error (JSON error.detail holds Herdr's error)
#   2  not inside Herdr (HERDR_ENV is not 1) or a tool missing: dispatch with background Bash instead
#   3  timeout: the worker is unaffected, wait again
#   4  pane or agent gone
#   5  mode B agent blocked at a dialog: the JSON holds the visible screen
#   6  mode B agent settled without writing its report
#   64 usage error, unknown or duplicate id
set -Eeuo pipefail

if [ "${HERDR_ENV:-}" != 1 ]; then
  printf '%s\n' '{"ok":false,"error":{"code":"not_in_herdr","message":"HERDR_ENV is not 1: dispatch with background Bash instead"}}'
  exit 2
fi
for tool in jq herdr flock setsid; do
  command -v "$tool" > /dev/null || {
    printf '{"ok":false,"error":{"code":"missing_tool","message":"%s is not on PATH"}}\n' "$tool"
    exit 2
  }
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SOURCE=custom:orchestrator
MARK=WORKER_DONE_

# ---- output and errors

CLEANUP_TAB=""   # a tab this call created for a worker that has not started; closed on failure

as_json() { jq -c . <<< "$1" 2> /dev/null || jq -cn --arg t "$1" '$t'; }

fail() {  # fail EXIT CODE MESSAGE [DETAIL_JSON]
  trap - ERR
  set +e
  local exit_status=$1 code=$2 message=$3 detail=${4:-null}
  if [ -n "$CLEANUP_TAB" ]; then
    herdr tab close "$CLEANUP_TAB" > /dev/null 2>&1
    [ -n "${REG:-}" ] && [ -f "$REG" ] && reg_apply --arg id "$ID" --arg t "$(now)" --arg m "$message" \
      '(.workers[] | select(.id == $id)) |= (. + {state: "closed", closed_at: $t, error: $m})'
  fi
  jq -cn --arg c "$code" --arg m "$message" --argjson d "$detail" \
    '{ok: false, error: ({code: $c, message: $m} + (if $d == null then {} else {detail: $d} end))}'
  exit "$exit_status"
}

trap 'fail 1 internal "line $LINENO: $BASH_COMMAND exited $?"' ERR

# ---- Herdr calls

HOUT="" HERR=""
hcall() {  # hcall ARGS...: herdr ARGS; stdout in HOUT, or stderr in HERR and status 1
  local ef
  ef=$(mktemp "${TMPDIR:-/tmp}/herdr-worker.XXXXXX")
  if HOUT=$(herdr "$@" 2> "$ef"); then
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
h() { hcall "$@" || fail 1 herdr_error "herdr $1 $2 failed" "$(as_json "$HERR")"; }

# ---- arguments

SUB=${1:-}
[ $# -gt 0 ] && shift
RUN="" ID="" LABEL="" CWD="" HARNESS="" CMD_FILE="" KIND="" NAME="" ARGS_FILE="" REPORT=""
TEXT_FILE="" TIMEOUT="" STATE="" MESSAGE="" WS_LABEL="" ALL=0
ENVS=()
while [ $# -gt 0 ]; do
  case $1 in
    --all) ALL=1; shift; continue ;;
    --run|--id|--label|--cwd|--harness|--cmd-file|--kind|--name|--args-file|--report|--text-file|--timeout|--state|--message|--workspace-label|--env)
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
    --name) NAME=$2 ;;
    --args-file) ARGS_FILE=$2 ;;
    --report) REPORT=$2 ;;
    --text-file) TEXT_FILE=$2 ;;
    --timeout) TIMEOUT=$2 ;;
    --state) STATE=$2 ;;
    --message) MESSAGE=$2 ;;
    --workspace-label) WS_LABEL=$2 ;;
    --env) ENVS+=("$2") ;;
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
now() { date -Iseconds; }
check_timeout() { [ -z "$TIMEOUT" ] || [[ $TIMEOUT =~ ^[0-9]+$ ]] || fail 64 usage "--timeout is in milliseconds"; }

setup_run() {
  [ -d "$RUN" ] || fail 64 usage "--run is not a directory: $RUN"
  RUN=$(cd "$RUN" && pwd -P)
  REG=$RUN/workers.json LOCK=$RUN/workers.lock OUT=$RUN/out
}
check_id() {
  [[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || fail 64 usage "--id takes letters, digits, - and _ (e.g. T41-1)"
}

# ---- registry: <run>/workers.json, rewritten whole (temp file, then rename) under a flock

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
reg_apply() {  # reg_apply [jq options...] FILTER
  local held=$LOCKED tmp=$REG.tmp.$$
  lock
  reg_read | jq "$@" > "$tmp"
  mv -f "$tmp" "$REG"
  [ "$held" = 1 ] || unlock
}

W=""   # the current worker's registry entry
load_worker() {
  W=$(reg_read | jq -c --arg id "$ID" '.workers[] | select(.id == $id)')
  [ -n "$W" ] || fail 64 unknown_id "no worker $ID in $REG"
}
wf() { jq -r --arg k "$1" '.[$k] // empty' <<< "$W"; }
update_worker() {  # update_worker OBJECT_EXPR [jq options...]: merged into the worker's entry
  local expr=$1
  shift
  # $gone: "gone", unless a close already marked the worker closed
  reg_apply --arg id "$ID" "$@" \
    "(.workers[] | select(.id == \$id)) |= ((if .state == \"closed\" then \"closed\" else \"gone\" end) as \$gone | . + ($expr))"
  W=$(reg_read | jq -c --arg id "$ID" '.workers[] | select(.id == $id)')
}

# ---- workspace and tab

default_ws_label() {  # w-<run slug>: the date prefix dropped, whole words up to 8 characters
  local base slug="" part parts
  base=$(basename "$RUN" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-?//')
  IFS=- read -ra parts <<< "${base:-run}"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    if [ -z "$slug" ]; then
      slug=${part:0:8}
    elif [ $(( ${#slug} + 1 + ${#part} )) -le 8 ]; then
      slug=$slug-$part
    else
      break
    fi
  done
  printf 'w-%s' "${slug:-run}"
}

open_tab() {  # open_tab CWD: sets WS, TAB and PANE; creates the run's workspace on first use. Under the lock.
  local cwd=$1 ws label env_args=() e
  for e in "${ENVS[@]}"; do env_args+=(--env "$e"); done
  ws=$(reg_read | jq -r '.workspace.id // empty')
  if [ -n "$ws" ] && hcall workspace get "$ws"; then
    h tab create --workspace "$ws" --label "$LABEL" --cwd "$cwd" "${env_args[@]}" --no-focus
    WS=$ws
  else
    label=${WS_LABEL:-$(default_ws_label)}
    h workspace create --label "$label" --cwd "$cwd" "${env_args[@]}" --no-focus
    WS=$(jq -r .result.workspace.workspace_id <<< "$HOUT")
    reg_apply --arg ws "$WS" --arg l "$label" --arg t "$(now)" '.workspace = {id: $ws, label: $l, created_at: $t}'
  fi
  TAB=$(jq -r .result.tab.tab_id <<< "$HOUT")
  PANE=$(jq -r .result.root_pane.pane_id <<< "$HOUT")
  CLEANUP_TAB=$TAB
  # A new workspace's own first tab becomes this worker's tab.
  [ "$(jq -r .result.tab.label <<< "$HOUT")" = "$LABEL" ] || h tab rename "$TAB" "$LABEL"
}

shell_is_foreground() {  # the pane's foreground is its own shell, alone
  hcall pane process-info --pane "$1" &&
    jq -e '.result.process_info | (.foreground_processes | length) == 1
           and .foreground_processes[0].pid == .shell_pid' <<< "$HOUT" > /dev/null
}
wait_shell() {  # wait_shell PANE [TRIES]: at most TRIES x 0.25 s (default 10 s)
  local i
  for ((i = 0; i < ${2:-40}; i++)); do
    if shell_is_foreground "$1"; then return 0; fi
    sleep 0.25
  done
  return 1
}
screen_text() {  # screen_text PANE: the visible screen (pane read prints plain text), or ""
  if hcall pane read "$1" --source visible; then printf '%s\n' "$HOUT"; fi
}

agent_label() {  # lower-case id plus harness, as Herdr agent names allow: t41-1-codex
  local n
  n=$(tr 'A-Z' 'a-z' <<< "$ID-$1" | tr -c 'a-z0-9_\n-' '-')
  [[ $n =~ ^[a-z] ]] || n=w$n
  printf '%s' "${n:0:32}"
}

report() {  # report STATE [MESSAGE]: the worker's pane shows STATE under its tab label
  local pane agent
  pane=$(wf pane_id)
  agent=$(wf agent_name)
  hcall pane report-agent "$pane" --source "$SOURCE" --agent "$agent" --state "$1" ${2:+--message "$2"} &&
    hcall pane report-metadata "$pane" --source "$SOURCE" --agent "$agent" --display-agent "$(wf label)"
}
report_took() {  # report_took STATE: Herdr shows the worker's label with STATE (an unseen idle reads "done")
  hcall pane get "$(wf pane_id)" &&
    jq -e --arg a "$(wf agent_name)" --arg s "$1" \
      '.result.pane | .agent == $a and (.agent_status == $s or ($s == "idle" and .agent_status == "done"))' \
      <<< "$HOUT" > /dev/null
}

# ---- mode A

write_runner() {
  local q_err="2>&1" view=""
  [ -z "$ERRF" ] || q_err="2> $(printf '%q' "$ERRF")"
  case $HARNESS in
    claude|deepseek) view=" | jq -rR --unbuffered -f $(printf '%q' "$SCRIPT_DIR/stream.jq")" ;;
  esac
  local q_agent q_label carry="" v
  q_agent=$(printf '%q' "$AGENT")
  q_label=$(printf '%q' "$LABEL")
  if [ "$HARNESS" = codex ]; then
    # The companion keeps its jobs under CLAUDE_PLUGIN_DATA, tagged with the Claude session; a pane
    # has neither. Carry the conductor's, so its status, result and cancel calls find the job.
    for v in CLAUDE_PLUGIN_DATA CODEX_COMPANION_SESSION_ID; do
      [ -z "${!v:-}" ] || carry+="export $v=$(printf '%q' "${!v}")"$'\n'
    done
  fi
  cat > "$RUNNER" << EOF
#!/usr/bin/env bash
# Worker $ID, written by herdr-worker.sh launch; its Herdr pane runs this file.
# The worker runs in its own session (setsid), outside the pane's foreground process group and
# without HERDR_ENV and HERDR_PANE_ID, so Herdr's agent detection leaves the pane to the
# orchestrator's report. The pane shows the log; a closed tab or Ctrl+C stops the worker.
cd $(printf '%q' "$CWD") || exit 1
log=$(printf '%q' "$LOG")
: > "\$log"
pane=\${HERDR_PANE_ID:-}
unset HERDR_ENV HERDR_PANE_ID
${carry}
setsid -w bash $(printf '%q' "$CMD_FILE") < /dev/null > "\$log" $q_err &
w=\$!
echo "\$w" > $(printf '%q' "$PIDF")
sig=-
stop() { sig=\$1; kill -TERM -- "-\$w" 2> /dev/null; }
trap 'stop INT' INT
trap 'stop TERM' TERM
trap 'stop HUP' HUP
tail -n +1 -f --pid="\$w" "\$log"$view
while :; do wait "\$w"; s=\$?; kill -0 "\$w" 2> /dev/null || break; done
echo "\$s \$sig" > $(printf '%q' "$EXITF.tmp") && mv -f $(printf '%q' "$EXITF.tmp") $(printf '%q' "$EXITF")
printf '\n%s%s exit=%d\n' '$MARK' '$ID' "\$s"
# Herdr drops a report once the bare shell is back in the foreground, so stay in the foreground
# and show the worker as finished until the conductor closes the tab. Ctrl+C gives the shell back.
trap 'kill "\$h" 2> /dev/null; exit 0' INT TERM HUP
if [ -n "\$pane" ]; then
  "\${HERDR_BIN_PATH:-herdr}" pane report-agent "\$pane" --source $SOURCE --agent $q_agent --state idle --message "finished, exit \$s" &&
    "\${HERDR_BIN_PATH:-herdr}" pane report-metadata "\$pane" --source $SOURCE --agent $q_agent --display-agent $q_label
fi > /dev/null 2>&1
while :; do sleep 86400 & h=\$!; wait "\$h"; done
EOF
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
  LOG=$OUT/$ID.log ERRF=$OUT/$ID.err RUNNER=$OUT/$ID.sh PIDF=$OUT/$ID.pid EXITF=$OUT/$ID.exit
  case $HARNESS in codex|plain) ERRF="" ;; esac
  AGENT=$(agent_label "$HARNESS")

  lock
  [ -z "$(reg_read | jq -r --arg id "$ID" '.workers[] | select(.id == $id) | .id')" ] ||
    fail 64 duplicate_id "worker $ID is already in $REG; a retry takes the next attempt number"
  rm -f "$PIDF" "$EXITF"
  write_runner
  open_tab "$CWD"
  reg_apply --arg id "$ID" --arg label "$LABEL" --arg h "$HARNESS" --arg agent "$AGENT" \
    --arg ws "$WS" --arg tab "$TAB" --arg pane "$PANE" --arg cwd "$CWD" --arg cmd "$CMD_FILE" \
    --arg runner "$RUNNER" --arg log "$LOG" --arg err "$ERRF" --arg t "$(now)" \
    '.workers += [{id: $id, label: $label, harness: $h, mode: "A", agent_name: $agent,
                   workspace_id: $ws, tab_id: $tab, pane_id: $pane, checkout: $cwd, cmd_file: $cmd,
                   runner: $runner, out_log: $log, out_err: (if $err == "" then null else $err end),
                   marker: ("WORKER_DONE_" + $id), state: "starting", exit_code: null,
                   started_at: $t, finished_at: null}]'
  unlock
  load_worker

  wait_shell "$PANE" || fail 1 shell_not_ready "the shell in pane $PANE was not at its prompt within 10 s"
  h pane run "$PANE" " bash $(printf '%q' "$RUNNER")"
  local i
  for ((i = 0; i < 60; i++)); do [ -s "$PIDF" ] && break; sleep 0.25; done
  [ -s "$PIDF" ] || fail 1 runner_not_started "the runner did not start within 15 s" "$(as_json "$(screen_text "$PANE")")"
  CLEANUP_TAB=""

  # The report binds to the pane's foreground process: send it once the runner is up, and again
  # until Herdr shows it. A worker already finished gets none (it would bind to the bare shell).
  local reported=false
  for ((i = 0; i < 20; i++)); do
    [ -e "$EXITF" ] && break
    if report working && report_took working; then reported=true; break; fi
    sleep 0.5
  done
  # A worker that ended during the loop: its runner's "finished" report may predate ours.
  if read_exit_file; then report idle "finished, exit $EXIT_CODE" || true; fi
  update_worker '{state: "running"}'
  jq -c --argjson r "$reported" '{ok: true} + . + {reported: $r}' <<< "$W"
}

read_exit_file() {  # sets EXIT_CODE and EXIT_SIG from out/<id>.exit; false when the runner is not done
  local f=$OUT/$ID.exit
  [ -s "$f" ] || return 1
  read -r EXIT_CODE EXIT_SIG < "$f"
}

finish_a() {  # finish_a CODE: record the end, and show it under the tab label
  update_worker '{state: "finished", exit_code: ($c | tonumber), finished_at: $t}' --arg c "$1" --arg t "$(now)"
  # The runner reports this too and holds the pane; repeat it in case its own report missed.
  local i
  for ((i = 0; i < 6; i++)); do
    report idle "finished, exit $1" || return 0
    sleep 0.3
    if report_took idle; then return 0; fi
    sleep 0.5
  done
}

wait_a() {
  local pane code line T=${TIMEOUT:-7000000}
  pane=$(wf pane_id)
  emit_wait() {  # emit_wait EXIT TIMED_OUT PANE_GONE
    jq -c --argjson ok "$([ "$1" = 0 ] && echo true || echo false)" --argjson to "$2" --argjson pg "$3" \
      '{ok: $ok, id, exit_code, timed_out: $to, pane_gone: $pg, state, out_log}' <<< "$W"
    exit "$1"
  }
  [ -z "$(wf finished_at)" ] || emit_wait 0 false false
  if read_exit_file; then finish_a "$EXIT_CODE"; emit_wait 0 false false; fi
  if hcall pane wait-output "$pane" --regex "(?m)^${MARK}${ID} exit=\\d+" --timeout "$T"; then
    line=$(jq -r '.result.matched_line' <<< "$HOUT")
    code=${line##*exit=}
    finish_a "$code"
    emit_wait 0 false false
  fi
  case $(herr_code) in
    timeout)
      if read_exit_file; then finish_a "$EXIT_CODE"; emit_wait 0 false false; fi
      emit_wait 3 true false ;;
    pane_not_found|tab_not_found|not_found)
      # Done before its tab closed: finished. Stopped by the close (signal set) or never done: gone.
      if read_exit_file && [ "$EXIT_SIG" = - ]; then
        update_worker '{state: "finished", exit_code: ($c | tonumber), finished_at: $t}' --arg c "$EXIT_CODE" --arg t "$(now)"
        emit_wait 0 false true
      fi
      if read_exit_file; then
        update_worker '{state: $gone, exit_code: ($c | tonumber), finished_at: $t}' --arg c "$EXIT_CODE" --arg t "$(now)"
      else
        update_worker '{state: $gone}'
      fi
      emit_wait 4 false true ;;
    *) fail 1 herdr_error "herdr pane wait-output failed" "$(as_json "$HERR")" ;;
  esac
}

worker_pid_alive() {  # the worker started by this registry entry still runs; sets WPID
  local pidf=$OUT/$ID.pid
  WPID=""
  [ -s "$pidf" ] || return 1
  WPID=$(< "$pidf")
  [ -r "/proc/$WPID/cmdline" ] && tr '\0' ' ' < "/proc/$WPID/cmdline" | grep -qF -- "$(wf cmd_file)"
}

# ---- mode B

agent_get() {  # agent_get: AGENT_STATUS and SESSION_ID of the worker's agent; false when it is gone
  hcall agent get "$(wf agent_name)" || return 1
  AGENT_STATUS=$(jq -r '(.result.agent // .result).agent_status // "unknown"' <<< "$HOUT")
  SESSION_ID=$(jq -r '(.result.agent // .result).agent_session.value // empty' <<< "$HOUT")
}

report_updated() {  # the report file exists, is non-empty, and was written after the last prompt
  local report since m
  report=$(wf report)
  since=$(wf prompted_at)
  [ -s "$report" ] || return 1
  [ -n "$since" ] || return 0
  m=$(stat -c '%.9Y' "$report")
  awk -v a="$m" -v b="$since" 'BEGIN { exit !(a > b) }'
}

emit_b() {  # emit_b EXIT [SCREEN]: the mode B worker's state after a prompt or wait
  local ready=false screen=${2:-}
  report_updated && ready=true
  jq -c --argjson ok "$([ "$1" = 0 ] && echo true || echo false)" --argjson ready "$ready" \
    --arg st "${AGENT_STATUS:-unknown}" --arg screen "$screen" \
    '{ok: $ok, id, agent_name, agent_status: $st, state, report, report_ready: $ready, session_id}
     + (if $screen == "" then {} else {screen: $screen} end)' <<< "$W"
  exit "$1"
}

blocked_b() {  # the agent waits at a dialog: record it and show the screen; answer nothing
  update_worker '{state: "blocked"}'
  AGENT_STATUS=blocked
  emit_b 5 "$(screen_text "$(wf pane_id)")"
}

settle_b() {  # settle_b DEADLINE: after a settled return, look until the report is written or time is up
  local rechecked=0
  while :; do
    agent_get || { update_worker '{state: $gone}'; AGENT_STATUS=gone; emit_b 4; }
    [ -z "$SESSION_ID" ] || update_worker '{session_id: $s}' --arg s "$SESSION_ID"
    [ "$AGENT_STATUS" != blocked ] || blocked_b
    if report_updated; then update_worker '{state: $s}' --arg s "$AGENT_STATUS"; emit_b 0; fi
    local left=$(( $1 - $(date +%s) ))
    [ "$left" -gt 0 ] || { update_worker '{state: $s}' --arg s "$AGENT_STATUS"; emit_b 3; }
    if [ "$AGENT_STATUS" = working ]; then
      hcall agent wait "$(wf agent_name)" --timeout $(( left * 1000 )) || true
      continue
    fi
    # An early idle can come before the turn's work: look once more after a pause.
    if [ "$rechecked" = 0 ]; then rechecked=1; sleep 3; continue; fi
    update_worker '{state: $s}' --arg s "$AGENT_STATUS"
    emit_b 6 "$(screen_text "$(wf pane_id)" | tail -n 25)"
  done
}

cmd_start() {
  require --run "$RUN" --id "$ID" --label "$LABEL" --cwd "$CWD" --kind "$KIND" --args-file "$ARGS_FILE" --report "$REPORT"
  setup_run
  check_id
  check_timeout
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
  NAME=${NAME:-$(agent_label "$KIND")}
  [[ $NAME =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || fail 64 usage "--name must match [a-z][a-z0-9_-]{0,31}"
  local -a native=()
  eval "native=( $(< "$ARGS_FILE") )"

  lock
  [ -z "$(reg_read | jq -r --arg id "$ID" '.workers[] | select(.id == $id) | .id')" ] ||
    fail 64 duplicate_id "worker $ID is already in $REG; a retry takes the next attempt number"
  open_tab "$CWD"
  reg_apply --arg id "$ID" --arg label "$LABEL" --arg k "$KIND" --arg name "$NAME" \
    --arg ws "$WS" --arg tab "$TAB" --arg pane "$PANE" --arg cwd "$CWD" --arg report "$REPORT" --arg t "$(now)" \
    '.workers += [{id: $id, label: $label, harness: $k, mode: "B", agent_name: $name,
                   workspace_id: $ws, tab_id: $tab, pane_id: $pane, checkout: $cwd, report: $report,
                   session_id: null, state: "starting", started_at: $t, prompted_at: null, finished_at: null}]'
  unlock
  load_worker

  wait_shell "$PANE" || fail 1 shell_not_ready "the shell in pane $PANE was not at its prompt within 10 s"
  if ! hcall agent start "$NAME" --kind "$KIND" --pane "$PANE" --timeout "${TIMEOUT:-60000}" -- "${native[@]}"; then
    case $(herr_code) in
      agent_not_ready) CLEANUP_TAB=""; blocked_b ;;
      *) fail 1 herdr_error "herdr agent start failed" "$(as_json "$HERR")" ;;
    esac
  fi
  CLEANUP_TAB=""
  if [ "$KIND" = pi ]; then
    # Pi can show a "Press any key to continue" splash while Herdr already reports it idle.
    local i
    for ((i = 0; i < 10; i++)); do
      screen_text "$PANE" | grep -q 'Press any key' || break
      hcall pane send-keys "$PANE" esc || true
      sleep 0.5
    done
  fi
  agent_get || fail 1 herdr_error "the agent left its pane after starting" "$(as_json "$HERR")"
  [ "$AGENT_STATUS" != blocked ] || blocked_b
  update_worker '{state: $s, session_id: (if $sid == "" then null else $sid end)}' --arg s "$AGENT_STATUS" --arg sid "$SESSION_ID"
  emit_b 0
}

cmd_prompt() {
  require --run "$RUN" --id "$ID" --text-file "$TEXT_FILE"
  setup_run
  check_timeout
  load_worker
  [ "$(wf mode)" = B ] || fail 64 usage "prompt is for mode B workers; $ID is mode A"
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  [ -f "$TEXT_FILE" ] || fail 64 usage "--text-file not found: $TEXT_FILE"
  local T=${TIMEOUT:-7000000} deadline before
  deadline=$(( $(date +%s) + T / 1000 ))
  before=$(wf prompted_at)
  update_worker '{prompted_at: $t, state: "working"}' --arg t "$(date +%s.%N)"
  if ! hcall agent prompt "$(wf agent_name)" "$(< "$TEXT_FILE")" --wait --timeout "$T"; then
    case $(herr_code) in
      agent_blocked)  # refused before sending: the earlier prompt is still the one to answer
        update_worker '{prompted_at: (if $b == "" then null else $b end)}' --arg b "$before"
        blocked_b ;;
      timeout) agent_get || true; emit_b 3 ;;
      agent_not_found|pane_not_found|not_found) update_worker '{state: $gone}'; AGENT_STATUS=gone; emit_b 4 ;;
      agent_prompt_stalled) agent_get || true; emit_b 6 "$(screen_text "$(wf pane_id)" | tail -n 25)" ;;
      *) fail 1 herdr_error "herdr agent prompt failed" "$(as_json "$HERR")" ;;
    esac
  fi
  settle_b "$deadline"
}

wait_b() {
  local T=${TIMEOUT:-7000000} deadline
  deadline=$(( $(date +%s) + T / 1000 ))
  if ! hcall agent wait "$(wf agent_name)" --timeout "$T"; then
    case $(herr_code) in
      timeout) agent_get || true; emit_b 3 ;;
      agent_not_found|pane_not_found|not_found) update_worker '{state: $gone}'; AGENT_STATUS=gone; emit_b 4 ;;
      *) fail 1 herdr_error "herdr agent wait failed" "$(as_json "$HERR")" ;;
    esac
  fi
  settle_b "$deadline"
}

# ---- both modes

cmd_wait() {
  require --run "$RUN" --id "$ID"
  setup_run
  check_timeout
  load_worker
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  if [ "$(wf mode)" = B ]; then wait_b; else wait_a; fi
}

live_json() {  # what Herdr says now about the worker's pane
  local pane exists=false agent=null marker=null report_ready=null
  pane=$(wf pane_id)
  if hcall pane get "$pane"; then
    exists=true
    agent=$(jq -c '.result.pane | {agent, agent_status, display_agent}' <<< "$HOUT")
  fi
  if [ "$(wf mode)" = A ]; then
    marker=false
    [ "$exists" = true ] && hcall pane wait-output "$pane" --regex "(?m)^${MARK}${ID} exit=\\d+" --timeout 200 && marker=true
  else
    report_ready=false
    [ -s "$(wf report)" ] && report_ready=true
  fi
  jq -cn --argjson e "$exists" --argjson a "$agent" --argjson m "$marker" --argjson r "$report_ready" \
    '{pane_exists: $e} + ($a // {}) + (if $m == null then {} else {marker_seen: $m} end)
     + (if $r == null then {} else {report_ready: $r} end)'
}

cmd_status() {
  require --run "$RUN"
  setup_run
  local ids id items=() ws ws_exists=false live
  if [ -n "$ID" ]; then load_worker; ids=$ID; else ids=$(reg_read | jq -r '.workers[].id'); fi
  for id in $ids; do
    ID=$id
    load_worker
    if [ "$(wf state)" = closed ]; then live=null; else live=$(live_json); fi
    items+=("$(jq -c --argjson l "$live" '. + {live: $l}' <<< "$W")")
  done
  ws=$(reg_read | jq -r '.workspace.id // empty')
  [ -n "$ws" ] && hcall workspace get "$ws" && ws_exists=true
  printf '%s\n' "${items[@]}" | jq -cs --argjson reg "$(reg_read)" --argjson we "$ws_exists" \
    '{ok: true, run: $reg.run, workspace: (if $reg.workspace == null then null else $reg.workspace + {exists: $we} end), workers: .}'
}

cmd_state() {
  require --run "$RUN" --id "$ID" --state "$STATE"
  setup_run
  case $STATE in working|blocked|idle) ;; *) fail 64 usage "--state must be working, blocked or idle" ;; esac
  load_worker
  [ "$(wf mode)" = A ] || fail 64 usage "a mode B agent reports its own state to Herdr"
  [ "$(wf state)" != closed ] || fail 64 closed "worker $ID is closed"
  if ! report "$STATE" "$MESSAGE"; then
    case $(herr_code) in
      pane_not_found|not_found) update_worker '{state: $gone}'; jq -c '{ok: false, id, state, pane_gone: true}' <<< "$W"; exit 4 ;;
      *) fail 1 herdr_error "herdr pane report failed" "$(as_json "$HERR")" ;;
    esac
  fi
  update_worker '{state: $s}' --arg s "$STATE"
  jq -c --arg m "$MESSAGE" '{ok: true, id, state, message: $m}' <<< "$W"
}

close_one() {  # close the current worker's tab; prints its result object
  local stopped=false note=null i
  if [ "$(wf state)" != closed ]; then
    if ! hcall tab close "$(wf tab_id)"; then
      case $(herr_code) in
        tab_not_found|pane_not_found|not_found) ;;
        *) fail 1 herdr_error "herdr tab close failed" "$(as_json "$HERR")" ;;
      esac
    fi
    # The closed tab hangs up the runner, which stops its worker; check that it did.
    if [ "$(wf mode)" = A ]; then
      for ((i = 0; i < 12; i++)); do worker_pid_alive || break; sleep 0.25; done
      if worker_pid_alive; then kill -TERM -- "-$WPID" 2> /dev/null || true; stopped=true; fi
    fi
    update_worker '{state: "closed", closed_at: $t}' --arg t "$(now)"
  fi
  [ "$(wf harness)" != codex ] ||
    note=$(jq -cn --arg c "python3 $SCRIPT_DIR/cleanup-codex-companion.py --workspace $(printf '%q' "$(wf checkout)") --execute" \
      '"Codex: its companion broker outlives the tab. Run the cleanup helper for this checkout when the result is in: " + $c')
  jq -c --argjson s "$stopped" --argjson n "$note" \
    '{id, state, tab_id, killed_worker: $s} + (if $n == null then {} else {codex_cleanup: $n} end)' <<< "$W"
}

cmd_close() {
  require --run "$RUN"
  setup_run
  if [ "$ALL" = 0 ]; then
    require --id "$ID"
    load_worker
    close_one | jq -c '{ok: true} + .'
    return
  fi
  [ -z "$ID" ] || fail 64 usage "close takes --id or --all, not both"
  local items=() id ws others="[]" ws_closed=false
  for id in $(reg_read | jq -r '.workers[].id'); do
    ID=$id
    load_worker
    items+=("$(close_one)")
  done
  ws=$(reg_read | jq -r '.workspace.id // empty')
  if [ -n "$ws" ] && hcall workspace get "$ws" && hcall tab list --workspace "$ws"; then
    # Close the workspace only when every tab left in it is one of the registry's.
    others=$(jq -c --argjson reg "$(reg_read)" '[.result.tabs[].tab_id] - [$reg.workers[].tab_id]' <<< "$HOUT")
    if [ "$others" = "[]" ]; then
      h workspace close "$ws"
      ws_closed=true
    fi
  else
    ws_closed=true
  fi
  [ "$ws_closed" = false ] || reg_apply --arg t "$(now)" 'if .workspace == null then . else .workspace += {closed_at: $t} end'
  printf '%s\n' "${items[@]}" | jq -cs --argjson wc "$ws_closed" --argjson o "$others" \
    '{ok: true, workers: ., workspace_closed: $wc} + (if $o == [] then {} else {tabs_not_in_registry: $o} end)'
}

case $SUB in
  launch) cmd_launch ;;
  start) cmd_start ;;
  prompt) cmd_prompt ;;
  wait) cmd_wait ;;
  status) cmd_status ;;
  state) cmd_state ;;
  close) cmd_close ;;
  *) fail 64 usage "subcommand must be launch, start, prompt, wait, status, state or close (see the header of $0)" ;;
esac
