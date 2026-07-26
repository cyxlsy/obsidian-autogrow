# Note contract

Use `home -> category index -> canonical content note`.

A content note links to its category index. It does not link directly to the home merely to create a graph edge.

Use one semantic title per durable topic. Dates belong in properties and progress sections, not filenames.

Recommended properties:

```yaml
---
type: project
status: active
category: work-projects
created: YYYY-MM-DD
updated: YYYY-MM-DD
source_ids:
  - example
---
```

Write generated content only between:

```markdown
<!-- AI-MAINTAINED:START -->
...
<!-- AI-MAINTAINED:END -->
```

Keep human text outside the markers untouched. Include only useful sections: topic, outcomes, problems solved, reusable knowledge, current status, next step, and concise provenance. Omit empty sections and never copy raw conversations or large passages.

For a new note, prepare a template containing `{{AI_BLOCK}}` and pass it through `apply-note.ps1 -NewNoteTemplatePath`. Do not place YAML inside the generated block.
