#!/usr/bin/perl
use strict;
use warnings;

use Symbol;
use Encode;
use Authen::Krb5;
use Filesys::SmbClient;
use XML::Simple qw( :strict );
use POSIX ();
use File::Basename;
use File::Spec;
use Unix::Syslog;

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

{
	package Mounter;

	sub new($$$) {
		my ($class, $user, $mount_root) = @_;
		my $self = bless({}, ref($class) || $class);
		my $options = 'sec=krb5i';

		$options = join(',', $options, 'username=' . $$user{name}) if defined($$user{name});
		$options = join(',', $options, 'cruid=' . $$user{uid}, 'uid=' . $$user{uid}) if defined($$user{uid});
		$options = join(',', $options, 'gid=' . $$user{gid}) if defined($$user{gid});

		$$self{OPTIONS} = $options;
		$$self{MOUNT_ROOT} = $mount_root;

		$self->condinit(__PACKAGE__);

		$self;
	}

	sub condinit($$) {
		my ($self, $package) = @_;

		# call the init() only if the caller specified a package
		# which matches our class name
		# this ensures that the init() is only called in the
		# class at the end of the inheritance chain, i.e. not
		# in any of its super classes
		$self->init() if (ref($self) eq $package);
	}

	sub init($) {
	}

	sub mount_device($$$) {
		my ($self, $device, $mountpoint) = @_;

		system(qw( /bin/mount -n -tcifs ), (defined($$self{OPTIONS}) ? '-o' . $$self{OPTIONS} : ()), $device, $mountpoint);
	}

	sub mount_volume($$) {
		my ($self, $volume) = @_;

		return unless defined($$volume{drive});

		my $mountpoint = join('/', $$self{MOUNT_ROOT}, $$volume{drive} . (defined($$volume{description}) ? '-' . $$volume{description} : ':'));
		mkdir($mountpoint)
			or main::log_message("Failed to create directory: $mountpoint"), return;

		$self->mount_device($$volume{path}, $mountpoint) == 0
			or main::log_message("Failed to mount $$volume{path} on $mountpoint"), rmdir($mountpoint);
	}
}

{
	package LinkingMounter;

	use base qw( Mounter );

	sub new($$$$) {
		my ($class, $user, $mount_root, $link_root) = @_;
		my $self = $class->SUPER::new($user, $mount_root);

		$$self{LINK_ROOT} = File::Spec->rel2abs($link_root, $$self{MOUNT_ROOT});

		$self->condinit(__PACKAGE__);

		$self;
	}

	sub init($) {
		my ($self) = @_;

		# change the permissions on the polyinstantiated directory
		chmod(0755, $$self{MOUNT_ROOT})
			or main::log_and_die("Failed to change permissions of $$self{MOUNT_ROOT} to 0755");

		# mount tmpfs on the polyinstantiated links directory
		system(qw( /bin/mount -n -ttmpfs ), '-osize=1M,mode=0755', 'tmpfs', $$self{LINK_ROOT}) == 0
			or main::log_and_die("Failed to mount tmpfs on $$self{LINK_ROOT}");
	}

	sub mount_volume($$) {
		my ($self, $volume) = @_;
		my @components = grep(length($_) > 0, split(/[\\\/]/, $$volume{path}));

		my $serverdir = join('/', $$self{MOUNT_ROOT}, $components[0]);
		unless(-e $serverdir) {
			mkdir($serverdir)
				or main::log_message("Failed to create directory: $serverdir"), return;
		}

		my $mountpoint = join('/', $serverdir, $components[1]);
		unless(-e $mountpoint) {
			mkdir($mountpoint)
				or main::log_message("Failed to create directory: $mountpoint"), return;

			$self->mount_device($$volume{path}, $mountpoint) == 0
				or main::log_message("Failed to mount $$volume{path} on $mountpoint"), rmdir($mountpoint), rmdir($serverdir);
		}

		return unless defined($$volume{drive});

		my $link = join('/', $$self{LINK_ROOT}, $$volume{drive} . (defined($$volume{description}) ? '-' . $$volume{description} : ':'));
		symlink($mountpoint, $link)
			or main::log_message("Failed to link $mountpoint to $link: $!");
	}
}

my $myname;
my $islogin;

sub log_message(@) {
	Unix::Syslog::openlog($myname, 0, Unix::Syslog::LOG_AUTHPRIV);
	Unix::Syslog::syslog(Unix::Syslog::LOG_WARNING, join('', @_));
	Unix::Syslog::closelog();
}

sub log_and_die(@) {
	log_message(@_);
	exit($islogin ? 0 : 1);
}

