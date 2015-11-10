class sml::domain_login_screen {
	include sml::software

	augeas { 'domain-login-screen-configure':
		incl => '/etc/lightdm/lightdm.conf',
		#Use this lens once it's available
		#lens => 'Lightdm.lns',
		lens => 'Puppet.lns',
		changes => [
			'set SeatDefaults/greeter-show-manual-login true',
			'set SeatDefaults/greeter-hide-users true',
		],
		notify => Service['lightdm'],
		require => Class['sml::software'],
	}

	service { 'lightdm':
		ensure => running,
		enable => true,
	}
}
