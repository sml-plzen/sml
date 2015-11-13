param (
	[Parameter(Position = 0, Mandatory = $false)]
	[String[]]
	#$accounts = @('Remote Desktop Users')
	$accounts = @('Students', 'Teachers', 'mise', 'správa')
)

# ==================================================================================================
#
# NAME: Get-User
#
# AUTHOR: Michal Růžička
# DATE  : 2/22/2013
#
# COMMENT:
# Given a list of DirectoryEntry objects representing AD accounts - both user and group accounts,
# outputs a list of DirectoryEntry objects representing solely user accounts. The output user
# accounts are either user accounts present in the supplied list or user accounts of users who
# are members (even transitive) of any group present in the supplied list.
#
# ==================================================================================================

function Get-User
{
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[DirectoryServices.DirectoryEntry[]]
		$account
		,
		[Parameter(Mandatory = $false)]
		[Hashtable]
		$processed
	)

	begin {
		if ($processed) {
			$processedSet = $processed
		} else {
			$processedSet = @{}
		}
		$groups = @()
	}

	process {
		foreach ($a in $account) {
			$distinguishedName = $a.distinguishedName.value
			if ($processedSet.Contains($distinguishedName)) {
				# skip the account if it was already processed
				continue
			}

			if ($a.objectClass -contains 'user') {
				# process (just output) user
				$a
			} elseif ($a.objectClass -contains 'group') {
				# remember nested groups to process them later
				$groups += $a
			} else {
				# if the AD account class is not recognized then continue
				# without storing it to the processed set so as not to bloat
				# the set
				continue
			}

			# remember the processed account
			$processedSet[$distinguishedName] = $true
		}
	}

	end {
		foreach ($g in $groups) {
			# process users who are members of the group by virtue of having the group set as their primary group
			$g.refreshCache('primaryGroupToken')
			([adsisearcher]"(&(objectClass=user)(primaryGroupID=$($g.primaryGroupToken)))").findAll() | ForEach-Object {
				$_.getDirectoryEntry()
			} | Get-User -processed $processedSet

			# process regular members of the group
			$g.member | ForEach-Object {
				[adsi]"LDAP://$_"
			} | Get-User -processed $processedSet
		}
	}
}

# ==================================================================================================
#
# NAME: Get-NTAccountName
#
# AUTHOR: Michal Růžička
# DATE  : 2/21/2013
#
# COMMENT:
# Given a distinguished name of an account, returns the NT name of that account.
#
# ==================================================================================================

function Get-NTAccountName
{
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[String[]]
		$distinguishedName
	)

	begin {
		$translator = New-Object -comObject 'NameTranslate'
		$translatorType = $translator.GetType()

		# bind the NameTranslate object to the current domain
		# (note the constant 1 is ADS_NAME_INITTYPE_DOMAIN)
		[void]$translatorType.InvokeMember('Init', 'InvokeMethod', $null, $translator,
			@(1, [DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name)
		)
	}

	process {
		foreach($n in $distinguishedName) {
			# use the Set method to specify the Distinguished Name of the account
			# (note the constant 1 is ADS_NAME_TYPE_1779)
			[void]$translatorType.InvokeMember('Set', 'InvokeMethod', $null, $translator, @(1, $n))

			# use the Get method to retrieve the NT name of the account
			# (note the constant 3 is ADS_NAME_TYPE_NT4)
			$translatorType.InvokeMember('Get', 'InvokeMethod', $null, $translator, 3)
		}
	}
}

([adsisearcher](
	"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
)).findAll() | ForEach-Object { $_.getDirectoryEntry() } | Get-User | ForEach-Object {
	$_.distinguishedName
} | Get-NTAccountName | Sort-Object | ForEach-Object {
	[Console]::WriteLine($_)
}
