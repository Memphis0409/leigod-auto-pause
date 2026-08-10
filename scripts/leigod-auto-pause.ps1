[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Repair', 'Uninstall')]
    [string]$Action = 'Status',
    [string]$InstallPath
)

$ErrorActionPreference = 'Stop'
$Marker = 'leigod-auto-pause:shutdown-native-v2'
$RendererMarker = 'leigod-auto-pause:renderer-core-v2'
$StateRoot = Join-Path $env:LOCALAPPDATA 'LeigodAutoPause'
$BackupRoot = Join-Path $StateRoot 'backups'
$StateFile = Join-Path $StateRoot 'state.json'

function Find-LeigodRoot {
    if ($InstallPath) {
        $resolved = (Resolve-Path -LiteralPath $InstallPath).Path
        if (Test-Path -LiteralPath (Join-Path $resolved 'resources\app.asar')) { return $resolved }
        throw "The supplied InstallPath does not contain resources\app.asar: $resolved"
    }
    $running = Get-CimInstance Win32_Process -Filter "Name='leigod.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath } | Select-Object -First 1
    if ($running) { return Split-Path -Parent $running.ExecutablePath }
    $uninstallKeys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($item in Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue) {
        if ($item.DisplayName -match '雷神|Leigod' -and $item.InstallLocation) {
            if (Test-Path -LiteralPath (Join-Path $item.InstallLocation 'resources\app.asar')) { return $item.InstallLocation }
        }
    }
    foreach ($candidate in @('D:\program\LeiGod_Acc', 'C:\Program Files\LeiGod_Acc', 'C:\Program Files (x86)\LeiGod_Acc')) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'resources\app.asar')) { return $candidate }
    }
    throw 'Could not find the Leigod installation. Pass -InstallPath explicitly.'
}

function Find-Toolchain {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    $pnpm = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
    if (-not $node) {
        $node = Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.cache\codex-runtimes') -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'dependencies\\node\\bin\\node\.exe$' } | Select-Object -First 1
    }
    if (-not $pnpm) {
        $pnpm = Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.cache\codex-runtimes') -Filter pnpm.cmd -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'dependencies\\bin\\fallback\\pnpm\.cmd$' } | Select-Object -First 1
    }
    if (-not $node -or -not $pnpm) { throw 'Node.js and pnpm are required. Run this action from Codex or install Node.js/pnpm.' }
    $nodePath = if ($node.Source) { $node.Source } else { $node.FullName }
    $pnpmPath = if ($pnpm.Source) { $pnpm.Source } else { $pnpm.FullName }
    return @{ Node = $nodePath; Pnpm = $pnpmPath }
}

function Invoke-Asar([hashtable]$Tool, [string[]]$Arguments) {
    & $Tool.Pnpm dlx '@electron/asar' @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "@electron/asar failed with exit code $LASTEXITCODE while running: $($Arguments -join ' ')" }
}

