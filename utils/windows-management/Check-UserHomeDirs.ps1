param(
	[Parameter(Position=0, Mandatory=$false)]
	[string[]]
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
	param(
		[Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true)]
		[DirectoryServices.DirectoryEntry[]]
		$account
		,
		[Parameter(Mandatory=$false)]
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

$homeDirectoryPattern = New-Object Text.RegularExpressions.Regex(
	'^\\\\sml-server\\home\\(?:students|teachers)\\([^\\]+)$',
	[Text.RegularExpressions.RegexOptions]::IgnoreCase
)

([adsisearcher](
	"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
)).findAll() | ForEach-Object { $_.getDirectoryEntry() } | Get-User | ForEach-Object {
	$match = $homeDirectoryPattern.match($_.homeDirectory.value)
	if ($match.success) {
		if ($match.groups[1].value -eq $_.sAMAccountName) {
			return
		}
	}
	"$($_.distinguishedName) ($($_.sAMAccountName))`n  $($_.homeDirectory)"
}
