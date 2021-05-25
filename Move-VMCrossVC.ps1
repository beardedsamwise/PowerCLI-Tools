function Move-VMCrossVC {
    <#
    .Synopsis
    This function will move all virtual machines from one host to another host in different vCenter Servers via Cross vCenter vMotion.

    It is assumed that all dvSwitch Port Proups have identical names on the source and destination virtual switches, datastores, 
    datastore clusters and datacenters have identical names. 
    
    Folders on the source and destination must be unique to avoid virtual machines being moved to the incorrect folder, with the 
    exception of folder names being the same over multiple datacenters. The function will check for uniqueness. 

    If you'd like to move only a single virtual machine specify the SingleVM parameter and the name of a virtual machine. This is 
    helpful for testing before you move entire host. 

    For testing, pass the DryRun parameter and the function will pass the WhatIf parameter on the Move-VM task. 
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
        [switch]$DryRun
    )   
    # Error handling, check that hosts and dvSwitches exist 
    try {
        Get-VMHost $sourcehost -ErrorAction Stop | Out-Null
        $VMHost = Get-VMhost -Name $DestHost -Server $DestvCenter -ErrorAction Stop
        Get-VDSwitch -Name $DestDVSwitch -Server $DestvCenter -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "ERROR: One or more of your input values could not be validated." -foregroundcolor Red
        Write-Host $_
        exit
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
        $vms = get-vmhost $sourcehost | get-vm | where-object { $_.Name -notmatch "vCLS" } # get all virtual machines on source host, exclude vCLS on vSphere 7.0
    }

    # Check to see if virtual machines were found
    if ($null -eq $vms) {
        Write-Host -foregroundcolor Red "ERROR: No virtual machines were found with the specified parameters."
        exit
    }
    # Check DataCenters in both vCenter Servers for duplicate folder names
    Write-Host -foregroundcolor Green "Checking if both vCenter Servers have unique VM folder names..."
    $vCenterServers = "$SourcevCenter", "$DestvCenter"
    foreach ($server in $vCenterServers) {
        $dcs = get-datacenter -server $server
        foreach ($dc in $dcs) {
            $AllFolders = get-folder -location (get-datacenter $dc -server $server) | where-object Type -Match "VM" 
            $UniqueFolders = get-folder -location (get-datacenter $dc -server $server) | where-object Type -Match "VM" | select-object -unique
            $Compare = Compare-Object -ReferenceObject $AllFolders -DifferenceObject $UniqueFolders
            If ($null -eq $Compare) {
                write-host "- Duplicate folders not found on $server in $dc"

            }
            Else {
                write-host -foregroundcolor Red "Duplicate folders found on $server in $dc, exiting..."
                write-host "To avoid virtual machines ending up in the wrong folder, folder names must be unique!"
                write-host "Found folders:"
                $AllFolders.parent
                exit
            }
        }
    }

    # Begin moving virtual machines using Move-VM 
    if ($DryRun) { Write-Host -foregroundcolor Magenta "Dry run enabled, passing -WhatIf to Move-VM, no virtual machines will be moved" }
    else { Write-Host -foregroundcolor Green "Beginning Cross vCenter vMotion of virtual machines..." }
    foreach ($vm in $vms) {
        $SourceNetworkAdapters = get-networkadapter $vm # get current vm network adapter 
        # Since datastore clusters are unsupported for Cross VC vMotion, get the datastore with the most amount of free space
        # If the virtual machine is not in a datastore cluster, get a single datastore (keeping in mind it may span multiple datastores but we'll only return the main datastore)
        $numDisks = get-vm $vm -server $SourcevCenter | get-harddisk | measure-object
        if ($numDisks.count -gt 1) {
            # Check if virtual machine has more than one VMDK
            try {
                # Try to get the datastore with the most free space in the datastore cluster
                $DatastoreCluster = get-vm $vm -server $SourcevCenter | get-datastore -server $SourcevCenter | get-datastorecluster -server $SourcevCenter -erroraction stop 
                $Datastore = get-datastorecluster -name $DatastoreCluster.name -server $DestvCenter | get-datastore | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1 
                # TO DO - Sanity check free space on datastore before moving! 
            }
            catch {
                # If a virtual machine has more than one VMDK and there's no datastore clusters, skip virtual machine and begin next loop 
                Write-Host "Moving virtual machine with > 1 VMDK without datastore clusters is risky, skipping virtual machine" $vm.Name -foregroundcolor Red
                Continue
            }
        }
        else {
            # If virtual machine only has one VMDK, we'll get the same datastore that the virtual machine currently resides in 
            $Datastore = get-vm $vm -server $SourcevCenter | get-datastore -server $SourcevCenter
            $Datastore = get-datastore $Datastore.Name -server $DestvCenter            
        }
        # Make sure there is at least 100GB free on the target datastore before migration
        if ($Datastore.FreeSpaceGB - ($vm.MemoryGB + $vm.UsedSpaceGB) -lt 100) {
            Write-Host "Not enough free space on target datastore" $Datastore.name", there must be a minimum of 100GB free space after the migration" -ForegroundColor Red
            Write-Host "Skipping virtual machine:" $vm.Name -ForegroundColor Red
            Continue
        }
        # Migrate the virtual machines!! 
        Write-Host -foregroundcolor Green "Migrating $vm to $desthost on switch $destdvSwitch from $sourcehost"
        # Get the destination port groups for the virtual NICs 
        $DestPortGroups = @()
        foreach ($networkAdapter in $SourceNetworkAdapters) {
            $PortGroup = get-vdportgroup -name $NetworkAdapter.NetworkName -server $DestvCenter -VDSwitch $DestdvSwitch
            Write-Host "- Moving"  $networkAdapter.name "from" $networkAdapter.NetworkName "to" $PortGroup
            $DestPortGroups += $PortGroup
        }
        # Execute Move-VM using What-If if DryRun specified then move the virtual machine to it's original VM folder location 
        # Includes handling for multiple DataCenters where folders may have the same names (ie. Production in DC1 and Production in DC2)
        move-vm -vm $vm -NetworkAdapter $SourceNetworkAdapters -PortGroup $DestPortGroups -destination $VMHost -datastore $Datastore -whatif:$DryRun | Out-Null
        if ($DryRun -eq $false) {
            $vmfolder = get-vm $vm.name -server $DestvCenter | get-datacenter -server $DestvCenter | get-folder $vm.folder.Name
            $datacenter = get-vm $vm.name -server $DestvCenter | get-datacenter
            Write-Host "- Moving" $vm.name "to folder in DC:" $vm.Folder.Name "in" $datacenter.Name
            get-vm $vm.name -server $DestvCenter | move-vm -InventoryLocation $vmfolder | Out-Null
        }
    }
} 