# Contributing

Obsidian AutoGrow (technical name: grow-obsidian) currently targets Windows and PowerShell.

Before submitting changes:

1. Keep private paths and data out of the repository.
2. Preserve the explicit-consent model for discovery and sensitive files.
3. Keep deterministic behavior in scripts and semantic judgment in the Skill workflow.
4. Run the tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\run-tests.ps1"
```

5. Run the publish privacy check before every push (register your own private names and paths in an untracked `.publish-private-patterns.local.txt`, one per line):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\publish-check.ps1"
```

6. Validate the Skill folder with the assistant's skill validator when available.

Changes that broaden default filesystem access, read metadata-only content, overwrite human text, or acknowledge queue items before successful writes should not be accepted.
