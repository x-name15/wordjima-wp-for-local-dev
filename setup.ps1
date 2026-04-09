param(
    [switch]$Down,
    [switch]$Reset,
    [switch]$Logs,
    [switch]$Pull,
    [switch]$Help
)
 
function Write-Step { param($msg) Write-Host "" ; Write-Host "   $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "   ok  $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "   !!  $msg" -ForegroundColor Yellow }
function Write-Info { param($msg) Write-Host "   ->  $msg" -ForegroundColor DarkGray }
function Write-Fail { param($msg) Write-Host "   ERR $msg" -ForegroundColor Red ; exit 1 }

function Show-Usage {
    Write-Host ""
    Write-Host "  WordJima setup script / Script de instalacion de WordJima" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Usage / Uso:" -ForegroundColor White
    Write-Host "    .\setup.ps1" -ForegroundColor Gray
    Write-Host "    .\setup.ps1 -Reset" -ForegroundColor Gray
    Write-Host "    .\setup.ps1 -Down" -ForegroundColor Gray
    Write-Host "    .\setup.ps1 -Pull" -ForegroundColor Gray
    Write-Host "    .\setup.ps1 -Logs" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Options / Opciones:" -ForegroundColor White
    Write-Host "    -Down   Stop containers without deleting data / Detiene contenedores sin borrar datos" -ForegroundColor Gray
    Write-Host "    -Reset  Remove DB volume + wordpress folder / Borra volumen DB + carpeta wordpress" -ForegroundColor Gray
    Write-Host "    -Pull   Force image pull before startup / Fuerza descarga de imagenes" -ForegroundColor Gray
    Write-Host "    -Logs   Tail compose logs at the end / Sigue logs al final" -ForegroundColor Gray
    Write-Host "    -Help   Show this help / Muestra esta ayuda" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  During execution, the script asks if you want to add FS_METHOD=direct to wp-config.php." -ForegroundColor DarkGray
    Write-Host "  Durante la ejecucion, el script pregunta si quieres agregar FS_METHOD=direct en wp-config.php." -ForegroundColor DarkGray
    Write-Host ""
}

function Get-DotEnvMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path $Path)) {
        return $map
    }

    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $map[$key] = $value
    }

    return $map
}

function Ensure-LocalFsMethod {
    param([string]$WpConfigPath)

    if (-not (Test-Path $WpConfigPath)) {
        Write-Warn "No se encontro wp-config.php para aplicar FS_METHOD."
        return
    }

    $content = Get-Content -Raw $WpConfigPath
    $line = "define('FS_METHOD', 'direct');"

    if ($content.Contains($line)) {
        Write-Ok "FS_METHOD ya existe en wp-config.php"
        return
    }

    $block = @"
/* Local development: allow plugin/theme install-delete without FTP */
define('FS_METHOD', 'direct');
"@

    $pattern = [regex]"/\* That's all, stop editing! Happy publishing\. \*/"
    if ($pattern.IsMatch($content)) {
        $content = $pattern.Replace($content, "$block`r`n`r`n$($pattern.Match($content).Value)", 1)
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n$block`r`n"
    }

    Set-Content -Path $WpConfigPath -Value $content
    Write-Ok "Se agrego FS_METHOD=direct en wp-config.php"
}

if ($Help) {
    Show-Usage
    exit 0
}
 
# --- Verificar Docker --------------------------------------------------------
Write-Step "Verificando dependencias"
 
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail "Docker no esta instalado o no esta en el PATH."
}
Write-Ok "Docker encontrado."
 
& docker compose version 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Docker Compose (plugin) disponible."
} else {
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        Write-Ok "docker-compose standalone disponible."
    } else {
        Write-Fail "docker compose no disponible. Instala Docker Desktop >= 3.4."
    }
}
 
# --- Modo -Down --------------------------------------------------------------
if ($Down) {
    Write-Step "Deteniendo contenedores"
    & docker compose down
    Write-Ok "Contenedores detenidos. (mysql_data sigue intacto en Docker)"
    exit 0
}
 
