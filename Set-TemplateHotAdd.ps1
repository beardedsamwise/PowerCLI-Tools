# Get all templates from all connected vCenter Servers, modify if your scope is different
$virtualTemplates = get-template 

# The following loop will convert the template to a virtual machine, then change the Hot Add config to the 
# specified values, then convert the virtual machine back to a template.
foreach ($virtualTemplate in $virtualTemplates) {
    set-template -template $virtualTemplate -tovm
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.CpuHotAddEnabled = $false
    $spec.MemoryHotAddEnabled = $true
    $virtualTemplate.ExtensionData.ReconfigVM($spec) 
    $virtualMachine = get-vm $virtualTemplate.Name
    $virtualMachine | Set-VM -totemplate -Confirm:$false
}

# Confirm all templates are configured with correct Hot Add configs with the following command
# get-template | select Name,@{N='HotAddMemory'; E={$_.ExtensionData.Config.MemoryHotAddEnabled}},@{N='HotAddCPU'; E={$_.ExtensionData.Config.CPUHotAddEnabled}}