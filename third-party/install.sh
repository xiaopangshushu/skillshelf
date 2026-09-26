#!/usr/bin/env bash
#
# third-party 技能管理脚本（随 ~/Skills 仓库分发）
# 详见同目录 README.md 与 manifest

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest"

SUBCMD="install"
REQUESTED_PLATFORMS="all"
PLATFORM_SET=0
NAME_OVERRIDE=""
FORCE=0
PURGE=0
YES=0
POSITIONAL=()

ENTRIES=()
E_REPO="" E_NAME="" E_PLATS="" E_BASE="" E_DIR=""

info() { printf '%s\n' "[info] $*"; }
ok()   { printf '%s\n' "[ok]   $*"; }
warn() { printf '%s\n' "[warn] $*"; }
fail() { printf '%s\n' "[fail] $*"; }
die()  { fail "$*"; exit 1; }

usage() {
  cat <<'EOF'
third-party 技能管理脚本

用法: install.sh [子命令] [选项]

子命令:
  add       添加第三方技能：克隆 + 登记 manifest + 建软链 一步完成
  install   按 manifest 克隆缺失仓库并建立软链（默认，幂等可重复运行）
  update    对已克隆仓库执行 git pull
  remove    移除（删除类操作，先出预览、需确认后才执行）:
              remove                  删除全部条目的软链（不动 manifest 与克隆，install 可恢复）
              remove <目标>           移除该条目: 全平台软链 + manifest 登记行
              remove <目标> --purge   在上者基础上再删除本地克隆目录
              目标 = 仓库目录名 / skill名 / 仓库地址片段
  list      manifest 与实际状态对照表
  help      显示本帮助

选项:
  --platform <列表>   平台过滤: opencode / claude / all
                      install/remove/list 默认 all（按 manifest 每行声明执行）
                      add 默认 opencode；remove <目标> 时忽略（定向移除删全平台）
  --name <skill名>    add 用：SKILL.md 没有 name 字段时手动指定 skill名
  --force             覆盖指向别处的软链（永不覆盖真实目录）
  --purge             配合 remove 删除本地克隆目录
  --yes               确认执行删除。非交互环境（如 AI 代跑）必须先看过预览再加此参数；
                      交互终端下可不加，脚本会要求输入 yes

add 用法:
  install.sh add <仓库地址 或 third-party 里的本地目录> [--platform ...] [--name ...]
  - 传 URL：未克隆则自动 clone，已克隆则复用
  - 传目录：必须是 third-party/ 下的 git 仓库
  - 仓库地址取自 git remote origin，skill名 自动读取 SKILL.md 的 name 字段
  - 若该仓库已登记：打印已有行并确认软链状态，不会产生重复行

manifest 格式: 仓库地址 | skill名 | 平台（可选，逗号分隔，默认 opencode）
skill名 必须等于该仓库 SKILL.md 的 name 字段。
EOF
  exit 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

platform_dir() {
  case "$1" in
    opencode) printf '%s' "$HOME/.config/opencode/skills" ;;
    claude)   printf '%s' "$HOME/.claude/skills" ;;
    *) return 1 ;;
  esac
}

platforms_of_line() {
  local raw="$1" p out=""
  [ -n "$raw" ] || raw="opencode"
  for p in $(printf '%s' "$raw" | tr ',' ' '); do
    p="$(trim "$p")"
    [ -n "$p" ] || continue
    out="$out $p"
  done
  printf '%s' "${out# }"
}

validate_requested_platforms() {
  [ "$REQUESTED_PLATFORMS" = "all" ] && return 0
  local p
  for p in $(printf '%s' "$REQUESTED_PLATFORMS" | tr ',' ' '); do
    p="$(trim "$p")"
    [ -n "$p" ] || continue
    platform_dir "$p" >/dev/null || die "未知平台: $p（可选: opencode, claude, all）"
  done
}

request_allows() {
  [ "$REQUESTED_PLATFORMS" = "all" ] && return 0
  local p
  for p in $(printf '%s' "$REQUESTED_PLATFORMS" | tr ',' ' '); do
    [ "$(trim "$p")" = "$1" ] && return 0
  done
  return 1
}

