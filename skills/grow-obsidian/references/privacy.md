# Privacy and publication

## Local privacy

- Use explicit allowlists for roots and extensions.
- Exclude hidden folders, dependencies, caches, credentials, exports, and user-defined private paths.
- Reject source roots that contain the vault or overlap another source.
- Limit semantic reads by file size.
- Keep local config, state, queue, backups, logs, exports, and discovery inventories outside the vault when possible.
- Redact secrets from logs and summaries.
- Quarantine paths matching `sensitiveNameFragments`; require explicit item approval before semantic reading.

Filename filtering is not sufficient protection. Read only the minimum file required for a queued topic.

## GitHub publication

Never publish personal drive paths, vault contents, local state or queue, backups, logs, ChatGPT or mail exports, private exclusions, WPS indexes, or source inventories. Publish only placeholder examples.
