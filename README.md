# TradeChi

ربات سیگنال فارکس با موتور Python، داشبورد Flask، پل فیسبوک و اعلان تلگرام. برای اجرای production روی VPS با PM2 و Nginx طراحی شده است.

## اجزا

| بخش | مسیر | توضیح |
|-----|------|--------|
| Signal engine | `engine/` | تحلیل بازار، تولید سیگنال، شبیه‌سازی |
| Dashboard | `dashboard/` | پنل وب Flask + Gunicorn |
| Facebook bridge | `Facebook/` | ارسال سیگنال به گروه‌های فیسبوک |
| PM2 | `ecosystem.config.js` | dashboard، signal-engine، signal-server |
| Deploy | `deploy/` | Nginx، bootstrap، auto-deploy |

## پیش‌نیاز

- Ubuntu 22.04 یا 24.04
- Python 3.12+
- Node.js 20+ و PM2
- Nginx

## نصب سریع

```bash
git clone git@github.com:mohammaddrboy-rgb/tradechi.git /opt/trading-bot
cd /opt/trading-bot
cp .env.example .env
# مقادیر .env را پر کنید
python3 -m venv venv
./venv/bin/pip install -r requirements-engine.txt
./venv/bin/pip install -r dashboard/requirements.txt
pm2 start ecosystem.config.js
pm2 save
```

## تنظیمات

فایل `.env.example` فهرست کامل متغیرها را دارد:

- `TWELVE_DATA_API_KEY` برای دادهٔ بازار
- `TELEGRAM_BOT_TOKEN` و `TELEGRAM_CHAT_ID`
- `DASHBOARD_USERNAME` و `DASHBOARD_PASSWORD`
- `BEHIND_PROXY=1` وقتی Nginx یا Cloudflare جلو سرور است

فایل `.env` را commit نکنید.

## PM2

```bash
pm2 status
pm2 logs dashboard
pm2 logs signal-engine
pm2 restart all
```

| سرویس | پورت | نقش |
|-------|------|-----|
| dashboard | 8080 | پنل وب |
| signal-server | 5005 | API فیسبوک |
| signal-engine | — | موتور سیگنال |

## Nginx

نمونه vhost در `deploy/nginx/testmachine.store.conf` است. برای HTTPS پشت Cloudflare، `BEHIND_PROXY=1` را در `.env` بگذارید.

## CI/CD

Workflow در `.github/workflows/deploy.yml` با push به `main` فقط فایل‌های dashboard را deploy می‌کند. برای deploy کامل از `deploy/bootstrap-from-github.sh` استفاده کنید.

Secrets لازم در GitHub:

- `SSH_PRIVATE_KEY`
- `DEPLOY_HOST`

## دادهٔ runtime

دادهٔ production (sqlite، لاگ، session فیسبوک) داخل Git نیست. برای انتقال سرور:

```bash
sudo bash deploy/export-runtime.sh   # روی سرور قدیم
sudo bash deploy/import-runtime.sh /path/to/archive.tar.gz  # روی سرور جدید
```

## تست

```bash
./venv/bin/python -m pytest tests/
```

## مستندات بیشتر

- `docs/PRODUCTION_MIGRATION_FA.md` برای انتقال سرور
- `Facebook/README_HOW_TO_RUN.txt` برای پل فیسبوک

## لایسنس

استفاده خصوصی.
