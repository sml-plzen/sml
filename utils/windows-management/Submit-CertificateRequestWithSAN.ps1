# Usage:
#   %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command <script path>\Submit-CertificateRequestWithSAN.ps1 <CSR file> [<subject alternative name 1>,<subject alternative name 2>,...]
# Where <subject alternative name> can be:
#   DNS:<host name>
#   IP:<IPv4 address>

param (
	[Parameter(Position = 0, Mandatory = $true)]
	[String]$RequestFile,
	[Parameter(Position = 1, Mandatory = $false)]
	[String[]]$AlternativeNames = @()
)

if ([IntPtr]::Size -gt 4) {
	# We rely on COM objects which are only available in 32bits,
	# namely the MSScriptControl.ScriptControl.
	Write-Error 'This script must be run with 32bit PowerShell'
	exit 1
}

$JSCode = @'
function callSetCertificateExtension(admin, cAConfigString, requestID, extensionOID, extensionObject) {
	admin.SetCertificateExtension(
		cAConfigString,
		requestID,
		extensionOID,
		3, // PROPTYPE_BINARY
		0, // not critical (EXTENSION_CRITICAL_FLAG), not disabled (EXTENSION_DISABLE_FLAG)
		extensionObject.RawData(
			2 // XCN_CRYPT_STRING_BINARY
		)
	)
}
'@

# This uses the JScript .NET compiler, but as the resulting code runs in CLR
# (just as PowerShell itself), the same kind of marshaling (which is ultimately
# responsible for the data corruption) still takes place (and so does the data
# corruption).
#$js = Add-Type -PassThru -Name 'JS' -Language JScript -MemberDefinition $JSCode | Select-Object -Last 1 | ForEach-Object {
#	$_ = $_.GetConstructor(@())
#
#	$_.Invoke(@())
#}

# This uses the original JScript active scripting engine, which is unmanaged
# so it doesn't need to perform the kind of marshaling PowerShell and
# JScript .NET do, so there is no data corruption ... but it only works in
# 32bit PowerShell as the ScriptControl COM object is only available in 32bit.
$js = New-Object -ComObject MSScriptControl.ScriptControl | ForEach-Object {
	$_.Language = 'JScript'
	$_.AddCode($JSCode)

	$_.CodeObject
}

function Get-LocalCAConfigString {
	param ()

	(New-Object -ComObject CertificateAuthority.Config).GetConfig(
		4 # CC_LOCALACTIVECONFIG
	)
}

function Submit-CertificateRequest {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String]$CAConfigString,
		[Parameter(Position = 1, Mandatory = $true)]
		[String]$RequestFile
	)

	$requestData = [IO.File]::ReadAllText($RequestFile)

	$requestor = New-Object -ComObject CertificateAuthority.Request

	$result = $requestor.Submit(
		0, # CR_IN_BASE64HEADER
		$requestData,
		'CertificateTemplate:StandardServer_V2',
		$CAConfigString
	)

	if ($result -ne 5) { # CR_DISP_UNDER_SUBMISSION
		Write-Error "Unexpected request submission result: $result"
		exit 1
	}

	$requestor.GetRequestId()
}

function Check-SANPrefix {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String]$Prefix,
		[Parameter(Position = 1, Mandatory = $true)]
		[ref]$StrRef
	)

	$Prefix += ':'
	$str = $StrRef.Value

	if ($str.Length -gt $Prefix.Length -and $str.Substring(0, $Prefix.Length) -eq $Prefix) {
		$StrRef.Value = $str.Substring($Prefix.Length).TrimStart($null)
		$true
	} else {
		$false
	}
}

function Set-SANCertificateExtension {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String]$CAConfigString,
		[Parameter(Position = 1, Mandatory = $true)]
		[int]$RequestID,
		[Parameter(Position = 2, Mandatory = $true)]
		[String[]]$AlternativeNames
	)

	$altNamesCollection = New-Object -ComObject X509Enrollment.CAlternativeNames
	foreach ($an in $AlternativeNames) {
		$an = $an.Trim()

		if (Check-SANPrefix 'DNS' ([ref]$an)) {
			$ano = New-Object -ComObject X509Enrollment.CAlternativeName
			$ano.InitializeFromString(
				3, # XCN_CERT_ALT_NAME_DNS_NAME
				$an
			)
			$altNamesCollection.Add($ano)
		} elseif (Check-SANPrefix 'IP' ([ref]$an)) {
			try {
				$ip = [Net.IPAddress] $an
			} catch {
				Write-Error "Invalid IP address: $an"
				continue
			}
			$ano = New-Object -ComObject X509Enrollment.CAlternativeName
			$ano.InitializeFromRawData(
				8, # XCN_CERT_ALT_NAME_IP_ADDRESS
				1, # XCN_CRYPT_STRING_BASE64
				[Convert]::ToBase64String($ip.GetAddressBytes())
			)
			$altNamesCollection.Add($ano)
		} else {
			Write-Error "Unrecognized alternative name: $an"
		}
	}

	$altNamesExtension = New-Object -ComObject X509Enrollment.CX509ExtensionAlternativeNames
	$altNamesExtension.InitializeEncode($altNamesCollection)

	$js.callSetCertificateExtension(
		(New-Object -ComObject CertificateAuthority.Admin),
		$CAConfigString,
		$RequestID,
		'2.5.29.17',
		$altNamesExtension
	)
}

$configStr = Get-LocalCAConfigString

$requestID = Submit-CertificateRequest $configStr $RequestFile

if ($AlternativeNames.Count -gt 0) {
	Set-SANCertificateExtension $configStr $requestID $AlternativeNames
}
