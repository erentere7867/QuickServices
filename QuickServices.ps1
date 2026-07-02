Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:Services = @()
$script:SortColumn = 'DisplayName'
$script:SortAscending = $true
$script:PendingStartupChanges = @{}

function Convert-ServiceStartMode {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto' { 'Automatic' }
        'Manual' { 'Manual' }
        'Disabled' { 'Disabled' }
        default { $StartMode }
    }
}

function Get-StartupLabel {
    param([string]$StartMode, [bool]$DelayedAutoStart)
    if ($StartMode -eq 'Auto' -and $DelayedAutoStart) { return 'Automatic (Delayed)' }
    Convert-ServiceStartMode $StartMode
}

function Load-Services {
    $script:Services = Get-CimInstance Win32_Service | ForEach-Object {
        $svc = $_
        $delayed = $false
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
            $delayedValue = Get-ItemProperty -Path $regPath -Name DelayedAutoStart -ErrorAction SilentlyContinue
            $delayed = [bool]($delayedValue.DelayedAutoStart -eq 1)
        } catch {
            $delayed = $false
        }

        [PSCustomObject]@{
            Name = $svc.Name
            DisplayName = $svc.DisplayName
            Description = $svc.Description
            State = $svc.State
            Status = $svc.Status
            StartMode = $svc.StartMode
            Startup = Get-StartupLabel $svc.StartMode $delayed
            DelayedAutoStart = $delayed
            PathName = $svc.PathName
            ServiceType = $svc.ServiceType
            StartName = $svc.StartName
            ProcessId = $svc.ProcessId
            IsMicrosoft = Test-MicrosoftService $svc
        }
    }
}

function Get-ServiceExecutablePath {
    param([string]$PathName)

    if (-not $PathName) { return '' }
    $trimmed = $PathName.Trim()

    if ($trimmed.StartsWith('"')) {
        $endQuote = $trimmed.IndexOf('"', 1)
        if ($endQuote -gt 1) { return $trimmed.Substring(1, $endQuote - 1) }
    }

    $match = [regex]::Match($trimmed, '(?i)^[a-z]:\\.*?\.exe')
    if ($match.Success) { return $match.Value }

    return $trimmed.Split(' ')[0]
}

function Test-MicrosoftService {
    param([object]$Service)

    $exePath = Get-ServiceExecutablePath ([string]$Service.PathName)
    if (-not $exePath) { return $false }

    if ($exePath -match '(?i)\\Windows\\System32\\svchost\.exe$') { return $true }
    if ($exePath -match '(?i)\\Windows\\System32\\spoolsv\.exe$') { return $true }
    if ($exePath -match '(?i)\\Windows\\System32\\lsass\.exe$') { return $true }
    if ($exePath -match '(?i)\\Windows\\System32\\services\.exe$') { return $true }
    if ($exePath -match '(?i)\\Windows\\servicing\\') { return $true }

    try {
        if (Test-Path -LiteralPath $exePath) {
            $company = [Diagnostics.FileVersionInfo]::GetVersionInfo($exePath).CompanyName
            if ($company -match '(?i)Microsoft') { return $true }
        }
    } catch {
        return $false
    }

    return $false
}

function Get-PendingStartupLabel {
    param([string]$Name)
    if (-not $script:PendingStartupChanges.ContainsKey($Name)) { return '' }
    $target = [string]$script:PendingStartupChanges[$Name]
    switch ($target) {
        'Disabled' { 'Pending: Disabled' }
        'Manual' { 'Pending: Manual' }
        'Automatic' { 'Pending: Automatic' }
        default { "Pending: $target" }
    }
}

function Update-PendingUi {
    $count = $script:PendingStartupChanges.Count
    if ($count -gt 0) {
        $statusLabel.Text = "$count pending startup change(s). Press Save to apply."
        $saveButton.Enabled = $true
        $discardButton.Enabled = $true
    } else {
        $saveButton.Enabled = $false
        $discardButton.Enabled = $false
        if ($script:IsAdmin) {
            $statusLabel.Text = 'Administrator mode: service changes enabled.'
        } else {
            $statusLabel.Text = 'Read-only mode: restart PowerShell as Administrator to save startup changes or control services.'
        }
    }
}

