#!/usr/bin/perl

use strict;
use warnings;

use constant DEFAULT_GROUP => 'SML\Domain Users';

while(<>) {
	chomp();
	@_ = getpwnam($_)
		or warn('User not found: ', $_, "\n"), next;

	#@_ = ('find', $_[7], qw(! -user), $_, '-o', qw(! -group), DEAFULT_GROUP);
	@_ = (qw(chown -cR), join(':', $_, DEFAULT_GROUP), $_[7]);
	print(join(' ', @_), "\n");
	system(@_);
}