link_points_to() {
  [ "$(readlink "$1" 2>/dev/null)" = "$2" ]
}

skill_md_name() {
  local f="$1/SKILL.md" v
  [ -f "$f" ] || return 1
  v="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -n 1 | sed 's/["'\'']//g')"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

confirm_or_die() { # $1=确认说明；预览必须先打印
  if [ "$YES" = "1" ]; then
    return 0
  fi
  if [ -t 0 ]; then
    local ans=""
    printf '%s' ">>> $1 —— 输入 yes 确认执行: "
    read -r ans
    [ "$ans" = "yes" ] || die "已取消，未做任何改动"
  else
    die "非交互环境：以上是删除预览，未做任何改动。确认无误后加 --yes 重新执行"
  fi
}

load_manifest() { # $1=1 允许空条目（add 场景）
  [ -f "$MANIFEST" ] || die "manifest 不存在: $MANIFEST"
  local line
  ENTRIES=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    case "$line" in
      ""|"#"*) continue ;;
    esac
    ENTRIES+=("$line")
  done < "$MANIFEST"
  if [ "${#ENTRIES[@]}" -eq 0 ] && [ "${1:-}" != "1" ]; then
    die "manifest 没有有效条目"
  fi
}

parse_entry() {
  local line="$1" repo rest name plats base
  repo="${line%%|*}"
  rest="${line#*|}"
  [ "$rest" = "$line" ] && die "manifest 行缺少 '|' 分隔: $line"
  name="${rest%%|*}"
  if [ "$name" = "$rest" ]; then
    plats=""
  else
    plats="${rest#*|}"
  fi
  repo="$(trim "$repo")"
  name="$(trim "$name")"
  plats="$(trim "$plats")"
  [ -n "$repo" ] || die "manifest 行缺仓库地址: $line"
  [ -n "$name" ] || die "manifest 行缺 skill名: $line"
  case "$name" in
    */*|*" "*) die "skill名 不合法（不能含 / 或空格）: $name" ;;
  esac
  base="${repo##*/}"
  base="${base%.git}"
  [ -n "$base" ] || die "无法从仓库地址解析目录名: $repo"
  E_REPO="$repo"
  E_NAME="$name"
  E_PLATS="$plats"
  E_BASE="$base"
  E_DIR="$SCRIPT_DIR/$base"
}

ensure_link() { # $1=平台 $2=skill名 $3=克隆目录(绝对路径)
  local p="$1" name="$2" tdir="$3" dir link
  request_allows "$p" || { info "[$p] 已被 --platform 过滤跳过: $name"; return 0; }
  dir="$(platform_dir "$p")"
  mkdir -p "$dir"
  link="$dir/$name"
  if [ -L "$link" ]; then
    if link_points_to "$link" "$tdir"; then
      ok "[$p] 软链已存在: $link"
    elif [ "$FORCE" = "1" ]; then
      ln -sfn "$tdir" "$link" && ok "[$p] 已强制重建软链: $link -> $tdir"
    else
      warn "[$p] 软链已存在且指向别处，跳过: $link -> $(readlink "$link")（--force 可覆盖）"
    fi
  elif [ -e "$link" ]; then
    warn "[$p] 已存在同名真实目录，跳过: $link"
  else
    ln -s "$tdir" "$link" && ok "[$p] 已创建软链: $link -> $tdir"
  fi
}

