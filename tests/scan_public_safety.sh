#!/usr/bin/env bash
# Public-safety scan: fails if private/local/machine-specific content appears anywhere in the
# repo. Run from anywhere; scans the repo root this script lives in.
#
# Excluded from scanning: this script itself (it must NAME the forbidden patterns), and .git
# internals. The CI workflow is scanned so leaks there are caught.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

# grep -r over the repo with the standing exclusions applied.
scan() { # scan <label> <extended-regex>
    local label="$1" pattern="$2" hits
    hits="$(grep -rInE --binary-files=without-match \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=worktrees \
        --exclude=scan_public_safety.sh \
        -e "$pattern" "$ROOT" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
        echo "FAIL: $label"
        printf '%s\n' "$hits" | sed 's/^/    /'
        FAIL=1
    else
        echo "  ok: $label"
    fi
}

echo "== Public-safety scan: $ROOT =="

# 1. Personal/local filesystem assumptions
scan "personal user path"                 '[Uu]sers[/\\]+benny'
scan "OneDrive path assumption"           'OneDrive'
scan "raw source workspace name"          'IPC work'

# 2. Private ids and machine-local state references
scan "removed real thread UUID"           '019e932e'
scan "dev-repo inbox path"                'state/agent-inbox'
# (references to dev-repo .omc CONTENT paths; a bare ".omc/" gitignore entry is legitimate.
#  Actual .omc directories in the tree are caught by the structural check in section 7.)
scan "dev-repo .omc state"                '\.omc/[A-Za-z]'
scan "dev-repo plans path"                'plans/20[0-9]{2}-'

# 3. Private model/reasoning defaults and private project identifiers
scan "private model default"             'gpt-5\.5'
scan "private reasoning default"         'xhigh'
scan "private project identifiers"       '[Ll]and[-_ ]?[Dd]iligence|project6'

# 4. Secret-shaped content
scan "provider API key env names"         'OPENAI_API_KEY|ANTHROPIC_API_KEY'
scan "OpenAI-style secret key literal"    'sk-[A-Za-z0-9]{20,}'
scan "assigned secret/password literal"   '(password|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']+["'"'"']'

# 5. Backup files must not exist (content-independent)
bak_files="$(find "$ROOT" -name '*.bak' -o -name '*.bak-*' 2>/dev/null | grep -vE '/(\.git|worktrees)/' || true)"
if [[ -n "$bak_files" ]]; then
    echo "FAIL: backup files present"
    printf '%s\n' "$bak_files" | sed 's/^/    /'
    FAIL=1
else
    echo "  ok: no backup files"
fi

# 6. Non-synthetic UUIDs: every UUID in the repo must be on the synthetic-fixture allowlist.
ALLOWED_UUIDS='^(00000000-0000-4000-8000-000000000000|00000000-0000-4000-8000-00000000c0de|11111111-1111-4111-8111-111111111111|22222222-2222-4222-8222-222222222222|33333333-3333-4333-8333-333333333333)$'
unknown_uuids="$(grep -rIhoE --binary-files=without-match \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=worktrees \
    --exclude=scan_public_safety.sh \
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$ROOT" 2>/dev/null \
    | sort -u | grep -vE "$ALLOWED_UUIDS" || true)"
if [[ -n "$unknown_uuids" ]]; then
    echo "FAIL: UUID(s) present that are not on the synthetic-fixture allowlist:"
    printf '%s\n' "$unknown_uuids" | sed 's/^/    /'
    FAIL=1
else
    echo "  ok: all UUIDs are known synthetic fixtures"
fi

# 7. Structural checks: state dirs and path-embedded UUIDs. Content greps cannot see
#    these — a tool-state directory (e.g. OMC/Claude/Codex hooks writing into the tree)
#    or a session-UUID-named path leaks machine state without matching any content rule.
state_dirs="$(find "$ROOT" \( -name '.omc' -o -name '.claude' -o -name '.codex' \) -not -path '*/.git/*' -not -path '*/worktrees/*' 2>/dev/null || true)"
if [[ -n "$state_dirs" ]]; then
    echo "FAIL: local tool-state directory present"
    printf '%s\n' "$state_dirs" | sed 's/^/    /'
    FAIL=1
else
    echo "  ok: no local tool-state directories"
fi

path_uuids="$(find "$ROOT" -not -path '*/.git/*' -not -path '*/worktrees/*' 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | sort -u | grep -vE "$ALLOWED_UUIDS" || true)"
if [[ -n "$path_uuids" ]]; then
    echo "FAIL: non-synthetic UUID(s) in file/dir names"
    printf '%s\n' "$path_uuids" | sed 's/^/    /'
    FAIL=1
else
    echo "  ok: no non-synthetic UUIDs in paths"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "PUBLIC-SAFETY SCAN: CLEAN"
else
    echo "PUBLIC-SAFETY SCAN: FAILURES PRESENT"
fi
exit "$FAIL"
