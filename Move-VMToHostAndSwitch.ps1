# This script will move all virtual machines from one host to another, and change the networking from a dvSwitch to a vSwitch
# * Assumptions *
# Port groups have identical names on the source and destination virtual switches
# * Use case * 
# This script was created to assist with moving virtual hosts from one vCenter to another where the dvSwitch must be removed from the ESXi host
# The migration scenario for this script is where the virtual machines cannot be moved from a dvSwitch to a vSwitch on the same host easily 

# VARIABLES #
$testRun = $true # Set to $true to move one virtual machine as a test, $false to move all virtual machines from source to target host
$testVM = "test1" # The test virtual machine used if above variable is $true
$whatIf = $true # Set to $true if you want to execute Move-VM with -WhatIf parameter 
$sourcehost = "esxi03.test.lab" # Source virtual host which all VMs will be vMotioned from 
$targethost = "esxi02.test.lab" # Target virtual host where all VMs will be vMotioned to 
$targetSwitch = "vSwitch0" # The name of the target vSwitch

if ($testRun) {
    $vms = get-vm $testVM # get only one virtual machine is $testRun is $true
}
else {
    $vms = get-vmhost $sourcehost | get-vm | where-object {$_.Name -notmatch "vCLS"} # get all virtual machines on source host, exclude vCLS for vSphere 7.0
}

$manuallymove = @() # create empty array to store virtual machines that need to be manually moved later  

foreach ($vm in $vms) {
    $netadap = get-networkadapter $vm # get current vm network adapter 
    $totalnetadap = $netadap | measure-object # get total network adapters on current virtual machine
    $portGroup = get-virtualportgroup -host $targethost -name $netadap.NetworkName -VirtualSwitch $targetSwitch # stash target port group in variable 

    # if only one network adapter, perform vmotion to target host and vSwitch PG
    if ($totalnetadap.count -lt 2) {
        Write-Host -foregroundcolor Green "Moving $vm to $targethost on switch $targetSwitch with PG $portGroup"
        move-vm -vm $vm -PortGroup $portGroup -destination $targethost -whatif:$whatIf | Out-Null
        }
    # if more than one network adapter, save vm to variable to report on later
    else {
        Write-Host -foregroundcolor Magenta "$vm has more than one network adapter, move manually later..."
        $manuallymove += $vm
    }
    Start-Sleep -seconds 5
}

# return results if any virtual machines have multiple nics and need to be moved manually, if none report all vms have been moved
if ($manuallymove) {
    Write-Host -foregroundcolor Magenta "The following virtual machines must be moved manually as they have multiple NICs"
    $manuallymove
}
else {
    write-host -foregroundcolor Green "All virtual machines were moved off the source host!!"
}