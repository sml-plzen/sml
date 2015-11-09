param(
	[Parameter(Position=0, Mandatory=$true)]
	[string]
	$inputFile
)

Get-Content -Encoding UTF8 -Path $inputFile | ConvertFrom-Csv | ForEach-Object {
	$user = [adsi]"LDAP://$($_.distinguishedName)"
 	if ($user.homeDirectory.value -eq $_.homeDirectory) {
		# continue with the next iteration of the ForEach-Object loop
		# if the home directory is alredy set to the desired value
		return
	}

	$user.homeDirectory = $_.homeDirectory
	$user.commitChanges()

	"$($user.distinguishedName)`n  $($user.homeDirectory)"
}
