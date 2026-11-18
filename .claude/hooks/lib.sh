# shellcheck shell=bash
# Shared helpers for the hook scripts. Sourced, not executed.

# Absolute, symlink-free project root.
project_dir() { (cd "${CLAUDE_PROJECT_DIR:-$PWD}" && pwd -P); }

# PreToolUse: refuse the tool call and tell Claude why.
deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# The ref that counts as "merged": origin/main, or main when there is no remote.
base_ref() {
  local r
  for r in origin/main main; do
    if git -C "$1" rev-parse --verify -q "$r^{commit}" >/dev/null; then
      echo "$r"
      return 0
    fi
  done
  return 1
}

# .env, .env.local, .env.production... hold secrets. .env.example is committed and safe.
is_secret_env_file() {
  local b
  b=$(basename -- "$1")
  case "$b" in
    .env.example) return 1 ;;
    .env | .env.*) return 0 ;;
  esac
  return 1
}

# Resolves $2 (absolute, or relative to $3) and prints it relative to project root $1.
# Fails when the path is outside the project.
relative_to_project() {
  local root=$1 path=$2 cwd=${3:-$1} dir
  [[ $path == /* ]] || path="$cwd/$path"
  dir=$(dirname -- "$path")
  if [ -d "$dir" ]; then
    path="$(cd "$dir" && pwd -P)/$(basename -- "$path")"
  fi
  case "$path" in
    "$root"/*) echo "${path#"$root"/}" ;;
    *) return 1 ;;
  esac
}

# True when the project-relative path is a migration that already exists on the base ref.
is_merged_migration() {
  local root=$1 rel=$2 base
  case "$rel" in supabase/migrations/*.sql) ;; *) return 1 ;; esac
  base=$(base_ref "$root") || return 1
  git -C "$root" cat-file -e "$base:$rel" 2>/dev/null
}

# Guards fail closed: if the script itself breaks, the tool call is refused, not let through.
refuse_on_error() {
  local rc=$?
  [ "$rc" -eq 0 ] || deny "$(basename "$0") failed (exit $rc) on this call, so it is refused."
}
fail_closed() {
  # deny() needs jq; without it the hook would exit 127, which Claude Code treats as
  # non-blocking. Refuse with hand-written JSON instead.
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "The guard hooks need jq. Install it, then retry."}}'
    exit 0
  fi
  trap refuse_on_error EXIT
}

# The guard rails: settings that wire the hooks, and the hooks themselves. A person
# changes them; the agent must not be able to switch them off.
is_guard_rail() {
  case "$1" in
    .claude/settings.json | .claude/settings.local.json | .claude/hooks | .claude/hooks/ | .claude/hooks/*) return 0 ;;
  esac
  return 1
}

# shellcheck disable=SC2034 # used by the scripts that source this file
GUARD_RULE="The guard rails (.claude/settings.json, .claude/settings.local.json, .claude/hooks/) \
are changed by a person, not by the agent. Ask the user to make this change."

# shellcheck disable=SC2034 # used by the scripts that source this file
MIGRATION_RULE="Merged migrations are immutable: they may already be applied to production. \
Write a new migration instead (supabase migration new <name>)."
