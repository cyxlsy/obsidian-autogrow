Use $grow-obsidian to perform one bounded weekly knowledge-growth run.

1. Read the local configuration path supplied with this task.
2. Run Doctor and stop on any error.
3. Run the metadata catalog script. Never read metadata-only source contents.
4. Run Scan.
5. Run Next.
6. If sensitive candidates require consent, report their filenames but do not read them.
7. If oversized candidates are listed, report them; do not read them and do not Fail them without the user's decision.
8. If there are no eligible items, report queue status and stop.
9. Group only the returned batch into at most the configured topic limit.
10. Read the minimum required files, respecting exclusions and size limits.
11. Create or update canonical notes through apply-note.ps1.
12. Ack only item IDs whose topic notes were written successfully. If a file is unreadable or corrupt, use Fail with a short reason instead of retrying forever.
13. Run Status and Report, then summarize scanned, selected, processed, pending, missing, quarantined, oversized, and failed counts.

Never reset state, delete queue history, overwrite human-authored sections, or broaden source roots.
