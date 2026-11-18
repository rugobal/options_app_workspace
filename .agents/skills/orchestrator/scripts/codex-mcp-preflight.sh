#!/usr/bin/env bash
# codex-mcp-preflight.sh: before a Codex worker's dispatch, the MCP servers and connectors it will
# have, read with no model turn, compared with what it may have.
#
#   codex-mcp-preflight.sh --cwd DIR [--list FILE | --args-file FILE] [--give-back SERVER=TOOL[,TOOL]...]...
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
#   `codex … features list`    whether `apps` (the connectors) is on;
#   for each --give-back server, `codex … mcp get SERVER --json` (enabled_tools) and the plain
#                              `mcp get SERVER` (default_tools_approval_mode).
# Expected: every listed server disabled except the --give-back servers, which are listed, enabled,
# with enabled_tools exactly the tools named and default_tools_approval_mode auto; apps false.
# Not covered: a tool's own approval_mode (no command shows it: with --give-back the JSON lists the
# approval_mode lines of the user's config and the checkout's .codex/config.toml, for the user), and
# Codex's own codex_tui server, which no setting removes; herdr-worker.sh mcp shows what a mode B
# worker really has connected.
# Prints one JSON object: {ok, route, cwd, codex, list|args_file, give_back, checks: {as_is, trusted},
# mismatches, approval_lines?}. Exit 0 as expected; 1 a mismatch (mismatches says which); 2 a codex
# command failed or printed what can't be read (error); 64 usage.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WRAPPER=$HERE/codex-no-mcp/codex

out() { printf '%s\n' "$1"; exit "$2"; }
usage() { out "$(jq -cn --arg m "$1" '{ok: false, error: {code: "usage", message: $m}}')" 64; }
error() { out "$(jq -cn --arg m "$1" --arg d "${2:-}" '{ok: false, error: {code: "codex_failed", message: $m, detail: $d}}')" 2; }

CWD="" LIST="" ARGS_FILE=""
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
    --give-back) [[ $2 =~ ^[A-Za-z0-9_-]+=[^,]+(,[^,]+)*$ ]] || usage "--give-back takes SERVER=TOOL[,TOOL]...: $2"; GIVE+=("$2") ;;
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
  run() { (cd "$CWD" && "$CODEX" "${CONFIG[@]}" "$@"); }
else
  CODEX=$WRAPPER
  ROUTE=companion
  if [ -n "$LIST" ]; then
    run() { (cd "$CWD" && env CODEX_NO_MCP_ARGS="$LIST" "$WRAPPER" "$@"); }
  else
    run() { (cd "$CWD" && env -u CODEX_NO_MCP_ARGS "$WRAPPER" "$@"); }
  fi
fi

TRUST="projects={$(jq -cn --arg p "$CWD" '$p')={trust_level=\"trusted\"}}"
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
check() {  # check as_is|trusted: one pass's facts as JSON
  local extra=() list feats apps get plain server js
  [ "$1" = as_is ] || extra=(-c "$TRUST")
  list=$(run "${extra[@]}" mcp list --json 2> "$ERR") || error "codex mcp list failed ($1)" "$(cat "$ERR")"
  jq -e 'type == "array" and all(.[]; (.name | type) == "string" and (.enabled | type) == "boolean")' <<< "$list" > /dev/null ||
    error "codex mcp list printed what this check can't read ($1)" "$list"
  feats=$(run "${extra[@]}" features list 2> "$ERR") || error "codex features list failed ($1)" "$(cat "$ERR")"
  apps=$(awk '$1 == "apps" { print $NF }' <<< "$feats")
  [[ $apps =~ ^(true|false)$ ]] || error "codex features list shows no state for apps ($1)" "$feats"
  get='{}'
  for server in $(jq -r 'keys[]' <<< "$GIVE_JSON"); do
    jq -e --arg s "$server" 'any(.[]; .name == $s)' <<< "$list" > /dev/null || continue
    js=$(run "${extra[@]}" mcp get "$server" --json 2> "$ERR") || error "codex mcp get $server --json failed ($1)" "$(cat "$ERR")"
    plain=$(run "${extra[@]}" mcp get "$server" 2> "$ERR") || error "codex mcp get $server failed ($1)" "$(cat "$ERR")"
    get=$(jq -c --arg s "$server" --argjson j "$js" --arg p "$plain" '. + {($s): {enabled_tools: $j.enabled_tools,
      default_tools_approval_mode: ($p | [capture("(?m)^\\s*default_tools_approval_mode: (?<m>\\S+)").m] | first)}}' <<< "$get") ||
      error "codex mcp get $server printed what this check can't read ($1)" "$js"
  done
  jq -cn --argjson l "$list" --argjson a "$apps" --argjson g "$get" \
    '{servers: ($l | map({(.name): .enabled}) | add // {}), apps: $a, give_back: $g}'
}
AS_IS=$(check as_is) || { r=$?; out "$AS_IS" "$r"; }
TRUSTED=$(check trusted) || { r=$?; out "$TRUSTED" "$r"; }

compare() {  # compare PASS FACTS: one line per difference from the expected
  jq -r --arg pass "$1" --argjson want "$GIVE_JSON" '. as $f |
    ($f.servers | to_entries[] | .key as $k | select(.value != ($want | has($k))) |
      if .value then "\($pass): \($k) is enabled" else "\($pass): \($k), given back, is not enabled" end),
    ($want | keys[] as $k | select(($f.servers | has($k)) | not) | "\($pass): \($k), given back, is not listed"),
    (if $f.apps then "\($pass): apps (the connectors) is on" else empty end),
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
  --arg list "${LIST:-$HERE/codex-no-mcp/no-mcp.args}" --arg args "$ARGS_FILE" --argjson give "$GIVE_JSON" \
  --argjson a "$AS_IS" --argjson t "$TRUSTED" --argjson ap "$APPROVALS" \
  '{ok: ($ARGS.positional | length == 0), route: $route, cwd: $cwd, codex: $codex}
   + (if $route == "companion" then {list: $list} else {args_file: $args} end)
   + {give_back: $give, checks: {as_is: $a, trusted: $t}, mismatches: $ARGS.positional}
   + (if $ap == null then {} else {approval_lines: $ap} end)' --args "${MISMATCH[@]}")
if [ "${#MISMATCH[@]}" -eq 0 ]; then out "$RESULT" 0; else out "$RESULT" 1; fi
