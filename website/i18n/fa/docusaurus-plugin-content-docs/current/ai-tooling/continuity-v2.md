---
title: AI Context Continuity v2
sidebar_label: Continuity v2
---

# AI Context Continuity v2

Continuity v2 مدل durable برای نگهداری context پروژه است که توسط `installer.ai-context` ارائه می‌شود. نسخه پایدار فعلی `1.2.8` است. هدف آن این است که کار repository در session، اکانت، ماشین یا دوره آفلاین جدید دقیقاً قابل ادامه باشد، بدون اینکه تاریخچه chat به منبع اصلی حقیقت تبدیل شود.

## محدوده و مرجعیت

AI Context فقط evidence هماهنگی را نگه می‌دارد: workstream فعلی، work itemها، execution cursor، blockerها، acceptance criteria، provenance اعتبارسنجی، تصمیم‌ها، رویکردهای ردشده و next action دقیق. این context جایگزین مرجعیت repository نیست. Source، testها، schema/migrationها، contractها، ADRها و ownerهای canonical همچنان برای claimهای implementation مرجع هستند.

اصل اصلی Continuity این است:

> `nextAction` فقط pointer به کار ساختاریافته و durable است، نه جایگزین backlog.

Agent نباید یک tracked workstream حل‌نشده را به summary آزاد کوتاهی تبدیل کند که identity یا status آیتم‌ها را از بین ببرد.

## namespaceهای schema

چند فایل مختلف فیلدی به نام `schemaVersion` دارند، اما contract آن‌ها مستقل است:

- checkpointهای substantive در Continuity v2 از `schemaVersion: 2` استفاده می‌کنند؛
- فایل member یعنی `.ai/context/config.json` فعلاً schema مستقل نسخه `1` دارد؛
- manifest و marker انتقال آفلاین فعلاً schema مستقل نسخه `1` دارند؛
- installer ownership state نیز contract مستقل خودش را دارد.

صرفاً به‌دلیل v2 بودن checkpoint نباید نسخه schema فایل config یا transfer را افزایش داد.

Checkpointهای `schemaVersion: 1` فقط برای backward compatibility پذیرفته می‌شوند، آن هم وقتی باعث حذف unresolved work در v2 نشوند. تمام checkpointهای substantive جدید باید checkpoint schema v2 باشند.

## tracked workstream

هر زمان کار قابل resume باقی مانده است از `continuity.mode: tracked` استفاده کنید. tracked workstream شامل ID پایدار، title، status، objective، نقش repositoryها، execution cursor و work itemهای durable است.

Statusهای work item:

- `PENDING`
- `IN_PROGRESS`
- `BLOCKED`
- `COMPLETED`
- `CANCELLED`
- `SUPERSEDED`

Statusهای workstream:

- `PROPOSED`
- `IN_PROGRESS`
- `BLOCKED`
- `COMPLETED`
- `CANCELLED`
- `SUPERSEDED`

هر work item meaningful باید identity پایدار و اطلاعات لازم برای resume صحیح را داشته باشد: priority، scope، acceptance criteria، dependencyها، blockerها، validation requirementها و در صورت نیاز notes/provenance.

Execution cursor باید current item دقیق، last completed item/action، phase و next action را ثبت کند.

## snapshot mode

`continuity.mode: snapshot` فقط زمانی مجاز است که هیچ tracked workstream حل‌نشده‌ای وجود نداشته باشد. snapshot راه میان‌بر برای حذف taskهای pending یا blocked نیست.

Workstream terminal باید status آیتم‌هایش را صریحاً انتقال دهد. Workstreamهای completed/cancelled/superseded از `workstreams/active/` به `workstreams/archive/` منتقل می‌شوند و حذف خاموش نمی‌شوند.

## invariantهای fail-closed

Lifecycle تغییراتی را که continuity را مبهم یا ناقص می‌کنند رد می‌کند؛ از جمله:

- ناپدید شدن silent یک unresolved work-item ID؛
- transition نامعتبر status یا بازکردن بی‌قاعده آیتم terminal؛
- dependency cycle؛
- آیتم BLOCKED بدون blocker معتبر از نوع work item؛
- validation ID تکراری؛
- جایگزینی active workstream با ID دیگر بدون terminal کردن قبلی؛
- checkpoint schema v1 یا snapshot که unresolved v2 work را پاک کند.

اگر invariant شکست خورد، مدل checkpoint را اصلاح کنید. برای عبور از validation، context history را reset یا rewrite نکنید.

## validation ledger و freshness

Evidence اعتبارسنجی به‌صورت append-only در `validation/repositories/` ذخیره می‌شود. هر entry یک validation ID immutable دارد و فقط چیزی را ثبت می‌کند که واقعاً اجرا شده است.

Lifecycle validation را به repository HEAD و deterministic worktree fingerprint متصل می‌کند. پس از تغییر source/worktree، evidence قبلی ممکن است stale شود. Evidence stale همچنان evidence تاریخی است، اما نباید validation فعلی معرفی شود.

Agent فقط برای gateهایی که واقعاً روی همان repository/worktree اجرا شده‌اند ledger entry جدید ایجاد می‌کند.

## lifecycle در member repository

Repositoryهای managed روی Windows و POSIX همین actionها را دارند:

```text
start
status
checkpoint
audit
export
import
reconnect
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context.ps1 start
```

Linux/macOS:

```bash
bash .ai/context/context.sh start
```

قبل از substantive work یک بار `start` را اجرا کنید و `.ai-bridge/context-runtime.md` را بخوانید. Active workstream، cursor، unresolved itemها، validation freshness و membership diagnostics داخل آن resume contract هستند.

