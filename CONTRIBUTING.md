# Contributing

## Ground rules

1. **`skills/ipc/` is the canonical skill source.** Do not create duplicate copies of the skill
   elsewhere in the repo; docs link into it instead.
2. **Safety invariants are not negotiable.** Any change must preserve: explicit-UUID targeting for
   live sends (no heuristics), dry-run-by-default with `--send --ack-live-write` gating,
   file-drop-first fallback, `readOnly:true` SQLite access, opt-in transcript disclosure, and no
   shipped authorized thread id. `tests/` and `codex_ipc_contract_audit.mjs` encode most of these —
   keep them green and extend them with your change.
3. **No private/local content.** No personal filesystem paths, real conversation/session UUIDs,
   API keys, or machine-specific defaults in code, docs, examples, or tests. CI's public-safety
   scan (`tests/scan_public_safety.sh`) enforces a baseline; run it locally.
4. **Hermetic tests only.** Tests must not require Codex Desktop, the Codex CLI, Claude state,
   `node:sqlite`, or the network. Stub external binaries the way `tests/test_ipc.sh` does.

## Text policy and recovery

Repository text is strict UTF-8 without a BOM, uses LF line endings, and ends with a final LF.
Intentional Unicode is retained; do not normalize or automatically convert it. `.editorconfig`
declares the editor policy, while `.gitattributes` makes Git normalize governed text to LF.

Mojibake can mean valid UTF-8 displayed with the wrong decoder.
Stored bytes can instead be invalid or corrupt, or valid UTF-8 can contain a known double-decoding signature.
On Windows PowerShell 5.1, define the path before inspecting it:

```powershell
$Path = 'C:\path\to\file.md'
Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
```

PowerShell 5.1 `Set-Content -Encoding UTF8` writes a BOM. For BOM-free writes, use a configured
UTF-8/LF editor, PowerShell 7 `utf8NoBOM`, or `.NET UTF8Encoding(false)`.

Inspect raw bytes first, then apply strict UTF-8 decoding.
If the bytes are valid, use the correct reader or editor and do not save the misrendered form.
If the bytes are corrupt, restore or reconstruct from authoritative source; a reconstruction is allowed only when its reviewed byte-to-codepoint mapping is unambiguous.
Then run index and worktree gates, then semantic tests.
Never paste broken console text back into a file. There is no automatic transcoder. Preserve
intentional Unicode; do not normalize or auto-convert it.

## Dev loop

```bash
# syntax
bash -n skills/ipc/scripts/handoff_to_codex.sh
bash -n skills/ipc/scripts/codex_ipc_replies.sh
for f in skills/ipc/scripts/*.mjs; do node --check "$f"; done

# text policy
node tests/check_text_integrity.mjs --self-test
node tests/check_text_integrity.mjs --source index
node tests/check_text_integrity.mjs --source worktree

# documentation policy
node tests/check_docs_quality.mjs --self-test
node tests/check_docs_quality.mjs

# complete repository runner
bash tests/run_release_gates.sh

# separate process-ownership meta-gate
bash tests/test_gate_process_ownership.sh

# public-safety scan
bash tests/scan_public_safety.sh

# static contract audit
node skills/ipc/scripts/codex_ipc_contract_audit.mjs

# frozen manifests without installed-root access
bash tests/gen_release_manifest.sh check-all --no-roots
```

On Windows PowerShell, use this pinned, fail-closed Git Bash procedure:

```powershell
$GitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $GitBash -PathType Leaf)) { throw 'Git Bash not found' }
& $GitBash --version
if ($LASTEXITCODE -ne 0) { throw 'Git Bash version check failed' }
& $GitBash -lc 'command -v dirname >/dev/null && command -v git >/dev/null && command -v node >/dev/null && command -v sha256sum >/dev/null'
if ($LASTEXITCODE -ne 0) { throw 'Git Bash tool preflight failed' }
& $GitBash -lc 'bash tests/run_release_gates.sh'
if ($LASTEXITCODE -ne 0) { throw 'release gates failed' }
```

External links are not fetched by the documentation gate. Hermetic gates do not prove live Codex
Desktop behavior. Source-candidate commit validation, release rebind and annotated-tag validation, and installed-root propagation are separate states; none implies the next.

## Commit identity privacy

The repository owner should configure this repository, rather than relying on a machine-wide
identity:

```bash
git config --local user.name 'benjmcd'
git config --local user.email '201677302+benjmcd@users.noreply.github.com'
test "$(git config --local --get user.name)" = 'benjmcd'
test "$(git config --local --get user.email)" = '201677302+benjmcd@users.noreply.github.com'
```

Run the two exact checks immediately before committing, and inspect the resulting commit before
pushing (`git show --no-patch --format=fuller HEAD`). External contributors must configure their
own name and their own GitHub no-reply address; never copy or impersonate the maintainer identity
shown above. Both modern `ID+USERNAME@users.noreply.github.com` and legacy
`USERNAME@users.noreply.github.com` addresses are accepted when they use GitHub's documented
username syntax.

In GitHub's email settings, also enable **Keep my email addresses private** and **Block command
line pushes that expose my email**. The repository scanner permits syntactically valid GitHub
no-reply formats for authors, committers, and taggers, plus GitHub's exact service identity as a
committer only. It audits raw headers for every commit reachable from publishable checkout refs
(`refs/heads/*`, `refs/remotes/origin/*`, and `refs/tags/*`) and from the explicit PR head SHA
supplied by CI. It also validates every annotated tag and rejects shallow or rootless history.
This is a privacy-format gate, not proof that an account exists, that a numeric ID belongs to a
username, or that a commit is authentic.

Detached HEAD and provider-only pull/merge refs are not publishable roots. In particular, CI does
not treat GitHub's synthetic PR merge commit as repository-authored history; it audits the PR head
instead. Synthetic-commit metadata is governed by the account's privacy settings, so enable the
two GitHub controls above before merging. The scanner also cannot inspect unreachable objects,
forks, other clones, or provider caches. A `.mailmap` only changes how some Git tools display
identities; it does not erase the original bytes. Removing persisted metadata requires a
disruptive history rewrite, changes commit and tag object IDs, invalidates old clones and links,
and may require GitHub Support to clear cached views or provider-managed PR refs.

## Live-IPC changes

Changes to the experimental Desktop route (`codex_ipc_client.mjs`, autoload, probes) cannot be
proven by CI — CI never performs live IPC. If your change affects live behavior, say so in the PR,
describe the manual revalidation you ran (`codex_ipc_revalidate.mjs`, and
`codex_ipc_write_proof.mjs` against a thread you own), and update
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) if support/stability changed. Do not claim live
behavior works without having actually run it.

## Commit / PR hygiene

- Keep diffs minimal and focused; update docs in the same PR as behavior changes.
- Update `CHANGELOG.md` under the `[Unreleased]` heading.
