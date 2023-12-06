
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $ConfigurationDataFile,

    # use -WhatIf to see what would happen if you ran this script
    [Parameter(Mandatory=$false)]
    [switch]
    $WhatIf,

    # Use -Force to bypass the warning message
    [Parameter(Mandatory=$false)]
    [switch]
    $Force
)

$configdata = [hashtable] (Invoke-Expression (Get-Content $ConfigurationDataFile | out-string))

$networkControllerNames = $configdata.NCs.computerName
$gatewayNames = $configdata.Gateways.ComputerName
$muxNames = $configData.Muxes.computerName
$allVMNames = $networkControllerNames + $gatewayNames + $muxNames

Write-Host "Found '$($allVMNames.count)' VMs in config file to clean up"

$nodeNames = $configData.HyperVHosts

$vmsToDelete = Get-VM -Name $allVMNames -CimSession $nodeNames -ErrorAction SilentlyContinue

Write-Host "Located '$($vmsToDelete.count)' of '$($allVMNames.count)' to remove..."

$disksToDelete = $vmsToDelete | Get-VMHardDiskDrive

# build array of disk paths to delete
$diskVHDsToDelete = @()
$disksToDelete | ForEach-Object { $diskVHDsToDelete += New-Object -Type PSObject -Property @{'ComputerName'=$_.ComputerName; 'Path'=$_.Path}}

If (!$Force.IsPresent) {
    Write-Warning "This operation is destructive and will delete your entire SDN infrastructure. If you plan to redeply, make sure you have taken and tested a backup of your NC database! See: https://learn.microsoft.com/en-us/windows-server/networking/sdn/manage/update-backup-restore"

    $response = $null
    while ($response -ne 'y' -and $response -ne 'n') {
        $response = Read-Host -Prompt "Do you want to continue? (y/n)"
    }
    If ($response -eq 'n') {
        Write-Host "Exiting..."
        return
    }
}

# stop all VMs to delete
Write-Host "Stopping VMs..."
$vmsToDelete | Stop-VM -Force -TurnOff -WhatIf:($WhatIf.IsPresent)

# remove disks from VMs
Write-Host "Removing disks from VMs..."
$disksToDelete | Remove-VMHardDiskDrive -Confirm:$false -WhatIf:($WhatIf.IsPresent)

# remove VMs
Write-Host "Deleting VMs from Hyper-V..."
$vmsToDelete | Remove-VM -Force -WhatIf:($WhatIf.IsPresent)

# delete hard disk drives
Write-Host "Deleting VHD files..."
$groupedDisks = $diskVHDsToDelete | Group-Object ComputerName

ForEach ($group in $groupedDisks) {
    Write-Host "Deleting disks on node: '$($group.name)'"

    ForEach ($disk in $group.Group) {
        Write-Host "Deleting disk '$($disk.path)'"
        Invoke-Command {
            Remove-Item -Path $args[0] -Force -WhatIf:($args[1])
        } -ComputerName $group.Name -ArgumentList $disk.Path,$whatIf.IsPresent
    }
}

# directory cleanup for VMs
$groupedVMs = $vmsToDelete | Group-Object ComputerName
ForEach ($group in $groupedVMs) {
    Write-Host "Deleting directories on: '$($group.name)'"

    ForEach ($vmPath in $group.Group) {
        Write-Host "Deleting directory: '$($vmPath.Path)'"
        Invoke-Command {
            Get-Item -Path $args[0] | rmdir -Force -WhatIf:($args[1]) -Recurse
        } -ComputerName $group.Name -ArgumentList $vmPath.Path,$whatIf.IsPresent 
    }
}

# AD cleanup
Write-Host "Deleteing AD computer accounts..."
$allVMNames | ForEach-Object {
    If (Get-AdComputer -Filter "name -eq '$_'") {
        Remove-AdComputer -Identity $_ -Confirm:$false -WhatIf:($whatIf.IsPresent)
    }
}

# clean up registry on host nodes
ForEach ($node in $nodeNames) {
    Invoke-Command {
        If (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\' -Name Connections -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -path 'HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\' -Name Connections -Force -WhatIf:($args[0])
        }
    } -ComputerName $node -ArgumentList $whatIf.IsPresent
}
