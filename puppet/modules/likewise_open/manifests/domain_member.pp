class likewise_open::domain_member {
	include likewise_open

	$domain = hiera('ad_domain')

	if ($joined_domain != $domain) {
		$quoted_login = shellquote(hiera('ad_admin_login'))
		$quoted_password = shellquote(hiera('ad_admin_password'))

		exec { 'lw-domainjoin':
			command => "domainjoin-cli join ${domain} ${quoted_login} ${quoted_password}",
			tries => 4,
			try_sleep => 30,
			path => ['/usr/local/bin', '/bin', '/usr/bin'],
			require => Package[$likewise_open::prerequisites],
		} -> Likewise_open_setting<| |>
	}
}
