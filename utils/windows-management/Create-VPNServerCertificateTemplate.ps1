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


$name = 'VPNServer'

$domainDN = ([adsi]'').distinguishedName
$certifacteTemplatesContainerDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,$domainDN"
$templateCN = "CN=$name"
$templateDN = "$templateCN,$certifacteTemplatesContainerDN"
$certifacteTemplatesContainer = [adsi]"LDAP://$certifacteTemplatesContainerDN"

# Delete the template first if it already exists
if ([adsi]::Exists("LDAP://$templateDN")) {
	# Comment out the following two lines if you realy want to overwrite an exisitng template
	#Write-Output 'Exiting to prevent accidental overwriting of an existing certificate template.'
	#Exit

	# Delete the template
	([adsi]"LDAP://$templateDN").deleteObject(0)
}

# Create the template
$template = $certifacteTemplatesContainer.create('pKICertificateTemplate', $templateCN)

# Set the attributes
$template.put('distinguishedName', $templateDN)
$template.put('displayName', 'VPN Server')
$template.put('msPKI-Template-Schema-Version', 1)

$template.put('revision', 1)
$template.put('msPKI-Template-Minor-Revision', 0)

$template.put('flags', 131680)
$template.put('pKIDefaultKeySpec', 1)

$template.put('pKIMaxIssuingDepth', 0)
$template.put('pKICriticalExtensions', @('2.5.29.7', '2.5.29.15'))
$template.put('pKIKeyUsage', [Byte[]](Get-Bytes ([Int16]160)))
$template.put('pKIExtendedKeyUsage', @('1.3.6.1.5.5.7.3.1'))
$template.put('pKIDefaultCSPs', @('1,Microsoft Enhanced Cryptographic Provider v1.0'))

$template.put('pKIExpirationPeriod', [Byte[]](Get-EncodedInterval (20 * 365))) # 20 years
$template.put('pKIOverlapPeriod', [Byte[]](Get-EncodedInterval (6 * 7))) # 6 weeks

$template.put('msPKI-RA-Signature', 0)
$template.put('msPKI-Enrollment-Flag', 0)
$template.put('msPKI-Private-Key-Flag', 16)
$template.put('msPKI-Certificate-Name-Flag', 1)
$template.put('msPKI-Certificate-Application-Policy', @('1.3.6.1.5.5.7.3.1'))
$template.put('msPKI-Minimal-Key-Size', 1024)
$template.put('msPKI-Cert-Template-OID', '1.3.6.1.4.1.311.21.8.3300854.14853128.3097485.3146638.8588309.69.416032.1865967')

# Save the template
$template.setInfo()
