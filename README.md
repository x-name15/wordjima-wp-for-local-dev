# WordJima

Dockerized WordPress for local development.

WordJima is a practical local WordPress environment built with Docker Compose and an automation script for setup, reset, and first-run provisioning.

## Why Jima
## Why WordJima

- Fast local bootstrap for WordPress + MySQL
- Project files mounted locally in [wordpress](wordpress)
- Automated WordPress install via WP-CLI
- Locale support from `.env` (`WP_LOCALE`)
- Optional `FS_METHOD=direct` for local plugin/theme install-delete without FTP

## Stack

- WordPress: `wordpress:6.9.4-php8.4`
- MySQL: `mysql:8.0`
- Compose orchestration via [docker-compose.yml](docker-compose.yml)
- Setup automation via [setup.ps1](setup.ps1)

## Quick Start

1. Configure your environment values in `.env` (or let setup create it from `.env.example`).
2. Run:

```powershell
.\setup.ps1
```

3. Open `http://localhost:8080`.

## setup.ps1 Commands

```powershell
.\setup.ps1          # Start or initialize everything
.\setup.ps1 -Reset   # Remove containers, DB volume and ./wordpress, then rebuild
.\setup.ps1 -Down    # Stop containers (keeps data)
.\setup.ps1 -Pull    # Force image pull
.\setup.ps1 -Logs    # Follow compose logs at the end
.\setup.ps1 -Help    # Show script help
```

## Documentation

- English: [docs/README-EN.md](docs/README-EN.md)
- Espanol: [docs/README-ES.md](docs/README-ES.md)

## Notes

- On each run, setup can ask if you want to add `FS_METHOD=direct` into `wp-config.php`.
- If accepted, WordPress can install/remove plugins and themes locally without FTP credentials.

