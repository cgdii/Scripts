<#
.SYNOPSIS
This script will import a CSV File and based on the content will create SQL Instance installation files.  Upon completion it will copy the SQL installation files to all other nodes of the cluster.

.DESCRIPTION
Written by Carl Davis
Final Version 4/11/2018

This script will take a CSV file with the headers Purpose, LunID, PartName, DriveLetter, SQLInstance, IP, MASK, NAME, Node, DomGroup, SQLPort and mount the LUNS given by the storage team with the names specified.  The format of each row is:

	Purpose = Valid values are Disk, Cluster, SQLInstance
	Lun = Lun ID as given by PowerPath (ex. 394 or 0B7E)
	PartName = Name of the Partition (ex. LOS19_ROOT)  Name must begin with SQL Instance name and Witness Disk must be named "Witness".  Root Drive must have the word Root in the Partition Name.
	DriveLetter = Drive it will be mounted as or under ( ex. R: )
	SQLInstance = The name of the SQL Instance using the storage or config information
	IP = IP Address to be assigned to Cluster Group or SQL Instance
	MASK = Subnet Mask of Network
	NAME = DNS Name of SQL Cluster Group or SQL Instance (i.e. DWPPIMGSQL-VN01)
	Node = Names of physical servers in cluster (only used for Cluster config)
	DomGroup = Active Directory Domain Group SQL Service account is a member of (i.e. EC\Production SQL Services)
	SQLPort = TCP Port SQL Instance will listen on.
	SQLDNSAlias = DNS CNAME entry for SQL Prod/DR Instance.  Used to make sure SPNs are set corectly in AD.

It will also rename all Cluster Storage Resources the same as the partition names.
Requirements:
	- You must give it the path of the CSV File you are importing.
	- You must run PowerShell as Administrator
	- You must run this script within the SQL Installattion Files directory

.PARAMETER ConfigFile
Mandatory - The path and filename of the CSV file containing configuration parameters

.PARAMETER SingleNode
Optional - Will install SQL on local node only and not in an MS cluster.

.EXAMPLE
./Create-SQLInstallAG_lcldisk_W2012_SQL2012-anon.ps1 -ConfigFile "D:\Software\SQL 2012 Enterpise Core SP1\dwppimgsql01_02-DiskCreate.csv"

.OUTPUTS
Upon completion of this script three new PowerShell scripts will be created for each SQL Instance defined in the Config File:

	- <SQLInstanceName>_SQL2k12_Node_Install.ps1 - Will install the SQL Instance unattended on the first node of the cluster.  It will also move the AD Cluster Resource object to the same AD OU as the physical server the script is run on.
	- <SQLInstanceName>_SQL2k12_Node_ConfigFile.ini - Contains all of teh configuration settings to install the SQL Instance unattended on the first node of the cluster.  
	- <SQLInstanceName>_SQL2k12_RemoveNode_Uninstall.ps1 - Will uninstall the SQL Instance unattended on any cluster node.  If the SQL Instance doesn't exist on any other node of the cluster, it will remove it entirely.  Shared SQL Components will remain.
#>


param(
	[Parameter(Mandatory=$true)]
    [string]$ConfigFile
	)

$HeartbeatNetwork = "" # First 2 octets of heartbeat network - not required
$BackupNetwork = "" # First 2 octets of backup network - not required
$dotnet35installdir = "" #Path to .NET 3.5 installation files - required
$ErrorActionPreference = "SilentlyContinue"

$SQLInstanceInstallSourceDir = (Get-Location).Path
$DateStamp = get-date -uformat "%m-%d-%Y_%H-%M-%S"
$LogFile = "$SQLInstanceInstallSourceDir\Create-SQLInstallOnly_W2k8_SQL2k12_$DateStamp.log"

If (Test-Path "D:\"){#
		$ProgramDirDrive = "D:"
		}
Else{$ProgramDirDrive = "C:"}

Add-Content "Info: Beginning Create-SQLInstallVMOnly_W2k8_SQL2k12.ps1 script - $LogDir - $DateStamp" -Path $LogFile

#Gather system info

#region This Section will grab the DOmain Controller the system is currently using (not the user).  This prevents LDAP and AD functions later in teh script from using another DC. 

$ADDomain = (gwmi WIN32_ComputerSystem).Domain
$ADDomainDesc = $ADDomain.split(".")[0]
$LogonServer = (Get-WmiObject Win32_ntdomain | Where-Object { $_.DomainName -eq $ADDomainDesc } ).DomainControllerName.trimstart("\\")
$LDAPDomainBegin = "LDAP://" + $LogonServer + ":389/dc="
$LDAPDomainCount = $ADDomain.split(".").count 
$LDAPDomainEnd = $null 
$i = 0 
do { 
	If ($i -lt ($LDAPDomainCount - 1)) {$LDAPDomainEnd += ($ADDomain.split("."))[$i] + ",dc=" } 
	Else {$LDAPDomainEnd += ($ADDomain.split("."))[$i] } 
	$i++} 
until ( $i -ge $LDAPDomainCount) 

$LDAPDomain = $LDAPDomainBegin + $LDAPDomainEnd 

#endregion

#region Gather system details and pipe to log file
$SystemCPU = Get-WmiObject -Class win32_computersystem | select NumberOfProcessors, NumberOfLogicalProcessors
$SystemProcs = Get-WmiObject -Class win32_processor | Select-Object -first 1 | select NumberOfCores,NumberOfLogicalProcessors
$SystemHardware = Get-WmiObject -Class Win32_ComputerSystem

$SystemInfo = @()
$SystemInfo = "" | Select Manufacturer,Model,SystemName,RAMGB,NumberOfProcessors,NumberOfLogicalProcessors,NumberOfCores,Hyperthreading
$SystemInfo.Manufacturer = $SystemHardware.Manufacturer
$SystemInfo.Model = $SystemHardware.Model
$SystemInfo.SystemName = $SystemHardware.Name
$SystemInfo.RAMGB =  [math]::Round( $SystemHardware.TotalPhysicalMemory / 1GB ,1 ) 
$SystemInfo.NumberOfProcessors = $SystemCPU.NumberOfProcessors
$SystemInfo.NumberOfLogicalProcessors = $SystemCPU.NumberOfLogicalProcessors
$SystemInfo.NumberOfCores = $SystemProcs.NumberOfCores
If ($SystemInfo.NumberOfCores -eq $SystemInfo.NumberOfLogicalProcessors){#
	$SystemInfo.Hyperthreading = "Disabled" }
