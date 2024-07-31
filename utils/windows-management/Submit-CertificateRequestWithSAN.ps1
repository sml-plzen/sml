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
			Write-Error -Exception ([Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero))
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
		$VirtualTableSlot * [IntPtr]::Size # slot offset
	)
}

function Get-TyepForIDispatch {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[IntPtr]$IDispatch
	)

	# Get a delegate for the GetTypeInfoCount method
	#
	# HRESULT GetTypeInfoCount(
	#   [out] UINT *pctinfo
	# );
	$GetTypeInfoCount = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
		(Get-COMInterfaceMethodPointer $IDispatch 3), # the GetTypeInfoCount is at slot 3 in the VTBL
		(Get-DelegateType ([int]) @([IntPtr], [uint32].MakeByRefType()))
	)

	[uint32]$count = 0
	$hresult = $GetTypeInfoCount.Invoke($iDispatch, [ref]$count)
	if ($hresult -ne 0) {
		Write-Error -Exception ([Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero))
	}
	if ($count -le 0) {
		Write-Error -Exception ([ArgumentException]'COM object does not provide type information')
	}

	# Get a delegate for the GetTypeInfo method
	#
	# HRESULT GetTypeInfo(
	#   [in]  UINT      iTInfo,
	#   [in]  LCID      lcid,
	#   [out] ITypeInfo **ppTInfo
	# );
	$GetTypeInfo = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
		(Get-COMInterfaceMethodPointer $IDispatch 4), # the GetTypeInfo is at slot 4 in the VTBL
		(Get-DelegateType ([int]) @([IntPtr], [uint32], [uint32], [IntPtr].MakeByRefType()))
	)

	$typeInfo = [IntPtr]::Zero
	$hresult = $GetTypeInfo.Invoke($iDispatch, 0, 0, [ref]$typeInfo)
	if ($hresult -ne 0) {
		Write-Error -Exception ([Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero))
	}

	[Runtime.InteropServices.Marshal]::GetTypeForITypeInfo($typeInfo)
}

function Get-IDispatchMethodPointer {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[IntPtr]$IDispatch,
		[Parameter(Position = 1, Mandatory = $true)]
		[String]$MethodName
	)

	$methodInfo = (Get-TyepForIDispatch $IDispatch).GetMethod($MethodName)
	if ($methodInfo -eq $null) {
		Write-Error -Exception ([ArgumentException]"Method not found: $MethodName")
	}

	Get-COMInterfaceMethodPointer $IDispatch ([Runtime.InteropServices.Marshal]::GetComSlotForMethodInfo($methodInfo))
}