# There is no way to pass extra arguments to this script except encoding them
# into the script name.
# This function decodes such arguments and based on their values creates an
# appropriate mounter.
sub get_mounter($$$) {
	my ($url, $user, $mount_root) = @_;
	my $link_root = (split(/\?/, $url, 2))[1];
	my $mounter;

	if (defined($link_root) && length($link_root) > 0) {
		# decode URL encoded characters
		$link_root =~ s/%([[:xdigit:]]{2})/chr(hex($1))/eg;
		LinkingMounter->new($user, $mount_root, $link_root);
	} else {
		Mounter->new($user, $mount_root);
	}
}

sub get_kerberos_principal($) {
	my ($user) = @_;
	my $principal;
	my $ccache;

	Authen::Krb5::init_context();

	$ccache = Authen::Krb5::cc_default();
	(-f $ccache->get_name())
		or log_and_die("Could not find kerberos credentials cache for user: $$user{name} ($$user{uid})");

	$principal = $ccache->get_principal()
		or log_and_die('Could not obtain principal from the credentials cache: ', $ccache->get_name());

	$principal;
}

# return a reference to an array containing all groups the specified user
# is a member of (even transitive);
# the array elements are distinguished names of the groups the user is
# a member of
sub get_ad_group_memberships($$) {
	my ($ldap, $user) = @_;
	my $userDN = $user->get_value('distinguishedName');
	my $sid = $user->get_value('objectSid');
	my $primaryGroupRid = pack('V', $user->get_value('primaryGroupID'));

	# get the SID of the user's primary group by replacing the user's RID with the RID
	# of the user's primary group in the user's SID
	substr($sid, -length($primaryGroupRid)) = $primaryGroupRid;

	# lookup the user's primary group by its SID
	my $primaryGroup = undef;
	foreach ($ldap->query(
		sprintf('(&(objectClass=group)(objectSid=%s))', join('\\', unpack('A0(A2)*', unpack('H*', $sid)))),
		[ qw( distinguishedName ) ]
	)) {
		$primaryGroup = $_;
		last;
	}
	defined($primaryGroup)
		or log_and_die('Could not find primary group of user: ', $user->get_value('sAMAccountName'), ' (', $userDN, ')');

	my %memberOf = (
		$primaryGroup->get_value('distinguishedName') => 1
	);
	foreach ($user->get_value('memberOf')) {
		$memberOf{$_} = 1;
	}

	# expand the groups, i.e. given a set of groups find groups in which the groups
	# from the given set are members, then add the found groups to the set and repeat
	# the process until there is nothing to add to the set
	my @unexpanded = keys(%memberOf);
	do {
		# lookup the groups which haven't been expanded yet
		foreach ($ldap->query(
			sprintf('(&(objectClass=group)(|%s))', join('', map("(distinguishedName=$_)", splice(@unexpanded)))),
			[ qw( distinguishedName memberOf ) ]
		)) {
			foreach ($_->get_value('memberOf')) {
				next if exists($memberOf{$_});

				$memberOf{$_} = 1;
				push(@unexpanded, $_);
			}
		}
	} while (@unexpanded > 0);

	[ $userDN, keys(%memberOf) ];
}

# return distinguished names corresponding to the specified account names
sub get_ad_account_dn($@) {
	my ($ldap, @accounts) = @_;
	my %checkMap = ();

	foreach (@accounts) {
		$checkMap{lc($_)} = $_;
	}

	# lookup the accounts
	my @distinguishedNames = ();
	foreach ($ldap->query(
		sprintf('(&(|(objectClass=group)(objectClass=user))(|%s))', join('', map("(sAMAccountName=$_)", @accounts))),
		[ qw( distinguishedName sAMAccountName ) ]
	)) {
		delete($checkMap{lc($_->get_value('sAMAccountName'))});
		push(@distinguishedNames, $_->get_value('distinguishedName'));
	}

	keys(%checkMap) == 0
		or log_and_die('Could not find out distinguished name(s) of the following account(s): ', join(', ', values(%checkMap)));

	@distinguishedNames;
}

sub safe_encode_utf8($) {
	my ($string) = @_;

	defined($string)
		? encode_utf8($string)
		: undef;
}