function Test-ServiceMatchesFilter {
    param(
        [object]$Service,
        [string]$Query,
        [string]$StartupFilter,
        [string]$StateFilter,
        [bool]$HideMicrosoft
    )

    if ($HideMicrosoft -and $Service.IsMicrosoft) { return $false }

    if ($Query) {
        $haystack = @(
            $Service.Name
            $Service.DisplayName
            $Service.Description
            $Service.PathName
        ) -join ' '
        if ($haystack -notlike "*$Query*") { return $false }
    }

    switch ($StartupFilter) {
        'Automatic' { if ($Service.StartMode -ne 'Auto' -or $Service.DelayedAutoStart) { return $false } }
        'Automatic (Delayed)' { if (-not ($Service.StartMode -eq 'Auto' -and $Service.DelayedAutoStart)) { return $false } }
        'Manual' { if ($Service.StartMode -ne 'Manual') { return $false } }
        'Disabled' { if ($Service.StartMode -ne 'Disabled') { return $false } }
    }

    switch ($StateFilter) {
        'Running' { if ($Service.State -ne 'Running') { return $false } }
        'Stopped' { if ($Service.State -ne 'Stopped') { return $false } }
    }

    return $true
}

function Show-ServiceDetails {
    param([object]$Service)

    if (-not $Service) {
        $detailsTextBox.Text = ''
        return
    }

    $detailsTextBox.Text = @"
Display name: $($Service.DisplayName)
Service name: $($Service.Name)
Description: $($Service.Description)

State: $($Service.State)
Startup: $($Service.Startup)
Pending: $(Get-PendingStartupLabel $Service.Name)
Type: $($Service.ServiceType)
PID: $($Service.ProcessId)

Path:
$($Service.PathName)
"@
}

function Get-SelectedServiceName {
    if ($grid.SelectedRows.Count -lt 1) { return $null }
    return [string]$grid.SelectedRows[0].Cells['Name'].Value
}

function Refresh-Grid {
    $previousName = Get-SelectedServiceName
    $firstDisplayedRow = -1
    try {
        if ($grid.Rows.Count -gt 0) { $firstDisplayedRow = $grid.FirstDisplayedScrollingRowIndex }
    } catch {
        $firstDisplayedRow = -1
    }

    $query = $searchBox.Text.Trim()
    $startupFilter = [string]$startupCombo.SelectedItem
    $stateFilter = [string]$stateCombo.SelectedItem
    $hideMicrosoft = $hideMicrosoftCheckBox.Checked

    $items = $script:Services | Where-Object {
        Test-ServiceMatchesFilter $_ $query $startupFilter $stateFilter $hideMicrosoft
    }

    if ($script:SortAscending) {
        $items = $items | Sort-Object -Property $script:SortColumn
    } else {
        $items = $items | Sort-Object -Property $script:SortColumn -Descending
    }

    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('AutoToggle', [string])
    [void]$table.Columns.Add('DisplayName', [string])
    [void]$table.Columns.Add('Name', [string])
    [void]$table.Columns.Add('Startup', [string])
    [void]$table.Columns.Add('State', [string])
    [void]$table.Columns.Add('Pending', [string])
    [void]$table.Columns.Add('Description', [string])

    foreach ($svc in $items) {
        $row = $table.NewRow()
        $pending = if ($script:PendingStartupChanges.ContainsKey($svc.Name)) { [string]$script:PendingStartupChanges[$svc.Name] } else { '' }
        $row.AutoToggle = if ($svc.StartMode -eq 'Auto' -and $pending -eq 'Disabled') { 'Off' } elseif ($svc.StartMode -eq 'Auto') { 'On' } else { '' }
        $row.DisplayName = $svc.DisplayName
        $row.Name = $svc.Name
        $row.Startup = $svc.Startup
        $row.State = $svc.State
        $row.Pending = Get-PendingStartupLabel $svc.Name
        $row.Description = $svc.Description
        [void]$table.Rows.Add($row)
    }

    $grid.DataSource = $table
    $pendingText = if ($script:PendingStartupChanges.Count -gt 0) { " | $($script:PendingStartupChanges.Count) pending" } else { '' }
    $countLabel.Text = "$($table.Rows.Count) service(s)$pendingText"

    if ($previousName) {
        foreach ($row in $grid.Rows) {
            if ($row.Cells['Name'].Value -eq $previousName) {
                $row.Selected = $true
                $grid.CurrentCell = $row.Cells['DisplayName']
                break
            }
        }
    }

    try {
        if ($firstDisplayedRow -ge 0 -and $firstDisplayedRow -lt $grid.Rows.Count) {
            $grid.FirstDisplayedScrollingRowIndex = $firstDisplayedRow
        }
    } catch {
    }

    Update-PendingUi
}

