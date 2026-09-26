#!/usr/bin/env python3
"""bookmark_tools.py — Chrome 书签整理工具集（bookmark-organizer 技能）

子命令:
  parse   解析 Chrome 书签 JSON → parsed.json + duplicates.txt
  map     全量映射到分类树（自动与上次对比，输出 added/removed）
  status  查看上次整理状态
  report  生成对照表 md（全量或增量）
  html    生成 Netscape 书签 HTML
  wiki    生成/更新知识库 wiki 页面（12 分类页 + 总览 + source 页）

所有路径均为显式参数，不依赖任何硬编码位置。
"""
import argparse, collections, glob, html, json, os, re, shutil, subprocess, sys, tempfile
from datetime import datetime

DEF_CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "categories.json")
DEF_PREFS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "preferences.json")

# ---------------- 公共 ----------------

def load_json(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)

def save_json(obj, p):
    with open(p, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)

def chrome_time(ts):
    try:
        return datetime.fromtimestamp(int(ts) / 1_000_000 - 11644473600).strftime("%Y-%m-%d")
    except Exception:
        return ""

def expand(p):
    return os.path.abspath(os.path.expanduser(p))

def find_bookmark_files(pattern):
    files = []
    for pat in pattern if isinstance(pattern, list) else [pattern]:
        files += [expand(g) for g in glob.glob(expand(pat))]
    return sorted(set(f for f in files if os.path.basename(f) == "Bookmarks" or f.endswith("Bookmarks")))

def rename_conservative(name, prefs):
    r = prefs.get("rename", {})
    n = name or ""
    for t in r.get("tail_drops", []):
        n = n.replace(t, "")
    for p in r.get("prefix_drops", []):
        if n.startswith(p):
            n = n[len(p):].strip()
    n = re.sub(r"\s+", " ", n).strip()
    mx = int(r.get("max_len", 80))
    if len(n) > mx:
        n = n[: mx - 3] + "…"
    return n

# ---------------- parse ----------------

def walk(node, path, out):
    if node.get("type") == "url":
        out.append({
            "name": node.get("name", ""),
            "url": node.get("url", ""),
            "folder": path,
            "date": chrome_time(node.get("date_added", "0")),
        })
    elif node.get("type") == "folder":
        p = path + [node.get("name", "")] if path else [node.get("name", "")]
        for ch in node.get("children", []):
            walk(ch, p, out)

def cmd_parse(args):
    src = expand(args.src)
    if not os.path.isfile(src):
        # 允许传 profile 名或 glob
        prefs = load_json(expand(args.prefs))
        cands = find_bookmark_files(prefs.get("chrome_bookmark_glob_darwin") if sys.platform == "darwin"
                                    else prefs.get("chrome_bookmark_glob_linux"))
        m = [c for c in cands if args.src in c] or cands
        if not m:
            sys.exit(f"ERROR: 找不到 Chrome 书签文件（参数: {args.src}）")
        src = m[0]
    work = expand(args.work)
    os.makedirs(work, exist_ok=True)
    data = load_json(src)
    bookmarks = []
    for root_name, node in data.get("roots", {}).items():
        if isinstance(node, dict):
            walk(node, [root_name], bookmarks)
    save_json(bookmarks, f"{work}/bookmarks-parsed.json")

    # 重复统计
    groups = collections.defaultdict(list)
    for b in bookmarks:
        groups[b["url"].rstrip("/")].append(b)
    dups = {u: bs for u, bs in groups.items() if len(bs) > 1}
    with open(f"{work}/bookmarks-duplicates.txt", "w", encoding="utf-8") as f:
        f.write("重复次数 | 名称 | URL | 所在文件夹\n")
        for u, bs in sorted(dups.items(), key=lambda x: -len(x[1])):
            f.write(f"\n[{len(bs)} 次] {bs[0]['name']}\n  {u}\n")
            for b in bs:
                f.write(f"   - {' > '.join(b['folder'])} | {b['name']} | {b['date']}\n")

    print(f"源文件: {src}")
    print(f"总书签数: {len(bookmarks)}")
    top = collections.Counter(b["folder"][0] for b in bookmarks)
    print("顶层分布:", dict(top.most_common()))
    print(f"重复 URL 组数: {len(dups)}（涉及 {sum(len(v) for v in dups.values())} 条）")
    print(f"解析结果: {work}/bookmarks-parsed.json")

