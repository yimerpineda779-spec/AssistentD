<#
  AssistentD | lanzador para Windows
  Uso:  lanzador.ps1 encender | apagar | reiniciar
  Revisa Docker, crea la configuracion la primera vez, levanta los
  servicios y abre el panel solo cuando el motor responde.
#>
param(
    [ValidateSet('encender', 'apagar', 'reiniciar')]
    [string]$Accion = 'encender'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Host.UI.RawUI.WindowTitle = 'AssistentD'

$Raiz      = Split-Path -Parent $PSScriptRoot
$ArchivoEnv = Join-Path $Raiz '.env'
$Registro  = Join-Path $Raiz 'registro'
New-Item -ItemType Directory -Force -Path $Registro | Out-Null
Set-Location $Raiz

$Total = 5

function Titulo {
    Clear-Host
    Write-Host ''
    Write-Host '   ▄▀█ █▀ █▀ █ █▀ ▀█▀ █▀▀ █▄ █ ▀█▀ █▀▄' -ForegroundColor DarkCyan
    Write-Host '   █▀█ ▄█ ▄█ █ ▄█  █  ██▄ █ ▀█  █  █▄▀' -ForegroundColor DarkCyan
    Write-Host '   asistente personal con agenda inteligente' -ForegroundColor DarkGray
    Write-Host ''
}

function Paso([int]$n, [string]$texto) {
    Write-Host ("   [{0}/{1}] " -f $n, $Total) -ForegroundColor DarkCyan -NoNewline
    Write-Host $texto
}
function Bien([string]$texto)  { Write-Host "         listo: $texto" -ForegroundColor Green }
function Nota([string]$texto)  { Write-Host "         $texto" -ForegroundColor DarkGray }

function Detener-Con-Error([string]$texto) {
    Write-Host ''
    Write-Host "   No pude continuar: $texto" -ForegroundColor Red
    Write-Host "   Revisa los archivos de la carpeta 'registro'." -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '   Pulsa Enter para cerrar' | Out-Null
    exit 1
}

function Guardar-Registro([string]$nombre, [string]$comando) {
    $ruta = Join-Path $Registro $nombre
    cmd /c "$comando > `"$ruta`" 2>&1" | Out-Null
}

function Docker-Responde {
    cmd /c 'docker info >nul 2>&1'
    return ($LASTEXITCODE -eq 0)
}

function Secreto {
    $b = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return -join ($b | ForEach-Object { $_.ToString('x2') })
}

function Leer-Valor([string]$clave, [string]$defecto) {
    if (Test-Path $ArchivoEnv) {
        $linea = Get-Content $ArchivoEnv | Where-Object { $_ -match "^\s*$clave\s*=" } | Select-Object -First 1
        if ($linea) { return ($linea -split '=', 2)[1].Trim() }
    }
    return $defecto
}

function Abrir-Panel([string]$url) {
    # AssistentD usa su propio perfil de navegador. Asi Windows lo trata como un
    # programa aparte: tiene su propio boton e icono en la barra de tareas y no
    # comparte cookies, permisos ni datos con otras ventanas de Edge o Chrome.
    $perfil = Join-Path $env:LOCALAPPDATA 'AssistentD\ventana'
    New-Item -ItemType Directory -Force -Path $perfil | Out-Null
    $navegador = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($navegador) {
        Start-Process -FilePath $navegador -ArgumentList @(
            "--app=$url",
            "--user-data-dir=`"$perfil`"",
            '--window-size=1360,860',
            '--no-first-run',
            '--no-default-browser-check'
        )
    } else {
        Start-Process $url
    }
}

function Crear-Acceso-Directo {
    try {
        $escritorio = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $escritorio 'AssistentD.lnk'
        if (Test-Path $lnk) { return }
        $ws = New-Object -ComObject WScript.Shell
        $a = $ws.CreateShortcut($lnk)
        $a.TargetPath = Join-Path $Raiz 'Encender AssistentD.cmd'
        $a.WorkingDirectory = $Raiz
        $a.IconLocation = (Join-Path $PSScriptRoot 'assistentd.ico') + ',0'
        $a.Description = 'Encender AssistentD'
        $a.Save()
        Nota 'Acceso directo "AssistentD" creado en el escritorio.'
    } catch { }
}

