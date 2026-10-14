# VPS-Traffic-Tunnel

یک برنامه‌ی تک‌فایلی (Bash) برای سرورهای مجازی Ubuntu/Debian که **بدون محیط گرافیکی و فقط با SSH** اجرا می‌شود و در چند دقیقه یک **تونل VLESS همیشه‌فعال** روی سرور شما نصب می‌کند.

بعد از اجرا یک منوی ساده می‌بینید:

```
  1) install      — نصب تونل و سرویس همیشه‌فعال
  2) viewConfig   — نمایش کانفیگ، لینک اشتراک و کد QR
  3) uninstall    — حذف کامل
```

`install` از شما می‌پرسد دامنه دارید یا نه، پورت تصادفی انتخاب می‌کند، گواهی SSL رایگان با **تمدید خودکار** می‌گیرد، یک سرویس systemd می‌سازد که با هر ریبوت بالا می‌آید، و در پایان کانفیگ آماده + کد QR را نشان می‌دهد.

---

## نصب سریع

```bash
curl -fsSL https://raw.githubusercontent.com/wrappedman/VPS-Traffic-Tunnel/main/bootstrap.sh | sudo bash
sudo vt
```

یا دستی:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/wrappedman/VPS-Traffic-Tunnel.git
cd VPS-Traffic-Tunnel
sudo ./vt self-install     # برنامه را در /opt/vt می‌گذارد و دستور vt را در PATH قرار می‌دهد
sudo vt
```

---

## چه چیزی نصب می‌شود؟

| مورد | توضیح |
|---|---|
| **Xray-core** | آخرین نسخه از GitHub، در `/usr/local/bin/xray` |
| **سرویس systemd** | `xray.service` با `Restart=always` و `WantedBy=multi-user.target` → همیشه فعال، حتی بعد از ریبوت |
| **کانفیگ VLESS** | در `/usr/local/etc/xray/config.json` با پورت تصادفی |
| **گواهی SSL** | Let's Encrypt (دامنه یا آی‌پی) یا خودامضا — همه رایگان و با تمدید خودکار |
| **تایمر سلامت** | هر ۵ دقیقه سرویس و پورت را بررسی می‌کند و در صورت قطعی، ری‌استارت می‌کند |
| **تایمر تمدید گواهی** | هر ۱۲ ساعت (به‌علاوه‌ی cron خودِ acme.sh) |
| **BBR و تنظیمات شبکه** | `/etc/sysctl.d/99-vt-tunnel.conf` |
| **swap** | اگر RAM سرور کمتر از ۲ گیگ باشد |
| **فایروال UFW** | فقط پورت SSH و پورت تونل باز می‌ماند |
| **logrotate** | لاگ‌ها خودکار چرخش می‌شوند |
| **خودِ برنامه** | در پایان نصب به `/opt/vt` کپی می‌شود و دستور `vt` در PATH قرار می‌گیرد (تایمرها به همین مسیر نیاز دارند) |

---

## سه حالت تونل

### ۱) REALITY — پیشنهاد ما
```
VLESS + TCP + REALITY (XTLS Vision)
```
* **بدون دامنه** و **بدون گواهی SSL** کار می‌کند — مستقیم روی آی‌پی.
* ترافیک شما پشت یک دست‌دادن TLS واقعی با یک سایت معروف (مثل `www.microsoft.com`) پنهان می‌شود، بنابراین از بیرون مثل یک اتصال HTTPS معمولی به آن سایت به نظر می‌رسد.
* بهترین گزینه وقتی دامنه ندارید.

### ۲) WebSocket + TLS (پورت ۴۴۳)
```
VLESS + WebSocket + TLS
```
* شبیه‌ترین حالت به یک وب‌سایت HTTPS واقعی.
* مسیر WebSocket یک رشته‌ی تصادفی ۳۲ کاراکتری است (`/a3f9…/`).
* نیاز به گواهی SSL دارد.

### ۳) TCP + TLS (پورت دلخواه)
```
VLESS + TCP + TLS (XTLS Vision)
```
* مثل حالت ۱ ولی با TLS واقعی به‌جای REALITY.
* نیاز به گواهی SSL دارد.

---

## گواهی SSL رایگان با تمدید خودکار

سه مسیر وجود دارد و خودِ برنامه در هنگام نصب پیشنهاد درست را می‌دهد:

### الف) دامنه دارید → Let's Encrypt
گواهی ۹۰ روزه‌ی معتبر، تمدید خودکار با acme.sh. سه روش تأیید:

| روش | کی استفاده شود |
|---|---|
| **standalone** | ساده‌ترین. اسکریپت موقتاً پورت ۸۰ را باز می‌کند. پورت ۸۰ باید آزاد و باز باشد. |
| **webroot** | اگر یک وب‌سرور (nginx/apache) روی پورت ۸۰ در حال اجراست. |
| **DNS API** | اگر دامنه هنوز به این سرور اشاره نمی‌کند یا پورت ۸۰ بسته است. با توکن Cloudflare (`dns_cf`) و سایر پلاگین‌های acme.sh کار می‌کند. |

### ب) دامنه ندارید → گواهی Let's Encrypt مخصوص آی‌پی
از **۱۵ ژانویه ۲۰۲۶** لتس‌انکریپت برای آدرس IP هم گواهی معتبر می‌دهد. شرایطش:

* پروفایل `shortlived` — اعتبار گواهی **۱۶۰ ساعت** (کمی بیش از ۶ روز) است.
* فقط با `http-01` یا `tls-alpn-01`؛ یعنی **پورت ۸۰ باید باز باشد**.
* برنامه هر ۳ روز بررسی و خودکار تمدید می‌کند (`acme.sh --days 3`).

نتیجه: یک گواهی **معتبر و سبز** روی آی‌پی خام، بدون allowInsecure.

### ج) گواهی خودامضا
اگر نه دامنه دارید و نه می‌خواهید پورت ۸۰ باز باشد:

* با OpenSSL ساخته می‌شود (ECDSA P-256، اعتبار ۸۲۵ روز).
* یک تایمر systemd هر ۱۲ ساعت بررسی و در نیمه‌ی عمر، خودکار تمدید می‌کند.
* **توجه:** کلاینت باید `allowInsecure` را فعال کند — برنامه این را خودش در کانفیگ و لینک اشتراک می‌گذارد.

---

## عبور «تمام» ترافیک از سرور

سمت سرور، تمام ترافیک ورودی از تونل به اینترنت می‌رود (خروجی پیش‌فرض `freedom` است). سمت کلاینت باید حالت «تمام ترافیک» را روشن کنید:

| پلتفرم | چه کار کنید |
|---|---|
| **اندروید** | v2rayNG / Happ / Streisand → لینک را وارد کنید → حالت **TUN** یا **Global** |
| **iOS/macOS** | Streisand / V2Box / Shadowrocket → **Set as system proxy** یا **Global Routing** |
| **ویندوز** | v2rayN → Import from clipboard → Routing را **Global** کنید و **Set system proxy** را بزنید |
| **لینوکس/دسکتاپ** | فایل `/etc/vt/client.json` را با `xray run -c client.json` اجرا کنید و پروکسی سیستم را روی `127.0.0.1:10808` (SOCKS) یا `10809` (HTTP) بگذارید |

---

## راهنمای دستورات

```bash
sudo vt                       # منوی تعاملی
```

### اصلی
| دستور | کار |
|---|---|
| `vt install` | نصب (تعاملی) |
| `vt viewconfig` | نمایش کانفیگ، لینک اشتراک و QR |
| `vt uninstall [--purge]` | حذف کامل (`--purge` پوشه‌ی `/etc/vt` را هم پاک می‌کند) |

### نصب خودکار (بدون پرسش)
```bash
# REALITY روی آی‌پی با پورت تصادفی
sudo vt install --mode reality --port random --email main --yes

