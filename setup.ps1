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
    Write-Host "    -Reset  Remove DB volumes + wordpress folder / Borra volumenes DB + carpeta wordpress" -ForegroundColor Gray
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
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key   = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $map[$key] = $value
    }
    return $map
}

# Resolve a value that may reference another key: e.g. "${DB_HOST}"
function Resolve-EnvValue {
    param([string]$value, [hashtable]$map)
    if ($value -match '^\$\{?(\w+)\}?$') {
        $ref = $matches[1]
        if ($map.ContainsKey($ref)) { return $map[$ref] }
    }
    return $value
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

# ---------------------------------------------------------------------------
# Read docker-compose.yml and extract key values so the script is agnostic
# to service names, image names, container names, ports and networks.
# ---------------------------------------------------------------------------
function Get-ComposeInfo {
    $composeFile = ".\docker-compose.yml"
    if (-not (Test-Path $composeFile)) {
        $composeFile = ".\docker-compose.yaml"
    }
    if (-not (Test-Path $composeFile)) {
        Write-Fail "No se encontro docker-compose.yml en el directorio actual."
    }

    $raw = Get-Content $composeFile -Raw
    $lines = Get-Content $composeFile

    $info = @{
        WpService       = ""
        WpImage         = "wordpress:latest"
        WpContainer     = ""
        WpPort          = "8080"
        DbService       = ""
        DbContainer     = ""
        DbPort          = "3306"
        Network         = ""
    }

    $currentService = ""
    $inServices     = $false
    $inVolumes      = $false
    $inNetworks     = $false
    $serviceIndent  = -1

    foreach ($line in $lines) {
        # Detect top-level sections
        if ($line -match '^services\s*:') { $inServices = $true; $inVolumes = $false; $inNetworks = $false; continue }
        if ($line -match '^volumes\s*:')  { $inVolumes  = $true; $inServices = $false; $inNetworks = $false; continue }
        if ($line -match '^networks\s*:') { $inNetworks = $true; $inServices = $false; $inVolumes  = $false; continue }

        if (-not $inServices) { continue }

        # Detect service name (2-space indent, word chars, colon)
        if ($line -match '^  (\w[\w_-]*)\s*:') {
            $currentService = $matches[1]
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentService)) { continue }

        # image:
        if ($line -match '^\s+image:\s*(.+)$') {
            $img = $matches[1].Trim().Trim('"').Trim("'")
            if ($img -match 'wordpress') {
                $info.WpService = $currentService
                $info.WpImage   = $img
            }
            if ($img -match 'mysql|mariadb|percona|postgres') {
                $info.DbService = $currentService
            }
        }

        # container_name:
        if ($line -match '^\s+container_name:\s*(.+)$') {
            $cn = $matches[1].Trim().Trim('"').Trim("'")
            # assign to whichever service we are currently parsing
            if ($currentService -eq $info.WpService -or
                ($info.WpService -eq "" -and $line -notmatch 'db|mysql|maria|sql')) {
                # tentative — will be overwritten if WpService gets set later
            }
            # We'll do a second pass assignment below after we know which is which
            # Store all container names keyed by service
            if (-not $info.ContainsKey("ContainerNames")) { $info["ContainerNames"] = @{} }
            $info["ContainerNames"][$currentService] = $cn
        }

        # ports: first entry for the service
        if ($line -match '^\s+-\s+"?(\d+):(\d+)"?') {
            $hostPort      = $matches[1]
            $containerPort = $matches[2]
            if ($containerPort -eq "80" -and $info.WpService -eq $currentService) {
                $info.WpPort = $hostPort
            }
            if (($containerPort -eq "3306" -or $containerPort -eq "5432") -and $info.DbService -eq $currentService) {
                $info.DbPort = $hostPort
            }
        }
    }

    # Resolve container names now that we know WpService / DbService
    if ($info.ContainsKey("ContainerNames")) {
        $cn = $info["ContainerNames"]
        if ($cn.ContainsKey($info.WpService)) { $info.WpContainer = $cn[$info.WpService] }
        if ($cn.ContainsKey($info.DbService)) { $info.DbContainer = $cn[$info.DbService] }
    }

    # Fallback container names = service names
    if ([string]::IsNullOrWhiteSpace($info.WpContainer)) { $info.WpContainer = $info.WpService }
    if ([string]::IsNullOrWhiteSpace($info.DbContainer)) { $info.DbContainer = $info.DbService }

    # Detect network: first user-defined network name
    $projectName = Split-Path (Get-Location) -Leaf
    if ($raw -match 'networks:\s*\n\s+(\w[\w_-]+)\s*:') {
        $info.Network = "${projectName}_$($matches[1])"
    } else {
        $info.Network = "${projectName}_default"
    }

    return $info
}

