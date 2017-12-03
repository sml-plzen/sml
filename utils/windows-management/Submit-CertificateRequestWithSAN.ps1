# Usage:
#   powershell -ExecutionPolicy Bypass -File <script path>\Submit-CertificateRequestWithSAN.ps1 <CSR file> [-Template <certificate template identifier>] [<subject alternative name> ...]
#   powershell -ExecutionPolicy Bypass -File <script path>\Submit-CertificateRequestWithSAN.ps1 -Update <request ID> [<subject alternative name> ...]
# Where <subject alternative name> can be:
#   DNS:<host name>
#   IP:<IPv4 address>

param (
	[switch]$Update,
	[Parameter(Position = 0)]
	[String]$Request,
	[String]$Template = 'StandardServer_V2',
	[Parameter(ValueFromRemainingArguments = $true)]
	[String[]]$AlternativeNames = @()
)

# Do not continue on errors
$script:ErrorActionPreference = [Management.Automation.ActionPreference]::Stop

function Get-COMInterfaceForObject {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Object]$COMObject,
		[Parameter(Position = 1, Mandatory = $true)]
		[guid]$IID
	)

	# First get hold of the IUnknown interface of the object
	$iUnknown = [Runtime.InteropServices.Marshal]::GetIUnknownForObject($COMObject)

	# Now query for the desired interface
	$interface = [IntPtr]::Zero
	try {
		$hresult = [Runtime.InteropServices.Marshal]::QueryInterface($iUnknown, [ref]$IID, [ref]$interface)
		if ($hresult -ne 0) {
			throw [Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero)
		}
	} finally {
		[void][Runtime.InteropServices.Marshal]::Release($iUnknown)
	}

	$interface
}

function Get-COMInterfaceMethodPointer {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[IntPtr]$COMInterface,
		[Parameter(Position = 1, Mandatory = $true)]
		[int]$VirtualTableSlot
	)

	[Runtime.InteropServices.Marshal]::ReadIntPtr(
		[Runtime.InteropServices.Marshal]::ReadIntPtr($COMInterface), # virtual method table
		[IntPtr]::Size * $VirtualTableSlot # slot offset
	)
}

function Get-DelegateType
{
	param (
		[Parameter(Position = 0, Mandatory = $false)]
		[Type]$ReturnType = [void],
		[Parameter(Position = 1, Mandatory = $false)]
		[Type[]]$ParameterTypes = [Type]::EmptyTypes,
		[Parameter(Position = 2, Mandatory = $false)]
		[Hashtable]$Marshaling = @{}
	)

	# Create a type builder for creating in-memory only delegate types derived from
	# the MulticastDelegate class
	$typeBuilder = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
		'ReflectedDelegate',
		[Reflection.Emit.AssemblyBuilderAccess]::Run
	).DefineDynamicModule(
		'InMemoryModule',
		$false
	).DefineType(
		'DynamicDelegateType',
		[Reflection.TypeAttributes]::Class -bor [Reflection.TypeAttributes]::Public -bor [Reflection.TypeAttributes]::Sealed -bor [Reflection.TypeAttributes]::AutoClass,
		[MulticastDelegate]
	)

	# Define the delegate's constructor
	$typeBuilder.DefineConstructor(
		[Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::HideBySig -bor [Reflection.MethodAttributes]::RTSpecialName,
		[Reflection.CallingConventions]::Standard,
		$null
	).SetImplementationFlags(
		[Reflection.MethodImplAttributes]::Runtime -bor [Reflection.MethodImplAttributes]::Managed
	)

	# Define the Invoke method
	$methodBuilder = $typeBuilder.DefineMethod(
		'Invoke',
		[Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Virtual -bor [Reflection.MethodAttributes]::HideBySig -bor [Reflection.MethodAttributes]::NewSlot,
		$ReturnType,
		$ParameterTypes
	)
	$methodBuilder.SetImplementationFlags(
		[Reflection.MethodImplAttributes]::Runtime -bor [Reflection.MethodImplAttributes]::Managed
	)

	# Define marshaling attributes of the Invoke method's return value & parameters
	foreach ($entry in $Marshaling.GetEnumerator()) {
		$methodBuilder.DefineParameter(
			$entry.Name, # index of the parameter: 0 is the return value, 1 is the first parameter, etc.
			[Reflection.ParameterAttributes]::HasFieldMarshal,
			$null
		).SetCustomAttribute(
			[Activator]::CreateInstance(
				[Reflection.Emit.CustomAttributeBuilder],
				@(
					[Runtime.InteropServices.MarshalAsAttribute].GetConstructor(@([Runtime.InteropServices.UnmanagedType])),
					@($entry.Value)
				)
			)
		)
	}

	$typeBuilder.CreateType()
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
		[String]$RequestFile,
		[Parameter(Position = 2, Mandatory = $true)]
		[String]$Template
	)

	$requestData = [IO.File]::ReadAllText($RequestFile)

	$requestor = New-Object -ComObject CertificateAuthority.Request

	$result = $requestor.Submit(
		0, # CR_IN_BASE64HEADER
		$requestData,
		"CertificateTemplate:$Template",
		$CAConfigString
	)

	if ($result -ne 5) { # CR_DISP_UNDER_SUBMISSION
		throw "Unexpected request submission result: $result"
	}

	$requestor.GetRequestId()
}

