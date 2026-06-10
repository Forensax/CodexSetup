# Codex Windows 安装包自动构建

这个仓库用于把 Microsoft Store 版本的 Codex MSIX 包重新封装为传统 Windows EXE 安装器，并通过 GitHub Actions 自动发布到 GitHub Release。

## 工作方式

- 每小时自动检查一次 Codex Retail x64 MSIX 是否有新版本。
- 如果 GitHub Release 中已经存在对应的 `v版本号`，说明没有新版本，本次 workflow 会正常停止。
- 如果发现新版本，会自动下载 MSIX、构建 EXE 安装包、在 GitHub Actions 的 Windows runner 中做安装/卸载验证，然后创建 GitHub Release。
- 也可以在 Actions 页面手动运行 workflow，并在自动解析失败时填写 `msix_url`。

## 安装包策略

- 安装器类型：传统 NSIS EXE。
- 安装范围：全机器安装，需要管理员权限。
- 默认安装目录：`%ProgramFiles%\Codex`。
- 注册内容：开始菜单快捷方式、卸载项、`codex:` 协议。
- 不注册 `.csv`、`.tsv`、`.xls`、`.xlsm`、`.xlsx` 文件关联。
- 压缩方式：`zlib`，在构建速度和安装包体积之间折中。
- 签名策略：当前安装器不签名，运行时可能出现 SmartScreen 或未知发布者提示。

## 常用操作

手动触发：

1. 打开 GitHub 仓库的 Actions 页面。
2. 选择 `构建 Codex Windows 安装器`。
3. 点击 `Run workflow`。
4. 如果自动解析 MSIX 失败，在 `msix_url` 中填写 OpenAI.Codex x64 Retail MSIX 直链。

本地静态测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\packaging.tests.ps1
```

本机不会运行真实安装/卸载测试；真实安装验证只在 GitHub Actions 的 Windows runner 中执行。

## 注意事项

- `store.rg-adguard.net` 是第三方服务，不是 Microsoft 官方稳定 API，自动解析可能偶发失败。
- 重新分发 Microsoft Store/OpenAI 应用包前，请自行确认许可、品牌和再分发合规性。
- 后续更新通过新的 GitHub Release 分发，不保留 Microsoft Store 自动更新能力。