# --- Modo -Reset -------------------------------------------------------------
if ($Reset) {
    Write-Warn "Reset COMPLETO: se borraran el volumen mysql_data y ./wordpress/. Continuar? [s/N]"
    $confirm = Read-Host
    if ($confirm -notin @('s','S','y','Y')) { Write-Warn "Cancelado." ; exit 0 }
    Write-Step "Eliminando contenedores, volumen mysql_data y carpeta wordpress"
    & docker compose down -v 2>$null
    if (Test-Path ".\wordpress") {
        Remove-Item -Recurse -Force ".\wordpress"
        Write-Ok "Eliminado: .\wordpress"
    }
}

$addLocalFsMethod = $false
Write-Step "Configuracion local de plugins"
Write-Warn "Quieres agregar FS_METHOD=direct en wp-config.php para instalar/eliminar plugins sin FTP? [s/N]"
$fsChoice = Read-Host
if ($fsChoice -in @('s','S','y','Y')) {
    $addLocalFsMethod = $true
    Write-Ok "Se intentara agregar FS_METHOD=direct durante el setup."
} else {
    Write-Info "No se agregara FS_METHOD=direct."
}
 
# --- .env --------------------------------------------------------------------
Write-Step "Configurando .env"
 
if (-not (Test-Path ".\.env")) {
    if (-not (Test-Path ".\.env.example")) {
        Write-Fail ".env.example no encontrado junto al script."
    }
    Copy-Item ".\.env.example" ".\.env"
    Write-Ok ".env creado desde .env.example"
    Write-Warn "Revisa .env si quieres cambiar credenciales. Enter para continuar..."
    Read-Host | Out-Null
} else {
    Write-Ok ".env ya existe."
}

$envMap = Get-DotEnvMap ".\.env"
 
# --- Pull imagenes -----------------------------------------------------------
& docker image inspect wordpress:6.9.4-php8.4 2>&1 | Out-Null
if ($Pull -or $LASTEXITCODE -ne 0) {
    Write-Step "Descargando imagenes Docker"
    & docker compose pull
    if ($LASTEXITCODE -ne 0) { Write-Fail "Error al descargar imagenes." }
    Write-Ok "Imagenes descargadas."
} else {
    Write-Ok "Imagenes ya en local. (usa -Pull para forzar actualizacion)"
}
 
# --- Extraer WP: arrancar sin bind mount, esperar, copiar, parar -------------
if (-not (Test-Path ".\wordpress\wp-login.php")) {
    Write-Step "Fase 1 - Generando archivos WordPress"
    Write-Info "WordPress necesita arrancar una vez para generar su codigo."
    Write-Info "Lo levantamos sin bind mount, copiamos los archivos, y lo paramos."
 
    & docker rm -f wp_init_tmp 2>$null | Out-Null
 
    # Levantar MySQL primero (necesario para que WP no crashee en el init)
    Write-Info "Arrancando MySQL..."
    & docker compose up -d mysql
    if ($LASTEXITCODE -ne 0) { Write-Fail "No se pudo arrancar MySQL." }
 
    # Esperar a que MySQL este healthy
    Write-Info "Esperando MySQL healthy..."
    $tries = 0
    do {
        Start-Sleep -Seconds 5
        $tries++
        $status = & docker inspect --format "{{.State.Health.Status}}" wordpress_db 2>$null
        Write-Host "   MySQL status: $status ($tries/12)" -ForegroundColor DarkGray
    } while ($status -ne "healthy" -and $tries -lt 12)
 
    if ($status -ne "healthy") { Write-Fail "MySQL no arranco correctamente." }
    Write-Ok "MySQL listo."
 
    # Arrancar WP temporal SIN volumen bind mount
    Write-Info "Arrancando WordPress temporal para generar archivos..."
    & docker run -d `
        --name wp_init_tmp `
        --network "$(Split-Path (Get-Location) -Leaf)_wp_network" `
        --env-file .\.env `
        -e WORDPRESS_DB_HOST=wordpress_db `
        -e WORDPRESS_DB_NAME=wordpress `
        -e WORDPRESS_DB_USER=username `
        -e WORDPRESS_DB_PASSWORD=password `
        wordpress:6.9.4-php8.4
 
    if ($LASTEXITCODE -ne 0) { Write-Fail "No se pudo arrancar el contenedor temporal de WordPress." }
 
    # Esperar a que WP genere los archivos en /var/www/html
    Write-Info "Esperando que WordPress genere su codigo..."
    $tries = 0
    do {
        Start-Sleep -Seconds 5
        $tries++
        $check = & docker exec wp_init_tmp test -f /var/www/html/wp-login.php 2>$null
        Write-Host "   Esperando wp-login.php... ($tries/12)" -ForegroundColor DarkGray
    } while ($LASTEXITCODE -ne 0 -and $tries -lt 12)
 
    if ($LASTEXITCODE -ne 0) { 
        & docker rm -f wp_init_tmp | Out-Null
        Write-Fail "WordPress no genero sus archivos. Revisa los logs: docker logs wp_init_tmp"
    }
 
    # Crear carpeta y copiar
    if (-not (Test-Path ".\wordpress")) {
        New-Item -ItemType Directory -Path ".\wordpress" -Force | Out-Null
    }
 
    Write-Info "Copiando /var/www/html -> ./wordpress/ ..."
    & docker cp wp_init_tmp:/var/www/html/. .\wordpress\
 
    if ($LASTEXITCODE -ne 0) {
        & docker rm -f wp_init_tmp | Out-Null
        Write-Fail "Error al copiar archivos."
    }
 
    & docker rm -f wp_init_tmp | Out-Null
    Write-Ok "Archivos de WordPress copiados a ./wordpress/"
 
    foreach ($f in @("wp-login.php","wp-config-sample.php","index.php","wp-admin","wp-content")) {
        if (Test-Path ".\wordpress\$f") {
            Write-Info "  ok  $f"
        } else {
            Write-Warn "  ??  No encontrado: $f"
        }
    }
} else {
    Write-Ok "./wordpress/ ya tiene el core de WP, saltando extraccion."
}

