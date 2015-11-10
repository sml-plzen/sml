class pam::update {
	exec { 'pam-update':
		command => 'pam-auth-update --package',
		path => ['/usr/local/bin', '/sbin', '/bin', '/usr/sbin', '/usr/bin'],
		logoutput => on_failure,
		refreshonly => true,
	}
}
