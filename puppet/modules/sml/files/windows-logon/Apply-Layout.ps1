# display the specified message in a message box and exit
function Display-ErrorMessage
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String]
		$message
		,
		[Parameter(Position = 1, Mandatory = $false)]
		[String]
		$caption = [IO.Path]::GetFilename($script:MyInvocation.InvocationName)
	)

	process {
		Add-Type -AssemblyName System.Windows.Forms
		[Windows.Forms.Application]::EnableVisualStyles()

		[void][Windows.Forms.MessageBox]::Show(
			$message, $caption,
			[Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning
		)

		Exit
	}
}

# return distinguished names corresponding to the specified account names
function Get-ADAccountDN
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String[]]
		$accounts
	)

	process {
		$checkMap = @{}
		foreach ($a in $accounts) {
			$checkMap[$a.toLower()] = $a
		}

		([adsisearcher](
			"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
		)).findAll() | ForEach-Object {
			$_ = $_.getDirectoryEntry()
			$checkMap.remove($_.sAMAccountName.value.toLower())
			$_.distinguishedName.value
		}

		if ($checkMap.count -gt 0) {
			Display-ErrorMessage "Could not find out distinguished name(s) of the following account(s):`n$($checkMap.values -join ', ')"
		}
	}
}

# return all groups the specified user is a member of (even transitive);
# the product of this function are distinguished names of the groups
# the user is a member of
function Get-GroupMembership
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[DirectoryServices.DirectoryEntry]
		$user
	)

	process {
		$sid = $user.objectSid.value
		$primaryGroupRid = [BitConverter]::GetBytes($user.primaryGroupID.value)

		# build escaped version of the SID of the user's primary group suitable
		# for use in an LDAP filter; we start with the users SID, but instead of
		# including the user's RID part of the SID we include the RID
		# of the user's primary group
		$sb = New-Object Text.StringBuilder
		for ($i = 0; $i -lt $sid.length - $primaryGroupRid.length; ++$i) {
			[void]$sb.append('\').append($sid[$i].toString('x2'))
		}
		if ([BitConverter]::IsLittleEndian) {
			for ($i = 0; $i -lt $primaryGroupRid.length; ++$i) {
				[void]$sb.append('\').append($primaryGroupRid[$i].toString('x2'))
			}
		} else {
			for ($i = $primaryGroupRid.length-1; $i -ge 0; --$i) {
				[void]$sb.append('\').append($primaryGroupRid[$i].toString('x2'))
			}
		}

		# lookup the user's primary group by its SID
		$primaryGroup = ([adsisearcher](
			"(&(objectClass=group)(objectSid=$($sb.toString())))"
		)).findAll() | ForEach-Object { $_.getDirectoryEntry() }
		if (!$primaryGroup) {
			Display-ErrorMessage "Could not find primary group of user:`n$($user.sAMAccountName) ($($user.distinguishedName))"
		}

		# output the user distinguished name
		$user.distinguishedName.value

		$memberOf = @{
			$primaryGroup.distinguishedName.value = $true
		}
		$user.memberOf | ForEach-Object {
			$memberOf[$_] = $true
		}

		# expand the groups, i.e. given a set of groups find groups in which the groups
		# from the given set are members, then add the found groups to the set and repeat
		# the process until there is nothing to add to the set
		$unexpanded = $memberOf.Keys
		do {
			# lookup the groups which haven't been expanded yet
			$searcher = [adsisearcher](
				"(&(objectClass=group)(|$(($unexpanded | % { "(distinguishedName=$_)" }) -join '')))"
			)

			$unexpanded = @()
			$searcher.findAll() | ForEach-Object {
				$_ = $_.getDirectoryEntry()

				# here we produce the output of the function
				$_.distinguishedName.value

				$_.memberOf | ForEach-Object {
					if ($memberOf.Contains($_)) {
						# continue with the next iteration
						# of the innermost ForEach-Object
						return
					}

					$memberOf[$_] = $true
					$unexpanded += $_
				}
			}
		} while ($unexpanded.length -gt 0)
	}
}

# read the layout & mappings definitions and return the data in the form
# of a layout priority map
function Read-Layouts
{
	param ()

	process {
		$layoutsFile = [IO.Path]::GetDirectoryName($script:MyInvocation.InvocationName) + '\layouts.xml'
		try {
			$xml = [xml](Get-Content -Encoding UTF8 -Path $layoutsFile -ErrorAction Stop)
		}
		catch [Exception] {
			$_ = $_.Exception
			if ($_.InnerException) {
				if ($_.InnerException -is [Xml.XmlException]) {
					$_ = $_.InnerException
				}
			}
			Display-ErrorMessage "Failed to parse the layouts definition file ($layoutsFile):`n$($_.Message)"
		}

		$layouts = @{}
		$xml.layouts.layout | ForEach-Object {
			$layout = @()

			if ($_.include) {
				$layout += $_.include | ForEach-Object {
					$layouts[$_.layout]
				}
			}

			if ($_.volume) {
				$layout += $_.volume | ForEach-Object {
					@{
						drive = $_.drive
						path = $_.path
						description = $_.description
						platform = $_.platform
					}
				}
			}

			$layouts[$_.name] = $layout
		}

		$layoutPriorityMap = @{}
		$prioritymax = 0
		$xml.layouts.apply | ForEach-Object {
			$layout = @{
				priority = 0
				layout = $layouts[$_.layout]
			}

			do {
				if ($_.supplementary) {
					if ($_.supplementary -eq 'true') {
						break
					}
				}

				$layout.priority = ++$prioritymax
			} while ($false)

			Get-ADAccountDN ($_.account | ForEach-Object { $_.name }) | ForEach-Object {
				if (-not $layoutPriorityMap.Contains($_)) {
					$layoutPriorityMap[$_] = $layout
				}
			}
		}

		return $layoutPriorityMap
	}
}

# convert the given collection to a map;
# the collection is expected to have even number of elements,
# each odd element is made into the resulting map's key
# with the immediately following even element being the mapped
# value, for example the following collection:
#   [Collections.ArrayList]@('one', 1, 'two', 2)
# is converted into the following map:
#   @{'one' = 1; 'two' = 2}
function ConvertTo-Map
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		# we cannot specify the type so as to be able to support
		# collections returned from COM objects
		#[Collections.ICollection]
		$collection
	)

	process {
		$map = @{}

		$count = $collection.count
		if (!($count -is [Int32])) {
			$count = $collection.count()
		}
		for ($i = 0; $i -lt $count; $i += 2) {
			$map[$collection.item($i)] = $collection.item($i+1)
		}

		return $map
	}
}