# read the layout definitions
sub read_layouts($$) {
	my ($ldap, $user) = @_;
	my $layoutsFile = sprintf('//%s/netlogon/layouts.xml', $ldap->host());
	my $fh = gensym(); # create an anonymous filehandle

	do {
		# override the HOME directory to point to the directory where this
		# script is located, the expectation is that that directory contains
		# the ``.smb'' subdirectory which in turns contains a smb.conf file
		# to be used by the ``Filesys::SmbClient''; some versions of the
		# module create an empty smb.conf file otherwise (that is if the
		# $HOME/.smb/smb.conf does not exist) which causes an authentication
		# problem when trying to access the layouts.xml file
		local $ENV{HOME} = dirname(File::Spec->rel2abs($0));

		# open the layouts definition file at the NETLOGON share through a tie to Filesys::SmbClient
		tie(*{$fh}, 'Filesys::SmbClient',
			"smb:$layoutsFile",
			undef,
			username => $user,
			flags => SMB_CTX_FLAG_USE_KERBEROS | SMBCCTX_FLAG_NO_AUTO_ANONYMOUS_LOGON,
		)
	}
		or log_and_die("Failed to open layouts definition file ($layoutsFile): $!");

	# read the raw XML data
	my $xml = eval { XMLin($fh, KeyAttr => {}, ForceArray => [ qw( layout include volume apply account ) ], KeepRoot => 1) };
	if ($@) {
		$@ =~ s/\r?\n$//s;
		log_and_die("Failed to parse the layouts definition file ($layoutsFile): $@");
	}
	close($fh);
	$fh = undef;

	# transform the raw XML data into a useful structure
	my %layouts = ();
	foreach (@{$$xml{'layouts'}{'layout'}}) {
		my $layout = $layouts{encode_utf8($$_{'name'})} = [];

		foreach (@{$$_{'include'}}) {
			push(@$layout, @{$layouts{encode_utf8($$_{'layout'})}});
		}

		foreach my $volume (@{$$_{'volume'}}) {
			push(@$layout,
				{
					map {
						($_ => safe_encode_utf8($$volume{$_}));
					} qw( drive path description platform )
				}
			);
		}
	}

	my %layoutPriorityMap = ();
	my $prioritymax = 0;
	foreach (@{$$xml{'layouts'}{'apply'}}) {
		my $layout = {
			priority => (defined($$_{'supplementary'}) && lc(encode_utf8($$_{'supplementary'})) eq 'true') ? ++$prioritymax : 0,
			layout => $layouts{encode_utf8($$_{'layout'})}
		};

		foreach (get_ad_account_dn($ldap, map(encode_utf8($$_{'name'}), @{$$_{'account'}}))) {
			exists($layoutPriorityMap{$_})
				or $layoutPriorityMap{$_} = $layout;
		}
	}

	\%layoutPriorityMap;
}


# main Main MAIN
$myname = basename($0);
$islogin = substr($myname, 0, 1) eq '-';

@ARGV == 4
	or log_message('Expected 4 parameters: <polyinstantiated dir> <instance dir> <newly created flag> <user name>, got: ', join(' ', map("<$_>", @ARGV))), exit(2);

my $user = {
	name => $ARGV[3]
};
@_ = getpwnam($$user{name})
	or log_message("Could not find passwd entry for user: $$user{name}"), exit(1);
@$user{qw( uid gid )} = @_[2, 3];

# use the kerberos credentials cache of the user on whose behalf we are executing
$ENV{KRB5CCNAME} = sprintf('FILE:/tmp/krb5cc_%d', $$user{uid});

# we create and initialize the mounter early so that at least the mount root directory
# is setup correctly in case we fail before anything is actually mounted
my $mounter = get_mounter($myname, $user, $ARGV[0]);

my $principal = get_kerberos_principal($user);

my $ldap = ADLDAP->connect($principal->realm());

# lookup the user in AD
my $ADuser = undef;
foreach ($ldap->query(
	sprintf('(&(objectClass=user)(sAMAccountName=%s))', join('/', $principal->data())),
	[ qw( distinguishedName objectSid sAMAccountName primaryGroupID memberOf homeDrive homeDirectory ) ]
)) {
	$ADuser = $_;
	last;
}
defined($ADuser)
	or log_and_die('Could not find AD account of user: ', join('/', $principal->data()));

my $layoutPriorityMap = read_layouts($ldap, $ADuser->get_value('sAMAccountName'));
my $ADgroups = get_ad_group_memberships($ldap, $ADuser);

# tear down the AD LDAP session
$ldap = undef;

my @layout = ();
push(@layout, {
	drive => do {
		# strip trailing colon (if any)
		($_ = $ADuser->get_value('homeDrive')) =~ s/:$//;
		$_;
	},
	path => $ADuser->get_value('homeDirectory'),
	description => $ADuser->get_value('sAMAccountName'),
}) if ($ADuser->get_value('homeDirectory') && $ADuser->get_value('homeDrive'));

# build the layout for the AD user
{
	my $primary = { priority => 0 };

	foreach (@$ADgroups) {
		if (exists($$layoutPriorityMap{$_})) {
			$_ = $$layoutPriorityMap{$_};
			if ($$_{priority} > 0) {
				# primary layout
				$primary = $_ if $$_{priority} > $$primary{priority};
			} else {
				# supplementary layout
				push(@layout, @{$$_{layout}});
			}
		}
	}

	push(@layout, @{$$primary{layout}}) if $$primary{priority} > 0;
}

my $platform = lc((POSIX::uname())[0]);
# mount the filesystems according to the layout
foreach (@layout) {
	# skip volumes not intended for the platform we are executing on
	next if (defined($$_{platform}) && $$_{platform} ne $platform);

	$mounter->mount_volume($_);
}