function New-TypeRegistry {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Reflection.Emit.ModuleBuilder]$ModuleBuilder
	)

	$typeMap = @{}

	New-Object -TypeName PSObject |`
		Add-Member -MemberType ScriptProperty -Name ModuleBuilder -Value {
			param ()

			$ModuleBuilder
		}.GetNewClosure() -PassThru |`
		Add-Member -MemberType ScriptMethod -Name GetRegisteredType -Value {
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[String]$key
			)

			$typeMap[$key]
		}.GetNewClosure() -PassThru |`
		Add-Member -MemberType ScriptMethod -Name RegisterType -Value {
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[String]$key,
				[Parameter(Position = 1, Mandatory = $true)]
				[Type]$type
			)

			($typeMap[$key] = $type) # need parentheses around the assignment to return a value
		}.GetNewClosure() -PassThru
}

function Get-TypeRegistryForDynamicAssembly {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String]$AssemblyName
	)

	$key = "TypeRegistry:$AssemblyName"

	# If the type registry for the specified assembly name is already
	# registered in the app domain data then simply return it
	$appDomain = [AppDomain]::CurrentDomain
	$registry = $appDomain.GetData($key)
	if ($registry -ne $null) {
		$moduleBuilder = $registry.ModuleBuilder
		if ($moduleBuilder -is [Reflection.Emit.ModuleBuilder]) {
			if ($moduleBuilder.Assembly.GetName().Name.Equals($AssemblyName)) {
				return $registry
			}
		}
	}

	# Create a new module builder in a new dynamic assembly
	$moduleBuilder = $appDomain.DefineDynamicAssembly(
		$AssemblyName,
		[Reflection.Emit.AssemblyBuilderAccess]::Run
	).DefineDynamicModule(
		'InMemoryModule',
		$false
	)

	# Create a new type registry with the new module builder
	$registry = New-TypeRegistry $moduleBuilder

	# Register the type registry for the specified dynamic assembly
	# name in the app domain data
	$appDomain.SetData($key, $registry)

	$registry
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

	# Get the type registry for the dynamic delegates assembly
	$registry = Get-TypeRegistryForDynamicAssembly 'ReflectedDynamicDelegates'

	# Build a unique key for the delegate type
	$key = "ReflectedDelegate`0$($ReturnType.FullName)"
	if ($Marshaling.ContainsKey(0)) {
		$key += "=>$($Marshaling[0])"
	}
	for ($parameterIndex = 0; $parameterIndex -lt $ParameterTypes.Count;) {
		$key += "`0$($ParameterTypes[$parameterIndex++].FullName)"
		if ($Marshaling.ContainsKey($parameterIndex)) {
			$key += "=>$($Marshaling[$parameterIndex])"
		}
	}

	# If the type is already registered then simply return it
	$delegateType = $registry.GetRegisteredType($key)
	if ($delegateType -ne $null) {
		return $delegateType
	}

	# Turn the key into a namespaced type name
	$typeName = ([regex]"`0").Replace($key.Replace('.', '::'), '.', 1).Replace("`0", ';')
	# Append a GUID to make the type name unique
	$typeName = "$typeName;$([guid]::NewGuid())"

	# Define the desired delegate type deriving it from the MulticastDelegate class
	$typeBuilder = $registry.ModuleBuilder.DefineType(
		$typeName,
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
			(New-Object Reflection.Emit.CustomAttributeBuilder(
				[Runtime.InteropServices.MarshalAsAttribute].GetConstructor(@([Runtime.InteropServices.UnmanagedType])),
				@($entry.Value)
			))
		)
	}

	# Create the delegate type & register it
	$registry.RegisterType($key, $typeBuilder.CreateType())
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

	$disposition = $requestor.Submit(
		0, # CR_IN_BASE64HEADER
		$requestData,
		"CertificateTemplate:$Template",
		$CAConfigString
	)

	if ($disposition -eq 0 -or $disposition -eq 1 -or $disposition -eq 2) { # CR_DISP_INCOMPLETE or CR_DISP_ERROR or CR_DISP_DENIED
		Write-Error -Exception ([Management.Automation.RuntimeException]"Request submission failed with disposition: $disposition")
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
		[Object]$X509ExtensionObject,
		[Parameter(Position = 4, Mandatory = $false)]
		[bool]$Disable = $false
	)

	# Get the IDispatch COM interface of the X509 extension object
	$x509ExtensionIDispatch = [Runtime.InteropServices.Marshal]::GetIDispatchForObject($X509ExtensionObject)

	# Obtain the raw data of the X509 extension object as a BSTR through the RawData property
	$x509ExtensionData_BSTR = [IntPtr]::Zero
	try {
		# Get a delegate for the RawData property getter
		#
		# HRESULT get_RawData(
		#   [in] EncodingType Encoding,
		#   [retval][out] BSTR *pValue
		# );
		$get_RawData = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
			(Get-IDispatchMethodPointer $x509ExtensionIDispatch 'get_RawData'),
			(Get-DelegateType ([int]) @([IntPtr], [int], [IntPtr].MakeByRefType()))
		)

		# Get the raw data
		$hresult = $get_RawData.Invoke(
			$x509ExtensionIDispatch,
			2, # XCN_CRYPT_STRING_BINARY
			[ref]$x509ExtensionData_BSTR
		)
		if ($hresult -ne 0) {
			Write-Error -Exception ([Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero))
		}
	} finally {
		[void][Runtime.InteropServices.Marshal]::Release($x509ExtensionIDispatch)
	}

	try {
		# Get the IDispatch COM interface of the cert admin object
		$certAdminIDispatch = [Runtime.InteropServices.Marshal]::GetIDispatchForObject($CertAdminObject)

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
			$SetCertificateExtension = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
				(Get-IDispatchMethodPointer $certAdminIDispatch 'SetCertificateExtension'),
				(Get-DelegateType `
					([int]) @([IntPtr], [String], [int], [String], [int], [int], [IntPtr]) `
					@{2 = [Runtime.InteropServices.UnmanagedType]::BStr; 4 = [Runtime.InteropServices.UnmanagedType]::BStr})
			)

			$flags = 0
			if ($X509ExtensionObject.Critical) {
				$flags = $flags -bor 1 # EXTENSION_CRITICAL_FLAG
			}
			if ($Disable) {
				$flags = $flags -bor 2 # EXTENSION_DISABLE_FLAG
			}

			# Allocate a memory chunk big enough to store a VARIANT
			$x509ExtensionData_VARIANT = [Runtime.InteropServices.Marshal]::AllocCoTaskMem(4 * 2 + 2 * [IntPtr]::Size)
			# Initialize the VARIANT to an empty VT_BSTR
			[Runtime.InteropServices.Marshal]::GetNativeVariantForObject(
				# Ensure the VARIANT is of the VT_BSTR type even when we effectively pass a $null
				(New-Object Runtime.InteropServices.BStrWrapper(@($null))),
				$x509ExtensionData_VARIANT
			)
			# Set the bstrVal pointer in the VARIANT to point to the extension raw data BSTR
			[Runtime.InteropServices.Marshal]::WriteIntPtr(
				$x509ExtensionData_VARIANT,
				4 * 2, # offset of the bstrVal member in the VARIANT structure
				$x509ExtensionData_BSTR
			)

			# Call the SetCertificateExtension method
			$hresult = $SetCertificateExtension.Invoke(
				$certAdminIDispatch,
				$CAConfigString,
				$RequestID,
				$X509ExtensionObject.ObjectId.Value,
				3, # PROPTYPE_BINARY
				$flags,
				$x509ExtensionData_VARIANT
			)
			if ($hresult -ne 0) {
				Write-Error -Exception ([Runtime.InteropServices.Marshal]::GetExceptionForHR($hresult, [IntPtr]::Zero))
			}
		} finally {
			[void][Runtime.InteropServices.Marshal]::Release($certAdminIDispatch)
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
		[AllowEmptyCollection()]
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
	if ($altNamesCollection.Count -gt 0) {
		$altNamesExtension.InitializeEncode($altNamesCollection)
	} else {
		# When there were no recognized alternative names specified, initialize
		# the extension in an alternative way from an empty DER encoded ASN.1
		# sequence (a sequence of bytes 0x30, 0x00) as the extension refuses to
		# initialize from an empty alternative names collection.
		$altNamesExtension.InitializeDecode(
			1, # XCN_CRYPT_STRING_BASE64
			[Convert]::ToBase64String(@(0x30, 0x00)) # empty DER sequence
		)
	}

	Call-SetCertificateExtension `
		(New-Object -ComObject CertificateAuthority.Admin) `
		$CAConfigString `
		$RequestID `
		$altNamesExtension `
		($AlternativeNames.Count -eq 0)
}

function Format-ErrorRecord {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Management.Automation.ErrorRecord]$ErrorRecord,
		[switch]$Detailed
	)

	$message = ''
	if ($Detailed -or -not $ErrorRecord.PSObject.Properties['ScriptStackTrace']) {
		$message += '-- Error Record '.PadRight(80, '-') + "`n"
		$message += $ErrorRecord | Format-List * -Force | Out-String

		$message += '-- Invocation Info '.PadRight(80, '-') + "`n"
		$message += $ErrorRecord.InvocationInfo | Format-List * | Out-String

		$exception = $ErrorRecord.Exception
		for ($i = 0; $exception; ++$i, ($exception = $exception.InnerException)) {
			$message += "-- Exception $i ".PadRight(80, '-') + "`n"
			# Need to grab the pass through object as the original
			# doesn't have the property appended in PowerShell 2.
			$exception = Add-Member -InputObject $exception -MemberType NoteProperty `
				-Name Type -Value ($exception.GetType().FullName) `
				-PassThru
			$message += $exception | Format-List * -Force | Out-String
		}
	} else {
		$exception = $ErrorRecord.Exception
		while ($exception.InnerException -ne $null) {
			$exception = $exception.InnerException
		}
		$message +=
			$exception.GetType().FullName + ': ' + $exception.Message +
			("`n" + $ErrorRecord.ScriptStackTrace).Replace("`n", "`n$(' '*8)")
	}

	$message
}

if (-not $MyInvocation.BoundParameters.ContainsKey('Request')) {
	if ($Update) {
		Write-Warning 'No request ID specified, nothing to do.'
	} else {
		Write-Warning 'No request file specified, nothing to do.'
	}
	exit 2
}

try {
	if ($Update) {
		try {
			$requestID = [int]$Request
		} catch {
			Write-Error -Exception ([ArgumentException]"Request ID must be a number, not: '$Request'")
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
} catch {
	$Host.UI.WriteErrorLine((Format-ErrorRecord $_ -Detailed:$false))
	exit 1
}