# ---------------- map ----------------

def match_rule(rel, rules):
    for r in rules:
        rp = r["path"]
        L = len(rp)
        if L == 0:
            if len(rel) == 0:
                return r
            continue
        if len(rel) >= L and list(rel[:L]) == list(rp):
            return r
    return None

def match_url(url, exact, prefix):
    for r in exact:
        if url == r["url"]:
            return r
    for r in prefix:
        if url.startswith(r["url"]):
            return r
    return None

def match_identity(rel, top_order):
    """新结构身份映射：书签已是本工具的分类结构时，直接映射回自身。
    rel 形如 ["前端基础", "JS"] / ["前端基础", "JS", "更深子层"] / ["前端基础"]"""
    if rel and rel[0] in top_order:
        top = rel[0]
        sub = ""
        if len(rel) >= 2 and rel[1] not in top_order:
            sub = rel[1]
        return {"top": top, "sub": sub, "note": "已整理结构"}
    # 书签栏根直接散落的书签（无分类层）
    if rel and rel[0] in ("书签栏", "bookmark_bar"):
        return {"top": "常用入口", "sub": "", "note": "书签栏根散落"}
    return None

def cmd_map(args):
    work = expand(args.work)
    parsed = load_json(f"{work}/bookmarks-parsed.json")
    cfg = load_json(expand(args.config))
    prefs = load_json(expand(args.prefs))

    prev_path = f"{work}/bookmarks-mapped.json"
    prev = None
    if os.path.isfile(prev_path):
        shutil.copy(prev_path, f"{work}/bookmarks-mapped-prev.json")
        prev = load_json(prev_path)

    exact, prefix = cfg.get("special_url_exact", []), cfg.get("special_url_prefix", [])
    top_order = cfg.get("top_order", [])
    out = []
    unmatched = []
    for b in parsed:
        rel = b["folder"][2:]
        r = match_url(b["url"], exact, prefix)
        if r is None:
            r = match_rule(rel, cfg["rules"])
        if r is None:
            ident = match_identity(rel, top_order)
            if ident:
                r = dict(ident)
        if r is None:
            unmatched.append(b)
            continue
        name = r.get("name") or rename_conservative(b["name"], prefs)
        out.append({**b, "new_top": r["top"], "new_sub": r.get("sub", ""),
                    "new_name": name, "note": r.get("note", "")})
    if unmatched:
        print(f"!! 未匹配 {len(unmatched)} 条（未归入任何分类，请补充 categories.json 规则）:")
        for b in unmatched:
            print(f"   {' > '.join(b['folder'])} | {b['name'][:40]} | {b['url'][:60]}")
        if not args.force:
            sys.exit("ERROR: 存在未匹配书签。补充规则后重跑，或加 --force 忽略。")

    # 去重（同 URL 保留日期最新/路径最短）
    groups = collections.defaultdict(list)
    for i, b in enumerate(out):
        groups[b["url"].rstrip("/")].append(i)
    keep = set()
    for idxs in groups.values():
        if len(idxs) == 1:
            keep.add(idxs[0]); continue
        winner = sorted(idxs, key=lambda i: (out[i].get("date") or "0000-00-00",
                                             -len(" > ".join(out[i]["folder"]))), reverse=True)[0]
        keep.add(winner)
    final = [out[i] for i in sorted(keep)]

    save_json(out, f"{work}/bookmarks-mapped-full.json")   # 含重复
    save_json(final, prev_path)                             # 去重后，作为正式 mapped

    renames = [{"old": b["name"], "new": b["new_name"], "url": b["url"],
                "folder": " > ".join(b["folder"][2:])} for b in final if b["new_name"] != b["name"]]
    save_json(renames, f"{work}/rename-list.json")

    # 增量对比
    added = removed = []
    if prev:
        def keys(lst):
            return {b["url"].rstrip("/") for b in lst}
        old_k, new_k = keys(prev), {b["url"].rstrip("/") for b in final}
        added = [b for b in final if b["url"].rstrip("/") in (new_k - old_k)]
        removed = [b for b in prev if b["url"].rstrip("/") in (old_k - new_k)]

    tree = collections.defaultdict(lambda: collections.Counter())
    for b in final:
        tree[b["new_top"]][b["new_sub"] or "(根)"] += 1

    print(f"映射完成: {len(final)} 条（去重移除 {len(out) - len(final)} 条）")
    if prev:
        print(f"对比上次: 新增 {len(added)} / 消失 {len(removed)}")
        for b in added[:20]:
            print(f"  [新增] {b['new_name'][:40]} → {b['new_top']}/{b['new_sub'] or '根'}")
        for b in removed[:20]:
            print(f"  [消失] {b['name'][:40]} ({b['url'][:50]})")
    print("\n===== 分类统计 =====")
    for top in sorted(tree, key=lambda t: -sum(tree[t].values())):
        print(f"【{top}】{sum(tree[top].values())}")
        for sub, n in tree[top].most_common():
            print(f"    {sub}: {n}")

    meta_path = f"{work}/meta.json"
    meta = load_json(meta_path) if os.path.isfile(meta_path) else {}
    meta.update({
        "last_map": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "total": len(final),
        "added": len(added), "removed": len(removed),
        "unmatched": len(unmatched),
    })
    save_json(meta, meta_path)

