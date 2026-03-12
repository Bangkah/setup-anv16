Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $script:LogFile -Value $line
}

function Ensure-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Jalankan script sebagai Administrator.'
    }
}

function Get-InstalledProgramNames {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        try {
            Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                ForEach-Object { [void]$names.Add($_.DisplayName.ToString()) }
        }
        catch {
            continue
        }
    }

    return $names
}

function Invoke-AutoDownloadDriversFromWindowsUpdate {
    Write-Log 'Auto-download driver: mencoba Windows Update (kategori Drivers).'

    try {
        if (-not (Get-Command Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
            Write-Log 'PSWindowsUpdate belum ada, mencoba install module.'
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name PSWindowsUpdate -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }

        Import-Module PSWindowsUpdate -Force -ErrorAction Stop

        try {
            Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            # Lanjutkan, service mungkin sudah ada.
        }

        $wuResult = Get-WindowsUpdate -MicrosoftUpdate -Category 'Drivers' -AcceptAll -Install -IgnoreReboot -ErrorAction SilentlyContinue
        if ($wuResult) {
            foreach ($item in $wuResult) {
                Add-Content -Path $script:LogFile -Value ("[WU] " + ($item | Out-String).Trim())
            }
            Write-Log 'Windows Update driver selesai diproses.'
        }
        else {
            Write-Log 'Tidak ada driver baru dari Windows Update.'
        }
    }
    catch {
        Write-Log ("Auto-download via Windows Update gagal: " + $_.Exception.Message) 'WARN'
    }
}

function Invoke-InstallAcerCareCenter {
    Write-Log 'Auto-download tambahan: mencoba install Acer Care Center S via winget.'
    try {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Log 'winget tidak tersedia, lewati instalasi Acer Care Center.' 'WARN'
            return
        }

        $args = @(
            'install',
            '--id', '9P8BB54NQNQ4',
            '--source', 'msstore',
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--silent'
        )

        $p = Start-Process -FilePath 'winget' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0) {
            Write-Log 'Acer Care Center S berhasil dipasang atau sudah ada.'
        }
        else {
            Write-Log "Acer Care Center S tidak terpasang (exit code $($p.ExitCode))." 'WARN'
        }
    }
    catch {
        Write-Log ("Gagal install Acer Care Center S: " + $_.Exception.Message) 'WARN'
    }
}

function Export-DriverStoreToFolder {
    param([string]$DriverRoot)

    $dest = Join-Path $DriverRoot '_exported_from_system'
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest | Out-Null
    }

    Write-Log "Export driver store ke: $dest"
    $output = & pnputil /export-driver * $dest 2>&1
    $output | ForEach-Object { Add-Content -Path $script:LogFile -Value $_ }
}

function Expand-DriverArchives {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }

    $zipFiles = Get-ChildItem -Path $Source -Filter '*.zip' -File -Recurse -ErrorAction SilentlyContinue
    foreach ($zip in $zipFiles) {
        $targetDir = Join-Path $Destination ([IO.Path]::GetFileNameWithoutExtension($zip.Name))
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir | Out-Null
        }

        Write-Log "Extract archive: $($zip.FullName)"
        Expand-Archive -Path $zip.FullName -DestinationPath $targetDir -Force
    }
}

function Get-InstallRoots {
    param(
        [string]$DriverDir,
        [string]$CleanDir,
        [string]$ExtractDir
    )

    $roots = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $CleanDir) {
        [void]$roots.Add($CleanDir)
    }

    if (Test-Path -LiteralPath $DriverDir) {
        Get-ChildItem -Path $DriverDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $name = $_.Name.ToLowerInvariant()
                if ($name -in @('_exported_from_system', 'anv16_clean')) { return }
                [void]$roots.Add($_.FullName)
            }
    }

    if (Test-Path -LiteralPath $ExtractDir) {
        [void]$roots.Add($ExtractDir)
    }

    return $roots | Select-Object -Unique
}

function Test-IsSetupCandidate {
    param([string]$Path)

    $p = $Path.ToLowerInvariant()

    # Jangan jalankan binary dari backup/export INF folder.
    if ($p -match '\\_exported_from_system\\') { return $false }
    if ($p -match '\\anv16_clean\\') { return $false }
    if ($p -match '\\.inf_amd64_') { return $false }

    # Hindari executable service/helper yang bukan installer.
    if ($p -match 'service\.exe$|helper\.exe$|host\.exe$') { return $false }

    return $true
}

