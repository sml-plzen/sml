#!/usr/bin/perl
use strict;
use warnings;

use Authen::Krb5;
use File::Basename;
use File::Spec;
use Unix::Syslog;
use POSIX ();
use Config qw(%Config);

use constant IMAGE_DISPLAY_TIME => 6;
use constant MEDIA_RESCAN_TIME => 120;

use constant ERROR_WAIT_TIME => 300;

use constant CRED_VALID_TIME => 3600;

use constant MOUNT_POINT => '/mnt';


{
	package Presenter;

	my $plymouth_deactivated = 0;

	sub new($) {
		my ($class) = @_;
		my $self = bless({}, ref($class) || $class);

		$self;
	}

	sub batch_presenter($) {
		0;
	}

	sub present($@) {
		my ($self, @files) = @_;

		unless ($plymouth_deactivated) {
			$plymouth_deactivated = 1;
			main::execute(qw(/bin/plymouth deactivate));
		}

		$self->do_present(@files);

		if ($plymouth_deactivated) {
			$plymouth_deactivated = 0;
			main::execute(qw(/bin/plymouth reactivate));
		}
	}

	sub do_present($@) {
	}
}


{
	package VideoPresenter;

	use base qw(Presenter);

	sub do_present($@) {
		my ($self, @files) = @_;

		main::execute(qw(omxplayer), @files);
	}
}

{
	package ImagePresenter;

	use base qw(Presenter);

	sub new($$) {
		my ($class, $timeout) = @_;
		my $self = $class->SUPER::new();

		$$self{TIMEOUT} = $timeout;

		$self;
	}

	sub batch_presenter($) {
		1;
	}

	sub do_present($@) {
		my ($self, @files) = @_;

		main::execute(qw(fbi -noverbose -nocomments -noedit -autozoom -once -timeout), $$self{TIMEOUT}, @files);
	}
}

my %presenters;

{
	my $video_presenter = VideoPresenter->new();
	my $image_presenter = ImagePresenter->new(IMAGE_DISPLAY_TIME);

	%presenters = (
		'mp4' => $video_presenter
		,
		'm4v' => $video_presenter
		,
		'mov' => $video_presenter
		,
		'jpg' => $image_presenter
		,
		'jpeg' => $image_presenter
		,
		'png' => $image_presenter
	);
}


my $myname;

sub log_message(@) {
	Unix::Syslog::openlog($myname . '[' . $$ . ']', 0, Unix::Syslog::LOG_DAEMON);
	Unix::Syslog::syslog(Unix::Syslog::LOG_ERR, join('', @_));
	Unix::Syslog::closelog();
}

sub log_and_wait($@) {
	my ($sleep_time, @message) = @_;
	log_message(@message);
	sleep($sleep_time);
}

sub principal_str($) {
	my ($principal) = @_;

	defined($principal)
		or return undef;

	join('/', $principal->data()) . '@' . $principal->realm();
}

sub same_principals($$) {
	my ($l, $r) = @_;

	unless (defined($l)) {
		return defined($r) ? 0 : 1;
	} else {
		return 0 unless defined($r);
	}

	return 0 unless $l->type() == $r->type();
	return 0 unless $l->realm() eq $r->realm();

	my @dl = $l->data();
	my @dr = $r->data();

	return 0 unless @dl == @dr;

	for (0 .. $#dl) {
		return 0 unless $dl[$_] eq $dr[$_];
	}

	1;
}

sub find_host_principal($) {
	my ($kt) = @_;

	my $cursor = $kt->start_seq_get();
	defined($cursor)
		or return undef;

	my $principal;

	eval {
		my $entry;
		my @entry_data;

		while (defined($entry = $kt->next_entry($cursor))) {
			$entry = $entry->principal();
			@entry_data = $entry->data();
			if (@entry_data == 1 && $entry_data[0] =~ /\$$/) {
				$principal = $entry;
				last;
			}
		}

		$kt->end_seq_get($cursor);
	};

	$principal;
}

