function Move-VMtoHostandSwitch {
    <#
    .Synopsis
    This function will move all virtual machines from one host to another, and change their networking from a dvSwitch to a vSwitch
    It is assumed that all Port Proups have identical names on the source and destination virtual switches
    This function was created to assist with moving virtual hosts from one vCenter to another where the dvSwitch must be removed from the ESXi host
    The migration scenario for this script is where the virtual machines cannot be moved from a dvSwitch to a vSwitch on the same host easily 
    NOTE: Currently this function only supports virtual machines with a single NIC 
    .EXAMPLE
    Move-VMtoHostandSwitch -SourceHost esx01 -DestHost esx02 -DestSwitch vSwitch0 -TestVM test01 
    Move-VMtoHostandSwitch -SourceHost esx01 -DestHost esx02 -DestSwitch vSwitch0 -WhatIf
    Move-VMtoHostandSwitch -SourceHost esx01 -DestHost esx02 -DestSwitch vSwitch0 
    #>
    [CmdletBinding()]
    [Alias()]
    Param
    (
        # Specify the source virtual machine host where virtual machines are to be migrated from 
        [Parameter(Mandatory = $true,
            Position = 0)]
        $SourceHost,

        # Specify the destination virtual machine host where virtual machines are to be migrated to 
        [Parameter(Mandatory = $true,
            Position = 1)]
        $DestHost,

        # Specify target vSwitch name on destination host 
        [Parameter(Mandatory = $true,
        Position = 2)]
        $DestSwitch,

        # Specify a test virtual machine to migrate instead of all virtual machines
        [Parameter(Mandatory = $false,
            Position = 3)]
        $TestVM = $null,

        # Specify if Move-VM should be run with -WhatIf parameter
        [Parameter(Mandatory = $false,
            Position = 4)]
        [switch]$WhatIf
    ) 

    # Check to see if virtual hosts and vSwitch are valid 
    try {
        Get-VMHost $sourcehost -ErrorAction Stop | Out-Null
        Get-VMHost $desthost -ErrorAction Stop | Out-Null
        Get-VirtualSwitch -VMHost $desthost -Name $destswitch -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "One or more of your input values could not be validated. Check SourceHost, DestHost and DestSwitch parameters" -foregroundcolor Red
        exit
    }

    # Get single virtual machine if -TestVM is passed
    if ($TestVM) {
        $vms = get-vm $TestVM # get only one virtual machine is $TestVM is $true
    }
    # Otherwise get all virtual machines on the source host
    else {
        $vms = get-vmhost $sourcehost | get-vm | where-object {$_.Name -notmatch "vCLS"} # get all virtual machines on source host, exclude vCLS on vSphere 7.0
    }

    $manuallymove = @() # create empty array to store virtual machines that need to be manually moved later  

    # If -WhatIf is passed, inform user that What-If has been enabled 
    if ($WhatIf) {Write-Host "*** What-If Mode Enabled ***" -foregroundcolor Yellow}

    # Loop through each virtual machine and migrate the virtual machine if only one NIC is attached 
    foreach ($vm in $vms) {
        $netadap = get-networkadapter $vm # get current vm network adapter 
        $totalnetadap = $netadap | measure-object # get total network adapters on current virtual machine
        $portGroup = get-virtualportgroup -host $desthost -name $netadap.NetworkName -VirtualSwitch $destswitch # stash target port group in variable 

        # if only one network adapter, perform vmotion to target host and vSwitch PG
        if ($totalnetadap.count -lt 2) {
            Write-Host -foregroundcolor Green "Moving $vm to $desthost on switch $destswitch with PG $portGroup"
            move-vm -vm $vm -PortGroup $portGroup -destination $desthost -whatif:$whatIf | Out-Null
            }
        # if more than one network adapter, save vm to variable to report on later
        else {
            Write-Host -foregroundcolor Magenta "$vm has more than one network adapter, move manually."
            $manuallymove += $vm
        }
        if ($WhatIf -eq $false){
            Start-Sleep -seconds 5 # Sleep for 5 seconds between Move-VM if not using -WhatIf
        }
    }

    # If Test-VM is passed, inform the user the test has completed
    if ($testvm) { 
        write-host -foregroundcolor Green "*Test Mode Complete*"
    }
    # If any virtual machines have multiple NICs, report these 
    elseif ($manuallymove) {
        Write-Host -foregroundcolor Magenta "The following virtual machines must be moved manually as they have multiple NICs"
        $manuallymove
    }
    # Otherwise, inform the user that all virtual machines were moved
    else {
        write-host -foregroundcolor Green "All virtual machines were moved off the source host!!"
    }
}