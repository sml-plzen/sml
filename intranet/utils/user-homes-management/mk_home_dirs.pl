#!/usr/bin/perl

use strict;
use warnings;

use constant MK_HOME_DIR => '/var/lib/samba/scripts/create_home_directory.sh';
use constant DEFAULT_GROUP => 'SML\Domain Users';

while(<>) {
	chomp();
	@_ = getpwnam($_)
		or warn('User not found: ', $_, "\n"), next;

	@_ = (MK_HOME_DIR, $_[7], $_, DEFAULT_GROUP);
	print(join(' ', @_), "\n");
	system(@_);
}
