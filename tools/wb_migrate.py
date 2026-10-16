#!/usr/bin/env python3
"""WorkBuddy 会话账号迁移工具。

WorkBuddy 把每个会话的"归属账号"存在本地 SQLite 的一列里，正文另存在按工作目录
分组的 jsonl 中且不含账号信息。因此账号隔离仅是这一列造成的列表过滤，把该列改成
另一个账号的 uid 即可让会话出现在那个账号下，正文与工作目录不受影响。

本工具只做两件事：
  移动  改变会话的归属账号
  导出  把会话正文导出为 markdown，不依赖 app 即可阅读

标准库实现，无第三方依赖。
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

APP_DATA_DIRS = {
    "overseas": Path.home() / ".workbuddy-ai",
    "domestic": Path.home() / ".workbuddy",
}
PROCESS_PATTERNS = ["WorkBuddy AI.app", "WorkBuddy.app"]
REQUIRED_COLUMNS = {"sessions": {"id", "user_id", "cwd", "title", "transport"}}


class MigrationError(Exception):
    pass


def resolve_data_dir(flavor: str) -> Path:
    path = APP_DATA_DIRS[flavor]
    if not (path / "workbuddy.db").exists():
        raise MigrationError(
            f"未找到 {path}/workbuddy.db，先用 --flavor 切换 domestic/overseas 后重试"
        )
    return path


def connect(path: Path, read_only: bool = True) -> sqlite3.Connection:
    if read_only:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    else:
        conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def verify_schema(conn: sqlite3.Connection) -> None:
    missing_tables = [
        t for t in REQUIRED_COLUMNS if not conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (t,)
        ).fetchone()
    ]
    if missing_tables:
        raise MigrationError(f"缺少表 {missing_tables}，app 版本可能已变更数据结构")

    cols = {r["name"] for r in conn.execute("PRAGMA table_info(sessions)")}
    missing = REQUIRED_COLUMNS["sessions"] - cols
    if missing:
        raise MigrationError(f"sessions 表缺少字段 {sorted(missing)}，app 可能已升级")


def running_processes() -> list[str]:
    found = []
    for pattern in PROCESS_PATTERNS:
        result = subprocess.run(
            ["pgrep", "-f", pattern], capture_output=True, text=True
        )
        if result.returncode == 0:
            found.extend(line for line in result.stdout.split() if line.strip())
    return found


def active_account(data_dir: Path) -> dict | None:
    path = data_dir / "storage" / "skeleton" / "account-snapshot.json"
    if not path.exists():
        return None
    try:
        snapshot = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    primary = snapshot.get("primary")
    return primary if isinstance(primary, dict) and primary.get("uid") else None


def humanize(uid: str) -> str:
    return uid[:8]


def project_dir_for(cwd: str, data_dir: Path) -> Path:
    return data_dir / "projects" / cwd.lstrip("/").replace("/", "-")


def resolve_session(conn: sqlite3.Connection, ref: str) -> sqlite3.Row:
    rows = conn.execute(
        "SELECT * FROM sessions WHERE id LIKE ?", (ref.strip() + "%",)
    ).fetchall()
    if not rows:
        raise MigrationError(f"未找到会话 {ref}")
    if len(rows) > 1:
        listing = "\n".join(f"  {r['id']}  {r['title']}" for r in rows)
        raise MigrationError(f"{ref} 匹配到多个会话，请写更长的前缀：\n{listing}")
    return rows[0]


def resolve_uid(conn: sqlite3.Connection, ref: str) -> str:
    rows = conn.execute(
        "SELECT DISTINCT user_id FROM sessions WHERE user_id LIKE ?",
        (ref.strip() + "%",),
    ).fetchall()
    if not rows:
        raise MigrationError(f"未找到账号 {ref}")
    if len(rows) > 1:
        listing = "\n".join(f"  {r['user_id']}" for r in rows)
        raise MigrationError(f"{ref} 匹配到多个账号：\n{listing}")
    return rows[0]["user_id"]


def cmd_inspect(args) -> int:
    data_dir = resolve_data_dir(args.flavor)
    conn = connect(data_dir / "workbuddy.db")
    verify_schema(conn)

    current = active_account(data_dir)
    current_uid = current["uid"] if current else None

    print(f"数据目录  {data_dir}")
    if current:
        label = current.get("nickname") or "未命名账号"
        print(f"当前登录  {label}  ({humanize(current_uid)})")
    procs = running_processes()
    print(f"app 状态  {'运行中 pid=' + ','.join(procs) if procs else '未运行'}")
    print()

    print("账号")
    for row in conn.execute(
        """
        SELECT user_id,
               COUNT(*)                              AS total,
               SUM(deleted_at IS NULL)               AS alive,
               SUM(deleted_at IS NULL AND transport='cloud') AS cloud,
               MAX(updated_at)                       AS last
        FROM sessions GROUP BY user_id ORDER BY total DESC
        """
    ):
        mark = " ← 当前" if row["user_id"] == current_uid else ""
        span = (
            datetime.fromtimestamp(row["last"] / 1000).strftime("%Y-%m-%d %H:%M")
            if row["last"]
            else "-"
        )
        print(
            f"  {humanize(row['user_id'])}  {row['total']:>3} 个会话"
            f"（正常 {row['alive']}，云端 {row['cloud']}）  最后 {span}{mark}"
        )

    print()
    print("会话")
    for row in conn.execute(
        """
        SELECT id, user_id, title, transport, updated_at, deleted_at
        FROM sessions ORDER BY updated_at DESC
        """
    ):
        state = "已删" if row["deleted_at"] else "正常"
        cloud = "云" if row["transport"] == "cloud" else "本"
        when = datetime.fromtimestamp(row["updated_at"] / 1000).strftime("%m-%d %H:%M")
        title = row["title"] or "(无标题)"
        print(f"  {row['id'][:8]}  {humanize(row['user_id'])}  {state}/{cloud}  {when}  {title}")
    conn.close()
    return 0


def build_move_targets(conn, session_ref: str, uid_ref: str, include_cloud: bool):
    session = resolve_session(conn, session_ref)
    target = resolve_uid(conn, uid_ref)
    if session["user_id"] == target:
        raise MigrationError(f"会话已归属 {humanize(target)}，无需移动")

    if session["transport"] == "cloud" and not include_cloud:
        raise MigrationError(
            f"会话 {session['id'][:8]} 是云端同步会话（transport=cloud），\n"
            "  云端可能把归属改回去。确认要改请加 --include-cloud。"
        )
    return session, target


def cmd_plan(args) -> int:
    data_dir = resolve_data_dir(args.flavor)
    conn = connect(data_dir / "workbuddy.db")
    verify_schema(conn)
    session, target = build_move_targets(
        conn, args.session, args.to, args.include_cloud
    )

    print("将执行 1 条 SQL（尚未写入）")
    print(f"  {session['id']}")
    print(f"  归属  {humanize(session['user_id'])} → {humanize(target)}")
    print(f"  标题  {session['title'] or '(无标题)'}")
    print(f"  位置  {session['cwd']}")
    print()
    print("SQL:")
    print(f"  UPDATE sessions SET user_id='{target}' WHERE id='{session['id']}';")
    print()
    print("正文文件不会被触碰。执行请用：apply 子命令")
    conn.close()
    return 0


def cmd_apply(args) -> int:
    data_dir = resolve_data_dir(args.flavor)
    db = data_dir / "workbuddy.db"

    conn = connect(db, read_only=False)
    verify_schema(conn)
    session, target = build_move_targets(
        conn, args.session, args.to, args.include_cloud
    )
    conn.close()

    procs = running_processes()
    if procs and not args.force:
        raise MigrationError(
            "检测到 app 仍在运行（pid "
            + ", ".join(procs)
            + "）。运行中写库会被内存状态覆盖。\n"
            "  请先 Cmd+Q 完全退出后重试，确认无误可加 --force。"
        )

    backup = data_dir.parent / f"workbuddy.db.bak-{datetime.now():%Y%m%d-%H%M%S}"
    snapshot = sqlite3.connect(backup)
    conn = connect(db, read_only=False)
    conn.backup(snapshot)
    snapshot.close()
    conn.close()

    check = sqlite3.connect(backup).execute("PRAGMA integrity_check").fetchone()[0]
    if check != "ok":
        backup.unlink(missing_ok=True)
        raise MigrationError(f"备份完整性校验失败（{check}），已中止")
    print(f"备份  {backup}")

    conn = connect(db, read_only=False)
    try:
        conn.execute(
            "UPDATE sessions SET user_id=? WHERE id=?", (target, session["id"])
        )
        conn.commit()
    finally:
        conn.close()

    verify = connect(db)
    actual = verify.execute(
        "SELECT user_id FROM sessions WHERE id=?", (session["id"],)
    ).fetchone()
    if actual is None or actual["user_id"] != target:
        restore = backup
        shutil.copyfile(restore, db)
        raise MigrationError("写入后校验失败，已自动回滚")
    verify.close()

    print(f"完成  {session['id'][:8]} 现归属 {humanize(target)}")
    print()
    print("回滚：")
    print(f"  cp {backup} {db}")
    print(f"  rm -f {db}-wal {db}-shm")
    return 0


TAG_BLOCK = re.compile(
    r"<(system-reminder|memory_and_skills_reminder|conversation_history_summary"
    r"|current_time|craft_mode|user_info|user_references|project_layout|summary"
    r"|status)\b[^>]*>.*?</\1>",
    re.S | re.I,
)
USER_QUERY = re.compile(r"<user_query>(.*?)</user_query>", re.S | re.I)
TOOL_NOISE = ("Called the ", "Result of calling ")


def extract_text(entry: dict) -> str:
    chunks = []
    for part in entry.get("content") or []:
        if part.get("type") in ("input_text", "output_text"):
            chunks.append(part.get("text", ""))
    return "\n".join(chunks).strip()


def user_prompt(text: str) -> str:
    """真实提问包在 <user_query> 里，其余是 app 注入的上下文块。"""
    found = [m.strip() for m in USER_QUERY.findall(text)]
    return "\n\n".join(p for p in found if p)


def assistant_text(text: str) -> str:
    cleaned = TAG_BLOCK.sub("", text)
    return "\n".join(
        line
        for line in cleaned.splitlines()
        if not line.lstrip().startswith(TOOL_NOISE)
    ).strip()


def cmd_export(args) -> int:
    data_dir = resolve_data_dir(args.flavor)
    conn = connect(data_dir / "workbuddy.db")
    verify_schema(conn)

    if args.session in (None, "", "all"):
        sessions = conn.execute(
            "SELECT * FROM sessions WHERE deleted_at IS NULL ORDER BY updated_at DESC"
        ).fetchall()
    else:
        sessions = [resolve_session(conn, args.session)]
    conn.close()

    if args.output.suffix == ".md":
        if len(sessions) != 1:
            raise MigrationError("指定单个输出文件时只能导出一个会话")
        path = export_one(sessions[0], data_dir, args)
        print(f"已导出  {path}")
        return 0

    written = []
    for session in sessions:
        path = args.output / f"{session['id'][:8]}-{slug(session['title'])}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(render(session, data_dir), encoding="utf-8")
        written.append(path)
    print(f"已导出 {len(written)} 个会话到 {args.output}")
    return 0


def slug(title: str | None) -> str:
    raw = (title or "untitled").strip().replace("/", "-").replace(" ", "-")
    return raw[:40] or "untitled"


def export_one(session, data_dir: Path, args) -> Path:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(session, data_dir), encoding="utf-8")
    return args.output


def render(session, data_dir: Path) -> str:
    lines = [
        f"# {session['title'] or '未命名会话'}",
        "",
        f"- 会话 ID: `{session['id']}`",
        f"- 归属账号: `{session['user_id']}`",
        f"- 工作目录: `{session['cwd']}`",
        f"- 创建: {datetime.fromtimestamp(session['created_at']/1000):%Y-%m-%d %H:%M}",
        f"- 更新: {datetime.fromtimestamp(session['updated_at']/1000):%Y-%m-%d %H:%M}",
        f"- 传输: {session['transport']}",
        "",
        "---",
        "",
    ]

    transcript = project_dir_for(session["cwd"], data_dir) / f"{session['id']}.jsonl"
    if not transcript.exists():
        lines.append(f"> 未找到正文文件：{transcript}")
        return "\n".join(lines)

    tool_names: dict[str, int] = {}
    for raw in transcript.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not raw.strip():
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        kind = entry.get("type")
        if kind == "message":
            raw = extract_text(entry)
            if not raw:
                continue
            if entry.get("role") == "user":
                text = user_prompt(raw)
            else:
                text = assistant_text(raw)
            if not text:
                continue
            speaker = "用户" if entry.get("role") == "user" else "助手"
            lines.append(f"### {speaker}")
            lines.append("")
            lines.append(text)
            lines.append("")
        elif kind == "function_call":
            name = entry.get("name", "tool")
            tool_names[name] = tool_names.get(name, 0) + 1

    if tool_names:
        summary = "、".join(f"{n}×{c}" for n, c in sorted(
            tool_names.items(), key=lambda kv: -kv[1]))
        lines.append("---")
        lines.append("")
        lines.append(f"工具调用：{summary}")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="wb-migrate",
        description="WorkBuddy 会话账号迁移与导出工具",
    )
    parser.add_argument(
        "--flavor",
        choices=["overseas", "domestic"],
        default="overseas",
        help="overseas=WorkBuddy AI 国际版 ~/.workbuddy-ai（默认），domestic=国内版 ~/.workbuddy",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("inspect", help="列出账号与全部会话（只读）")

    p_plan = sub.add_parser("plan", help="预览迁移，不写入")
    p_plan.add_argument("session", help="会话 id 或前缀")
    p_plan.add_argument("--to", required=True, help="目标账号 uid 或前缀")
    p_plan.add_argument("--include-cloud", action="store_true", help="允许改动云端同步会话")

    p_apply = sub.add_parser("apply", help="执行迁移（会先备份）")
    p_apply.add_argument("session", help="会话 id 或前缀")
    p_apply.add_argument("--to", required=True, help="目标账号 uid 或前缀")
    p_apply.add_argument("--include-cloud", action="store_true", help="允许改动云端同步会话")
    p_apply.add_argument("--force", action="store_true", help="app 运行时也强制写入")

    p_export = sub.add_parser("export", help="导出为 markdown")
    p_export.add_argument("session", nargs="?", default="all", help="会话 id、前缀，或 all")
    p_export.add_argument("-o", "--output", required=True, type=Path, help="输出 .md 文件或目录")

    args = parser.parse_args()
    handlers = {
        "inspect": cmd_inspect,
        "plan": cmd_plan,
        "apply": cmd_apply,
        "export": cmd_export,
    }
    try:
        return handlers[args.command](args)
    except MigrationError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
