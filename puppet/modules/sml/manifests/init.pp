class sml {
	include sml::update_system

	case $operatingsystem {
		# enable puppet on ubuntu (debian?)
		'ubuntu', 'debian': {
			augeas { 'puppet-agent-enable':
				incl => '/etc/default/puppet',
				lens => 'Shellvars.lns',
				changes => [
					'set START yes',
				],
				notify => Service['puppet'],
			}
		}
	}

	augeas { 'puppet-agent-configure':
		incl => '/etc/puppet/puppet.conf',
		lens => 'Puppet.lns',
		changes => [
			# this is the default now
			#'set agent/pluginsync true',
			'rm agent/pluginsync',
			'rm main/templatedir',
		],
		notify => Service['puppet'],
	}

	service { 'puppet':
		ensure => running,
		enable => true,
		notify => Class['sml::update_system'],
	}
}
