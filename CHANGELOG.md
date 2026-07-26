# Changelog

## Unreleased (2026-07-26)

### 笔记规范重写（第四轮，来自首位用户的真实反馈）

首轮自动生成的笔记被用户否定：单篇高达 29-38KB，堆满提示词、JSON 字段名、像素指标和脚本内部实现，用户表示"看到标题都想不起这是个啥"。

核心洞察：**这些技术细节本来就是 AI 代为完成的，可以随时让 AI 重做一遍，留在个人知识库里没有价值；不可再生的是用户自己的意图、判断和成果记忆。**

- `references/note-contract.md` 全面重写：笔记定位为"给未来的自己看的记忆锚点"，**2KB 上限**（约 30 秒读完），第一人称，必须给出回忆锚点（时间、场合、成果形态）。
- 明令禁止写入：提示词原文与技法、JSON/schema 字段名、配置键、脚本内部、像素/哈希/阈值、逐帧指标、文件清单、机制复述。工具只允许一句话带过。
- 必须保留：为什么开始、看得见的成果物、**用户自己的决策与判断**、会改变下次做法的教训、诚实的状态。
- 标题必须让用户数月后一眼认出，禁止技法味标题（如"……提示词与确定性配准"）。
- `SKILL.md` 的语义提炼章节同步更新，把该原则前置为每轮运行的首要约束。

### 产品化（第三轮）

- **`NewConfig` 命令**：一条命令生成配置骨架，绝不覆盖已有文件，并输出后续步骤指引。
- **配置 JSON Schema**（`assets/config.schema.json`）：`config.example.json` 带 `$schema` 引用，VS Code 中每个字段有自动补全与悬停说明；CI 中用 `Test-Json` 验证示例配置。
- **英文 README**（`README.en.md`）：面向国际用户，中英 README 顶部互链。
- **发布隐私检查**（`tools/publish-check.ps1`）：推送前扫描已跟踪文件与全部 git 历史——本地私有文件误跟踪、含非 ASCII 字符的盘符路径、非 noreply 邮箱、以及用户在未跟踪的 `.publish-private-patterns.local.txt` 中登记的私人标识；已接入 CI。
- **双平台安装文档**：Codex（`%USERPROFILE%\.codex\skills`）与 Claude Code（`%USERPROFILE%\.claude\skills`）。
- `.gitignore` 补充 `*.local.txt` 与私人特征清单文件名。

### 修复（第二轮：多代理对抗审查确认的 14 项）

- **Requeue 状态守卫**：不再允许复活 superseded 条目（会导致同一文件与其新版本同时排队、被重复提炼）。
- **Compact 归档时间基准**：supersede 时打上 `supersededUtc` 时间戳，Compact 按"终结时间"而非发现时间归档，刚被取代的条目不会被立即归档、Requeue 恢复路径不再失效。
- **游标保持**：部分目录不可读（占位文件、杀毒锁定、权限问题）时不再推进该来源游标，这些目录里的文件下轮自动重试，不会被永久跳过。
- **云盘兼容遍历**：只剪枝 Junction/SymbolicLink（防环），OneDrive/Google Drive 云端占位目录（同样带重解析点属性）正常下钻；另加 100 层深度上限兜底。
- **excludedPaths 追溯生效**：向 `privacy.excludedPaths` 新增路径后，已入队的旧条目也会被 `Next` 排除（与 sensitiveNameFragments 的实时判定行为一致），并以 `excludedCount` 显示。
- **catalog 只覆盖自己生成的文件**：目标文件缺少生成哨兵行时拒绝覆盖并报告 `SKIPPED_HUMAN_FILE`，人工笔记不再可能被索引重写。
- **绝对 destination 拒绝**：`metadataOnlySources[].destination` 为绝对路径时 Doctor 与 catalog 都直接报错（原先在 PS5.1 下抛异常、在 PS7 下静默绕过库内检查）。
- **metadata/semantic 重叠检查**：元数据目录与语义目录互相包含时 Doctor 报错，防止"仅元数据"目录的正文被语义扫描读取。
- **maxFilesPerTopic 校验**：小于 1 报错（0 会静默停摆队列、负数会让 Next 崩溃）；`maxFilesPerTopic × maxTopicsPerRun > maxFilesPerBatch` 时警告（前面的主题可能吃满预算、延迟其他来源）。
- **features/creatorInsights 未知键警告**：拼错 `enabled`/`creatorInsights` 不再静默绕过 distilled-notes-only 校验。
- **StrictMode 属性守卫**：`metadataOnlySources` 缺省、metadata 源缺 `title`/`label`、`discovery.roots` 缺省时不再抛 PropertyNotFoundException。

