Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Configuration ---
$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

$Config = @{
    SingPath         = Join-Path $BaseDir 'core\sing-box.exe'
    SingConfigDir    = Join-Path $BaseDir 'config' # Directory for config files
    LogDir           = Join-Path $BaseDir 'logs'
    MaxLogSize       = 5MB   # Maximum size per log file before rotation
    MaxLogFiles      = 5     # Keep this many rotated log files
    LogRotationCheck = 60000 # Check for rotation every 60 seconds
}

$FoldersToEnsure = @(
    (Join-Path $BaseDir 'core'),
    $Config.SingConfigDir,
    $Config.LogDir
)

foreach ($folder in $FoldersToEnsure) {
    if (-not (Test-Path -Path $folder -PathType Container)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
}

$SingLog = Join-Path $Config.LogDir 'sing-box.log'
$AppLog = Join-Path $Config.LogDir 'controller.log'

function Write-AppLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    try {
        Add-Content -Path $AppLog -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }

    try {
        if ($Level -eq 'ERROR') {
            [System.Diagnostics.Debug]::WriteLine($logEntry)
        }
        else {
            [System.Diagnostics.Debug]::WriteLine($logEntry)
        }
    }
    catch { }
}

function Invoke-LogRotation {
    param([string]$LogPath)

    if (-not (Test-Path $LogPath)) { return }

    try {
        $logInfo = Get-Item $LogPath
        if ($logInfo.Length -gt $Config.MaxLogSize) {
            Write-AppLog "Rotating log file: $LogPath (Size: $([math]::Round($logInfo.Length / 1MB, 2))MB)" -Level 'INFO'

            $oldestLog = "$LogPath.$($Config.MaxLogFiles)"
            if (Test-Path $oldestLog) {
                Remove-Item $oldestLog -Force -ErrorAction SilentlyContinue
            }

            for ($i = $Config.MaxLogFiles - 1; $i -ge 1; $i--) {
                $currentLog = "$LogPath.$i"
                $nextLog = "$LogPath.$($i + 1)"
                if (Test-Path $currentLog) {
                    Move-Item $currentLog $nextLog -Force -ErrorAction SilentlyContinue
                }
            }

            Move-Item $LogPath "$LogPath.1" -Force -ErrorAction SilentlyContinue
            Write-AppLog "Log rotation completed for: $LogPath" -Level 'INFO'
        }
    }
    catch {
        Write-AppLog "Failed to rotate log $LogPath`: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Test-IsElevated {
    try {
        $currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-AppLog "Failed to check elevation status: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

function Start-Elevated {
    if (-not (Test-IsElevated)) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "powershell.exe"
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            $psi.Verb = "runas"
            $psi.WindowStyle = "Hidden"
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            exit
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to start as administrator: $($_.Exception.Message)",
                "Elevation Error",
                "OK",
                "Error"
            )
            exit
        }
    }
}

Start-Elevated

function Test-FileExists {
    param([string]$Path, [string]$Description)

    if (-not (Test-Path $Path)) {
        $message = "$Description not found at: $Path"
        Write-AppLog $message -Level 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($message, "File Not Found", "OK", "Error")
        return $false
    }
    return $true
}

