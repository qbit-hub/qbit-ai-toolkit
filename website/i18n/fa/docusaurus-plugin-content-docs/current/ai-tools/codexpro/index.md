---
id: index
title: CodexPro
sidebar_label: معرفی
---

# CodexPro

CodexPro یک bridge متن‌باز است که workspace توسعه محلی را از طریق MCP در اختیار ChatGPT قرار می‌دهد و repository tooling، اجرای Bash در sandbox و اجرای مستقیم اختیاری روی host را به‌عنوان capabilityهای مستقل نگه می‌دارد.

این مستندات **deployment-neutral** هستند. برای username، workspace root، connector name، package location، hostname، tunnel ID و credential از placeholder استفاده کنید و مقادیر یک سیستم واقعی را به‌عنوان مقدار canonical منتشر نکنید.

## راهنماهای موجود

- [راهنمای Windows](./windows-setup.md) — راه‌اندازی deployment پچ‌شده Qbit با پشتیبانی اختیاری از OpenAI Secure MCP Tunnel، Cloudflare و ngrok.
- [راهنمای Linux](./linux-setup.md) — نصب و اجرای CodexPro روی Linux، local/public HTTPS، repository boundary و اجرای interactive/headless.
- [راهنمای macOS](./macos-setup.md) — نصب و اجرای CodexPro روی macOS با پوشش shell/PATH، privacy permission، معماری CPU، tunnel و repository-scoped access.

## مرز package manager

CodexPro در اکوسیستم npm توزیع می‌شود، اما setup به Bun وابسته نیست. هر package manager سازگاری که version موردنیاز CodexPro را نصب کند و executable `codexpro` را روی `PATH` قرار دهد قابل استفاده است. Storage layout package manager بخشی از معماری CodexPro نیست.

## مرز امنیتی مهم

Sandboxed Bash و اجرای مستقیم روی host دو capability مستقل هستند:

- Bash باید داخل repository/workspace انتخاب‌شده محدود بماند.
- Direct host execution، اگر فعال باشد، با اختیار OS user جاری اجرا می‌شود و به approval و credential model سخت‌گیرانه‌تری نیاز دارد.

Connector URLهای دارای token، OpenAI Runtime API key و credentialهای provider را secret در نظر بگیرید. Narrowest practical workspace root را انتخاب کنید و فقط capabilityهای لازم workflow را فعال کنید.

## Launcher چند-provider روی Windows

Installer ویندوزی dispatcher و launcherهای provider-specific زیر را نصب می‌کند:

- `Start-CodexPro.ps1` — provider پیش‌فرض را انتخاب می‌کند یا `--openai`، `--cf` و `--ngrok` را route می‌کند؛
- `Start-CodexPro.openai.ps1` — OpenAI Secure MCP Tunnel روی local port `8788`؛
- `Start-CodexPro.cloudflare.ps1` — Cloudflare named tunnel روی local port `8787`؛
- `Start-CodexPro.ngrok.ps1` — ngrok روی local port `8789`.

می‌توان فقط یکی، دو مورد یا هر سه provider را configure کرد؛ installer هر سه را اجباری نمی‌کند.

Cloudflare و ngrok از CodexPro query-token Server URL استفاده می‌کنند و در ChatGPT باید `Authentication: None / No Authentication` انتخاب شود. OpenAI Secure MCP Tunnel از integration خود OpenAI استفاده می‌کند و custom token-bearing Server URL ندارد.

این repository asset ویندوزی `installer.codexpro` را زیر `installers/codexpro/` منتشر می‌کند. این installer deployment پین‌شده CodexPro `0.29.0` را آماده می‌کند و low-level package patch را به‌عنوان جزئیات version-specific داخلی نگه می‌دارد.
