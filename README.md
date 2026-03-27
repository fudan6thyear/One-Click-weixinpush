# weixin-publish

微信公众号一键发布 Skill（Windows/PowerShell 版）。

核心能力：
- Markdown 自动排版并发布到公众号草稿箱
- AI 自动生成封面图并回写 `cover`
- 使用内置样式化渲染器 + 直连微信 API 稳定发布
- 强制校验 Markdown 输入/输出为 UTF-8

## 快速开始

1) 准备环境变量（建议放在用户环境变量）：

```powershell
$env:WECHAT_APP_ID = "your_app_id"
$env:WECHAT_APP_SECRET = "your_app_secret"
$env:YUNWU_API_KEY = "your_yunwu_key"
```

2) 推荐一键发布（默认自动生图）：

```powershell
.\scripts\publish.ps1 .\example.md
```

3) 直接使用唯一发布实现：

```powershell
.\scripts\publish-direct.ps1 .\example.md
```

说明：
- `publish-direct.ps1` 是唯一发布实现。
- `publish.ps1` 仅为兼容旧命令而保留，内部直接转调 `publish-direct.ps1`。
- `Theme` / `Highlight` 参数仅为兼容旧命令保留，不再影响当前内置渲染器输出。
- 默认发布会自动生成 AI 封面并写回 `cover`。
- 如果本次不想重新生成封面，请使用 `-NoAutoCover`。

## 正文渲染

- 使用内置样式化渲染器，不依赖 `wenyan` 或 `node`
- 发布前会剥离 frontmatter，避免 `title:`、`cover:`、`digest:` 进入正文
- 支持标题、段落、列表、引用、代码块、行内代码、链接和图片

## AI 生图默认配置

- `BaseUrl`: `https://yunwu.ai`
- `Model`: `doubao-seedream-5-0-260128`
- `FallbackEndpoint`: `/v1/images/generations`
- `OpenAIImagePath`: `/v1/images/generations`

## 常用命令

默认自动生图：

```powershell
.\scripts\publish-direct.ps1 .\example.md
```

跳过本次自动生图：

```powershell
.\scripts\publish-direct.ps1 .\example.md -NoAutoCover
```

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

