class sml::domain_member {
	include likewise_open::domain_member

	$homedir_template = '%H/%D/%U'

	likewise_open::setting {
		'AssumeDefaultDomain':
			value => true;

		'HomeDirTemplate':
			value => $homedir_template;

# a separate home directory is created on each host but a subdirectory
# of it is kept in sync with the network home directory
#		'CreateHomeDir':
#			value => false;
		'CreateHomeDir':
			value => true;

		'Local_HomeDirTemplate':
			value => $homedir_template;
	}

	file { '/etc/sudoers.d/domain-sudoers':
		source => "puppet:///modules/${module_name}/domain-sudoers",
		owner => 'root',
		group => 'root',
		mode => '0440',
		require => Class['likewise_open::domain_member'],
	}
}