# ---------------------------------------------------------------------------

if ($Help) { Show-Usage; exit 0 }

# --- Verificar Docker -------------------------------------------------------
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

# --- Leer docker-compose.yml ------------------------------------------------
Write-Step "Leyendo docker-compose.yml"
$compose = Get-ComposeInfo

if ([string]::IsNullOrWhiteSpace($compose.WpService)) { Write-Fail "No se encontro un servicio WordPress en docker-compose.yml." }
if ([string]::IsNullOrWhiteSpace($compose.DbService)) { Write-Fail "No se encontro un servicio de base de datos en docker-compose.yml." }

Write-Ok "Servicio WP    : $($compose.WpService)  (imagen: $($compose.WpImage))"
Write-Ok "Contenedor WP  : $($compose.WpContainer)"
Write-Ok "Servicio DB    : $($compose.DbService)"
Write-Ok "Contenedor DB  : $($compose.DbContainer)"
Write-Ok "Puerto WP      : $($compose.WpPort)"
Write-Ok "Red            : $($compose.Network)"

# --- Modo -Down -------------------------------------------------------------
if ($Down) {
    Write-Step "Deteniendo contenedores"
    & docker compose down
    Write-Ok "Contenedores detenidos. (volumenes de datos intactos)"
    exit 0
}

