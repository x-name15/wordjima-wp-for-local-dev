# WordJima

Dockerized WordPress for local development.

WordJima is a practical local WordPress environment powered by Docker Compose.

### Stack

- WordPress: `wordpress:6.9.4-php8.4`
- MySQL: `mysql:8.0`
- HTTP URL: `http://localhost:8080`
- WordPress source mounted from `./wordpress`

### Requirements

- Docker Desktop (with Docker Compose plugin)
- PowerShell (Windows)

### Quick Start

1. Configure environment values in `.env`.
2. Run:

```powershell
.\setup.ps1
```

3. Open `http://localhost:8080`.

### setup.ps1 options

```powershell
.\setup.ps1          # Start or initialize everything
.\setup.ps1 -Reset   # Remove containers, DB volume and ./wordpress, then rebuild
.\setup.ps1 -Down    # Stop containers (keeps data)
.\setup.ps1 -Pull    # Force image pull
.\setup.ps1 -Logs    # Follow compose logs at the end
.\setup.ps1 -Help    # Show script help
```

### What setup.ps1 does

- Validates Docker and Compose availability.
- Creates `.env` from `.env.example` if needed.
- Optionally pulls images.
- Initializes WordPress files into `./wordpress` if they are missing.
- Starts full stack with bind mount.
- Auto-installs WordPress through WP-CLI using values from `.env`:
  - `WP_SITE_URL`
  - `WP_SITE_TITLE`
  - `WP_ADMIN_USER`
  - `WP_ADMIN_PASSWORD`
  - `WP_ADMIN_EMAIL`
  - `WP_LOCALE`
- Applies locale for existing installs as well.
- Asks before execution if you want to add this to `wp-config.php`:

```php
/* Local development: allow plugin/theme install-delete without FTP */
define('FS_METHOD', 'direct');
```

This allows plugin/theme installation and removal locally without FTP credentials.

### Common workflow

```powershell
# Start/update environment
.\setup.ps1

# Full reset when needed
.\setup.ps1 -Reset

# Stop everything
.\setup.ps1 -Down
```

---