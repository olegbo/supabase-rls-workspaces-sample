#!/usr/bin/env bash
# PreToolUse(Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob). Blocks:
#   - any access to .env files (except .env.example): they hold secrets
#   - edits to migrations that already exist on origin/main
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
fail_closed

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""' <<<"$input")
# Grep's own `pattern` is a regex over file contents (e.g. "Deno.env"), so only its `glob`
# counts; Glob's `pattern` is a file pattern.
if [ "$tool" = Glob ]; then
  pattern=$(jq -r '.tool_input.pattern // ""' <<<"$input")
else
  pattern=$(jq -r '.tool_input.glob // ""' <<<"$input")
fi
cwd=$(jq -r '.cwd // ""' <<<"$input")
root=$(project_dir)
[ -d "$cwd" ] || cwd=$root

ENV="Access to .env files is blocked: they hold secrets. Local values live in \
supabase/functions/.env.example."

if [ -n "$path" ] && is_secret_env_file "$path"; then deny "$ENV"; fi
# Grep and Glob take a file pattern; a pattern aimed at .env files counts as reading them.
env_glob='(^|[/{,*])\.env($|[.*},])'
if [[ $tool == Grep || $tool == Glob ]] && [[ $pattern =~ $env_glob && $pattern != *.env.example* ]]; then
  deny "$ENV"
fi

case "$tool" in
  Edit | Write | MultiEdit | NotebookEdit) ;;
  *) exit 0 ;;
esac

rel=$(relative_to_project "$root" "$path" "$cwd") || exit 0
if is_guard_rail "$rel"; then deny "$GUARD_RULE"; fi
if is_merged_migration "$root" "$rel"; then deny "$MIGRATION_RULE"; fi
exit 0
