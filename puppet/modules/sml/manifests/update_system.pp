class sml::update_system {
	# update all packages on the system
	case $operatingsystem {
		'ubuntu', 'debian': {
			$apt_proxy = hiera('apt_proxy')

			file { '/etc/apt/apt.conf.d/10proxy':
				ensure => present,
				content => template("${module_name}/apt_proxy.erb"),
				owner => 'root',
				group => 'root',
				mode => 0644,
			}

			exec { 'apt-get-update':
				command => 'apt-get update',
				path => ['/usr/local/bin', '/bin', '/usr/bin'],
				logoutput => on_failure,
				timeout => 300,
				refreshonly => true,
				require => File['/etc/apt/apt.conf.d/10proxy'],
			}

			exec { 'apt-get-dist-upgrade':
				command => 'apt-get dist-upgrade -y',
				path => ['/usr/local/bin', '/sbin', '/bin', '/usr/sbin', '/usr/bin'],
				logoutput => on_failure,
				refreshonly => true,
				timeout => 0,
				subscribe => Exec['apt-get-update'],
				notify => Exec['reboot'],
			}
		}

		default: {
			exec { 'yum-update':
				command => 'yum update -y',
				path => ['/usr/local/bin', '/bin', '/usr/bin'],
				logoutput => on_failure,
				refreshonly => true,
				timeout => 0,
				notify => Exec['reboot'],
			}
		}
	}

	# reboot the system
	exec { 'reboot':
		command => 'sh -c \'sleep 30; init 6;\' &',
		path => ['/usr/local/bin', '/sbin', '/bin', '/usr/sbin', '/usr/bin'],
		refreshonly => true,
	}
}
