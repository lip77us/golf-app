# Deploying the Golf App to Railway

This guide covers deploying the Django backend to Railway and connecting it to your
`lipkin.us` domain.

---

## Prerequisites

- A [Railway account](https://railway.app) (free to sign up)
- Your code pushed to a GitHub repository
- Access to your domain registrar (wherever `lipkin.us` is registered)

---

## Step 1 — Push your code to GitHub

If you haven't already, create a GitHub repo and push the project:

```bash
cd /path/to/golf-app
git add .
git commit -m "Add Railway deployment config"
git push origin main
```

---

## Step 2 — Create a new Railway project

1. Go to [railway.app](https://railway.app) and sign in.
2. Click **New Project** → **Deploy from GitHub repo**.
3. Select your golf-app repository.
4. Railway will detect the `Procfile` and `railway.toml` automatically.

---

## Step 3 — Add a Postgres database

1. In your Railway project dashboard, click **+ New** → **Database** → **PostgreSQL**.
2. Railway automatically injects a `DATABASE_URL` environment variable into your
   service — no manual wiring needed.

---

## Step 4 — Set environment variables

In Railway: open your service → **Variables** tab → add the following:

| Variable | Value |
|---|---|
| `SECRET_KEY` | A long random string (generate one at [djecrety.ir](https://djecrety.ir)) |
| `DEBUG` | `False` |
| `ALLOWED_HOSTS` | `golf.lipkin.us,*.up.railway.app` (update after Step 6) |
| `GOLF_API_KEY` | `UY6CYIOJQR6HWCSLXVIIKDILJQ` |

`DATABASE_URL` is already injected by Railway's Postgres addon — do not set it manually.

---

## Step 5 — Run migrations on first deploy

Railway doesn't run migrations automatically. After the first successful deploy:

1. In your service dashboard, click the **three-dot menu** → **Run command**.
2. Enter:
   ```
   python manage.py migrate
   ```
3. Also create a superuser if you want Django admin access:
   ```
   python manage.py createsuperuser
   ```

Alternatively, add a release command to `railway.toml` to run migrations
automatically on every deploy:

```toml
[deploy]
# add this line:
releaseCommand = "python manage.py migrate --noinput"
```

---

## Step 6 — Connect your lipkin.us domain

Yes — Railway fully supports custom domains. Here's how:

### In Railway

1. Open your service → **Settings** → **Networking** → **Custom Domain**.
2. Click **Add Custom Domain** and type `golf.lipkin.us` (or whatever subdomain
   you want — `api.lipkin.us` works too).
3. Railway will show you a **CNAME target** that looks like:
   `<something>.up.railway.app`

### At your domain registrar

1. Log in to wherever `lipkin.us` is registered (GoDaddy, Namecheap, Cloudflare, etc.).
2. Go to DNS settings for `lipkin.us`.
3. Add a **CNAME record**:
   - **Name/Host:** `golf` (or whichever subdomain you chose)
   - **Value/Target:** the `*.up.railway.app` address Railway gave you
   - **TTL:** 300 (or Auto)
4. Save. DNS propagation takes anywhere from a few minutes to a few hours.

### Back in Railway

Once DNS propagates, Railway will automatically provision a free TLS certificate
(HTTPS) for your domain.

### Update ALLOWED_HOSTS

Once the domain is live, update the `ALLOWED_HOSTS` environment variable in Railway
to include your domain:

```
golf.lipkin.us,*.up.railway.app
```

---

## Step 7 — Point the Flutter app at the server

In `mobile/lib/api/client.dart`, update the base URL from `localhost` to your
Railway domain:

```dart
static const String baseUrl = 'https://golf.lipkin.us';
```

Rebuild and reinstall the app on your phone.

---

## Local development (unchanged)

Your local workflow is exactly the same as before. The `.env` file now includes
`DEBUG=True` and `ALLOWED_HOSTS=localhost,127.0.0.1` so local dev continues to
work without any changes.

```bash
python manage.py runserver
```

---

## Costs

Railway's **Hobby plan** ($5/month) is sufficient for testing. It includes:
- 512 MB RAM, shared vCPU
- Postgres (1 GB storage)
- Unlimited deploys

You can start on the free trial and upgrade when you're ready to keep it running
24/7.
