#!/usr/bin/env bash
# Run one headless Claude Code worker on DeepSeek through OpenRouter.
#
#   deepseek-worker.sh --brief <file> --cwd <checkout> [--compact-window <tokens>]
#                      [--effort <level>] [--resume <session-id>] [--max-budget <usd>]
#                      [--stream]
#
# Prints Claude Code's JSON result (result text, session_id, usage) on stdout;
# redirect it to the run's out/<task>-<attempt>.json and stderr to a separate
# file, since Claude Code writes warnings there.
#
# --stream: stdout is stream-json instead, one event per line as it happens
# (for a watched pane: herdr-worker.sh shows it through stream.jq). The result
# object is the last line: tail -n 1 <log> | jq '{is_error, result, session_id}'
#
# Key: $OPENROUTER_API_KEY, else ~/.config/openrouter/api_key.
# Model: $DEEPSEEK_WORKER_MODEL, default deepseek/deepseek-v4.1-flash-1017.
# Permission mode: $DEEPSEEK_WORKER_PERMISSION_MODE, default auto.
set -euo pipefail

brief="" cwd="" compact_window=300000 effort="" resume="" max_budget="" format=json
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) brief="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    --compact-window) compact_window="$2"; shift 2 ;;
    --effort) effort="$2"; shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --max-budget) max_budget="$2"; shift 2 ;;
    --stream) format=stream-json; shift ;;
    *) echo "deepseek-worker: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -f "$brief" ] || { echo "deepseek-worker: --brief file missing: $brief" >&2; exit 64; }
[ -d "$cwd" ] || { echo "deepseek-worker: --cwd is not a directory: $cwd" >&2; exit 64; }

key="${OPENROUTER_API_KEY:-}"
if [ -z "$key" ] && [ -r "$HOME/.config/openrouter/api_key" ]; then
  key="$(tr -d '[:space:]' < "$HOME/.config/openrouter/api_key")"
fi
[ -n "$key" ] || { echo "deepseek-worker: no OpenRouter key (OPENROUTER_API_KEY or ~/.config/openrouter/api_key)" >&2; exit 65; }

model="${DEEPSEEK_WORKER_MODEL:-deepseek/deepseek-v4.1-flash-1017}"

# Every model slot points at DeepSeek, so the worker's own subagents and
# background calls never fall back to Claude. The key replaces the Claude
# login for this process only; the owner's login is untouched.
export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
export ANTHROPIC_AUTH_TOKEN="$key"
export ANTHROPIC_API_KEY=""
export ANTHROPIC_MODEL="$model"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
export CLAUDE_CODE_SUBAGENT_MODEL="$model"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$compact_window"

model_settings="{\"autoCompactWindow\": $compact_window"
[ -n "$effort" ] && model_settings="$model_settings, \"effortLevel\": \"$effort\""
model_settings="$model_settings}"
settings="{\"modelSettings\": {\"$model\": $model_settings}}"

args=(-p --output-format "$format" --model "$model" --settings "$settings"
      --permission-mode "${DEEPSEEK_WORKER_PERMISSION_MODE:-auto}"
      --permission-prompts none
      # No MCP servers: the Telegram plugin's server would take the bot from the owner's session.
      --strict-mcp-config)
[ "$format" = stream-json ] && args+=(--verbose)
[ -n "$resume" ] && args+=(--resume "$resume")
[ -n "$max_budget" ] && args+=(--max-budget-usd "$max_budget")

cd "$cwd"
exec claude "${args[@]}" < "$brief"
