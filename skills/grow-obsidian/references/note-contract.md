# Note contract

## Who the note is for

The note is written for **the user's future self**, skimming their own vault months later. It is a memory aid, not documentation.

Before writing, ask: *if the owner read only this note, would they remember doing this, and feel it was worth keeping?* If the answer is no, the note is wrong — no matter how accurate it is.

## The hard rule: outcomes over mechanics

Most of the technical work in these folders was carried out by an AI assistant on the user's instruction. **Reproducing that mechanism in the vault has almost no value** — the user can simply ask an AI to do it again. What cannot be regenerated is the user's own memory: what they set out to do, what they decided, what came out of it.

Do NOT write into a note:

- prompt text, prompt structure, or prompt-engineering technique;
- JSON/schema field names, config keys, function or script internals;
- pixel dimensions, hashes, thresholds, per-frame metrics, file counts as an end in themselves;
- step-by-step reconstruction of how a script works;
- exhaustive inventories ("read all 8 files, here is each one").

DO write:

- what the thing was and why the user started it, in their own terms;
- the concrete deliverable someone could point at (a proposal, a video, a sprite set, a report);
- decisions and judgments the user made — these are theirs, not the AI's;
- what was learned that would change how they do it next time;
- honest status: finished, blocked, abandoned, waiting on someone.

Mention tooling in **one short phrase**, not a section: "用 Codex 生成了整套精灵图", "写了 Python 脚本自动排版". That is enough for recall; the details live in the source folder, which the note links to.

## Length

Target **under 2 KB** — roughly 30 seconds of reading. A note over 3 KB is almost certainly a mechanics dump; cut it. Depth belongs in the source files, not the vault.

## Structure

```markdown
## 这是什么
2-4 句。第一人称视角：什么时候、为了什么、做了个什么东西。给足能唤起记忆的锚点（时间、场合、对方是谁、什么形态的成果）。

## 做出了什么
3-6 条。看得见的成果物，不是过程。

## 怎么做的
1-3 句。工具和路径一句带过。

## 值得记住的
2-4 条。真正属于用户的判断、踩过的坑、定下的原则、验证过的结论。没有就省略这一节。

## 当前状态
1-2 句。完成 / 卡在哪 / 等谁。

## 进展记录
- YYYY-MM-DD：一句话

## 相关文件
3-5 条最有代表性的路径，不要罗列全部。
```

Omit any section with nothing real to say. Never pad.

## Title

The title must be recognizable to the user at a glance, months later. Use the words they would use — the project's real-world name, the客户/课程/平台, the outcome. Avoid technique-flavored titles ("……提示词与确定性配准") — the user will not recognize their own work in them.

## Grouping

One durable topic per note. Prefer updating an existing canonical note over creating a near-duplicate. Several folders may feed one note; one folder may hold several topics. Split only when the user would genuinely think of them as separate things.

## Facts and inference

Never fabricate. Separate observed facts from inference. When something is uncertain, say so briefly rather than omitting or overstating it. Psychology material is educational reflection, never diagnosis.

## Mechanics

Write generated content only between:

```markdown
<!-- AI-MAINTAINED:START -->
...
<!-- AI-MAINTAINED:END -->
```

Keep human text outside the markers untouched. No YAML inside the generated block. For a new note, prepare a template containing `{{AI_BLOCK}}` and pass it through `apply-note.ps1 -NewNoteTemplatePath`. Recommended properties:

```yaml
---
类型: 项目总结
分类: 工作项目
来源路径: "..."
最近更新: YYYY-MM-DD
状态: ...
标签:
  - 3-5 个
---
```
