class likewise_open {
	$prerequisites = [
		'likewise-open',
	]
	$params = {
		ensure => installed,
	}

	# Use the ensure_resources function to prevent conflicts
	ensure_resources(Package[$prerequisites], $params)

	Package[$prerequisites] -> Likewise_open_setting<| |>

	exec { 'lw-refresh-configuration':
		path => ['/usr/local/bin', '/bin', '/usr/bin'],
		refreshonly => true,
		require => Package[$prerequisites],
	} <~ Likewise_open_setting<| |>
}
