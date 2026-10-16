<p align="center">
  <img src="Resources/AppIcon.png" width="120" alt="WorkBuddy 会话管理">
</p>

<h1 align="center">WorkBuddy 会话管理</h1>

<p align="center">把 WorkBuddy 换账号后「消失」的旧对话找回来。</p>

---

## 这是什么问题

WorkBuddy 换账号之后,旧账号的对话其实**没被删掉**,只是在界面上被藏起来了。

原因很直白:WorkBuddy 判断「这条对话属于谁」,只看数据库里的一个字段。对话正文存在硬盘上另一个地方,文件里根本没有任何账号信息。

所以换账号 = 改一个字段的事。对话一直躺在原地,只是没人给你显示它。

这个工具就是把那批对话重新摆出来,并且允许你在账号之间挪动它们。

## 能做什么

- **找回旧对话** —— 列出本机所有账号,点进去就能看当时的聊天记录
- **读正文** —— 按聊天气泡显示,Markdown、代码块、表格都正常渲染
- **迁移** —— 把某条对话挪到另一个账号名下
- **导出** —— 存成 Markdown,脱离 WorkBuddy 自己看
- **回收站** —— 删除是软删除,随时还原

WorkBuddy 有两个版本,数据完全独立:

| 应用 | 数据目录 |
|---|---|
| WorkBuddy AI | `~/.workbuddy-ai/` |
| WorkBuddy | `~/.workbuddy/` |

左上角可以切换看哪一个。没装的会标出来。

## 下载

去 [Releases](https://github.com/NeoXue-ai/workbuddy-session-manager/releases) 下载最新的 `WorkBuddy-Session-Manager-macOS.zip`,解压后双击 `WorkBuddy 会话管理.app`。

需要 **macOS 14 或更新版本**。

> 第一次打开如果提示「无法验证开发者」,右键点 app 选「打开」就行。
> 这是因为 app 没有花钱做苹果开发者认证,它只读你自己机器上的数据,没有必要。

## 怎么用

1. **先完全退出 WorkBuddy。** 这一步别跳——它开着的时候,数据库状态在它自己内存里,你写进去的东西会被它盖掉。
2. 双击打开这个工具。
3. 左上角选你看的是哪个应用。
4. 左边选账号 → 中间选对话 → 右边看内容。
5. 要挪走或者删,用顶部的按钮。

## 它会动你的数据吗

只有「写」的部分有风险,所以这几道保险是硬性的:

- **每次动手前自动备份** 一份数据库,就放在你的家目录里。
- **备份先验完整性**,验不过就不碰你的原库。
- **改完立刻回读确认**,对不上就自动撤回去。
- **WorkBuddy 还在跑的话,直接拒绝写入**——这是有意的。

「迁移」只改一条记录的归属字段,对话正文一个字都不动,随时能改回去。
「删除」用的是 WorkBuddy 自己的回收站机制,随时能还原。

## 它不做什么

- **不跨版本迁移。** 两个版本是两个独立数据库,工具不做互相搬运。「迁移」只指同一个版本内换账号。
- **不碰云端会话。** 云端同步的对话归属由服务器决定,本地改了会被同步覆盖,所以工具直接拒绝。
- **不上传任何东西。** 没有网络请求,不收集数据,只读你本机的文件。

## 自己编译

```bash
git clone https://github.com/NeoXue-ai/workbuddy-session-manager.git
cd workbuddy-session-manager
./build-app.sh
open "build/WorkBuddy 会话管理.app"
```

只需要装了 Xcode 命令行工具。

## 命令行版

不想开界面的话,`tools/wb_migrate.py` 是同一套逻辑的命令行版本,还能批量、按标题筛选、先出迁移计划再执行。

```bash
python3 tools/wb_migrate.py inspect
python3 tools/wb_migrate.py plan <会话> --to <账号>
```

详见 [`tools/README.md`](tools/README.md)。

## 许可

MIT
