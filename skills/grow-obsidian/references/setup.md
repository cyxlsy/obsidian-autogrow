# Setup and migration

## New installation

1. Copy `assets/config.example.json` to a controller directory as `config.local.json`.
2. Ask the user for the Obsidian vault path and every source root.
3. Explain semantic sources versus metadata-only catalogs.
4. Add only explicitly approved paths.
5. Run `Doctor`.
6. Optionally run `Discover` and present taxonomy suggestions before creating folders.
7. Create only approved category folders and index notes.
8. Run `Scan`, then `Next`, as a dry first pass.
9. Distill one small batch and verify it in Obsidian before scheduling.
10. Create one weekly Codex scheduled task only after the manual run succeeds.

## Migration

Keep the old automation intact until the new queue completes a real manual run.

1. Copy source roots, vault path, destinations, and exclusions into `config.local.json`.
2. Do not copy the old global checkpoint as authoritative state.
3. Set `initialLookbackDays` to cover the desired migration window.
4. Run `Scan`; inspect queue counts.
5. Process a small batch.
6. Verify marker-bounded updates, category links, and backups.
7. Switch the scheduled task only after approval.

## Scheduling

Prefer weekly execution for intermittent personal work. The scheduled prompt should run `Doctor`, `Scan`, `Next`, distill and safely apply a bounded batch, acknowledge only successful IDs, and print a concise report.

The computer and Codex desktop app must be running for local scheduled tasks.
