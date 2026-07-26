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

- Leave items pending after any extraction, classification, or write failure.
- Do not reset cursors to force retries; the queue is the retry mechanism.
- Do not delete queue history during normal runs.
- A newer file version supersedes an older pending version of the same source path.

`Next` selects items round-robin across semantic sources so a noisy source cannot monopolize a run.

Treat historical backfill separately: increase `initialLookbackDays` before the first scan, then process the resulting queue over multiple runs without resetting state.
