class sml::graphical_boot {
	case $operatingsystem {
		# configure graphical boot on ubuntu (debian?)
		'ubuntu', 'debian': {
			augeas { 'graphical-boot-enable':
				incl => '/etc/default/grub',
				lens => 'Shellvars.lns',
				changes => [
					'set GRUB_HIDDEN_TIMEOUT 0',
					'set GRUB_HIDDEN_TIMEOUT_QUIET true',
					"set GRUB_CMDLINE_LINUX_DEFAULT '\"quiet splash\"'",
				],
				notify => Exec['grub-update'],
			}

			exec { 'grub-update':
				command => 'update-grub',
				path => ['/usr/local/bin', '/sbin', '/bin', '/usr/sbin', '/usr/bin'],
				refreshonly => true,
			}
		}
	}
}
