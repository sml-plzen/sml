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

sub get_unc_mount_pattern(@) {
	my (@unc) = @_;
	my $unc = join('[\\\\/]', map(quotemeta(lc($_)), @unc));

	qr/^$unc$/i;
}

sub unescape_mount($) {
	my ($string) = @_;

	$string =~ s/\\([0-7]{3})/chr(oct($1))/eg;

	$string;
}

sub find_mount_dir($) {
	my ($pattern) = @_;
	my $fh;

	open($fh, '<', '/proc/mounts')
		or return undef;

	my $result = undef;
	while (<$fh>) {
		@_ = split(' ', $_, 3);
		if (unescape_mount($_[0]) =~ $pattern) {
			$result = unescape_mount($_[1]);
			last;
		}
	}

	close($fh);

	$result;
}


# main Main MAIN
$myname = basename($0);

@ARGV >= 2
	or log_and_die('Expected at least 2 parameters: <unc path> <exe file> [<argument> ...]');

my @uncPath = split(/[\\\/]/, $ARGV[0]);
@uncPath >= 4 && length($uncPath[0]) == 0 && length($uncPath[1]) == 0 && length($uncPath[2]) > 0 && length($uncPath[3]) > 0
	or log_and_die('Invalid UNC path: ', $ARGV[0]);

my $mountPoint = find_mount_dir(get_unc_mount_pattern(@uncPath[0..3]));
defined($mountPoint)
	or log_and_die('UNC not mounted: ', join('\\', @uncPath[0..3]));

$ARGV[0] = join('/', $mountPoint, splice(@uncPath, 4));

chdir($ARGV[0])
	or log_and_die("Could not change directory to $ARGV[0]: $!");

exec('wine', splice(@ARGV, 1));
exit(127);