# --- Modo -Reset ------------------------------------------------------------
if ($Reset) {
    Write-Warn "Reset COMPLETO: se borraran los volumenes y ./wp-content/. Continuar? [s/N]"
    $confirm = Read-Host
    if ($confirm -notin @('s','S','y','Y')) { Write-Warn "Cancelado." ; exit 0 }
    Write-Step "Eliminando contenedores, volumenes y carpeta wp-content"
    & docker compose down -v 2>$null
    if (Test-Path ".\wp-content") {
        Remove-Item -Recurse -Force ".\wp-content"
        Write-Ok "Eliminado: .\wp-content"
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

# --- .env -------------------------------------------------------------------
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

# Resolve DB credentials — support both DB_* and WORDPRESS_DB_* conventions
function Get-EnvVal {
    param([string[]]$keys, [string]$default, [hashtable]$map)
    foreach ($k in $keys) {
        if ($map.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($map[$k])) {
            return Resolve-EnvValue $map[$k] $map
        }
    }
    return $default
}

$dbHost = Get-EnvVal @("WORDPRESS_DB_HOST","DB_HOST") "db" $envMap
$dbName = Get-EnvVal @("WORDPRESS_DB_NAME","DB_DATABASE","MARIADB_DATABASE","MYSQL_DATABASE") "wordpress" $envMap
$dbUser = Get-EnvVal @("WORDPRESS_DB_USER","DB_USERNAME","MARIADB_USER","MYSQL_USER") "user" $envMap
$dbPass = Get-EnvVal @("WORDPRESS_DB_PASSWORD","DB_PASSWORD","MARIADB_PASSWORD","MYSQL_PASSWORD") "pass" $envMap

# --- Pull imagenes ----------------------------------------------------------
& docker image inspect $compose.WpImage 2>&1 | Out-Null
if ($Pull -or $LASTEXITCODE -ne 0) {
    Write-Step "Descargando imagenes Docker"
    & docker compose pull
    if ($LASTEXITCODE -ne 0) { Write-Fail "Error al descargar imagenes." }
    Write-Ok "Imagenes descargadas."
} else {
    Write-Ok "Imagenes ya en local. (usa -Pull para forzar actualizacion)"
}

# --- Fase 1: extraer wp-content si no existe --------------------------------
if (-not (Test-Path ".\wp-content")) {
    Write-Step "Fase 1 - Generando wp-content desde la imagen WordPress"
    Write-Info "Arrancando contenedor temporal para extraer wp-content..."

    & docker rm -f wp_init_tmp 2>$null | Out-Null

    # Levantar solo la DB
    Write-Info "Arrancando DB ($($compose.DbService))..."
    & docker compose up -d $compose.DbService
    if ($LASTEXITCODE -ne 0) { Write-Fail "No se pudo arrancar la DB." }

    # Esperar DB por puerto (agnostico a healthcheck)
    Write-Info "Esperando que la DB acepte conexiones en el puerto $($compose.DbPort)..."
    $tries = 0
    $dbReady = $false
    do {
        Start-Sleep -Seconds 5
        $tries++
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", [int]$compose.DbPort)
            $tcp.Close()
            $dbReady = $true
        } catch {
            $dbReady = $false
        }
        Write-Host "   DB puerto $($compose.DbPort) listo: $dbReady ($tries/18)" -ForegroundColor DarkGray
    } while (-not $dbReady -and $tries -lt 18)

    if (-not $dbReady) { Write-Fail "La DB no acepto conexiones despues de 90s." }
    Write-Ok "DB lista."

    # Arrancar WP temporal SIN bind mount
    Write-Info "Arrancando WordPress temporal..."
    & docker run -d `
        --name wp_init_tmp `
        --network $compose.Network `
        --env-file .\.env `
        -e WORDPRESS_DB_HOST=$($compose.DbContainer) `
        -e WORDPRESS_DB_NAME=$dbName `
        -e WORDPRESS_DB_USER=$dbUser `
        -e WORDPRESS_DB_PASSWORD=$dbPass `
        $compose.WpImage

    if ($LASTEXITCODE -ne 0) { Write-Fail "No se pudo arrancar el contenedor temporal de WordPress." }

    # Esperar wp-content
    Write-Info "Esperando que WordPress genere wp-content..."
    $tries = 0
    do {
        Start-Sleep -Seconds 5
        $tries++
        & docker exec wp_init_tmp test -d /var/www/html/wp-content 2>$null
        Write-Host "   Esperando wp-content... ($tries/18)" -ForegroundColor DarkGray
    } while ($LASTEXITCODE -ne 0 -and $tries -lt 18)

    if ($LASTEXITCODE -ne 0) {
        & docker logs wp_init_tmp
        & docker rm -f wp_init_tmp | Out-Null
        Write-Fail "WordPress no genero wp-content."
    }

    # Copiar solo wp-content
    Write-Info "Copiando /var/www/html/wp-content -> ./wp-content/ ..."
    & docker cp wp_init_tmp:/var/www/html/wp-content/. .\wp-content\

    if ($LASTEXITCODE -ne 0) {
        & docker rm -f wp_init_tmp | Out-Null
        Write-Fail "Error al copiar wp-content."
    }

    & docker rm -f wp_init_tmp | Out-Null
    Write-Ok "wp-content copiado correctamente."

    foreach ($f in @("themes","plugins","uploads")) {
        if (Test-Path ".\wp-content\$f") {
            Write-Info "  ok  wp-content\$f"
        } else {
            Write-Warn "  ??  No encontrado: wp-content\$f"
        }
    }
} else {
    Write-Ok "./wp-content/ ya existe, saltando extraccion."
}

if ($addLocalFsMethod) {
    Ensure-LocalFsMethod ".\wp-config.php"
}

# --- Fase 2: levantar stack completo ----------------------------------------
Write-Step "Fase 2 - Levantando stack completo con bind mount"

& docker compose up -d --remove-orphans
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al levantar los contenedores." }

# --- Esperar WordPress -------------------------------------------------------
$wpUrl = "http://localhost:$($compose.WpPort)"
Write-Step "Esperando a que WordPress responda en $wpUrl"
$retries = 0
$maxRetries = 30
$up = $false

do {
    Start-Sleep -Seconds 5
    $retries++
    try {
        $r = Invoke-WebRequest -Uri $wpUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $up = $r.StatusCode -lt 500
    } catch {
        $up = $false
    }
    Write-Host "   Intento $retries / $maxRetries ..." -ForegroundColor DarkGray
} while (-not $up -and $retries -lt $maxRetries)

# --- WP-CLI: instalar WordPress automaticamente -----------------------------
Write-Step "Verificando instalacion automatica de WordPress"

# Detect actual network from running container (more reliable than parsing)
$composeNetwork = (& docker inspect -f "{{range `$k, `$v := .NetworkSettings.Networks}}{{`$k}}{{end}}" $compose.WpContainer 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($composeNetwork)) {
    $composeNetwork = $compose.Network
    Write-Warn "No se pudo detectar la red del contenedor WP, usando: $composeNetwork"
}

$siteUrl       = Get-EnvVal @("WP_SITE_URL")       $wpUrl         $envMap
$siteTitle     = Get-EnvVal @("WP_SITE_TITLE")     "WordJima"     $envMap
$adminUser     = Get-EnvVal @("WP_ADMIN_USER")     "admin"        $envMap
$adminPassword = Get-EnvVal @("WP_ADMIN_PASSWORD") "admin"        $envMap
$adminEmail    = Get-EnvVal @("WP_ADMIN_EMAIL")    "admin@example.com" $envMap
$wpLocale      = Get-EnvVal @("WP_LOCALE")         "en_US"        $envMap

& docker run --rm `
    --network $composeNetwork `
    --volumes-from $compose.WpContainer `
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
        --volumes-from $compose.WpContainer `
        -e WORDPRESS_DB_HOST=$dbHost `
        -e WORDPRESS_DB_NAME=$dbName `
        -e WORDPRESS_DB_USER=$dbUser `
        -e WORDPRESS_DB_PASSWORD=$dbPass `
        wordpress:cli `
        wp core install --allow-root --path=/var/www/html `
            --url="$siteUrl" --title="$siteTitle" `
            --admin_user="$adminUser" --admin_password="$adminPassword" `
            --admin_email="$adminEmail" --skip-email --locale="$wpLocale"

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WordPress instalado automaticamente."
    } else {
        Write-Warn "No se pudo completar wp core install automaticamente."
        Write-Warn "Revisa logs con: docker compose logs $($compose.WpService)"
    }
}