function Get-SetupRoots {
    param(
        [string]$DriverDir,
        [string]$ExtractDir
    )

    $roots = New-Object System.Collections.Generic.List[string]

    # Setup EXE/MSI hanya dari paket driver user (bukan hasil export store).
    if (Test-Path -LiteralPath $DriverDir) {
        Get-ChildItem -Path $DriverDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $name = $_.Name.ToLowerInvariant()
                if ($name -in @('_exported_from_system', 'anv16_clean')) { return }
                [void]$roots.Add($_.FullName)
            }

        # Juga cek file installer yang ditaruh langsung di root Drivers.
        [void]$roots.Add($DriverDir)
    }

    if (Test-Path -LiteralPath $ExtractDir) {
        [void]$roots.Add($ExtractDir)
    }

    return $roots | Select-Object -Unique
}

function Get-TargetHardwareIds {
    # Prioritaskan perangkat yang error/missing driver, fallback ke perangkat present.
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $problemDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 }

        foreach ($dev in $problemDevices) {
            if ($dev.PNPDeviceID) { [void]$ids.Add($dev.PNPDeviceID) }
            if ($dev.HardwareID) {
                foreach ($hw in $dev.HardwareID) {
                    if ($hw) { [void]$ids.Add($hw) }
                }
            }
        }
    }
    catch {
        # Lanjutkan ke fallback tanpa menghentikan instalasi.
    }

    if ($ids.Count -eq 0) {
        try {
            $allDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
            foreach ($dev in $allDevices) {
                if ($dev.PNPDeviceID) { [void]$ids.Add($dev.PNPDeviceID) }
                if ($dev.HardwareID) {
                    foreach ($hw in $dev.HardwareID) {
                        if ($hw) { [void]$ids.Add($hw) }
                    }
                }
            }
        }
        catch {
            return @()
        }
    }

    return @($ids)
}

function Get-InfPriorityList {
    param(
        [string[]]$Roots,
        [string[]]$HardwareIds
    )

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -Path $root -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$files.Add($_) }
    }

    if ($files.Count -eq 0) { return @() }
    if (-not $HardwareIds -or $HardwareIds.Count -eq 0) {
        return $files | Sort-Object FullName -Unique
    }

    $idTokens = $HardwareIds |
        Where-Object { $_ } |
        ForEach-Object { $_.ToLowerInvariant() } |
        Sort-Object -Unique

    $scored = foreach ($inf in $files) {
        $score = 0
        try {
            $raw = (Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction Stop).ToLowerInvariant()
            foreach ($id in $idTokens) {
                if ($id.Length -ge 8 -and $raw.Contains($id)) {
                    $score++
                }
            }
        }
        catch {
            $score = 0
        }

        [pscustomobject]@{
            File  = $inf
            Score = $score
        }
    }

    return $scored |
        Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.File.FullName } } |
        Select-Object -ExpandProperty File -Unique
}

function Install-InfDrivers {
    param(
        [string[]]$Roots,
        [string[]]$HardwareIds
    )

    $infFiles = Get-InfPriorityList -Roots $Roots -HardwareIds $HardwareIds
    foreach ($inf in $infFiles) {
        Write-Log "Install INF: $($inf.FullName)"
        $output = & pnputil /add-driver $inf.FullName /install 2>&1
        $output | ForEach-Object { Add-Content -Path $script:LogFile -Value $_ }
    }
}

function Get-FileHashSafe {
    param([string]$Path)
    try {
        return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    }
    catch {
        return "$Path|$((Get-Item -LiteralPath $Path).LastWriteTimeUtc.Ticks)"
    }
}