if ($addLocalFsMethod) {
    Ensure-LocalFsMethod ".\wordpress\wp-config.php"
}
 
# --- Fase 2: levantar stack completo con bind mount --------------------------
Write-Step "Fase 2 - Levantando stack completo con bind mount"
 
& docker compose up -d --remove-orphans
 
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al levantar los contenedores." }
 
# --- Esperar WordPress -------------------------------------------------------
Write-Step "Esperando a que WordPress responda en http://localhost:8080"
$retries = 0
$maxRetries = 30
$up = $false
 
do {
    Start-Sleep -Seconds 5
    $retries++
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $up = $r.StatusCode -lt 500
    } catch {
        $up = $false
    }
    Write-Host "   Intento $retries / $maxRetries ..." -ForegroundColor DarkGray
} while (-not $up -and $retries -lt $maxRetries)

# --- Instalar WordPress automaticamente (evita pantalla Welcome) ------------
Write-Step "Verificando instalacion automatica de WordPress"

$projectName = Split-Path (Get-Location) -Leaf
$composeNetwork = (& docker inspect -f "{{range `$k, `$v := .NetworkSettings.Networks}}{{`$k}}{{end}}" wordpress_app 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($composeNetwork)) {
    $composeNetwork = "${projectName}_wp_network"
    Write-Warn "No se pudo detectar la red de wordpress_app, usando fallback: $composeNetwork"
}

$dbHost = if ($envMap.ContainsKey("DB_HOST")) { $envMap["DB_HOST"] } else { "mysql" }
$dbName = if ($envMap.ContainsKey("DB_DATABASE")) { $envMap["DB_DATABASE"] } else { "wordpress" }
$dbUser = if ($envMap.ContainsKey("DB_USERNAME")) { $envMap["DB_USERNAME"] } else { "user" }
$dbPass = if ($envMap.ContainsKey("DB_PASSWORD")) { $envMap["DB_PASSWORD"] } else { "pass" }

$siteUrl = if ($envMap.ContainsKey("WP_SITE_URL")) { $envMap["WP_SITE_URL"] } else { "http://localhost:8080" }
$siteTitle = if ($envMap.ContainsKey("WP_SITE_TITLE")) { $envMap["WP_SITE_TITLE"] } else { "WordJima" }
$adminUser = if ($envMap.ContainsKey("WP_ADMIN_USER")) { $envMap["WP_ADMIN_USER"] } else { "admin" }
$adminPassword = if ($envMap.ContainsKey("WP_ADMIN_PASSWORD")) { $envMap["WP_ADMIN_PASSWORD"] } else { "admin" }
$adminEmail = if ($envMap.ContainsKey("WP_ADMIN_EMAIL")) { $envMap["WP_ADMIN_EMAIL"] } else { "admin@example.com" }
$wpLocale = if ($envMap.ContainsKey("WP_LOCALE") -and -not [string]::IsNullOrWhiteSpace($envMap["WP_LOCALE"])) { $envMap["WP_LOCALE"] } else { "en_US" }

