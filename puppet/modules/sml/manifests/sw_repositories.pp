class sml::sw_repositories {
	case $operatingsystem {
		# register debian repos of google chrome and opera browsers
		'ubuntu', 'debian': {
			apt::source { 'google-chrome':
				ensure      => absent, # google-chrome is no longer supported on this ubuntu version
				location    => 'http://dl.google.com/linux/chrome/deb/',
				release     => 'stable',
				repos       => 'main',
				key         => '7FAC5991',
				key_server  => 'keys.gnupg.net',
				include_src => false,
			}

			apt::source { 'opera':
				location    => 'http://deb.opera.com/opera/',
				release     => 'stable',
				repos       => 'non-free',
				key         => 'A5C7FF72',
				key_server  => 'keys.gnupg.net',
				include_src => false,
			}

			# Remove old Opera keys
			apt::key { ['30C18A2B', 'A8492E35', 'F6D61D45']:
				ensure      => absent,
				key_server  => 'keys.gnupg.net',
			}
		}
	}
}