function Reload-Services {
    $previousName = Get-SelectedServiceName
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Load-Services
        Refresh-Grid
        if ($previousName) {
            foreach ($row in $grid.Rows) {
                if ($row.Cells['Name'].Value -eq $previousName) {
                    $row.Selected = $true
                    $grid.CurrentCell = $row.Cells['DisplayName']
                    break
                }
            }
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Queue-StartupChange {
    param(
        [string]$Name,
        [ValidateSet('Disabled','Manual','Automatic')]
        [string]$StartupType
    )

    $svc = $script:Services | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $svc) { return }

    $current = Convert-ServiceStartMode $svc.StartMode
    if ($script:PendingStartupChanges.ContainsKey($Name) -and $script:PendingStartupChanges[$Name] -eq $StartupType) {
        [void]$script:PendingStartupChanges.Remove($Name)
    } elseif ($current -eq $StartupType) {
        [void]$script:PendingStartupChanges.Remove($Name)
    } else {
        $script:PendingStartupChanges[$Name] = $StartupType
    }

    Refresh-Grid
}

function Save-PendingStartupChanges {
    if ($script:PendingStartupChanges.Count -lt 1) { return }

    if (-not $script:IsAdmin) {
        [System.Windows.Forms.MessageBox]::Show('Run this script as Administrator to save startup changes.', 'Administrator required', 'OK', 'Warning') | Out-Null
        return
    }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $failed = New-Object System.Collections.Generic.List[string]
    $saved = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($name in @($script:PendingStartupChanges.Keys)) {
            $target = [string]$script:PendingStartupChanges[$name]
            try {
                Set-Service -Name $name -StartupType $target -ErrorAction Stop
                [void]$saved.Add($name)
            } catch {
                [void]$failed.Add("$name`: $($_.Exception.Message)")
            }
        }

        foreach ($name in $saved) {
            [void]$script:PendingStartupChanges.Remove($name)
        }

        if ($failed.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(($failed -join "`r`n"), 'Some changes failed', 'OK', 'Error') | Out-Null
        }

        Reload-Services
        $statusLabel.Text = if ($failed.Count -gt 0) { 'Saved remaining startup changes; some failed.' } else { 'Startup changes saved.' }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Update-PendingUi
    }
}

function Discard-PendingStartupChanges {
    $script:PendingStartupChanges.Clear()
    Refresh-Grid
}

