# WordJima

WordPress dockerizado para desarrollo local.

## Espanol

Entorno local de WordPress con Docker Compose.

### Stack

- WordPress: `wordpress:6.9.4-php8.4`
- MySQL: `mysql:8.0`
- URL HTTP: `http://localhost:8080`
- Codigo WordPress montado desde `./wordpress`

### Requisitos

- Docker Desktop (con plugin Docker Compose)
- PowerShell (Windows)

### Inicio rapido

1. Configura los valores de `.env`.
2. Ejecuta:

```powershell
.\setup.ps1
```

3. Abre `http://localhost:8080`.

### Opciones de setup.ps1

```powershell
.\setup.ps1          # Inicia o inicializa todo
.\setup.ps1 -Reset   # Borra contenedores, volumen DB y ./wordpress, luego reconstruye
.\setup.ps1 -Down    # Detiene contenedores (conserva datos)
.\setup.ps1 -Pull    # Fuerza descarga de imagenes
.\setup.ps1 -Logs    # Muestra logs de compose al final
.\setup.ps1 -Help    # Muestra ayuda del script
```

### Que hace setup.ps1

- Valida que Docker y Compose esten disponibles.
- Crea `.env` desde `.env.example` si hace falta.
- Opcionalmente descarga imagenes.
- Inicializa archivos de WordPress en `./wordpress` si no existen.
- Levanta el stack completo con bind mount.
- Instala WordPress automaticamente con WP-CLI usando `.env`:
  - `WP_SITE_URL`
  - `WP_SITE_TITLE`
  - `WP_ADMIN_USER`
  - `WP_ADMIN_PASSWORD`
  - `WP_ADMIN_EMAIL`
  - `WP_LOCALE`
- Aplica el locale tambien cuando el sitio ya estaba instalado.
- Pregunta antes de ejecutar si quieres agregar esto en `wp-config.php`:

```php
/* Local development: allow plugin/theme install-delete without FTP */
define('FS_METHOD', 'direct');
```

Esto permite instalar/eliminar plugins y temas localmente sin credenciales FTP.

### Flujo comun

```powershell
# Levantar/actualizar entorno
.\setup.ps1

# Reset completo cuando sea necesario
.\setup.ps1 -Reset

# Detener todo
.\setup.ps1 -Down
```