# ---------------- status ----------------

def cmd_status(args):
    work = expand(args.work)
    meta = load_json(f"{work}/meta.json") if os.path.isfile(f"{work}/meta.json") else {}
    mapped = f"{work}/bookmarks-mapped.json"
    print("== bookmark-organizer 状态 ==")
    print(f"工作目录: {work}")
    if meta:
        print(f"上次映射: {meta.get('last_map')} | 总数 {meta.get('total')} | 新增 {meta.get('added')} | 消失 {meta.get('removed')} | 未匹配 {meta.get('unmatched')}")
    else:
        print("尚未运行过 map")
    for f, label in [("bookmarks-parsed.json", "解析快照"), ("bookmarks-mapped.json", "映射结果"),
                     ("bookmarks-mapped-prev.json", "上一版映射"), ("rename-list.json", "改名清单")]:
        p = f"{work}/{f}"
        if os.path.isfile(p):
            n = len(load_json(p)) if f.endswith(".json") else "-"
            mt = datetime.fromtimestamp(os.path.getmtime(p)).strftime("%Y-%m-%d %H:%M")
            print(f"  {label}: {f} ({n} 条, {mt})")
        else:
            print(f"  {label}: 无")
    if os.path.isfile(mapped):
        tree = collections.defaultdict(int)
        for b in load_json(mapped):
            tree[b["new_top"]] += 1
        print("分类分布:", dict(sorted(tree.items(), key=lambda x: -x[1])))

# ---------------- report ----------------

