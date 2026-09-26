# third-party 第三方技能

本目录存放从 GitHub 克隆的第三方 Skill。

## 这是什么

目录里除以下 3 个管理文件外，其余都是 `git clone` 下来的第三方项目（各自带有自己的 `.git`）：

| 文件 | 作用 | 是否入库 |
| --- | --- | --- |
| `README.md` | 本说明 | 是 |
| `manifest` | 第三方技能清单 | 是 |
| `install.sh` | 一键安装 / 更新 / 移除脚本 | 是 |

> 注意：`third-party/` 本身是主仓库的普通目录，它自己没有 `.git`；嵌套的 `.git` 都在各克隆项目的内部。

## 为什么第三方项目不纳入 Git

第三方仓库自带 `.git`，直接 `git add` 会产生嵌套仓库（gitlink）问题。

主仓库的 `.gitignore` 用 `third-party/*` 排除所有克隆项目，再用 `!` 白名单保留上面 3 个管理文件。因此 `git status` 里看不到第三方项目属于正常现象。

## manifest 格式

每行一条，用 `|` 分隔：

```
仓库地址 | skill名 | 平台（可选）
```

- 以 `#` 开头的行为注释，空行忽略
- **skill名**：软链接的目录名，必须等于该仓库 `SKILL.md` 里的 `name` 字段（注意不一定等于 GitHub 仓库名）
- **平台**：逗号分隔；不填默认 `opencode`；可选值 `opencode`、`claude`
- 想让某个技能同时出现在多个终端：手动把这行的平台改成 `opencode,claude`，然后重新运行 `install`，脚本会自动补建缺失的软链

## 使用方法

### OpenCode 用户

```
/third-party add <仓库地址>    # 克隆 + 登记 manifest + 建软链，一步完成（推荐）
/third-party install           # 按 manifest 克隆缺失仓库 + 建软链（幂等，可重复运行）
/third-party update            # 更新已克隆的第三方仓库（git pull）
/third-party list              # 查看 manifest 与实际安装状态对照表
/third-party remove            # 删除全部条目的软链（不动 manifest/克隆，需确认）
/third-party remove bbb        # 移除单个条目：软链 + manifest 登记行（需确认）
/third-party remove bbb --purge  # 再删除本地克隆 third-party/bbb/（需确认）
/third-party help              # 显示完整帮助
```

### 添加新的第三方技能（推荐流程）

不用手写 manifest，一条命令搞定：

```
/third-party add https://github.com/xxx/yyy.git
```

脚本会自动完成：克隆到本目录（已克隆则复用）→ 从 `git remote origin` 读取规范仓库地址 → 读取 `SKILL.md` 的 `name` 字段作为 skill名 → 查重 → 追加 manifest → 建软链。

- **已经手动 clone 过**：`/third-party add yyy`，直接登记 `third-party/` 里已有的目录
- **SKILL.md 没有 name 字段**：加 `--name 手动指定skill名`
- **要多个平台**：加 `--platform opencode,claude`
- **仓库已登记过**：打印已有行并确认软链状态，不会产生重复行
- **skill名 冲突**（不同仓库用了同一个 name）：报错拒绝，避免软链冲突
- 添加成功后 manifest 有改动，**记得自行 git commit**

### 移除第三方技能

`remove` 是删除类操作，**永远先出预览、确认后才执行**（脚本在非交互环境下必须加 `--yes`，交互终端下要求输入 `yes`）：

| 命令 | 动作 |
| --- | --- |
| `remove` | 删除**全部**条目的软链，不动 manifest 和克隆（`install` 可恢复） |
| `remove bbb` | 移除单个条目：该条目全平台软链 + manifest 登记行，克隆保留 |
| `remove bbb --purge` | 在上者基础上再删除本地克隆目录 `third-party/bbb/` |

- 目标可以是**仓库目录名 / skill名 / 仓库地址片段**，匹配到多条会列出让你精确指定
- 定向移除不受 `--platform` 影响（整体注销，删全平台软链）
- 被删的 manifest 行会打印出来，想恢复照着重新 `add` 即可
- 软链只删指向本目录克隆的；manifest 改写用临时文件原子替换，不会写坏
- 移除后 manifest 有改动，**记得自行 git commit**

### 恢复心法

**反悔就 `add`，批量重建就 `install`。**

| 移除操作 | 恢复方式 |
| --- | --- |
| `remove` | `install` 一键恢复（manifest 和克隆都没动，只重建软链） |
| `remove bbb` | `add bbb` 秒恢复（克隆还在，复用不下载，只补登记行 + 软链） |
| `remove bbb --purge` | `add <仓库地址>` 重新下载（登记行和文件都没了） |

原理：manifest 是唯一事实来源，`install` 只按 manifest 工作。`remove` 不动 manifest 所以可逆；`remove bbb` 删了登记行，install 就"不认识" bbb 了；`--purge` 连文件都删，只能重新下载。

### 非 OpenCode 用户（如纯 Claude Code）

脚本随仓库分发，直接用 bash 运行即可：

```
bash third-party/install.sh install --platform claude
bash third-party/install.sh add https://github.com/xxx/yyy.git
```

`--platform` 在 install/remove/list 里是过滤器（`opencode` / `claude` / `all`），不带时按 manifest 每行声明的平台执行；在 add 里指定新条目的平台，默认 `opencode`。

### 别人 clone 了我的 Skills 之后

1. 确认 `third-party/manifest` 存在（它随 Git 分发）
2. 运行 `bash third-party/install.sh install`（OpenCode 用户也可用 `/third-party install`）

脚本会读取 manifest，逐个 clone 到本目录，并按平台建立软链接。

## 软链接规则

| 平台 | 扫描目录 |
| --- | --- |
| opencode | `~/.config/opencode/skills/<name>/` |
| claude | `~/.claude/skills/<name>/` |

- 软链目录名 = manifest 里的 skill名 = SKILL.md 的 `name` 字段
- 脚本永远创建**绝对路径**软链，指向本目录下对应的克隆项目
- 目标位置已存在同名目录/软链时，脚本默认跳过并警告；`--force` 可覆盖指向别处的软链，但**永远不会覆盖真实目录**

## 如果不想要第三方技能

跳过安装步骤即可。`third-party/` 里没有克隆项目时，你的 Skills 主仓库依然完整可用；软链不存在时各平台只是识别不到对应技能，无其他影响。

## 安全提示

第三方 Skill 的 SKILL.md 内容会被注入到 AI 上下文中，可能影响 AI 行为。**只添加你信任的仓库**；添加前建议先浏览其 `SKILL.md` 与最近提交记录。
