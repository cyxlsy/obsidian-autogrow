# Contributing

Grow Obsidian currently targets Windows and PowerShell.

Before submitting changes:

1. Keep private paths and data out of the repository.
2. Preserve the explicit-consent model for discovery and sensitive files.
3. Keep deterministic behavior in scripts and semantic judgment in the Skill workflow.
4. Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\run-tests.ps1"
```

5. Validate the Skill folder with Codex `quick_validate.py`.

Changes that broaden default filesystem access, read metadata-only content, overwrite human text, or acknowledge queue items before successful writes should not be accepted.