cmd_install() {
  command -v git >/dev/null 2>&1 || die "未找到 git，请先安装"
  validate_requested_platforms
  load_manifest
  local line seen=" " n_clone=0 n_have=0 n_fail=0
  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    case "$seen" in
      *" $E_NAME "*)
        warn "skill名 重复，跳过该行: $E_NAME ($E_REPO)"
        n_fail=$((n_fail+1))
        continue
        ;;
    esac
    seen="$seen$E_NAME "

    if [ -d "$E_DIR/.git" ]; then
      ok "已存在克隆，跳过: $E_BASE"
      n_have=$((n_have+1))
    elif [ -e "$E_DIR" ]; then
      warn "目录已存在但不是 git 仓库，跳过克隆: $E_DIR"
      n_fail=$((n_fail+1))
      continue
    else
      info "克隆: $E_REPO -> $E_DIR"
      if git clone "$E_REPO" "$E_DIR"; then
        if [ -f "$E_DIR/.gitmodules" ]; then
          git -C "$E_DIR" submodule update --init --recursive >/dev/null 2>&1 \
            || warn "子模块初始化失败: $E_BASE"
        fi
        n_clone=$((n_clone+1))
      else
        fail "克隆失败: $E_REPO"
        n_fail=$((n_fail+1))
        continue
      fi
    fi

    local md_name
    if md_name="$(skill_md_name "$E_DIR")"; then
      if [ "$md_name" != "$E_NAME" ]; then
        warn "SKILL.md 的 name 为 '$md_name'，与 manifest 的 skill名 '$E_NAME' 不一致（软链按 manifest 建为 $E_NAME）"
      fi
    else
      warn "未找到 SKILL.md 或缺少 name 字段: $E_DIR/SKILL.md"
    fi

    local p
    for p in $(platforms_of_line "$E_PLATS"); do
      ensure_link "$p" "$E_NAME" "$E_DIR"
    done
  done
  info "install 完成: 新克隆 $n_clone，已有 $n_have，异常 $n_fail"
}

normalize_repo() {
  local r="$1"
  r="${r%/}"
  r="${r%.git}"
  printf '%s' "$r"
}

