#!/usr/bin/env bash
# Stop hook for any DEVELOPMENT-tracked project (workspace or subproject).
# Wired in via .claude/settings.json — fires at the end of every turn
# (when Claude finishes responding) in Claude Code sessions whose cwd
# is under the owning project.
#
# Authored in the workspace at /home/ivan/DEVELOPMENT/tools/stop-hook.sh
# and synced into each subproject by tools/sync-agent-files.sh, so every
# project runs identical logic. PROJECT is derived from the script's own
# location, so the same file does the right thing whether invoked from
# the workspace or from a subproject. Workspace-only behavior (Step 2)
# is gated by an explicit equality check against $WORKSPACE.
#
# Steps are independent (no `set -e` so a failure in one step doesn't
# skip the others). The Trojan Source check in step 3 is the one
# exception -- it gates the auto-commit but does not stop the push of
# any earlier commits.
#
#   1. If any event-sourced folder under $PROJECT/LOGOS/ has uncommitted
#      *.toml changes, regenerate $PROJECT/LOGOS/_VIEW/ via the workspace
#      build-view.fsx and stage the result. Skips entirely (no
#      `dotnet fsi` startup tax) when no event-sourced folders changed,
#      or when the project has no LOGOS/ dir.
#   2. WORKSPACE-ONLY. If AGENTS.source.md or any LOGOS/conventions/*.md
#      has uncommitted changes, regenerate workspace AGENTS.md and
#      CLAUDE.md via tools/sync-agent-files.sh and stage them. The same
#      sync also updates each subproject's AGENTS.md, CLAUDE.md,
#      tools/stop-hook.sh, and .claude/settings.json on disk, but those
#      are NOT staged or committed by this hook -- subproject commits
#      are the subproject session's responsibility. See
#      LOGOS/conventions/agent-files-build.md.
#   3. Auto-commit any remaining uncommitted project changes with a
#      safety-net message. This is the LOW-quality fallback — turns that
#      change things intentionally should commit explicitly first
#      (per LOGOS/conventions/WORKFLOW.md). Refuses to commit when HEAD
#      is main (the safety-net message must not be how work lands on
#      main); warns instead and leaves changes untouched. On any other
#      branch: stages all, then runs the Trojan Source hard-floor check
#      (tools/check-trojan-source.sh -- decision 019e2e55-5cef-...); if
#      it fails, the commit is skipped (staged changes remain for the
#      next turn to investigate), but step 4 still runs to push any
#      earlier good commits.
#   4. Push to origin if local is ahead of upstream (or no upstream set).
#      Silently no-ops if the project has no `origin` remote configured.

export LC_ALL=C

WORKSPACE="/home/ivan/DEVELOPMENT"
PROJECT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

cd "$PROJECT" || exit 0

# -- Step 1: regenerate _VIEW/ only if event-sourced changes happened --

NEEDS_RENDER=0
if [ -d "$PROJECT/LOGOS" ]; then
  for folder in "$PROJECT/LOGOS"/*/; do
    if [ -d "$folder" ] && \
       [ -n "$(find "$folder" -maxdepth 1 -name '*.toml' -print -quit 2>/dev/null)" ] && \
       [ -n "$(git status --porcelain "$folder" 2>/dev/null)" ]; then
      NEEDS_RENDER=1
      break
    fi
  done
fi

if [ "$NEEDS_RENDER" -eq 1 ]; then
  dotnet fsi "$WORKSPACE/tools/build-view.fsx" "$PROJECT/LOGOS" && \
    git add "$PROJECT/LOGOS/_VIEW/"
fi

# -- Step 2: workspace-only -- regenerate AGENTS.md and CLAUDE.md if sources changed --
# Sources: AGENTS.source.md and LOGOS/conventions/*.md
# (see LOGOS/conventions/agent-files-build.md). The sync script also
# writes subproject AGENTS.md / CLAUDE.md / tools/stop-hook.sh /
# .claude/settings.json on disk; this hook only stages the workspace-side
# files, subproject commits happen in subproject sessions.

if [ "$PROJECT" = "$WORKSPACE" ]; then
  if [ -n "$(git status --porcelain -- "$WORKSPACE/AGENTS.source.md" "$WORKSPACE/LOGOS/conventions/" 2>/dev/null)" ]; then
    if "$WORKSPACE/tools/sync-agent-files.sh" >/dev/null; then
      git add "$WORKSPACE/AGENTS.md" "$WORKSPACE/CLAUDE.md"
    fi
  fi
fi

# -- Step 3: auto-commit any remaining uncommitted changes --
# Refuses to commit on main: non-trivial work belongs on a feature branch
# per LOGOS/conventions/WORKFLOW.md, and the safety-net commit message
# is the LOW-quality fallback that should never be the way work lands on
# main. Leaves changes untouched and warns; the next turn must move to a
# branch or commit explicitly. On any other branch: stages all, runs the
# Trojan Source hard-floor check, commits if clean. If the check fails,
# staged changes are left for the next turn -- this step's commit is
# skipped, but step 4 still runs to push any earlier commits.

if [ -n "$(git status --porcelain)" ]; then
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$CURRENT_BRANCH" = "main" ]; then
    echo "" >&2
    echo "Stop hook: auto-commit skipped -- HEAD is main." >&2
    echo "Non-trivial work belongs on a feature branch (LOGOS/conventions/WORKFLOW.md)." >&2
    echo "Move changes to a branch, or commit explicitly if truly trivial." >&2
  else
    git add -A
    if "$WORKSPACE/tools/check-trojan-source.sh"; then
      git commit -m "chore: turn-end safety net $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      echo "" >&2
      echo "Stop hook: auto-commit skipped due to Trojan Source violation(s) above." >&2
      echo "Staged changes remain. Resolve in the next turn." >&2
    fi
  fi
fi

# -- Step 4: push if ahead of upstream (or no upstream set yet) --
# Skips entirely when the project has no `origin` remote, so subprojects
# without a configured remote (e.g., not-yet-pushed local forks) don't
# error out every turn.

if git remote get-url origin >/dev/null 2>&1; then
  if [ -n "$(git log @{u}..HEAD 2>/dev/null)" ] || ! git rev-parse @{u} >/dev/null 2>&1; then
    git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
  fi
fi
