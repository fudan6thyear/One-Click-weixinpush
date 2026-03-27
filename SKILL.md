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

用于把 Markdown 快速发布到微信公众号草稿箱，适配 Windows/PowerShell。

## 你能做什么

- 生成 AI 封面并自动写回 frontmatter 的 `cover`
- 发布到公众号草稿箱
- 常规发布卡住时，自动切换到直连微信 API 的备用路径

## 前置条件

请确保以下环境变量可用：

```powershell
$env:WECHAT_APP_ID = "your_app_id"
$env:WECHAT_APP_SECRET = "your_app_secret"
$env:YUNWU_API_KEY = "your_yunwu_api_key"
```

并且公众号后台已把运行机器公网 IP 加入白名单。

## 常用命令

### 1) 常规发布（推荐先试）

```powershell
.\scripts\publish.ps1 .\example.md -AutoCover
```

### 2) 备用直连发布（当常规发布卡住时）

```powershell
.\scripts\publish-direct.ps1 .\example.md -AutoCover
```

### 3) 单独生图

```powershell
.\scripts\generate-cover.ps1 -MarkdownFile .\example.md
```

## 默认 AI 配置

- BaseUrl: `https://yunwu.ai`
- 主模型: `doubao-seedream-5-0-260128`
- 备选模型: `gemini-3-pro-image-preview`
- 备选端点: `/v1/images/generations`