if ($wpLocale -ne "en_US") {
    Write-Info "Aplicando locale: $wpLocale"

    & docker run --rm `
        --network $composeNetwork `
        --volumes-from $compose.WpContainer `
        -e WORDPRESS_DB_HOST=$dbHost `
        -e WORDPRESS_DB_NAME=$dbName `
        -e WORDPRESS_DB_USER=$dbUser `
        -e WORDPRESS_DB_PASSWORD=$dbPass `
        wordpress:cli `
        wp language core install "$wpLocale" --allow-root --path=/var/www/html

    & docker run --rm `
        --network $composeNetwork `
        --volumes-from $compose.WpContainer `
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

# --- Resumen ----------------------------------------------------------------
Write-Host ""
Write-Host "  =================================================" -ForegroundColor DarkGray
if ($up) {
    Write-Host "  WordJima listo!" -ForegroundColor Green
} else {
    Write-Host "  WordJima tarda en responder." -ForegroundColor Yellow
    Write-Host "  Revisa: docker compose logs -f" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  WordJima  ->  $wpUrl" -ForegroundColor White
Write-Host ""
Write-Host "  Codigo WP  ->  .\wp-content\             (edita aqui)" -ForegroundColor Cyan
Write-Host "  Temas      ->  .\wp-content\themes\" -ForegroundColor Cyan
Write-Host "  Plugins    ->  .\wp-content\plugins\" -ForegroundColor Cyan
Write-Host "  Config     ->  .\wp-config.php" -ForegroundColor Cyan
Write-Host "  Base datos ->  volumen Docker (persiste siempre)" -ForegroundColor Cyan
Write-Host "  =================================================" -ForegroundColor DarkGray
Write-Host ""

if ($Logs) {
    Write-Step "Logs en tiempo real (Ctrl+C para salir)"
    & docker compose logs -f
}
