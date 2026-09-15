<#
.SYNOPSIS
    Drag-and-drop front end for the Azure Support -> MSX ingestion workflow.

.DESCRIPTION
    Shows a small window. Drop the customer's hand-off file (azure-support-results-*.json
    or the *.email.txt) onto it and the tool will:

      1. Build the MSX ingestion plan (dry run) with Ingest-SupportEmail.ps1.
      2. Show the plan summary and open the plan JSON.
      3. Offer to launch an interactive Copilot session (copilot -i) that reads the plan
         and the runbook and creates the opportunity, milestones, and Non-AI UATs via the
         msx-mcp tools - prompting you to confirm every single write.

    The msx-mcp write tools and their confirmation prompts only exist inside the Copilot
    agent runtime, so this window cannot write to MSX itself - it launches Copilot to do
    the writes. Nothing is written to MSX until you confirm each write in that session.

    Run via Ingest-DropUI.cmd (which starts PowerShell in STA mode, required for WinForms).
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$planner     = Join-Path $scriptDir "Ingest-SupportEmail.ps1"
$runbook     = Join-Path $scriptDir "INGEST-RUNBOOK.md"

if (-not (Test-Path $planner)) {
    [System.Windows.Forms.MessageBox]::Show("Cannot find Ingest-SupportEmail.ps1 next to this UI.","Setup error",'OK','Error') | Out-Null
    return
}

# --- Form ------------------------------------------------------------------------
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Azure Support -> MSX Ingestion"
$form.Size          = New-Object System.Drawing.Size(640, 460)
$form.StartPosition = "CenterScreen"
$form.BackColor     = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.AllowDrop     = $true

$drop               = New-Object System.Windows.Forms.Panel
$drop.Size          = New-Object System.Drawing.Size(600, 150)
$drop.Location      = New-Object System.Drawing.Point(15, 15)
$drop.BackColor     = [System.Drawing.Color]::FromArgb(232, 240, 254)
$drop.BorderStyle   = "FixedSingle"
$drop.AllowDrop     = $true
$form.Controls.Add($drop)

$dropLabel          = New-Object System.Windows.Forms.Label
$dropLabel.Text     = "Drop the hand-off file here`r`n(azure-support-results-*.json  or  *.email.txt)"
$dropLabel.Dock     = "Fill"
$dropLabel.TextAlign= "MiddleCenter"
$dropLabel.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$dropLabel.ForeColor= [System.Drawing.Color]::FromArgb(30, 64, 120)
$drop.Controls.Add($dropLabel)

$log                = New-Object System.Windows.Forms.TextBox
$log.Multiline      = $true
$log.ScrollBars     = "Vertical"
$log.ReadOnly       = $true
$log.Size           = New-Object System.Drawing.Size(600, 210)
$log.Location       = New-Object System.Drawing.Point(15, 180)
$log.Font           = New-Object System.Drawing.Font("Consolas", 9)
$log.BackColor      = [System.Drawing.Color]::White
$form.Controls.Add($log)

$status             = New-Object System.Windows.Forms.Label
$status.Text        = "Ready. Waiting for a file..."
$status.Size        = New-Object System.Drawing.Size(600, 22)
$status.Location    = New-Object System.Drawing.Point(15, 398)
$status.Font        = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($status)

function Add-Log { param([string]$Text)
    $log.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $Text))
}

