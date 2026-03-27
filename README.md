# weixin-publish

微信公众号一键发布 Skill（Windows/PowerShell 版）。

核心能力：
- Markdown 自动排版并发布到公众号草稿箱
- AI 自动生成封面图并回写 `cover`
- 当 `wenyan publish` 卡住时，使用直连微信 API 的发布路径

## 快速开始

1) 准备环境变量（建议放在用户环境变量）：

```powershell
$env:WECHAT_APP_ID = "your_app_id"
$env:WECHAT_APP_SECRET = "your_app_secret"
$env:YUNWU_API_KEY = "your_yunwu_key"
```

2) 常规一键发布：

```powershell
.\scripts\publish.ps1 .\example.md -AutoCover
```

3) 若常规发布卡住，使用直连发布：

```powershell
.\scripts\publish-direct.ps1 .\example.md -AutoCover
```

## AI 生图默认配置

- `BaseUrl`: `https://yunwu.ai`
- `Model`: `doubao-seedream-5-0-260128`
- `FallbackModel`: `gemini-3-pro-image-preview`
- `OpenAIImagePath`: `/v1/images/generations`

## 目录结构

```text
weixin-publish/
├── SKILL.md
├── README.md
├── example.md
├── .gitignore
├── assets/
│   └── default-cover.jpg
├── references/
│   ├── themes.md
│   └── troubleshooting.md
└── scripts/
    ├── setup.ps1
    ├── generate-cover.ps1
    ├── publish.ps1
    └── publish-direct.ps1
```