sub find_tgt_ticket($$) {
	my ($cc, $realm) = @_;

	my $cursor = $cc->start_seq_get();
	defined($cursor)
		or return undef;

	my $cred;

	eval {
		my $entry;
		my $tgt = 'krbtgt/' . $realm . '@' . $realm;

		while (defined($entry = $cc->next_cred($cursor))) {
			if ($entry->server() eq $tgt) {
				$cred = $entry;
				last;
			}
		}

		$cc->end_seq_get($cursor);
	};

	$cred;
}

sub need_refresh_credentials($$) {
	my ($cc, $principal) = @_;

	same_principals($principal, $cc->get_principal())
		or return 1;

	my $cred = find_tgt_ticket($cc, $principal->realm());

	(defined($cred) && $cred->endtime() > time() + CRED_VALID_TIME) ? 0 : 1;
}

sub refresh_credentials($$$) {
	my ($kt, $principal, $cc) = @_;
	my $tgt = Authen::Krb5::get_init_creds_keytab($principal, $kt);

	unless (defined($tgt)) {
		$@ = join('',
			'Failed to authenticate ', principal_str($principal), ': ',
			Authen::Krb5::error(Authen::Krb5::error())
		);
		return 0;
	}

	$cc->initialize($principal);
	$cc->store_cred($tgt);
	1;
}

sub unescape_mount($) {
	my ($string) = @_;

	$string =~ s/\\([0-7]{3})/chr(oct($1))/eg;

	$string;
}

sub is_mounted($) {
	my ($mount_point) = @_;
	my $fh;

	open($fh, '<', '/proc/mounts')
		or return undef;

	my $result = 0;
	while (<$fh>) {
		@_ = split(' ', $_, 3);
		if (unescape_mount($_[1]) eq $mount_point) {
			$result = 1;
			last;
		}
	}

	close($fh);

	$result;
}

