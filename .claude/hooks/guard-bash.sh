#!/usr/bin/env bash
# PreToolUse(Bash). Blocks:
#   - deploys and remote project operations (supabase db push, functions deploy, secrets,
#     --linked / --db-url / --project-ref): deploys happen only from CI
#   - force pushes, pushes to main, --all / --mirror
#   - commands that touch .env files (except .env.example)
#   - commands that modify merged migrations, or the guard rails themselves
#     (.claude/settings*.json, .claude/hooks/)
#   - psql against a host other than the local stack (a deploy without the CLI)
#   - gh actions that belong to a person: merging, approving, secrets, repository settings,
#     and any GitHub API write except replies on review threads
# Matching works on words of each simple command, so it catches the usual spellings.
# It is a guard rail, not a sandbox: CI and branch protection are the backstop.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
fail_closed

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")
root=$(project_dir)
[ -d "$cwd" ] || cwd=$root

DEPLOY="Deploys run only from CI after review. Local supabase commands must not touch the \
hosted project (db push, functions deploy, secrets, --linked, --db-url, --project-ref)."
FORCE="Force pushes are blocked: shared history is never rewritten. Push new commits instead."
MAIN="Pushing to main is blocked: main changes only through a reviewed PR. \
Push a feature branch and open a PR."
SHELL_STDIN="Piping commands into a shell is blocked: they cannot be checked. Run them directly."
ENV="Reading .env files is blocked: they hold secrets. Local values live in \
supabase/functions/.env.example."
PERSON="Merging, approving, secrets and repository settings are a person's decision \
(CONSTITUTION.md, article 3). Ask the user to do it."
API_WRITE="GitHub API writes are blocked, except replies on review threads \
(repos/<owner>/<repo>/pulls/<n>/comments/<id>/replies). Use gh pr create / edit / comment, \
or ask the user."
REMOTE_DB="psql to a host other than the local stack is blocked: hosted databases change \
only through CI."

# Commands that only read the paths they are given. Anything else counts as a write.
read_only_command() {
  local first=${1:-} sub=${2:-}
  case "$first" in
    cat | head | tail | less | more | grep | rg | diff | wc | ls | stat | file | shasum | \
      sha256sum | md5 | md5sum | psql | supabase | echo | printf | tree | shellcheck | jq) return 0 ;;
    find)
      # find only reads, unless it deletes or runs commands on what it finds.
      [[ " $* " != *" -delete "* && " $* " != *" -exec"* && " $* " != *" -ok"* ]]
      return
      ;;
    git)
      case "$sub" in
        add | commit | diff | log | show | blame | status | ls-files | ls-tree | cat-file | grep) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Paths a word may name: the word itself, without redirections, or the value of an