def cmd_report(args):
    work = expand(args.work)
    out = expand(args.out)
    cfg = load_json(expand(args.config))
    final = load_json(f"{work}/bookmarks-mapped.json")
    renames = load_json(f"{work}/rename-list.json") if os.path.isfile(f"{work}/rename-list.json") else []
    prev_p = f"{work}/bookmarks-mapped-prev.json"
    prev = load_json(prev_p) if os.path.isfile(prev_p) else None

    tree = collections.defaultdict(lambda: collections.Counter())
    oldmap = collections.defaultdict(collections.Counter)
    for b in final:
        tree[b["new_top"]][b["new_sub"] or "(根)"] += 1
        old = " > ".join(b["folder"][2:]) if len(b["folder"]) > 2 else "(散落/书签栏根)"
        oldmap[(b["new_top"], b["new_sub"] or "(根)")][old] += 1

    L = ["# 书签整理对照表\n", f"> 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M')} | 共 {len(final)} 条书签\n", "---\n"]
    if prev:
        ok, nk = {b["url"].rstrip("/") for b in prev}, {b["url"].rstrip("/") for b in final}
        added = [b for b in final if b["url"].rstrip("/") in nk - ok]
        removed = [b for b in prev if b["url"].rstrip("/") in ok - nk]
        L.append("## 〇、增量变化\n")
        L.append(f"- 新增：{len(added)} 条；消失：{len(removed)} 条\n")
        if added:
            L.append("| 新增书签 | 归入分类 |")
            L.append("|---|---|")
            for b in added:
                L.append(f"| {b['new_name'][:50]} | {b['new_top']}/{b['new_sub'] or '根'} |")
            L.append("")
        if removed:
            L.append("| 消失书签（浏览器里已删除） | 原分类 |")
            L.append("|---|---|")
            for b in removed:
                L.append(f"| {b['name'][:50]} | {b.get('new_top','')}/{b.get('new_sub') or '根'} |")
            L.append("")
    L.append("## 一、新分类树\n")
    order = cfg.get("top_order", [])
    for top in sorted(tree, key=lambda t: (order.index(t) if t in order else 99, -sum(tree[t].values()))):
        L.append(f"### 【{top}】{sum(tree[top].values())} 条\n")
        for sub, n in tree[top].most_common():
            L.append(f"- {sub}: {n}")
        L.append("")
    L.append("---\n## 二、改名清单（保守规则命中）\n")
    L.append(f"共 {len(renames)} 条。完整清单见 rename-list.json，样例（前 20）：\n")
    L.append("| 原标题 | 新标题 |")
    L.append("|---|---|")
    for r in renames[:20]:
        L.append(f"| {r['old'][:45]} | {r['new'][:45]} |")
    L.append("\n---\n## 三、重复 URL 清单\n")
    dup_p = f"{work}/bookmarks-duplicates.txt"
    if os.path.isfile(dup_p):
        L.append("```")
        L.append(open(dup_p, encoding="utf-8").read().strip())
        L.append("```")
    L.append("\n**确认后执行 html / wiki 子命令生成产物。**\n")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    open(out, "w", encoding="utf-8").write("\n".join(L))
    print(f"对照表: {out}")

# ---------------- html ----------------

def cmd_html(args):
    work = expand(args.work)
    out = expand(args.out)
    final = load_json(f"{work}/bookmarks-mapped.json")
    cfg = load_json(expand(args.config))
    order = cfg.get("top_order", [])
    tree = {t: {} for t in order}
    for b in final:
        tree.setdefault(b["new_top"], {}).setdefault(b["new_sub"] or "", []).append(b)

    def esc(s):
        return html.escape(s or "", quote=True)

    def epoch(d):
        try:
            return str(int(datetime.strptime(d, "%Y-%m-%d").timestamp()))
        except Exception:
            return ""

    now = epoch(datetime.now().strftime("%Y-%m-%d"))
    L = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
         "<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->",
         '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
         "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>",
         f'    <DT><H3 ADD_DATE="{now}" LAST_MODIFIED="{now}" PERSONAL_TOOLBAR_FOLDER="true">书签栏</H3>',
         "    <DL><p>"]
    count = 0
    for top in order + [t for t in tree if t not in order]:
        subs = tree.get(top) or {}
        if not sum(len(v) for v in subs.values()):
            continue
        L.append(f'        <DT><H3 ADD_DATE="{now}">{esc(top)}</H3>')
        L.append("        <DL><p>")
        for sub in sorted(subs.keys(), key=lambda s: (s != "", -len(subs[s]))):
            marks = subs[sub]
            pad = "            "
            if sub:
                L.append(f'            <DT><H3 ADD_DATE="{now}">{esc(sub)}</H3>')
                L.append("            <DL><p>")
                pad = "                "
            for b in marks:
                ad = epoch(b.get("date") or "")
                attr = f' ADD_DATE="{ad}"' if ad else ""
                L.append(f'{pad}<DT><A HREF="{esc(b["url"])}"{attr}>{esc(b["new_name"])}</A>')
                count += 1
            if sub:
                L.append("            </DL><p>")
        L.append("        </DL><p>")
    L += ["    </DL><p>", "</DL><p>"]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    open(out, "w", encoding="utf-8").write("\n".join(L))
    print(f"已生成: {out}\n共 {count} 条书签, 顶层分类 {sum(1 for t in tree if tree[t])} 个")

