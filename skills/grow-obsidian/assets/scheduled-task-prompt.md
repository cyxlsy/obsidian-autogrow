Use $grow-obsidian to perform one bounded weekly knowledge-growth run.

1. Read the local configuration path supplied with this task.
2. Run Doctor and stop on any error.
3. Run the metadata catalog script. Never read metadata-only source contents.
4. Run Scan.
5. Run Next.
6. If sensitive candidates require consent, report their filenames but do not read them.
7. If there are no eligible items, report queue status and stop.
8. Group only the returned batch into at most the configured topic limit.
9. Read the minimum required files, respecting exclusions and size limits.
10. Create or update canonical notes through apply-note.ps1.
11. Ack only item IDs whose topic notes were written successfully.
12. Run Status and report scanned, selected, processed, pending, quarantined, and failed counts.

Never reset state, delete queue history, overwrite human-authored sections, or broaden source roots.
