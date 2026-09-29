# Jev — Typed Decisions for Your Agent (TypeSafe System One)

> **A "fuzzy if" your code can trust.** Jev turns messy text or application state into typed, calibrated answers — a choice, a score, or a yes/no probability — in milliseconds. The response shape is fixed by your request, so the agent branches on typed values instead of parsing prose.

Jev is a **System One model**: it does not write text, code, or conversation. You give it a `state` and a map of typed `questions`; it returns `answers` under the same keys. That makes it the right tool for the small judgments that are too fuzzy for a hand-written `if` and too small for a frontier LLM call: routing, classification, extraction, ranking, scoring, guardrails, gating.

## Install

Copy-paste this to your Hermes agent (any profile):

```text
I want to install the jev skill from github.com/ciberjohn/Hermes-Skills.
Copy the whole jev/ folder - SKILL.md, README.md and every file in scripts/
(jev-call.sh, sync-to-profiles.sh, update-from-upstream.sh) - into
~/.hermes/skills/autonomous-ai-agents/jev/.

Then add TYPESAFE_API_KEY to my Hermes profile .env (mint a key in the
TypeSafe console dashboard, https://console.typesafe.ai/keys) and verify with
~/.hermes/skills/autonomous-ai-agents/jev/scripts/jev-call.sh

Finally, confirm the copy is intact before anything else:
cd ~/.hermes/skills/autonomous-ai-agents/jev && sha256sum -c MANIFEST.sha256
```

Or install manually:

```bash
# Clone the skills repo
git clone https://github.com/ciberjohn/Hermes-Skills.git ~/Hermes-Skills

# Copy the whole skill folder (SKILL.md, README.md + scripts)
mkdir -p ~/.hermes/skills/autonomous-ai-agents
cp -r ~/Hermes-Skills/jev ~/.hermes/skills/autonomous-ai-agents/jev
chmod +x ~/.hermes/skills/autonomous-ai-agents/jev/scripts/*.sh

# Add the credential (mode 600, never committed) - replace the placeholder first
printf '\nTYPESAFE_API_KEY=<key from https://console.typesafe.ai/keys>\n' >> ~/.hermes/.env
chmod 600 ~/.hermes/.env
```

## How it Works