# ---------------- wiki ----------------

def cmd_wiki(args):
    work = expand(args.work)
    root = expand(args.wiki_root)
    cfg = load_json(expand(args.config))
    final = load_json(f"{work}/bookmarks-mapped.json")
    order, related, desc = cfg["top_order"], cfg.get("related", {}), cfg.get("desc", {})

    tree = {t: {} for t in order}
    for b in final:
        tree.setdefault(b["new_top"], {}).setdefault(b["new_sub"] or "", []).append(b)

    ent_dir = f"{root}/wiki/entities"
    top_dir = f"{root}/wiki/topics"
    src_dir = f"{root}/wiki/sources"
    for d in (ent_dir, top_dir, src_dir):
        os.makedirs(d, exist_ok=True)

    written = []
    for top in order:
        subs = tree.get(top) or {}
        total = sum(len(v) for v in subs.values())
        if not total:
            continue
        tags = "\n".join(f"  - {x}" for x in ["书签", top])
        L = [f"---\ntitle: 书签-{top}\ntype: entity\ntags:\n{tags}\naliases: []\nsources: []\n---\n",
             f"# 书签-{top}\n",
             f"> 共 {total} 条书签 | 整理自 Chrome 书签快照\n"]
        rel = "、".join(f"[[书签-{r}]]" for r in related.get(top, []))
        if rel:
            L.append(f"**相关分类**：{rel}\n")
        for sub in sorted(subs.keys(), key=lambda s: (s != "", -len(subs[s]))):
            marks = subs[sub]
            L.append(f"## {sub if sub else '其他'}（{len(marks)}）\n")
            L.append("| 名称 | 添加日期 |")
            L.append("|---|---|")
            for b in marks:
                name = b["new_name"].replace("|", "\\|")
                L.append(f"| [{name}]({b['url']}) | {b.get('date') or ''} |")
            L.append("")
        open(f"{ent_dir}/书签-{top}.md", "w").write("\n".join(L))
        written.append(("entity", f"书签-{top}", total))

    # 总览页
    L = ["---\ntitle: 书签总览\ntype: topic\ntags:\n  - 书签\n  - 总览\nsources: []\n---\n",
         "# 书签总览\n",
         f"> Chrome 书签整理 | 共 {len(final)} 条 | {sum(1 for t in order if tree.get(t))} 个分类 | 更新 {datetime.now().strftime('%Y-%m-%d')}\n",
         "## 分类导航\n", "| 分类 | 条数 | 说明 |", "|---|---|---|"]
    for top in order:
        total = sum(len(v) for v in (tree.get(top) or {}).values())
        if total:
            L.append(f"| [[书签-{top}]] | {total} | {desc.get(top, '')} |")
    L.append("\n## 说明\n")
    L.append("- 数据源：Chrome 书签快照，去重后入库")
    L.append("- 日后直接问 AI「XX 书签在哪」，会从这里检索\n")
    open(f"{top_dir}/书签总览.md", "w").write("\n".join(L))
    written.append(("topic", "书签总览", len(final)))

    # source 页（尽量走 create-source-page.sh 更新缓存）
    src_content = f"""---
title: {os.path.basename(work)}-chrome书签快照
type: source
tags:
  - 书签
  - chrome
sources:
  - raw/bookmarks/chrome-bookmarks-source.json
---

# Chrome 书签快照

## 基本信息

- **来源**：Chrome 本地书签文件
- **快照**：raw/bookmarks/chrome-bookmarks-source.json
- **条目**：{len(final)} 条（去重后）
- **分类**：{sum(1 for t in order if tree.get(t))} 个顶级分类

## 关键概念

- [[书签总览]] — 分类导航
"""
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False)
    tmp.write(src_content); tmp.close()
    src_name = "wiki/sources/chrome书签快照.md"
    raw_json = expand(args.raw) if args.raw else f"{root}/raw/bookmarks/chrome-bookmarks-source.json"
    if not os.path.isfile(raw_json):
        raw_json = f"{work}/bookmarks-parsed.json"
    ok = False
    llm_scripts = expand(args.llm_scripts)
    if os.path.isdir(llm_scripts):
        r = subprocess.run(["bash", f"{llm_scripts}/create-source-page.sh", raw_json, src_name, tmp.name],
                           capture_output=True, text=True)
        ok = "SUCCESS" in r.stdout or "UPDATED" in r.stdout
        print("create-source-page.sh:", (r.stdout + r.stderr).strip()[:150])
    if not ok:
        open(f"{root}/{src_name}", "w").write(src_content)
        print(f"（未找到 llm-wiki 脚本，source 页直接写入，缓存未更新）")
    os.unlink(tmp.name)
    written.append(("source", "chrome书签快照", len(final)))

    # index / log
    idx_p = f"{root}/index.md"
    if os.path.isfile(idx_p):
        idx = open(idx_p, encoding="utf-8").read()
        ent_rows = "\n".join(f"- [[书签-{t}]]（{n} 条书签）" for k, t, n in written if k == "entity")
        if "书签总览" not in idx:
            idx = idx.replace("（暂无）", "", 1)
            idx = idx.replace("> 人物、组织、概念、工具等\n",
                              "> 人物、组织、概念、工具等\n\n" + ent_rows + "\n", 1)
            idx = idx.replace("> 研究主题、知识领域\n",
                              "> 研究主题、知识领域\n\n- [[书签总览]]（分类导航）\n", 1)
            idx = idx.replace("> 每个消化过的素材都有一篇摘要\n",
                              "> 每个消化过的素材都有一篇摘要\n\n- [[chrome书签快照]]\n", 1)
            open(idx_p, "w", encoding="utf-8").write(idx)
    log_p = f"{root}/log.md"
    if os.path.isfile(log_p):
        log = open(log_p, encoding="utf-8").read()
        log += f"\n## {datetime.now().strftime('%Y-%m-%d')} ingest | Chrome 书签整理\n\n" \
               f"- **操作**：书签映射与 wiki 更新（{len(final)} 条）\n" \
               f"- **新增/更新页面**：{len(written)} 页\n"
        open(log_p, "w", encoding="utf-8").write(log)
    print(f"wiki 页面完成: {len(written)} 页（root={root}）")

