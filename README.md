# Obsidian AutoGrow

简体中文 | [English](README.en.md)

### 让你做过的项目，自动长成可回顾的 Obsidian 知识库

你照常在电脑里写方案、做项目、改代码。**Obsidian AutoGrow** 每周扫描你明确允许的文件夹，让 Codex 分析真正完成了什么、解决了什么问题、学到了什么方法，然后创建或更新 Obsidian 中的项目笔记。

你不需要在完成工作后，再把整个项目手工整理一遍。

> 产品当前处于 Alpha 阶段，适合愿意测试和反馈的 Windows + Codex + Obsidian 用户。

## 30秒看懂它

| 你平时做的事情 | AutoGrow 自动完成 | Obsidian里得到 |
|---|---|---|
| 在项目文件夹中写方案、做PPT、修改代码 | 识别本周真正变化的项目 | 一篇以项目内容命名的主笔记 |
| 一个项目产生很多草稿、测试稿和最终稿 | 选择最有代表性的成果并提炼 | 成果、问题、方法、状态和下一步 |
| 多个项目同时推进 | 按来源和主题公平排队，不遗漏 | 清晰的分类目录和持续更新记录 |
| WPS中有大量工作文件 | 只读取文件名、日期和大小 | 一个方便查找的文件索引 |
| 反复解决相似问题 | 从已整理的笔记中寻找模式 | 可选的文章、视频或工具灵感 |

例如，一个文件夹里原本有：

```text
final-delivery.docx
方案_精简版.md
测试记录.md
采访资料.pdf
```

AutoGrow不会把四个文件复制进笔记，而是整理成：

```markdown
# 公众号内容运营与求职交付

## 本轮成果
## 解决的问题
## 可复用方法
## 当前状态与下一步
## 来源依据
```

## 它适合谁

- 同时使用 Codex 和 Obsidian，希望减少手工整理的人；
- 有多个项目目录的创作者、开发者、学生和自由职业者；
- 希望保留“自己做过什么、学会什么”，但不想复制工作日志的人；
- 希望知识库由真实项目成果生长，而不是变成收藏夹的人。

## 它不会做什么

- 不会默认扫描整台电脑；
- 不会读取未经授权的目录；
- 不会把完整聊天、邮件或项目原文复制进知识库；
- 不会读取标记为“仅元数据”的WPS文件正文；
- 不会覆盖AI维护区域以外的人工笔记；
- 不会把心理学推测写成诊断或事实；
- 不会分析键盘记录、浏览记录或人格。

## 工作方式

```text
已授权项目目录
       ↓
元数据扫描与持久队列
       ↓
Codex语义提炼
       ↓
安全更新AI维护区域
       ↓
Obsidian分类与主笔记
```

扫描、隐私排除、队列和安全写入由确定性脚本完成；AI只负责需要理解语义的主题聚合、分类、提炼和可选灵感。

技术调用名保持为 `$grow-obsidian`；GitHub产品名和界面名称使用 **Obsidian AutoGrow**。

## 主要能力

- 每个来源拥有独立扫描进度；
- 批次没有处理完的内容留在队列中，不会因更新时间推进而丢失；
- 按"积压最久优先"轮流进入批次，任何来源都不会被其他活跃项目无限期挤占；
- 新版本自动取代同一路径的旧待处理版本；
- 被删除或改名的文件自动标记为 missing，不会永远堵在队列里；
- 超过大小限制的文件单独列出，不会反复占用批次名额；
- 敏感文件名（如聊天记录、心理分析）自动隔离，须明确授权才会读取；
- 配置里出现未知或拼错的键会在体检时收到警告，隐私保护不会静默失效；
- 只修改 `AI-MAINTAINED` 标记区域；
- 写入前可校验当前文件哈希；
- 修改已有笔记前在知识库外生成备份；
- 提供 `Report`（积压概览）与 `Compact`（历史归档、备份清理）维护命令；
- 目录发现必须明确授权，并且默认只读取元数据；
- 创作者灵感默认关闭，只能分析已经提炼的笔记。

## 命令一览

| 命令 | 作用 |
|---|---|
| `NewConfig` | 生成配置骨架（带编辑器自动补全的 `$schema` 引用） |
| `Doctor` | 配置体检：路径、重叠、必填项、未知键警告 |
| `Init` | 初始化状态、队列、备份与报告目录 |
| `Scan` | 扫描来源并入队；清扫 missing 文件；记录扫描错误 |
| `Next` | 只读取出一个公平批次；单列敏感与超大文件 |
| `Approve` | 授权读取被隔离的敏感文件 |
| `Ack` | 确认写入成功的条目 |
| `Fail` / `Requeue` | 淘汰无法处理的条目 / 恢复重排 |
| `Status` | 队列各状态计数 |
| `Report` | 各来源积压数量与最老积压天数，快照存入 `reports/` |
| `Compact` | 归档旧历史到 `queue-archive.local.json`，可选清理旧备份 |
| `Discover` | （须明确同意）只读元数据的目录盘点 |