1. **You mint a key** in the TypeSafe console dashboard (https://console.typesafe.ai/keys) and store it as `TYPESAFE_API_KEY` in your profile's `.env`.
2. **Your agent loads this skill** and writes decisions instead of prompts: a `state`, plus typed questions (`noul` = yes/no probability, `choice` = one of a set, `score` = position along ordered levels).
3. **Code consumes typed answers** — a probability, an option name, a level — with no parsing step.
4. **`scripts/jev-call.sh` does the plumbing** — it reads the key from the environment or from your Hermes `.env`, posts to `/v1/systemone`, and prints the JSON.

## What's Included

| File | Purpose |
|------|---------|
| `SKILL.md` | The skill itself: primitives, state and question design, patterns, and guidance on validating performance in your domain. Upstream TypeSafe content, with an install/credential header. |
| `README.md` | This file — install, usage, cost and safety notes. |
| `scripts/jev-call.sh` | One-shot CLI caller. Resolves the key itself, prints JSON. `jev-call.sh` with no argument runs a health probe. |
| `scripts/sync-to-profiles.sh` | Copies this skill folder into other Hermes profiles. It **replaces** the destination (staged, then swapped; a failure leaves the old copy in place), refuses any path that resolves outside `$HERMES_ROOT/profiles`, and skips a destination that is the same directory as the source. `DRY_RUN=1` previews. |
| `scripts/update-from-upstream.sh` | Re-pulls the upstream TypeSafe skill and compares its git blob SHA-1 with the recorded one. Fails closed on a bad download. |
| `MANIFEST.sha256` | SHA-256 of `SKILL.md` and the three scripts - check the copy you fetched with `sha256sum -c MANIFEST.sha256`. |
| `LICENSE` | TypeSafe's MIT license for the upstream skill body (Copyright (c) 2026 TypeSafe AI). |

## Usage Examples

Health probe:

```bash
~/.hermes/skills/autonomous-ai-agents/jev/scripts/jev-call.sh
# {"model":"jev-1.13.0","answers":{"ok":{"type":"noul","noul":0.33}},"usage":{"input_tokens":274,"output_tokens":20}}
```

Route an incoming message to a lane:

```bash
SKILL=~/.hermes/skills/autonomous-ai-agents/jev
"$SKILL/scripts/jev-call.sh" '{"state":"My invoice was charged twice.","model":"jev-latest","questions":{"lane":{"type":"choice","instructions":"Which queue should handle this?","criteria":{"billing":"a charge, invoice or payment problem","general support":"anything else"}}}}'
# {"model":"jev-1.13.0","answers":{"lane":{"type":"choice","choice":"billing","confidence":1.0,"probabilities":{"billing":1.0,"general support":0.0}}},"usage":{"input_tokens":320,"output_tokens":32}}
```

Grade a document with the same questions every time:

```bash
SKILL=~/.hermes/skills/autonomous-ai-agents/jev
"$SKILL/scripts/jev-call.sh" '{"state":"Please confirm the invoice number so I can issue the credit note.","model":"jev-latest","questions":{"actionable":{"type":"noul","instructions":"Does this document require a reply from me?"},"effort":{"type":"score","instructions":"How much effort will a proper reply take?","criteria":["a few minutes","under an hour","half a day or more"]}}}'
# {"model":"jev-1.13.0","answers":{"actionable":{"type":"noul","noul":0.93},"effort":{"type":"score","score":0.06,"confidence":0.9,"legend":{"0":"a few minutes","1":"under an hour","2":"half a day or more"},"probabilities":{"0":0.94,"1":0.06,"2":0.0}}},"usage":{"input_tokens":336,"output_tokens":36}}
```

**Criteria shapes differ between primitives.** `choice` takes a map of option name to description; `score` takes an ordered list of level descriptions, low end first (a map is rejected with HTTP 422, `Input should be a valid list`); `noul` takes an optional criteria object with `true` and `false` descriptions. **Confidence is a concentration measure, not the peak probability** - the score example above returns `confidence` 0.9 on a distribution whose peak is 0.94, which is expected.

Inside a Hermes session, just ask: *"Use the jev skill to check whether these 40 support tickets are urgent, then tell me which ones to answer first."*

## Cost and Safety

- **The key stays out of prompts and logs.** Store it in `.env` (mode 600, gitignored), read it from the environment, and keep it server-side in any web app. Never paste it into a chat message.
- **Ask independent questions together.** Questions in one request run in parallel and cannot see each other's answers; a second request is only warranted when an earlier answer must change the next question or fetch new evidence.
- **Thresholds are yours.** Choice and Score return `confidence` derived from the probability distribution — that is distribution concentration, not permission to act. Evaluate thresholds on your own data and consequences.
- **Typed output guarantees the interface, not the truth.** Validate performance in your domain with representative cases, and inspect the exact state, questions, and answers when a case fails.

## Upstream and License

MIT (c) 2026 Joao Silva for this packaging. The skill body is TypeSafe AI's own agent skill (`skills/typesafe-ai/SKILL.md` from [typesafe-ai/skills](https://github.com/typesafe-ai/skills)), redistributed under their MIT license - see `LICENSE` (Copyright (c) 2026 TypeSafe AI). Kept verbatim apart from the rewritten frontmatter, the prepended header, and one dead documentation link that was refreshed. Verified against upstream git blob SHA-1 `0109513f9656917dc93cbc5ecddfca465a53ce66`; re-check any time with `scripts/update-from-upstream.sh`.

**Integrity note.** The install prompt fetches the tip of `main`, so pin it to a commit you have reviewed (`git checkout <sha>`) if you want reproducibility, and check `sha256sum -c MANIFEST.sha256` after copying. The MANIFEST covers `SKILL.md` and the three scripts, not this README.
