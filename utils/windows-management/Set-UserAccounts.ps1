param(
	[Parameter(Position=0, Mandatory=$false)]
	[string[]]
	#$accounts = @('Remote Desktop Users')
	$accounts = @('Students', 'Teachers', 'mise', 'správa')
)

# This is a template of the desired values of the respective properties
# of each relevant user account.
# BEWARE that the values are expanded before use in an environment where
# the $_ variable holds the DirectoryEntry object of the user being updated.
$accountTemplate = @{
	homeDrive = 'H:'
	homeDirectory = '\\intranet.sml.cz\$($_.sAMAccountName)'
	scriptPath = 'Apply-Layout.js'
}

# this script block represents the purpose of the entire script, the rest is just presentation ...
$workerScriptBlock = {
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[String[]]
		$accounts
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[Hashtable]
		$template
		,
		[Parameter(Position = 2, Mandatory = $true)]
		[Int64]
		$hwnd
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

	function Expand-String
	{
		param(
			[Parameter(Position = 0, Mandatory = $true)]
			[String]
			$string
			,
			[Parameter(Position = 1, Mandatory = $true)]
			[Object]
			$_
		)

		process {
			return $ExecutionContext.InvokeCommand.ExpandString($string)
		}
	}

	function Update-Object
	{
		param(
			[Parameter(Position = 0, Mandatory = $true)]
			[Object]
			$actual
			,
			[Parameter(Position = 1, Mandatory = $true)]
			[Hashtable]
			$template
		)

		process {
			$changes = @{}

			$template.Keys | ForEach-Object {
				$intended = (Expand-String $template[$_] $actual).toString()
				$current = $actual.$_.toString()

				if ($current -ne $intended) {
					$actual.$_ = $intended
					$changes[$_] = @($current, $intended)
				}
			}

			return $changes
		}
	}

	$PostMessage = Get-PrivateUnsafeWin32Method PostMessage
	$hwndRef = New-Object Runtime.InteropServices.HandleRef($null, [IntPtr]$hwnd)
	$postUserMessage = {
		param()

		# post a WM_USER message to the form window displayed by the foreground code
		# to ensure that the Application.Idle handler (where the ouput of this job
		# is processed) is called
		# 0x0400 = WM_USER
		[void]$PostMessage.Invoke($null, @([Runtime.InteropServices.HandleRef]$hwndRef, 0x0400, [IntPtr]::Zero, [IntPtr]::Zero))
	}

	([adsisearcher](
		"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
	)).findAll() | ForEach-Object { $_.getDirectoryEntry() } | Get-User | ForEach-Object {
		$changes = Update-Object $_ $template

		# update the user account only if we need to
		if ($changes.count -gt 0) {
			$_.commitChanges()
		}

		# emit an object communicating to the foreground code the processed
		# user account
		New-Object PSCustomObject -Property @{
			messageType = 1
			distinguishedName = $_.distinguishedName.value
			changes = $changes
		}

		& $postUserMessage
	}

	# emit an object indicating to the foreground code that we are done
	New-Object PSCustomObject -Property @{ messageType = 0 }

	# make sure the foreground code notices we are done
	for (;;) {
		& $postUserMessage
		Start-Sleep -Milliseconds 100
	}
}

# this script block defines functions used in both the foreground code and the background worker job
$libraryScriptBlock = {
	param()

	function Get-PrivateTypeMethod {
		param (
			[Parameter(Position = 0, Mandatory = $true)]
			[String]
			$assembly
			,
			[Parameter(Position = 1, Mandatory = $true)]
			[String]
			$type
			,
			[Parameter(Position = 2, Mandatory = $true)]
			[String]
			$method
		)

		process {
			# - first find the assembly by its name in the list of currently
			#   loaded assemblies
			# - then get the desired type
			# - finally get the desired method
			([AppDomain]::CurrentDomain.getAssemblies() | Where-Object {
				$_.GetName().Name -eq $assembly
			}).GetType($type).GetMethod($method)
		}
	}

	function Get-PrivateUnsafeWin32Method {
		param (
			[Parameter(Position = 0, Mandatory = $true)]
			[String]
			$proc
		)

		process {
			Get-PrivateTypeMethod System Microsoft.Win32.UnsafeNativeMethods $proc
		}
	}
}