function Invoke-ServiceAction {
    param(
        [ValidateSet('Disable','Manual','Automatic','Stop','Start','Restart')]
        [string]$Action
    )

    $name = Get-SelectedServiceName
    if (-not $name) {
        [System.Windows.Forms.MessageBox]::Show('Select a service first.', 'Quick Service Control', 'OK', 'Information') | Out-Null
        return
    }

    if ($Action -in @('Disable','Manual','Automatic')) {
        switch ($Action) {
            'Disable' { Queue-StartupChange $name Disabled }
            'Manual' { Queue-StartupChange $name Manual }
            'Automatic' { Queue-StartupChange $name Automatic }
        }
        return
    }

    if (-not $script:IsAdmin) {
        [System.Windows.Forms.MessageBox]::Show('Run this script as Administrator to change services.', 'Administrator required', 'OK', 'Warning') | Out-Null
        return
    }

    $svc = $script:Services | Where-Object Name -eq $name | Select-Object -First 1

    try {
        switch ($Action) {
            'Stop' { Stop-Service -Name $name -ErrorAction Stop }
            'Start' { Start-Service -Name $name -ErrorAction Stop }
            'Restart' { Restart-Service -Name $name -ErrorAction Stop }
        }
        Reload-Services
        $statusLabel.Text = "$Action completed: $name"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "$Action failed", 'OK', 'Error') | Out-Null
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Quick Service Control'
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1100, 680)
$form.Size = New-Object System.Drawing.Size(1280, 760)

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.RowCount = 4
$root.ColumnCount = 1
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
$form.Controls.Add($root)

$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 6)
$toolbar.WrapContents = $false
$root.Controls.Add($toolbar, 0, 0)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = 'Search'
$searchLabel.AutoSize = $true
$searchLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 4, 0)
$toolbar.Controls.Add($searchLabel)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Width = 280
$searchBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 12, 0)
$toolbar.Controls.Add($searchBox)

$startupCombo = New-Object System.Windows.Forms.ComboBox
$startupCombo.DropDownStyle = 'DropDownList'
$startupCombo.Width = 170
[void]$startupCombo.Items.AddRange(@('All startup', 'Automatic', 'Automatic (Delayed)', 'Manual', 'Disabled'))
$startupCombo.SelectedIndex = 0
$startupCombo.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
$toolbar.Controls.Add($startupCombo)

$stateCombo = New-Object System.Windows.Forms.ComboBox
$stateCombo.DropDownStyle = 'DropDownList'
$stateCombo.Width = 120
[void]$stateCombo.Items.AddRange(@('All states', 'Running', 'Stopped'))
$stateCombo.SelectedIndex = 0
$stateCombo.Margin = New-Object System.Windows.Forms.Padding(0, 2, 12, 0)
$toolbar.Controls.Add($stateCombo)

$hideMicrosoftCheckBox = New-Object System.Windows.Forms.CheckBox
$hideMicrosoftCheckBox.Text = 'Hide Microsoft/Windows'
$hideMicrosoftCheckBox.AutoSize = $true
$hideMicrosoftCheckBox.Margin = New-Object System.Windows.Forms.Padding(0, 6, 12, 0)
$toolbar.Controls.Add($hideMicrosoftCheckBox)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Width = 84
$refreshButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$toolbar.Controls.Add($refreshButton)

$disableButton = New-Object System.Windows.Forms.Button
$disableButton.Text = 'Disable'
$disableButton.Width = 88
$disableButton.Margin = New-Object System.Windows.Forms.Padding(12, 0, 6, 0)
$toolbar.Controls.Add($disableButton)

$manualButton = New-Object System.Windows.Forms.Button
$manualButton.Text = 'Manual'
$manualButton.Width = 84
$manualButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$toolbar.Controls.Add($manualButton)

