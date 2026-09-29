#!/usr/bin/env bash
# Mirror this skill folder into one or more Hermes profile skill directories.
#
# The destination directory is REPLACED: the copy is staged first and only swapped in if it
# contains a SKILL.md, so a failure never leaves a profile without the skill. Destinations are
# validated: every path component must be a plain name, the resolved target must live under
# $HERMES_ROOT/profiles, and a destination that is the same directory as the source (compared by
# device:inode, so symlinks cannot fool it) is skipped. Set DRY_RUN=1 to preview.
#
# Usage: sync-to-profiles.sh <profile> [<profile> ...]
#        PROFILES="one two" sync-to-profiles.sh
#        CATEGORY=autonomous-ai-agents HERMES_ROOT=~/.hermes DRY_RUN=1 sync-to-profiles.sh one
set -euo pipefail

SRC="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
NAME="$(basename "$SRC")"
CATEGORY="${CATEGORY:-autonomous-ai-agents}"
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
DRY_RUN="${DRY_RUN:-0}"

valid_name() {
  [ -n "$1" ] && [ "$1" != "." ] && [ "$1" != ".." ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'
}

[ -f "$SRC/SKILL.md" ] || { echo "refusing: $SRC has no SKILL.md" >&2; exit 2; }
valid_name "$NAME"     || { echo "refusing: skill folder name '$NAME' is not a plain name" >&2; exit 2; }
valid_name "$CATEGORY" || { echo "refusing: CATEGORY '$CATEGORY' is not a plain name" >&2; exit 2; }

if [ "$#" -gt 0 ]; then PROFILES="$*"; fi
[ -n "${PROFILES:-}" ] || { echo "usage: $0 <profile> [<profile> ...]   (or set PROFILES)" >&2; exit 2; }

ROOT_PHYS="$(readlink -f "$HERMES_ROOT" || true)"
[ -n "$ROOT_PHYS" ] || { echo "refusing: cannot resolve $HERMES_ROOT" >&2; exit 2; }
SRC_ID="$(stat -c '%d:%i' "$SRC")"

for p in $PROFILES; do
  valid_name "$p" || { echo "refusing: profile name '$p' is not a plain name" >&2; continue; }
  skills="$HERMES_ROOT/profiles/$p/skills"
  [ -d "$skills" ] || { echo "skip $p: no $skills" >&2; continue; }

  skills_phys="$(readlink -f "$skills")"
  case "$skills_phys" in
    "$ROOT_PHYS"/profiles/*) : ;;
    *) echo "refusing $p: $skills resolves outside $ROOT_PHYS/profiles" >&2; continue ;;
  esac

  dest="$skills/$CATEGORY/$NAME"
  if [ -e "$dest" ] && [ "$(stat -c '%d:%i' "$dest")" = "$SRC_ID" ]; then
    echo "skip $p: source and destination are the same directory"
    continue
  fi
  if [ "$DRY_RUN" != "0" ]; then
    echo "DRY RUN: would replace $dest with a copy of $SRC"
    continue
  fi

  mkdir -p "$(dirname "$dest")"
  stage="$dest.stage.$$"
  rm -rf "$stage"; mkdir -p "$stage"
  tar -cf - --exclude='.gitignore' --exclude='.env' --exclude='.env.*' \
             --exclude='*.log' --exclude='*.tmp' -C "$SRC" . | tar -xf - -C "$stage"
  if [ ! -f "$stage/SKILL.md" ]; then
    echo "failed $p: staged copy has no SKILL.md - leaving $dest untouched" >&2
    rm -rf "$stage"; exit 1
  fi
  rm -rf "$dest"
  mv -T "$stage" "$dest" 2>/dev/null || mv "$stage" "$dest"
  echo "synced $NAME -> $dest"
done
