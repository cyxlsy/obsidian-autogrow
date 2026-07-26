English | [简体中文](README.md)

# Obsidian AutoGrow

### Let the projects you have already done grow into a reviewable Obsidian knowledge base — automatically

You keep writing documents, running projects, and editing code on your computer as usual. **Obsidian AutoGrow** scans the folders you have explicitly approved once a week, lets an AI agent (such as Codex or Claude Code) analyze what was actually accomplished, which problems were solved, and which methods were learned, and then creates or updates project notes in Obsidian.

You never have to re-organize a whole project by hand after the work is done.

> The product is currently in **Alpha** and is aimed at Windows + AI agent + Obsidian users who are willing to test and give feedback.

## Understand it in 30 seconds

| What you normally do | What AutoGrow does automatically | What you get in Obsidian |
|---|---|---|
| Write docs, build slides, edit code in project folders | Detects which projects really changed this week | One canonical note named after the project's content |
| One project produces many drafts, test files, and final versions | Picks the most representative artifacts and distills them | Outcomes, problems, methods, status, and next steps |
| Several projects move forward at the same time | Queues them fairly by source and topic, nothing gets lost | Clear category indexes and a continuously updated record |
| Lots of work files pile up in office folders | Reads only file names, dates, and sizes | A searchable file catalog |
| You keep solving similar problems | Looks for patterns in the already-distilled notes | Optional inspiration for articles, videos, or tools |

For example, a folder that originally contains:

```text
final-delivery.docx
proposal_condensed.md
test-notes.md
interview-material.pdf
```

is not copied into your vault as four files. AutoGrow distills it into:

```markdown
# Content Operations and Job-Application Delivery

## Outcomes this round
## Problems solved
## Reusable methods
## Current status and next steps
## Sources
```

## Who it is for

- People who use an AI agent (Codex or Claude Code) together with Obsidian and want less manual organizing;
- Creators, developers, students, and freelancers with multiple project directories;
- People who want to keep a record of "what I did and what I learned" without copying work logs;
- People who want a knowledge base grown from real project outcomes, not another bookmark pile.

## What it will NOT do

- It will not scan your whole computer by default;
- It will not read directories you have not authorized;
- It will not copy full chats, emails, or raw project text into the knowledge base;
- It will not read the body of files in directories marked "metadata only";
- It will not overwrite human-written notes outside the AI-maintained regions;
- It will not present psychological speculation as diagnosis or fact;
- It will not analyze keystrokes, browsing history, or personality.

## How it works

```text
Approved project directories
       ↓
Metadata scan and persistent queue
       ↓
AI semantic distillation
       ↓
Safe writes to AI-maintained regions
       ↓
Obsidian categories and canonical notes
```

Scanning, privacy exclusions, queuing, and safe writes are done by deterministic scripts. The AI is only responsible for the parts that require understanding: topic grouping, classification, distillation, and optional inspiration.

The technical invocation name stays `$grow-obsidian`; the product name on GitHub and in user-facing text is **Obsidian AutoGrow**.

## Main capabilities

- Every source keeps its own independent scan cursor;
- Items not processed in a batch stay in the queue — they are never lost just because a timestamp moved forward;
- Sources rotate into batches by "oldest backlog first", so no source is starved indefinitely by other active projects;
- A newer version of a file automatically supersedes the older pending version of the same path;
- Files that were deleted or renamed are marked `missing` instead of clogging the queue forever;
- Files over the size limit are listed separately and stop consuming batch slots;
- Sensitive file names (e.g. chat logs, psychological analysis) are quarantined automatically and are read only after explicit approval;
- Unknown or misspelled keys in the config produce warnings during the health check, so privacy protection never fails silently;
- Only `AI-MAINTAINED` marker regions are ever modified;
- The current file hash can be verified before writing;
- A backup is created outside the vault before an existing note is modified;
- `Report` (backlog overview) and `Compact` (history archiving, backup pruning) maintenance commands are included;
- Directory discovery requires explicit consent and reads metadata only by default;
- Creator insights are off by default and can only analyze already-distilled notes.

## Command overview

| Command | Purpose |
|---|---|
| `NewConfig` | Generate a starter config (with a `$schema` reference for editor autocomplete) |
| `Doctor` | Config health check: paths, overlaps, required fields, unknown-key warnings |
| `Init` | Initialize state, queue, backup, and report directories |
| `Scan` | Scan sources and enqueue changes; sweep `missing` files; record scan errors |
| `Next` | Read out one fair batch (read-only); lists sensitive and oversized files separately |
| `Approve` | Authorize reading of quarantined sensitive files |
| `Ack` | Acknowledge items whose notes were written successfully |
| `Fail` / `Requeue` | Retire items that cannot be processed / restore them to the queue |
| `Status` | Queue counts per state |
| `Report` | Per-source backlog counts and oldest backlog age; snapshot saved to `reports/` |
| `Compact` | Archive old history to `queue-archive.local.json`; optionally prune old backups |
| `Discover` | (Explicit consent required) metadata-only directory inventory |

