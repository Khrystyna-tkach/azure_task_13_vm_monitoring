$location = "denmarkeast" # any region that is available in your Azure subscription
$resourceGroupName = "mate-azure-task-13"
$networkSecurityGroupName = "defaultnsg"
$virtualNetworkName = "vnet"
$subnetName = "default"
$vnetAddressPrefix = "10.0.0.0/16"
$subnetAddressPrefix = "10.0.0.0/24"
$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = (Get-Content "$HOME\.ssh\mate_azure_task2.pub" -Raw).Trim()
$publicIpAddressName = "linuxboxpip"
$vmName = "matebox"
$vmImage = "Ubuntu2204"
$vmSize = "Standard_B1s"
$dnsLabel = "matetask" + (Get-Random -Count 1) 
$ErrorActionPreference = "Stop"

Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

Write-Host "Creating a network security group $networkSecurityGroupName ..."
$nsgRuleSSH = New-AzNetworkSecurityRuleConfig -Name SSH  -Protocol Tcp -Direction Inbound -Priority 1001 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22 -Access Allow;
$nsgRuleHTTP = New-AzNetworkSecurityRuleConfig -Name HTTP  -Protocol Tcp -Direction Inbound -Priority 1002 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080 -Access Allow;
New-AzNetworkSecurityGroup -Name $networkSecurityGroupName -ResourceGroupName $resourceGroupName -Location $location -SecurityRules $nsgRuleSSH, $nsgRuleHTTP

Write-Host "Creating a virtual network ..."
$subnet = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetAddressPrefix
New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $subnet

Write-Host "Creating a SSH key ..."
New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey

Write-Host "Creating a Public IP Address ..."
New-AzPublicIpAddress -Name $publicIpAddressName -ResourceGroupName $resourceGroupName -Location $location -Sku Standard -AllocationMethod Static -DomainNameLabel $dnsLabel

Write-Host "Creating a VM ..."
# Update the VM deployment command to enable a system-assigned mannaged identity on it. 
$existingVm = Get-AzVM `
    -ResourceGroupName $resourceGroupName `
    -Name $vmName `
    -ErrorAction SilentlyContinue

if (-not $existingVm) {

    # Get network resources
    $vnet = Get-AzVirtualNetwork `
        -ResourceGroupName $resourceGroupName `
        -Name $virtualNetworkName

    $nsg = Get-AzNetworkSecurityGroup `
        -ResourceGroupName $resourceGroupName `
        -Name $networkSecurityGroupName

    $publicIp = Get-AzPublicIpAddress `
        -ResourceGroupName $resourceGroupName `
        -Name $publicIpAddressName

    $subnet = $vnet.Subnets |
        Where-Object { $_.Name -eq $subnetName }

    # Create network interface
    $nic = New-AzNetworkInterface `
        -Name "$vmName-nic" `
        -ResourceGroupName $resourceGroupName `
        -Location $location `
        -SubnetId $subnet.Id `
        -PublicIpAddressId $publicIp.Id `
        -NetworkSecurityGroupId $nsg.Id

    # Create VM configuration with Managed Identity
    $vmConfig = New-AzVMConfig `
        -VMName $vmName `
        -VMSize $vmSize `
        -SecurityType Standard `
        -IdentityType SystemAssigned

    # Configure Linux
    $credential = Get-Credential -UserName "azureuser"

    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Linux `
        -ComputerName $vmName `
        -Credential $credential `
        -DisablePasswordAuthentication

    # Ubuntu 22.04 image
    $vmConfig = Set-AzVMSourceImage `
        -VM $vmConfig `
        -PublisherName "Canonical" `
        -Offer "0001-com-ubuntu-server-jammy" `
        -Skus "22_04-lts-gen2" `
        -Version "latest"

    # Configure OS disk
    $vmConfig = Set-AzVMOSDisk `
        -VM $vmConfig `
        -Name "$vmName-osdisk" `
        -CreateOption FromImage `
        -StorageAccountType Standard_LRS `
        -Linux

    # Configure SSH key
    $vmConfig = Add-AzVMSshPublicKey `
        -VM $vmConfig `
        -KeyData $sshKeyPublicKey `
        -Path "/home/azureuser/.ssh/authorized_keys"

    # Attach network interface
    $vmConfig = Add-AzVMNetworkInterface `
        -VM $vmConfig `
        -Id $nic.Id

    # Deploy VM
    New-AzVM `
        -ResourceGroupName $resourceGroupName `
        -Location $location `
        -VM $vmConfig `
        -ErrorAction Stop
}
else {
    Write-Host "VM already exists. Checking identity..."

    if ($existingVm.Identity.Type -notmatch "SystemAssigned") {
        Update-AzVM `
            -ResourceGroupName $resourceGroupName `
            -VM $existingVm `
            -IdentityType SystemAssigned `
            -ErrorAction Stop
    }
}

Write-Host "Installing the TODO web app..."
$Params = @{
    ResourceGroupName  = $resourceGroupName
    VMName             = $vmName
    Location           = $location
    Name               = 'CustomScript'
    Publisher          = 'Microsoft.Azure.Extensions'
    ExtensionType      = 'CustomScript'
    TypeHandlerVersion = '2.1'
    Settings          = @{fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_13_vm_monitoring/main/install-app.sh'); commandToExecute = 'bash install-app.sh'}
}
Set-AzVMExtension @Params

# Install Azure Monitor Agent VM extention -> 

$monitorParams = @{
    ResourceGroupName = $resourceGroupName
    VMName = $vmName
    Location = $location
    Name = 'AzureMonitorLinuxAgent'
    Publisher = 'Microsoft.Azure.Monitor'
    ExtensionType = 'AzureMonitorLinuxAgent'
    TypeHandlerVersion = '1.0'
    EnableAutomaticUpgrade = $true
}

Set-AzVMExtension @monitorParams
