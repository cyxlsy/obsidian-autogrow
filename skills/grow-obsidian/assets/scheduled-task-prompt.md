Use $grow-obsidian to perform one bounded weekly knowledge-growth run.

1. Read the local configuration path supplied with this task.
2. Run Doctor and stop on any error.
3. Run Inbox. Read each listed item, file it into the right canonical note or category through apply-note.ps1, then move it out with InboxClear. Leave anything too vague to place, and report it. Skip this step if the config has no `destinations.inbox`.
4. Run the metadata catalog script. Never read metadata-only source contents.
5. Run Scan.
6. Run Next.
7. If sensitive candidates require consent, report their filenames but do not read them.
8. If oversized candidates are listed, report them; do not read them and do not Fail them without the user's decision.
9. If there are no eligible items, report queue status and stop.
10. Group only the returned batch into at most the configured topic limit.
11. Read the minimum required files, respecting exclusions and size limits.
12. Create or update canonical notes through apply-note.ps1.
13. Ack only item IDs whose topic notes were written successfully. If a file is unreadable or corrupt, use Fail with a short reason instead of retrying forever.
14. Run Status and Report, then summarize scanned, selected, processed, pending, missing, quarantined, oversized, and failed counts, plus how many inbox items were filed and how many remain.

Never reset state, delete queue history, overwrite human-authored sections, or broaden source roots.