function Start-VpnProcess {
    param(
        [string]$ExePath,
        [string]$Arguments,
        [string]$LogFile,
        [string]$ProcessName
    )

    if (-not (Test-FileExists $ExePath "$ProcessName executable")) {
        return $false
    }

    try {
        Write-AppLog "Starting $ProcessName with arguments: $Arguments" -Level 'INFO'

        Invoke-LogRotation $LogFile

        $cmdArgs = "/c `"$ExePath $Arguments > `"$LogFile`" 2>&1`""
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -WindowStyle Hidden -WorkingDirectory (Split-Path $ExePath) -PassThru

        Start-Sleep -Milliseconds 500
        if ($process.HasExited) {
            Write-AppLog "$ProcessName process exited immediately. Check configuration." -Level 'ERROR'
            return $false
        }

        Write-AppLog "$ProcessName started successfully (PID: $($process.Id))" -Level 'INFO'
        return $true
    }
    catch {
        Write-AppLog "Error starting $ProcessName`: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

function Send-CtrlC {
    param([int]$ProcessId)

    $signature = @"
using System;
using System.Runtime.InteropServices;

public static class ConsoleManager {
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AttachConsole(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
}
"@

    try {
        Add-Type $signature -ErrorAction SilentlyContinue
    }
    catch {
        # Type might already be loaded. We can ignore this specific error.
    }

    [ConsoleManager]::FreeConsole() | Out-Null

    if (-not [ConsoleManager]::AttachConsole($ProcessId)) {
        $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-AppLog "Failed to attach to console of PID $ProcessId. Win32 Error Code: $errorCode." -Level 'WARNING'
        return $false
    }

    try {
        if (-not [ConsoleManager]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-AppLog "Failed to set console control handler for PID $ProcessId. Win32 Error Code: $errorCode." -Level 'WARNING'
            return $false
        }

        if (-not [ConsoleManager]::GenerateConsoleCtrlEvent(0, 0)) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-AppLog "Failed to generate CTRL+C event for PID $ProcessId. Win32 Error Code: $errorCode." -Level 'WARNING'
            return $false
        }

        Start-Sleep -Milliseconds 500

        return $true
    }
    finally {
        [ConsoleManager]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
        [ConsoleManager]::FreeConsole() | Out-Null
    }
}

function Stop-ProcessByName {
    param([string]$ProcessName)

    $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($processes) {
        Write-AppLog "Stopping $($processes.Count) instance(s) of $ProcessName" -Level 'INFO'

        foreach ($proc in $processes) {
            try {
                Write-AppLog "Attempting graceful shutdown of $ProcessName (PID: $($proc.Id))" -Level 'INFO'

                if (Send-CtrlC $proc.Id) {
                    if (-not $proc.WaitForExit(10000)) {
                        Write-AppLog "Graceful shutdown failed, force killing $ProcessName (PID: $($proc.Id))" -Level 'WARNING'
                        $proc.Kill()
                        $proc.WaitForExit(2000)
                    }
                    else {
                        Write-AppLog "$ProcessName (PID: $($proc.Id)) stopped gracefully" -Level 'INFO'
                    }
                }
                else {
                    Write-AppLog "CTRL+C failed, force killing $ProcessName (PID: $($proc.Id))" -Level 'WARNING'
                    $proc.Kill()
                    $proc.WaitForExit(2000)
                }
            }
            catch {
                Write-AppLog "Error stopping $ProcessName (PID: $($proc.Id)): $($_.Exception.Message)" -Level 'ERROR'
            }
        }
        return $true
    }
    return $false
}

function Test-ProcessRunning {
    param([string]$ProcessName)
    return $null -ne (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
}

function Update-Singbox {
    Write-AppLog "Starting sing-box update..." -Level 'INFO'

    $wasRunning = Test-ProcessRunning "sing-box"
    if ($wasRunning) {
        Write-AppLog "Stopping sing-box service for update..." -Level 'INFO'
        Stop-ProcessByName "sing-box"
        Start-Sleep -Seconds 2
    }

    try {
        Write-AppLog "Fetching latest sing-box release from GitHub API..." -Level 'INFO'
        [System.Windows.Forms.MessageBox]::Show("Downloading sing-box update. The UI may become unresponsive.", "Update in Progress", "OK", "Information")

        $apiUrl = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl

        $asset = $release.assets | Where-Object { $_.name -like '*-windows-amd64.zip' }
        if (-not $asset) {
            throw "Could not find a suitable Windows AMD64 release asset."
        }
        $downloadUrl = $asset.browser_download_url
        $zipFileName = $asset.name
        $zipPath = Join-Path $env:TEMP $zipFileName
        $extractPath = Split-Path $Config.SingPath

        Write-AppLog "Downloading sing-box from $downloadUrl" -Level 'INFO'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath

        Write-AppLog "Download complete. Extracting to a temporary directory first..." -Level 'INFO'

        $tempExtract = Join-Path $env:TEMP "singbox_temp"
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force

        $subDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
        if (-not $subDir) {
            throw "Could not find the extracted content subdirectory."
        }

        Write-AppLog "Moving files from $($subDir.FullName) to $extractPath" -Level 'INFO'
        Get-ChildItem -Path $subDir.FullName | Move-Item -Destination $extractPath -Force

        Remove-Item $zipPath -Force
        Remove-Item $tempExtract -Recurse -Force

        Write-AppLog "sing-box update successful." -Level 'INFO'
        [System.Windows.Forms.MessageBox]::Show("sing-box core has been updated successfully!", "Update Complete", "OK", "Information")
    }
    catch {
        $errorMessage = "Failed to update sing-box: $($_.Exception.Message)"
        Write-AppLog $errorMessage -Level 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Update Error", "OK", "Error")
    }
    finally {
        if ($wasRunning) {
            Write-AppLog "Restarting sing-box service after update..." -Level 'INFO'
            Start-Service
        }
    }
}

function Get-RemoteConfig {
    $url = $Global:ConfigUrlInput.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a valid URL.", "Input Error", "OK", "Warning")
        return
    }

    Write-AppLog "Starting remote config download from: $url" -Level 'INFO'
    [System.Windows.Forms.MessageBox]::Show("Downloading configuration. The UI may become unresponsive.", "Download in Progress", "OK", "Information")

    try {
        $headers = @{ "User-Agent" = "SFA" }
        $response = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing
        $jsonContent = $response.Content

        if ([string]::IsNullOrWhiteSpace($jsonContent)) {
            throw "Downloaded content is empty."
        }

        $configObject = $jsonContent | ConvertFrom-Json -ErrorAction Stop

        if (-not $configObject.PSObject.Properties['experimental']) {
            $configObject | Add-Member -MemberType NoteProperty -Name 'experimental' -Value (New-Object -TypeName PSCustomObject)
        }

        $clashApi = [PSCustomObject]@{
            external_controller      = "127.0.0.1:9090"
            external_ui              = "ui"
            external_ui_download_url = "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
            external_ui_download_detour = "direct"
        }
        $configObject.experimental | Add-Member -MemberType NoteProperty -Name 'clash_api' -Value $clashApi -Force

        $modifiedJson = $configObject | ConvertTo-Json -Depth 100

        $uri = New-Object System.Uri($url)
        $fileName = "remote_$($uri.Host).json"
        $newConfigPath = Join-Path $Config.SingConfigDir $fileName

        [System.IO.File]::WriteAllText($newConfigPath, $modifiedJson, (New-Object System.Text.UTF8Encoding($false)))

        Write-AppLog "Validating new config file: $newConfigPath" -Level 'INFO'
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $Config.SingPath
        $processInfo.Arguments = "check -c `"$newConfigPath`""
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($processInfo)
        $process.WaitForExit()
        $errorOutput = $process.StandardError.ReadToEnd().Trim()

        if ($process.ExitCode -eq 0) {
            Write-AppLog "Config validation successful for $fileName" -Level 'INFO'

            Write-AppLog "Formatting config file: $newConfigPath" -Level 'INFO'
            $fmtInfo = New-Object System.Diagnostics.ProcessStartInfo
            $fmtInfo.FileName = $Config.SingPath
            $fmtInfo.Arguments = "format -wc `"$newConfigPath`""
            $fmtInfo.UseShellExecute = $false
            $fmtInfo.CreateNoWindow = $true
            [System.Diagnostics.Process]::Start($fmtInfo).WaitForExit()

            [System.Windows.Forms.MessageBox]::Show("Configuration downloaded, modified, and saved successfully as '$fileName'.", "Success", "OK", "Information")
            Update-ConfigFileList
            $Global:ConfigSelector.SelectedItem = $fileName
        } else {
            $validationError = "Config validation failed for '$fileName'. The file will be removed.`n`nError: $errorOutput"
            Write-AppLog $validationError -Level 'ERROR'
            Remove-Item -Path $newConfigPath -Force -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show($validationError, "Validation Error", "OK", "Error")
        }
    }
    catch {
        $errorMessage = "Failed to get remote configuration: $($_.Exception.Message)"
        Write-AppLog $errorMessage -Level 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", "OK", "Error")
    }
}

$Global:NotifyIcon = $null
$Global:MainForm = $null
$Global:LogForm = $null
$Global:LogTextBox = $null
$Global:SingStatusLabel = $null
$Global:ConfigSelector = $null
$Global:ConfigUrlInput = $null
$Global:LogPreview = $null
$Global:StatusTimer = $null
$Global:LogTimer = $null
$Global:LogRotationTimer = $null

function Update-ConfigFileList {
    try {
        if (-not $Global:ConfigSelector) { return }

        $selectedItem = $Global:ConfigSelector.SelectedItem

        $Global:ConfigSelector.Items.Clear()
        $configFiles = Get-ChildItem -Path $Config.SingConfigDir -Filter "*.json" | ForEach-Object { $_.Name }

        if ($configFiles) {
            $Global:ConfigSelector.Items.AddRange($configFiles)

            if ($selectedItem -and $Global:ConfigSelector.Items.Contains($selectedItem)) {
                $Global:ConfigSelector.SelectedItem = $selectedItem
            } else {
                $Global:ConfigSelector.SelectedIndex = 0
            }
            $Global:ConfigSelector.Enabled = $true
        } else {
            $Global:ConfigSelector.Items.Add("No config files found")
            $Global:ConfigSelector.SelectedIndex = 0
            $Global:ConfigSelector.Enabled = $false
        }
    } catch {
        Write-AppLog "Could not refresh config file list: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Initialize-TrayIcon {
    try {
        $Global:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon

        $bitmap = New-Object System.Drawing.Bitmap(16, 16)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.FillEllipse([System.Drawing.Brushes]::DodgerBlue, 2, 2, 12, 12)
        $graphics.Dispose()

        $Global:NotifyIcon.Icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        $Global:NotifyIcon.Text = "sing-box Controller"
        $Global:NotifyIcon.Visible = $true

        $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

        $showItem = New-Object System.Windows.Forms.ToolStripMenuItem("Show Control Panel")
        $showItem.add_Click({ Show-MainForm })

        $startItem = New-Object System.Windows.Forms.ToolStripMenuItem("Start Service")
        $startItem.add_Click({ Start-Service })

        $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem("Stop Service")
        $stopItem.add_Click({ Stop-Service })

        $logsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Show Logs")
        $logsItem.add_Click({ Show-LogWindow })

        $rotateLogsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Rotate Logs Now")
        $rotateLogsItem.add_Click({
                Invoke-LogRotation $SingLog
                Invoke-LogRotation $AppLog
                $Global:NotifyIcon.ShowBalloonTip(2000, "sing-box Controller", "Log rotation completed", [System.Windows.Forms.ToolTipIcon]::Info)
            })

        $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
        $exitItem.add_Click({ Exit-Application })

        $contextMenu.Items.AddRange(@(
                $showItem,
                (New-Object System.Windows.Forms.ToolStripSeparator),
                $startItem,
                $stopItem,
                (New-Object System.Windows.Forms.ToolStripSeparator),
                $logsItem,
                $rotateLogsItem,
                (New-Object System.Windows.Forms.ToolStripSeparator),
                $exitItem
            ))
        $Global:NotifyIcon.ContextMenuStrip = $contextMenu

        $Global:NotifyIcon.add_DoubleClick({ Show-MainForm })

        $Global:NotifyIcon.ShowBalloonTip(3000, "sing-box Controller", "Controller is running in system tray", [System.Windows.Forms.ToolTipIcon]::Info)

        Write-AppLog "System tray icon initialized successfully" -Level 'INFO'
    }
    catch {
        Write-AppLog "Failed to initialize tray icon: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Initialize-MainForm {
    try {
        $Global:MainForm = New-Object System.Windows.Forms.Form
        $Global:MainForm.Text = "sing-box Controller v1.0"
        $Global:MainForm.Size = New-Object System.Drawing.Size(500, 610)
        $Global:MainForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $Global:MainForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
        $Global:MainForm.MaximizeBox = $false
        $Global:MainForm.ShowInTaskbar = $false

        $statusPanel = New-Object System.Windows.Forms.Panel
        $statusPanel.Dock = [System.Windows.Forms.DockStyle]::Top
        $statusPanel.Height = 150
        $statusPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        $statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

        $configLabel = New-Object System.Windows.Forms.Label
        $configLabel.Text = "Configuration:"
        $configLabel.Location = New-Object System.Drawing.Point(20, 20)
        $configLabel.Size = New-Object System.Drawing.Size(100, 20)
        $configLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $Global:ConfigSelector = New-Object System.Windows.Forms.ComboBox
        $Global:ConfigSelector.Location = New-Object System.Drawing.Point(130, 20)
        $Global:ConfigSelector.Size = New-Object System.Drawing.Size(340, 25)
        $Global:ConfigSelector.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $Global:ConfigSelector.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        Update-ConfigFileList

        $singLabel = New-Object System.Windows.Forms.Label
        $singLabel.Text = "sing-Box Status:"
        $singLabel.Location = New-Object System.Drawing.Point(20, 50)
        $singLabel.Size = New-Object System.Drawing.Size(100, 20)
        $singLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $Global:SingStatusLabel = New-Object System.Windows.Forms.Label
        $Global:SingStatusLabel.Text = "Stopped"
        $Global:SingStatusLabel.Location = New-Object System.Drawing.Point(130, 50)
        $Global:SingStatusLabel.Size = New-Object System.Drawing.Size(200, 20)
        $Global:SingStatusLabel.ForeColor = [System.Drawing.Color]::Red
        $Global:SingStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $logDirLabel = New-Object System.Windows.Forms.Label
        $logDirLabel.Text = "Log Directory:"
        $logDirLabel.Location = New-Object System.Drawing.Point(20, 80)
        $logDirLabel.Size = New-Object System.Drawing.Size(100, 20)
        $logDirLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $logDirPath = New-Object System.Windows.Forms.Label
        $logDirPath.Text = $Config.LogDir
        $logDirPath.Location = New-Object System.Drawing.Point(130, 80)
        $logDirPath.Size = New-Object System.Drawing.Size(340, 20)
        $logDirPath.Font = New-Object System.Drawing.Font("Segoe UI", 8)
        $logDirPath.ForeColor = [System.Drawing.Color]::Blue
        $logDirPath.Cursor = [System.Windows.Forms.Cursors]::Hand
        $logDirPath.add_Click({
                try {
                    Start-Process "explorer.exe" -ArgumentList $Config.LogDir
                }
                catch {
                    Write-AppLog "Failed to open log directory: $($_.Exception.Message)" -Level 'WARNING'
                }
            })

        $maxLogLabel = New-Object System.Windows.Forms.Label
        $maxLogLabel.Text = "Max Log Size:"
        $maxLogLabel.Location = New-Object System.Drawing.Point(20, 110)
        $maxLogLabel.Size = New-Object System.Drawing.Size(100, 20)
        $maxLogLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $maxLogSize = New-Object System.Windows.Forms.Label
        $maxLogSize.Text = "$([math]::Round($Config.MaxLogSize / 1MB, 1))MB (Keeping $($Config.MaxLogFiles) rotated files)"
        $maxLogSize.Location = New-Object System.Drawing.Point(130, 110)
        $maxLogSize.Size = New-Object System.Drawing.Size(300, 20)
        $maxLogSize.Font = New-Object System.Drawing.Font("Segoe UI", 8)

        $statusPanel.Controls.AddRange(@($configLabel, $Global:ConfigSelector, $singLabel, $Global:SingStatusLabel, $logDirLabel, $logDirPath, $maxLogLabel, $maxLogSize))

        $buttonPanel = New-Object System.Windows.Forms.Panel
        $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
        $buttonPanel.Height = 60

        $startBtn = New-Object System.Windows.Forms.Button
        $startBtn.Text = "Start Service"
        $startBtn.Location = New-Object System.Drawing.Point(20, 15)
        $startBtn.Size = New-Object System.Drawing.Size(100, 30)
        $startBtn.BackColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
        $startBtn.ForeColor = [System.Drawing.Color]::White
        $startBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $startBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $startBtn.add_Click({ Start-Service })

        $stopBtn = New-Object System.Windows.Forms.Button
        $stopBtn.Text = "Stop Service"
        $stopBtn.Location = New-Object System.Drawing.Point(140, 15)
        $stopBtn.Size = New-Object System.Drawing.Size(100, 30)
        $stopBtn.BackColor = [System.Drawing.Color]::FromArgb(244, 67, 54)
        $stopBtn.ForeColor = [System.Drawing.Color]::White
        $stopBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $stopBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $stopBtn.add_Click({ Stop-Service })

        $logsBtn = New-Object System.Windows.Forms.Button
        $logsBtn.Text = "Show Logs"
        $logsBtn.Location = New-Object System.Drawing.Point(260, 15)
        $logsBtn.Size = New-Object System.Drawing.Size(100, 30)
        $logsBtn.BackColor = [System.Drawing.Color]::FromArgb(33, 150, 243)
        $logsBtn.ForeColor = [System.Drawing.Color]::White
        $logsBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $logsBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $logsBtn.add_Click({ Show-LogWindow })

        $rotateBtn = New-Object System.Windows.Forms.Button
        $rotateBtn.Text = "Rotate Logs"
        $rotateBtn.Location = New-Object System.Drawing.Point(380, 15)
        $rotateBtn.Size = New-Object System.Drawing.Size(100, 30)
        $rotateBtn.BackColor = [System.Drawing.Color]::FromArgb(156, 39, 176)
        $rotateBtn.ForeColor = [System.Drawing.Color]::White
        $rotateBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $rotateBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $rotateBtn.add_Click({
                Invoke-LogRotation $SingLog
                Invoke-LogRotation $AppLog
                [System.Windows.Forms.MessageBox]::Show("Log rotation completed successfully!", "sing-box Controller", "OK", "Information")
                Update-LogPreview
            })

        $buttonPanel.Controls.AddRange(@($startBtn, $stopBtn, $logsBtn, $rotateBtn))

        $updateGroup = New-Object System.Windows.Forms.GroupBox
        $updateGroup.Text = "Core Update"
        $updateGroup.Dock = [System.Windows.Forms.DockStyle]::Top
        $updateGroup.Height = 80
        $updateGroup.Padding = New-Object System.Windows.Forms.Padding(15)

        $updateSingBtn = New-Object System.Windows.Forms.Button
        $updateSingBtn.Text = "Update sing-box Core"
        $updateSingBtn.Location = New-Object System.Drawing.Point(20, 30)
        $updateSingBtn.Size = New-Object System.Drawing.Size(440, 35)
        $updateSingBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 150, 136)
        $updateSingBtn.ForeColor = [System.Drawing.Color]::White
        $updateSingBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $updateSingBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $updateSingBtn.add_Click({ Update-Singbox })

        $updateGroup.Controls.Add($updateSingBtn)

        $remoteConfigGroup = New-Object System.Windows.Forms.GroupBox
        $remoteConfigGroup.Text = "Remote Configuration"
        $remoteConfigGroup.Dock = [System.Windows.Forms.DockStyle]::Top
        $remoteConfigGroup.Height = 120
        $remoteConfigGroup.Padding = New-Object System.Windows.Forms.Padding(15)

        $urlLabel = New-Object System.Windows.Forms.Label
        $urlLabel.Text = "Config URL:"
        $urlLabel.Location = New-Object System.Drawing.Point(20, 30)
        $urlLabel.Size = New-Object System.Drawing.Size(80, 25)
        $urlLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $Global:ConfigUrlInput = New-Object System.Windows.Forms.TextBox
        $Global:ConfigUrlInput.Location = New-Object System.Drawing.Point(100, 30)
        $Global:ConfigUrlInput.Size = New-Object System.Drawing.Size(360, 25)
        $Global:ConfigUrlInput.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $getConfigBtn = New-Object System.Windows.Forms.Button
        $getConfigBtn.Text = "Download and Import"
        $getConfigBtn.Location = New-Object System.Drawing.Point(20, 70)
        $getConfigBtn.Size = New-Object System.Drawing.Size(440, 35)
        $getConfigBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 152, 0)
        $getConfigBtn.ForeColor = [System.Drawing.Color]::White
        $getConfigBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $getConfigBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $getConfigBtn.add_Click({ Get-RemoteConfig })

        $remoteConfigGroup.Controls.AddRange(@($urlLabel, $Global:ConfigUrlInput, $getConfigBtn))

        $logPreviewLabel = New-Object System.Windows.Forms.Label
        $logPreviewLabel.Text = "Recent Log Entries (Auto-refreshed every 5 seconds):"
        $logPreviewLabel.Dock = [System.Windows.Forms.DockStyle]::Top
        $logPreviewLabel.Height = 25
        $logPreviewLabel.Padding = New-Object System.Windows.Forms.Padding(20, 5, 0, 0)
        $logPreviewLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $Global:LogPreview = New-Object System.Windows.Forms.TextBox
        $Global:LogPreview.Multiline = $true
        $Global:LogPreview.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $Global:LogPreview.ReadOnly = $true
        $Global:LogPreview.Dock = [System.Windows.Forms.DockStyle]::Fill
        $Global:LogPreview.Font = New-Object System.Drawing.Font("Consolas", 9)
        $Global:LogPreview.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $Global:LogPreview.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 0)

        $Global:MainForm.Controls.AddRange(@($Global:LogPreview, $logPreviewLabel, $remoteConfigGroup, $updateGroup, $buttonPanel, $statusPanel))

        $Global:MainForm.add_FormClosing({
                param($sender, $e)
                $e.Cancel = $true
                Hide-MainForm
            })

        Write-AppLog "Main form initialized successfully" -Level 'INFO'
    }
    catch {
        Write-AppLog "Failed to initialize main form: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Initialize-LogForm {
    try {
        $Global:LogForm = New-Object System.Windows.Forms.Form
        $Global:LogForm.Text = "sing-box Controller - Detailed Logs"
        $Global:LogForm.Size = New-Object System.Drawing.Size(1000, 700)
        $Global:LogForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $Global:LogForm.ShowInTaskbar = $false

        $toolStrip = New-Object System.Windows.Forms.ToolStrip
        $toolStrip.GripStyle = [System.Windows.Forms.ToolStripGripStyle]::Hidden

        $refreshBtn = New-Object System.Windows.Forms.ToolStripButton
        $refreshBtn.Text = "Refresh"
        $refreshBtn.add_Click({ Update-Logs })

        $clearBtn = New-Object System.Windows.Forms.ToolStripButton
        $clearBtn.Text = "Clear Display"
        $clearBtn.add_Click({ if ($Global:LogTextBox) { $Global:LogTextBox.Clear() } })

        $openLogDirBtn = New-Object System.Windows.Forms.ToolStripButton
        $openLogDirBtn.Text = "Open Log Directory"
        $openLogDirBtn.add_Click({
                try {
                    Start-Process "explorer.exe" -ArgumentList $Config.LogDir
                }
                catch {
                    Write-AppLog "Failed to open log directory: $($_.Exception.Message)" -Level 'WARNING'
                }
            })

        $toolStrip.Items.AddRange(@($refreshBtn, (New-Object System.Windows.Forms.ToolStripSeparator), $clearBtn, (New-Object System.Windows.Forms.ToolStripSeparator), $openLogDirBtn))

        $Global:LogTextBox = New-Object System.Windows.Forms.TextBox
        $Global:LogTextBox.Multiline = $true
        $Global:LogTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $Global:LogTextBox.ReadOnly = $true
        $Global:LogTextBox.WordWrap = $false
        $Global:LogTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
        $Global:LogTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
        $Global:LogTextBox.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
        $Global:LogTextBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)

        $Global:LogForm.Controls.AddRange(@($Global:LogTextBox, $toolStrip))

        $Global:LogForm.add_FormClosing({
                param($sender, $e)
                $e.Cancel = $true
                $Global:LogForm.Hide()
            })

        Write-AppLog "Log form initialized successfully" -Level 'INFO'
    }
    catch {
        Write-AppLog "Failed to initialize log form: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Initialize-Timers {
    try {
        $Global:StatusTimer = New-Object System.Windows.Forms.Timer
        $Global:StatusTimer.Interval = 2000
        $Global:StatusTimer.add_Tick({ Update-Status })
        $Global:StatusTimer.Start()

        $Global:LogTimer = New-Object System.Windows.Forms.Timer
        $Global:LogTimer.Interval = 5000
        $Global:LogTimer.add_Tick({ Update-LogPreview })
        $Global:LogTimer.Start()

        $Global:LogRotationTimer = New-Object System.Windows.Forms.Timer
        $Global:LogRotationTimer.Interval = $Config.LogRotationCheck
        $Global:LogRotationTimer.add_Tick({
                Invoke-LogRotation $SingLog
                Invoke-LogRotation $AppLog
            })
        $Global:LogRotationTimer.Start()

        Write-AppLog "All timers initialized successfully" -Level 'INFO'
    }
    catch {
        Write-AppLog "Failed to initialize timers: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Show-MainForm {
    try {
        if ($Global:MainForm) {
            $Global:MainForm.Show()
            $Global:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $Global:MainForm.Activate()
            Update-Status
            Update-LogPreview
        }
    }
    catch {
        Write-AppLog "Error showing main form: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Hide-MainForm {
    try {
        if ($Global:MainForm) {
            $Global:MainForm.Hide()
        }
    }
    catch {
        Write-AppLog "Error hiding main form: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Start-Service {
    Write-AppLog "Starting sing-box service..." -Level 'INFO'
    $success = $true

    if ($null -eq $Global:ConfigSelector.SelectedItem -or -not $Global:ConfigSelector.Enabled) {
        $msg = "No configuration file selected or found in the 'config' directory."
        Write-AppLog $msg -Level "WARNING"
        [System.Windows.Forms.MessageBox]::Show($msg, "Start Error", "OK", "Warning")
        return
    }


    if (-not (Test-ProcessRunning "sing-box")) {
        $selectedConfigFile = $Global:ConfigSelector.SelectedItem.ToString()
        $fullConfigPath = Join-Path $Config.SingConfigDir $selectedConfigFile
        Write-AppLog "Using configuration: $fullConfigPath" -Level "INFO"

        $singArgs = "run -c `"$fullConfigPath`" --disable-color"
        if (-not (Start-VpnProcess $Config.SingPath $singArgs $SingLog "Sing-Box")) {
            $success = $false
        }
    }

    $message = if ($success) { "sing-box service started successfully" } else { "Failed to start sing-box service" }
    $icon = if ($success) { [System.Windows.Forms.ToolTipIcon]::Info } else { [System.Windows.Forms.ToolTipIcon]::Error }

    $Global:NotifyIcon.ShowBalloonTip(3000, "sing-box Controller", $message, $icon)
    Write-AppLog $message -Level $(if ($success) { 'INFO' } else { 'ERROR' })
    Update-Status
}

function Stop-Service {
    Write-AppLog "Stopping sing-box service..." -Level 'INFO'
    Stop-ProcessByName "sing-box"

    $message = "sing-box service stopped"
    $Global:NotifyIcon.ShowBalloonTip(3000, "sing-box Controller", $message, [System.Windows.Forms.ToolTipIcon]::Info)
    Write-AppLog $message -Level 'INFO'
    Update-Status
}

function Update-Status {
    try {
        $singRunning = Test-ProcessRunning "sing-box"

        if ($Global:SingStatusLabel) {
            $Global:SingStatusLabel.Text = if ($singRunning) { "Running" } else { "Stopped" }
            $Global:SingStatusLabel.ForeColor = if ($singRunning) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::Red }
        }

        if ($Global:NotifyIcon) {
            $Global:NotifyIcon.Text = if ($singRunning) { "sing-box Controller - Service Running" } else { "sing-box Controller - Service Stopped" }
        }
    }
    catch {
        Write-AppLog "Error updating status: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Update-LogPreview {
    if ($Global:LogPreview -and $Global:MainForm.Visible) {
        try {
            $logs = @()

            if (Test-Path $AppLog) {
                $logs += "=== Controller Log (last 5 lines) ==="
                $logs += Get-Content -Path $AppLog -Tail 5 -ErrorAction SilentlyContinue
                $logs += ""
            }

            if (Test-Path $SingLog) {
                $logs += "=== Sing-Box (last 15 lines) ==="
                $logs += Get-Content -Path $SingLog -Tail 15 -ErrorAction SilentlyContinue
            }

            $Global:LogPreview.Text = $logs -join "`r`n"
            $Global:LogPreview.SelectionStart = $Global:LogPreview.Text.Length
            $Global:LogPreview.ScrollToCaret()
        }
        catch {
            # Ignore errors silently to avoid spam
        }
    }
}

function Show-LogWindow {
    try {
        Update-Logs
        $Global:LogForm.Show()
        $Global:LogForm.Activate()
    }
    catch {
        Write-AppLog "Error showing log window: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Update-Logs {
    if ($Global:LogTextBox) {
        try {
            $logs = @()

            $logs += "=== LOG VIEWER - Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
            $logs += ""

            if (Test-Path $AppLog) {
                $logs += "=== CONTROLLER LOG (last 50 lines) ==="
                $logs += Get-Content -Path $AppLog -Tail 50 -ErrorAction SilentlyContinue
                $logs += ""
                $logs += ""
            }

            if (Test-Path $SingLog) {
                $logs += "=== SING-BOX LOG (last 200 lines) ==="
                $logs += Get-Content -Path $SingLog -Tail 200 -ErrorAction SilentlyContinue
            }

            $Global:LogTextBox.Text = $logs -join "`r`n"
            $Global:LogTextBox.SelectionStart = $Global:LogTextBox.Text.Length
            $Global:LogTextBox.ScrollToCaret()
        }
        catch {
            $Global:LogTextBox.Text = "Error reading log files: $($_.Exception.Message)"
            Write-AppLog "Error reading log files: $($_.Exception.Message)" -Level 'ERROR'
        }
    }
}

function Exit-Application {
    try {
        Write-AppLog "Application shutdown initiated" -Level 'INFO'

        if ($Global:StatusTimer) { $Global:StatusTimer.Stop(); $Global:StatusTimer.Dispose() }
        if ($Global:LogTimer) { $Global:LogTimer.Stop(); $Global:LogTimer.Dispose() }
        if ($Global:LogRotationTimer) { $Global:LogRotationTimer.Stop(); $Global:LogRotationTimer.Dispose() }

        Stop-Service

        if ($Global:NotifyIcon) { $Global:NotifyIcon.Dispose() }
        if ($Global:LogForm) { $Global:LogForm.Dispose() }
        if ($Global:MainForm) { $Global:MainForm.Dispose() }

        Write-AppLog "Application shutdown completed successfully" -Level 'INFO'

        [System.Windows.Forms.Application]::Exit()
        Stop-Process -Id $PID -Force
    }
    catch {
        Write-AppLog "Error during application shutdown: $($_.Exception.Message)" -Level 'ERROR'
        Stop-Process -Id $PID -Force
    }
}

try {
    Write-AppLog "sing-box Controller starting up..." -Level 'INFO'

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    Initialize-TrayIcon
    Initialize-MainForm
    Initialize-LogForm
    Initialize-Timers

    Write-AppLog "sing-box Controller initialized successfully, entering message loop" -Level 'INFO'

    [System.Windows.Forms.Application]::Run()
}
catch {
    $errorMessage = "Critical error running sing-box Controller: $($_.Exception.Message)"
    Write-AppLog $errorMessage -Level 'ERROR'
    [System.Windows.Forms.MessageBox]::Show($errorMessage, "Fatal Error", "OK", "Error")
}
finally {
    Write-AppLog "Final cleanup: stopping sing-box service..." -Level 'INFO'
    Stop-Service
    if ($Global:NotifyIcon) { $Global:NotifyIcon.Dispose() }
    Write-AppLog "sing-box Controller shutdown complete" -Level 'INFO'
}