function Get-ProcessedLabelText
{
	param(
		[Parameter(Position = 0, Mandatory = $false)]
		[Int]
		$count = 0
	)

	process {
		if ($count -eq 1) {
			"Processed $count user account."
		} else {
			"Processed $count user accounts."
		}
	}
}

function Get-UpdatedLabelText
{
	param(
		[Parameter(Position = 0, Mandatory = $false)]
		[Int]
		$count = 0
	)

	process {
		if ($count -eq 1) {
			"Updated $count user account:"
		} else {
			"Updated $count user accounts:"
		}
	}
}

function Format-Changes
{
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[Hashtable]
		$changes
	)

	process {
		$changes.Keys | Sort-Object | ForEach-Object {
			"    $($_):  $($changes[$_][0])  →  $($changes[$_][1])"
		}
	}
}

function Add-ControlToNextPanelRow
{
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[Windows.Forms.TableLayoutPanel]
		$panel
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[Windows.Forms.Control]
		$control
		,
		[Parameter(Position = 2, Mandatory = $false)]
		[Windows.Forms.RowStyle]
		$style = (New-Object Windows.Forms.RowStyle)
	)

	process {
		++$panel.RowCount
		[void]$panel.RowStyles.Add($style)
		$panel.Controls.Add($control)
	}
}

function Get-Form
{
	param(
		[Parameter(Position = 0, Mandatory = $false)]
		[String]
		$caption = [IO.Path]::GetFilenameWithoutExtension($script:MyInvocation.InvocationName)
	)

	process {
		$form = New-Object Windows.Forms.Form
		$form.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$pshome\powershell.exe")
		$form.Text = $caption
		$form.Width *= 2
		$form.Padding = New-Object Windows.Forms.Padding(10)
		$form.add_Load({
			$SendMessage = Get-PrivateUnsafeWin32Method SendMessage
			$hwndRef = New-Object Runtime.InteropServices.HandleRef($this, $this.Handle)

			# make sure the keyboard cues are NOT rendered throughout the form
			# 0x0128  = WM_UPDATEUISTATE
			# 0x20001 = MAKEWPARAM(UIS_SET, UISF_HIDEACCEL)
			[void]$SendMessage.Invoke($null, @([Runtime.InteropServices.HandleRef]$hwndRef, 0x0128, [IntPtr]0x20001, [IntPtr]::Zero))

			# make sure the focus cues are rendered throughout the form
			# 0x0128  = WM_UPDATEUISTATE
			# 0x10002 = MAKEWPARAM(UIS_CLEAR, UISF_HIDEFOCUS)
			[void]$SendMessage.Invoke($null, @([Runtime.InteropServices.HandleRef]$hwndRef, 0x0128, [IntPtr]0x10002, [IntPtr]::Zero))
		})
		$form.add_Shown({
			$this.Activate()
		})
		$form.Tag = $formUserData = New-Object PSCustomObject

		$panel = New-Object Windows.Forms.TableLayoutPanel
		$panel.ColumnCount = 1
		$panel.RowCount = 0
		$panel.Dock = [Windows.Forms.DockStyle]::Fill
		$form.Controls.Add($panel)

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name ProcessedLabel -Value (New-Object Windows.Forms.Label)
		$formUserData.ProcessedLabel.Text = Get-ProcessedLabelText
		$formUserData.ProcessedLabel.AutoSize = $true
		$formUserData.ProcessedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		$formUserData.ProcessedLabel.Dock = [Windows.Forms.DockStyle]::Left
		Add-ControlToNextPanelRow $panel $formUserData.ProcessedLabel

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name UpdatedLabel -Value (New-Object Windows.Forms.Label)
		$formUserData.UpdatedLabel.Text = Get-UpdatedLabelText
		$formUserData.UpdatedLabel.AutoSize = $true
		$formUserData.UpdatedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		$formUserData.UpdatedLabel.Dock = [Windows.Forms.DockStyle]::Left
		Add-ControlToNextPanelRow $panel $formUserData.UpdatedLabel

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name Log -Value (New-Object Windows.Forms.TextBox)
		$formUserData.Log.Multiline = $true
		$formUserData.Log.ReadOnly = $true
		$formUserData.Log.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
		$formUserData.Log.BackColor = [Drawing.SystemColors]::Window
		$formUserData.Log.Margin = New-Object Windows.Forms.Padding(0)
		$formUserData.Log.Dock = [Windows.Forms.DockStyle]::Fill
		# get the HideCaret MethodInfo reflection and save it in the control's Tag property
		$formUserData.Log.Tag = Get-PrivateTypeMethod System.Windows.Forms System.Windows.Forms.SafeNativeMethods HideCaret
		$formUserData.Log.add_GotFocus({
			# call the HideCaret method to hide the caret
			$hwndRef = New-Object Runtime.InteropServices.HandleRef($this, $this.Handle)
			[void]$this.Tag.Invoke($null, @([Runtime.InteropServices.HandleRef]$hwndRef))
		})
		# set the style of the TableLayoutPanel's row for this control such that it stretches vertically as much as possible
		Add-ControlToNextPanelRow $panel $formUserData.Log (New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100))

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name Button -Value (New-Object Windows.Forms.Button)
		$formUserData.Button.Text = 'Cancel'
		$formUserData.Button.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 0)
		$formUserData.Button.Dock = [Windows.Forms.DockStyle]::Right
		$formUserData.Button.add_Click({
			$this.TopLevelControl.Close()
		})
		Add-ControlToNextPanelRow $panel $formUserData.Button

		($form.AcceptButton = $formUserData.Button).Select()

		$form
	}
}


