class sml::params {
	$volume_root_dir = hiera('volume_root_dir', '/volume')
	$remote_home_mirror_dir = hiera('remote_home_mirror_dir', 'Synchronized')
	$remote_home_mirror_dir_bookmark_name = hiera('remote_home_mirror_dir_bookmark_name', 'Synchronized')
}
