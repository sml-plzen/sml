#!/usr/bin/perl
use strict;
use warnings;

use Cwd;
use URI::Escape;
use Authen::Krb5;
use File::Basename;
use File::Spec;

{
	package ADLDAP;

	use Net::DNS;
	use Net::LDAP;
	use Authen::SASL;

	# return the first line of the message
	my $strip_message = sub($) {
		my ($message) = @_;

		$message =~ s/\r?\n.*$//s;

		$message;
	};

	sub connect($$) {
		my ($class, $domain) = @_;
		my $self = bless({}, ref($class) || $class);
		my @servers;
		my $result;

		# find AD LDAP servers through DNS
		$result = Net::DNS::Resolver->new(usevc => 1, tcp_timeout => 20)->send("_ldap._tcp.dc._msdcs.$domain.", 'SRV') and $result->answer() > 0
			or main::log_and_die("Failed to locate AD LDAP servers for domain: $domain");
		@servers = map { join(':', $_->target(), $_->port()) } $result->answer();

		# connect to any of the servers
		$$self{LDAP} = Net::LDAP->new(\@servers)
			or main::log_and_die("Failed to connect to any of the following AD LDAP servers of the $domain domain: ", join(', ', @servers));

		# bind using kerberos
		$result = $$self{LDAP}->bind(undef, sasl => Authen::SASL->new(mechanism => 'GSSAPI'));
		$result->code() == 0
			or main::log_and_die('Failed to bind to AD LDAP server "', $$self{LDAP}->uri(), '": ', &$strip_message($result->error()));

		$$self{BASE} = join(',', map("DC=$_", split(/\./, $domain)));

		$self;
	}

	# perform an AD LDAP query
	sub query($$;$) {
		my ($self, $filter, $attributes) = @_;
		my %param = (base => $$self{BASE}, filter => $filter);
		$param{attrs} = $attributes if defined($attributes);

		my $result = $$self{LDAP}->search(%param);
		unless ($result->code() == 0) {
			($result = $result->error) =~ s/\r?\n$//s;
			main::log_and_die("Failed to execute AD LDAP query \"$filter\": $result");
		}

		$result->entries();
	}

	sub host($) {
		my ($self) = @_;

		$$self{LDAP}->host();
	}

	sub DESTROY($) {
		my ($self) = @_;

		$$self{LDAP}->unbind();
		$$self{LDAP}->disconnect();
	}
}

my $myname;

sub log_message(@) {
	print(STDERR $myname, ': ', @_, "\n");
}

sub log_and_die(@) {
	log_message(@_);
	die("\n");
}

sub get_kerberos_principal() {
	my $principal;
	my $ccache;

	Authen::Krb5::init_context();

	$ccache = Authen::Krb5::cc_default();
	(-f $ccache->get_name())
		or log_and_die("Could not find kerberos credentials cache for the current user.");

	$principal = $ccache->get_principal()
		or log_and_die('Could not obtain principal from the credentials cache: ', $ccache->get_name());

	$principal;
}

sub get_user_remote_home() {
	my $principal = get_kerberos_principal();
	my $ldap = ADLDAP->connect($principal->realm());
	my $ADuser = undef;

	# lookup the user in AD
	foreach ($ldap->query(
		sprintf('(&(objectClass=user)(sAMAccountName=%s))', join('/', $principal->data())),
		[ qw( homeDirectory ) ]
	)) {
		$ADuser = $_;
		last;
	}
	defined($ADuser)
		or log_and_die('Could not find AD account of user: ', join('/', $principal->data()));

	$ADuser->get_value('homeDirectory');
}

