# init-skills-repo 技能

用于初始化个人技能仓库的目录结构。

## 触发场景

当用户想新建一套技能仓库，或想调整现有仓库的分类结构时使用。

## 核心步骤

1. 在用户主目录下创建 MySkills 文件夹
2. 创建 conventions、tech_design、tasks、reviews、plans 等分类目录
3. 每个分类目录里创建占位 SKILL.md
4. 创建 README.md 说明目录结构
5. 打印目录树供用户确认

## 边界

- 不覆盖已存在的目录
- 不擅自删除任何文件
