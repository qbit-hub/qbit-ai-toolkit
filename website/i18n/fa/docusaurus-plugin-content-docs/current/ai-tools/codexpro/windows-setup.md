---
id: windows-setup
title: راه‌اندازی CodexPro روی Windows
sidebar_label: راه‌اندازی Windows
---

# راه‌اندازی CodexPro روی Windows

این راهنما یک deployment عمومی و قابل استفاده مجدد را توضیح می‌دهد، نه snapshot یک سیستم، پروژه، hostname، tunnel، account یا package-manager layout خاص.

برای مقادیری مثل `<WORKSPACE_PATH>`، `<PUBLIC_HOSTNAME>`، `<NGROK_HOSTNAME>` و `<CONNECTOR_NAME>` از placeholder استفاده کنید. username، tunnel ID، Runtime API key، ngrok credential، MCP token یا private path مربوط به deployment دیگر را داخل مستندات canonical قرار ندهید.

## Providerهای پشتیبانی‌شده

Installer ویندوزی Qbit می‌تواند هرکدام از providerهای زیر را به‌صورت مستقل configure کند:

| Provider | Local MCP | Remote authentication | External state |
|---|---:|---|---|
| OpenAI Secure MCP Tunnel | `127.0.0.1:8788` | OpenAI tunnel runtime | tunnel ID و Runtime API key موجود |
| Cloudflare named tunnel | `127.0.0.1:8787` | CodexPro query token | Cloudflare login/tunnel/DNS |
| ngrok | `127.0.0.1:8789` | CodexPro query token | ngrok config و hostname تحت مالکیت user |

می‌توان فقط یکی، دو مورد یا هر سه provider را انتخاب کرد. نصب هر سه اجباری نیست. همه local listenerها روی loopback باقی می‌مانند.

## سیاست نسخه

Customization ویندوزی Qbit به **CodexPro `0.29.0`** پین شده است، چون workspace-sandbox و direct-host extension روی همین build patch می‌شوند. این patch را بدون review و validation روی version دیگر اعمال نکنید.

Versionهای common tool را ثبت کنید:

```powershell
pwsh --version
git --version
codex --version
codexpro --version
```

Version provider-specific را فقط در صورت استفاده بررسی کنید:

```powershell
cloudflared --version
ngrok version
```

## نصب پیشنهادی

از installer versioned زیر `installers/codexpro/` استفاده کنید.

### فقط OpenAI

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels openai `
  -DefaultTunnel openai
```

### فقط Cloudflare

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels cloudflare `
  -Hostname '<PUBLIC_HOSTNAME>' `
  -TunnelName '<TUNNEL_NAME>'
```

### فقط ngrok

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels ngrok `
  -NgrokHostname '<NGROK_HOSTNAME>'
```

### چند provider

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\install.ps1 `
  -WorkspaceRoot '<WORKSPACE_PATH>' `
  -Tunnels @('openai', 'cloudflare', 'ngrok') `
  -DefaultTunnel openai `
  -Hostname '<PUBLIC_HOSTNAME>' `
  -TunnelName '<TUNNEL_NAME>' `
  -NgrokHostname '<NGROK_HOSTNAME>'
```

اگر `-Tunnels` مشخص نشود، برای backward compatibility با رفتار قبلی فقط **Cloudflare** انتخاب می‌شود. در این حالت `-Hostname` مانند قبل الزامی است.

اگر `-DefaultTunnel` مشخص نشود، اولین provider انتخاب‌شده default خواهد بود. Provider تکراری یا defaultی که انتخاب نشده باشد رد می‌شود.

## پیش‌نیازهای مشترک

هر configuration به این موارد نیاز دارد:

1. PowerShell 7؛
2. Git for Windows و Git Bash؛
3. یک JavaScript package manager پشتیبانی‌شده؛
4. Codex CLI با session احراز هویت‌شده؛
5. CodexPro `0.29.0`.

Bun اجباری نیست. Installer مسیر واقعی package را resolve و ثبت می‌کند و به layout اختصاصی Bun وابسته نیست.

## پیش‌نیازهای هر provider

### OpenAI Secure MCP Tunnel

OpenAI mode به یک **tunnel از قبل provision شده** و Runtime API key موجود نیاز دارد.

Defaultهای conventional:

```text
tunnel-client executable: $HOME\.tunnel-client\bin\tunnel-client.exe
tunnel id file:           $HOME\.tunnel-client\codexpro\tunnel-id.txt
runtime key file:         $HOME\.tunnel-client\secrets\runtime.key
profile directory:        $HOME\.config\tunnel-client
runtime alias/profile:    codexpro-laptop
```

همه این pathها و nameها قابل override هستند.

Runtime به tunnel موجود attach می‌شود:

```text
tunnel-client runtimes connect --alias <ALIAS> --profile <PROFILE> --profile-dir <PROFILE_DIR> --tunnel-id <EXISTING_TUNNEL_ID> --mcp-server-url http://127.0.0.1:8788/mcp --runtime-api-key file:<RUNTIME_KEY_FILE>
```