### 修复

- **公平调度饥饿**：`Next` 原先按字母序轮询来源分配主题名额；当来源数量多于每轮主题上限时，字母序靠后的来源会被无限期饿死。现改为"积压最久优先"排序，错过名额的来源会在后续运行中自动升到队首。
- **僵尸队列项**：入队后被删除或改名的文件原先永远停留在 pending，反复占用批次。现在 `Scan` 会把磁盘上已消失的文件清扫为 `missing`，文件恢复后自动回到 `pending`。
- **超大文件堵塞**：`maxSemanticFileBytes` 原先没有任何代码强制执行，超限文件照常进入批次。现在 `Next` 将其单独列在 `oversized` 中，不进入批次。
- **扫描错误静默丢失**：目录枚举失败原先被静默吞掉且游标照常前进。现在无法访问的来源根目录会被跳过且不推进游标；部分目录不可读会记入来源状态 `lastError`。
- **PowerShell 5.1 编码**：所有脚本统一保存为带 BOM 的 UTF-8，避免中文字面量在 Windows PowerShell 5.1 下被误读为 ANSI。
- **单元素数组解包**：修复 `Resolve-ItemIds` 返回单个 ID 时在 StrictMode 下 `.Count` 报错的问题。

### 新增

- `Fail` / `Requeue` 命令：淘汰永远无法处理的条目（损坏、格式不支持、超大）并记录原因；可逆。
- `Report` 命令：各来源积压数量、最老积压天数、敏感与超大统计，快照存入 `reports/`。
- `Compact` 命令：将超过指定天数的 processed/superseded 历史归档到 `queue-archive.local.json`，可选清理旧的时间戳备份目录。
- 所有 `-ItemIds` 参数支持不少于 8 位的唯一 ID 前缀，不必复制完整 64 位哈希。
- `Doctor` 全面加强：校验 `metadataOnlySources`（readFileContents、destination 在库内、路径存在）、必填 scanPolicy 字段、来源与 controllerDataRoot 重叠；对未知/拼错的配置键发出警告，防止隐私配置静默失效；不可达的来源根目录降级为警告（Scan 跳过且不丢数据），仅当全部来源不可达时报错。
- 扫描与目录发现改用剪枝遍历：被忽略目录（node_modules、.git 等）不再被完整枚举后过滤，同时跳过重解析点避免符号链接环。
- 新增共享库 `scripts/common.ps1`，消除三个脚本中重复的路径、原子写入与哈希代码。

### 测试与工程

- 测试从 7 项断言扩展到 22 项场景：敏感隔离与前缀授权、超大排除、supersede、missing 清扫、Fail/Requeue、Compact 归档与备份清理、冲突检测、残缺标记拒写、Discover 同意门槛、未知键警告、最老积压优先公平性等。
- 新增 GitHub Actions 工作流，在 Windows PowerShell 5.1 与 PowerShell 7 双引擎上运行测试。

### 兼容性

- 队列与状态文件保持 schemaVersion 1，旧版本产生的队列条目（缺少 `consentStatus`/`topicKey` 字段）可直接继续使用，无需迁移。
