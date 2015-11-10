param(
	[Parameter(Position = 0, Mandatory = $false)]
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
		[Hashtable]
		$formRecord
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
			$ExecutionContext.InvokeCommand.ExpandString($string)
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

		begin {
			$changes = @{}
		}

		process {
			$template.Keys | ForEach-Object {
				$intended = (Expand-String $template[$_] $actual).toString()
				$current = $actual.$_.toString()

				if ($current -ne $intended) {
					$actual.$_ = $intended
					$changes[$_] = @($current, $intended)
				}
			}
		}

		end {
			$changes
		}
	}

	$message = $null
	$handler = [EventHandler]{
		param()

		& $formRecord.Updater $message
	}

	([adsisearcher](
		"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
	)).findAll() | ForEach-Object { $_.getDirectoryEntry() } | Get-User | ForEach-Object {
		$changes = Update-Object $_ $template

		# update the user account only if we need to
		if ($changes.count -gt 0) {
			$_.commitChanges()
		}

		# build the user-account-processed message and invoke the form updater
		$message = @{
			messageType = 1
			distinguishedName = $_.distinguishedName.value
			changes = $changes
		}
		$formRecord.Form.Invoke($handler)
	}

	# build the end-of-processing message and invoke the form updater
	$message = @{ messageType = 0 }
	$formRecord.Form.Invoke($handler)
}

function Get-PrivateType {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Reflection.Assembly]
		$assembly
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[String]
		$typeName
	)

	process {
		$assembly.GetType($typeName)
	}
}

function Get-NestedType {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Type]
		$type
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[String[]]
		$nestedTypeName
	)

	begin {
		[Reflection.BindingFlags]$bindingFlags =
			[Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic
	}

	process {
		$nestedTypeName | ForEach-Object {
			$type = $type.GetNestedType($_, $bindingFlags)
		}
		$type
	}
}

function Get-Constant {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Type]
		$type
		,
		[Parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true)]
		[String[]]
		$constantName
	)

	begin {
		[Reflection.BindingFlags]$bindingFlags =
			[Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic
		$result = @{}
	}

	process {
		$constantName | ForEach-Object {
			$result[$_] = $type.GetField($_, $bindingFlags).GetValue($null)
		}
	}

	end {
		$result
	}
}

