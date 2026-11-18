# Pane view of a Claude Code stream-json log, one event per input line.
# Run as: jq -rR --unbuffered -f stream.jq   (-R plus fromjson? skips any non-JSON line)
fromjson? |
if .type == "system" and .subtype == "init" then
  "· " + (.model // "?") + ", session " + (.session_id // "?")
elif .type == "assistant" then
  .message.content[]? |
  if .type == "text" then "· " + .text
  elif .type == "tool_use" then "→ " + .name + " " + ((.input | tostring)[0:100])
  else empty end
elif .type == "result" then
  "= " + (.subtype // "result") + (if .is_error then ", error" else "" end) + ": " + ((.result // "") | tostring | .[0:300])
else empty end
