#!/usr/bin/env bash
# jev-triage.sh -- route a free-text request to one of your agents, with a typed decision.
#
# One Jev request asks four questions about the same text and gets four typed answers back:
#   lane            choice  -- which agent should take it (one of your roster)
#   needs_captain   noul    -- does it need the human's decision before work starts
#   depth           score   -- how much work a proper answer takes, on an ordered scale
#   contains_secret noul    -- is there a credential in the text that must not be echoed
#
# Everything is a value your shell can branch on. There is no prose to parse and no
# "reply with only the word" instruction to be ignored.
#
# Usage:
#   jev-triage.sh '<request text>'
#   jev-triage.sh --roster-file roster.json '<request text>'
#   jev-triage.sh --roster 'alice=writes the docs' --roster 'bob=runs the servers' '<request text>'
#   jev-triage.sh --raw '<request text>'     # the full JSON, for piping
#
# Roster file or --roster values: name=description, one per line / one per flag. The
# descriptions are what the model chooses between, so write them as the work each agent does.
# Needs: bash, curl (via jev-call.sh), jq. Key: TYPESAFE_API_KEY, resolved by jev-call.sh.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CALLER="$SCRIPT_DIR/jev-call.sh"
[ -x "$CALLER" ] || { echo "jev-triage: cannot find executable $CALLER" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jev-triage: jq is required" >&2; exit 2; }

ROSTER_FILE=""
RAW=0
declare -a ROSTER_ITEMS=()
REQUEST=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --roster-file) [ "$#" -ge 2 ] || { echo "jev-triage: --roster-file needs a path" >&2; exit 2; }; ROSTER_FILE="$2"; shift 2 ;;
    --roster)      [ "$#" -ge 2 ] || { echo "jev-triage: --roster needs name=description" >&2; exit 2; }; ROSTER_ITEMS+=("$2"); shift 2 ;;
    --raw)         RAW=1; shift ;;
    -h|--help)     sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)            shift; break ;;
    -*)            echo "jev-triage: unknown option $1" >&2; exit 2 ;;
    *)             REQUEST="$1"; shift ;;
  esac
done
[ -n "$REQUEST" ] || { echo "jev-triage: no request text given" >&2; exit 2; }

# Build the criteria map: option name -> what that agent does. This is what a choice
# question chooses between, so the descriptions carry the routing policy.
roster='{}'
add_item() {
  local item="$1" name desc
  case "$item" in
    *=*) name="${item%%=*}"; desc="${item#*=}" ;;
    *)   echo "jev-triage: roster entry '$item' is not name=description" >&2; exit 2 ;;
  esac
  [ -n "$name" ] && [ -n "$desc" ] || { echo "jev-triage: roster entry '$item' has an empty name or description" >&2; exit 2; }
  roster="$(jq -c --arg n "$name" --arg d "$desc" '. + {($n): $d}' <<<"$roster")"
}

if [ -n "$ROSTER_FILE" ]; then
  [ -f "$ROSTER_FILE" ] || { echo "jev-triage: no such roster file: $ROSTER_FILE" >&2; exit 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    add_item "$line"
  done < "$ROSTER_FILE"
fi
for item in ${ROSTER_ITEMS+"${ROSTER_ITEMS[@]}"}; do add_item "$item"; done

# No roster given: a three-agent example so the tool still runs out of the box.
if [ "$roster" = "{}" ]; then
  add_item 'engineer=owns servers, deployments, credentials and anything that runs on a host'
  add_item 'researcher=answers questions from documents, sources and web research'
  add_item 'writer=turns settled material into published prose'
fi

body="$(jq -cn \
  --arg state "$REQUEST" \
  --argjson criteria "$roster" \
  '{state: $state,
    model: "jev-latest",
    questions: {
      lane: {type: "choice",
             instructions: "Which one of these agents should take this request? Choose by the work the request actually needs, not by who is named in it or who is mentioned in passing.",
             criteria: $criteria},
      needs_captain: {type: "noul",
             instructions: "Does this request need its owner to make a decision, approve spending, or confirm scope before any work starts?"},
      depth: {type: "score",
             instructions: "How much work will a proper answer take?",
             criteria: ["a quick answer with no tool use", "one focused task", "multi-step work across several tools"]},
      contains_secret: {type: "noul",
             instructions: "Does the request text itself contain a credential, API key, password or token that must not be copied into logs, files or replies?"}
    }}')"

response="$("$CALLER" "$body")"

if [ "$RAW" = "1" ]; then printf '%s\n' "$response"; exit 0; fi

# Render a human line from the typed answers. Any failure to parse is fatal: a routing
# decision that cannot be read is worse than no decision.
lane="$(jq -r '.answers.lane.choice // empty' <<<"$response")"
[ -n "$lane" ] || { echo "jev-triage: could not read the routing answer; raw response follows" >&2; printf '%s\n' "$response"; exit 1; }

jq -r --arg lane "$lane" '
  def pct: ((. * 100) | round | tostring) + "%";
  (.answers) as $a |
  "agent:        " + $lane + "  (probability " + ($a.lane.probabilities[$lane] | pct) + ")",
  "  runner-up:  " + ([$a.lane.probabilities | to_entries[] | select(.key != $lane and .value > 0.001) | "\(.key) \(.value | pct)"] | sort_by(-(.value)) | join(", ")),
  "  confidence: " + ($a.lane.confidence | pct) + "  (how concentrated the distribution is, NOT the winner\u0027s probability)",
  "needs you:    " + ($a.needs_captain.noul | pct),
  "depth:        " + ($a.depth.score | tostring) + "  (" + ($a.depth.probabilities | to_entries | max_by(.value) | .key | "level " + .) + ")",
  "secret:       " + ($a.contains_secret.noul | pct),
  "",
  "usage:        " + (.usage.input_tokens | tostring) + " in / " + (.usage.output_tokens | tostring) + " out  (" + .model + ")"
' <<<"$response"
