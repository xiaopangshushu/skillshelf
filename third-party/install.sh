#!/usr/bin/env bash
#
# third-party 技能管理脚本（随 ~/Skills 仓库分发）
# 详见同目录 README.md 与 manifest

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest"

SUBCMD="install"
REQUESTED_PLATFORMS="all"
FORCE=0
PURGE=0

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
  install   按 manifest 克隆缺失仓库并建立软链（默认，幂等可重复运行）
  update    对已克隆仓库执行 git pull
  remove    删除软链（--purge 同时删除本地克隆）
  list      manifest 与实际状态对照表
  help      显示本帮助

选项:
  --platform <列表>  平台过滤: opencode / claude / all（默认 all，按 manifest 每行声明执行）
  --force            覆盖指向别处的软链（永不覆盖真实目录）
  --purge            配合 remove 删除本地克隆

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

load_manifest() {
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
  [ "${#ENTRIES[@]}" -gt 0 ] || die "manifest 没有有效条目"
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

ensure_link() {
  local p="$1" dir link
  request_allows "$p" || { info "[$p] 已被 --platform 过滤跳过: $E_NAME"; return 0; }
  dir="$(platform_dir "$p")"
  mkdir -p "$dir"
  link="$dir/$E_NAME"
  if [ -L "$link" ]; then
    if link_points_to "$link" "$E_DIR"; then
      ok "[$p] 软链已存在: $link"
    elif [ "$FORCE" = "1" ]; then
      ln -sfn "$E_DIR" "$link" && ok "[$p] 已强制重建软链: $link -> $E_DIR"
    else
      warn "[$p] 软链已存在且指向别处，跳过: $link -> $(readlink "$link")（--force 可覆盖）"
    fi
  elif [ -e "$link" ]; then
    warn "[$p] 已存在同名真实目录，跳过: $link"
  else
    ln -s "$E_DIR" "$link" && ok "[$p] 已创建软链: $link -> $E_DIR"
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
      ensure_link "$p"
    done
  done
  info "install 完成: 新克隆 $n_clone，已有 $n_have，异常 $n_fail"
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

cmd_remove() {
  validate_requested_platforms
  load_manifest
  local line p dir link n_rm=0 n_keep=0
  for line in "${ENTRIES[@]}"; do
    parse_entry "$line"
    for p in $(platforms_of_line "$E_PLATS"); do
      request_allows "$p" || continue
      dir="$(platform_dir "$p")"
      link="$dir/$E_NAME"
      if [ -L "$link" ]; then
        if link_points_to "$link" "$E_DIR"; then
          rm "$link" && ok "[$p] 已删除软链: $link"
          n_rm=$((n_rm+1))
        else
          warn "[$p] 软链不指向本克隆目录，跳过: $link -> $(readlink "$link")"
          n_keep=$((n_keep+1))
        fi
      elif [ -e "$link" ]; then
        warn "[$p] 是真实目录，不删除: $link"
        n_keep=$((n_keep+1))
      fi
    done
    if [ "$PURGE" = "1" ]; then
      if [ -d "$E_DIR/.git" ]; then
        rm -rf "$E_DIR" && ok "已删除本地克隆: $E_DIR"
      elif [ -e "$E_DIR" ]; then
        warn "不是 git 克隆目录，purge 跳过: $E_DIR"
      fi
    fi
  done
  info "remove 完成: 删除软链 $n_rm，保留/跳过 $n_keep"
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
      install|update|remove|list)
        SUBCMD="$1"
        ;;
      help|-h|--help)
        usage
        ;;
      --platform)
        [ $# -ge 2 ] || die "--platform 需要参数"
        REQUESTED_PLATFORMS="$(trim "$2")"
        shift
        ;;
      --platform=*)
        REQUESTED_PLATFORMS="$(trim "${1#*=}")"
        ;;
      --force)
        FORCE=1
        ;;
      --purge)
        PURGE=1
        ;;
      *)
        die "未知参数: $1（help 查看用法）"
        ;;
    esac
    shift
  done

  case "$SUBCMD" in
    install) cmd_install ;;
    update)  cmd_update ;;
    remove)  cmd_remove ;;
    list)    cmd_list ;;
  esac
}

main "$@"