# WebSocket+TLS با دامنه و گواهی Let's Encrypt
sudo vt install --mode ws-tls --domain tunnel.example.com \
     --cert letsencrypt-domain --acme standalone --port 443 --yes

# گواهی Let's Encrypt مخصوص آی‌پی
sudo vt install --mode tcp-tls --cert letsencrypt-ip --port random --yes

# دامنه‌ای که هنوز DNS ندارد، با توکن Cloudflare
sudo vt install --mode ws-tls --domain tunnel.example.com \
     --cert letsencrypt-domain --acme dns \
     --dns-plugin dns_cf --dns-token "YOUR_CF_TOKEN" --yes
```

گزینه‌ها: `--mode --domain --cert --acme --webroot --dns-plugin --dns-env --dns-token --sni --port --email --email-acme --firewall --adblock --no-torrent --force --yes`

### مدیریت کاربران
```bash
sudo vt add-user [name]     # کاربر جدید + لینک اشتراک + QR
sudo vt rm-user [name]
sudo vt users               # لیست کاربران و لینک‌ها
sudo vt stats               # ترافیک مصرفی هر کاربر
sudo vt connections         # اتصالات برقرار
sudo vt rotate-uuid [name]  # تعویض UUID
sudo vt rotate-keys         # چرخش کلیدهای REALITY (کل کانفیگ‌ها عوض می‌شود)
```

### سرویس و نگهداری
```bash
sudo vt status
sudo vt restart | stop | start
sudo vt logs [xray|error|health|cert|install|follow]
sudo vt doctor              # عیب‌یابی خودکار
sudo vt health              # همان کاری که تایمر سلامت انجام می‌دهد
sudo vt update              # به‌روزرسانی Xray-core
sudo vt renew-cert          # تمدید دستی گواهی
sudo vt selfsigned-cert     # ساخت گواهی خودامضای جدید
sudo vt port <n|random>     # تغییر پورت
sudo vt switch-mode         # تغییر حالت تونل
sudo vt backup [dir]        # پشتیبان‌گیری
sudo vt restore <file>      # بازگردانی
```

---

## ساختار فایل‌ها

```
/etc/vt/                     state، کاربران، گواهی‌ها، کانفیگ متنی   (0700)
├── vt.env                   وضعیت نصب (MODE، PORT، کلیدها و ...)
├── users.json               لیست کاربران
├── certs/                   fullchain.pem و privkey.pem
├── acme.sh + acme/          ابزار و حساب Let's Encrypt
├── config.txt               کانفیگ متنی
└── client.json              کانفیگ آماده‌ی کلاینت دسکتاپ