function Test-AlreadyInstalledByRegistry {
    param(
        [string]$InstallerName,
        [string[]]$InstalledNames
    )

    $name = $InstallerName.ToLowerInvariant()

    $rules = @(
        @{ Pattern = 'chipset'; Match = 'chipset|intel.*chipset' },
        @{ Pattern = 'serial'; Match = 'serial\s*i/o|serial io' },
        @{ Pattern = 'me|mgmtengine'; Match = 'management engine|intel.*me' },
        @{ Pattern = 'dptf'; Match = 'dptf|dynamic platform and thermal' },
        @{ Pattern = 'irst'; Match = 'rapid storage|irst' },
        @{ Pattern = 'thunderbolt'; Match = 'thunderbolt' },
        @{ Pattern = 'lan|killer'; Match = 'killer|ethernet|lan' },
        @{ Pattern = 'wifi|wlan|ax201|mt7921'; Match = 'wireless|wi-?fi|wlan|intel.*ax201|mtk|mediatek' },
        @{ Pattern = 'bluetooth'; Match = 'bluetooth|intel wireless bluetooth|mediatek bluetooth' },
        @{ Pattern = 'audio|realtek'; Match = 'realtek.*audio|audio console|purified voice' },
        @{ Pattern = 'touchpad'; Match = 'touchpad|precision touch' },
        @{ Pattern = 'camera|sunplus'; Match = 'camera|sunplus|webcam' },
        @{ Pattern = 'nvidia|vga|graphics'; Match = 'nvidia|intel.*graphics|graphics driver' }
    )

    foreach ($rule in $rules) {
        if ($name -match $rule.Pattern) {
            foreach ($installed in $InstalledNames) {
                if ($installed -match $rule.Match) {
                    return $true
                }
            }
            return $false
        }
    }

    return $false
}

function Invoke-Installer {
    param(
        [string]$Path,
        [hashtable]$State,
        [string[]]$InstalledNames,
        [switch]$AllowInteractive
    )

    $hash = Get-FileHashSafe -Path $Path
    if ($State.ContainsKey($hash) -and $State[$hash] -eq 'success') {
        Write-Log "Skip (sudah pernah sukses): $Path"
        return @{ Success = $true; Skipped = $true }
    }

    $fileName = [IO.Path]::GetFileName($Path)
    if (Test-AlreadyInstalledByRegistry -InstallerName $fileName -InstalledNames $InstalledNames) {
        Write-Log "Skip (terdeteksi sudah terpasang): $Path"
        $State[$hash] = 'success'
        return @{ Success = $true; Skipped = $true }
    }

    Write-Log "Install setup: $Path"

    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.msi') {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $Path, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -in @(0, 1641, 3010)) {
            $State[$hash] = 'success'
            return @{ Success = $true; Skipped = $false }
        }

        Write-Log "MSI exit code: $($p.ExitCode) for $Path" 'WARN'
        return @{ Success = $false; Skipped = $false }
    }

    $silentArgs = @(
        '/S',
        '/s',
        '/silent',
        '/verysilent /norestart',
        '/quiet',
        '-s'
    )

    foreach ($args in $silentArgs) {
        try {
            $p = Start-Process -FilePath $Path -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
            if ($p.ExitCode -in @(0, 1641, 3010)) {
                $State[$hash] = 'success'
                Write-Log "Sukses pakai arg: $args"
                return @{ Success = $true; Skipped = $false }
            }
        }
        catch {
            Write-Log "Gagal jalankan dengan arg [$args]: $($_.Exception.Message)" 'WARN'
        }
    }

    if ($AllowInteractive) {
        Write-Log "Fallback interactive install: $Path"
        $p = Start-Process -FilePath $Path -Wait -PassThru
        if ($p.ExitCode -in @(0, 1641, 3010)) {
            $State[$hash] = 'success'
            return @{ Success = $true; Skipped = $false }
        }

        Write-Log "Interactive installer exit code: $($p.ExitCode)" 'WARN'
    }

    return @{ Success = $false; Skipped = $false }
}

function Get-InstallerPriority {
    param([string]$FileName)

    $name = $FileName.ToLowerInvariant()
    if ($name -match 'chipset') { return 10 }
    if ($name -match 'serial|io') { return 20 }
    if ($name -match 'me|mgmtengine') { return 30 }
    if ($name -match 'dptf') { return 40 }
    if ($name -match 'hid') { return 50 }
    if ($name -match 'thunderbolt') { return 60 }
    if ($name -match 'irst') { return 70 }
    if ($name -match 'lan|killer') { return 80 }
    if ($name -match 'wifi|wlan|ax201|mt7921') { return 90 }
    if ($name -match 'bluetooth') { return 100 }
    if ($name -match 'vga|graphics|nvidia|intel.*gfx') { return 110 }
    if ($name -match 'audio|realtek|console') { return 120 }
    if ($name -match 'camera|sunplus') { return 130 }
    if ($name -match 'touchpad') { return 140 }
    return 999
}

