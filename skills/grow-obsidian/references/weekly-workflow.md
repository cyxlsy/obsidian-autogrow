# Weekly workflow

1. Run `Doctor`.
2. Run `Inbox` and clear it first (see below).
3. Run `catalog-metadata.ps1` for metadata-only sources without reading their contents.
4. Run `Scan` to enqueue every stable eligible file version.
5. Run `Next` to receive a fair cross-source batch without changing state.
6. Group files into at most `maxTopicsPerRun` topics.
7. Read only files required for those topics and within size limits.
8. Distill into canonical notes using the note contract.
9. Apply generated blocks with `apply-note.ps1`.
10. Run `Ack` only for queue IDs represented by successful writes.
11. Run `Status` and report remaining work.

## Clearing the inbox

`Inbox` lists everything sitting in the folder named by `destinations.inbox`, minus the folder's own index note, with each item's inbox-relative path, size, modification time, extension, and whether it is plain text.

Read those items — never route one by its filename alone — and decide for each whether it belongs in an existing canonical note or in a category of its own. Apply it through `apply-note.ps1`, then move it out with:

```powershell
& $tool -Command InboxClear -ConfigPath "<controller>\config.local.json" -ItemIds "随手记.md" "clip\screenshot.png"
```

`InboxClear` moves items into `controllerDataRoot\inbox-archive\<timestamp>\` instead of deleting them, so a filing mistake stays recoverable; it also removes folders its own move left empty, while folders that were already empty are left alone. A whole dropped folder clears in one item by passing its path, but a folder and something inside it may not be passed together. Unknown paths, paths escaping the inbox, and the index note are all refused, and one bad path aborts the entire call before anything moves.

Items too vague to place stay in the inbox and are reported. Items flagged `sensitive` are surfaced to the user before being read. If `destinations.inbox` is unconfigured, `Inbox` says so plainly — add the key or skip this step.

## Failure behavior

- Leave items pending after a transient extraction, classification, or write failure; the queue is the retry mechanism.
- Use `Fail -ItemIds <ids> -Reason "<why>"` for permanent failures (corrupt file, unsupported format, oversized) so they stop returning in every batch. `Requeue` reverses it.
- Do not reset cursors to force retries.
- Do not delete queue history during normal runs; use `Compact` for old terminal history.
- A newer file version supersedes an older pending version of the same source path.
- Files deleted from disk are swept to `missing` during `Scan` and return to `pending` if restored.
- Oversized candidates never enter a batch; report them and let the user decide (raise the limit or `Fail` them).

`Next` serves sources oldest-backlog-first, so a source that keeps missing the topic cut rises to the front of later runs and cannot be starved.

Treat historical backfill separately: increase `initialLookbackDays` before the first scan, then process the resulting queue over multiple runs without resetting state. Run `Report` to watch per-source backlog age shrink between runs.

## Maintenance

Roughly monthly, run:

```powershell
& $tool -Command Compact -ConfigPath "<controller>\config.local.json" -OlderThanDays 30 -PruneBackupsOlderThanDays 60
```

This archives old processed/superseded history into `queue-archive.local.json` and removes timestamped backup sets older than the given number of days. Nothing pending, missing, or failed is touched.