sub parse_unc_path($$) {
	my ($unc, $mount_point) = @_;
	my @segments = split(/[\\\/]/, $unc);

	(
		@segments >= 4
		&&
		!length($segments[0]) && !length($segments[1])
		&&
		length($segments[2]) && length($segments[3])
	)
		or log_message('Invalid UNC path: ', $unc), exit(1);

	(join('/', @segments[0..3]), File::Spec->catfile($mount_point, @segments[4..$#segments]));
}

sub get_index($$) {
	my ($media, $entry) = @_;

	defined($entry)
		or return 0;

	my $name = $$entry{NAME};

	my $l = 0;
	my $h = @$media;
	my $i;
	my $c;
	while (1) {
		$i = int(($l + $h) / 2);
		$c = $name cmp $$media[$i]{NAME};

		if ($c < 0) {
			$h = $i;
			return $l unless $l < $h;
		} elsif ($c > 0) {
			$l = $i + 1;
			return $h unless $l < $h;
		} else {
			return $i;
		}
	}
}

sub get_current($$) {
	my ($media, $index_ref) = @_;

	$$index_ref < @$media
		or $$index_ref = 0;
	@$media[$$index_ref];
}

my $child;

sub execute(@) {
	my ($rh, $wh);

	pipe($rh, $wh);

	$child = fork();
	unless (defined($child)) {
		close($rh);
		close($wh);
		$@ = 'Failed to fork: ' . $!;
		return undef;
	}

	if ($child == 0) {
		# child
		$SIG{'INT'} = $SIG{'QUIT'} = $SIG{'TERM'} = 'DEFAULT';

		close($rh);
		open(STDERR, '>&', $wh)
			or POSIX::_exit(127);
		close($wh);
		open(STDOUT, '>', '/dev/null');
		exec({$_[0]} @_)
			or POSIX::_exit(127);
	} else {
		# parent
		close($wh);
		{
			local $/ = undef;
			($@ = <$rh>) =~ s/\n+$//s;
		}
		close($rh);
		waitpid($child, 0);
		$child = undef;
		$? == 0;
	}
}

my %sigmap;
@sigmap{split(' ', $Config{sig_name})} = map { int } split(' ', $Config{sig_num});

sub forward_signal($) {
	my ($signame) = @_;

	(defined($child) && $child > 0)
		and kill($sigmap{$signame}, $child);

	exit(0);
}


# main Main MAIN
$myname = basename($0);

$SIG{'INT'} = $SIG{'QUIT'} = $SIG{'TERM'} = \&forward_signal;

(@ARGV == 1)
	or log_message('Expected 1 parameter: <UNC path>, got: ', join(' ', map('<' . $_ . '>', @ARGV))), exit(1);

my $unc_path = $ARGV[0];
my $mount_point = MOUNT_POINT;
my ($share, $media_dir) = parse_unc_path($unc_path, $mount_point);

Authen::Krb5::init_context();

my $kt = Authen::Krb5::kt_default();
my $cc = Authen::Krb5::cc_default();
my $principal;

my $media;
my $last_scan;
my $index;
my $current;

while (1) {
	unless (defined($principal)) {
		$principal = find_host_principal($kt)
			or log_and_wait(ERROR_WAIT_TIME, 'Could not find any host principal in: ', $kt->get_name()), next;
	}

	if (need_refresh_credentials($cc, $principal)) {
		is_mounted($mount_point)
			and execute(qw(/bin/umount), $mount_point);

		refresh_credentials($kt, $principal, $cc)
			or log_and_wait(ERROR_WAIT_TIME, 'Failed to refresh credentials: ', $@), next;
	}

	unless (is_mounted($mount_point)) {
		execute(qw(/bin/mount -t cifs -o sec=krb5), $share, $mount_point)
			or log_and_wait(ERROR_WAIT_TIME, 'Failed to mount share: ', $share, ': ', $@), next;
		$media = undef;
	}

	unless (defined($media)) {
		my $dh;

		opendir($dh, $media_dir)
			or log_and_wait(ERROR_WAIT_TIME, 'Failed to open directory: ', $unc_path, ': ', $!), next;

		my @media;
		my $entry;
		my $ext;
		while (defined($entry = readdir($dh))) {
			$entry = {
				NAME => $entry,
				PATH => File::Spec->catfile($media_dir, $entry)
			};

			# only process plain files
			(-f $$entry{PATH})
				or next;

			# skip hidden files
			($$entry{NAME} =~ /^\./)
				and next;

			# skip files without extensions
			($ext = $$entry{NAME}) =~ s/^.+\.([^.]+)$/lc($1)/e
				or next;

			# skip files we can't present
			exists($presenters{$ext})
				or next;

			$$entry{PRESENTER} = $presenters{$ext};

			push(@media, $entry);
		}

		closedir($dh);

		(@media > 0)
			or log_and_wait(MEDIA_RESCAN_TIME, 'No media files found in: ', $unc_path), next;

		$last_scan = time();

		@media = sort { $$a{NAME} cmp $$b{NAME} } @media;
		$media = \@media;
		$index = get_index($media, $current);
		$current = get_current($media, \$index);
	}

	my @batch = ($current);
	my $presenter = $$current{PRESENTER};

	++$index;
	$current = get_current($media, \$index);
	if ($presenter->batch_presenter()) {
		while ($$current{PRESENTER} == $presenter && $current != $batch[0]) {
			push(@batch, $current);

			++$index;
			$current = get_current($media, \$index);
		}
	}

	# discard media files which are not present any more
	@batch = map {
		$_ = $$_{PATH};
		unless (-f $_) {
			# force rescan of media
			$media = undef;
			();
		} else {
			$_;
		}
	} @batch;

	(@batch > 0)
		and $presenter->present(@batch);

	# force rescan of media if last scan was too long time ago
	(defined($media) && time() - $last_scan >= MEDIA_RESCAN_TIME)
		and $media = undef;
}

END {
	(defined($mount_point) && is_mounted($mount_point))
		and execute(qw(/bin/umount), $mount_point);
	# reactivate plymouth
	Presenter->present();
}