# ---------------- main ----------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("parse", help="解析 Chrome 书签 JSON")
    p.add_argument("--src", required=True, help="Chrome Bookmarks 文件路径（或 profile 名/glob）")
    p.add_argument("--work", required=True, help="工作目录")
    p.add_argument("--prefs", default=DEF_PREFS)
    p.set_defaults(fn=cmd_parse)

    p = sub.add_parser("map", help="全量映射 + 增量对比")
    p.add_argument("--work", required=True)
    p.add_argument("--config", default=DEF_CONFIG)
    p.add_argument("--prefs", default=DEF_PREFS)
    p.add_argument("--force", action="store_true", help="存在未匹配书签时仍继续")
    p.set_defaults(fn=cmd_map)

    p = sub.add_parser("status", help="查看状态")
    p.add_argument("--work", required=True)
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("report", help="生成对照表 md")
    p.add_argument("--work", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--config", default=DEF_CONFIG)
    p.set_defaults(fn=cmd_report)

    p = sub.add_parser("html", help="生成 Netscape 书签 HTML")
    p.add_argument("--work", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--config", default=DEF_CONFIG)
    p.set_defaults(fn=cmd_html)

    p = sub.add_parser("wiki", help="生成知识库 wiki 页面")
    p.add_argument("--work", required=True)
    p.add_argument("--wiki-root", required=True)
    p.add_argument("--raw", default="", help="知识库内书签快照路径（缺省 raw/bookmarks/chrome-bookmarks-source.json）")
    p.add_argument("--config", default=DEF_CONFIG)
    p.add_argument("--llm-scripts", default="~/.config/opencode/skills/llm-wiki/scripts")
    p.set_defaults(fn=cmd_wiki)

    args = ap.parse_args()
    args.fn(args)

if __name__ == "__main__":
    main()
