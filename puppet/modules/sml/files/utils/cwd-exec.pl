#!/usr/bin/perl
use strict;
use warnings;

use File::Basename;

my $myname;

sub log_message(@) {
	print(STDERR $myname, ': ', @_, "\n");
}

sub log_and_die(@) {
	log_message(@_);
	exit(126);
}


# main Main MAIN
$myname = basename($0);

@ARGV >= 2
	or log_and_die('Expected at least 2 parameters: <directory> <executable> [<argument> ...]');

chdir($ARGV[0])
	or log_and_die("Could not change directory to $ARGV[0]: $!");

exec(splice(@ARGV, 1));
exit(127);