این flow به `OPENAI_ADMIN_KEY` نیاز ندارد و tunnel جدید ایجاد نمی‌کند. Installer فقط path و metadata غیرمحرمانه را ذخیره می‌کند و محتوای Runtime API key را وارد `deployment.json` یا log نمی‌کند.

در OpenAI mode، CodexPro با `--tunnel none --no-auth` روی loopback اجرا می‌شود و remote authentication بر عهده OpenAI tunnel boundary است.

### Cloudflare named tunnel

Cloudflare mode روی local port `8787` اجرا می‌شود. وقتی Cloudflare انتخاب شده باشد، `-Hostname` الزامی است و `-TunnelName` به‌صورت پیش‌فرض `codexpro-local` است.

اگر `cloudflared` نصب نباشد، installer می‌تواند آن را با winget نصب کند. با `-CloudflaredPath` می‌توان executable موجود را صریح مشخص کرد.

اگر `-SkipTunnelSetup` استفاده نشود، flow معمول login/create/route Cloudflare انجام می‌شود. `-SkipTunnelSetup` فقط برای Cloudflare است و بدون انتخاب Cloudflare رد می‌شود.

Default transport برابر `http2` است؛ `auto` و `quic` گزینه‌های صریح جایگزین هستند.

### ngrok

ngrok mode روی local port `8789` اجرا می‌شود. `-NgrokHostname` الزامی است و باید hostname/dev-domain پایدار متعلق به user باشد.

اگر ngrok CLI نصب نباشد، installer می‌تواند package `Ngrok.Ngrok` را با winget نصب کند. با `-NgrokExecutable` می‌توان مسیر CLI را override کرد.

Default config path:

```text
$HOME\.config\ngrok\ngrok.yml
```

Installer آن را با `ngrok config check --config <CONFIG_PATH>` validate می‌کند. Auth token ngrok از user دریافت، کپی یا داخل state ذخیره نمی‌شود.

Browser warning اکانت رایگان ngrok مکانیزم MCP authentication نیست و نباید جای CodexPro token را بگیرد.

## Dispatcher و commandهای cpx

Installer یک dispatcher با raw argument forwarding و یک function کوچک `cpx` در PowerShell profile نصب می‌کند، مگر اینکه `-SkipProfileUpdate` استفاده شود.

از داخل project directory:

```powershell
cd <WORKSPACE_PATH>

cpx
cpx --openai
cpx --cf
cpx --ngrok
```

`cpx` بدون flag، provider پیش‌فرض را اجرا می‌کند. وقتی root مشخص نشده باشد، current PowerShell location به‌عنوان workspace root استفاده می‌شود.

Root را می‌توان صریح هم داد:

```powershell
cpx D:\Projects --cf
cpx D:\Projects --ngrok
cpx --root D:\Projects --openai
```

Runtime overrideهای مهم:

```powershell
cpx --openai --host-exec-mode off
cpx --cf --tunnel-protocol auto
cpx --ngrok --ngrok-hostname <NGROK_HOSTNAME>
```

اگر چند provider flag هم‌زمان داده شود یا provider انتخاب‌شده configure نشده باشد، dispatcher قبل از startup fail می‌شود.

## اتصال به ChatGPT

### OpenAI Secure MCP Tunnel

برای OpenAI mode یک custom token-bearing Server URL نسازید. این provider از OpenAI tunnel integration استفاده می‌کند.

Endpoint محلی:

```text
http://127.0.0.1:8788/mcp
```

این loopback URL یک public ChatGPT connector URL نیست.

### Cloudflare و ngrok

هر دو از CodexPro query-token authentication استفاده می‌کنند:

```text
https://<HOSTNAME>/mcp?codexpro_token=<SECRET>
```

در ChatGPT custom MCP:

| Field | مقدار |
|---|---|
| Server URL | URL کامل شامل token |
| Authentication | None / No Authentication |
| Permissions | فقط actionهای موردنیاز workflow |

کل URL secret است چون credential داخل query string قرار دارد. Launcher تلاش می‌کند URL کامل را بدون چاپ token داخل clipboard بگذارد. `Get-CodexProConnectorUrl.ps1` فقط در صورت اجرای صریح operator URL را چاپ می‌کند.

## State نصب‌شده

```text
$HOME\.codexpro\
├── backups\
├── deployment.json
├── http-token
├── Start-CodexPro.ps1
├── Start-CodexPro.openai.ps1
├── Start-CodexPro.cloudflare.ps1
├── Start-CodexPro.ngrok.ps1
└── Get-CodexProConnectorUrl.ps1
```

`http-token` فقط برای Cloudflare یا ngrok لازم است.

`deployment.json` با schema version 2، providerهای انتخاب‌شده، default provider، executable/config pathها، local portها و metadata غیرمحرمانه را ثبت می‌کند.

## مرزهای امنیتی

### Workspace Bash

```text
ChatGPT -> CodexPro bash -> Codex workspace sandbox -> Git Bash
```

