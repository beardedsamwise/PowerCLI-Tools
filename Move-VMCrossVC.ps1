function Move-VMCrossVC {
    <#
    .Synopsis
    This function will move all virtual machines from one host to another host in different vCenter Servers via Cross vCenter vMotion.
    It is assumed that all dvSwitch Port Proups have identical names on the source and destination virtual switches and datastores and datastore clusters are also identical.
    Folders on the source and destination must be unique to avoid virtual machines being moved to the incorrect folder. 

    If you'd like to move only a single virtual machine specify the -SingleVM parameter and the name of a virtual machine.

    For testing, pass the -WhatIf parameter and the fucntion will enable -WhatIf on the Move-VM task. 
    .EXAMPLE
    Move-VMCrossVC -SourceHost esxi02.test.lab -DestHost esxi03.test.lab -sourcevCenter vc01 -DestvCenter vc02 -DestDVSwitch dswitch
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

        #Specify target vCenter name on destination host 
        [Parameter(Mandatory = $true,
            Position = 2)]
        $SourcevCenter,

        #Specify target vCenter name on destination host 
        [Parameter(Mandatory = $true,
            Position = 3)]
        $DestvCenter,

        #Specify destination dvSwitch name on the destination vCenter Server
        [Parameter(Mandatory = $true,
            Position = 4)]
        $DestDVSwitch,

        #Specify a test virtual machine to migrate instead of all virtual machines
        [Parameter(Mandatory = $false,
            Position = 5)]
        $SingleVM = $null,

        #Specify if Move-VM should be run with -WhatIf parameter
        [Parameter(Mandatory = $false,
            Position = 6)]
        [switch]$WhatIf
    )   
    # Error handling, check that hosts and dvSwitches exist 
    try {
        Get-VMHost $sourcehost -ErrorAction Stop | Out-Null
        $VMHost = Get-VMhost -Name $DestHost -Server $DestvCenter -ErrorAction Stop
        Get-VDSwitch -Name $DestDVSwitch -Server $DestvCenter -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "One or more of your input values could not be validated. Check SourceHost, DestHost and DestDVSwitch parameters" -foregroundcolor Red
        exit
    }
    # Check both vCenter Servers for duplicate folder names
    Write-Host -foregroundcolor Green "Checking if both vCenter Servers have unique VM folder names..."
    $vCenterServers = "$SourcevCenter","$DestvCenter"
    foreach ($server in $vCenterServers) {
        $AllFolders = get-folder -server $server | where-object Type -Match "VM" 
        $UniqueFolders = get-folder -server $server | where-object Type -Match "VM" | select-object -unique
        $Compare = Compare-Object -ReferenceObject $AllFolders -DifferenceObject $UniqueFolders
        If ($null -eq $Compare) {
            write-host "- Duplicate folders not found on $server"
        }
        Else {
            write-host -foregroundcolor Red "Duplicate folders found on $server, exiting..."
            write-host "To avoid virtual machines ending up in the wrong folder, folder names must be unique!"
            exit
        }
    }

    # If a Single Virtual machine is specfied, check that it exists then save it in a variable, otherwise throw error and exit
    # Else, get all virtual machines from the source ESXi host 
    if ($SingleVM) {
        try {
            $vms = get-vmhost $sourcehost | get-vm $SingleVM -ErrorAction Stop # get only one virtual machine is $SingleVM is $true
        }
        catch {
            Write-Host "The test virtual machine $SingleVM was not found on $SourceHost" -foregroundcolor Red
            exit
        }    
    }
    else {
        $vms = get-vmhost $sourcehost | get-vm | where-object {$_.Name -notmatch "vCLS"} # get all virtual machines on source host, exclude vCLS on vSphere 7.0
    }

    # Execute Move-VM for each virtual machine in $vms
    Write-Host -foregroundcolor Green "Beginning Cross vCenter vMotion of virtual machines..."
    foreach ($vm in $vms) {
        $SourceNetworkAdapters = get-networkadapter $vm # get current vm network adapter 
        # Since datastore clusters are unsupported for Cross VC vMotion, get the datastore with the most amount of free space
        # If the virtual machine is not in a datastore cluster, get a single datastore (keeping in mind it may span multiple datastores but we'll only return the main datastore)
        try {
            $DatastoreCluster = get-vm $vm -server $SourcevCenter | get-datastore -server $SourcevCenter | get-datastorecluster -server $SourcevCenter -erroraction stop 
            $Datastore = get-datastorecluster -name $DatastoreCluster.name -server $DestvCenter | get-datastore | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1 
        }
        catch {
            $Datastore = get-vm $vm -server $SourcevCenter | get-datastore -server $SourcevCenter            
        }
        # Migrate the virtual machines!! 
        Write-Host -foregroundcolor Green "Migrating $vm to $desthost on switch $destdvSwitch from $sourcehost"
        # Get the destination port groups for the virtual NICs 
        $DestPortGroups = @()
        foreach ($networkAdapter in $SourceNetworkAdapters) {
            $PortGroup = get-vdportgroup -name $NetworkAdapter.NetworkName -server $DestvCenter -VDSwitch $DestdvSwitch
            Write-Host "Moving"  $networkAdapter.name "from" $networkAdapter.NetworkName "to" $PortGroup
            $DestPortGroups += $PortGroup
        }
        # Execute Move-VM using What-If if specified then move the virtual machine to it's original VM folder location 
        move-vm -vm $vm -NetworkAdapter $SourceNetworkAdapters -PortGroup $DestPortGroups -destination $VMHost -datastore $Datastore -whatif:$whatIf | Out-Null
        if ($WhatIF -eq $false) {
            Write-Host "Moving" $vm.name "to folder:" $vm.Folder.Name
            get-vm $vm.name -server $DestvCenter | move-vm -InventoryLocation $vm.folder.Name | Out-Null
        }
    }
} 