# --- Core: build the plan, then offer to launch Copilot --------------------------
function Invoke-Ingest { param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { Add-Log "File not found: $File"; return }
    $ext = [System.IO.Path]::GetExtension($File).ToLower()
    if ($ext -notin @(".json", ".txt")) {
        Add-Log "Unsupported file type '$ext'. Drop a .json or .email.txt hand-off."
        $status.Text = "Unsupported file type."
        return
    }

    $status.Text = "Building ingestion plan..."
    Add-Log "Dropped: $File"
    Add-Log "Running planner (dry run - no MSX writes)..."

    $before = @(Get-ChildItem -Path $scriptDir -Filter 'ingestion-plan-*.json' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planner -InputFile $File 2>&1
    } catch {
        Add-Log "Planner error: $($_.Exception.Message)"; $status.Text = "Planner failed."; return
    }
    # Surface the human-readable plan lines (strip the timestamp prefix noise).
    foreach ($line in ($out | Out-String -Stream)) {
        if ($line.Trim()) { $log.AppendText(($line -replace "`0","") + "`r`n") }
    }

    $planFile = @(Get-ChildItem -Path $scriptDir -Filter 'ingestion-plan-*.json' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -ExpandProperty FullName |
                  Where-Object { $_ -notin $before }) | Select-Object -Last 1
    if (-not $planFile) {
        $planFile = @(Get-ChildItem -Path $scriptDir -Filter 'ingestion-plan-*.json' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime | Select-Object -ExpandProperty FullName) | Select-Object -Last 1
    }
    if (-not $planFile) { Add-Log "No plan file was produced - check the output above."; $status.Text = "Planner produced no plan."; return }

    Add-Log "Plan built: $planFile"
    Start-Process notepad.exe $planFile
    $status.Text = "Plan built. Review, then choose whether to launch Copilot."

    $ask = [System.Windows.Forms.MessageBox]::Show(
        "Ingestion plan built (dry run - nothing written yet).`n`nLaunch an interactive Copilot session now to create the opportunity, milestones, and Non-AI UATs?`n`nYou will be asked to confirm every MSX write in that session.",
        "Launch Copilot to execute?", 'YesNo', 'Question')
    if ($ask -ne 'Yes') { Add-Log "Left as a dry run. Plan saved; no Copilot session launched."; return }

    if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
        Add-Log "copilot CLI not found on PATH - open a terminal and run it manually against the plan."
        [System.Windows.Forms.MessageBox]::Show("The 'copilot' CLI was not found on PATH.`nOpen Copilot manually and point it at:`n$planFile","Copilot not found",'OK','Warning') | Out-Null
        return
    }

    $planName = [System.IO.Path]::GetFileName($planFile)
    # Quote-safe seed prompt (NO embedded double quotes) - the folder is the working dir,
    # so the runbook and plan are referenced by bare filename.
    $seed = "Follow INGEST-RUNBOOK.md in this folder to execute the MSX ingestion plan " +
            "$planName. Create one opportunity, then one Blocked milestone per support request " +
            "(record the exact SR number in the Risk/Blocker details and never set ACR), then " +
            "file the Non-AI Capacity UATs via the msx-mcp tools. Confirm every write before " +
            "committing. Start with msx_auth_status."

    # copilot -i needs a real interactive console (TTY). Two traps to avoid:
    #   1. Spawned bare via Start-Process it has no attached console and exits (exit 1).
    #   2. Start-Process -ArgumentList does NOT reliably quote args with spaces, so the
    #      prompt and the space-containing folder path get split into broken args.
    # Both are dodged by writing a tiny launcher .cmd with everything quoted literally, then
    # running it - it opens its own console (real TTY) and passes clean args to copilot.
    $runDir = Join-Path $scriptDir "launchers"
    if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
    $runCmd = Join-Path $runDir ("_run-ingest-{0}.cmd" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $batch = @(
        '@echo off'
        'title MSX Ingestion - Copilot'
        ('cd /d "{0}"' -f $scriptDir)
        ('copilot -i "{0}" --add-dir "{1}"' -f $seed, $scriptDir)
    ) -join "`r`n"
    Set-Content -LiteralPath $runCmd -Value $batch -Encoding ASCII

    Add-Log "Launching Copilot (interactive) in a new terminal window..."
    Start-Process -FilePath $runCmd -WorkingDirectory $scriptDir
    $status.Text = "Copilot launched in a terminal - confirm each write there."
    Add-Log "Copilot session started in a new terminal. Approve each milestone/UAT write there."
}

# --- Drag/drop wiring (panel + form) ---------------------------------------------
$enter = {
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        $drop.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 201)
    } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
}
$leave = { $drop.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 254) }
$dropped = {
    param($s, $e)
    $drop.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -gt 0) { Invoke-Ingest -File $files[0] }
}
foreach ($ctl in @($form, $drop, $dropLabel)) {
    $ctl.AllowDrop = $true
    $ctl.Add_DragEnter($enter)
    $ctl.Add_DragLeave($leave)
    $ctl.Add_DragDrop($dropped)
}

[void]$form.ShowDialog()
