# 雷神自动暂停

这是一个面向 Windows 版雷神加速器的 Codex 个人插件。它会在退出雷神或 Windows 关机/重启前，调用雷神客户端自身的暂停时长逻辑。

> 本项目不是雷神官方插件，会修改雷神客户端的 `app.asar` 和 `renderer.asar`。安装前会按 SHA-256 备份原文件，可随时卸载还原。

## 功能

- 右上角关闭并确认退出时，先暂停时长，再关闭客户端。
- Windows 正常关机或重启时尝试自动暂停。
- 支持状态检查、雷神升级后修复和卸载还原。
- 不读取、不保存雷神账号、密码或 GitHub 凭据。

## 文件放在哪里

只使用自动暂停功能时，文件包可以解压到任意固定目录，例如：

```text
C:\Tools\leigod-auto-pause
```

如果还希望 Codex 将其识别为个人插件，推荐放在：

```text
%USERPROFILE%\plugins\leigod-auto-pause
```

仅运行自动暂停脚本不要求安装到 Codex，也不要求一直保持 Codex 开启。

## 环境要求

- Windows 10 或 Windows 11
- 已安装并登录 Windows 版雷神加速器
- 以下任意一种运行环境：
  - Codex Desktop（脚本会自动查找 Codex 自带的 Node.js 和 pnpm）
  - 系统已安装 Node.js 和 pnpm

没有 pnpm 时可以运行：

```powershell
npm install --global pnpm
```

## 下载

### 方法一：下载 ZIP

1. 打开本仓库首页。
2. 点击 `Code` → `Download ZIP`。
3. 解压到一个不会随手删除的目录。

### 方法二：使用 Git

```powershell
git clone https://github.com/Memphis0409/leigod-auto-pause.git "$env:USERPROFILE\plugins\leigod-auto-pause"
cd "$env:USERPROFILE\plugins\leigod-auto-pause"
```

## 安装自动暂停

建议先完全退出雷神，然后打开 PowerShell，进入解压后的插件目录：

```powershell
cd "C:\Tools\leigod-auto-pause"
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\leigod-auto-pause.ps1 -Action Status
.\scripts\leigod-auto-pause.ps1 -Action Install
```

如果雷神安装在脚本无法自动识别的位置，可显式指定目录：

```powershell
.\scripts\leigod-auto-pause.ps1 -Action Install -InstallPath "D:\program\LeiGod_Acc"
```

出现“拒绝访问”时，请使用“以管理员身份运行”的 PowerShell 再执行安装。

## 检查是否安装成功

```powershell
.\scripts\leigod-auto-pause.ps1 -Action Status
```

成功状态应包含：

```json
{
  "mainPatched": true,
  "rendererPatched": true,
  "patched": true
}
```

如果安装时雷神正在运行，需要完全退出并重新打开一次，才能加载补丁。

## 测试方法

1. 打开雷神，确认可暂停时长正在消耗。
2. 点击右上角关闭。
3. 第一次提示选择“退出加速器”并点击“确定”。
4. 第二次“暂停时长提醒”中点击“退出”。
5. 再次打开雷神，确认时长显示为暂停。

暂停请求失败时，插件会尽量阻止客户端继续退出，避免误以为已经暂停。

## 雷神升级后修复

雷神升级可能覆盖补丁。升级后重新执行：

```powershell
.\scripts\leigod-auto-pause.ps1 -Action Repair
```

然后运行 `Status`，确认三个补丁状态均为 `true`。

## 卸载和还原

```powershell
.\scripts\leigod-auto-pause.ps1 -Action Uninstall
```

脚本会验证备份哈希，再还原雷神原始文件。卸载后重新启动雷神。

## 本地数据位置

插件运行状态、原始文件备份和日志保存在：

```text
%LOCALAPPDATA%\LeigodAutoPause\
├── backups\
├── state.json
└── auto-pause.log
```

这些文件不会提交到 GitHub。

## 作为 Codex 个人插件使用（可选）

仓库中的 Codex 插件结构为：

```text
.codex-plugin\plugin.json
skills\leigod-auto-pause\SKILL.md
scripts\
```

推荐将仓库克隆到 `%USERPROFILE%\plugins\leigod-auto-pause`，然后在 Codex 中提出：

```text
请把 C:\Users\<你的用户名>\plugins\leigod-auto-pause 安装到我的个人插件市场。
```

安装后可直接对 Codex 说：

```text
检查雷神自动暂停状态
修复雷神自动暂停
卸载雷神自动暂停
```

Codex 插件机制可参考 [OpenAI Developers](https://developers.openai.com/) 的最新说明。

## 限制

- 断电、强制结束进程或系统崩溃时无法保证暂停。
- 账号未登录、网络断开或当前消耗的是不可暂停时长时，雷神可能拒绝暂停。
- 雷神更新客户端结构后，补丁程序可能需要同步更新。
