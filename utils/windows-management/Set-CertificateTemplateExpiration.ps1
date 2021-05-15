param (
	[Parameter(Position = 0, Mandatory = $true)]
	[String]$name
	,
	[Parameter(Position = 1, Mandatory = $true)]
	[Int]$expirationInDays
)

# Do not continue on errors
$script:ErrorActionPreference = [Management.Automation.ActionPreference]::Stop

function Encode-LDAPBinaryData
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Byte[]]
		$data
	)

	process {
		$sb = New-Object System.Text.StringBuilder

		foreach ($b in $data) {
			[void]$sb.append('\').append($b.toString('x2'))
		}

		return $sb.ToString()
	}
}

function Get-Bytes
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		$value
	)

	process {
		$bytes = [BitConverter]::GetBytes($value)
		if (![BitConverter]::IsLittleEndian) {
			[Array]::Reverse($bytes)
		}
		return $bytes
	}
}

function Get-EncodedInterval
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Int32]
		$days
	)

	process {
		[Int64]$interval = $days
		$interval *= 24 * 3600 * 10000000
		return (Get-Bytes (-$interval))
	}
}


$domainDN = ([adsi]'').distinguishedName
$certifacteTemplatesContainerDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,$domainDN"
$templateDN = "CN=$(Encode-LDAPBinaryData ([System.Text.Encoding]::UTF8.GetBytes($name))),$certifacteTemplatesContainerDN"

# Check that the template exists
if (-not [adsi]::Exists("LDAP://$templateDN")) {
	Write-Error -Exception ([Management.Automation.RuntimeException]"Certificate template not found: $name")
}

$template = [adsi]"LDAP://$templateDN"

[void]$template.put('pKIExpirationPeriod', [Byte[]](Get-EncodedInterval $expirationInDays))
# original value of the attribute of the "CodeSigning" template:
#   CT_FLAG_SUBJECT_REQUIRE_DIRECTORY_PATH | CT_FLAG_SUBJECT_ALT_REQUIRE_UPN
#[void]$template.put('msPKI-Certificate-Name-Flag', 0x82000000)
# value allowing specifying of the subject:
#   CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT
#[void]$template.put('msPKI-Certificate-Name-Flag', 0x00000001)

# Save the template
$template.setInfo()