/usr/local/etc/xray/config.json      پیکربندی Xray
/usr/local/bin/xray                  باینری Xray
/usr/local/share/xray/               geoip.dat / geosite.dat (اختیاری)
/var/log/vt/                         لاگ نصب، سلامت، گواهی، خطاهای Xray

/etc/systemd/system/xray.service
/etc/systemd/system/vt-health.{service,timer}
/etc/systemd/system/vt-cert-renew.{service,timer}
/etc/sysctl.d/99-vt-tunnel.conf
/etc/logrotate.d/vt-tunnel
```

---

## نکات امنیتی که رعایت شده

* API آماری Xray فقط روی `127.0.0.1` گوش می‌دهد.
* مسیرهای خصوصی (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `100.64/10`, `169.254/16`, `fc00::/7`) در خروجی مسدود هستند تا از تونل برای اسکن شبکه‌ی داخلی دیتاسنتر استفاده نشود.
* `/etc/vt` با مجوز `0700` و کلید خصوصی با `0600` ذخیره می‌شود.
* در حالت TLS، `rejectUnknownSni` فعال است تا پروب‌های ناشناس رد شوند (برای گواهی آی‌پی به‌طور خودکار غیرفعال می‌شود، چون کلاینت برای IP مقدار SNI نمی‌فرستد).
* قبل از فعال‌کردن فایروال، پورت SSH از روی همان اتصال جاری (`$SSH_CONNECTION`) تشخیص داده و از شما تأیید می‌گیرد.
* مسیر WebSocket و ShortId تصادفی هستند.

---

## تست

```bash
./tests/run_tests.sh
```

شش مرحله: بررسی نحو، ShellCheck، تست واحد توابع، **نصب کامل خشک (dry-run) برای هر چهار ترکیب حالت/گواهی** داخل یک ریشه‌ی موقت، اعتبارسنجی ساختار کانفیگ Xray، و تست حذف.

نصب خشک با متغیر `VT_ROOT` کار می‌کند: تمام مسیرها پیشوند می‌گیرند، بنابراین کل جریان نصب واقعاً اجرا می‌شود بدون اینکه به سیستم دست بزند.

```
PASS: 163   FAIL: 0
```

---

## رفع اشکال سریع

| مشکل | راه‌حل |
|---|---|
| وصل نمی‌شوم | `sudo vt doctor` — سپس فایروال پنل ابری را چک کنید |
| پورت باز است ولی اتصال برقرار نمی‌شود | در حالت REALITY، سایت استتار (`--sni`) را عوض کنید |
| `certificate has expired` | `sudo vt renew-cert` و سپس `sudo vt logs cert` |
| سرویس بالا نمی‌آید | `sudo vt logs error` |
| سرعت کم است | `sysctl net.ipv4.tcp_congestion_control` باید `bbr` باشد |

جزئیات بیشتر: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

---

## مجوز

GPL-3.0 — فایل [LICENSE](LICENSE) را ببینید.

English documentation: [`docs/README.en.md`](docs/README.en.md)