Else { $SystemInfo.Hyperthreading = "Enabled" }

Add-Content "Info: System Information" -Path $LogFile
($SystemInfo | Format-List) | Out-File -Append $LogFile -Encoding UTF8
#endregion 

#This function will partition and mount the SAN LUNs specified in the CSV File
Function Mount-Drives(){#
	$LunMapDrives = @()
	$LunMapDrives = $LunMappings | where { $_.Purpose -eq 'Disk' }
	$LunMapTable = @()

	$LunMapTable = $LunMapDrives | Sort-Object DriveLetter, PartName -Descending


	# Error handling if Partition already exists

	$volumes = gwmi Win32_volume | where {$_.BootVolume -ne $True -and $_.SystemVolume -ne $True -and $_.DriveType -eq "3"}

	Set-StorageSetting –NewDiskPolicy OfflineShared

	#Grab the Root Mountpoints
	$RootDrives = @()
	$RootDrives = $LunMapTable | Where-Object { $_.PartName -like "*_rmp*" -or $_.PartName -like "*_root*" -or $_.PartName -like "*_root*" -or $_.PartName -like "*Quorum*" -or $_.PartName -like "*Witness*"  } | Sort-Object PartName
	Foreach ( $RootDrive in $RootDrives ){#
		$MountName = $RootDrive.Driveletter
		If (!($MountName)){#
				Write-host "There is a missing drive letter or Mountpoint in the CSV.  Exiting script." -ForegroundColor Yellow 
				Add-Content "Error: There is a missing drive letter or Mountpoint in the CSV.  Exiting script." -Path $LogFile
			}
		$Drivenumber = $RootDrive.Disk
		$RootName = $RootDrive.SQLInstance
		$Label = $RootDrive.PartName
		$VolumeExists = $volumes | where { $_.Label -eq $Label}
		If ($VolumeExists -eq $null){#
			Write-Host "Initializing Disk $Drivenumber Partition name  $Label" -ForegroundColor Green
			Initialize-Disk $Drivenumber –PartitionStyle MBR
			If (!($SkipCleanDisk)) {
				Write-Host "Clearing all data on disk $Drivenumber Partition name $Label." -ForegroundColor Green
				Clear-Disk -Number $Drivenumber -RemoveData -confirm:$false
				Write-Host "Bringing Disk $Drivenumber Partition name $Label Online" -ForegroundColor Green
				Set-Disk -Number $Drivenumber -IsOffline $False
				Set-Disk $Drivenumber -IsReadonly $False
				Initialize-Disk $Drivenumber –PartitionStyle MBR
				Write-Host "Creating partition on Disk $Drivenumber Partition name $Label Online" -ForegroundColor Green
				$Partition = New-Partition -DiskNumber $Drivenumber -UseMaximumSize -DriveLetter $($MountName.replace(":",""))
				Sleep 3
				Write-Host "Formatting partition on Disk $Drivenumber Partition name $Label" -ForegroundColor Green
				$Partition | Format-Volume -AllocationUnitSize 65536 -FileSystem NTFS -Force -NewFileSystemLabel $Label -Confirm:$false 
				$IsFormatted = get-Volume -DriveLetter $($MountName.Replace(":",""))
				If (!($IsFormatted)){#
					Write-Host "Error creating partition $Label" -ForegroundColor Red
					#Add-Content "Error: Error creating $Label" -Path $LogFile
					break
					}
				}
			Else{# Do not alter the disk if it contains data

			}
		Else{#
			Write-Host "$Label Volume already exists" -ForegroundColor Red
			#Add-Content "Warning: $Label Volume already exists" -Path $LogFile
			}
		If ($MountName -eq 'W:' -or $MountName -eq 'Q:'){ $RootName = $null }
		$MountPointvolumes = @()
		If ($RootName){$MountPointvolumes = $LunMapTable | Where-Object { $_.SQLInstance -ieq $RootName -and $_.PartName -ne $Label} -ErrorAction SilentlyContinue}
		If ( $MountPointvolumes -ne $null ){#
			ForEach ( $MountPointvolume in $MountPointvolumes ) {#

					$MountPointName = $MountPointvolume.PartName
					$MountPoint = $MountName + "\" + $MountPointName

				If ( $MountPointvolume.Name -ne $MountPoint ){#

					If (!(test-path $MountPoint)){
						Write-Host "Creating mountpoint folder on Disk $Drivenumber Partition name $Label as $MountPoint" -ForegroundColor Green
						New-Item $MountPoint -type directory
						sleep 3
						}
					If ( Test-Path $MountPoint ){#
						$DiskSize = $MountPointvolume.CapacityGB
						$Drivenumber = $MountPointvolume.Disk
						$RootName = $MountPointvolume.SQLInstance
						$Label = $MountPointvolume.PartName
						$VolumeExists = $volumes | where { $_.Label -eq $Label}
						If ($VolumeExists -eq $null){#
							Write-Host "Initializing Disk $Drivenumber Partition name  $Label" -ForegroundColor Green
							If (!($SkipCleanDisk)) {
								Write-Host "Clearing all data on disk $Drivenumber Partition name $Label.  If this is a large volume, this might take a few minutes.  Please stand by...." -ForegroundColor Green
								Clear-Disk -Number $Drivenumber -RemoveData -confirm:$false
								}
							Write-Host "Bringing Disk $Drivenumber Partition name $Label Online" -ForegroundColor Green
							Set-Disk -Number $Drivenumber -IsOffline $False
							Set-Disk $Drivenumber -IsReadonly $False
							If ( $DiskSize -lt "2048" ){# 
								Write-Host "Initializing Disk $Drivenumber Partition name $Label as type MBR" -ForegroundColor Green
								Initialize-Disk $Drivenumber –PartitionStyle MBR
								}
							Else{#
								Write-Host "Initializing Disk $Drivenumber Partition name $Label as type GPT" -ForegroundColor Green
								Initialize-Disk $Drivenumber –PartitionStyle GPT
								}
							Write-Host "Creating partition on Disk $Drivenumber Partition name $Label Online" -ForegroundColor Green
							$Partition = New-Partition -DiskNumber $Drivenumber -UseMaximumSize 
							Sleep 3
							Write-Host "Creating mountpoint for disk $Drivenumber as $MountPoint" -ForegroundColor Green
							Add-PartitionAccessPath -DiskNumber $Drivenumber -PartitionNumber 1 -AccessPath $MountPoint
							Write-Host "Formatting partition on Disk $Drivenumber Partition name $Label" -ForegroundColor Green
							$Partition | Format-Volume -AllocationUnitSize 65536 -FileSystem NTFS -Force -NewFileSystemLabel $Label -Confirm:$false 
								}
							Else{#
								Write-Host "$Label Volume already exists" -ForegroundColor Red
								#Add-Content "Warning: $Label Volume already exists" -Path $LogFile
								}
						}
					Else{#
						Write-Host "Error creating $MountPoint" -ForegroundColor Red
						#Add-Content "Error: Error creating $MountPoint" -Path $LogFile
						}
					}
				}
			}
			$MountName = $null
		}
	}
}