function Read-AsarText([string]$AsarPath, [string]$RelativePath) {
    $tool = Find-Toolchain
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('leigod-auto-pause-read-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $oldPath = $env:Path
    try {
        $env:Path = (Split-Path -Parent $tool.Node) + ';' + $env:Path
        Invoke-Asar $tool @('extract', $AsarPath, $tempRoot)
        $target = Join-Path $tempRoot ($RelativePath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $target)) { throw "Archive entry was not found: $RelativePath" }
        return Get-Content -Raw -LiteralPath $target
    } finally {
        $env:Path = $oldPath
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Test-AsarMarker([string]$AsarPath, [string]$TextMarker) {
    $tool = Find-Toolchain
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('leigod-auto-pause-scan-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $oldPath = $env:Path
    try {
        $env:Path = (Split-Path -Parent $tool.Node) + ';' + $env:Path
        Invoke-Asar $tool @('extract', $AsarPath, $tempRoot)
        $match = Get-ChildItem -LiteralPath $tempRoot -Recurse -File -Filter '*.js' |
            Select-String -SimpleMatch -Pattern $TextMarker -List | Select-Object -First 1
        return ($null -ne $match)
    } finally {
        $env:Path = $oldPath
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Get-State([string]$Root) {
    $asar = Join-Path $Root 'resources\app.asar'
    $rendererAsar = Join-Path $Root 'resources\renderer.asar'
    $mainText = Read-AsarText $asar 'dist/main/main.js'
    $rendererPatched = Test-AsarMarker $rendererAsar $RendererMarker
    $exe = Join-Path $Root 'leigod.exe'
    $version = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } else { $null }
    [ordered]@{
        action = 'Status'; installPath = $Root; version = $version
        mainPatched = $mainText.Contains($Marker)
        rendererPatched = $rendererPatched
        patched = ($mainText.Contains($Marker) -and $rendererPatched)
        running = [bool](Get-Process leigod -ErrorAction SilentlyContinue)
        restartRequired = [bool]((Get-Process leigod -ErrorAction SilentlyContinue) -and $mainText.Contains($Marker))
        logPath = Join-Path $StateRoot 'auto-pause.log'
    }
}

function Install-Patch([string]$Root) {
    $current = Get-State $Root
    if ($current.patched) { return }
    $tool = Find-Toolchain
    $asar = Join-Path $Root 'resources\app.asar'
    $rendererAsar = Join-Path $Root 'resources\renderer.asar'
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $existingState = if (Test-Path -LiteralPath $StateFile) { Get-Content -Raw -LiteralPath $StateFile | ConvertFrom-Json } else { $null }
    $state = [ordered]@{ installPath = $Root; installedAt = (Get-Date).ToString('o') }
    if ($existingState -and $existingState.originalHash) {
        $state.originalHash = $existingState.originalHash
        $state.backupPath = $existingState.backupPath
    }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('leigod-auto-pause-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $oldPath = $env:Path
    try {
        $env:Path = (Split-Path -Parent $tool.Node) + ';' + $env:Path
        if (-not $current.mainPatched) {
            if ($existingState -and $existingState.originalHash -and $existingState.backupPath) {
                $hash = $existingState.originalHash
                $backup = $existingState.backupPath
            } else {
                $hash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash.ToLowerInvariant()
                $backup = Join-Path $BackupRoot ($hash + '.app.asar')
                if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $asar -Destination $backup }
            }
            $extractRoot = Join-Path $tempRoot 'app'
            $packed = Join-Path $tempRoot 'app.asar'
            Invoke-Asar $tool @('extract', $asar, $extractRoot)
            & $tool.Node (Join-Path $PSScriptRoot 'patch-main.js') $extractRoot | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "patch-main.js failed with exit code $LASTEXITCODE" }
            Invoke-Asar $tool @('pack', $extractRoot, $packed, '--unpack-dir', 'node_modules/@leigod-rs/win32-node-addon-win32-ia32-msvc')
            Copy-Item -LiteralPath $packed -Destination $asar -Force
            $state.originalHash = $hash; $state.backupPath = $backup
        }
        if (-not $current.rendererPatched) {
            if ($existingState -and $existingState.rendererOriginalHash -and $existingState.rendererBackupPath) {
                $rendererHash = $existingState.rendererOriginalHash
                $rendererBackup = $existingState.rendererBackupPath
            } else {
                $rendererHash = (Get-FileHash -LiteralPath $rendererAsar -Algorithm SHA256).Hash.ToLowerInvariant()
                $rendererBackup = Join-Path $BackupRoot ($rendererHash + '.renderer.asar')
                if (-not (Test-Path -LiteralPath $rendererBackup)) { Copy-Item -LiteralPath $rendererAsar -Destination $rendererBackup }
            }
            $rendererRoot = Join-Path $tempRoot 'renderer'
            $rendererPacked = Join-Path $tempRoot 'renderer.asar'
            Invoke-Asar $tool @('extract', $rendererAsar, $rendererRoot)
            & $tool.Node (Join-Path $PSScriptRoot 'patch-renderer.js') $rendererRoot | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "patch-renderer.js failed with exit code $LASTEXITCODE" }
            Invoke-Asar $tool @('pack', $rendererRoot, $rendererPacked)
            Copy-Item -LiteralPath $rendererPacked -Destination $rendererAsar -Force
            $state.rendererOriginalHash = $rendererHash; $state.rendererBackupPath = $rendererBackup
        } elseif ($existingState -and $existingState.rendererOriginalHash) {
            $state.rendererOriginalHash = $existingState.rendererOriginalHash
            $state.rendererBackupPath = $existingState.rendererBackupPath
        }
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
        $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } finally {
        $env:Path = $oldPath
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Uninstall-Patch([string]$Root) {
    if (-not (Test-Path -LiteralPath $StateFile)) { throw 'No install state was found; refusing to guess which backup to restore.' }
    $state = Get-Content -Raw -LiteralPath $StateFile | ConvertFrom-Json
    if ($state.installPath -ne $Root) { throw "Install state belongs to a different path: $($state.installPath)" }
    if (-not (Test-Path -LiteralPath $state.backupPath)) { throw "Backup is missing: $($state.backupPath)" }
    $backupHash = (Get-FileHash -LiteralPath $state.backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($backupHash -ne $state.originalHash) { throw 'Backup hash verification failed; no files were changed.' }
    if ($state.rendererBackupPath) {
        if (-not (Test-Path -LiteralPath $state.rendererBackupPath)) { throw "Renderer backup is missing: $($state.rendererBackupPath)" }
        $rendererBackupHash = (Get-FileHash -LiteralPath $state.rendererBackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($rendererBackupHash -ne $state.rendererOriginalHash) { throw 'Renderer backup hash verification failed; no files were changed.' }
    }
    Copy-Item -LiteralPath $state.backupPath -Destination (Join-Path $Root 'resources\app.asar') -Force
    if ($state.rendererBackupPath) {
        Copy-Item -LiteralPath $state.rendererBackupPath -Destination (Join-Path $Root 'resources\renderer.asar') -Force
    }
    Remove-Item -LiteralPath $StateFile -Force
}

$root = Find-LeigodRoot
switch ($Action) {
    'Status' { $result = Get-State $root }
    'Install' { Install-Patch $root; $result = Get-State $root; $result.action = 'Install' }
    'Repair' { Install-Patch $root; $result = Get-State $root; $result.action = 'Repair' }
    'Uninstall' { Uninstall-Patch $root; $result = Get-State $root; $result.action = 'Uninstall' }
}
$result | ConvertTo-Json -Depth 4
