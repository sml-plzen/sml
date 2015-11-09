#cd c:\Users\administrator.SML\Downloads\PSTools
#pslist \\sml-server
#psexec \\sml-server -s taskkill /f /pid ?

#psexec \\sml-server powershell.exe -version 1.0 -command ". C:\Users\administrator\Documents\RemoveFolders.ps1"

#Import-Module Servermanager

#Get-WindowsFeature

#Add-PSSnapin Microsoft.Exchange.Management.PowerShell.Admin

$oldServer = 'sml-server'
$newServer = 'win-02'

$dbOld = get-publicfolderdatabase -server $oldServer -erroraction Stop
$dbNew = get-publicfolderdatabase -server $newServer -erroraction Stop

Get-PublicFolder -Server $oldServer -Identity \NON_IPM_SUBTREE -recurse -ResultSize unlimited | ForEach-Object {
	if ($_.Replicas.Contains($dbOld.Identity)) {
		$_.Replicas -= $dbOld.Identity;

		if (!$_.Replicas.Contains($dbNew.Identity)) {
			$_.Replicas += $dbNew.Identity;
		}

		$_ | Set-PublicFolder -Server $_.OriginatingServer;
	}
}