`-ItemIds` 接受完整队列 ID 或不少于 8 位的唯一前缀。

## 环境

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7
- Codex桌面端
- Obsidian

知识库可以位于本地磁盘或云盘同步目录，但不要让两个同步程序同时编辑同一个本地仓库。

## 安装 Skill

### 推荐：直接让 Codex 安装

把下面这段话发给 Codex：

```text
请从 https://github.com/cyxlsy/obsidian-autogrow 安装 grow-obsidian Skill，
然后一步一步引导我选择 Obsidian 仓库、允许扫描的项目文件夹和每周运行时间。
未经我明确批准，不要扫描其他目录。
```

用户只需要决定三件事：

1. Obsidian仓库在哪里；
2. 哪些项目文件夹允许分析，哪些目录只建立文件索引；
3. 每周什么时候自动整理。

### 手动安装

克隆仓库后，将 `skills/grow-obsidian` 复制到你所用 AI 助手的技能目录：

| 助手 | 技能目录 |
|---|---|
| Codex | `%USERPROFILE%\.codex\skills\grow-obsidian` |
| Claude Code | `%USERPROFILE%\.claude\skills\grow-obsidian` |

安装后重新打开任务，让助手使用 `$grow-obsidian`（Claude Code 中为 `/grow-obsidian`）。

## 初次配置

1. 一条命令生成配置骨架（不会覆盖已有文件）：

```powershell
& ".\skills\grow-obsidian\scripts\grow-obsidian.ps1" -Command NewConfig -TargetPath ".\config.local.json"
```

配置文件带有 `$schema` 引用（[config.schema.json](skills/grow-obsidian/assets/config.schema.json)），在 VS Code 里编辑时每个字段都有自动补全和悬停说明。

2. 填写知识库位置、私人数据目录和你明确允许分析的项目目录。
3. 运行：

```powershell
$tool = ".\skills\grow-obsidian\scripts\grow-obsidian.ps1"
& $tool -Command Doctor -ConfigPath ".\config.local.json"
& $tool -Command Init -ConfigPath ".\config.local.json"
& $tool -Command Scan -ConfigPath ".\config.local.json"
& $tool -Command Next -ConfigPath ".\config.local.json"
```

第一次只处理一个小批次，检查生成笔记后再启用每周自动任务。

## 知识库结构

推荐保持简单的三级层级：

```text
总首页
└─ 分类索引
   └─ 具体主题或项目笔记
```

不要为了让图谱看起来丰富而添加无意义链接。项目文件夹与知识分类也不必一一对应。

## 创作者灵感

开启后，系统可以从已经沉淀的成果中寻找：

- 多次出现、值得公开讲解的问题；
- 已经形成的方法和工具；
- 尚未解决但适合继续实验的问题；
- 可以组合成文章、视频或开发工具的项目关系。

它只生成有来源依据的建议，不分析键盘、浏览记录或人格，也不把推测写成事实。

## 隐私

以下内容不应提交到GitHub：

- `config.local.json`
- `.local/`
- 私人路径、队列、日志、备份
- Obsidian仓库内容
- 邮件和聊天导出
- 私人排除名单
- 目录发现结果

详细边界见 [SECURITY.md](SECURITY.md)。

## 日常维护

积压较多时（例如首次回填了几个月的历史），每周批次会分多轮消化。建议：

- 每次运行后看一眼 `Report` 输出的"最老积压天数"，确认在持续下降；
- 大约每月运行一次 `Compact -OlderThanDays 30 -PruneBackupsOlderThanDays 60`，防止队列文件和备份无限膨胀；
- `Next` 列出的超大文件（超过 `maxSemanticFileBytes`）不会自动处理：要么调大限制，要么用 `Fail` 淘汰。

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\run-tests.ps1"
```

测试在系统临时目录中验证：无损队列、目录剪枝、敏感文件隔离与授权、公平批次（最老积压优先）、超大文件排除、短 ID 前缀、确认机制、人工内容保护、冲突检测、残缺标记拒写、备份、supersede、missing 清扫、Fail/Requeue、Compact 归档与备份清理、Discover 同意门槛和 Report。兼容 Windows PowerShell 5.1 与 PowerShell 7。
