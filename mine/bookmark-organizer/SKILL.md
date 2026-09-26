---
name: bookmark-organizer
description: Chrome 书签整理：解析浏览器书签，按分类规则归类改名，生成可导入的 Netscape 书签 HTML、可搜索的 llm-wiki 知识库页面与交互式知识图谱。支持增量整理（只处理新增书签）。触发词：书签整理、整理书签、归类书签、bookmarks。
---

# bookmark-organizer — Chrome 书签整理技能

把 Chrome 书签整理成：全新分类结构的导入 HTML + llm-wiki 知识库页面（可搜索）+ 交互式图谱。增量模式只处理新增/消失的书签，几秒钟完成。

## 依赖

- `python3`（必需）
- `jq` + `node >= 20`（仅图谱构建需要；缺失时跳过图谱并告知用户）
- 可选：llm-wiki 技能（source 页缓存联动；缺失时降级为直接写文件）

## 核心概念（先读这个）

- **工作目录 (work)**：知识库内的 `raw/bookmarks/work/`，存放解析快照、映射结果、改名清单
- **知识库 (wiki-root)**：llm-wiki 知识库根目录（含 `.wiki-schema.md`）
- **分类规则**：`scripts/categories.json`（12 个顶级分类 + 旧结构映射规则 + URL 特例）
- **个人偏好**：`scripts/preferences.json`（改名规则、导出位置、Chrome 路径）
- **身份映射**：浏览器里的书签已经是本工具输出的分类结构时（路径以顶级分类名开头），自动映射回自身——所以第二次运行天然就是增量

## 工作流

### 模式判定

用户在命令/对话里的参数：

| 参数 | 模式 |
|---|---|
| （空）或 `inc` | **增量整理**（默认） |
| `full` | **全量重整**（重出对照表给用户确认后再生成产物） |
| `status` | **只看状态**，不做任何写入 |

### 模式：status

```bash
python3 ${SKILL_DIR}/scripts/bookmark_tools.py status --work "<work>"
```
输出上次整理时间、书签总数、分类分布。只读，到此结束。

### 前置：Bootstrap（首次使用或环境变化时）

1. **定位知识库**：当前目录有 `.wiki-schema.md` 则用之；否则读 `~/.llm-wiki-path`；都没有 → 提示先运行 llm-wiki 的 init（或询问用户创建位置），创建后写入 `~/.llm-wiki-path`
2. **确保 work 目录**：`<wiki-root>/raw/bookmarks/work/`，不存在则创建，并把 `${SKILL_DIR}/scripts/` 下的 `categories.json`、`preferences.json` 复制进去（**副本**，后续改动都改副本，技能目录保持出厂态）
3. **找 Chrome 书签源文件**（只读，绝不修改）：
   - macOS: `~/Library/Application Support/Google/Chrome/*/Bookmarks`
   - Linux: `~/.config/google-chrome/*/Bookmarks`
   - 多 profile 时列出各 profile 书签数，让用户选（默认 `Default`）

### 模式：增量整理（默认）

按顺序执行，**每步等上一步成功再继续**：

1. **快照**（只读源文件）：
   ```bash
   cp "<Chrome书签文件>" "<wiki-root>/raw/bookmarks/chrome-bookmarks-source.json"
   ```
2. **解析**：
   ```bash
   python3 ${SKILL_DIR}/scripts/bookmark_tools.py parse --src "<快照或profile名>" --work "<work>"
   ```
3. **映射 + 增量对比**（自动备份上次结果为 `bookmarks-mapped-prev.json`）：
   ```bash
   python3 ${SKILL_DIR}/scripts/bookmark_tools.py map --work "<work>"
   ```
   - 输出 `新增 N / 消失 M`
   - **N=0 且 M=0** → 告诉用户"书签无变化"，结束
   - 出现 `未匹配` → 把未匹配书签列给用户，询问归入哪个分类，把规则补进 work 目录的 `categories.json` 后重跑（不要改技能目录的出厂规则）
4. **生成产物**（增量模式下无新增时跳过；有变化时直接生成，完成后汇报）：
   ```bash
   python3 .../bookmark_tools.py html --work "<work>" --out "<wiki-root>/../书签整理-<日期>.html"
   python3 .../bookmark_tools.py wiki --work "<work>" --wiki-root "<wiki-root>"
   ```
5. **重建图谱**（有 node>=20 + jq 时；用 llm-wiki 的脚本）：
   ```bash
   bash <llm-wiki>/scripts/build-graph-data.sh "<wiki-root>"
   bash <llm-wiki>/scripts/build-graph-html.sh "<wiki-root>"
   ```
6. **汇报**：新增/消失清单、产物路径、导入提醒（导入 Chrome → 检查"已导入"文件夹 → 删除旧结构 → 拖到书签栏）

**消失的书签**（浏览器里已删但知识库还有）：只列清单提醒，**不自动从 wiki 删除**；用户要求时才按 llm-wiki 的 delete 流程处理。

### 模式：全量重整（full）

同增量 1-3 步，但第 3 步后**必须先出完整对照表**给用户确认：

```bash
python3 .../bookmark_tools.py report --work "<work>" --out "<wiki-root>/raw/bookmarks/work/对照表.md"
```

用户确认分类树和改名后才执行 4-6 步。首次使用（work 里没有 mapped）等同 full。

## 隐私确认（首次对某知识库执行前必须问一次）

> 书签里可能包含敏感内容（内网地址、个人账号页、私密文件夹等）。整理产物（wiki 页面、HTML）会保留全部书签。确认继续请回复 y。

用户明确肯定才继续；否定则终止。同一知识库确认过一次即可（记录在 work/meta.json 的 `privacy_confirmed: true`）。

## 边界与禁止

1. **绝不修改** Chrome 原生书签文件（`~/Library/.../Bookmarks`），只读复制
2. 技能目录 `scripts/categories.json`、`preferences.json` 是出厂默认——运行时改动只发生在 work 目录的副本
3. 删除类操作（去重、移除消失书签）必须先列清单确认
4. 图谱脚本需要 Node 20+（如 nvm：`export PATH="$HOME/.nvm/versions/node/vXX/bin:$PATH"`）；缺环境时跳过图谱并说明，不阻塞主流程
5. 不读取书签内容指向的网页（只处理标题/URL/文件夹元数据）

## 产物一览

| 产物 | 路径 | 用途 |
|---|---|---|
| 书签 HTML | `书签整理-<日期>.html` | Chrome 导入（Netscape 格式） |
| 分类页面 ×N | `wiki/entities/书签-<分类>.md` | 搜索「XX 书签在哪」 |
| 总览页 | `wiki/topics/书签总览.md` | 分类导航 |
| 素材页 | `wiki/sources/chrome书签快照.md` | 知识库溯源 |
| 交互图谱 | `wiki/knowledge-graph.html` | 双击离线浏览 |
| 对照表 | `work/对照表.md` | 全量模式的人工确认 |
