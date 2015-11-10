#!/usr/bin/perl
use strict;
use warnings;

use Net::DBus qw( :typing );
use Net::DBus::Reactor;
use File::Basename;
use POSIX qw( :sys_wait_h );

my $myname;
my $display;
my $client;
my $reactor;
my $worker_pid;
my @roots;

sub log_message(@) {
	print(STDERR $myname, ': ', @_, "\n");
}

sub log_and_die(@) {
	log_message(@_);
	exit(1);
}

sub reap_worker() {
	if (waitpid($worker_pid, WNOHANG) > 0) {
		$worker_pid = undef;
		1;
	} else {
		0;
	}
}

sub run_worker(;$) {
	if (defined($worker_pid)) {
		return unless reap_worker();
	}

	my ($occasion) = @_;
	$occasion = 0 unless defined($occasion);

	$worker_pid = fork();
	if (defined($worker_pid) && !$worker_pid) {
		# run the synchronization
		exec(qw( unison -batch -fat -dumbtty -terse ), @roots);
		exit(127);
	}
}

sub register_gsm_client() {
	my $bus = Net::DBus->session();

	my $sm_service = $bus->get_service('org.gnome.SessionManager');
	my $sm = $sm_service->get_object('/org/gnome/SessionManager', 'org.gnome.SessionManager');

	my $client_path = $sm->RegisterClient($myname, '');

	$sm_service->get_object($client_path, 'org.gnome.SessionManager.ClientPrivate');
}

sub handle_query_end_session() {
	$client->EndSessionResponse(dbus_boolean(1), undef);
	run_worker(2);
}

sub handle_end_session() {
	$client->EndSessionResponse(dbus_boolean(1), undef);
	$reactor->shutdown();
}


# main Main MAIN
$myname = basename($0);

@ARGV == 2
	or log_and_die('Expected 2 parameters: <directory 1> <directory 2>, got: ', join(' ', map("<$_>", @ARGV)));

@roots = splice(@ARGV, 0, 2);

# make sure unison does not start its UI
$display = delete($ENV{DISPLAY});

$client = register_gsm_client();

$client->connect_to_signal('QueryEndSession', \&handle_query_end_session);
$client->connect_to_signal('EndSession', \&handle_end_session);
$client->connect_to_signal('Stop', \&handle_end_session);

$SIG{CHLD} = \&reap_worker;

$reactor = Net::DBus::Reactor->main();
$reactor->add_timeout(10 * 60 * 1000, \&run_worker);

run_worker(1);
$reactor->run();
