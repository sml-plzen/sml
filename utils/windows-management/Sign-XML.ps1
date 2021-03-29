# Do not continue on errors
$script:ErrorActionPreference = [Management.Automation.ActionPreference]::Stop

function Load-Xml {
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[string]
		$xml
		,
		[Parameter(Position = 1, Mandatory = $false)]
		[bool]
		$preserveWhitespace = $true
	)

	$xmlDocument = New-Object System.Xml.XmlDocument
	$xmlDocument.PreserveWhitespace = $preserveWhitespace
	$xmlDocument.Load((New-Object System.Xml.XmlTextReader((New-Object System.IO.StringReader($xml)))))

	$xmlDocument
}

function Verify-XMLSignature {
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[string]
		$xml
	)

	$xmlDocument = Load-Xml $xml
	$signedXml = New-Object System.Security.Cryptography.Xml.SignedXml($xmlDocument)

	# Get the Signature element
	$signature = $xmlDocument.GetElementsByTagName("Signature")
	if ($signature.Count -eq 1) {
		$signature = $signature[0]
	} else {
		return $false
	}

	# Load the signature node
	$signedXml.LoadXml($signature)

	# Check the signature and return the result
	$signedXml.CheckSignature()
}

function Sign-XML {
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[string]
		$xml
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]
		$certificate
	)

	# Check that the PrivateKey was provided
	if (-not $certificate.HasPrivateKey){
		throw 'Private Key not provided, cannot sign XML document'
	}

	$xmlDocument = Load-Xml $xml

	# Remove any previous signature
	$signature = $xmlDocument.GetElementsByTagName("Signature")
	if ($signature.Count -ne 0) {
		if ($signature.Count -ne 1) {
			throw 'Multiple signatures found in the XML document'
		}
		$signature = $signature[0]
		[void]$signature.ParentNode.RemoveChild($signature)
	}

	# Create a SignedXml object
	$signedXml = New-Object System.Security.Cryptography.Xml.SignedXml($xmlDocument)
	$signedXml.SigningKey = $certificate.PrivateKey

	$signature = $signedXml.Signature

	# Create a reference to be signed. Pass '' to specify that all of the current XML
	# document should be signed.
	$reference = New-Object System.Security.Cryptography.Xml.Reference('')
	$reference.AddTransform((New-Object System.Security.Cryptography.Xml.XmlDsigEnvelopedSignatureTransform));

	$signature.SignedInfo.AddReference($Reference)

	# Add a KeyInfo blob to the SignedXml element
	# KeyInfo blob will hold the public key
	$keyInfo = New-Object System.Security.Cryptography.Xml.KeyInfo
	$keyInfo.AddClause((New-Object System.Security.Cryptography.Xml.RSAKeyValue($certificate.PublicKey.Key)))

	$signature.KeyInfo = $keyInfo

	# Compute the signature
	$signedXml.ComputeSignature()

	# Get the signature as an XML node
	$signature = $signedXml.GetXml()

	# Append the signature to xml document
	[void]$xmlDocument.DocumentElement.AppendChild($xmlDocument.ImportNode($signature, $true))

	# XML declaration not part of the signed content?
	#if ($xmlDocument.DocumentElement.FirstChild -is [system.xml.XmlDeclaration]) {
	#	[void]$xml.RemoveChild($xml.FirstChild);
	#}

	$xmlStringWriter = New-Object System.IO.StringWriter

	$xmlDocument.WriteTo((New-Object System.Xml.XmlTextWriter($xmlStringWriter)))

	$xmlStringWriter.ToString()
}

if ($args.Count -gt 0) {
	Add-Type -AssemblyName System.Security

	if ($args.Count -eq 1) {
		Verify-XMLSignature ([IO.File]::ReadAllText($args[0]))
	} else {
		Sign-XML `
			([IO.File]::ReadAllText($args[0])) `
			(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
				[IO.File]::ReadAllBytes($args[1]),
				$args[2],
				[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
			))
	}
}