# lookup the user who is logging on
$userAccount = ([adsisearcher](
	"(&(objectClass=user)(sAMAccountName=$($env:USERNAME)))"
)).findAll() | ForEach-Object { $_.getDirectoryEntry() }

# read the layout configuration
$layoutPriorityMap = Read-Layouts

# build the drive mapping for the user based on his/her group memberships
$layout = @()
$primary = @{
	priority = 0
}
Get-GroupMembership $userAccount | ForEach-Object {
	if ($layoutPriorityMap.Contains($_)) {
		$_ = $layoutPriorityMap[$_]
		if ($_.priority -gt 0) {
			# primary layout
			if ($_.priority -gt $primary.priority) {
				$primary = $_
			}
		} else {
			# supplementary layout
			$layout += $_.layout
		}
	}
}
if ($primary.priority -gt 0) {
	$layout += $primary.layout
}

# apply the layout (if not empty)
if ($layout.length -gt 0) {
	$netCom = New-Object -ComObject WScript.Network
	$netDeviceMap = ConvertTo-Map $netCom.EnumNetworkDrives()

	$failed = @()
	$layout | ForEach-Object {
		# skip volumes not intended for windows
		if ($_.platform) {
			if ($_.platform -ne 'windows') {
				return
			}
		}
		$deviceName = $_.drive.toUpper() + ':'
		$path = $_.path
		if ($netDeviceMap.Contains($deviceName)) {
			if ($path -eq $netDeviceMap[$deviceName]) {
				return
			} else {
				try {
					$netCom.RemoveNetworkDrive($deviceName, $true)
				}
				catch {
					# ignore
				}
			}
		}
		try {
			$netCom.MapNetworkDrive($deviceName, $path, $false)
		}
		catch {
			$failed += "  $deviceName  $path"
		}
	}
	if ($failed.length -gt 0) {
		Display-ErrorMessage "Failed to map the following drives:`n$($failed -join "`n")"
	}
}
