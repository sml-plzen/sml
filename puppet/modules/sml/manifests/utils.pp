class sml::utils {
	#file { '/usr/local/bin/wine-unc-exec.pl':
	#	ensure => present,
	#	source => "puppet:///modules/${module_name}/utils/wine-unc-exec.pl",
	#	owner => 'root',
	#	group => 'root',
	#	mode => '0755',
	#}

	file { '/usr/local/bin/cwd-exec.pl':
		ensure => present,
		source => "puppet:///modules/${module_name}/utils/cwd-exec.pl",
		owner => 'root',
		group => 'root',
		mode => '0755',
	}
}
