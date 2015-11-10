define pam::profile(
	$content = undef,
	$source = undef
) {
	include pam::update

	$standard_params = {
		ensure => present,
		owner => 'root',
		group => 'root',
		mode => 0644,
		notify => Exec['pam-update'],
	}

	if ($content != undef) {
		$source_param = {
			content => $content,
		}
	} elsif ($source != undef) {
		$source_param = {
			source => $source,
		}
	} else {
		fail('content or source must be specified')
	}

	$resource_template = { "/usr/share/pam-configs/${title}" => $source_param }

	create_resources('file', $resource_template, $standard_params)
}
