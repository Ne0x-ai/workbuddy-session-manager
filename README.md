<p align="center">
  <img src="Resources/AppIcon.png" width="120" alt="WorkBuddy 会话管理">
</p>

<h1 align="center">WorkBuddy 会话管理</h1>

<p align="center">查看、导出、清理、迁移你的 WorkBuddy 本地对话。</p>

---

## 你的对话存在哪

WorkBuddy 把所有对话放在你自己的 Mac 上,两个地方:

```
~/.workbuddy-ai/
├── workbuddy.db                          索引:标题、归属账号、时间、状态
└── projects/<工作目录>/<会话id>.jsonl      正文:你和助手实际说的话
```

数据库里 `sessions.user_id` 这一列决定一条对话算哪个账号的,WorkBuddy 拿它过滤列表。

于是就有了这个问题:换个号,历史就散到另一个账号下面去了;删掉的进了回收站;攒了两年几百条对话,想找其中一段,只能一个账号一个账号点进去翻,找到之后还得一段段手动复制出来。

WorkBuddy 本身没提供管理这些对话的地方。这个工具补上。

## 能做什么

| | |
|---|---|
| **查看** | 所有账号的对话摆在一起,Markdown、代码块、表格正常渲染 |
| **导出** | 整段存成 Markdown,自己读、存档,或当上下文喂给别的 agent |
| **删除** | 清理不想要的,软删除,误删随时还原 |
| **迁移** | 挪到另一个账号名下 |

两个官方发行版的数据完全独立,左上角可以切换看哪一个:

| 应用 | 数据目录 |
|---|---|
| WorkBuddy AI | `~/.workbuddy-ai/` |
| WorkBuddy | `~/.workbuddy/` |

## 关于导出

导出出来的是干净的 Markdown,可以直接扔给别的 agent。

WorkBuddy 会在每条对话里塞一堆东西:系统提示、记忆摘要、当前时间、项目结构说明。这些是给它自己看的,不是你说的内容。直接复制粘贴喂给别的 agent,等于把一堆噪声当上下文塞进去。

这个工具会把这些注入块整段剥掉,只留你和助手的真实对话,保留 `### 用户` / `### 助手` 的轮次结构,末尾附一份工具调用统计。

## 下载

去 [Releases](https://github.com/NeoXue-ai/workbuddy-session-manager/releases) 下载 `WorkBuddy-Session-Manager-macOS.zip`,解压后把 `WorkBuddy 会话管理.app` 拖进「应用程序」。

需要 **macOS 14 或更新版本**。

> 第一次打开如果提示「无法验证开发者」,右键点 app 选「打开」就行。
> 它没有花钱做苹果开发者认证——只读你自己机器上的数据,没必要。

## 怎么用

1. **先完全退出 WorkBuddy。** 这一步别跳——它开着的时候数据库状态在它自己内存里,你写进去的东西会被它盖掉。
2. 打开这个工具。
3. 左上角选应用,左边选账号,中间选对话,右边看内容。
4. 顶部是导出、迁移、删除。

## 它会动你的数据吗

只有「写」的部分有风险,所以这几道保险是硬性的:

- **每次动手前自动备份** 一份数据库,就放在你的家目录里。
- **备份先验完整性**,验不过就不碰你的原库。
- **改完立刻回读确认**,对不上就自动撤回去。
- **WorkBuddy 还在跑的话,直接拒绝写入**——这是有意的。

删除用的是 WorkBuddy 自己的回收站机制(`deleted_at`),正文文件一个字节都不动,随时能还原。
迁移只改一条记录的归属字段,随时能改回去。

## 它不做什么

- **不跨版本搬运。** 两个版本是两个独立数据库,工具不做互相搬运。
- **不碰云端会话。** `transport=cloud` 的对话归属由服务器决定,本地改了会被同步覆盖,所以直接拒绝。
- **没有网络请求。** 不上传、不收集、不统计,只读本机文件。

## 自己编译

```bash
git clone https://github.com/NeoXue-ai/workbuddy-session-manager.git
cd workbuddy-session-manager
./build-app.sh
open "build/WorkBuddy 会话管理.app"
```

只需要装了 Xcode 命令行工具。

## 命令行版

`tools/wb_migrate.py` 是同一套逻辑的命令行版本,适合批量操作和先出计划再执行。

```bash
python3 tools/wb_migrate.py inspect
python3 tools/wb_migrate.py plan <会话> --to <账号>
```

详见 [`tools/README.md`](tools/README.md)。

## 许可

MIT
