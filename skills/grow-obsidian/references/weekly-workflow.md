# Weekly workflow

1. Run `Doctor`.
2. Run `catalog-metadata.ps1` for metadata-only sources without reading their contents.
3. Run `Scan` to enqueue every stable eligible file version.
4. Run `Next` to receive a fair cross-source batch without changing state.
5. Group files into at most `maxTopicsPerRun` topics.
6. Read only files required for those topics and within size limits.
7. Distill into canonical notes using the note contract.
8. Apply generated blocks with `apply-note.ps1`.
9. Run `Ack` only for queue IDs represented by successful writes.
10. Run `Status` and report remaining work.

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