# option such as `of=<path>` or `--output=<path>`.
path_of() {
  local w=${1#"${1%%[!<>]*}"}
  [[ $w == *=* ]] && w=${w##*=}
  printf '%s' "$w"
}

current_branch() { git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true; }

check_env() {
  local w part prev="" file_arg text_only=0
  # echo/printf arguments and commit or tag messages are text, not file reads, and may
  # mention .env files. Redirections and `-F <file>` still count.
  case "${1:-} ${2:-}" in echo\ * | printf\ * | "git commit" | "git tag") text_only=1 ;; esac
  for w in "$@"; do
    file_arg=0
    case "$prev" in \<* | \>* | -F | --file) file_arg=1 ;; esac
    [[ $w == [\<\>]* ]] && file_arg=1
    prev=$w
    [ $text_only = 1 ] && [ $file_arg = 0 ] && continue
    w=${w#"${w%%[!<>]*}"} # drop redirection characters: <.env, >.env
    [ -n "$w" ] || continue
    IFS='=' read -ra parts <<<"$w"
    for part in "${parts[@]}"; do
      if [[ $part == *[\*?[]* ]]; then # a glob: refuse if it could expand to a secret .env file
        local b probe
        b=$(basename -- "$part")
        # Without dotglob a pattern reaches dotfiles only if it starts with a literal dot,
        # so `*` and `select *` cannot expand to .env.
        [[ $b == .* ]] || continue
        for probe in .env .env.local .env.production .env.keys; do
          # shellcheck disable=SC2053 # $b is a glob pattern on purpose
          if [[ $probe == $b ]]; then deny "$ENV"; fi
        done
      elif [ -n "$part" ] && is_secret_env_file "$part"; then
        deny "$ENV"
      fi
    done
  done
}

check_supabase() {
  local i found=0 w prev=""
  for ((i = 0; i < $#; i++)); do
    w=${*:i+1:1}
    if [ $found = 0 ]; then
      # supabase, ./node_modules/.bin/supabase, supabase@3, npm:supabase, the supabase/cli image
      if [[ $w == supabase || $w == */supabase || $w == supabase@* || $w == *:supabase ||
        $w == *:supabase@* || $w == supabase/cli* || $w == */supabase/cli* ]]; then found=1; fi
      continue
    fi
    case "$w" in
      --linked | --linked=* | --db-url | --db-url=* | --project-ref | --project-ref=*) deny "$DEPLOY" ;;
      -*) continue ;;
    esac
    case "$prev $w" in
      "db push" | "functions deploy" | "functions delete" | "secrets set" | "secrets unset" | \
        "config push" | "storage rm" | "storage mv" | "storage cp" | "branches create" | \
        "branches delete" | "branches update" | "projects delete") deny "$DEPLOY" ;;
      # squash rewrites merged migration files; repair edits the migration history.
      "migration squash" | "migration repair") deny "$MIGRATION_RULE" ;;
    esac
    prev=$w
  done
}