# ---------------------------------------------------------------- apagar
if ($Accion -eq 'apagar') {
    Titulo
    $Total = 1
    Paso 1 'Apagando AssistentD (tu agenda queda guardada)...'
    if (-not (Docker-Responde)) { Nota 'Docker ya estaba apagado.'; Start-Sleep 3; exit 0 }
    cmd /c 'docker compose down'
    Bien 'AssistentD apagado.'
    Start-Sleep 3
    exit 0
}

# ---------------------------------------------------------------- encender
Titulo

Paso 1 'Buscando Docker...'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Start-Process 'https://www.docker.com/products/docker-desktop/'
    Detener-Con-Error 'Docker Desktop no está instalado. Te abrí la página para descargarlo; instálalo, reinicia y vuelve a abrir AssistentD.'
}
Bien 'Docker instalado.'

Paso 2 'Revisando que Docker esté encendido...'
if (-not (Docker-Responde)) {
    $exe = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) { Nota 'Abriendo Docker Desktop...'; Start-Process $exe }
    $limite = (Get-Date).AddMinutes(4)
    Write-Host '         esperando' -NoNewline -ForegroundColor DarkGray
    while (-not (Docker-Responde)) {
        if ((Get-Date) -gt $limite) { Write-Host ''; Detener-Con-Error 'Docker no terminó de encender. Ábrelo a mano, espera a que diga "Engine running" y vuelve a intentar.' }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
    Write-Host ''
}
Bien 'Docker encendido.'

Paso 3 'Preparando la configuración...'
if (-not (Test-Path $ArchivoEnv)) {
    $contenido = @(
        '# AssistentD | configuracion local (se creo sola, no la compartas)',
        "CLAVE_BASE=$(Secreto)",
        "CLAVE_MOTOR=$(Secreto)",
        'ZONA=America/Caracas',
        'PUERTO_PANEL=7340',
        'PUERTO_MOTOR=5690'
    ) -join "`n"
    [System.IO.File]::WriteAllText($ArchivoEnv, $contenido + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Nota 'Primera vez: se generaron claves internas nuevas.'
}
$PuertoPanel = Leer-Valor 'PUERTO_PANEL' '7340'
$PuertoMotor = Leer-Valor 'PUERTO_MOTOR' '5690'
Bien 'Configuración lista.'

Paso 4 'Encendiendo los servicios...'
cmd /c 'docker image inspect n8nio/n8n:2.45.7 >nul 2>&1'
if ($LASTEXITCODE -ne 0) { Nota 'La primera vez descarga cerca de 700 MB. Puede tardar unos minutos.' }
Write-Host ''
if ($Accion -eq 'reiniciar') { cmd /c 'docker compose down' }
cmd /c 'docker compose up -d --remove-orphans'
$codigo = $LASTEXITCODE
Write-Host ''
if ($codigo -ne 0) {
    Guardar-Registro 'servicios.log' 'docker compose logs --no-color --tail 300'
    Detener-Con-Error 'Docker no pudo levantar los servicios.'
}
Bien 'Servicios encendidos.'

Paso 5 'Esperando a que AssistentD responda...'
$url = "http://localhost:$PuertoPanel"
$limite = (Get-Date).AddMinutes(3)
$listo = $false
while ((Get-Date) -lt $limite) {
    try {
        $r = Invoke-WebRequest -Uri "$url/api/salud" -UseBasicParsing -TimeoutSec 4
        if ($r.StatusCode -eq 200) { $listo = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $listo) {
    Guardar-Registro 'servicios.log' 'docker compose logs --no-color --tail 300'
    Guardar-Registro 'estado.log' 'docker compose ps -a'
    Detener-Con-Error 'El motor no respondió a tiempo.'
}
Bien 'AssistentD está en línea.'

Crear-Acceso-Directo
Abrir-Panel $url

Write-Host ''
Write-Host "   Panel:          $url" -ForegroundColor White
Write-Host "   Editor de n8n:  http://localhost:$PuertoMotor" -ForegroundColor DarkGray
Write-Host ''
Write-Host '   AssistentD sigue funcionando aunque cierres esta ventana.' -ForegroundColor DarkGray
Write-Host '   Para apagarlo usa "Apagar AssistentD".' -ForegroundColor DarkGray
Write-Host ''
for ($i = 15; $i -gt 0; $i--) {
    Write-Host "`r   Esta ventana se cierra en $i s " -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
