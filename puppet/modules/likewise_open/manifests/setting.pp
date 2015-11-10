define likewise_open::setting($value) {
	include likewise_open

	likewise_open_setting { $title:
		value => $value,
	}
}
