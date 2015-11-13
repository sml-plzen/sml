param (
	[Parameter(Position = 0, Mandatory = $false)]
	[String[]]
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

# this script block represents the meat of the entire script, the rest is just presentation ...
$workerScriptBlock = {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[String[]]
		$accounts
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[Hashtable]
		$template
		,
		[Parameter(Position = 2, Mandatory = $true)]
		[PSObject]
		$monitor
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

	function Expand-String
	{
		param (
			[Parameter(Position = 0, Mandatory = $true)]
			[String]
			$string
			,
			[Parameter(Position = 1, Mandatory = $true)]
			[Object]
			$data
		)

		process {
			$private:_ = $data
			try {
				# $ExecutionContext.InvokeCommand.ExpandString($string) # doesn't work in PowerShell 3.0 & 4.0
				Invoke-Expression ('"' + ($string -replace '(`*)"', '$1$1`"') + '"')
			} catch {
				''
			}
		}
	}

	function Update-Object
	{
		param (
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

	([adsisearcher](
		"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
	)).findAll() | ForEach-Object { $_.getDirectoryEntry() } | Get-User | ForEach-Object {
		$changes = Update-Object $_ $template

		# update the user account only if we need to
		if ($changes.count -gt 0) {
			$_.commitChanges()
		}

		# tell the monitor about our progress
		$monitor.Update(@{
			distinguishedName = $_.distinguishedName.value
			changes = $changes
		})
	}

	# tell the monitor we are done
	$monitor.Done()
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

function Format-Changes
{
	param (
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

function Format-Message
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Hashtable]
		$message
	)

	process {
		$message.distinguishedName + [Environment]::NewLine +
			((Format-Changes $message.changes) -join [Environment]::NewLine)
	}
}

function Add-ControlToNextPanelRow
{
	param (
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
		[void]$panel.RowStyles.Add($style)
		$panel.Controls.Add($control)
	}
}

function Add-ControlToNextPanelColumn
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[Windows.Forms.TableLayoutPanel]
		$panel
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[Windows.Forms.Control]
		$control
		,
		[Parameter(Position = 2, Mandatory = $false)]
		[Windows.Forms.ColumnStyle]
		$style = (New-Object Windows.Forms.ColumnStyle)
	)

	process {
		[void]$panel.ColumnStyles.Add($style)
		$panel.Controls.Add($control)
	}
}

function Run-GUI
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[ScriptBlock]
		$scriptBlock
		,
		[Parameter(Position = 1, Mandatory = $false)]
		[Object[]]
		$arguments = @()
		,
		[Parameter(Position = 2, Mandatory = $false)]
		[String]
		$caption = [IO.Path]::GetFilenameWithoutExtension($script:MyInvocation.InvocationName)
	)

	process {
		# we use PSObject because it doesn't lose custom properties when unboxed when passed
		# as an argument to .Net methods (in contrast to Object)
		$monitor = New-Object PSObject

		# state data storage
		Add-Member -InputObject $monitor -Name State -MemberType NoteProperty -Value @{
			Total = 0
			Updated = 0
		}

		# the top level form
		Add-Member -InputObject $monitor -Name Form -MemberType NoteProperty -Value (New-Object Windows.Forms.Form)
		$monitor.Form.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$pshome\powershell.exe")
		$monitor.Form.Text = $caption
		$monitor.Form.Width *= 2
		$monitor.Form.Padding = New-Object Windows.Forms.Padding(10, 10, 10, 6)
		$monitor.Form.add_Load({
			$SendMessage = Get-Method $this.getType() SendMessage @([Int32], [Int32], [Int32])
			$NativeMethodsType = Get-PrivateType ([Windows.Forms.Form].Assembly) System.Windows.Forms.NativeMethods
			$winConst = Get-Constant $NativeMethodsType WM_UPDATEUISTATE, UIS_CLEAR, UIS_SET, UISF_HIDEFOCUS, UISF_HIDEACCEL
			$MAKELONG = Get-Method (Get-NestedType $NativeMethodsType Util) MAKELONG

			# make sure the focus cues are rendered throughout the form
			[void]$SendMessage.Invoke($this, @($winConst.WM_UPDATEUISTATE, $MAKELONG.Invoke($null, @($winConst.UIS_CLEAR, $winConst.UISF_HIDEFOCUS)), 0))
			# make sure the keyboard cues are NOT rendered throughout the form
			[void]$SendMessage.Invoke($this, @($winConst.WM_UPDATEUISTATE, $MAKELONG.Invoke($null, @($winConst.UIS_SET, $winConst.UISF_HIDEACCEL)), 0))
		})
		$monitor.Form.add_Shown({
			$this.Activate()
		})

		$panel = New-Object Windows.Forms.TableLayoutPanel
		$panel.ColumnCount = 1
		$panel.RowCount = 0
		$panel.Dock = [Windows.Forms.DockStyle]::Fill

		Add-Member -InputObject $monitor -Name ProcessedLabel -MemberType NoteProperty -Value (New-Object Windows.Forms.Label)
		$monitor.ProcessedLabel.AutoSize = $true
		$monitor.ProcessedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		$monitor.ProcessedLabel.Anchor = [Windows.Forms.AnchorStyles]::Left
		Add-ControlToNextPanelRow $panel $monitor.ProcessedLabel

		Add-Member -InputObject $monitor -Name UpdatedLabel -MemberType NoteProperty -Value (New-Object Windows.Forms.Label)
		$monitor.UpdatedLabel.AutoSize = $true
		$monitor.UpdatedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		$monitor.UpdatedLabel.Anchor = [Windows.Forms.AnchorStyles]::Left
		Add-ControlToNextPanelRow $panel $monitor.UpdatedLabel

		Add-Member -InputObject $monitor -Name Log -MemberType NoteProperty -Value (New-Object Windows.Forms.TextBox)
		$monitor.Log.Multiline = $true
		$monitor.Log.ReadOnly = $true
		$monitor.Log.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
		$monitor.Log.BackColor = [Drawing.SystemColors]::Window
		$monitor.Log.Margin = New-Object Windows.Forms.Padding(0)
		$monitor.Log.Dock = [Windows.Forms.DockStyle]::Fill
		# get the HideCaret MethodInfo reflection and save it in the control's Tag property
		$monitor.Log.Tag = Get-Method (Get-PrivateType ([Windows.Forms.Form].Assembly) System.Windows.Forms.SafeNativeMethods) HideCaret
		$monitor.Log.add_GotFocus({
			# call the HideCaret method to hide the caret
			[void]$this.Tag.Invoke($null, @([Runtime.InteropServices.HandleRef](New-Object Runtime.InteropServices.HandleRef($this, $this.Handle))))
		})
		# set the style of the TableLayoutPanel's row for this control such that it stretches vertically as much as possible
		Add-ControlToNextPanelRow $panel $monitor.Log (New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100))

		$bottomPanel = New-Object Windows.Forms.TableLayoutPanel
		$bottomPanel.ColumnCount = 0
		$bottomPanel.RowCount = 1
		$bottomPanel.GrowStyle = [Windows.Forms.TableLayoutPanelGrowStyle]::AddColumns
		$bottomPanel.AutoSize = $true
		$bottomPanel.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
		$bottomPanel.Dock = [Windows.Forms.DockStyle]::Bottom

		$version = $PSVersionTable.PSVersion
		$versionLabel = New-Object Windows.Forms.Label
		$versionLabel.Text = 'PowerShell ' + $version.Major + '.' + $version.Minor
		$versionLabel.AutoSize = $true
		$versionLabel.Font = New-Object Drawing.Font($versionLabel.Font.FontFamily, [Single]($versionLabel.Font.Size * 0.8), $versionLabel.Font.Style, $versionLabel.Font.Unit)
		$versionLabel.Enabled = $false
		$versionLabel.Margin = New-Object Windows.Forms.Padding(2, 0, 0, 0)
		$versionLabel.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Bottom
		Add-ControlToNextPanelColumn $bottomPanel $versionLabel (New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100))

		Add-Member -InputObject $monitor -Name StopButton -MemberType NoteProperty -Value (New-Object Windows.Forms.Button)
		$monitor.StopButton.Tag = $monitor
		$monitor.StopButton.Text = 'Stop'
		$monitor.StopButton.Margin = New-Object Windows.Forms.Padding(10, 0, 0, 4)
		$monitor.StopButton.Enabled = $true
		$monitor.StopButton.add_Click({
			$state = $this.Tag.State
			if ($state.Pipe) {
				$state.AsyncStopHandle = $state.Pipe.BeginStop($null, $null)
				$state.Pipe = $null
				$this.Tag._ToggleButtons()
				$this.Tag._UpdateProcessedLabel()
			}
		})
		Add-ControlToNextPanelColumn $bottomPanel $monitor.StopButton

		Add-Member -InputObject $monitor -Name CloseButton -MemberType NoteProperty -Value (New-Object Windows.Forms.Button)
		$monitor.CloseButton.Tag = $monitor
		$monitor.CloseButton.Text = 'Close'
		$monitor.CloseButton.Margin = New-Object Windows.Forms.Padding(10, 0, 0, 4)
		$monitor.CloseButton.Enabled = $false
		$monitor.CloseButton.add_Click({
			$this.Tag.Form.Close()
		})
		Add-ControlToNextPanelColumn $bottomPanel $monitor.CloseButton

		Add-ControlToNextPanelRow $panel $bottomPanel

		$monitor.Form.Controls.Add($panel)
		$monitor.Form.CancelButton = $monitor.StopButton
		$monitor.Form.AcceptButton = $monitor.CloseButton
		$monitor.StopButton.Select()

		Add-Member -InputObject $monitor -Name _ToggleButtons -MemberType ScriptMethod -Value {
			$shouldSelect = [Object]::ReferenceEquals($this.Form.ActiveControl, $this.StopButton)

			$this.StopButton.Enabled = $false
			$this.CloseButton.Enabled = $true

			if ($shouldSelect) {
				$this.CloseButton.Select()
			}
		}

		Add-Member -InputObject $monitor -Name _UpdateProcessedLabel -MemberType ScriptMethod -Value {
			param (
				[Parameter(Position = 0, Mandatory = $false)]
				[Int32]
				$increment = 0
			)

			$count = ($this.State.Total += $increment)

			$ending = ''
			if ($count -ne 1) {
				$ending += 's'
			}
			if ($this.State.Contains('AsyncStopHandle')) {
				$ending += '; interrupted'
			}

			$this.ProcessedLabel.Text = "Processed $count user account$($ending)."
		}

		Add-Member -InputObject $monitor -Name _UpdateUpdatedLabel -MemberType ScriptMethod -Value {
			param (
				[Parameter(Position = 0, Mandatory = $false)]
				[Int32]
				$increment = 0
			)

			$count = ($this.State.Updated += $increment)

			$plural = ''
			if ($count -ne 1) {
				$plural += 's'
			}

			$this.UpdatedLabel.Text = "Updated $count user account$($plural):"
		}

		Add-Member -InputObject $monitor -Name _Update -MemberType ScriptMethod -Value {
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[Hashtable]
				$message
			)

			$this._UpdateProcessedLabel(1)

			if ($message.changes.count -gt 0) {
				# update the count & log of updated user accounts
				$this._UpdateUpdatedLabel(1)

				$logRecord = ''
				if ($this.State.Updated -gt 1) {
					$logRecord += [Environment]::NewLine
				}
				$logRecord += (Format-Message $message)
				$this.Log.AppendText($logRecord)
			}
		}

		Add-Member -InputObject $monitor -Name _UpdateAction -MemberType NoteProperty -Value ([Action[PSObject,Hashtable]]{
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[PSObject]
				$target
				,
				[Parameter(Position = 1, Mandatory = $true)]
				[Hashtable]
				$message
			)

			$target._Update($message)
		})

		Add-Member -InputObject $monitor -Name _Done -MemberType ScriptMethod -Value {
			param ()

			# the worker thread has finished processing of the user accounts;
			# disable the 'Stop' button & enable the 'Close' button
			$this._ToggleButtons()
		}

		Add-Member -InputObject $monitor -Name _DoneAction -MemberType NoteProperty -Value ([Action[PSObject]]{
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[PSObject]
				$target
			)

			$target._Done()
		})

		$monitor._UpdateProcessedLabel()
		$monitor._UpdateUpdatedLabel()
		$monitor.Form.Show()

		$pipe = [PowerShell]::Create()
		$monitor.State.Pipe = $pipe

		# define the Update & Done methods on the client thread to avoid performance
		# penatly of their invocations from the client thread on certain versions of
		# PowerShell
		[void]$pipe.AddScript({
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[PSObject]
				$monitor
			)

			Add-Member -InputObject $monitor -Name Update -MemberType ScriptMethod -Value {
				param (
					[Parameter(Position = 0, Mandatory = $true)]
					[Hashtable]
					$message
				)

				# schedule the _UpdateAtion handler for execution on the GUI thread
				[void]$this.Form.BeginInvoke($this._UpdateAction, $this, $message)
			}

			Add-Member -InputObject $monitor -Name Done -MemberType ScriptMethod -Value {
				param ()

				# schedule the _DoneAction handler for execution on the GUI thread
				[void]$this.Form.BeginInvoke($this._DoneAction, $this)
			}
		}).AddArgument($monitor)

		# now add the worker script block
		[void]$pipe.AddScript($scriptBlock)
		foreach ($a in $arguments) {
			[void]$pipe.AddArgument($a)
		}
		# append the monitor as the last argument
		[void]$pipe.AddArgument($monitor)

		# run the worker pipeline asynchronously
		$asyncHandle = $pipe.BeginInvoke()

		# run the event loop for the monitor form
		[Windows.Forms.Application]::run($monitor.Form)

		if ($monitor.State.AsyncStopHandle) {
			$pipe.EndStop($monitor.State.AsyncStopHandle)
		} elseif (-not $asyncHandle.IsCompleted) {
			$pipe.Stop()
		}
		if ($pipe.InvocationStateInfo.State -eq [Management.Automation.PSInvocationState]::Completed) {
			[void]$pipe.EndInvoke($asyncHandle)
		}
		$pipe.Dispose()
	}
}

