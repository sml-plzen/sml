class sml::mount_layout {
	include sml::params

	$prerequisites = [
		'perl',
		'libnet-dns-perl',
		'libnet-ldap-perl',
		'libauthen-krb5-perl',
		'libauthen-sasl-perl',
		'libgssapi-perl',
		'libfilesys-smbclient-perl',
		'libxml-simple-perl',
		'libunix-syslog-perl',
		'libnet-dbus-perl',
		'cifs-utils',
		'unison',
		'unison-gtk',
	]
	$params = {
		ensure => installed,
	}

	$apply_layout_script_link =
		inline_template("-apply_layout.pl?<%= URI.encode(scope.lookupvar('sml::params::volume_root_dir'), '%/:') %>")

	# Use the ensure_resources function to prevent conflicts
	ensure_resources(Package[$prerequisites], $params)

	file { '/etc/mtab':
		ensure => link,
		target => '/proc/mounts',
	}

	file { '/etc/rc.local':
		ensure => present,
		source => "puppet:///modules/${module_name}/rc.local",
		owner => 'root',
		group => 'root',
		mode => '0755',
	}

	file { $sml::params::volume_root_dir:
		ensure => directory,
		owner => 'root',
		group => 'root',
		mode => '0755',
	}

	file { '/etc/security/namespace.d/apply_layout.pl':
		ensure => present,
		source => "puppet:///modules/${module_name}/mount-namespace/apply_layout.pl",
		owner => 'root',
		group => 'root',
		mode => '0755',
		require => [Package[$prerequisites], File[$sml::params::volume_root_dir]],
	}

	file { "/etc/security/namespace.d/${apply_layout_script_link}":
		ensure => link,
		target => 'apply_layout.pl',
		require => File['/etc/security/namespace.d/apply_layout.pl'],
	}

	file { '/etc/security/namespace.conf':
		ensure => present,
		content => template("${module_name}/namespace.conf.erb"),
		owner => 'root',
		group => 'root',
		mode => '0644',
		require => File["/etc/security/namespace.d/${apply_layout_script_link}"],
	}

	pam::profile { 'private-mount-namespace':
		source => "puppet:///modules/${module_name}/mount-namespace/private-mount-namespace",
		require => File['/etc/security/namespace.conf'],
	}

	file { '/usr/local/bin/gtk-session-user-dirs-setup.pl':
		ensure => present,
		source => "puppet:///modules/${module_name}/gtk-session-user-dirs-setup/gtk-session-user-dirs-setup.pl",
		owner => 'root',
		group => 'root',
		mode => '0755',
	}

	file { '/usr/local/bin/directory-synchronizer.pl':
		ensure => present,
		source => "puppet:///modules/${module_name}/gtk-session-user-dirs-setup/directory-synchronizer.pl",
		owner => 'root',
		group => 'root',
		mode => '0755',
	}

	file { [
		'/usr/share/gnome',
		'/usr/share/gnome/autostart',
	]:
		ensure => directory,
	}

	file { '/usr/share/gnome/autostart/gtk-session-user-dirs-setup.desktop':
		ensure => present,
		content => template("${module_name}/gtk-session-user-dirs-setup.desktop.erb"),
		owner => 'root',
		group => 'root',
		mode => '0644',
		require => File[
			'/usr/local/bin/gtk-session-user-dirs-setup.pl',
			'/usr/local/bin/directory-synchronizer.pl'
		],
	}

	# We need to remove this autorun entry so that the xdg-user-dirs-gtk-update
	# program it launches doesn't write to the ~/.gtk-bookmarks file at the same
	# time the gtk-session-user-dirs-setup above does.
	# Besides the xdg-user-dirs-gtk-update is executed from within
	# the the gtk-session-user-dirs-setup, so its functionality is not lost.
	file { '/etc/xdg/autostart/user-dirs-update-gtk.desktop':
		ensure => absent,
	} <- Package<| |>
}