#This function will create the cluster on the nodes specified in the CSV File
Function Create-Cluster(){#
	# If a Cluster does not already exist, check the CSV file for Cluster params (i.e. Purpose = Cluster).  If no entries, break out of script.
	$ClusterParams = $LunMappings | where { $_.Purpose -eq 'Cluster' }
	If ($ClusterParams){#
		$ClusterMembers = @()

		$ClusterName = $ClusterParams.Name
		If ( $ClusterName.length -gt 15 ){# Cluster name is too long
			Write-Host "Cluster name $ClusterName is more than 15 characters long.  Please create a new name and rerun this script to complete the configuration." -ForegroundColor Yellow
			Add-Content "Error: Cluster name $ClusterName is more than 15 characters long.  Please create a new name and rerun this script to complete the configuration." -Path $LogFile
			break
				}
		$ClusterNodes = $ClusterParams.Node
		$ClusterIP = $ClusterParams.IP
		$ClusterMembers = $ClusterNodes.split(",")
		$ClusterMembers = $ClusterMembers.trim()

		#Determine OU Location for Cluster Object
		$root = New-Object System.DirectoryServices.DirectoryEntry ($LDAPDomain) 
	    $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)  
	    $searcher.Filter = "(&(objectCategory=computer)(objectClass=computer)(samAccountName=$($env:ComputerName)$))"  
	    $CurrentComputerObject = $searcher.FindOne()  
	    $TexttobeReplaced = $env:ComputerName
	    $CurrentComputerPath = [string]($CurrentComputerObject.Properties.adspath)  
	    $CurrentComputerPath = $CurrentComputerPath.replace($TexttobeReplaced, $ClusterName)  
		$CurrentComputerPath = $CurrentComputerPath.Substring($CurrentComputerPath.lastindexof("/")+1,($CurrentComputerPath.Length - ($CurrentComputerPath.lastindexof("/")+1)))

	If ($TestCluster){#
		$ClusterTests = Test-Cluster -Node $ClusterMembers 

		# If there are any failed items in the Cluster test results, launch the report and break out of the script, otherwise continue.
		$ClusterTestResults = get-content $ClusterTests.FullName

		If ($ClusterTestResults -imatch 'failed') { #
			Write-Host "Please resolve Cluster issues and rerun this script to complete the configuration." -ForegroundColor Yellow
			Add-Content "Error: Please resolve Cluster issues and rerun this script to complete the configuration. Results location is $($ClusterTests.FullName)" -Path $LogFile
			Invoke-Item $ClusterTests.FullName
			break
			}
		}
		# Create the cluster based on items in CSV file.  NOTE - Witness disk is added later.
		New-Cluster -Name $CurrentComputerPath -Node $ClusterMembers -NoStorage -StaticAddress $ClusterIP
		}
	Else {$
			Write-Host "No Cluster exists on this system and no Cluster Parameters in config file.  Exiting script..." -ForegroundColor Red
			Add-Content "Error: No Cluster exists on this system and no Cluster Parameters in config file.  Exiting script..." -Path $LogFile
			Break}
		}

#Since the DBA team may run the SQL install scripts and they have no rights in AD, Pre-create the AD Objects and give them full control of them.  Also grant the Cluster COmputer object full control of the SQL Network Name computer object.
Function Create-SQLADObjects(){#

	$SQLClusterParams = @()
	$SQLClusterParams = $LunMappings | where { $_.Purpose -eq 'SQLInstance' }
	$SQLClusterName = (get-cluster).name

	Foreach ($SQLClusterParam in $SQLClusterParams){#
		$SQLInstanceDNSName = $SQLClusterParam.NAME
		$SQLInstanceName = $SQLClusterParam.SQLInstance
		Create-ADComputerObject $SQLInstanceDNSName $SQLClusterName "SQL Cluster Virtual Object for $SQLInstanceName running on $SQLClusterName"
	}

}

