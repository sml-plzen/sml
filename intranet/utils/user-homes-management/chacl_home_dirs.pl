#!/usr/bin/perl

use strict;
use warnings;

use File::Find;

use constant DEFAULT_GROUP => 'SML\Domain Users';

while(<>) {
	chomp();
	@_ = getpwnam($_)
		or warn('User not found: ', $_, "\n"), next;

	my $acl = "user::rwx,user:$_[0]:rwx,group::---,other::---,mask::rwx,group:SML\\Domain Admins:rwx,group:SML\\SIS:rwx";

	find({ wanted => sub {
		@_ = ($acl, $_);
		if (-d $_) {
			unshift(@_, '-b', $acl);
		}
		unshift(@_, 'chacl');
		system(@_);
	}, no_chdir => 1 }, $_[7]);
}
