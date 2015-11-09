param(
	[Parameter(Position=0, Mandatory=$false)]
	[string[]]
	#$accounts = @('Remote Desktop Users')
	$accounts = @('Students', 'Teachers', 'mise')
)

# this script block defines functions used in both the main code and the background job
$libraryScriptBlock = {
	param()

	function Get-ProcAddress {
		param (
			[Parameter(Position = 0, Mandatory = $true)]
			[String]
			$module
			,
			[Parameter(Position = 1, Mandatory = $true)]
			[String]
			$procedure
		)

		begin {
			# get the UnsafeNativeMethods class from the System assembly;
			# note that we can't use it directly like in:
			#   [Microsoft.Win32.UnsafeNativeMethods]
			# as it is a private class
			$unsafeNativeMethods = ([AppDomain]::CurrentDomain.getAssemblies() | Where-Object {
				$_.GetName().Name -eq 'System'
			}).GetType('Microsoft.Win32.UnsafeNativeMethods')

			# get references to the GetModuleHandle and GetProcAddress methods
			$GetModuleHandle = $unsafeNativeMethods.GetMethod('GetModuleHandle')
			$GetProcAddress = $unsafeNativeMethods.GetMethod('GetProcAddress')
		}

		process {
			# get a HandleRef to the specified module
			$moduleHandleRef = New-Object Runtime.InteropServices.HandleRef(
				(New-Object Object),
				$GetModuleHandle.Invoke($null, @($module))
			)
			# return the address of the specified function
			$GetProcAddress.Invoke($null, @([Runtime.InteropServices.HandleRef]$moduleHandleRef, $procedure))
		}
	}

	function Get-ProcDelegateType {
		Param (
			[Parameter(Position = 0, Mandatory = $true)]
			[Type[]]
			$parameterTypes
			,
			[Parameter(Position = 1, Mandatory = $false)]
			[Type]
			$returnType = [void]
		)

		begin {
			# get a delegate type builder
			$typeBuilder = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
				(New-Object Reflection.AssemblyName('InMemoryAssembly')),
				[Reflection.Emit.AssemblyBuilderAccess]::Run
			).DefineDynamicModule('InMemoryModule', $false).DefineType(
				'ProcDelegateType',
				'Class, Public, Sealed, AnsiClass, AutoClass',
				[MulticastDelegate]
			)
		}

		process {
			# define the delegate type constructor ...
			$typeBuilder.DefineConstructor(
				'RTSpecialName, HideBySig, Public',
				[Reflection.CallingConventions]::Standard,
				$parameterTypes
			).SetImplementationFlags('Runtime, Managed')

			# ... and the Invoke method
			$typeBuilder.DefineMethod(
				'Invoke',
				'Public, HideBySig, NewSlot, Virtual',
				$returnType,
				$parameterTypes
			).SetImplementationFlags('Runtime, Managed')

			# create the delegate type and return it
			$typeBuilder.CreateType()
		}
	}

	function Get-ProcDelegate {
		param (
			[Parameter(Position = 0, Mandatory = $true)]
			[String]
			$module
			,
			[Parameter(Position = 1, Mandatory = $true)]
			[String]
			$procedure
			,
			[Parameter(Position = 2, Mandatory = $true)]
			[Type[]]
			$parameterTypes
			,
			[Parameter(Position = 3, Mandatory = $false)]
			[Type]
			$returnType = [void]
		)

		process {
			[Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
				(Get-ProcAddress $module $procedure),
				(Get-ProcDelegateType $parameterTypes $returnType)
			)
		}
	}
}