Membership در central context صریح است. `repositories/repositories.yaml` فهرست repositoryهای managed و role آن‌ها را نگه می‌دارد. Member config باید همان project ID را داشته باشد و repository ID آن در registry ثبت شده باشد. Repository ثبت‌نشده در `start` و `checkpoint` fail-closed می‌شود؛ `status` همچنان runtime diagnostic تولید می‌کند، اما با وضعیت unhealthy خارج می‌شود. Action `audit` کاملاً read-only است و registry را با Git worktreeهای نزدیک مقایسه می‌کند تا memberهای missing/mismatched و siblingهای محتملِ ثبت‌نشده را بدون auto-register یا mutation تاریخچه گزارش کند.

بعد از milestone substantive و validated که continuity durable را تغییر می‌دهد، `.ai-bridge/context-checkpoint.json` را بسازید و `checkpoint` اجرا کنید. سؤال‌های read-only یا هر پیام chat نیاز به checkpoint ندارند. Publication آنلاین checkpoint بر پایه ancestry است: بعد از push rejection، lifecycle branch تنظیم‌شده را fetch می‌کند و فقط وقتی یکی از historyها ancestor دیگری باشد retry یا fast-forward انجام می‌دهد. اگر هر دو history مستقل جلو رفته باشند، operation fail-closed می‌شود و هر دو history حفظ می‌شوند؛ checkpoint هیچ‌وقت به‌صورت خودکار merge، rebase، reset یا force-push نمی‌کند.

## انتقال آفلاین و بین ماشین‌ها

`export` در `.ai-bridge/context-transfer/` یک Git bundle و manifest می‌سازد. Context cache باید clean باشد و export فایل‌های tracked central context را از نظر نوع فایل، path boundary، UTF-8 و secret-like material بررسی می‌کند.

Manifest انتقال را به project/repository identity، context branch، provenance member/context، byte length، SHA-256 و summary cursor فعلی bind می‌کند.

`import` قبل از پذیرش cache، شکل manifest، project/repository/branch identity، اندازه و SHA-256 bundle، `git bundle verify` و exact source context HEAD را بررسی می‌کند. Session واردشده حالت `OFFLINE_IMPORTED_CONTEXT` دارد؛ `start`، `status` و `checkpoint` بدون network قابل استفاده‌اند و offline checkpoint فقط local commit ایجاد می‌کند و push نمی‌کند.

## reconnect

`reconnect` تنها خروج خودکار پشتیبانی‌شده از offline imported mode است:

- اگر remote ancestor local باشد: normal non-force push؛
- اگر local ancestor remote باشد: fast-forward local؛
- اگر هر دو مستقل جلو رفته باشند: fail closed و حفظ هر دو history و offline marker.

Reconnect هیچ‌وقت روی continuity diverged به‌صورت خودکار merge، rebase، reset یا force-push انجام نمی‌دهد.

## مرزهای امنیتی

Context نباید credential، token، cookie، private key، مقدار `.env`، customer secret، production secret یا raw chat transcript ذخیره کند. Export قبل از packaging محتوای tracked context را از نظر secret-like material اسکن می‌کند.

Context remote نباید credential embedded داشته باشد. Runtime Git از credential chain میزبان استفاده می‌کند. Windows می‌تواند برای GitHub خصوصی از `gh auth git-credential` به‌عنوان fallback استفاده کند؛ POSIX به Git credential helperهای عادی متکی است.

## contract مربوط به repository policy

`AGENTS.md` یک managed member باید این قواعد را الزام کند:

1. اجرای خودکار context `start` قبل از substantive work؛
2. خواندن `.ai-bridge/context-runtime.md`؛
3. checkpoint schema v2 برای continuity substantive جدید؛
4. tracked mode تا وقتی unresolved work وجود دارد؛
5. حفظ صریح work-item ID، dependency، blocker، acceptance criteria و cursor؛
6. validation freshness مبتنی بر fingerprint؛
7. reconnect آفلاین به‌صورت fail-closed؛
8. حفظ dirty work نامرتبط و ممنوعیت destructive recovery.

`qbit-ai-toolkit` مرجع installer است و عمداً مثل یک consumer عادی روی خودش self-install نمی‌شود، اما root `AGENTS.md` آن باید همین policy Continuity v2 را رعایت کند.

## قرارداد release و rollout

Release مربوط به Continuity با ویرایش template تمام نمی‌شود. قبل از fleet rollout باید metadata installer، unit test، Windows/POSIX installer integration، legacy migration، lifecycle behavior، cross-platform parity و در صورت اثرگذاری runtime یک real-member canary validate شوند.

Rollout repositoryها باید یکی‌یکی انجام شود. در dirty worktree فقط pathهای installer-owned stage/commit شوند و باید ثابت شود product work قبلی unstaged/untracked باقی مانده است. برای ساده‌کردن rollout از reset، clean، stash، rebase یا force-push استفاده نکنید.

## محل‌های canonical implementation

- installer metadata و entrypointها: `installers/ai-context/`
- member policy template: `installers/ai-context/templates/common/member/agents-block.md.tpl`
- member launcherها: `installers/ai-context/templates/common/member/context.ps1`، `context.sh` و `context.py`
- checkpoint schema: `installers/ai-context/templates/common/central/schemas/checkpoint.schema.json`
- continuity invariantها: `installers/ai-context/templates/common/central/tooling/context-continuity.ps1` و `context-lifecycle.py`
- lifecycle regression suiteها: `installers/ai-context/templates/common/central/tests/`
- راهنمای central تولیدشده: `installers/ai-context/templates/common/central/docs/context-automation.md.tpl`

اگر documentation و runtime behavior با هم اختلاف داشتند، drift را در source و test owner اصلاح کنید؛ documentation به‌تنهایی runtime authority نیست.