& docker run --rm `
    --network $composeNetwork `
    --volumes-from wordpress_app `
    -e WORDPRESS_DB_HOST=$dbHost `
    -e WORDPRESS_DB_NAME=$dbName `
    -e WORDPRESS_DB_USER=$dbUser `
    -e WORDPRESS_DB_PASSWORD=$dbPass `
    wordpress:cli `
    wp core is-installed --allow-root --path=/var/www/html 2>$null | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Ok "WordPress ya esta instalado en la base de datos."
} else {
    Write-Info "Instalando WordPress con datos de .env ..."
    & docker run --rm `
        --network $composeNetwork `
        --volumes-from wordpress_app `
        -e WORDPRESS_DB_HOST=$dbHost `
        -e WORDPRESS_DB_NAME=$dbName `
        -e WORDPRESS_DB_USER=$dbUser `
        -e WORDPRESS_DB_PASSWORD=$dbPass `
        wordpress:cli `
        wp core install --allow-root --path=/var/www/html --url="$siteUrl" --title="$siteTitle" --admin_user="$adminUser" --admin_password="$adminPassword" --admin_email="$adminEmail" --skip-email --locale="$wpLocale"

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WordPress instalado automaticamente. Ya no deberias ver la pantalla Welcome."
    } else {
        Write-Warn "No se pudo completar wp core install automaticamente."
        Write-Warn "Revisa logs con: docker compose logs wordpress"
    }
}

if ($wpLocale -ne "en_US") {
    Write-Info "Aplicando locale de WordPress: $wpLocale"

    & docker run --rm `
        --network $composeNetwork `
        --volumes-from wordpress_app `
        -e WORDPRESS_DB_HOST=$dbHost `
        -e WORDPRESS_DB_NAME=$dbName `
        -e WORDPRESS_DB_USER=$dbUser `
        -e WORDPRESS_DB_PASSWORD=$dbPass `
        wordpress:cli `
        wp language core install "$wpLocale" --allow-root --path=/var/www/html

    & docker run --rm `
        --network $composeNetwork `
        --volumes-from wordpress_app `
        -e WORDPRESS_DB_HOST=$dbHost `
        -e WORDPRESS_DB_NAME=$dbName `
        -e WORDPRESS_DB_USER=$dbUser `
        -e WORDPRESS_DB_PASSWORD=$dbPass `
        wordpress:cli `
        wp language core activate "$wpLocale" --allow-root --path=/var/www/html

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Locale activo: $wpLocale"
    } else {
        Write-Warn "No se pudo activar locale $wpLocale."
    }
}
 
# --- Resumen -----------------------------------------------------------------
Write-Host ""
Write-Host "  =================================================" -ForegroundColor DarkGray
if ($up) {
    Write-Host "  WordJima listo!" -ForegroundColor Green
} else {
    Write-Host "  WordJima tarda en responder." -ForegroundColor Yellow
    Write-Host "  Revisa: docker compose logs -f" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  WordJima  ->  http://localhost:8080" -ForegroundColor White
Write-Host ""
Write-Host "  Codigo WP  ->  .\wordpress\                (edita aqui)" -ForegroundColor Cyan
Write-Host "  Temas      ->  .\wordpress\wp-content\themes\" -ForegroundColor Cyan
Write-Host "  Plugins    ->  .\wordpress\wp-content\plugins\" -ForegroundColor Cyan
Write-Host "  Base datos ->  volumen Docker 'mysql_data' (persiste siempre)" -ForegroundColor Cyan
Write-Host "  =================================================" -ForegroundColor DarkGray
Write-Host ""
 
if ($Logs) {
    Write-Step "Logs en tiempo real (Ctrl+C para salir)"
    & docker compose logs -f
}