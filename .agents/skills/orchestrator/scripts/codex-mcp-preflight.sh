#!/usr/bin/env bash
# codex-mcp-preflight.sh: before a Codex worker's dispatch, the MCP servers, connectors, web tool and
# image generation it will have, read with no model turn, compared with what it may have.
#
#   codex-mcp-preflight.sh --cwd DIR [--list FILE | --args-file FILE] [--give-back SERVER=TOOL[,TOOL]... | --give-back web]...
#
# Companion worker (no --args-file): codex runs through codex-no-mcp/codex, the wrapper its dispatch
#   uses, with the list beside it, or with --list, a task's copy (absolute path; the dispatch sets the
#   same file as CODEX_NO_MCP_ARGS). CODEX_NO_MCP_ARGS from the caller's environment is never used.
# Mode B worker (--args-file): codex runs with the -c/--config and --enable/--disable pairs of the
#   worker's args file (one argument per line, as herdr-worker.sh reads it); -m, -a, -s, --add-dir and
#   a leading `resume <id>` are passed over; any other argument is a mismatch, as this check can't
#   mirror it.
# From DIR, twice: as is, and with DIR trusted in memory (Codex reads a checkout's .codex/config.toml
# only once the checkout is trusted, and the trust dialog or a companion task can save that trust in
# the user's config later), it reads:
#   `codex … mcp list --json`  every server of the user's config, of a trusted checkout's
#                              .codex/config.toml and of each enabled plugin, and whether it is enabled;
#   `codex … features list`    whether `apps` (the connectors) and `image_generation` are on;
#   `codex … app-server`       `config/read` from an app server that runs only for that request (no
#                              thread, no turn, no MCP server started; it ends when its input closes):
#                              `web_search`, the setting every web path follows (the hosted web tool,
#                              the standalone one and a model-selected search are all off at
#                              "disabled"); null when unset, which Codex reads as "cached", web on;
#   for each --give-back server, `codex … mcp get SERVER --json` (enabled_tools) and the plain
#                              `mcp get SERVER` (default_tools_approval_mode).
# Expected: every listed server disabled except the --give-back servers, which are listed, enabled,
# with enabled_tools exactly the tools named and default_tools_approval_mode auto; apps and
# image_generation false; web_search "disabled", or with --give-back web any other value.
# Not covered: a tool's own approval_mode (no command shows it: with --give-back the JSON lists the
# approval_mode lines of the user's config and the checkout's .codex/config.toml, for the user);
# Codex's own codex_tui server, which no setting removes (herdr-worker.sh mcp shows what a mode B
# worker really has connected); and managed requirements (requirements.toml, MDM), which can refuse
# web_search "disabled" at a turn.
# Prints one JSON object: {ok, route, cwd, codex, list|args_file, give_back, give_back_web,
# checks: {as_is, trusted}, mismatches, approval_lines?}. Exit 0 as expected; 1 a mismatch
# (mismatches says which); 2 a codex command failed or printed what can't be read (error); 64 usage.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WRAPPER=$HERE/codex-no-mcp/codex

out() { printf '%s\n' "$1"; exit "$2"; }
usage() { out "$(jq -cn --arg m "$1" '{ok: false, error: {code: "usage", message: $m}}')" 64; }
error() { out "$(jq -cn --arg m "$1" --arg d "${2:-}" '{ok: false, error: {code: "codex_failed", message: $m, detail: $d}}')" 2; }

CWD="" LIST="" ARGS_FILE="" WEB_BACK=false
GIVE=()
while [ $# -gt 0 ]; do
  case $1 in
    --cwd|--list|--args-file|--give-back) [ $# -ge 2 ] || usage "$1 takes a value" ;;
    *) usage "unknown argument: $1" ;;
  esac
  case $1 in
    --cwd) CWD=$2 ;;
    --list) LIST=$2 ;;
    --args-file) ARGS_FILE=$2 ;;
    --give-back)
      if [ "$2" = web ]; then WEB_BACK=true
      elif [[ $2 =~ ^[A-Za-z0-9_-]+=[^,]+(,[^,]+)*$ ]]; then GIVE+=("$2")
      else usage "--give-back takes SERVER=TOOL[,TOOL]... or web: $2"
      fi ;;
  esac
  shift 2
