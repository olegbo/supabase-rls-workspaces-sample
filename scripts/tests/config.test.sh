#!/usr/bin/env bash
# Static checks on the Claude Code configuration: files parse, every hook the settings
# reference exists and is executable, agents and commands carry their frontmatter, and
# .mcp.json holds no literal credentials.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=lib.sh
. scripts/tests/lib.sh

for f in .claude/settings.json .mcp.json; do
  if jq empty "$f" 2>/dev/null; then ok "$f is valid JSON"; else not_ok "$f is valid JSON"; fi
done

while read -r cmd; do
  file=${cmd//\"\$CLAUDE_PROJECT_DIR\"\//}
  if [ -x "$file" ]; then ok "hook exists and is executable: $file"; else not_ok "hook missing: $file"; fi
done < <(jq -r '.hooks[][].hooks[].command' .claude/settings.json)

for f in .claude/agents/*.md; do
  name=$(sed -n '2,/^---$/s/^name: //p' "$f")
  desc=$(sed -n '2,/^---$/s/^description: //p' "$f")
  assert_eq "$(basename "$f" .md)" "$name" "agent $f is named after its file"
  if [ -n "$desc" ]; then ok "agent $f has a description"; else not_ok "agent $f has a description"; fi
done

for c in plan review; do
  f=.claude/commands/$c.md
  if [ -f "$f" ] && sed -n '2,/^---$/p' "$f" | grep -q '^description: '; then
    ok "/$c exists with a description"
  else
    not_ok "/$c exists with a description"
  fi
done

literal=$(jq -r '.. | strings' .mcp.json | grep -Ei 'bearer [^$]|gh[pousr]_|sk-|eyJ' || true)
assert_eq '' "$literal" '.mcp.json holds no literal credentials'
assert_eq true "$(jq '.mcpServers.supabase.url | test("read_only=true")' .mcp.json)" \
  'the Supabase MCP server is read-only'
assert_eq true "$(jq -r '.mcpServers.github.headers["X-MCP-Readonly"]' .mcp.json)" \
  'the GitHub MCP server is read-only'
assert_eq true "$(jq '.mcpServers.supabase.url | test("^http://(127\\.0\\.0\\.1|localhost):")' .mcp.json)" \
  'the Supabase MCP server is the local stack'

if [ -f CONSTITUTION.md ] && grep -q 'CONSTITUTION.md' CLAUDE.md; then
  ok 'CONSTITUTION.md exists and CLAUDE.md defers to it'
else
  not_ok 'CONSTITUTION.md exists and CLAUDE.md defers to it'
fi
for a in database-reviewer security-reviewer architect planner; do
  if grep -q CONSTITUTION.md ".claude/agents/$a.md"; then ok "$a reads CONSTITUTION.md"; else not_ok "$a reads CONSTITUTION.md"; fi
done

if grep -q '^## Requirements' .github/pull_request_template.md &&
  grep -q '^## Test output' .github/pull_request_template.md; then
  ok 'the PR template asks for requirements and test output'
else
  not_ok 'the PR template asks for requirements and test output'
fi

finish