$autoButton = New-Object System.Windows.Forms.Button
$autoButton.Text = 'Automatic'
$autoButton.Width = 92
$autoButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$toolbar.Controls.Add($autoButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save'
$saveButton.Width = 72
$saveButton.Enabled = $false
$saveButton.Margin = New-Object System.Windows.Forms.Padding(10, 0, 6, 0)
$toolbar.Controls.Add($saveButton)

$discardButton = New-Object System.Windows.Forms.Button
$discardButton.Text = 'Discard'
$discardButton.Width = 78
$discardButton.Enabled = $false
$discardButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$toolbar.Controls.Add($discardButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = 'Stop'
$stopButton.Width = 72
$stopButton.Margin = New-Object System.Windows.Forms.Padding(10, 0, 6, 0)
$toolbar.Controls.Add($stopButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = 'Start'
$startButton.Width = 72
$startButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$toolbar.Controls.Add($startButton)

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = 'Loading...'
$countLabel.AutoSize = $true
$countLabel.Margin = New-Object System.Windows.Forms.Padding(12, 6, 0, 0)
$toolbar.Controls.Add($countLabel)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.MultiSelect = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoGenerateColumns = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.BorderStyle = 'None'

function Add-GridTextColumn {
    param(
        [string]$Name,
        [string]$HeaderText,
        [int]$FillWeight,
        [int]$MinimumWidth = 50
    )

    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.DataPropertyName = $Name
    $column.HeaderText = $HeaderText
    $column.FillWeight = $FillWeight
    $column.MinimumWidth = $MinimumWidth
    [void]$grid.Columns.Add($column)
}

Add-GridTextColumn 'AutoToggle' 'Auto' 28 42
Add-GridTextColumn 'DisplayName' 'Display name' 190 130
Add-GridTextColumn 'Name' 'Service name' 105 95
Add-GridTextColumn 'Startup' 'Startup' 58 76
Add-GridTextColumn 'State' 'State' 44 60
Add-GridTextColumn 'Pending' 'Pending' 72 90
Add-GridTextColumn 'Description' 'Description' 260 160

$root.Controls.Add($grid, 0, 1)

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$disableMenuItem = $contextMenu.Items.Add('Disable')
$stopMenuItem = $contextMenu.Items.Add('Stop')
$startMenuItem = $contextMenu.Items.Add('Start')
$restartMenuItem = $contextMenu.Items.Add('Restart')
$grid.ContextMenuStrip = $contextMenu

$detailsTextBox = New-Object System.Windows.Forms.TextBox
$detailsTextBox.Dock = 'Fill'
$detailsTextBox.Multiline = $true
$detailsTextBox.ReadOnly = $true
$detailsTextBox.ScrollBars = 'Vertical'
$detailsTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$root.Controls.Add($detailsTextBox, 0, 2)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = 'Fill'
$statusLabel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 0)
if ($script:IsAdmin) {
    $statusLabel.Text = 'Administrator mode: service changes enabled.'
} else {
    $statusLabel.Text = 'Read-only mode: restart PowerShell as Administrator to disable, stop, or change startup type.'
}
$root.Controls.Add($statusLabel, 0, 3)

$searchTimer = New-Object System.Windows.Forms.Timer
$searchTimer.Interval = 180
$searchTimer.Add_Tick({
    $searchTimer.Stop()
    Refresh-Grid
})

$searchBox.Add_TextChanged({
    $searchTimer.Stop()
    $searchTimer.Start()
})
$startupCombo.Add_SelectedIndexChanged({ Refresh-Grid })
$stateCombo.Add_SelectedIndexChanged({ Refresh-Grid })
$hideMicrosoftCheckBox.Add_CheckedChanged({ Refresh-Grid })
$refreshButton.Add_Click({ Reload-Services })
$disableButton.Add_Click({ Invoke-ServiceAction Disable })
$manualButton.Add_Click({ Invoke-ServiceAction Manual })
$autoButton.Add_Click({ Invoke-ServiceAction Automatic })
$saveButton.Add_Click({ Save-PendingStartupChanges })
$discardButton.Add_Click({ Discard-PendingStartupChanges })
$stopButton.Add_Click({ Invoke-ServiceAction Stop })
$startButton.Add_Click({ Invoke-ServiceAction Start })
$disableMenuItem.Add_Click({ Invoke-ServiceAction Disable })
$stopMenuItem.Add_Click({ Invoke-ServiceAction Stop })
$startMenuItem.Add_Click({ Invoke-ServiceAction Start })
$restartMenuItem.Add_Click({ Invoke-ServiceAction Restart })

$grid.Add_SelectionChanged({
    $name = Get-SelectedServiceName
    if ($name) {
        Show-ServiceDetails ($script:Services | Where-Object Name -eq $name | Select-Object -First 1)
    }
})

$grid.Add_CellClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 0) { return }
    $columnName = $grid.Columns[$eventArgs.ColumnIndex].Name
    if ($columnName -ne 'AutoToggle') { return }

    $name = [string]$grid.Rows[$eventArgs.RowIndex].Cells['Name'].Value
    if (-not $name) { return }

    $svc = $script:Services | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $svc -or $svc.StartMode -ne 'Auto') { return }

    $grid.ClearSelection()
    $grid.Rows[$eventArgs.RowIndex].Selected = $true
    $grid.CurrentCell = $grid.Rows[$eventArgs.RowIndex].Cells['AutoToggle']
    Invoke-ServiceAction Disable
})