try {
    Ensure-Admin

    $baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $driverDir = Join-Path $baseDir 'Drivers'
    $cleanDir = Join-Path $driverDir 'ANV16_CLEAN'
    $extractDir = Join-Path $baseDir '_extracted'
    $stateFile = Join-Path $baseDir 'install-state.json'
    $script:LogFile = Join-Path $baseDir ('install-log-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if (-not (Test-Path -LiteralPath $driverDir)) {
        throw "Folder driver tidak ditemukan: $driverDir"
    }

    "Driver installer started: $(Get-Date)" | Set-Content -Path $script:LogFile
    Write-Log "Base dir: $baseDir"
    Write-Log "Driver dir: $driverDir"
    if (Test-Path -LiteralPath $cleanDir) {
        Write-Log "Curated dir: $cleanDir"
    }

    Write-Log 'Step 0/6: Auto-download driver via Windows Update.'
    Invoke-AutoDownloadDriversFromWindowsUpdate
    Invoke-InstallAcerCareCenter

    $state = @{}
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $stateText = Get-Content -Path $stateFile -Raw
            if (-not [string]::IsNullOrWhiteSpace($stateText)) {
                $raw = $stateText | ConvertFrom-Json
                if ($raw) {
                    $tmp = @{}
                    foreach ($p in $raw.PSObject.Properties) {
                        $tmp[$p.Name] = [string]$p.Value
                    }
                    $state = $tmp
                }
            }
        }
        catch {
            Write-Log 'State file rusak, membuat state baru.' 'WARN'
            $state = @{}
        }
    }

    Write-Log 'Step 1/6: Extract ZIP jika ada.'
    Expand-DriverArchives -Source $driverDir -Destination $extractDir

    Write-Log 'Step 2/6: Install INF driver (prioritas hardware ID).' 
    $targetHardwareIds = Get-TargetHardwareIds
    Write-Log "Hardware IDs terdeteksi: $($targetHardwareIds.Count)"
    $infRoots = Get-InstallRoots -DriverDir $driverDir -CleanDir $cleanDir -ExtractDir $extractDir
    foreach ($r in $infRoots) { Write-Log "INF root: $r" }
    Install-InfDrivers -Roots $infRoots -HardwareIds $targetHardwareIds

    Write-Log 'Step 3/6: Install EXE/MSI berdasarkan prioritas.'
    $installers = @()
    $setupRoots = Get-SetupRoots -DriverDir $driverDir -ExtractDir $extractDir
    foreach ($r in $setupRoots) { Write-Log "Setup root: $r" }
    foreach ($root in $setupRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $installers += Get-ChildItem -Path $root -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(exe|msi)$' -and (Test-IsSetupCandidate -Path $_.FullName) }
    }

    $installers = $installers |
        Sort-Object @{ Expression = { Get-InstallerPriority -FileName $_.Name } }, @{ Expression = { $_.FullName } } -Unique

    $installedNames = Get-InstalledProgramNames
    $ok = 0
    $skip = 0
    $fail = 0

    foreach ($installer in $installers) {
        $result = Invoke-Installer -Path $installer.FullName -State $state -InstalledNames $installedNames -AllowInteractive
        if ($result.Success -and $result.Skipped) {
            $skip++
        }
        elseif ($result.Success) {
            $ok++
        }
        else {
            $fail++
        }
    }

    Write-Log 'Step 4/6: Simpan state instalasi.'
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding UTF8

    Write-Log 'Step 5/6: Export driver store ke folder Drivers.'
    Export-DriverStoreToFolder -DriverRoot $driverDir

    Write-Log "Ringkasan: sukses=$ok, skip=$skip, gagal=$fail"
    Write-Log "Log file: $script:LogFile"

    if ($fail -gt 0) {
        Write-Log 'Ada installer yang gagal. Cek log untuk detail.' 'WARN'
        exit 2
    }

    Write-Log 'Semua proses selesai. Disarankan restart laptop.'
    exit 0
}
catch {
    $msg = $_.Exception.Message
    if (Get-Variable -Name LogFile -Scope Script -ErrorAction SilentlyContinue) {
        Add-Content -Path $script:LogFile -Value "[ERROR] $msg"
    }
    Write-Host "[ERROR] $msg"
    exit 1
}
