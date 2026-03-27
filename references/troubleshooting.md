# 故障排查指南

`weixin-publish` 当前仅依赖内置样式化渲染器与直连微信 API，不再依赖 `wenyan` 或 `node`。

## 1. IP 不在白名单

错误信息：
```text
ip not in whitelist
```

处理方法：

1. 获取公网 IP：`curl ifconfig.me`
2. 登录 [https://mp.weixin.qq.com/](https://mp.weixin.qq.com/)
3. 在“开发 -> 基本配置 -> IP 白名单”中加入当前机器公网 IP
4. 重试发布

## 2. 环境变量未设置

错误信息：
```text
Missing WECHAT_APP_ID / WECHAT_APP_SECRET.
```

处理方法：

```powershell
$env:WECHAT_APP_ID = "your_app_id"
$env:WECHAT_APP_SECRET = "your_app_secret"
```

若使用 `-AutoCover`，还需：

```powershell
$env:YUNWU_API_KEY = "your_yunwu_key"
```

## 3. Markdown 不是 UTF-8

错误信息：
```text
Markdown file must be valid UTF-8: <path>
```

处理方法：

- 将 Markdown 文件重新保存为 UTF-8
- 重新执行发布

说明：
- 脚本会在执行前强制检查 UTF-8
- `generate-cover.ps1` 回写 frontmatter 时也会保持 UTF-8 输出

## 4. Frontmatter 缺失

错误信息：
```text
Frontmatter title is required.
Frontmatter cover is required.
```

最小可用示例：

```markdown
---
title: 文章标题
cover: ./assets/default-cover.jpg
author: Cursor
---

# 正文标题
```

关键点：

- `title` 必填
- `cover` 必填
- frontmatter 必须位于文件顶部

## 5. 图片上传失败

常见原因：

- 本地图片路径错误
- 网络图片无法访问
- 图片格式或大小不符合微信要求

处理方法：

- 检查 `cover` 路径是否存在
- 检查正文图片 URL 是否可访问
- 优先使用 `jpg` / `png`

## 6. API 凭证错误

错误信息：
```text
invalid credential
```

处理方法：

1. 检查 AppID / AppSecret
2. 在公众号后台重新核对“开发 -> 基本配置”
3. 更新环境变量后重试

## 7. 网络连接问题

错误信息：
```text
connect ETIMEDOUT
```

处理方法：

- 测试 `https://api.weixin.qq.com` 连通性
- 稍后重试
- 检查本机代理、防火墙和公司网络策略

## 8. 正文格式不理想

说明：

- 当前正文由内置样式化渲染器生成
- 支持标题、段落、列表、引用、代码块、行内代码、链接和图片
- 若排版仍不理想，请改进 `scripts/publish-direct.ps1` 中的 `Convert-MarkdownToBasicHtml()` 和 `Convert-InlineMarkdown()`

## 检查列表

- Markdown 为 UTF-8
- frontmatter 中有 `title` 和 `cover`
- 环境变量已设置
- IP 在白名单中
- 图片路径或图片 URL 有效
