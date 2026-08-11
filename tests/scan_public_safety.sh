#!/usr/bin/env bash
# Public-safety scan: fails if private/local/machine-specific content appears anywhere in the
# repo. Run from anywhere; scans the repo root this script lives in.
#
# Excluded from content scanning: this script itself (it must NAME the forbidden patterns), and
# .git administrative data (a directory in a checkout, a pointer file in a worktree). The CI
# workflow is scanned so leaks there are caught.
set -uo pipefail

fatal() {
    echo "PUBLIC-SAFETY SCAN ERROR: $*" >&2
    exit 2
}

# Keep this list in sync with the CI provenance step. A missing scanner dependency is an
# infrastructure failure, never evidence that the repository is clean.
for tool in dirname find git grep sed sort; do
    command -v "$tool" >/dev/null 2>&1 || fatal "missing required tool: $tool"
done

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")" \
    || fatal "cannot resolve scanner directory"
[[ -n "$SCRIPT_DIR" ]] || fatal "scanner directory resolved empty"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)" \
    || fatal "cannot resolve repository root from $SCRIPT_DIR"
[[ -n "$ROOT" && -d "$ROOT" ]] || fatal "repository root is not a directory"
FAIL=0

# capture_match <output-variable> <context> <command...>
# Returns 0 for matches and 1 for no match. Any other command status is fatal.
capture_match() {
    local -n output_ref="$1"
    local context="$2" rc=0
    shift 2
    output_ref="$("$@")" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) output_ref=""; return 1 ;;
        *) fatal "$context failed (rc=$rc)" ;;
    esac
}

# capture_required <output-variable> <context> <command...>
# Structural enumeration and transformation must succeed even when their output is empty.
capture_required() {
    local -n output_ref="$1"
    local context="$2" rc=0
    shift 2
    output_ref="$("$@")" || rc=$?
    [[ "$rc" -eq 0 ]] || fatal "$context failed (rc=$rc)"
}

# capture_raw_object <output-variable> <context> <git-command...>
# The sentinel prevents command substitution from stripping an object's terminal newlines.
capture_raw_object() {
    local -n output_ref="$1"
    local context="$2" rc=0 sentinel=$'\x1e'
    shift 2
    output_ref="$(
        "$@"
        command_rc=$?
        printf '%s' "$sentinel"
        exit "$command_rc"
    )" || rc=$?
    [[ "$rc" -eq 0 ]] || fatal "$context failed (rc=$rc)"
    [[ "$output_ref" == *"$sentinel" ]] || fatal "$context framing failed"
    output_ref="${output_ref%"$sentinel"}"
}

# grep -r over the repo with the standing exclusions applied.
scan() { # scan <label> <extended-regex>
    local label="$1" pattern="$2" hits=""
    if capture_match hits "grep for $label" grep -rInE --binary-files=without-match \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=worktrees \
        --exclude=.git --exclude=scan_public_safety.sh \
        -e "$pattern" "$ROOT"; then
        echo "FAIL: $label"
        printf '%s\n' "$hits" | sed 's/^/    /'
        FAIL=1
    else
        echo "  ok: $label"
    fi
}

echo "== Public-safety scan: $ROOT =="

# History is part of the public surface. Inspect raw object headers rather than formatted log
# output so mailmaps and display settings cannot hide persisted identity metadata.
GITHUB_IDENT='GitHub <noreply@github.com>'