sub get_unc_mount_pattern($) {
	my ($unc) = @_;

	$unc = join('[\\\\/]', map(quotemeta(lc($_)), split(/[\\\/]/, $unc)));

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

sub read_volume_links($$) {
	my ($volumeLinksDir, $remoteHomeMountDir) = @_;
	my $volumes = {};

	my $dh;
	opendir($dh, $volumeLinksDir)
		or log_and_die("Could not open volume links directory $volumeLinksDir: $!\n"), return $volumes;

	my $entry;
	while (defined($entry = readdir($dh))) {
		# skip default entries
		next if $entry =~ /^\.\.?$/;

		my $path = File::Spec->catfile($volumeLinksDir, $entry);
		# skip non directory entries
		unless (-l $path) {
			warn("Not a symbolic link: $path\n");
			next;
		}
		next if (defined($remoteHomeMountDir) && readlink($path) eq $remoteHomeMountDir);

		my $description = $entry;

		$description =~ s/^[A-Z]-//;

		$$volumes{$path} = $description;
	}

	closedir($dh);

	$volumes;
}

sub update_bookmarks_file($$) {
	my ($volumes, $volumeLinksDir) = @_;
	my $bookmarksfile = File::Spec->catfile('/', $ENV{HOME}, '.gtk-bookmarks');
	my @bookmarks = ();
	my $fh;

	if (-e $bookmarksfile) {
		# read the bookmarks file and parse the bookmark entries
		open($fh, '<', $bookmarksfile)
			or log_message("Could not open bookmarks file $bookmarksfile: $!\n"), return;

		$volumeLinksDir .= '/' unless $volumeLinksDir =~ /\/$/;

		while (<$fh>) {
			chomp();
			unless (s|^file://||) {
				# preserve non-file bookmarks
				push(@bookmarks, $_);
				next;
			}

			my @bookmark = split(' ', $_, 2);
			my $path = $bookmark[0];

			$path =~ s|%([0-9a-fA-F]{2})|chr(hex($1))|ge;

			if (exists($$volumes{$path})) {
				# if the bookmark already exists, then just make sure its description is up to date
				push(@bookmarks, 'file://' . join(' ', $bookmark[0], delete($$volumes{$path})));
			} elsif (length($path) < length($volumeLinksDir) || substr($path, 0, length($volumeLinksDir)) ne $volumeLinksDir) {
				# preserve non volume links bookmarks
				push(@bookmarks, 'file://' . join(' ', @bookmark));
			}
		}

		close($fh);
	}

	foreach (sort(keys(%$volumes))) {
		push(@bookmarks, 'file://' . join(' ', uri_escape($_, '\x00-\x20\x7f-\xff'), $$volumes{$_}));
	}

	my $tempfile = join('.', $bookmarksfile, $$, 'tmp');

	open($fh, '>', $tempfile)
		or log_message("Could not open temporary bookmarks file $tempfile: $!\n"), return;

	foreach (@bookmarks) {
		print($fh $_, "\n");
	}

	close($fh);

	unless (rename($tempfile, $bookmarksfile)) {
		unlink($tempfile);
		log_message("Could not update bookmarks file $bookmarksfile: $!\n");
		return;
	}

	system(qw( xdg-user-dirs-gtk-update ));
}


# main Main MAIN
$myname = basename($0);

@ARGV == 3
	or log_message(
		'Expected 3 parameters: <volume links directory> <remote home local mirror directory> <remote home local mirror directory bookmark name>, got: ',
		join(' ', map("<$_>", @ARGV))
	), exit(2);

my $remoteHomeMountDir = undef;

eval {
	$remoteHomeMountDir = find_mount_dir(get_unc_mount_pattern(get_user_remote_home()));
};

my $volumeLinksDir = Cwd::abs_path($ARGV[0]);
my $volumes = read_volume_links($volumeLinksDir, $remoteHomeMountDir);
my $remoteHomeMirrorDirectory = File::Spec->rel2abs($ARGV[1], $ENV{HOME});

unless (-d $remoteHomeMirrorDirectory) {
	mkdir($remoteHomeMirrorDirectory)
		or log_message("Could not create directory: $remoteHomeMirrorDirectory: $!");
}

$$volumes{$remoteHomeMirrorDirectory} = $ARGV[2];

update_bookmarks_file($volumes, $volumeLinksDir);

defined($remoteHomeMountDir)
	or log_message('Remote home not mouted, not starting the synchronization.'), exit(0);

exec(
	File::Spec->catfile(dirname($0), 'directory-synchronizer.pl'),
	$remoteHomeMountDir,
	$remoteHomeMirrorDirectory
);
