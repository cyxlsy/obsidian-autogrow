---
name: grow-obsidian
description: Build, configure, audit, and run a privacy-conscious Obsidian knowledge-growth workflow that scans explicitly approved project folders, queues changes without losing work, distills outcomes into canonical notes, maintains category indexes, and optionally produces creator inspiration from already-distilled knowledge. Use when setting up automatic weekly Obsidian organization, migrating an existing personal automation, recommending a vault taxonomy after an authorized metadata scan, troubleshooting missed or duplicate notes, or preparing a portable GitHub-distributed workflow.
---

# Obsidian AutoGrow

Turn approved project folders into a self-growing Obsidian knowledge base without copying raw work logs or silently monitoring the computer. Keep deterministic scan, queue, validation, and safe-write steps in scripts; use AI only for semantic grouping, classification, summarization, and optional inspiration.

## Guardrails

- Require explicit user approval for every scanned root. Never expand a configured root to a parent drive automatically.
- Default to metadata-only discovery. Read file contents only for queued semantic sources.
- Never read configured exclusions, secret-like files, caches, dependencies, raw mail stores, or private conversation exclusions.
- Keep private paths and state in `config.local.json` and `.local/`; never put them in public examples.
- Never advance work by a global timestamp alone. Enqueue every discovered version before advancing each source cursor.
- Never mark queue items processed until all target notes were written successfully.
- Preserve human-written text. Update only `AI-MAINTAINED` blocks through the safe-write script.
- Keep the graph hierarchy `home -> category index -> content note`. Add cross-links only for real semantic relationships.
- Treat psychology content as educational reflection, not diagnosis.
- Keep creator insights opt-in and derive them from distilled notes, not background surveillance.

## Choose the workflow

- New installation or migration: follow [setup.md](references/setup.md).
- Weekly run or manual preview: follow [weekly-workflow.md](references/weekly-workflow.md).
- Taxonomy recommendation: follow [discovery-and-taxonomy.md](references/discovery-and-taxonomy.md).
- Creator inspiration: follow [creator-insights.md](references/creator-insights.md).
- Privacy or publication review: follow [privacy.md](references/privacy.md).
- Note creation and updates: follow [note-contract.md](references/note-contract.md).

## Core commands

Resolve the script path relative to this file:

```powershell
$tool = "<skill-folder>\scripts\grow-obsidian.ps1"
```

For a brand-new user, generate a starter config first (never overwrites; the file carries a `$schema` reference for editor autocomplete):

```powershell
& $tool -Command NewConfig -TargetPath "<controller>\config.local.json"
```

Run the doctor before any write:

```powershell
& $tool -Command Doctor -ConfigPath "<controller>\config.local.json"
```

List whatever the user dropped into the inbox folder named by `destinations.inbox`:

```powershell
& $tool -Command Inbox -ConfigPath "<controller>\config.local.json"
```

Each item carries its inbox-relative path, size, modification time, extension, and `isPlainText` (whether it can be read directly, or needs a converter as with `.pdf`/`.docx`). The folder's own index note (`<folder>.md`) is never listed. Items flagged `sensitive` are shown to the user before being read, exactly like `Next` candidates. Never route an inbox item by filename alone; open it.

Once an item has been filed into a canonical note, move it out of the inbox with its relative path:

```powershell
& $tool -Command InboxClear -ConfigPath "<controller>\config.local.json" -ItemIds <relative paths>
```

Nothing is deleted: items move to `controllerDataRoot\inbox-archive\<timestamp>\`, keeping their inbox-relative layout, so a wrong distillation can still be recovered. A dropped folder can be cleared as one unit by passing the folder's path; passing a folder and something inside it in the same call is refused. An unknown path, or one escaping the inbox, aborts the whole call before anything moves. Leave anything too vague to place in the inbox and report it.

Scan approved roots and persist every eligible change:

```powershell
& $tool -Command Scan -ConfigPath "<controller>\config.local.json"
```

Request a fair batch without changing its state:

```powershell
& $tool -Command Next -ConfigPath "<controller>\config.local.json"
```

`Next` excludes sensitive candidates and oversized candidates. Show sensitive filenames to the user and run `Approve` only for IDs the user explicitly authorizes. Oversized items (larger than `scanPolicy.maxSemanticFileBytes`) are listed under `oversized`; either retire them with `Fail` or let the user raise the limit.

```powershell
& $tool -Command Approve -ConfigPath "<controller>\config.local.json" -ItemIds <ids>
```

Every command that takes `-ItemIds` accepts full queue IDs or unique prefixes of at least 8 characters.

After every note was safely written, acknowledge only the returned queue IDs:

```powershell
& $tool -Command Ack -ConfigPath "<controller>\config.local.json" -ItemIds <ids>
```

Retire an item that can never be processed (corrupt, unsupported format, oversized), with a reason; reverse with `Requeue`:

```powershell
& $tool -Command Fail -ConfigPath "<controller>\config.local.json" -ItemIds <ids> -Reason "why"
& $tool -Command Requeue -ConfigPath "<controller>\config.local.json" -ItemIds <ids>
```

Show queue counts:

```powershell
& $tool -Command Status -ConfigPath "<controller>\config.local.json"
```

Summarize per-source backlog age and persist a snapshot under `reports/`:

```powershell
& $tool -Command Report -ConfigPath "<controller>\config.local.json"
```

Periodically (for example monthly) archive old processed history and prune old backup sets:

```powershell
& $tool -Command Compact -ConfigPath "<controller>\config.local.json" -OlderThanDays 30 -PruneBackupsOlderThanDays 60
```

Scan marks queued files that vanished from disk as `missing` (they return to `pending` automatically if the file reappears). Sources whose root is unreachable are skipped without advancing their cursor, and partial enumeration failures are recorded in the per-source `lastError` state.

Use `Discover` only after confirming `discovery.consentGranted=true` and reviewing its exact roots. It inventories names, extensions, counts, and modification dates; it does not read content.

## Semantic distillation

A note is a **memory aid for the user's future self**, not documentation. Most of the technical work in these folders was carried out by an AI on the user's instruction — reproducing that mechanism in the vault is worthless, because the user can simply ask an AI to do it again. What cannot be regenerated is their own memory of what they set out to do, decided, and produced.

The heart of every note is `## 我学到了什么` — the user's own judgment, traps, and rules. Never write prompt text, schema/config keys, script internals, or per-frame metrics; mention tooling in one clause at most, and never as its own section. Titles must be recognizable at a glance months later, never technique-flavored.

Length follows how much the project actually mattered, judged from the source folder's **活跃天数** (distinct days it was touched) and how recently: a still-running thread may take 4-6 KB with staged progress, a finished project ~2 KB, a one-off favour 0.5-1 KB with no forced lesson. Route each note by where its value sits — a shipped deliverable to `04-工作项目`, a capability learned (especially about using AI) to `03-AI学习`, study material to `90-资料库`. Full rules: [note-contract.md](references/note-contract.md).

For each `Next` batch:

1. Group files by actual work topic, not merely by folder.
2. Prefer final artifacts, reports, release notes, and meaningful source changes over caches and renders.
3. Locate a canonical note before creating a new one.
4. Distill to what the user would want to remember: why it started, the visible deliverable, their own decisions, lessons that change future behavior, honest status, brief provenance.
5. Separate observed facts from inference.
6. Route to one primary category. Add secondary links only when useful.
7. Write through `scripts/apply-note.ps1`.
8. Acknowledge queue IDs only after every grouped item was applied successfully.

If any write or classification is uncertain, leave the items pending and report the uncertainty. Do not force completion.
