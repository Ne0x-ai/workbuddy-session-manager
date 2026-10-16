# wb-migrate

WorkBuddy 会话账号迁移与导出工具。换账号后看不到旧会话的对话，一行命令就能搬过去。

```
python3 wb_migrate.py inspect
python3 wb_migrate.py plan <会话> --to <账号>
python3 wb_migrate.py apply <会话> --to <账号>
python3 wb_migrate.py export <会话> -o talk.md
```

Python 3.9+ 标准库实现，无第三方依赖，无需安装。

## 为什么需要它

WorkBuddy 里每个会话的数据分散在两处：

| 位置 | 内容 | 是否记录账号 |
|---|---|---|
| `~/.workbuddy-ai/workbuddy.db` → `sessions` 表 | 标题、归属账号、状态、时间 | **是，唯一一处** |
| `~/.workbuddy-ai/projects/<工作目录>/<id>.jsonl` | 对话正文、工具调用 | **否** |

会话的账号归属只是 `sessions.user_id` 这一列，界面据此过滤列表。正文按工作目录分组且完全不含账号信息——所以账号之间看到的历史差异，是**本地的列表过滤**，不是云端隔离，也不是数据丢失。

因此"迁移"就是把这一列改成另一个账号的 uid：

```sql
UPDATE sessions SET user_id='<目标uid>' WHERE id='<会话id>';
```

文件层一个字节都不用动，正文、工作目录、上下文续接全部原样保留。

## 命令

### inspect — 查看（只读）

```bash
python3 wb_migrate.py inspect
```

列出数据目录、当前登录账号（含昵称）、app 运行状态、所有账号及会话数、全部会话清单。会话 id 和账号 uid 都可用前 8 位代替。

```
数据目录  /Users/you/.workbuddy-ai
当前登录  someone@example.com  (a1b2c3d4)
app 状态  未运行

账号
  a1b2c3d4   21 个会话（正常 20，云端 0）  最后 2026-01-01 08:10
  e5f6a7b8   12 个会话（正常 12，云端 0）  最后 2026-01-02 09:15
  9c0d1e2f    5 个会话（正常 5，云端 0）  最后 2026-01-03 13:34 ← 当前
  3a4b5c6d    4 个会话（正常 4，云端 0）  最后 2025-12-30 14:22
```

### plan — 预览（不写入）

```bash
python3 wb_migrate.py plan <会话> --to <账号>
```

打印将要执行的 SQL 与会话信息，不动任何数据。

### apply — 执行

```bash
python3 wb_migrate.py apply <会话> --to <账号>
```

执行前强制四道检查，任一不过即中止：

1. **app 已退出** — 通过 `pgrep` 检测。运行中写库会被内存状态覆盖
2. **schema 匹配** — 校验 `sessions` 表存在且含必要字段，app 改版后不会静默写坏
3. **事务快照备份** — 用 SQLite `.backup` 生成一致性副本，并跑 `integrity_check`
4. **写后校验** — 重读确认归属已变更，不符则自动回滚

完成后打印备份路径和回滚命令。

### export — 导出 markdown

```bash
python3 wb_migrate.py export <会话> -o talk.md    # 单个
python3 wb_migrate.py export all -o ./archive     # 全部
```

输出可读对话稿，自动剥离 app 注入的上下文块（`<system-reminder>`、`<user_query>`、
`<memory_and_skills_reminder>` 等），保留真实提问与回复，末尾附工具调用统计。
app 卸载或账号消失后，记录依然可读。

## 选项

| 选项 | 适用命令 | 说明 |
|---|---|---|
| `--flavor overseas\|domestic` | 全部 | 国际版 `~/.workbuddy-ai`（默认）/ 国内版 `~/.workbuddy` |
| `--include-cloud` | plan, apply | 允许改动 `transport=cloud` 的会话 |
| `--force` | apply | app 运行时也写入（不建议） |

## 云端会话

`transport=cloud` 的会话归属由云端维护，改本地可能被同步覆盖。
这类会话默认拒绝操作，需要显式加 `--include-cloud` 才会放行。

## 已知限制

- 依赖 WorkBuddy 内部 schema，app 大版本升级后可能失效（`inspect` 会先校验并明确报错）
- 只支持**移动**。让同一会话在两个账号下同时可见需要复制记录，涉及新会话 id 和新工作目录，未实现
- 不修改 `user-<uid>-personal/` 下的人格文件（SOUL.md / MEMORY.md 等），切号仍会换人格
- 进程检测是全局 `pgrep`，同时开着多个 WorkBuddy 实例时会误判为运行中

## 风险声明

本工具直接读写应用私有数据库，属于非官方手段。使用前请先备份
（`cp ~/.workbuddy-ai/workbuddy.db* <备份目录>/`），并注意连 `-wal`、`-shm` 一起复制。
请自行评估风险后使用。

## License

MIT