done
[ -n "$CWD" ] || usage "--cwd is required"
[ -d "$CWD" ] || usage "--cwd is not a directory: $CWD"
CWD=$(cd "$CWD" && pwd -P)
[ -z "$LIST" ] || [ -z "$ARGS_FILE" ] || usage "--list is for a companion worker, --args-file for a mode B worker: not both"
[ -z "$LIST" ] || [[ $LIST == /* ]] || usage "--list takes an absolute path: $LIST"
[ -z "$LIST" ] || [ -r "$LIST" ] || usage "--list is not readable: $LIST"
[ -z "$ARGS_FILE" ] || [ -r "$ARGS_FILE" ] || usage "--args-file is not readable: $ARGS_FILE"
GIVE_JSON=$(printf '%s\n' "${GIVE[@]}" | jq -R 'select(. != "") | split("=") | {(.[0]): (.[1] | split(",") | sort)}' | jq -cs 'add // {}')

MISMATCH=()
CONFIG=()   # the pairs from a mode B args file
if [ -n "$ARGS_FILE" ]; then
  mapfile -t lines < <(sed -e 's/\r$//' -e '/^$/d' "$ARGS_FILE")
  i=0
  [ "${lines[0]:-}" != resume ] || i=2
  while [ "$i" -lt "${#lines[@]}" ]; do
    a=${lines[i]}
    case $a in
      -c|--config|--enable|--disable)
        [ $((i + 1)) -lt "${#lines[@]}" ] || { MISMATCH+=("args file: $a has no value"); break; }
        CONFIG+=("$a" "${lines[i + 1]}"); i=$((i + 2)) ;;
      -m|--model|-a|--ask-for-approval|-s|--sandbox|--add-dir) i=$((i + 2)) ;;
      *) MISMATCH+=("args file: an argument this check can't mirror: $a"); i=$((i + 1)) ;;
    esac
  done
  # Mode B runs the real codex: the first absolute PATH folder with an executable codex that isn't
  # the wrapper (what the wrapper itself would run).
  CODEX=""
  IFS=: read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [[ $d == /* ]] && [ -f "$d/codex" ] && [ -x "$d/codex" ] && ! [ "$d/codex" -ef "$WRAPPER" ] || continue
    CODEX=$d/codex
    break
  done
  [ -n "$CODEX" ] || error "no codex in PATH"
  ROUTE=mode_b
  CMD=("$CODEX" "${CONFIG[@]}")
else
  CODEX=$WRAPPER
  ROUTE=companion
  if [ -n "$LIST" ]; then CMD=(env CODEX_NO_MCP_ARGS="$LIST" "$WRAPPER"); else CMD=(env -u CODEX_NO_MCP_ARGS "$WRAPPER"); fi
fi
run() { (cd "$CWD" && "${CMD[@]}" "$@"); }

# config_read ARGS...: `config/read` from `codex ARGS... app-server`, started from DIR for that request
# alone; prints {"web_search": VALUE}. Exits 1 with a message when no answer comes within 10 s. The app
# server ends when its input closes; one that hasn't 3 s later is stopped, its process group with it.
config_read() {
  python3 -I - "$CWD" "$ERR" "${CMD[@]}" "$@" app-server <<'PY'
import json, os, select, signal, subprocess, sys, time
cwd, err, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(err, 'w') as e:
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=e, start_new_session=True)
end, buf = time.monotonic() + 10, b''
def send(message):
    p.stdin.write((json.dumps(message) + '\n').encode()); p.stdin.flush()
def reply(i):
    global buf
    while True:
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            try: message = json.loads(line)
            except ValueError: continue
            if isinstance(message, dict) and message.get('id') == i: return message
        left = end - time.monotonic()
        if left <= 0 or not select.select([p.stdout], [], [], left)[0]: return None
        chunk = os.read(p.stdout.fileno(), 65536)
        if not chunk: return None
        buf += chunk
answer = None
try:
    send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'codex-mcp-preflight', 'version': '1'}}})
    if (reply(1) or {}).get('result') is not None:
        send({'method': 'initialized'})
        send({'id': 2, 'method': 'config/read', 'params': {'cwd': cwd, 'includeLayers': False}})
        answer = reply(2)
except OSError:
    pass
finally:
    try: p.stdin.close()
    except OSError: pass
    try: p.wait(3)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)
        try: p.wait(2)
        except subprocess.TimeoutExpired: os.killpg(p.pid, signal.SIGKILL); p.wait()
config = ((answer or {}).get('result') or {}).get('config')
if not isinstance(config, dict):
    print('no config/read answer: ' + json.dumps(answer)[:500]); sys.exit(1)
print(json.dumps({'web_search': config.get('web_search')}))
PY
}

TRUST="projects={$(jq -cn --arg p "$CWD" '$p')={trust_level=\"trusted\"}}"
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
check() {  # check as_is|trusted: one pass's facts as JSON
  local extra=() list feats apps image web get plain server js
  [ "$1" = as_is ] || extra=(-c "$TRUST")
  list=$(run "${extra[@]}" mcp list --json 2> "$ERR") || error "codex mcp list failed ($1)" "$(cat "$ERR")"
  jq -e 'type == "array" and all(.[]; (.name | type) == "string" and (.enabled | type) == "boolean")' <<< "$list" > /dev/null ||
    error "codex mcp list printed what this check can't read ($1)" "$list"
  feats=$(run "${extra[@]}" features list 2> "$ERR") || error "codex features list failed ($1)" "$(cat "$ERR")"
  apps=$(awk '$1 == "apps" { print $NF }' <<< "$feats")
  [[ $apps =~ ^(true|false)$ ]] || error "codex features list shows no state for apps ($1)" "$feats"
  image=$(awk '$1 == "image_generation" { print $NF }' <<< "$feats")
  [[ $image =~ ^(true|false)$ ]] || error "codex features list shows no state for image_generation ($1)" "$feats"
  web=$(config_read "${extra[@]}") || error "codex app-server config/read failed ($1)" "$web $(cat "$ERR")"
  jq -e '.web_search | . == null or IN("disabled", "cached", "indexed", "live")' <<< "$web" > /dev/null ||
    error "codex app-server config/read printed what this check can't read ($1)" "$web"
  get='{}'
  for server in $(jq -r 'keys[]' <<< "$GIVE_JSON"); do
    jq -e --arg s "$server" 'any(.[]; .name == $s)' <<< "$list" > /dev/null || continue
    js=$(run "${extra[@]}" mcp get "$server" --json 2> "$ERR") || error "codex mcp get $server --json failed ($1)" "$(cat "$ERR")"
    plain=$(run "${extra[@]}" mcp get "$server" 2> "$ERR") || error "codex mcp get $server failed ($1)" "$(cat "$ERR")"
    get=$(jq -c --arg s "$server" --argjson j "$js" --arg p "$plain" '. + {($s): {enabled_tools: $j.enabled_tools,
      default_tools_approval_mode: ($p | [capture("(?m)^\\s*default_tools_approval_mode: (?<m>\\S+)").m] | first)}}' <<< "$get") ||
      error "codex mcp get $server printed what this check can't read ($1)" "$js"
  done
  jq -cn --argjson l "$list" --argjson a "$apps" --argjson i "$image" --argjson w "$web" --argjson g "$get" \
    '{servers: ($l | map({(.name): .enabled}) | add // {}), apps: $a, image_generation: $i,
      web_search: $w.web_search, give_back: $g}'
}
AS_IS=$(check as_is) || { r=$?; out "$AS_IS" "$r"; }
TRUSTED=$(check trusted) || { r=$?; out "$TRUSTED" "$r"; }

compare() {  # compare PASS FACTS: one line per difference from the expected
  jq -r --arg pass "$1" --argjson want "$GIVE_JSON" --argjson web_back "$WEB_BACK" '. as $f |
    ($f.servers | to_entries[] | .key as $k | select(.value != ($want | has($k))) |
      if .value then "\($pass): \($k) is enabled" else "\($pass): \($k), given back, is not enabled" end),
    ($want | keys[] as $k | select(($f.servers | has($k)) | not) | "\($pass): \($k), given back, is not listed"),
    (if $f.apps then "\($pass): apps (the connectors) is on" else empty end),
    (if $f.image_generation then "\($pass): image generation is on (features.image_generation=false is missing or overridden)" else empty end),
    (if $web_back then
       (if $f.web_search == "disabled" then "\($pass): the web, given back, is disabled (web_search=\"disabled\" is still in the arguments)" else empty end)
     elif $f.web_search != "disabled" then
       "\($pass): web_search is \($f.web_search // "unset, read as cached") (web_search=\"disabled\" is missing or overridden)"
     else empty end),
    ($f.give_back | to_entries[] | .key as $k | .value.enabled_tools as $t |
      select(($t | type) != "array" or ($t | sort) != $want[$k]) |
      "\($pass): \($k) enabled_tools is \($t | tojson), not \($want[$k] | tojson)"),
    ($f.give_back | to_entries[] | select(.value.default_tools_approval_mode != "auto") |
      "\($pass): \(.key) default_tools_approval_mode is \(.value.default_tools_approval_mode // "unset"), not auto")
  ' <<< "$2"
}
DIFF=$(compare as_is "$AS_IS" 2>&1 && compare trusted "$TRUSTED" 2>&1) || error "the comparison failed" "$DIFF"
[ -z "$DIFF" ] || mapfile -t -O "${#MISMATCH[@]}" MISMATCH <<< "$DIFF"

APPROVALS='null'
if [ "${#GIVE[@]}" -gt 0 ]; then
  APPROVALS=$(grep -H -n -s approval_mode "${CODEX_HOME:-$HOME/.codex}/config.toml" "$CWD/.codex/config.toml" | jq -R . | jq -cs .)
fi
RESULT=$(jq -cn --arg route "$ROUTE" --arg cwd "$CWD" --arg codex "$CODEX" \
  --arg list "${LIST:-$HERE/codex-no-mcp/no-mcp.args}" --arg args "$ARGS_FILE" --argjson give "$GIVE_JSON" --argjson web_back "$WEB_BACK" \
  --argjson a "$AS_IS" --argjson t "$TRUSTED" --argjson ap "$APPROVALS" \
  '{ok: ($ARGS.positional | length == 0), route: $route, cwd: $cwd, codex: $codex}
   + (if $route == "companion" then {list: $list} else {args_file: $args} end)
   + {give_back: $give, give_back_web: $web_back, checks: {as_is: $a, trusted: $t}, mismatches: $ARGS.positional}
   + (if $ap == null then {} else {approval_lines: $ap} end)' --args "${MISMATCH[@]}")
if [ "${#MISMATCH[@]}" -eq 0 ]; then out "$RESULT" 0; else out "$RESULT" 1; fi