$grid.Add_CellMouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    if ($eventArgs.RowIndex -lt 0) { return }

    $grid.ClearSelection()
    $grid.Rows[$eventArgs.RowIndex].Selected = $true
    $columnIndex = if ($eventArgs.ColumnIndex -ge 0) { $eventArgs.ColumnIndex } else { 0 }
    $grid.CurrentCell = $grid.Rows[$eventArgs.RowIndex].Cells[$columnIndex]

    $name = Get-SelectedServiceName
    $svc = $script:Services | Where-Object Name -eq $name | Select-Object -First 1
    $hasSelection = [bool]$svc
    $isRunning = $hasSelection -and $svc.State -eq 'Running'
    $isStopped = $hasSelection -and $svc.State -eq 'Stopped'

    $disableMenuItem.Enabled = $hasSelection -and $svc.StartMode -ne 'Disabled'
    $stopMenuItem.Enabled = $isRunning
    $startMenuItem.Enabled = $isStopped
    $restartMenuItem.Enabled = $isRunning
})

$grid.Add_CellFormatting({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 0) { return }
    if ($grid.Columns[$eventArgs.ColumnIndex].Name -ne 'AutoToggle') { return }

    $value = [string]$eventArgs.Value
    $cell = $grid.Rows[$eventArgs.RowIndex].Cells[$eventArgs.ColumnIndex]
    $cell.Style.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter

    if ($value -eq 'On') {
        $cell.Style.BackColor = [System.Drawing.Color]::FromArgb(214, 245, 226)
        $cell.Style.ForeColor = [System.Drawing.Color]::FromArgb(20, 105, 55)
        $cell.Style.SelectionBackColor = [System.Drawing.Color]::FromArgb(169, 228, 191)
        $cell.Style.SelectionForeColor = [System.Drawing.Color]::FromArgb(10, 78, 39)
    } elseif ($value -eq 'Off') {
        $cell.Style.BackColor = [System.Drawing.Color]::FromArgb(255, 229, 229)
        $cell.Style.ForeColor = [System.Drawing.Color]::FromArgb(150, 35, 35)
        $cell.Style.SelectionBackColor = [System.Drawing.Color]::FromArgb(246, 187, 187)
        $cell.Style.SelectionForeColor = [System.Drawing.Color]::FromArgb(112, 25, 25)
    } else {
        $cell.Style.BackColor = $grid.DefaultCellStyle.BackColor
        $cell.Style.ForeColor = $grid.DefaultCellStyle.BackColor
        $cell.Style.SelectionBackColor = $grid.DefaultCellStyle.SelectionBackColor
        $cell.Style.SelectionForeColor = $grid.DefaultCellStyle.SelectionBackColor
    }
})

$grid.Add_ColumnHeaderMouseClick({
    param($sender, $eventArgs)
    $columnName = $grid.Columns[$eventArgs.ColumnIndex].Name
    if ($script:SortColumn -eq $columnName) {
        $script:SortAscending = -not $script:SortAscending
    } else {
        $script:SortColumn = $columnName
        $script:SortAscending = $true
    }
    Refresh-Grid
})

$form.Add_Shown({ Reload-Services })

[void][System.Windows.Forms.Application]::Run($form)