# this script block defines the code which is the purpose of the script
# the rest is just presentation
$workerScriptBlock = {
	param($accounts, $hwnd)

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

	$hwnd = ($hwnd.toString() -as [UInt32]) -as [IntPtr]
	$PostMessageW = Get-ProcDelegate user32.dll PostMessageW @([IntPtr], [UInt32], [IntPtr], [IntPtr]) ([boolean])

	([adsisearcher](
		"(&(|(objectClass=group)(objectClass=user))(|$(($accounts | % { "(sAMAccountName=$_)" }) -join '')))"
	)).findAll() | ForEach-Object { $_.getDirectoryEntry() } | Get-User | ForEach-Object {
		$newHomeDirectory = "\\INTRANET\$($_.sAMAccountName)"

		# update the user account only if we need to
		if ($_.homeDirectory.value -ne $newHomeDirectory) {
			$_.homeDirectory = $newHomeDirectory
			$_.commitChanges()

			# emit an object communicating to the foreground code the updated
			# user account
			New-Object PSCustomObject -Property @{
				messageType = 2
				distinguishedName = $_.distinguishedName.value
				homeDirectory = $_.homeDirectory.value
			}
		} else {
			# emit an object indicationg to the foreground code that we've
			# proessed another user account but didn't need to update it
			New-Object PSCustomObject -Property @{ messageType = 1 }
		}

		# post a WM_USER message to the form window displayed by the foreground code
		# to ensure sure the Application.Idle handler (where the ouput of this job
		# is processed) is called
		# 0x0400 = WM_USER
		[void]$PostMessageW.Invoke($hwnd, 0x0400, [IntPtr]::Zero, [IntPtr]::Zero)
	}

	# emit an object indicating to the foreground code that we are done
	New-Object PSCustomObject -Property @{ messageType = 0 }

	# make sure the foreground code notices we are done
	for(;;) {
		# post a WM_USER message to the form window displayed by the foreground code
		# to ensure the Application.Idle handler (where the ouput of this job
		# is processed) is called
		# 0x0400 = WM_USER
		[void]$PostMessageW.Invoke($hwnd, 0x0400, [IntPtr]::Zero, [IntPtr]::Zero)
		Start-Sleep -Milliseconds 100
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
			"Updated home directory of $count user:"
		} else {
			"Updated home directories of $count users:"
		}
	}
}

