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

## Length follows how much the project actually mattered

Not every project deserves the same note. Judge from the source folder's file timestamps, which say more than the file count does:

- **活跃天数** — how many distinct calendar days the folder was touched. This is the single best signal: a folder edited on 19 separate days is a real thread in the user's life; one edited on 2 days was a sprint.
- **最后更新距今** — still warm, or finished and gone quiet.

| 信号 | 类型 | 篇幅 | 写法 |
|---|---|---|---|
| 活跃天数 ≥ 3 且 30 天内仍有更新 | **持续推进** | 放宽到 4-6 KB | 允许更长，因为它还在长。`## 进展记录` 按阶段分条，每条写清那个阶段**学会了什么、判断变了什么**，让用户能看见自己的成长轨迹 |
| 活跃天数 ≥ 3 但已超过 30 天没动 | **已完成的正式项目** | ~2 KB | 标准结构，重心仍在 `## 我学到了什么` |
| 活跃天数 ≤ 2，或明显是一次性交付且已停更 | **一次性的事** | 0.5-1 KB | 极简。几行说清「什么时候、为谁、做了什么、结果如何」就够。没有真正的教训就不要硬写 `## 我学到了什么`，宁可只留证明做过 |

Typical one-off: 帮朋友做的一次课程作业、一份交完就结束的文档、一个跑完即弃的脚本。它值得一条记录证明做过，不值得一篇复盘。

The 2 KB ceiling still applies to everything except the 持续推进 tier — depth belongs in the source files, not the vault.

**Merging is not an excuse to exceed the ceiling.** When many runs update one note in turn, each preserving the previous facts and adding its own, the note bloats — this has happened, taking a study-material note to 4.6 KB. Every write owns the whole block: fold duplicate lessons into one sharper line, drop process and counting detail (who found what in which pass, what an intermediate file was called), compress same-day 进展记录 into one line, keep 相关文件 to 3-4 paths. Cut until it fits before writing, not afterwards.

## The heart of the note

The user's own words for what this vault is for: **"我学习了什么、我学会了什么、我做了什么"** — not an information flood.

So `## 我学到了什么` is the most important section, and it should usually be the longest. It holds the things only the user can supply: the judgment they made, the trap they fell into, the rule they now follow, the thing they got wrong the first time. Everything else in the note exists to give that section context.

If a note has nothing in that section, it is probably not worth a note — record it in one line and move on.

## Structure

```markdown
## 这是什么
2-4 句。第一人称：什么时候、为了什么、做了个什么东西。给足回忆锚点（时间、场合、为谁做、成果长什么样）。工具最多一个短句带过（"让 AI 提取整理后排成 Word"），不单独成节。

## 我做了什么
3-5 条。看得见的成果物，不是过程。

## 我学到了什么
2-5 条，本篇重心。用户自己的判断、踩过的坑、定下的原则、被验证或推翻的想法。写成下次还用得上的话，而不是事件复述。

## 当前状态
1-2 句。完成 / 卡在哪 / 等谁。

## 进展记录
- YYYY-MM-DD：一句话

## 相关文件
3-5 条最有代表性的路径，不要罗列全部。
```

There is deliberately **no "怎么做的" section** — mechanism is the thing the user least wants to read. Omit any other section with nothing real to say. Never pad.

## Routing

Ask: **where does this note's value mainly sit?**

| 价值主要在 | 去向 |
|---|---|
| 我完成/交付了一件事（求职、比赛、客户、账号、课程作品） | `04-工作项目` |
| 我学会了一种能力或方法，尤其是 AI/工具的用法与边界 | `03-AI学习` |
| 这是我备考或学习要用的材料（讲义、题库、复习资料） | `90-资料库` |
| 心理学的学习与反思 | `09-心理学` |
| 还没成形的想法 | `02-临时想法` |

A project that produced a deliverable but whose lasting value is "我学会了怎么用 AI 做这件事" belongs in `03-AI学习`, not `04-工作项目`. When two categories both fit, pick the one matching what the user would search for months later, and do not cross-link merely to create a graph edge.

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