valid_stamp() { # valid_stamp <"unix-seconds timezone">
    local stamp="$1" seconds="" zone="" extra="" hours=0 minutes=0
    IFS=' ' read -r seconds zone extra <<<"$stamp"
    [[ -z "$extra" && "$stamp" == "$seconds $zone" ]] || return 1
    [[ "$seconds" =~ ^[0-9]+$ && "$zone" =~ ^[+-][0-9]{4}$ ]] || return 1
    hours=$((10#${zone:1:2}))
    minutes=$((10#${zone:3:2}))
    (( hours <= 14 && minutes <= 59 )) || return 1
    (( hours < 14 || minutes == 0 ))
}

valid_ident_header() { # valid_ident_header <raw-line> <header-name> <exact-ident>
    local line="$1" header="$2" ident="$3" prefix="" stamp=""
    prefix="$header $ident "
    [[ "$line" == "$prefix"* ]] || return 1
    stamp="${line#"$prefix"}"
    valid_stamp "$stamp"
}

valid_github_username() {
    local username="$1"
    (( ${#username} >= 1 && ${#username} <= 39 )) || return 1
    [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || return 1
    [[ "$username" != *--* ]]
}

valid_github_noreply_header() { # valid_github_noreply_header <raw-line> <header-name>
    local line="$1" header="$2" body="" pattern="" name="" email=""
    local seconds="" zone="" local_part="" username=""
    [[ "$line" == "$header "* ]] || return 1
    body="${line#"$header "}"
    pattern='^([^<>]+) <([^<>[:space:]]+)> ([0-9]+) ([+-][0-9]{4})$'
    [[ "$body" =~ $pattern ]] || return 1
    name="${BASH_REMATCH[1]}"
    email="${BASH_REMATCH[2]}"
    seconds="${BASH_REMATCH[3]}"
    zone="${BASH_REMATCH[4]}"
    [[ "$name" != [[:space:]]* && "$name" != *[[:space:]] ]] || return 1
    valid_stamp "$seconds $zone" || return 1
    [[ "$email" == *@users.noreply.github.com ]] || return 1
    local_part="${email%@users.noreply.github.com}"
    [[ -n "$local_part" ]] || return 1
    if [[ "$local_part" =~ ^([1-9][0-9]*)\+(.+)$ ]]; then
        username="${BASH_REMATCH[2]}"
    elif [[ "$local_part" == *+* ]]; then
        return 1
    else
        username="$local_part"
    fi
    valid_github_username "$username"
}

history_failure() { # history_failure <safe-description> <oid-or-ref>
    echo "FAIL: $1 ($2)"
    FAIL=1
}

inside_worktree=""
capture_required inside_worktree "Git worktree detection" \
    git -C "$ROOT" rev-parse --is-inside-work-tree
[[ "$inside_worktree" == "true" ]] || fatal "scanner root is not a Git worktree"

is_shallow=""
capture_required is_shallow "shallow-repository detection" \
    git -C "$ROOT" rev-parse --is-shallow-repository
case "$is_shallow" in
    false) ;;
    true) fatal "shallow Git history cannot be audited" ;;
    *) fatal "unexpected shallow-repository result" ;;
esac

commit_oids=""
capture_required commit_oids "reachable commit enumeration" \
    git -C "$ROOT" rev-list --all
[[ -n "$commit_oids" ]] || fatal "no reachable Git history"

while IFS= read -r oid; do
    [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || fatal "invalid commit object id from rev-list"
    raw_commit=""
    capture_raw_object raw_commit "commit object read for $oid" \
        git -C "$ROOT" cat-file commit "$oid"
    if [[ "$raw_commit" != *$'\n\n'* ]]; then
        history_failure "commit lacks a complete header block" "$oid"
        continue
    fi

    commit_headers="${raw_commit%%$'\n\n'*}"
    author_count=0
    committer_count=0
    author_header=""
    committer_header=""
    while IFS= read -r header_line; do
        case "$header_line" in
            author\ *)
                ((author_count += 1))
                author_header="$header_line"
                ;;
            committer\ *)
                ((committer_count += 1))
                committer_header="$header_line"
                ;;
        esac
    done <<<"$commit_headers"

    if (( author_count != 1 )); then
        history_failure "commit author-header cardinality is not one" "$oid"
    elif ! valid_github_noreply_header "$author_header" author; then
        history_failure "commit author identity or timestamp violates policy" "$oid"
    fi

    if (( committer_count != 1 )); then
        history_failure "commit committer-header cardinality is not one" "$oid"
    elif ! valid_github_noreply_header "$committer_header" committer \
        && ! valid_ident_header "$committer_header" committer "$GITHUB_IDENT"; then
        history_failure "commit committer identity or timestamp violates policy" "$oid"
    fi
done <<<"$commit_oids"

tag_refs=""
capture_required tag_refs "tag-ref enumeration" \
    git -C "$ROOT" for-each-ref --format='%(refname)' refs/tags
if [[ -n "$tag_refs" ]]; then
    while IFS= read -r tag_ref; do
        [[ "$tag_ref" == refs/tags/* ]] || fatal "invalid tag ref from enumeration"
        object_kind=""
        capture_required object_kind "tag object-type read for $tag_ref" \
            git -C "$ROOT" cat-file -t "$tag_ref"
        if [[ "$object_kind" != "tag" ]]; then
            history_failure "tag ref is not annotated" "$tag_ref"
            continue
        fi

        raw_tag=""
        capture_raw_object raw_tag "tag object read for $tag_ref" \
            git -C "$ROOT" cat-file tag "$tag_ref"
        if [[ "$raw_tag" != *$'\n\n'* ]]; then
            history_failure "tag lacks a complete header block" "$tag_ref"
            continue
        fi

        tag_headers="${raw_tag%%$'\n\n'*}"
        object_count=0
        type_count=0
        name_count=0
        tagger_count=0
        object_header=""
        type_header=""
        name_header=""
        tagger_header=""
        while IFS= read -r header_line; do
            case "$header_line" in
                object\ *) ((object_count += 1)); object_header="$header_line" ;;
                type\ *) ((type_count += 1)); type_header="$header_line" ;;
                tag\ *) ((name_count += 1)); name_header="$header_line" ;;
                tagger\ *) ((tagger_count += 1)); tagger_header="$header_line" ;;
            esac
        done <<<"$tag_headers"

        if (( object_count != 1 || type_count != 1 || name_count != 1 || tagger_count != 1 )); then
            history_failure "annotated-tag header cardinality violates policy" "$tag_ref"
            continue
        fi
        if [[ "$type_header" != "type commit" ]]; then
            history_failure "annotated tag does not directly target a commit" "$tag_ref"
        fi
        if [[ "$name_header" != "tag ${tag_ref#refs/tags/}" ]]; then
            history_failure "annotated-tag name does not match its ref" "$tag_ref"
        fi
        if ! valid_github_noreply_header "$tagger_header" tagger; then
            history_failure "annotated-tag identity or timestamp violates policy" "$tag_ref"
        fi

        target_oid="${object_header#object }"
        [[ "$target_oid" =~ ^[0-9a-f]{40,64}$ ]] \
            || fatal "invalid annotated-tag target object id for $tag_ref"
        target_kind=""
        capture_required target_kind "annotated-tag target read for $tag_ref" \
            git -C "$ROOT" cat-file -t "$target_oid"
        if [[ "$target_kind" != "commit" ]]; then
            history_failure "annotated-tag target object is not a commit" "$tag_ref"
        fi
    done <<<"$tag_refs"
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "  ok: reachable commit and annotated-tag identities"
fi

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
all_bak_files=""
capture_required all_bak_files "backup-file enumeration" \
    find "$ROOT" \( -name '*.bak' -o -name '*.bak-*' \)
bak_files=""
capture_match bak_files "backup-file exclusion filter" \
    grep -vE '/(\.git|worktrees)/' <<<"$all_bak_files" || true
if [[ -n "$bak_files" ]]; then
    echo "FAIL: backup files present"
    printf '%s\n' "$bak_files" | sed 's/^/    /'
    FAIL=1
else
    echo "  ok: no backup files"
fi

# 6. Non-synthetic UUIDs: every UUID in the repo must be on the synthetic-fixture allowlist.
ALLOWED_UUIDS='^(00000000-0000-4000-8000-000000000000|00000000-0000-4000-8000-00000000c0de|11111111-1111-4111-8111-111111111111|22222222-2222-4222-8222-222222222222|33333333-3333-4333-8333-333333333333)$'
uuid_matches=""
capture_match uuid_matches "repository UUID grep" grep -rIhoE --binary-files=without-match \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=worktrees \
    --exclude=.git --exclude=scan_public_safety.sh \
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$ROOT" || true
sorted_uuids=""
if [[ -n "$uuid_matches" ]]; then
    capture_required sorted_uuids "repository UUID sort" sort -u <<<"$uuid_matches"
fi
unknown_uuids=""
capture_match unknown_uuids "repository UUID allowlist filter" \
    grep -vE "$ALLOWED_UUIDS" <<<"$sorted_uuids" || true
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
state_dirs=""
capture_required state_dirs "tool-state directory enumeration" \
    find "$ROOT" \( -name '.omc' -o -name '.claude' -o -name '.codex' \) \
        -not -path '*/.git/*' -not -path '*/worktrees/*'
if [[ -n "$state_dirs" ]]; then
    echo "FAIL: local tool-state directory present"
    printf '%s\n' "$state_dirs" | sed 's/^/    /'
    FAIL=1
else
    echo "  ok: no local tool-state directories"
fi

all_paths=""
capture_required all_paths "repository path enumeration" \
    find "$ROOT" -not -path '*/.git/*' -not -path '*/worktrees/*'
path_uuid_matches=""
capture_match path_uuid_matches "path UUID grep" \
    grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    <<<"$all_paths" || true
sorted_path_uuids=""
if [[ -n "$path_uuid_matches" ]]; then
    capture_required sorted_path_uuids "path UUID sort" sort -u <<<"$path_uuid_matches"
fi
path_uuids=""
capture_match path_uuids "path UUID allowlist filter" \
    grep -vE "$ALLOWED_UUIDS" <<<"$sorted_path_uuids" || true
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
