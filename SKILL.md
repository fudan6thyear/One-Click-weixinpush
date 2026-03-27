---
name: weixin-publish
description: "微信公众号一键发布：支持 AI 封面生成、自动上传素材、草稿箱发布；提供直连微信 API 的防卡住发布路径。"
metadata:
  {
    "openclaw":
      {
        "emoji": "🧩",
      },
  }
---

# weixin-publish

用于把 Markdown 快速发布到微信公众号草稿箱，适配 Windows/PowerShell；工作流会在执行阶段强制校验 Markdown 输入/输出为 UTF-8，并仅依赖内置样式化渲染器与直连微信 API。

## 你能做什么

- 生成 AI 封面并自动写回 frontmatter 的 `cover`
- 发布到公众号草稿箱
- 默认走直连微信 API 的稳定发布路径
- 使用内置样式化渲染器生成可读正文，而不是无格式纯文本
- 在执行发布或封面生成前，强制校验 Markdown 输入是合法 UTF-8；校验失败直接终止
- 提供直连微信 API 的稳定发布路径，无需 `wenyan` 或 `node`

## 前置条件

发布文章请确保以下环境变量可用：

```powershell
$env:WECHAT_APP_ID = "your_app_id"
$env:WECHAT_APP_SECRET = "your_app_secret"
```

默认发布会自动生成 AI 封面，因此通常需要：

```powershell
$env:YUNWU_API_KEY = "your_yunwu_api_key"
```

如果本次发布不想重新生成封面，可显式传入 `-NoAutoCover` 跳过。并且公众号后台已把运行机器公网 IP 加入白名单。

## UTF-8 强制门禁

- 不依赖人工检查编码。
- `publish-direct.ps1`、`publish.ps1`、`generate-cover.ps1` 会在真正执行前严格校验 Markdown 输入是否为合法 UTF-8。
- `generate-cover.ps1` 在回写 `cover` frontmatter 后，也会以 UTF-8 重新写出 Markdown，保证输出仍为 UTF-8。
- 如果输入文件不是 UTF-8，脚本会直接失败并给出明确报错，不会带着乱码继续发布。

## 正文格式策略

- 直连发布路径不是简单把 Markdown 原文塞进草稿箱。
- 默认会先调用 AI 生图流程，为文章生成新封面并写回 frontmatter 的 `cover`。
- 当前内置渲染器会先剥离 frontmatter，避免 `title:`、`cover:`、`digest:` 被误发到正文。
- 内置渲染器会输出适合微信公众号阅读的基础版式，重点支持：`#`/`##`/`###` 标题、段落、无序/有序列表、引用、代码块、行内代码、链接和图片。
- `publish-direct.ps1` 是唯一发布实现，不依赖 `wenyan`。

## 参数兼容性

- `Theme` / `Highlight` 参数仅为兼容旧命令保留，不再影响当前内置渲染器输出。
- `AutoCover` 参数仅为兼容旧命令保留；默认已经自动生图。
- 如需跳过本次生图，请使用 `-NoAutoCover`。
- `publish.ps1` 已降级为兼容入口，内部直接转调 `publish-direct.ps1`。

## 推荐工作流

1. 默认使用直连发布。发布前会自动通过 UTF-8 门禁，并自动生成新封面：

```powershell
.\scripts\publish-direct.ps1 .\example.md
```

2. 如果你想跳过本次封面生成：

```powershell
.\scripts\publish-direct.ps1 .\example.md -NoAutoCover
```

3. 如需兼容旧命令，可继续使用包装脚本：

```powershell
.\scripts\publish.ps1 .\example.md
```

`publish.ps1` 会直接转调 `publish-direct.ps1`；两条入口都会先做 UTF-8 校验，并保证正文有基础排版。

## 常用命令

### 1) 默认直连发布（推荐）

```powershell
.\scripts\publish-direct.ps1 .\example.md
```

### 2) 跳过本次自动生图

```powershell
.\scripts\publish-direct.ps1 .\example.md -NoAutoCover
```

### 3) 兼容旧命令（可选）

```powershell
.\scripts\publish.ps1 .\example.md
```

### 4) 单独生图

```powershell
.\scripts\generate-cover.ps1 -MarkdownFile .\example.md
```

## 默认 AI 配置

- BaseUrl: `https://yunwu.ai`
- 默认模型: `doubao-seedream-5-0-260128`
- 备选端点: `/v1/images/generations`