check_git_push() {
  local words=("$@") i=0 n=$# w sub="" refspecs=() dst
  # Find "git", skip its global options, read the subcommand.
  while [ $i -lt "$n" ] && [[ ${words[i]} != git && ${words[i]} != */git ]]; do i=$((i + 1)); done
  [ $i -lt "$n" ] || return 0
  for ((i = i + 1; i < n; i++)); do
    w=${words[i]}
    case "$w" in
      -C | -c | --git-dir | --work-tree | --namespace) i=$((i + 1)) ;;
      -*) ;;
      *)
        sub=$w
        break
        ;;
    esac
  done
  [ "$sub" = push ] || return 0

  for ((i = i + 1; i < n; i++)); do
    w=${words[i]}
    case "$w" in
      --force | --force=* | --force-with-lease* | --force-if-includes) deny "$FORCE" ;;
      --mirror | --all) deny "$MAIN" ;;
      -o | --push-option | --repo | --receive-pack | --exec) i=$((i + 1)) ;;
      --*) ;;
      -*) if [[ $w == *f* ]]; then deny "$FORCE"; fi ;;
      *) refspecs+=("$w") ;;
    esac
  done

  # The first positional is the remote; the rest are refspecs.
  if [ ${#refspecs[@]} -le 1 ]; then
    if [ "$(current_branch)" = main ]; then deny "$MAIN"; fi
    return 0
  fi
  for w in "${refspecs[@]:1}"; do
    if [[ $w == +* ]]; then deny "$FORCE"; fi
    dst=${w##*:}
    if [ "$dst" = HEAD ] || [ "$dst" = @ ]; then dst=$(current_branch); fi
    dst=${dst#refs/}
    dst=${dst#heads/}
    if [ "$dst" = main ]; then deny "$MAIN"; fi
  done
}

check_migrations() {
  local w rel touches=0 redirect=0
  for w in "$@"; do
    if [[ $w == \>* ]]; then redirect=1; fi
    w=$(path_of "$w")
    [[ $w == *migrations* ]] || continue
    rel=$(relative_to_project "$root" "$w" "$cwd") || continue
    case "$rel" in
      supabase/migrations | supabase/migrations/ | supabase/migrations/*[*?]*) touches=1 ;;
      supabase/migrations/*) if is_merged_migration "$root" "$rel"; then touches=1; fi ;;
    esac
  done
  [ $touches = 1 ] || return 0
  if [ $redirect = 1 ]; then deny "$MIGRATION_RULE"; fi
  if ! read_only_command "$@"; then deny "$MIGRATION_RULE"; fi
}

# The guard rails themselves: the agent must not be able to switch them off.
check_guard_rails() {
  local w rel touches=0 redirect=0
  for w in "$@"; do
    if [[ $w == \>* ]]; then redirect=1; fi
    w=$(path_of "$w")
    [[ $w == *.claude* || $w == *hooks* || $w == *settings* ]] || continue
    rel=$(relative_to_project "$root" "$w" "$cwd") || continue
    if is_guard_rail "$rel"; then touches=1; fi
  done
  [ $touches = 1 ] || return 0
  if [ $redirect = 1 ]; then deny "$GUARD_RULE"; fi
  if ! read_only_command "$@"; then deny "$GUARD_RULE"; fi
}

check_psql() {
  local w host
  [[ ${1##*/} == psql || ${1##*/} == pg_restore ]] || return 0
  local -a hosts=()
  for ((i = 1; i < $#; i++)); do
    w=${*:i+1:1}
    case "$w" in
      -h | --host) hosts+=("${*:i+2:1}") ;;
      --host=*) hosts+=("${w#--host=}") ;;
      -h?*) hosts+=("${w#-h}") ;;
    esac
    if [[ $w =~ ^postgres(ql)?://([^@/]*@)?(\[[^]]*\]|[^:/?]+) ]]; then hosts+=("${BASH_REMATCH[3]}"); fi
    if [[ $w =~ (^|[[:space:]])host=([^[:space:]]+) ]]; then hosts+=("${BASH_REMATCH[2]}"); fi
  done
  for host in ${hosts[@]+"${hosts[@]}"}; do
    case "$host" in
      127.0.0.1 | localhost | ::1 | "[::1]" | \$*) ;;
      *) deny "$REMOTE_DB" ;;
    esac
  done
}

check_gh() {
  local words=("$@") i=0 n=$# w sub="" sub2="" method="" endpoint="" writes=0
  while [ $i -lt "$n" ] && [[ ${words[i]} != gh && ${words[i]} != */gh ]]; do i=$((i + 1)); done
  [ $i -lt "$n" ] || return 0
  for ((i = i + 1; i < n; i++)); do
    w=${words[i]}
    case "$w" in
      -R | --repo) i=$((i + 1)) ;;
      -*) ;;
      *) if [ -z "$sub" ]; then sub=$w; else sub2=$w; break; fi ;;
    esac
  done
  case "$sub $sub2" in
    "pr merge" | "secret set" | "secret delete" | "secret remove" | "variable set" | \
      "variable delete" | "repo delete" | "repo edit" | "repo rename" | "repo archive" | \
      "ruleset create" | "ruleset delete") deny "$PERSON" ;;
    "pr review")
      for w in "${words[@]}"; do
        case "$w" in --approve | -a) deny "$PERSON" ;; esac
      done
      ;;
  esac
  [ "$sub" = api ] || return 0

  # gh api: the first positional after `api` is the endpoint. Fields imply POST.
  for ((i = 0; i < n; i++)); do [ "${words[i]}" = api ] && break; done
  for ((i = i + 1; i < n; i++)); do
    w=${words[i]}
    case "$w" in
      -X | --method) method=${words[i + 1]:-}; i=$((i + 1)) ;;
      -X?*) method=${w#-X} ;;
      --method=*) method=${w#--method=} ;;
      -f | -F | --field | --raw-field | --input) writes=1; i=$((i + 1)) ;;
      -H | --header | -q | --jq | -t | --template | --cache | -p | --preview | --hostname) i=$((i + 1)) ;;
      -*) ;;
      *) [ -z "$endpoint" ] && endpoint=$w ;;
    esac
  done
  method=$(tr '[:lower:]' '[:upper:]' <<<"${method:-$([ $writes = 1 ] && echo POST || echo GET)}")
  [ "$method" = GET ] && return 0
  if [ "$endpoint" = graphql ]; then
    for w in "${words[@]}"; do
      if [[ $w == *mutation* ]]; then deny "$API_WRITE"; fi
    done
    return 0
  fi
  if [ "$method" = POST ] && [[ ${endpoint#/} =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+/comments/[0-9]+/replies$ ]]; then
    return 0
  fi
  deny "$API_WRITE"
}

# Checks every simple command in a command line. Strings run by `sh -c` / `bash -c` /
# `eval` are checked the same way, wherever the shell appears (`timeout 5 bash -c ...`).
analyze() {
  local seg i j w segments
  local -a words
  # Split first: if the splitter fails, refuse (fail closed) instead of seeing no commands.
  segments=$(printf '%s' "$1" | perl "$(dirname "$0")/split-command.pl") || exit 1
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    IFS=$'\x1f' read -ra words <<<"$seg"
    # Leading VAR=value assignments and wrappers do not change what runs.
    while [ ${#words[@]} -gt 0 ]; do
      if [[ ${words[0]} =~ ^[A-Za-z_][A-Za-z0-9_]*= || ${words[0]} =~ ^(env|sudo|command|exec|time|nohup|nice|npx|bunx)$ ]]; then
        words=("${words[@]:1}")
      elif [ "${words[0]}" = timeout ] && [ ${#words[@]} -gt 1 ]; then
        words=("${words[@]:2}")
      else
        break
      fi
    done
    [ ${#words[@]} -gt 0 ] || continue

    # A shell with no script or -c reads its commands from stdin (`... | bash`), which
    # cannot be checked.
    if [[ ${words[0]##*/} =~ ^(sh|bash|zsh|dash|ksh)$ ]]; then
      w=stdin
      for ((j = 1; j < ${#words[@]}; j++)); do
        [[ ${words[j]} == -* && ${words[j]} != *c* ]] || { w=""; break; }
      done
      if [ "$w" = stdin ]; then deny "$SHELL_STDIN"; fi
    fi
    # xargs feeds stdin to the shell as arguments, which cannot be checked either.
    if [ "${words[0]##*/}" = xargs ]; then
      for ((j = 1; j < ${#words[@]}; j++)); do
        if [[ ${words[j]##*/} =~ ^(sh|bash|zsh|dash|ksh)$ ]] && [[ ${words[j + 1]:-} != -*c* ]]; then
          deny "$SHELL_STDIN"
        fi
      done
    fi
    for ((i = 0; i < ${#words[@]}; i++)); do
      case "${words[i]##*/}" in
        sh | bash | zsh | dash | ksh)
          for ((j = i + 1; j < ${#words[@]} - 1; j++)); do
            if [[ ${words[j]} == -*c* && ${words[j]} != --* ]]; then analyze "${words[j + 1]}"; fi
          done
          ;;
        eval) analyze "${words[*]:i+1}" ;;
      esac
    done
    # Inline code for an interpreter is one quoted word; look inside it for .env files.
    if [[ ${words[0]##*/} =~ ^(python[0-9.]*|node|deno|bun|ruby|perl|php)$ ]]; then
      for w in "${words[@]:1}"; do
        if [[ $w =~ (^|[^A-Za-z0-9_.])\.env($|[^A-Za-z0-9_.]|\.(local|production|keys)) ]]; then deny "$ENV"; fi
      done
    fi
    check_env "${words[@]}"
    check_supabase "${words[@]}"
    check_git_push "${words[@]}"
    check_migrations "${words[@]}"
    check_guard_rails "${words[@]}"
    check_psql "${words[@]}"
    check_gh "${words[@]}"
  done <<<"$segments"
}

analyze "$cmd"
exit 0