Bash باید داخل workspace انتخاب‌شده محدود بماند. permissive بودن command policy به معنی دسترسی filesystem خارج workspace نیست و containment باید جداگانه تست شود.

### Direct host execution

`host_exec` و `open_app` از workspace Bash جدا هستند. از absolute executable path، argv مستقیم، environment محدود و `HostExecMode` موردنظر استفاده کنید. `full-access` محدودیت UAC ویندوز را دور نمی‌زند.

Permissionهای connector در ChatGPT نیز authorization gate جدا هستند.

### Secretهای provider

این موارد نباید داخل repository، prompt، log عادی یا public docs قرار گیرند:

- CodexPro MCP token؛
- connector URL حاوی token؛
- OpenAI Runtime API key؛
- ngrok auth token؛
- provider cookie یا private key.

Installer در صورت نیاز path فایل secret را ثبت می‌کند، نه محتوای آن را.

## Verification

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\verify.ps1
```

Verifier ابتدا state مشترک CodexPro/package/patch/profile را بررسی می‌کند و سپس فقط dependencyهای providerهای انتخاب‌شده را validate می‌کند.

- Cloudflare: executable، hostname/tunnel config و در صورت provision شدن توسط installer، وجود named tunnel.
- ngrok: executable، hostname، config path و `ngrok config check` بدون startup public tunnel.
- OpenAI: tunnel-client، tunnel-ID/runtime-key fileها و profile inputها بدون چاپ محتوای secret. Runtime لازم نیست از قبل online باشد.

## Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installers\codexpro\uninstall.ps1
```

Uninstall پیش‌فرض launcher/profile/stateهای installer-managed را remove/restore و package patch backup را در صورت امن بودن restore می‌کند.

External provider state به‌صورت پیش‌فرض حفظ می‌شود:

- OpenAI tunnel registration، tunnel-client config، tunnel ID و Runtime API key حذف نمی‌شوند؛
- ngrok account config و hostname ownership حذف نمی‌شوند؛
- Cloudflare tunnel فقط با `-RemoveTunnel` صریح حذف می‌شود.

`-RemoveTunnel` فقط مخصوص Cloudflare است و OpenAI یا ngrok resource را حذف نمی‌کند.

## Troubleshooting

### OpenAI local healthy است ولی ChatGPT disconnected است

`tunnel-client runtimes status <alias> --json` و `remote_error` را جدا بررسی کنید. Local health/ready به‌تنهایی healthy بودن control-plane polling را ثابت نمی‌کند. برای tunnel موجود از Runtime API key attach/reuse flow استفاده کنید و صرفاً برای restart کردن runtime موجود `OPENAI_ADMIN_KEY` اضافه نکنید.

### Cloudflare محلی کار می‌کند ولی public endpoint نه

Hostname ownership، DNS route، named-tunnel state، transport و query-token authentication را جدا بررسی کنید.

### ngrok start نمی‌شود

`ngrok config check --config <CONFIG_PATH>` را اجرا و مالکیت stable hostname را بررسی کنید. برای عبور از browser warning، MCP authentication را ضعیف نکنید.

### VPN/TUN/proxy رفتار tunnel را تغییر می‌دهد

Network middleware می‌تواند providerها را متفاوت تحت تأثیر قرار دهد. Routing را برای هر provider در همان environment بررسی کنید. Reusable installer هیچ فرض hardcoded درباره Hiddify، SOCKS یا محصول VPN خاص ندارد.

## Acceptance checklist

- [ ] CodexPro `0.29.0` و patch مربوط به همان build نصب شده است.
- [ ] فقط providerهای موردنظر انتخاب شده‌اند.
- [ ] Default provider جزو providerهای انتخاب‌شده است.
- [ ] Provider انتخاب‌نشده dependency اجباری ایجاد نمی‌کند.
- [ ] Local MCP فقط روی loopback bind می‌شود.
- [ ] OpenAI از tunnel ID و Runtime API key موجود استفاده می‌کند، نه admin key.
- [ ] Token-bearing URLهای Cloudflare/ngrok به‌عنوان secret مدیریت می‌شوند.
- [ ] برای Cloudflare/ngrok در ChatGPT مقدار Authentication برابر None / No Authentication است.
- [ ] ngrok account credential خارج installer state باقی می‌ماند.
- [ ] Default transport Cloudflare برابر HTTP/2 است مگر override صریح.
- [ ] `cpx` در نبود root صریح از current directory استفاده می‌کند.
- [ ] `cwd=..` نمی‌تواند از workspace خارج شود.
- [ ] Direct host execution approval mode موردنظر را دارد.
- [ ] Uninstall external provider state را به‌صورت پیش‌فرض حفظ می‌کند.
- [ ] برای هر provider استفاده‌شده یک E2E test روی disposable workspace پاس می‌شود.

## قانون مستندسازی

Canonical docs باید contract و placeholder را توصیف کنند، نه machine یک توسعه‌دهنده. username واقعی، private hostname، tunnel ID واقعی، Runtime API key، token-bearing URL، ngrok credential یا package-manager-specific personal path را به‌عنوان مقدار universal منتشر نکنید.
