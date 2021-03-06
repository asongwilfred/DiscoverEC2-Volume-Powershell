# List the Windows disks 
 
function Get-EC2InstanceMetadata { 
  param([string]$Path) 
  (Invoke-WebRequest -Uri "http://169.254.169.254/latest/$Path").Content  
} 
 
function Convert-SCSITargetIdToDeviceName { 
  param([int]$SCSITargetId) 
  If ($SCSITargetId -eq 0) { 
    return "sda1" 
  } 
  $deviceName = "xvd" 
  If ($SCSITargetId -gt 25) { 
    $deviceName += [char](0x60 + [int]($SCSITargetId / 26)) 
  } 
  $deviceName += [char](0x61 + $SCSITargetId % 26) 
  return $deviceName 
} 
 
Try { 
  $InstanceId = Get-EC2InstanceMetadata "meta-data/instance-id" 
  $AZ = Get-EC2InstanceMetadata "meta-data/placement/availability-zone" 
  $Region = $AZ.Remove($AZ.Length - 1) 
  $BlockDeviceMappings = (Get-EC2Instance -Region $Region -Instance $InstanceId).Instances.BlockDeviceMappings 
  $VirtualDeviceMap = @{} 
  (Get-EC2InstanceMetadata "meta-data/block-device-mapping").Split("`n") | ForEach-Object { 
    $VirtualDevice = $_ 
    $BlockDeviceName = Get-EC2InstanceMetadata "meta-data/block-device-mapping/$VirtualDevice" 
    $VirtualDeviceMap[$BlockDeviceName] = $VirtualDevice 
    $VirtualDeviceMap[$VirtualDevice] = $BlockDeviceName 
  } 
} 
Catch { 
  Write-Host "Could not access the AWS API, therefore, VolumeId is not available.  
Verify that you provided your access keys." -ForegroundColor Yellow 
} 
 
Get-disk | ForEach-Object { 
  $DriveLetter = $null 
  $VolumeName = $null 
 
  $DiskDrive = $_ 
  $Disk = $_.Number 
  $Partitions = $_.NumberOfPartitions 
  $EbsVolumeID = $_.SerialNumber -replace "_[^ ]*$" -replace "vol", "vol-" 
  Get-Partition -DiskId $_.Path | ForEach-Object { 
    if ($_.DriveLetter -ne "") { 
      $DriveLetter = $_.DriveLetter 
      $VolumeName = (Get-PSDrive | Where-Object {$_.Name -eq $DriveLetter}).Description 
    } 
  }  
 
  If ($DiskDrive.path -like "*PROD_PVDISK*") { 
    $BlockDeviceName = Convert-SCSITargetIdToDeviceName((Get-WmiObject -Class Win32_Diskdrive | Where-Object {$_.DeviceID -eq ("\\.\PHYSICALDRIVE" + $DiskDrive.Number) }).SCSITargetId) 
    $BlockDeviceName = "/dev/" + $BlockDeviceName 
    $BlockDevice = $BlockDeviceMappings | Where-Object { $BlockDeviceName -like "*"+$_.DeviceName+"*" } 
    $EbsVolumeID = $BlockDevice.Ebs.VolumeId  
    $VirtualDevice = If ($VirtualDeviceMap.ContainsKey($BlockDeviceName)) { $VirtualDeviceMap[$BlockDeviceName] } Else { $null } 
  } 
  ElseIf ($DiskDrive.path -like "*PROD_AMAZON_EC2_NVME*") { 
    $BlockDeviceName = Get-EC2InstanceMetadata "meta-data/block-device-mapping/ephemeral$((Get-WmiObject -Class Win32_Diskdrive | Where-Object {$_.DeviceID -eq ("\\.\PHYSICALDRIVE"+$DiskDrive.Number) }).SCSIPort - 2)" 
    $BlockDevice = $null 
    $VirtualDevice = If ($VirtualDeviceMap.ContainsKey($BlockDeviceName)) { $VirtualDeviceMap[$BlockDeviceName] } Else { $null } 
  } 
  ElseIf ($DiskDrive.path -like "*PROD_AMAZON*") { 
    $BlockDevice = "" 
    $BlockDeviceName = ($BlockDeviceMappings | Where-Object {$_.ebs.VolumeId -eq $EbsVolumeID}).DeviceName 
    $VirtualDevice = $null 
  } 
  Else { 
    $BlockDeviceName = $null 
    $BlockDevice = $null 
    $VirtualDevice = $null 
  } 
  New-Object PSObject -Property @{ 
    Disk          = $Disk; 
    Partitions    = $Partitions; 
    DriveLetter   = If ($DriveLetter -eq $null) { "N/A" } Else { $DriveLetter }; 
    EbsVolumeId   = If ($EbsVolumeID -eq $null) { "N/A" } Else { $EbsVolumeID }; 
    Device        = If ($BlockDeviceName -eq $null) { "N/A" } Else { $BlockDeviceName }; 
    VirtualDevice = If ($VirtualDevice -eq $null) { "N/A" } Else { $VirtualDevice }; 
    VolumeName    = If ($VolumeName -eq $null) { "N/A" } Else { $VolumeName }; 
  } 
} | Sort-Object Disk | Format-Table -AutoSize -Property Disk, Partitions, DriveLetter, EbsVolumeId, Device, VirtualDevice, VolumeName 