function Get-FieldValue
{
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[Object]
		$object
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[Type]
		$type
		,
		[Parameter(Position = 2, Mandatory = $true)]
		[String]
		$fieldName
	)

	process {
		$finfo = $type.GetField($fieldName, [Reflection.BindingFlags]([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
		$finfo.GetValue($object)
	}
}

function Get-PropertyValue
{
	param(
		[Parameter(Position = 0, Mandatory = $true)]
		[Object]
		$object
		,
		[Parameter(Position = 1, Mandatory = $true)]
		[String]
		$propertyName
	)

	process {
		$pinfo = $object.GetType().GetProperty($propertyName, [Reflection.BindingFlags]([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
		$pinfo.GetValue($object, @())
	}
}

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
	public class ExtendedUICuesEventArgs : System.Windows.Forms.UICuesEventArgs {

		private readonly int origCuesState;
		private readonly int newCuesState;
		private readonly System.Windows.Forms.Message message;

		public int OrigCuesState {
			get {
				return origCuesState;
			}
		}

		public int NewCuesState {
			get {
				return newCuesState;
			}
		}

		public System.Windows.Forms.Message Message {
			get {
				return message;
			}
		}

		public ExtendedUICuesEventArgs(
			System.Windows.Forms.UICues uicues,
			int origCuesState,
			int newCuesState,
			System.Windows.Forms.Message message
		) : base(uicues) {
			this.origCuesState = origCuesState;
			this.newCuesState = newCuesState;
			this.message = message;
		}

	}

	public class SpyForm : System.Windows.Forms.Form {

		private readonly System.Reflection.FieldInfo uiCuesStateField = typeof(System.Windows.Forms.Control).GetField(
			"uiCuesState",
			System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic
		);

		public int getUiCuesState() {
			return (int) uiCuesStateField.GetValue(this);
		}

		protected override void WndProc(ref System.Windows.Forms.Message m) {
			int origUiCuesState = getUiCuesState();

			base.WndProc(ref m);

			int newUiCuesState = getUiCuesState();

			if ((origUiCuesState & 0xff) != (newUiCuesState & 0xff)) {
				System.Windows.Forms.UICues uicues = System.Windows.Forms.UICues.None;

				if ((origUiCuesState & 0x0f) != (newUiCuesState & 0x0f)) {
					uicues |= System.Windows.Forms.UICues.ChangeFocus;
					if ((newUiCuesState & 0x02) != 0)
						uicues |= System.Windows.Forms.UICues.ShowFocus;
				}

				if ((origUiCuesState & 0xf0) != (newUiCuesState & 0xf0)) {
					uicues |= System.Windows.Forms.UICues.ChangeKeyboard;
					if ((newUiCuesState & 0x20) != 0)
						uicues |= System.Windows.Forms.UICues.ShowKeyboard;
				}

				OnChangeUICues(new ExtendedUICuesEventArgs(uicues, origUiCuesState, newUiCuesState, m));
			}
		}

	}
"@

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
			$SendMessageW = Get-ProcDelegate user32.dll SendMessageW @([IntPtr], [UInt32], [IntPtr], [IntPtr]) ([IntPtr])

			# make sure the keyboard cues are NOT rendered throughout the form
			# 0x0128  = WM_UPDATEUISTATE
			# 0x20001 = MAKEWPARAM(UIS_SET, UISF_HIDEACCEL)
			[void]$SendMessageW.Invoke($this.handle, 0x0128, [IntPtr]0x20001, [IntPtr]::Zero)

			# make sure the focus cues are rendered throughout the form
			# 0x0128  = WM_UPDATEUISTATE
			# 0x10002 = MAKEWPARAM(UIS_CLEAR, UISF_HIDEFOCUS)
			[void]$SendMessageW.Invoke($this.handle, 0x0128, [IntPtr]0x10002, [IntPtr]::Zero)
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
		$formUserData.ProcessedLabel.Dock = [Windows.Forms.DockStyle]::Left
		$formUserData.ProcessedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		++$panel.RowCount
		[void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle))
		$panel.Controls.Add($formUserData.ProcessedLabel)

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name UpdatedLabel -Value (New-Object Windows.Forms.Label)
		$formUserData.UpdatedLabel.Text = Get-UpdatedLabelText
		$formUserData.UpdatedLabel.AutoSize = $true
		$formUserData.UpdatedLabel.Dock = [Windows.Forms.DockStyle]::Left
		$formUserData.UpdatedLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2)
		++$panel.RowCount
		[void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle))
		$panel.Controls.Add($formUserData.UpdatedLabel)

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name Log -Value (New-Object Windows.Forms.TextBox)
		$formUserData.Log.Multiline = $true
		$formUserData.Log.ReadOnly = $true
		$formUserData.Log.BackColor = [Drawing.SystemColors]::Window
		$formUserData.Log.Dock = [Windows.Forms.DockStyle]::Fill
		$formUserData.Log.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
		$formUserData.Log.Margin = New-Object Windows.Forms.Padding(0)
		# get a delegate for the HideCaret Windows API call and save it
		# in the control's Tag property
		$formUserData.Log.Tag = Get-ProcDelegate user32.dll HideCaret @([IntPtr]) ([boolean])
		$formUserData.Log.add_GotFocus({
			# call the HideCaret Windows API to hide the caret
			[void]$this.Tag.Invoke($this.handle)
		})
		++$panel.RowCount
		# make the TableLayoutPanel's cell for this control strech its height as much as possible
		[void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
		$panel.Controls.Add($formUserData.Log)

		Add-Member -InputObject $formUserData -MemberType NoteProperty -Name Button -Value (New-Object Windows.Forms.Button)
		$formUserData.Button.Text = 'Cancel'
		$formUserData.Button.Dock = [Windows.Forms.DockStyle]::Right
		$formUserData.Button.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 0)
		$formUserData.Button.add_Click({
			$this.TopLevelControl.Close()
		})
		++$panel.RowCount
		[void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle))
		$panel.Controls.Add($formUserData.Button)

		$form.AcceptButton = $formUserData.Button
		$form.AcceptButton.Select()

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
	# (we need to pass the handle to the background job as an argument)
	$workerJob = Start-Job -InitializationScript $libraryScriptBlock -ScriptBlock $workerScriptBlock -ArgumentList $accounts, $this.handle
})

# stop the worker job (if not already stopped) when the form is closing
$form.add_Closing({
	if ($workerJob) {
		Remove-Job -Job $workerJob -Force
		$workerJob = $null
	}
})

$total = 0
$updated = 0
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
			} elseif ($_.messageType -lt 3) {
				# update the count of processed user accounts
				$form.Tag.ProcessedLabel.Text = Get-ProcessedLabelText (++$total)
				if ($_.messageType -lt 2) {
					return
				}

				# update the count & list of updated user accounts
				$form.Tag.UpdatedLabel.Text = Get-UpdatedLabelText (++$updated)
				$form.Tag.Log.Lines += $_.distinguishedName
				$form.Tag.Log.Lines += '  ' + $_.homeDirectory
			}
		}
	}
})

if ($form) {
	# make sure the form is shown even if the process was started with SW_HIDE
	$form.Show()
	[Windows.Forms.Application]::run($form)
}
