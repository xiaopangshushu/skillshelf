# Skills
我的个人技能仓库（本地技能在 mine/，第三方技能在 third-party/）。
技能清单见 MANIFEST.md。

## 目录说明
- conventions/ — 开发规范、协作规范
- tech_design/ — 技术方案、实现记录
- tasks/ — 任务看板、进度跟踪
- reviews/ — 评审记录、复盘总结
- plans/ — 版本计划、决策记录
- frontend/ — 前端专项技能
- ai/ — AI 相关技能
- office/ — 日常办公技能
- meta/ — 仓库自身治理技能
  - meta/init-skills-repo/ — 初始化技能仓库的技能（提示词原文存档）
- workspace-manager/ — Workspace 索引管理技能
- folder-organizer/ — 文件夹整理顾问技能
- platforms — 软链平台配置文件（install.sh 使用）

## SKILL.md 规范

每个技能目录必须包含 `SKILL.md`，且开头有 YAML frontmatter：

```markdown
---
name: 目录名
description: 一句话说明用途与触发场景
---
```

- `name` 必须等于目录名（`third-party/install.sh` 的 install/list 按它建软链，各平台按它注册技能）
- `description` 用于各终端的技能匹配与触发，建议写清触发场景

## 软链平台配置

`platforms` 文件控制 `install.sh install` 为 mine 技能建软链的目标平台：

- 取第一条有效行（空行与 `#` 开头的行忽略），逗号分隔，当前值: `opencode`
- 优先级: `--platform` 参数 > 本文件 > 默认 `opencode`
- 接入新平台（如 mimo code）: 先在 `third-party/install.sh` 的 `platform_dir()` 加目录映射，再在本文件追加平台名
