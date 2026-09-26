# bookmark-organizer

Chrome 书签整理技能：把浏览器书签整理成**分类清晰的可导入 HTML**、**可搜索的 llm-wiki 知识库页面**和**交互式知识图谱**。支持增量整理——以后新增书签，一条命令几秒完成。

## 朋友安装（三步）

前提：装好 [opencode](https://opencode.ai)、python3；图谱功能需要 jq + Node 20+（可选）。

### 第 1 步：放技能

把整个 `bookmark-organizer/` 文件夹放到你的技能目录（二选一）：

```bash
# 方式 A：有 ~/Skills/mine 仓库（opencode.json 配了 skills.path 指向它）
cp -r bookmark-organizer ~/Skills/mine/

# 方式 B：直接放 opencode 技能目录
cp -r bookmark-organizer ~/.config/opencode/skills/
```

### 第 2 步：装命令

```bash
mkdir -p ~/.config/opencode/commands
cp bookmark-organizer/command/bookmarks.md ~/.config/opencode/commands/
```

### 第 3 步：重启 opencode，输入

```
/bookmarks
```

首次运行会引导你：选择 Chrome profile → 初始化知识库（llm-wiki init）→ 隐私确认 → 全量整理（出对照表给你确认）→ 生成产物。

## 日常使用

| 命令 | 作用 |
|---|---|
| `/bookmarks` | 增量整理：只处理新增/消失书签，无变化秒回 |
| `/bookmarks full` | 全量重整（先出对照表确认） |
| `/bookmarks status` | 查看上次整理状态（只读） |

## 产物

| 产物 | 用途 |
|---|---|
| `书签整理-<日期>.html` | Chrome → 书签管理器 → 导入书签，一键换新分类 |
| `wiki/entities/书签-*.md` | 之后问 AI「XX 书签在哪」直接命中 |
| `wiki/knowledge-graph.html` | 双击离线打开的可点击图谱 |

## 自定义分类

- 出厂规则在 `scripts/categories.json`（12 个顶级分类 + 路径映射）
- 首次运行后会复制到知识库 `raw/bookmarks/work/`，**改副本**才会生效（保留出厂态便于升级）
- 也可以直接告诉 AI："把 XX 类书签单独归一类"，它会帮你改规则

## 注意

- Chrome 原生书签文件**只读**，本技能绝不修改它；替换书签请用"导出 HTML → 导入"流程
- 消失的书签（你在浏览器删了）只提醒，不会自动从知识库删除
- 整理前会做一次隐私确认（内网地址、个人信息等会原样进入 wiki）
