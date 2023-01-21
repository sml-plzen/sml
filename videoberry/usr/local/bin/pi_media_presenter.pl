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

use constant ERROR_WAIT_TIME => 60;

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

	sub can_present($$) {
		my ($self, $entry) = @_;
		my $files = $self->get_presentable_files($entry);

		if (defined($files) && @$files > 0) {
			$$entry{FILES} = $files;
			1;
		} else {
			0;
		}
	}

	sub get_presentable_files($$) {
		undef;
	}

	sub present($$) {
		my ($self, $entry) = @_;
		my $files = $$entry{FILES};
		# discard removed files
		my @files = grep { (-f $_) } @$files;

		# force rescan if there are no files left to present
		(@files > 0)
			or return 0;

		unless ($plymouth_deactivated) {
			$plymouth_deactivated = 1;
			#main::execute(qw(/bin/plymouth deactivate));
		}

		$self->do_present(\@files);

		if ($plymouth_deactivated) {
			$plymouth_deactivated = 0;
			#main::execute(qw(/bin/plymouth reactivate));
		}

		# no need to rescan if no files were removed
		(@$files == @files);
	}

	sub do_present($$) {
	}

	sub build_extension_map($@) {
		my ($self, @extensions) = @_;
		my $extmap = { map { $_ => 1 } @extensions };

		$extmap;
	}

	sub get_extension($$) {
		my ($self, $name) = @_;

		$name =~ s/^.+\.([^.]+)$/lc($1)/e
			or return '';

		$name;
	}
}

{
	package VideoPresenter;

	use base qw(Presenter);

	my $extensions = __PACKAGE__->build_extension_map(qw(mp4 m4v mov));

	sub get_presentable_files($$) {
		my ($self, $entry) = @_;
		my $ext;

		($ext = $self->get_extension($$entry{NAME}))
			or return undef;

		exists($$extensions{$ext})
			or return undef;

		[$$entry{PATH}];
	}

	sub do_present($$) {
		my ($self, $files) = @_;

		main::execute(qw(omxplayer), @$files);
		#main::execute(qw(su presenter -s /usr/bin/vlc -- -I dummy), @$files, 'vlc://quit');
	}
}

{
	package ImagePresenter;

	use base qw(Presenter);

	my $extensions = __PACKAGE__->build_extension_map(qw(jpg jpeg png));

	sub new($$) {
		my ($class, $timeout) = @_;
		my $self = $class->SUPER::new();

		$$self{TIMEOUT} = $timeout;

		$self;
	}

	sub get_presentable_files($$) {
		my ($self, $entry) = @_;
		my $dir = $$entry{PATH};
		my $dh;

		opendir($dh, $dir)
			or return undef;

		my @files;
		my $file;
		my $ext;
		while (defined($file = readdir($dh))) {
			$file = {
				NAME => $file,
				PATH => File::Spec->catfile($dir, $file)
			};

			# only process plain files
			(-f $$file{PATH})
				or next;

			# skip hidden files
			($$file{NAME} =~ /^\./)
				and next;

			# skip files without extensions
			($ext = $self->get_extension($$file{NAME}))
				or next;

			# skip files we can't present
			exists($$extensions{$ext})
				or next;

			push(@files, $file);
		}

		closedir($dh);

		(@files > 0)
			or return undef;

		@files = map { $$_{PATH} } sort { $$a{NAME} cmp $$b{NAME} } @files;

		\@files;
	}

	sub do_present($$) {
		my ($self, $files) = @_;

		main::execute(qw(fbi -noverbose -nocomments -noedit -autozoom -once -timeout), $$self{TIMEOUT}, @$files);
	}
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

sub filter_played($$) {
	my ($media, $played) = @_;

	if (defined($played)) {
		my @media;
		my %played;
		my $name;

		@media = map {
			$name = $$_{NAME};
			if (exists($$played{$name})) {
				$played{$name} = $_;
				();
			} else {
				$_;
			}
		} @$media;

		(\@media, \%played);
	} else {
		($media, {});
	}
}

sub shuffle($) {
	my ($array) = @_;
	my $i = @$array;
	my $j;

	while ($i > 1) {
		$j = int(rand($i--));
		@$array[$i, $j] = @$array[$j, $i];
	}
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
		if (ref($_[0]) eq 'HASH') {
			my $env = shift(@_);
			@ENV{keys(%$env)} = values(%$env);
		}
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

my $video_presenter = VideoPresenter->new();
my $image_presenter = ImagePresenter->new(IMAGE_DISPLAY_TIME);

Authen::Krb5::init_context();

my $kt = Authen::Krb5::kt_default();
my $cc = Authen::Krb5::cc_default();
my $principal;

my $media;
my $played;
my $last_scan;
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
		no warnings qw(qw);
		execute(qw(/bin/mount -t cifs -o sec=krb5,dir_mode=0755,file_mode=0644), $share, $mount_point)
			or log_and_wait(ERROR_WAIT_TIME, 'Failed to mount share: ', $share, ': ', $@), next;
		$media = undef;
	}

	unless (defined($media)) {
		my $dh;

		opendir($dh, $media_dir)
			or log_and_wait(ERROR_WAIT_TIME, 'Failed to open directory: ', $unc_path, ': ', $!), next;

		my @media;
		my $entry;
		my $presenter;
		while (defined($entry = readdir($dh))) {
			$entry = {
				NAME => $entry,
				PATH => File::Spec->catfile($media_dir, $entry)
			};

			# skip hidden files and directories
			($$entry{NAME} =~ /^\./)
				and next;

			if (-f $$entry{PATH}) {
				$presenter = $video_presenter;
			} elsif (-d $$entry{PATH}) {
				$presenter = $image_presenter;
			} else {
				next;
			}

			# skip files and/or directories we can't present
			$presenter->can_present($entry)
				or next;

			$$entry{PRESENTER} = $presenter;

			push(@media, $entry);
		}

		closedir($dh);

		(@media > 0)
			or log_and_wait(MEDIA_RESCAN_TIME, 'No presentable media files found in: ', $unc_path), next;

		$last_scan = time();

		# defer already played media
		($media, $played) = filter_played(\@media, $played);

		shuffle($media);
	}

	unless (@$media > 0) {
		push(@$media, delete(@$played{keys(%$played)}));
		shuffle($media);
		# avoid playing a single media file twice in a row if possible
		(defined($current) && $$current{NAME} eq $$media[0]{NAME} && @$media > 1)
			and @$media[0, 1] = @$media[1, 0];
	}

	$current = shift(@$media);
	$$played{$$current{NAME}} = $current;

	($$current{PRESENTER}->present($current) && time() - $last_scan < MEDIA_RESCAN_TIME)
		# force rescan of media if presenter recommends that or last scan was too long
		# time ago
		or $media = undef;
}

END {
	(defined($mount_point) && is_mounted($mount_point))
		and execute(qw(/bin/umount), $mount_point);
	# reactivate plymouth
	Presenter->present();
}