function Call-SetCertificateExtension {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Object]$CertAdminObject,
		[Parameter(Position = 1, Mandatory = $true)]
		[String]$CAConfigString,
		[Parameter(Position = 2, Mandatory = $true)]
		[int]$RequestID,
		[Parameter(Position = 3, Mandatory = $true)]
		[Object]$X509ExtensionObject
	)

	# Get the IX509Extension COM interface of the X509 extension object
	$iX509Extension = Get-COMInterfaceForObject $X509ExtensionObject '728ab30d-217d-11da-b2a4-000e7bbb2b09'

	# Obtain the raw data of the X509 extension object as a BSTR through
	# that interface
	$x509ExtensionData_BSTR = [IntPtr]::Zero
	try {
		# Get a delegate for the RawData property getter
		#
		# HRESULT get_RawData(
		#   [in] EncodingType Encoding,
		#   [retval][out] BSTR *pValue
		# );
		$delegate = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
			(Get-COMInterfaceMethodPointer $iX509Extension 9), # the get_RawData is at slot 9 in the VTBL
			(Get-DelegateType ([int]) @([IntPtr], [int], [IntPtr].MakeByRefType()))
		)

		# Get the raw data
		$hresult = $delegate.Invoke(
			$iX509Extension,
			2, # XCN_CRYPT_STRING_BINARY
			[ref]$x509ExtensionData_BSTR
		)
		if ($hresult -ne 0) {
			throw [Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero)
		}
	} finally {
		[void][Runtime.InteropServices.Marshal]::Release($iX509Extension)
	}

	try {
		# Get the ICertAdmin COM interface of the cert admin object
		$iCertAdmin = Get-COMInterfaceForObject $CertAdminObject '34df6950-7fb6-11d0-8817-00a0c903b83c'

		# Call the SetCertificateExtension method on the cert admin object through
		# that interface passing it the extension raw data in a VARIANT
		$x509ExtensionData_VARIANT = [IntPtr]::Zero
		try {
			# Get a delegate for the SetCertificateExtension method
			#
			# HRESULT SetCertificateExtension(
			#   [in] const BSTR strConfig,
			#   [in]       LONG RequestId,
			#   [in] const BSTR strExtensionName,
			#   [in]       LONG Type,
			#   [in]       LONG Flags,
			#   [in] const VARIANT *pvarValue
			# );
			$delegate = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
				(Get-COMInterfaceMethodPointer $iCertAdmin 11), # the SetCertificateExtension is at slot 11 in the VTBL
				(Get-DelegateType `
					([int]) @([IntPtr], [String], [int], [String], [int], [int], [IntPtr]) `
					@{2 = [Runtime.InteropServices.UnmanagedType]::BStr; 4 = [Runtime.InteropServices.UnmanagedType]::BStr})
			)

			# Allocate a memory chunk big enough to store a VARIANT
			$x509ExtensionData_VARIANT = [Runtime.InteropServices.Marshal]::AllocCoTaskMem([IntPtr]::Size * 4)
			# Initialize the VARIANT to an empty VT_BSTR
			[Runtime.InteropServices.Marshal]::GetNativeVariantForObject(
				# Ensure the VARIANT is of the VT_BSTR type even when we effectively pass a $null
				[Activator]::CreateInstance([Runtime.InteropServices.BStrWrapper], @($null)),
				$x509ExtensionData_VARIANT
			)
			# Set the bstrVal pointer in the VARIANT to point to the extension raw data BSTR
			[Runtime.InteropServices.Marshal]::WriteIntPtr(
				$x509ExtensionData_VARIANT,
				8, # offset of the bstrVal member in the VARIANT structure
				$x509ExtensionData_BSTR
			)

			# Call the SetCertificateExtension method
			$hresult = $delegate.Invoke(
				$iCertAdmin,
				$CAConfigString,
				$RequestID,
				$X509ExtensionObject.ObjectId.Value,
				3, # PROPTYPE_BINARY
				0, # not critical (EXTENSION_CRITICAL_FLAG), not disabled (EXTENSION_DISABLE_FLAG)
				$x509ExtensionData_VARIANT
			)
			if ($hresult -ne 0) {
				throw [Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero)
			}
		} finally {
			[void][Runtime.InteropServices.Marshal]::Release($iCertAdmin)
			[Runtime.InteropServices.Marshal]::FreeCoTaskMem($x509ExtensionData_VARIANT)
		}
	} finally {
		[Runtime.InteropServices.Marshal]::FreeBSTR($x509ExtensionData_BSTR)
	}
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
				Write-Warning "Invalid IP address: $an"
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
			Write-Warning "Unrecognized alternative name: $an"
		}
	}

	$altNamesExtension = New-Object -ComObject X509Enrollment.CX509ExtensionAlternativeNames
	$altNamesExtension.InitializeEncode($altNamesCollection)

	Call-SetCertificateExtension (New-Object -ComObject CertificateAuthority.Admin) $CAConfigString $RequestID $altNamesExtension
}

if (-not $MyInvocation.BoundParameters.ContainsKey('Request')) {
	if ($Update) {
		Write-Warning 'No request ID specified, nothing to do.'
	} else {
		Write-Warning 'No request file specified, nothing to do.'
	}
	exit 2
}

if ($Update) {
	try {
		$requestID = [int]$Request
	} catch {
		throw "Request ID must be a number, not: '$Request'"
	}

	if ($AlternativeNames.Count -eq 0) {
		Write-Warning 'No subject alternative names specified, nothing to do.'
		exit 2
	}

	if ($MyInvocation.BoundParameters.ContainsKey('Template')) {
		Write-Warning 'Template cannot be changed during an update, it is ignored.'
	}

	$configStr = Get-LocalCAConfigString

	Set-SANCertificateExtension $configStr $requestID $AlternativeNames
} else {
	$configStr = Get-LocalCAConfigString

	$requestID = Submit-CertificateRequest $configStr $Request $Template

	Write-Output @{RequestID = $requestID}

	if ($AlternativeNames.Count -gt 0) {
		Set-SANCertificateExtension $configStr $requestID $AlternativeNames
	}
}