# Creates the SQL Install scripts based on data in the CSV File
Function Create-SQLUnattendedScripts(){#
	$SQLClusterParams = @()
	$SQLClusterParams = $LunMappings | where { $_.Purpose -eq 'SQLInstance' }

	Foreach ($SQLClusterParam in $SQLClusterParams){#
		$SQLInstanceName = $SQLClusterParam.SQLInstance.trim()
		If (!($SQLInstanceName)){# SQL Instance name does not exist in the CSV File
			Add-Content "Error: SQL Instance name does not exist in the CSV File.  Exiting script..." -Path $LogFile
			Write-Host "Error: SQL Instance name does not exist in the CSV File.  Exiting script..." -ForegroundColor Yellow
			Break
			}
		$SQLInstanceDisks = ($LunMappings | where { $_.PartName -like "*_rmp*" -or $_.PartName -like "*_root*" } | where {$_.SQLInstance -eq $SQLInstanceName }).PartName.trim()
		$SQLInstanceIP = $SQLClusterParam.IP
		If (!($SQLInstanceIP)){# SQL Instance IP does not exist in the CSV File
			Add-Content "Error: SQL Instance IP does not exist in the CSV File.  Exiting script..." -Path $LogFile
			Write-Host "Error: SQL Instance IP does not exist in the CSV File.  Exiting script..." -ForegroundColor Yellow
			Break
			}
		$SQLInstanceMask = $SQLClusterParam.MASK
		If (!($SQLInstanceMask)){# SQL Instance Subnet Mask does not exist in the CSV File
			Add-Content "Error: SQL Instance Subnet Mask does not exist in the CSV File.  Exiting script..." -Path $LogFile
			Write-Host "Error: SQL Instance Subnet Mask does not exist in the CSV File.  Exiting script..." -ForegroundColor Yellow
			Break
			}
		$SQLInstanceDomGroup = $SQLClusterParam.DomGroup
		If (!($SQLInstanceDomGroup)){# SQL Instance Domain Group does not exist in the CSV File
			Add-Content "Error: SQL Instance Domain Group does not exist in the CSV File.  Exiting script..." -Path $LogFile
			Write-Host "Error: SQL Instance Domain Group does not exist in the CSV File.  Exiting script..." -ForegroundColor Yellow
			Break
			}
		$SQLInstanceRootDrive = ($LunMappings | where { $_.PartName -like "*_rmp*" -or $_.PartName -like "*_root*" } | where {$_.SQLInstance -eq $SQLInstanceName }).DriveLetter
		$SQLInstanceSysDB = $SQLInstanceRootDrive + "\" + ($LunMappings | where { ($_.PartName.trim() -like "*SysDB*" -or $_.PartName.trim() -like "*SystemDB*") -and $_.SQLInstance.trim() -eq $SQLInstanceName }).PartName.trim() + "\SQLData\System"
		$SQLInstanceBackupDir = $SQLInstanceRootDrive + "\" + ($LunMappings | where { $_.PartName.trim() -like "*Backup*" -and $_.SQLInstance.trim() -eq $SQLInstanceName } | Sort-Object PartName | Select-Object -First 1 ).PartName.trim() + "\SQLBackup"
		$SQLInstanceUserDBDir = $SQLInstanceRootDrive + "\" + ($LunMappings | where { $_.PartName.trim() -like "*_Data_01*" -and $_.SQLInstance.trim() -eq $SQLInstanceName } | Sort-Object PartName | Select-Object -First 1 ).PartName.trim() + "\SQLData\User"
		$SQLInstanceTransLogDir = $SQLInstanceRootDrive + "\" + ($LunMappings | where { $_.PartName.trim() -like "*_Log_01*" -and $_.SQLInstance.trim() -eq $SQLInstanceName } | Sort-Object PartName | Select-Object -First 1 ).PartName.trim() + "\SQLLog\User"
		$SQLInstanceTempDBDir = $SQLInstanceRootDrive + "\" + ($LunMappings | where { $_.PartName.trim() -like "*_TempDB*" -and $_.SQLInstance.trim() -eq $SQLInstanceName }  | Sort-Object PartName | Select-Object -First 1 ).PartName.trim() + "\SQLLog\System"
		$SQLInstancePort = $SQLClusterParam.SQLPort.trim()
		If (!($SQLInstancePort)){# SQL Instance Port does not exist in the CSV File
			Add-Content "Error: SQL Instance Port does not exist in the CSV File.  Exiting script..." -Path $LogFile
			Write-Host "Error: SQL Instance Port does not exist in the CSV File.  Exiting script..." -ForegroundColor Yellow
			Break
			}
		$SQLDNSAlias = $env:COMPUTERNAME

		$SQLInstanceTempLogDir = $SQLInstanceRootDrive + "\" + ($LunMappings | where { $_.PartName.trim() -like "*_TempDB*" -and $_.SQLInstance.trim() -eq $SQLInstanceName }  | Sort-Object PartName | Select-Object -First 1 ).PartName.trim() + "\SQLData\System"
		$SQLInstanceBackupDataDir = $SQLInstanceBackupDir + "\SQLBackup\Data"
		$SQLInstanceBackupLogDir = $SQLInstanceBackupDir + "\SQLBackup\Logs"
		If (!(test-path $SQLInstanceUserDBDir)) { New-Item -ItemType directory -Path $SQLInstanceUserDBDir }
		If (!(test-path $SQLInstanceTransLogDir)) { New-Item -ItemType directory -Path $SQLInstanceTransLogDir }
		If (!(test-path $SQLInstanceTempLogDir)) { New-Item -ItemType directory -Path $SQLInstanceTempDBDir	}
		If (!(test-path $SQLInstanceTempLogDir)) { New-Item -ItemType directory -Path $SQLInstanceTempLogDir }
		If (!(test-path $SQLInstanceBackupDataDir)) { New-Item -ItemType directory -Path $SQLInstanceBackupDataDir }
		If (!(test-path $SQLInstanceBackupLogDir)) { New-Item -ItemType directory -Path $SQLInstanceBackupLogDir }
		
		Write-Host "Creating SQL install files for $SQLInstanceName" -ForegroundColor Green

		#Create First Node Config File
		$SQLFirstInstanceCfgFile = @()
		$SQLFirstInstanceCfgFile = @"
;SQL Server 2012 Configuration File `r
[OPTIONS] `r
 `r
; Specifies a Setup work flow, like INSTALL, UNINSTALL, or UPGRADE. This is a required parameter.  `r
 `r
ACTION=`"Install`" `r
 `r
; Detailed help for command line argument ENU has not been defined yet.  `r
 `r
ENU=`"True`" `r
 `r
; Parameter that controls the user interface behavior. Valid values are Normal for the full UI,AutoAdvance for a simplied UI, and EnableUIOnServerCore for bypassing Server Core setup GUI block.  `r
 `r
;UIMODE=`"Normal`" `r
 `r
; Setup will not display any user interface.  `r
 `r
QUIET=`"False`" `r
 `r
; Setup will display progress only, without any user interaction.  `r
 `r
QUIETSIMPLE=`"False`" `r
 `r
; Specify whether SQL Server Setup should discover and include product updates. The valid values are True and False or 1 and 0. By default SQL Server Setup will include updates that are found.  `r
 `r
UpdateEnabled=`"True`" `r
 `r
; Specifies features to install, uninstall, or upgrade. The list of top-level features include SQL, AS, RS, IS, MDS, and Tools. The SQL feature will install the Database Engine, Replication, Full-Text, and Data Quality Services (DQS) server. The Tools feature will install Management Tools, Books online components, SQL Server Data Tools, and other shared components.  `r
 `r
FEATURES=SQLENGINE,FULLTEXT,IS,BC,ADV_SSMS `r
 `r
; Specify the location where SQL Server Setup will obtain product updates. The valid values are `"MU`" to search Microsoft Update, a valid folder path, a relative path such as .\MyUpdates or a UNC share. By default SQL Server Setup will search Microsoft Update or a Windows Update service through the Window Server Update Services.  `r
 `r
UpdateSource=`"$SQLInstanceInstallSourceDir\PCUSource`" `r
 `r
; Displays the command line parameters usage  `r
 `r
HELP=`"False`" `r
 `r
; Specifies that the detailed Setup log should be piped to the console.  `r
 `r
INDICATEPROGRESS=`"False`" `r
 `r
; Specifies that Setup should install into WOW64. This command line argument is not supported on an IA64 or a 32-bit system.  `r
 `r
X86=`"False`" `r
 `r
; Specify the root installation directory for shared components.  This directory remains unchanged after shared components are already installed.  `r
 `r
INSTALLSHAREDDIR=`"$ProgramDirDrive\Program Files\Microsoft SQL Server`" `r
 `r
; Specify the root installation directory for the WOW64 shared components.  This directory remains unchanged after WOW64 shared components are already installed.  `r
 `r
INSTALLSHAREDWOWDIR=`"$ProgramDirDrive\Program Files (x86)\Microsoft SQL Server`" `r
 `r
; Specify a default or named instance. MSSQLSERVER is the default instance for non-Express editions and SQLExpress for Express editions. This parameter is required when installing the SQL Server Database Engine (SQL), Analysis Services (AS), or Reporting Services (RS).  `r
 `r
INSTANCENAME=$SQLInstanceName `r
 `r
; Specify the Instance ID for the SQL Server features you have specified. SQL Server directory structure, registry structure, and service names will incorporate the instance ID of the SQL Server instance.  `r
 `r
INSTANCEID=$SQLInstanceName `r
 `r
; Specify that SQL Server feature usage data can be collected and sent to Microsoft. Specify 1 or True to enable and 0 or False to disable this feature.  `r
 `r
SQMREPORTING=`"False`" `r
 `r
; Specify if errors can be reported to Microsoft to improve future SQL Server releases. Specify 1 or True to enable and 0 or False to disable this feature.  `r
 `r
ERRORREPORTING=`"False`" `r
 `r
; Specify the installation directory.  `r
 `r
INSTANCEDIR=`"$ProgramDirDrive\Program Files\Microsoft SQL Server`" `r
 `r
; Specifies a cluster shared disk to associate with the SQL Server failover cluster instance.  `r
 `r
FAILOVERCLUSTERDISKS=`"$SQLInstanceDisks`" `r
 `r
; Specifies the name of the cluster group for the SQL Server failover cluster instance.  `r
 `r
; Specifies an encoded IP address. The encodings are semicolon-delimited (;), and follow the format <IP Type>;<address>;<network name>;<subnet mask>. Supported IP types include DHCP, IPV4, and IPV6.  `r
 `r
; Agent Domain Group `r
 `r
; AGTDOMAINGROUP=`"$SQLInstanceDomGroup`" `r
; SQLDOMAINGROUP=`"$SQLInstanceDomGroup`" `r
 `r
; Startup type for Integration Services.  `r
 `r
ISSVCSTARTUPTYPE=`"Automatic`" `r
 `r
; Account for Integration Services: Domain\User or system account.  `r
 `r
ISSVCACCOUNT=`"NT AUTHORITY\NetworkService`" `r
 `r
; CM brick TCP communication port  `r
 `r
COMMFABRICPORT=`"0`" `r
 `r
; How matrix will use private networks  `r
 `r
COMMFABRICNETWORKLEVEL=`"0`" `r
 `r
; How inter brick communication will be protected  `r
 `r
COMMFABRICENCRYPTION=`"0`" `r
 `r
; TCP port used by the CM brick  `r
 `r
MATRIXCMBRICKCOMMPORT=`"0`" `r
 `r
; Level to enable FILESTREAM feature at (0, 1, 2 or 3).  `r
 `r
FILESTREAMLEVEL=`"0`" `r
 `r
; Specifies a Windows collation or an SQL collation to use for the Database Engine.  `r
 `r
SQLCOLLATION=`"SQL_Latin1_General_CP1_CI_AS`" `r
 `r
; Account for SQL Server service: Domain\User or system account.  `r
 `r
; Windows account(s) to provision as SQL Server system administrators.  `r
 `r
SQLSYSADMINACCOUNTS=`"$ADDomain\Admin Core`" `"$ADDomain\SQL Core`" `r
 `r
; The Database Engine root data directory.  `r
 `r
INSTALLSQLDATADIR=`"$SQLInstanceSysDB`" `r
 `r
; Default directory for the Database Engine backup files.  `r
 `r
SQLBACKUPDIR=`"$SQLInstanceBackupDir`" `r
 `r
; Default directory for the Database Engine user databases.  `r
 `r
SQLUSERDBDIR=`"$SQLInstanceUserDBDir`" `r
 `r
; Default directory for the Database Engine user database logs.  `r
 `r
SQLUSERDBLOGDIR=`"$SQLInstanceTransLogDir`" `r
 `r
; Directory for Database Engine TempDB files.  `r
 `r
SQLTEMPDBDIR=`"$SQLInstanceTempDBDir`" `r
 `r
; Add description of input argument FTSVCACCOUNT  `r
 `r
FTSVCACCOUNT=`"NT AUTHORITY\LOCAL SERVICE`" `r
 `r
ASSVCSTARTUPTYPE=`"Automatic`"  `r
ASCOLLATION=`"Latin1_General_CI_AS`"  `r
ASDATADIR=`"Data`"  `r
ASLOGDIR=`"Log`"  `r
ASBACKUPDIR=`"Backup`"  `r
ASTEMPDIR=`"Temp`"  `r
ASCONFIGDIR=`"Config`"  `r
ASPROVIDERMSOLAP=`"1`" `r
RSSVCSTARTUPTYPE=`"Automatic`" `r
RSINSTALLMODE=`"FilesOnlyMode`" `r
 `r
"@

		$ConfigINIFilename = $SQLInstanceInstallSourceDir + "\" + $SQLInstanceName + "_SQL2k12_Node_ConfigFile.ini"
		Set-Content -Path $ConfigINIFilename -Value $SQLFirstInstanceCfgFile


		#Create First Node installation script
		$SQLFirstInstanceCmdLine = @()
		$SQLFirstInstanceCmdLine = @"
param( `r
    [Parameter(Mandatory=`$true)]  `r
    [string]`$SQLInstanceSvcAccount, `r
    [Parameter(Mandatory=`$true)]  `r
    [string]`$SQLInstanceSvcPwd, `r
	[Parameter(Mandatory=`$false)]  `r
    [switch]`$silent=`$false `r
) `r
 `r