# include the scipt block defining utility functions in the current
# scope so that the function the block defines are available
# in the current scope
. $libraryScriptBlock

Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

$workerJob = $null
$form = Get-Form

$form.add_HandleCreated({
	# start the background worker job as soon as the handle for the form has been created
	# (we can't start the job sooner as we need to pass the handle to it as an argument)
	$workerJob = Start-Job -InitializationScript $libraryScriptBlock -ScriptBlock $workerScriptBlock -ArgumentList $accounts, $accountTemplate, ([Int64]$this.Handle)
})

# stop the worker job (if not already stopped) when the form is closing
$form.add_Closing({
	if ($workerJob) {
		Remove-Job -Job $workerJob -Force
		$workerJob = $null
	}
})

$total = $updated = 0
# process the worker job output when the form window message loop goes idle
[Windows.Forms.Application]::add_Idle({
	if ($workerJob) {
		Receive-Job -Job $workerJob | ForEach-Object {
			if ($_.messageType -eq 0) {
				# the worker job has finished processing of the user accounts
				if ($workerJob.State -eq [Management.Automation.JobState]::Running) {
					Stop-Job -Job $workerJob
				}
				Remove-Job -Job $workerJob
				$workerJob = $null
				$form.Tag.Button.Text = 'OK'
			} elseif ($_.messageType -eq 1) {
				# update the count of processed user accounts
				$form.Tag.ProcessedLabel.Text = Get-ProcessedLabelText (++$total)

				if ($_.changes.count -gt 0) {
					# update the count & list of updated user accounts
					$form.Tag.UpdatedLabel.Text = Get-UpdatedLabelText (++$updated)
					$form.Tag.Log.Lines += $_.distinguishedName
					$form.Tag.Log.Lines += Format-Changes $_.changes
				}
			}
		}
	}
})

if ($form) {
	# make sure the form is shown even if the process was started with SW_HIDE
	$form.Show()
	[Windows.Forms.Application]::run($form)
}