cmd_add() {
  command -v git >/dev/null 2>&1 || die "未找到 git，请先安装"
  local target="${POSITIONAL[0]:-}"
  [ -n "$target" ] || die "用法: install.sh add <仓库地址 或 third-party 里的本地目录> [--platform opencode,claude] [--name skill名]"
  case "$target" in
    -*) die "未知选项: $target" ;;
  esac

  local add_plats
  if [ "$PLATFORM_SET" = "1" ]; then
    add_plats="$REQUESTED_PLATFORMS"
  else
    add_plats="opencode"
  fi
  if [ "$add_plats" = "all" ]; then
    add_plats="opencode claude"
  fi
  local p
  for p in $(printf '%s' "$add_plats" | tr ',' ' '); do
    p="$(trim "$p")"
    [ -n "$p" ] || continue
    platform_dir "$p" >/dev/null || die "未知平台: $p（可选: opencode, claude）"
  done

  local dir="" base=""
  case "$target" in
    http://*|https://*|git@*|ssh://*|git://*)
      base="${target##*/}"
      base="${base%.git}"
      [ -n "$base" ] || die "无法从仓库地址解析目录名: $target"
      dir="$SCRIPT_DIR/$base"
      if [ -d "$dir/.git" ]; then
        ok "克隆已存在，复用: $dir"
      elif [ -e "$dir" ]; then
        die "目录已存在但不是 git 仓库，请手动处理: $dir"
      else
        info "克隆: $target -> $dir"
        git clone "$target" "$dir" || die "克隆失败: $target"
      fi
      ;;
    *)
      local abs="$target"
      case "$abs" in
        /*) ;;
        *) abs="$PWD/$abs" ;;
      esac
      if [ -d "$abs" ]; then
        abs="$(cd "$abs" && pwd)"
      else
        die "目录不存在: $target"
      fi
      case "$abs" in
        "$SCRIPT_DIR") die "请指向 third-party/ 下具体的项目目录，而不是目录本身" ;;
        "$SCRIPT_DIR"/*) ;;
        *) die "本地目录必须位于 $SCRIPT_DIR 下: $abs" ;;
      esac
      [ -d "$abs/.git" ] || die "不是 git 仓库（缺少 .git）: $abs"
      dir="$abs"
      ;;
  esac

  local remote
  remote="$(git -C "$dir" remote get-url origin 2>/dev/null || git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$remote" ] || die "无法读取 origin 远程地址，请检查该仓库是否设置过 remote: $dir"
  base="${dir##*/}"
  local url_base="${remote##*/}"
  url_base="${url_base%.git}"
  if [ "$base" != "$url_base" ]; then
    warn "本地目录名 '$base' 与仓库地址解析的目录名 '$url_base' 不一致，install/update/remove 将以 '$url_base' 为准；建议把目录重命名为 '$url_base'"
  fi

  local name
  if [ -n "$NAME_OVERRIDE" ]; then
    name="$NAME_OVERRIDE"
  else
    name="$(skill_md_name "$dir" || true)"
    [ -n "$name" ] || die "无法从 SKILL.md 读取 name 字段: $dir/SKILL.md（可用 --name 手动指定）"
  fi
  case "$name" in
    */*|*" "*) die "skill名 不合法（不能含 / 或空格）: $name" ;;
  esac

  load_manifest 1

  local line found_repo="" found_name="" found_plats=""
  if [ "${#ENTRIES[@]}" -gt 0 ]; then
    for line in "${ENTRIES[@]}"; do
      parse_entry "$line"
      if [ "$(normalize_repo "$E_REPO")" = "$(normalize_repo "$remote")" ]; then
        found_repo="$E_NAME"
        found_name="$E_NAME"
        found_plats="$E_PLATS"
        break
      fi
      if [ -z "$found_name" ] && [ "$E_NAME" = "$name" ]; then
        found_name="$E_NAME"
      fi
    done
  fi

  if [ -n "$found_repo" ]; then
    ok "该仓库已在 manifest 登记（skill名: $found_repo），无需重复添加:"
    printf '       %s\n' "$line"
    local q
    for q in $(platforms_of_line "$found_plats"); do
      ensure_link "$q" "$found_name" "$dir"
    done
    return 0
  fi

  if [ -n "$found_name" ]; then
    die "skill名 '$name' 已被条目 '$found_name' 使用，软链会冲突；请修改 manifest 或用 --name 指定其他名字"
  fi

  printf '%s | %s | %s\n' "$remote" "$name" "$add_plats" >> "$MANIFEST"
  ok "已登记 manifest: $remote | $name | $add_plats"
  warn "manifest 已修改，请记得自行提交到 Skills 仓库（git add third-party/manifest && git commit）"

  local q
  for q in $(printf '%s' "$add_plats" | tr ',' ' '); do
    q="$(trim "$q")"
    [ -n "$q" ] || continue
    ensure_link "$q" "$name" "$dir"
  done
  info "add 完成。运行 'install.sh list' 查看状态"
}

cmd_update() {
  load_manifest
  local line n=0 n_ok=0 n_missing=0 n_fail=0
  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    n=$((n+1))
    if [ -d "$E_DIR/.git" ]; then
      info "更新: $E_BASE"
      if git -C "$E_DIR" pull --ff-only; then
        n_ok=$((n_ok+1))
      else
        fail "更新失败: $E_BASE"
        n_fail=$((n_fail+1))
      fi
    else
      info "未克隆，跳过（先运行 install）: $E_BASE"
      n_missing=$((n_missing+1))
    fi
  done
  info "update 完成: 共 $n，更新 $n_ok，未克隆 $n_missing，失败 $n_fail"
}

remove_links_of_entry() { # 删除当前 E_ 条目的全部平台软链（只删指向本克隆的）
  local p dir link
  for p in $(platforms_of_line "$E_PLATS"); do
    dir="$(platform_dir "$p")"
    link="$dir/$E_NAME"
    if [ -L "$link" ]; then
      if link_points_to "$link" "$E_DIR"; then
        rm "$link" && ok "[$p] 已删除软链: $link"
      else
        warn "[$p] 软链不指向本克隆目录，跳过: $link -> $(readlink "$link")"
      fi
    elif [ -e "$link" ]; then
      warn "[$p] 是真实目录，不删除: $link"
    fi
  done
}

cmd_remove_all() {
  validate_requested_platforms
  load_manifest
  [ "${#ENTRIES[@]}" -gt 0 ] || die "manifest 为空，没有可移除的条目"

  info "──── 删除预览: remove（全部软链）────"
  local line p dir link total=0
  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    for p in $(platforms_of_line "$E_PLATS"); do
      request_allows "$p" || continue
      dir="$(platform_dir "$p")"
      link="$dir/$E_NAME"
      if [ -L "$link" ] && link_points_to "$link" "$E_DIR"; then
        info "  删除软链: $link"
        total=$((total+1))
      fi
    done
  done
  [ "$total" -gt 0 ] || die "没有指向本目录克隆的软链可删除"
  info "  不动 manifest，不删本地克隆（install 可一键恢复软链）"
  info "────────────────────────────"
  confirm_or_die "删除以上全部软链"

  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    remove_links_of_entry
  done
  info "remove 完成: 已删除全部软链。运行 install 可恢复"
}

cmd_remove_target() { # $1=目标（仓库目录名 / skill名 / 仓库地址片段）
  if [ "$PLATFORM_SET" = "1" ]; then
    warn "定向移除会删除该条目全部平台的软链，--platform 已忽略"
  fi
  load_manifest
  [ "${#ENTRIES[@]}" -gt 0 ] || die "manifest 为空，没有可移除的条目"

  local target="$1" line hit
  local -a match_lines=()
  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    hit=0
    [ "$E_BASE" = "$target" ] && hit=1
    [ "$E_NAME" = "$target" ] && hit=1
    if [ "$hit" -eq 0 ]; then
      case "$(normalize_repo "$E_REPO")" in
        *"$target"*) hit=1 ;;
      esac
    fi
    [ "$hit" -eq 1 ] && match_lines+=("$line")
  done

  local n=${#match_lines[@]}
  if [ "$n" -eq 0 ]; then
    warn "没有匹配 '$target' 的条目。现有条目:"
    for line in "${ENTRIES[@]}"; do printf '  %s\n' "$line"; done
    exit 1
  fi
  if [ "$n" -gt 1 ]; then
    warn "匹配到多条不同条目，请用更精确的目录名或 skill名 指定:"
    for line in "${match_lines[@]}"; do printf '  %s\n' "$line"; done
    exit 1
  fi

  local target_line="${match_lines[0]}"
  parse_entry "$target_line"

  info "──── 删除预览: remove $target ────"
  info "将移除条目: $target_line"
  local p dir link
  for p in $(platforms_of_line "$E_PLATS"); do
    dir="$(platform_dir "$p")"
    link="$dir/$E_NAME"
    if [ -L "$link" ] && link_points_to "$link" "$E_DIR"; then
      info "  删除软链: $link"
    fi
  done
  info "  删除 manifest 登记行（文件: $MANIFEST）"
  if [ "$PURGE" = "1" ]; then
    if [ -d "$E_DIR/.git" ]; then
      info "  删除本地克隆目录: $E_DIR"
    else
      warn "  本地克隆不存在或不是 git 仓库，purge 将跳过: $E_DIR"
    fi
  else
    info "  保留本地克隆: $E_DIR（--purge 可同时删除）"
  fi
  info "────────────────────────────"
  confirm_or_die "确认移除条目 '$E_NAME'"
  if [ "$PURGE" = "1" ]; then
    if [ "$YES" = "1" ]; then
      info "--purge 模式: 磁盘文件删除已经过确认"
    else
      confirm_or_die "purge 将永久删除磁盘目录 $E_DIR（第 2 次确认）"
    fi
  fi

  remove_links_of_entry

  local tmp="$MANIFEST.tmp"
  awk -v t="$target_line" '{ l=$0; gsub(/^[ \t]+|[ \t]+$/, "", l); if (l != t) print }' "$MANIFEST" > "$tmp" \
    || { rm -f "$tmp"; die "写临时文件失败: $tmp"; }
  mv "$tmp" "$MANIFEST"
  ok "已从 manifest 移除登记行: $target_line"
  warn "manifest 已修改，请记得自行提交到 Skills 仓库"

  if [ "$PURGE" = "1" ]; then
    if [ -d "$E_DIR/.git" ]; then
      rm -rf "$E_DIR" && ok "已删除本地克隆: $E_DIR"
    elif [ -e "$E_DIR" ]; then
      warn "不是 git 克隆目录，purge 跳过: $E_DIR"
    else
      info "本地克隆不存在，跳过 purge: $E_DIR"
    fi
  else
    info "本地克隆已保留: $E_DIR"
  fi
  info "remove 完成（条目: $E_NAME）。如需恢复，重新运行 add 即可"
}

cmd_list() {
  load_manifest
  local line
  printf '%-24s %-14s %-18s %-8s %s\n' "仓库目录" "skill名" "平台" "已克隆" "软链状态"
  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    local cloned="-" linkstat="" md_name="" nameflag=""
    [ -d "$E_DIR/.git" ] && cloned="yes"
    if md_name="$(skill_md_name "$E_DIR")"; then
      [ "$md_name" = "$E_NAME" ] || nameflag=" [SKILL.md: $md_name]"
    fi
    local p dir link
    for p in $(platforms_of_line "$E_PLATS"); do
      dir="$(platform_dir "$p")"
      link="$dir/$E_NAME"
      if [ -L "$link" ]; then
        if link_points_to "$link" "$E_DIR"; then
          linkstat="$linkstat $p:linked"
        else
          linkstat="$linkstat $p:wrong-target"
        fi
      elif [ -e "$link" ]; then
        linkstat="$linkstat $p:occupied"
      else
        linkstat="$linkstat $p:missing"
      fi
    done
    [ -n "$linkstat" ] || linkstat=" (无平台声明)"
    printf '%-24s %-14s %-18s %-8s %s%s\n' "$E_BASE" "$E_NAME" "${E_PLATS:-opencode}" "$cloned" "$linkstat" "$nameflag"
  done
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      install|update|remove|list|add)
        SUBCMD="$1"
        ;;
      help|-h|--help)
        usage
        ;;
      --platform)
        [ $# -ge 2 ] || die "--platform 需要参数"
        REQUESTED_PLATFORMS="$(trim "$2")"
        PLATFORM_SET=1
        shift
        ;;
      --platform=*)
        REQUESTED_PLATFORMS="$(trim "${1#*=}")"
        PLATFORM_SET=1
        ;;
      --name)
        [ $# -ge 2 ] || die "--name 需要参数"
        NAME_OVERRIDE="$(trim "$2")"
        shift
        ;;
      --name=*)
        NAME_OVERRIDE="$(trim "${1#*=}")"
        ;;
      --force)
        FORCE=1
        ;;
      --purge)
        PURGE=1
        ;;
      --yes|-y)
        YES=1
        ;;
      -*)
        die "未知选项: $1（help 查看用法）"
        ;;
      *)
        POSITIONAL+=("$1")
        ;;
    esac
    shift
  done

  case "$SUBCMD" in
    add)
      [ "${#POSITIONAL[@]}" -le 1 ] || die "add 只接受一个 仓库地址或目录 参数"
      cmd_add
      ;;
    install)
      [ "${#POSITIONAL[@]}" -eq 0 ] || die "install 不接受位置参数"
      cmd_install
      ;;
    update)
      [ "${#POSITIONAL[@]}" -eq 0 ] || die "update 不接受位置参数"
      cmd_update
      ;;
    remove)
      [ "${#POSITIONAL[@]}" -le 1 ] || die "remove 最多接受一个目标参数（仓库目录名 / skill名 / 仓库地址片段）"
      if [ "${#POSITIONAL[@]}" -eq 1 ]; then
        cmd_remove_target "${POSITIONAL[0]}"
      else
        cmd_remove_all
      fi
      ;;
    list)
      [ "${#POSITIONAL[@]}" -eq 0 ] || die "list 不接受位置参数"
      cmd_list
      ;;
  esac
}

main "$@"
