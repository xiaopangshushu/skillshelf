---
description: Chrome 书签整理：增量归类新增书签，重生成导入 HTML、wiki 页面与知识图谱（关键词：书签、整理、归类、增量、bookmark）
---

执行 Chrome 书签整理任务。完整工作流见 bookmark-organizer 技能（SKILL_DIR = ~/Skills/mine/bookmark-organizer，若该目录不存在则提示用户先安装此技能）。读取并遵循其 SKILL.md，脚本入口为 ${SKILL_DIR}/scripts/bookmark_tools.py。

下面是本次指令的参数，即用户在 /bookmarks 后面输入的全部内容：

【参数开始】$ARGUMENTS【参数结束】

## 执行规则
1. 模式判定：参数为空或 `inc` → 增量整理；`full` → 全量重整（先出对照表等确认）；`status` → 只读状态查询后即止。
2. 按 SKILL.md 的 Bootstrap 定位知识库（`.wiki-schema.md` 或 `~/.llm-wiki-path`）与 Chrome 书签文件（只读，多 profile 时让用户选）。
3. 按顺序执行 解析 → 映射(自动增量对比) → 生成产物 → 重建图谱；每步成功后再进行下一步，任何一步报错就停下如实说明，不要跳步。
4. 增量结果为「新增 0 / 消失 0」时告知用户无变化并结束，不生成任何产物。
5. 全量模式、或出现大量未匹配书签、或要移除消失书签时：先列清单，等用户明确确认后再写入。
6. 首次对某知识库整理前，按 SKILL.md 做一次隐私确认。
7. 禁止修改 Chrome 原生书签文件；禁止改动技能目录内的出厂 categories.json / preferences.json（运行时改动只发生在知识库 work 目录的副本）；删除类操作必须先确认。
8. 完成后汇报：新增/消失数量与清单、产物路径（HTML / wiki 页面 / 图谱）、Chrome 导入步骤提醒。

## 用法示例
- `/bookmarks` —— 增量整理：只处理新增/消失书签，无变化则秒回
- `/bookmarks full` —— 全量重整：重出完整对照表，确认后重建全部产物
- `/bookmarks status` —— 查看上次整理时间、书签总数与分类分布（只读）