function Run-Console
{
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[ScriptBlock]
		$scriptBlock
		,
		[Parameter(Position = 1, Mandatory = $false)]
		[Object[]]
		$arguments = @()
	)

	process {
		# we use PSObject because it doesn't lose custom properties when unboxed when passed
		# as an argument to .Net methods (in contrast to Object).
		$monitor = New-Object PSObject

		Add-Member -InputObject $monitor -Name Update -MemberType ScriptMethod -Value {
			param (
				[Parameter(Position = 0, Mandatory = $true)]
				[Hashtable]
				$message
			)

			if ($message.changes.count -gt 0) {
				[Console]::WriteLine((Format-Message $message))
			}
		}

		Add-Member -InputObject $monitor -Name Done -MemberType ScriptMethod -Value {
			param ()
		}

		# append the monitor as the last argument
		$arguments += $monitor

		Invoke-Command $scriptBlock -ArgumentList $arguments
	}
}

function Get-ConsoleWindowVisibility
{
	param ()

	process {
		$GetConsoleWindow = Get-Method (Get-PrivateType ([PSObject].Assembly) System.Management.Automation.ConsoleVisibility) GetConsoleWindow
		$IsWindowVisible = Get-Method (Get-PrivateType ([Windows.Forms.Form].Assembly) System.Windows.Forms.SafeNativeMethods) IsWindowVisible

		# get the console window handle
		$handle = [IntPtr]$GetConsoleWindow.Invoke($null, @())
		if ($handle -eq [IntPtr]::Zero) {
			$false
		} else {
			[Boolean]$IsWindowVisible.Invoke($null, @([Runtime.InteropServices.HandleRef](New-Object Runtime.InteropServices.HandleRef($IsWindowVisible, $handle))))
		}
	}
}

# main Main MAIN
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

if (Get-ConsoleWindowVisibility) {
	# log progress/changes to console if it is visible
	Run-Console $workerScriptBlock $accounts, $accountTemplate
} else {
	# log progress/changes to a windows forms dialog window if console is not visible
	Run-GUI $workerScriptBlock $accounts, $accountTemplate
}