`-ItemIds` accepts full queue IDs or unique prefixes of at least 8 characters.

## Environment

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7
- An AI agent, such as Codex or Claude Code
- Obsidian

The vault can live on a local disk or inside a cloud-sync folder, but do not let two sync programs edit the same local repository at the same time.

## Installing the skill

### Recommended: let your agent install it

Send this to Codex or Claude Code:

```text
Please install the grow-obsidian skill from
https://github.com/cyxlsy/obsidian-autogrow,
then guide me step by step through choosing my Obsidian vault,
the project folders allowed for scanning, and the weekly run time.
Do not scan any other directory without my explicit approval.
```

You only need to decide three things:

1. Where your Obsidian vault is;
2. Which project folders may be analyzed, and which directories get a metadata-only file catalog;
3. When the weekly organization run should happen.

### Manual installation

Clone the repository, then copy:

```text
skills/grow-obsidian
```

to the skill directory of your agent:

- **Codex**: `%USERPROFILE%\.codex\skills\grow-obsidian`
- **Claude Code**: `%USERPROFILE%\.claude\skills\grow-obsidian`

After installing, start a new session and ask the agent to use `$grow-obsidian`.

## First-run configuration

1. Generate a starter config with one command (it never overwrites an existing file):

```powershell
& ".\skills\grow-obsidian\scripts\grow-obsidian.ps1" -Command NewConfig -TargetPath ".\config.local.json"
```

The generated file carries a `$schema` reference to [config.schema.json](skills/grow-obsidian/assets/config.schema.json), so editors like VS Code give you autocomplete and hover documentation for every field.

2. Fill in the vault location, private data directories, and the project directories you explicitly allow.
3. Run:

```powershell
$tool = ".\skills\grow-obsidian\scripts\grow-obsidian.ps1"
& $tool -Command Doctor -ConfigPath ".\config.local.json"
& $tool -Command Init -ConfigPath ".\config.local.json"
& $tool -Command Scan -ConfigPath ".\config.local.json"
& $tool -Command Next -ConfigPath ".\config.local.json"
```

Process only one small batch the first time, inspect the generated notes, and enable the weekly scheduled task only after that manual run looks right.

## Vault structure

Keep a simple three-level hierarchy:

```text
Home page
└─ Category indexes
   └─ Topic or project notes
```

Do not add meaningless links just to make the graph look richer. Project folders do not need to map one-to-one to knowledge categories.

## Creator insights

When enabled, the system can look through your already-distilled outcomes for:

- Problems that appeared repeatedly and are worth explaining in public;
- Methods and tools that have already taken shape;
- Unsolved problems that are worth further experiments;
- Project relationships that could combine into articles, videos, or tools.

It only produces suggestions backed by sources. It does not analyze keystrokes, browsing history, or personality, and it never presents speculation as fact.

## Privacy

The following must never be committed to GitHub:

- `config.local.json`
- `.local/`
- Private paths, queues, logs, backups
- Obsidian vault content
- Mail and chat exports
- Private exclusion lists
- Directory discovery results

See [SECURITY.md](SECURITY.md) for the exact boundaries.

## Routine maintenance

When the backlog is large (for example after backfilling months of history), the weekly batches will take several rounds to catch up. Recommended habits:

- After each run, check the "oldest backlog age" in the `Report` output and confirm it keeps decreasing;
- Run `Compact -OlderThanDays 30 -PruneBackupsOlderThanDays 60` about once a month so queue files and backups do not grow forever;
- Oversized files listed by `Next` (larger than `maxSemanticFileBytes`) are never processed automatically: either raise the limit or retire them with `Fail`.

## Testing

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\run-tests.ps1"
```

The tests run in the system temp directory and cover: the lossless queue, directory pruning, sensitive-file quarantine and approval, fair batching (oldest backlog first), oversized-file exclusion, short ID prefixes, the acknowledgment mechanism, human-content protection, conflict detection, refusal to write into broken markers, backups, supersede, `missing` sweeps, `Fail`/`Requeue`, `Compact` archiving and backup pruning, the `Discover` consent gate, and `Report`. Compatible with Windows PowerShell 5.1 and PowerShell 7.