function Get-Method {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Type]
		$type
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[String]
		$methodName
		,
		[Parameter(Position = 2, Mandatory = $false)]
		[Type[]]
		$parameterTypes = $null
	)

	begin {
		[Reflection.BindingFlags]$bindingFlags =
			[Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic
	}

	process {
		if ($parameterTypes) {
			$type.GetMethod($methodName, $bindingFlags, $null, $parameterTypes, $null)
		} else {
			$type.GetMethod($methodName, $bindingFlags)
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
		$plural = ''
		if ($count -ne 1) {
			$plural += 's'
		}

		"Processed $count user account$($plural)."
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
		$plural = ''
		if ($count -ne 1) {
			$plural += 's'
		}

		"Updated $count user account$($plural):"
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

function Build-Form
{
	param(
		[Parameter(Position = 0, Mandatory = $false)]
		[String]
		$caption = [IO.Path]::GetFilenameWithoutExtension($script:MyInvocation.InvocationName)
	)

	process {
		$formRecord = @{}
		$formRecord.Form = New-Object Windows.Forms.Form
		$formRecord.Form.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$pshome\powershell.exe")
		$formRecord.Form.Text = $caption
		$formRecord.Form.Width *= 2
		$formRecord.Form.Padding = New-Object Windows.Forms.Padding(10)
		$formRecord.Form.add_Load({
			$SendMessage = Get-Method $this.getType() SendMessage @([Int], [Int], [Int])
			$NativeMethodsType = Get-PrivateType ([Windows.Forms.Form].Assembly) System.Windows.Forms.NativeMethods
			$winConst = Get-Constant $NativeMethodsType WM_UPDATEUISTATE, UIS_CLEAR, UIS_SET, UISF_HIDEFOCUS, UISF_HIDEACCEL
			$MAKELONG = Get-Method (Get-NestedType $NativeMethodsType Util) MAKELONG

			# make sure the focus cues are rendered throughout the form
			[void]$SendMessage.Invoke($this, @($winConst.WM_UPDATEUISTATE, $MAKELONG.Invoke($null, @($winConst.UIS_CLEAR, $winConst.UISF_HIDEFOCUS)), 0))
			# make sure the keyboard cues are NOT rendered throughout the form
			[void]$SendMessage.Invoke($this, @($winConst.WM_UPDATEUISTATE, $MAKELONG.Invoke($null, @($winConst.UIS_SET, $winConst.UISF_HIDEACCEL)), 0))
		})
		$formRecord.Form.add_Shown({
			$this.Activate()
		})

		$panel = New-Object Windows.Forms.TableLayoutPanel
		$panel.ColumnCount = 1
		$panel.RowCount = 0
		$panel.Dock = [Windows.Forms.DockStyle]::Fill

		$formRecord.ProcessedLabel = New-Object Windows.Forms.Label
		$formRecord.ProcessedLabel.Text = Get-ProcessedLabelText
		$formRecord.ProcessedLabel.AutoSize = $true
		$formRecord.ProcessedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		$formRecord.ProcessedLabel.Dock = [Windows.Forms.DockStyle]::Left
		Add-ControlToNextPanelRow $panel $formRecord.ProcessedLabel

		$formRecord.UpdatedLabel = New-Object Windows.Forms.Label
		$formRecord.UpdatedLabel.Text = Get-UpdatedLabelText
		$formRecord.UpdatedLabel.AutoSize = $true
		$formRecord.UpdatedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		$formRecord.UpdatedLabel.Dock = [Windows.Forms.DockStyle]::Left
		Add-ControlToNextPanelRow $panel $formRecord.UpdatedLabel

		$formRecord.Log = New-Object Windows.Forms.TextBox
		$formRecord.Log.Multiline = $true
		$formRecord.Log.ReadOnly = $true
		$formRecord.Log.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
		$formRecord.Log.BackColor = [Drawing.SystemColors]::Window
		$formRecord.Log.Margin = New-Object Windows.Forms.Padding(0)
		$formRecord.Log.Dock = [Windows.Forms.DockStyle]::Fill
		# get the HideCaret MethodInfo reflection and save it in the control's Tag property
		$formRecord.Log.Tag = Get-Method (Get-PrivateType ([Windows.Forms.Form].Assembly) System.Windows.Forms.SafeNativeMethods) HideCaret
		$formRecord.Log.add_GotFocus({
			# call the HideCaret method to hide the caret
			[void]$this.Tag.Invoke($null, @([Runtime.InteropServices.HandleRef](New-Object Runtime.InteropServices.HandleRef($this, $this.Handle))))
		})
		# set the style of the TableLayoutPanel's row for this control such that it stretches vertically as much as possible
		Add-ControlToNextPanelRow $panel $formRecord.Log (New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100))

		$buttonPanel = New-Object Windows.Forms.FlowLayoutPanel
		$buttonPanel.AutoSize = $true
		$buttonPanel.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
		$buttonPanel.Dock = [Windows.Forms.DockStyle]::Right

		$formRecord.StopButton = New-Object Windows.Forms.Button
		$formRecord.StopButton.Text = 'Stop'
		$formRecord.StopButton.Margin = New-Object Windows.Forms.Padding(10, 0, 0, 0)
		$buttonPanel.Controls.Add($formRecord.StopButton)

		$formRecord.CloseButton = New-Object Windows.Forms.Button
		$formRecord.CloseButton.Text = 'Close'
		$formRecord.CloseButton.Margin = New-Object Windows.Forms.Padding(10, 0, 0, 0)
		$formRecord.CloseButton.Enabled = $false
		$formRecord.CloseButton.add_Click({
			$this.TopLevelControl.Close()
		})
		$buttonPanel.Controls.Add($formRecord.CloseButton)

		Add-ControlToNextPanelRow $panel $buttonPanel

		$formRecord.Form.Controls.Add($panel)
		$formRecord.Form.CancelButton = $formRecord.StopButton
		$formRecord.Form.AcceptButton = $formRecord.CloseButton
		$formRecord.StopButton.Select()

		$formRecord
	}
}

function Toggle-FormButtons
{
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[Hashtable]
		$formRecord
	)

	process {
		$shouldSelect = [Object]::ReferenceEquals($formRecord.Form.ActiveControl, $formRecord.StopButton)

		$formRecord.StopButton.Enabled = $false
		$formRecord.CloseButton.Enabled = $true

		if ($shouldSelect) {
			$formRecord.CloseButton.Select()
		}
	}
}


# main Main MAIN
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

$formRecord = Build-Form

$stats = @{
	total = 0
	updated = 0
}
# this code block will be called periodically from the worker thread to update the form UI
$formRecord.Updater = {
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[Hashtable]
		$message
	)

	if ($message.messageType -eq 0) {
		# the worker thread has finished processing of the user accounts;
		# disable the 'Stop' button & enable the 'Close' button
		Toggle-FormButtons $formRecord
	} elseif ($message.messageType -eq 1) {
		# update the count of processed user accounts
		$formRecord.ProcessedLabel.Text = Get-ProcessedLabelText (++$stats.total)

		if ($message.changes.count -gt 0) {
			# update the count & log of updated user accounts
			$logRecord = ''
			if ($stats.updated -gt 0) {
				$logRecord += [Environment]::NewLine
			}
			$logRecord += $message.distinguishedName + [Environment]::NewLine +
				((Format-Changes $message.changes) -join [Environment]::NewLine)

			$formRecord.UpdatedLabel.Text = Get-UpdatedLabelText (++$stats.updated)
			$formRecord.Log.AppendText($logRecord)
		}
	}
}

$ps = [PowerShell]::Create().AddScript($workerScriptBlock).AddArgument($accounts).AddArgument($accountTemplate).AddArgument($formRecord)
$workerAsyncInvoke = $null
$workerAsyncStop = $null

$formRecord.Form.add_HandleCreated({
	# start the worker thread as soon as the handle for the form has been created
	$workerAsyncInvoke = $ps.BeginInvoke()
})

# add 'Stop' button handler
$formRecord.StopButton.add_Click({
	$workerAsyncStop = $ps.BeginStop($null, $null)
	Toggle-FormButtons $formRecord
})

# make sure the form is shown even if the process was started with SW_HIDE
$formRecord.Form.Show()
[Windows.Forms.Application]::run($formRecord.Form)

if ($workerAsyncStop) {
	$ps.EndStop($workerAsyncStop)
} elseif (-not $workerAsyncInvoke.IsCompleted) {
	$ps.Stop()
}
[void]$ps.EndInvoke($workerAsyncInvoke)
$ps.Dispose()
