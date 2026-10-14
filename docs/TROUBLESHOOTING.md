# عیب‌یابی / Troubleshooting

اولین قدم همیشه:

```bash
sudo vt doctor
```

این دستور باینری، معتبربودن `config.json`، فعال‌بودن سرویس، شنود پورت، اعتبار
گواهی، ساعت سیستم، الگوریتم کنترل ازدحام و قوانین فایروال را یک‌جا بررسی می‌کند.

---

## ۱. اتصال برقرار نمی‌شود

**قدم ۱ — سرویس روی سرور بالاست؟**
```bash
sudo vt status
sudo vt logs error
```

**قدم ۲ — پورت از بیرون در دسترس است؟**
از یک ماشین دیگر:
```bash
nc -vz <IP> <PORT>
```
اگر بسته بود، به‌ترتیب این‌ها را چک کنید:
1. فایروال خودِ سرور: `sudo ufw status numbered`
2. **فایروال پنل ابری** (Hetzner Cloud Firewall، AWS Security Group،
   DigitalOcean Firewall، Arvan، ابرآراز و ...) — این رایج‌ترین علت است و از
   داخل سرور قابل دیدن نیست.

**قدم ۳ — پورت مسدود نشده باشد**
بعضی ISPها پورت‌های خاصی را می‌بندند. با `sudo vt port random` یک پورت تازه
بگیرید و دوباره امتحان کنید.

---

## ۲. حالت REALITY وصل نمی‌شود

* سایت استتار (`SNI`) باید TLS 1.3 پشتیبانی کند و از سمت سرور قابل دسترس باشد:
  ```bash
  echo Q | openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com -tls1_3 | head -5
  ```
  اگر خطا داد، سایت را عوض کنید (`www.apple.com`, `www.cloudflare.com`, …) —
  از منو گزینه‌ی ۱۰ (تغییر حالت) یا با نصب دوباره با `--sni`.
* `pbk` (کلید عمومی) در کانفیگ کلاینت باید دقیقاً با `Public key` سرور یکی باشد.
  بعد از هر بار چرخش کلید، کانفیگ کلاینت را دوباره بگیرید: `sudo vt viewconfig`.
* ساعت سرور و کلاینت باید تقریباً یکی باشد.

---

## ۳. خطای گواهی SSL

```bash
sudo vt logs cert
sudo vt renew-cert
```

**صدور گواهی دامنه ناموفق بود**
* رکورد A دامنه باید به آی‌پی عمومی سرور اشاره کند. برنامه در هنگام نصب این را
  بررسی و گزارش می‌کند.
* اگر دامنه پشت Cloudflare است و پروکسی (ابر نارنجی) روشن است، یا پروکسی را
  خاموش کنید یا از روش DNS استفاده کنید:
  ```bash
  sudo vt install --mode ws-tls --domain your.domain \
       --cert letsencrypt-domain --acme dns \
       --dns-plugin dns_cf --dns-token "TOKEN" --yes
  ```
* پورت ۸۰ باید باز باشد (روش standalone).

**گواهی آی‌پی صادر نشد**
* پورت ۸۰ باید از اینترنت قابل دسترس باشد.
* گواهی آی‌پی فقط با پروفایل `shortlived` و اعتبار ~۶ روز صادر می‌شود؛ اگر
  acme.sh شما قدیمی است آن را به‌روز کنید:
  ```bash
  sudo /etc/vt/acme.sh --upgrade --home /etc/vt/acme
  ```
* اگر باز هم نشد، برنامه پیشنهاد گواهی خودامضا می‌دهد؛ یا دستی:
  `sudo vt selfsigned-cert`

**گواهی خودامضا: کلاینت خطا می‌دهد**
طبیعی است — باید `allowInsecure` فعال باشد. برنامه این را خودش در لینک
اشتراک (`allowInsecure=1`) می‌گذارد. اگر کانفیگ را دستی نوشته‌اید، اضافه‌اش کنید.

---

## ۴. سرویس بعد از ریبوت بالا نمی‌آید

```bash
systemctl is-enabled xray.service      # باید enabled باشد
systemctl status xray.service
sudo vt logs error
```
اگر `disabled` بود:
```bash
sudo systemctl enable --now xray.service
```

---

## ۵. سرعت پایین

```bash
sysctl net.ipv4.tcp_congestion_control    # باید bbr باشد
```
اگر `cubic` بود، BBR در هسته فعال نیست:
```bash
sudo modprobe tcp_bbr
lsmod | grep bbr
```
برای فعال‌سازی دائمی، `tcp_bbr` را به `/etc/modules-load.d/bbr.conf` اضافه کنید.

موارد دیگر:
* MTU: اگر از تونل دیگری (مثل WireGuard روی همان VPS) استفاده می‌کنید، MTU را
  کم کنید.
* برنامه به‌طور پیش‌فرض `net.ipv4.tcp_notsent_lowat` و بافرها را تنظیم می‌کند؛
  اگر دستی sysctl را عوض کرده‌اید، `/etc/sysctl.d/99-vt-tunnel.conf` را ببینید.

---

## ۶. فایروال دسترسی SSH را قطع کرد

اگر هنوز یک نشست باز دارید، **آن را نبندید** و:
```bash
sudo ufw allow 22/tcp        # یا پورت SSH واقعی شما
sudo ufw status numbered
```
اگر هیچ نشستی ندارید، از کنسول پنل ابری (VNC/Console) وارد شوید و:
```bash
sudo ufw disable
```

---

## ۷. نصب نیمه‌تمام ماند

لاگ کامل نصب اینجا است:
```bash
sudo vt logs install
```
برای شروع دوباره:
```bash
sudo vt uninstall --purge --yes
sudo vt install
```

---

## ۸. فایل‌های مفید برای گزارش مشکل

```bash
sudo vt doctor
sudo vt logs error
sudo vt logs install
cat /etc/vt/vt.env | grep -v PRIVATE
```

> ⚠️ هرگز `REALITY_PRIVATE`، `privkey.pem` یا `users.json` را برای کسی نفرستید.