`$SQLInstanceDomGroup = "$SQLInstanceDomGroup" `r
`$ADDomain = (gwmi WIN32_ComputerSystem).Domain
`$ADDomainDesc = `$ADDomain.split(".")[0]
`$LogonServer = (Get-WmiObject Win32_ntdomain | Where-Object { `$_.DnsForestName -eq `$ADDomain -and `$_.DomainName -eq `$ADDomainDesc } ).DomainControllerName.trimstart("\\")
`$LDAPDomainBegin = "LDAP://" + `$LogonServer + ":389/dc=" `r
`$LDAPDomainCount = `$ADDomain.split(".").count  `r
`$LDAPDomainEnd = `$null  `r
`$i = 0  `r
do {  `r
	If (`$i -lt (`$LDAPDomainCount - 1)) {`$LDAPDomainEnd += (`$ADDomain.split("."))[`$i] + ",dc=" }  `r
	Else {`$LDAPDomainEnd += (`$ADDomain.split("."))[`$i] }  `r
	 `r
	`$i++} `r
until ( `$i -ge `$LDAPDomainCount)  `r
 `r
`$LDAPDomain = `$LDAPDomainBegin + `$LDAPDomainEnd `r
 `r
Function Move-ADComputerObject(`$ADClusterResource)  `r
{  `r
 `r
	`$root = New-Object System.DirectoryServices.DirectoryEntry (`$LDAPDomain) `r
    `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$root)  `r
    `$searcher.Filter = "(&(objectCategory=computer)(objectClass=computer)(samAccountName=`$(`$env:ComputerName)`$))"  `r
    `$CurrentComputerObject = `$searcher.FindOne()  `r
    `$TexttobeReplaced = "CN=" + `$env:ComputerName + ","  `r
    `$CurrentComputerPath = [string](`$CurrentComputerObject.Properties.adspath)  `r
    `$CurrentComputerPath = `$CurrentComputerPath.replace(`$TexttobeReplaced, "")  `r
    `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$root)  `r
	`$searcher.Filter = "(&(objectCategory=computer)(objectClass=computer)(samAccountName=`$(`$ADClusterResource)`$))"  `r
    `$searcher.SearchScope = "SubTree"  `r
    `$CurrentClusterADObject = `$searcher.FindOne()  `r
    `$CurrentClusterADObjectPath = `$CurrentClusterADObject.Path  `r
    `$CurrentClusterADObject = [adsi]`$CurrentClusterADObjectPath  `r
    `$CurrentClusterADObject.PSBase.MoveTo(`$CurrentComputerPath)  `r
      `r
    #Validate AD Object Move  `r
    `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$root)  `r
    `$searcher.Filter = "(&(objectCategory=computer)(objectClass=computer)(samAccountName=`$(`$ADClusterResource)`$))"  `r
    `$searcher.SearchScope = "SubTree"  `r
    `$CurrentClusterADObject = `$searcher.FindOne()  `r
 `r
    `$NewPath = `$CurrentComputerPath.Insert((`$CurrentComputerPath.LastIndexOf("/")+1),"CN=`$ADClusterResource,")  `r
    If (`$CurrentClusterADObject.Path -ieq `$NewPath ){#  `r
        Write-host "`$ADClusterResource successfully moved to `$CurrentComputerPath" -ForegroundColor green  `r
    }  `r
    Else{ Write-host "`$ADClusterResource Was not successfully moved to `$CurrentComputerPath" -ForegroundColor Yellow}  `r
}  `r
 `r
Function ValidateGroupMembership(){   `r
    `$SQLInstanceSvcAccountName = (`$SQLInstanceSvcAccount.split("\"))[1]   `r
 	`$UserGroup = (`$SQLInstanceDomGroup.split("\"))[1] `r
 	`$root = New-Object System.DirectoryServices.DirectoryEntry (`$LDAPDomain) `r
    `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$root) `r
	`$searcher.SearchScope = "Subtree" `r
    `$searcher.Filter = "(&(objectCategory=Group)(name=`$(`$UserGroup)))" `r
    `$SQLGroupObject = `$searcher.FindOne()  `r
	`$GroupMembers = `$SQLGroupObject.GetDirectoryEntry().member `r
 `r
    `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$root) `r
	`$searcher.SearchScope = "Subtree" `r
    `$searcher.Filter = "(&(objectCategory=User)(Samaccountname=`$(`$SQLInstanceSvcAccountName)))" `r
    `$SQLSvcAcctObject = `$searcher.FindOne()  `r
	 `r
 	`$SQLServiceAccountDN = `$SQLSvcAcctObject.path.tostring().Substring((`$SQLSvcAcctObject.path.tostring().LastIndexOf("/")+1),(`$SQLSvcAcctObject.path.tostring().length)-(`$SQLSvcAcctObject.path.tostring().LastIndexOf("/")+1)) `r
  `r
 	If (`$GroupMembers -match `$SQLServiceAccountDN){#  `r
        Write-host "`$SQLInstanceSvcAccount is a member of the `$SQLInstanceDomGroup Group" -ForegroundColor green  `r
        Return `$true  `r
    }  `r
    Else{  `r
        Write-host "`$SQLInstanceSvcAccount is not a member of the `$SQLInstanceDomGroup Group.  Please add the account and rerun this script" -ForegroundColor Yellow  `r
        Return `$false  `r
        }  `r
  `r
    }  `r
 `r
Function ValidateSPN(){ `r
	`$SQLDNSAlias = "$SQLDNSAlias" `r
	`$ADDomain = (gwmi WIN32_ComputerSystem).Domain `r
	`$CurSPNs = setspn -L `$SQLInstanceSvcAccount | Where-Object {`$_ -like "*MSSQLSvc/$($env:computername)*" } `r
	If (!(`$CurSPNs -ilike "*MSSQLSvc/$SQLInstanceDNSName.`$(`$ADDomain):$SQLInstancePort*")){ SetSPN -A "MSSQLSvc/$($env:computername).`$(`$ADDomain):$SQLInstancePort" `$SQLInstanceSvcAccount } `r
	If (!(`$CurSPNs -ilike "*MSSQLSvc/$($env:computername).`$(`$ADDomain):$SQLInstanceName*")){ SetSPN -A "MSSQLSvc/$($env:computername).$($ADDomain):$SQLInstanceName" `$SQLInstanceSvcAccount } `r
	If (!(`$CurSPNs -ilike "*MSSQLSvc/$($env:computername)`:$SQLInstancePort*")){ SetSPN -A "MSSQLSvc/$($env:computername)`:$SQLInstancePort" `$SQLInstanceSvcAccount } `r
	If (!(`$CurSPNs -ilike "*MSSQLSvc/$($env:computername)`:$SQLInstanceName*")){ SetSPN -A "MSSQLSvc/$($env:computername)`:$SQLInstanceName" `$SQLInstanceSvcAccount } `r
	If (`$SQLDNSAlias.length -gt 0 ){#
		`$CurSPNs = setspn -L `$SQLInstanceSvcAccount | Where-Object {`$_ -like "*MSSQLSvc/`$SQLDNSAlias*" } `r
		If (!(`$CurSPNs -ilike "*MSSQLSvc/`$SQLDNSAlias.`$(`$ADDomain):$SQLInstancePort*")){ SetSPN -A "MSSQLSvc/`$SQLDNSAlias.`$(`$ADDomain):$SQLInstancePort" `$SQLInstanceSvcAccount } `r
		If (!(`$CurSPNs -ilike "*MSSQLSvc/`$SQLDNSAlias.`$(`$ADDomain):$SQLInstanceName*")){ SetSPN -A "MSSQLSvc/`$SQLDNSAlias.$($ADDomain):$SQLInstanceName" `$SQLInstanceSvcAccount } `r
		If (!(`$CurSPNs -ilike "*MSSQLSvc/`$SQLDNSAlias`:$SQLInstancePort*")){ SetSPN -A "MSSQLSvc/`$SQLDNSAlias`:$SQLInstancePort" `$SQLInstanceSvcAccount } `r
		If (!(`$CurSPNs -ilike "*MSSQLSvc/`$SQLDNSAlias`:$SQLInstanceName*")){ SetSPN -A "MSSQLSvc/`$SQLDNSAlias`:$SQLInstanceName" `$SQLInstanceSvcAccount } `r
		}
	} `r
`r
Function Create-ArcsightShare(){ `r
 `r
	New-Item -Name ArcSight -Path $SQLInstanceSysDB -ItemType directory `r
 `r
	`$FolderPath = "$SQLInstanceSysDB\ArcSight" `r
	`$ShareName = "ArcSight_$SQLInstanceName" `r
	`$Type = 0 `r
	`$objWMI = [wmiClass] 'Win32_share' `r
	`$objWMI.create(`$FolderPath, `$ShareName, `$Type) `r
	} `r
 `r
 `r
 If (!(ValidateGroupMembership)){ break } `r
`$SQLSvcAccount = "WinNT://" + `$SQLInstanceSvcAccount.replace("\","/")`r
([ADSI]"WinNT://`$(`$env:ComputerName)/Administrators,group").add(`$SQLSvcAccount)`r
If (`$silent){# `r
	`$CMDLine = `"setup.exe /q /ACTION=``"Install``" /AGTSVCACCOUNT=``"`$SQLInstanceSvcAccount``" /AGTSVCPASSWORD=``"`$SQLInstanceSvcPwd``" /SQLSVCACCOUNT=``"`$SQLInstanceSvcAccount``" /SQLSVCPASSWORD=``"`$SQLInstanceSvcPwd``"  /CONFIGURATIONFILE=``"$ConfigINIFilename``" /IACCEPTSQLSERVERLICENSETERMS `" `r
	} `r
Else {#  `r
	`$CMDLine = `"setup.exe/ACTION=``"Install``" /AGTSVCACCOUNT=``"`$SQLInstanceSvcAccount``" /AGTSVCPASSWORD=``"`$SQLInstanceSvcPwd``" /SQLSVCACCOUNT=``"`$SQLInstanceSvcAccount``" /SQLSVCPASSWORD=``"`$SQLInstanceSvcPwd``"  /CONFIGURATIONFILE=``"$ConfigINIFilename``" /IACCEPTSQLSERVERLICENSETERMS `" `r
	} `r
cmd /c `$CMDLine `r
`r
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement") | out-null `r
`$m = New-Object ('Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer') $($env:computername) `r
If (`$m){# `r 
	`$urn = "ManagedComputer[@Name='$($env:computername)']/ServerInstance[@Name='$SQLInstanceName']/ServerProtocol[@Name='Tcp']" `r
	`$Tcp = `$m.GetSmoObject(`$urn) `r
	`$Enabled = `$Tcp.IsEnabled `r
	IF (!`$Enabled){`$Tcp.IsEnabled = `$true } `r
	`$m.GetSmoObject(`$urn + "/IPAddress[@Name='IPAll']").IPAddressProperties[1].Value = '$SQLInstancePort' `r
	`$m.GetSmoObject(`$urn + "/IPAddress[@Name='IPAll']").IPAddressProperties[0].Value = '' `r
	`$TCP.alter() `r
	} `r
Else{ `r
	write-host `" SQL Instance did not install properly.  Please check the detail and summary log files for the installation to determine the issue and re-run installer.  Exiting script...`" -foregroundcolor yellow `r
	`$InstallLogDirectory = Get-childitem "C:\Program Files\Microsoft SQL Server\110\Setup Bootstrap\Log" | where {`$_.Attributes -eq "Directory" } | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1  `r
	Invoke-Item `$InstallLogDirectory.Fullname `r
	break `r
	} `r
 `r
 `r
ValidateSPN `r
 `r
Create-ArcsightShare `r
 `r
([ADSI]"WinNT://`$(`$env:ComputerName)/Administrators,group").remove(`$SQLSvcAccount)`r
Write-Host `"Press any key to continue ...`" `r
`$x = `$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") `r

"@
	
		$Filename = $SQLInstanceInstallSourceDir + "\" + $SQLInstanceName + "_SQL2k12_Node_Install.ps1"
		Set-Content -Path $Filename -Value $SQLFirstInstanceCmdLine

		#Create Remove Node uninstallation script
	$SQLRemoveCmdLine = @"
`$CMDLine = `"setup.exe /q /ACTION=Uninstall /INSTANCENAME=$SQLInstanceName /INDICATEPROGRESS `" `r
CMD /C `$CMDLine `r
Write-Host `"Press any key to continue ...`" `r
`$x = `$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") `r
"@

		$Filename = $SQLInstanceInstallSourceDir + "\" + $SQLInstanceName + "_SQL2k12_RemoveNode_Uninstall.ps1"
		
		Set-Content -Path $Filename -Value $SQLRemoveCmdLine	
		
		}
}

#Copy all SQL install files and scripts just created to teh other cluster nodes
Function Copy-SQLInstallFiles(){#
	$ClusterMembers = @()
	Get-ClusterNode | ForEach-Object {$ClusterMembers += $_.Name }

	Foreach ($ClusterMember in $ClusterMembers){#
		If ( $ClusterMember -ne $env:COMPUTERNAME ){#
			$Path = "\\" + $ClusterMember + "\" + $SQLInstanceInstallSourceDir.replace(":\","$\")
			
			$CMD = "Robocopy `"$SQLInstanceInstallSourceDir`" `"$Path`" /MT /e /z /R:2 /W:10"
			
			cmd /c $CMD
			}
		}
}

#Begin work
#region Validate that the Failover Cluster Windows Feature is already installed.  If it isn't, install it.
Import-Module servermanager
$Failoverclusteringinstalled = (get-windowsfeature Failover-Clustering).Installed

If (!($Failoverclusteringinstalled)){# Install Windows Failover Clustering if it doesn't exist
	$AddFailoverclustering = add-windowsfeature Failover-Clustering
	If ( $AddFailoverclustering.Success -ne $true ){ # There was an issue installing the Failover-Clustering Feature
		Write-host "Error: There was an issue installing the Failover-Clustering Feature.  Exiting script" -ForegroundColor green
		Add-Content "Error: There was an issue installing the Failover-Clustering Feature.  Exiting script" -Path $LogFile
		Break
		}
	}

$PoShFailoverclusteringinstalled = (get-windowsfeature "RSAT-Clustering-PowerShell").Installed
If (!($PoShFailoverclusteringinstalled)){# Install Windows Failover Clustering PowerShell Module if it doesn't exist
	$AddPoShFailoverclustering = add-windowsfeature "RSAT-Clustering"
	If ( $AddPoShFailoverclustering.Success -ne $true ){ # There was an issue installing the Failover-Clustering Feature
		Write-host "Error: There was an issue installing the Failover-Clustering Feature.  Exiting script" -ForegroundColor green
		Add-Content "Error: There was an issue installing the Failover-Clustering Feature.  Exiting script" -Path $LogFile
		Break
		}
	}
#endregion 

#region Install .NET 3.5 since SQL 2012 still requires it

Import-Module servermanager
$Net35installed = (get-windowsfeature "NET-Framework-Core").Installed
If (!($Net35installed)){# Install .NET 35 if it doesn't exist
	$AddNet35 = add-windowsfeature "NET-Framework-Core" -Source "$SQLInstanceInstallSourceDir\NET35\3.5 SP1\2012R2\sxs"
	If ( $AddNet35.Success -ne $true ){ # There was an issue installing the .NET 3.5 Feature
		Write-host "Error: There was an issue installing .NET 3.5 Feature.  Exiting script" -ForegroundColor green
		Add-Content "Error: There was an issue installing the .NET 3.5 Feature.  Exiting script" -Path $LogFile
		Break
		}
	}

#endregion

# grab data from CSV File param
$LunMappings = Import-Csv $ConfigFile

#Mount the drives
Add-Content "Info: Entering MountDrives" -Path $LogFile
Mount-Drives 

# Checks to see if a Cluster already exists
$ExistingCluster = get-cluster 

If (!($ExistingCluster)){# Cluster does not exist, so create one based on setting in CSV file if they exist
	Write-Host "No configured Cluster on this system.  Entering Cluster config..." -ForegroundColor Green
	Add-Content "Info: No configured Cluster on this system.  Entering Cluster config..." -Path $LogFile
	Create-Cluster
	}
Else {# Cluster does exist
	Write-Host "Cluster already exists on this system.  Skipping Cluster config..." -ForegroundColor Yellow
	Add-Content "Info: Cluster already exists on this system.  Skipping Cluster config..." -Path $LogFile
	}

#Create SQL Network Names in AD
Add-Content "Info: Entering Create-SQLADObjects" -Path $LogFile
Create-SQLADObjects

#Create SQL Install Powershell Scripts based on data from CSV
Add-Content "Info: Entering Create-SQLUnattendedScripts" -Path $LogFile
Create-SQLUnattendedScripts

# Copies all files from SQL Install directory (any that do not already exist) to all other cluster nodes
Add-Content "Info: Entering Copy-SQLInstallFiles" -Path $LogFile
Copy-SQLInstallFiles

Write-Host "Cluster configured and ready for SQL Install." -ForegroundColor Green
Invoke-Item $SQLInstanceInstallSourceDir
Add-Content "Info: Script complete" -Path $LogFile