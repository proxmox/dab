package PVE::DAB;

use strict;
use warnings;
use IO::File;
use File::Path;
use File::Basename;
use IO::Select;
use IPC::Open2;
use IPC::Open3;
use POSIX qw (LONG_MAX);
use UUID;
use Cwd;

# fixme: lock container ?

my $dablibdir = "/usr/lib/dab";
my $devicetar = "$dablibdir/devices.tar.gz";
my $default_env = "$dablibdir/scripts/defenv";
my $fake_init = "$dablibdir/scripts/init.pl";
my $script_ssh_init = "$dablibdir/scripts/ssh_gen_host_keys";
my $script_mysql_randompw = "$dablibdir/scripts/mysql_randompw";
my $script_init_urandom = "$dablibdir/scripts/init_urandom";

my $postfix_main_cf = <<EOD;
# See /usr/share/postfix/main.cf.dist for a commented, more complete version

smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no

# appending .domain is the MUA's job.
append_dot_mydomain = no

# Uncomment the next line to generate "delayed mail" warnings
#delay_warning_time = 4h

alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = \$myhostname, localhost.\$mydomain, localhost
relayhost = 
mynetworks = 127.0.0.0/8
inet_interfaces = loopback-only
recipient_delimiter = +

compatibility_level = 2

EOD

# produce apt compatible filenames (/var/lib/apt/lists)
sub __url_to_filename {
    my $url = shift;

    $url =~ s|^\S+://||;
    $url =~ s|_|%5f|g;
    $url =~ s|/|_|g;

    return $url;
}

# defaults:
#  origin: debian
#  flags:
#    systemd: true (except for devuan ostypes)
my $supported_suites = {
    'bookworm' => {
	ostype => "debian-12",
    },
    'bullseye' => {
	ostype => "debian-11",
    },
    'buster' => {
	ostype => "debian-10",
    },
    'stretch' => {
	ostype => "debian-9.0",
    },
    'jessie' => {
	ostype => "debian-8.0",
    },
    'wheezy' => {
	flags => {
	    systemd => 0,
	},
	ostype => "debian-7.0",
    },
    'squeeze' => {
	flags => {
	    systemd => 0,
	},
	ostype => "debian-6.0",
    },
    'lenny' => {
	flags => {
	    systemd => 0,
	},
	ostype => "debian-5.0",
    },
    'etch' => {
	flags => {
	    systemd => 0,
	},
	ostype => "debian-4.0",
    },

# DEVUAN (imply systemd = 0 default)
    'devuan-jessie' => {
	suite => 'jessie',
	ostype => "devuan-1.0",
    },
    'devuan-ascii' => {
	suite => 'ascii',
	ostype => "devuan-2.0",
    },
    'ascii' => {
	ostype => "devuan-2.0",
    },
    'beowulf' => {
	ostype => "devuan-3.0",
    },
    'chimaera' => {
	ostype => "devuan-4.0",
    },
    'daedalus' => {
	ostype => "devuan-5.0",
    },

# UBUNTU
    'hardy' => {
	flags => {
	    systemd => 0,
	},
	ostype => "ubuntu-8.04",
	origin => 'ubuntu',
    },
    'intrepid' => {
	flags => {
	    systemd => 0,
	},
	ostype => "ubuntu-8.10",
	origin => 'ubuntu',
    },
    'jaunty' => {
	flags => {
	    systemd => 0,
	},
	ostype => "ubuntu-9.04",
	origin => 'ubuntu',
    },
    'precise' => {
	flags => {
	    systemd => 0,
	},
	ostype => "ubuntu-12.04",
	origin => 'ubuntu',
    },
    'trusty' => {
	flags => {
	    systemd => 0,
	},
	ostype => "ubuntu-14.04",
	origin => 'ubuntu',
    },
    'vivid' => {
	ostype => "ubuntu-15.04",
	origin => 'ubuntu',
    },
    'wily' => {
	ostype => "ubuntu-15.10",
	origin => 'ubuntu',
    },
    'xenial' => {
	ostype => "ubuntu-16.04",
	origin => 'ubuntu',
    },
    'yakkety' => {
	ostype => "ubuntu-16.10",
	origin => 'ubuntu',
    },
    'zesty' => {
	ostype => "ubuntu-17.04",
	origin => 'ubuntu',
    },
    'artful' => {
	ostype => "ubuntu-17.10",
	origin => 'ubuntu',
    },
    'bionic' => {
	ostype => "ubuntu-18.04",
	origin => 'ubuntu',
    },
    'cosmic' => {
	ostype => "ubuntu-18.10",
	origin => 'ubuntu',
    },
    'disco' => {
	ostype => "ubuntu-19.04",
	origin => 'ubuntu',
    },
    'eoan' => {
	ostype => "ubuntu-19.10",
	origin => 'ubuntu',
    },
    'focal' => {
	ostype => "ubuntu-20.04",
	origin => 'ubuntu',
    },
    'groovy' => {
	ostype => "ubuntu-20.10",
	origin => 'ubuntu',
    },
    'hirsute' => {
	ostype => "ubuntu-21.04",
	origin => 'ubuntu',
    },
    'impish' => {
	ostype => "ubuntu-21.10",
	origin => 'ubuntu',
    },
    'jammy' => {
	ostype => "ubuntu-22.04",
	origin => 'ubuntu',
    },
    'kinetic' => {
	ostype => "ubuntu-22.10",
	origin => 'ubuntu',
    },
};

sub get_suite_info {
    my ($suite) = @_;

    my $suiteinfo = $supported_suites->{$suite} || die "unsupported suite '$suite'!\n";

    # set defaults
    $suiteinfo->{origin} //= 'debian';
    $suiteinfo->{suite} //= $suite;

    $suiteinfo->{flags} //= {};
    if ($suiteinfo->{ostype} =~ /^devuan/) {
	$suiteinfo->{flags}->{systemd} //= 0;
    } else {
	$suiteinfo->{flags}->{systemd} //= 1;
    }

    return $suiteinfo;
}

sub download {
    my ($self, $url, $path) = @_;
    my $tmpfn = "$path.tmp$$";

    $self->logmsg ("download: $url\n");

    eval { $self->run_command ("wget -q '$url'  -O '$tmpfn'") };
    if (my $err = $@) {
	unlink $tmpfn;
	die $err;
    }

    rename ($tmpfn, $path);
}

sub write_file {
    my ($data, $file, $perm) = @_;

    die "no filename" if !$file;

    unlink $file;

    my $fh = IO::File->new ($file, O_WRONLY | O_CREAT, $perm) ||
	die "unable to open file '$file'";

    print $fh $data;

    $fh->close;
}

sub read_file {
    my ($file) = @_;

    die "no filename" if !$file;

    my $fh = IO::File->new ($file) ||
	die "unable to open file '$file'";

    local $/; # slurp mode
    
    my $data = <$fh>;

    $fh->close;

    return $data;
}

sub read_config {
    my ($filename) = @_;

    my $res = {};

    my $fh = IO::File->new ("<$filename") || return $res;
    my $rec = '';

    while (defined (my $line = <$fh>)) {
	next if $line =~ m/^\#/;
	next if $line =~ m/^\s*$/;
	$rec .= $line;
    };

    close ($fh);

    chomp $rec;
    $rec .= "\n";

    while ($rec) {
	if ($rec =~ s/^Description:\s*([^\n]*)(\n\s+.*)*$//si) {
	    $res->{headline} = $1;
	    chomp $res->{headline};
	    my $long = $2;
	    $long =~ s/^\s+/ /;
	    $res->{description} = $long;
	    chomp $res->{description};	    
	} elsif ($rec =~ s/^([^:]+):\s*(.*\S)\s*\n//) {
	    my ($key, $value) = (lc ($1), $2);
	    if ($key eq 'source' || $key eq 'mirror') {
		push @{$res->{$key}}, $value;
	    } else {
		die "duplicate key '$key'\n" if defined ($res->{$key});
		$res->{$key} = $value;
	    }
	} else {
	    die "unable to parse config file: $rec";
	}
    }

    die "unable to parse config file" if $rec;

    return $res;
}

sub run_command {
    my ($self, $cmd, $input, $getoutput) = @_;

    my $reader = IO::File->new();
    my $writer = IO::File->new();
    my $error  = IO::File->new();

    my $orig_pid = $$;

    my $cmdstr = ref ($cmd) eq 'ARRAY' ? join (' ', @$cmd) : $cmd;

    my $pid;
    eval {
	if (ref ($cmd) eq 'ARRAY') {
	    $pid = open3 ($writer, $reader, $error, @$cmd) || die $!;
	} else {
	    $pid = open3 ($writer, $reader, $error, $cmdstr) || die $!;
	}
    };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
	$self->logmsg ("ERROR: command '$cmdstr' failed - fork failed\n");
	POSIX::_exit (1); 
	kill ('KILL', $$); 
    }

    die $err if $err;

    print $writer $input if defined $input;
    close $writer;

    my $select = IO::Select->new();
    $select->add ($reader);
    $select->add ($error);

    my $res = '';
    my $logfd = $self->{logfd};

    while ($select->count) {
	my @handles = $select->can_read ();

	foreach my $h (@handles) {
	    my $buf = '';
	    my $count = sysread ($h, $buf, 4096);
	    if (!defined ($count)) {
		waitpid ($pid, 0);
		die "command '$cmdstr' failed: $!";
	    }
	    $select->remove ($h) if !$count;

	    print $logfd $buf;

	    $res .= $buf if $getoutput;
	}
    }

    waitpid ($pid, 0);
    my $ec = ($? >> 8);

    die "command '$cmdstr' failed with exit code $ec\n" if $ec;

    return $res;
}

sub logmsg {
    my $self = shift;
    print STDERR @_;
    $self->writelog (@_);
}

sub writelog {
    my $self = shift;
    my $fd = $self->{logfd};
    print $fd @_;
}

sub __sample_config {
    my ($self) = @_;

    my $data = '';
    my $arch = $self->{config}->{architecture};

    my $ostype = $self->{config}->{ostype};

    if ($ostype =~ m/^de(bi|vu)an-/) {
	$data .= "lxc.include = /usr/share/lxc/config/debian.common.conf\n";
    } elsif ($ostype =~ m/^ubuntu-/) {
	$data .= "lxc.include = /usr/share/lxc/config/ubuntu.common.conf\n";
    } else {
	die "unknown os type '$ostype'\n";
    }
    $data .= "lxc.uts.name = localhost\n";
    $data .= "lxc.rootfs.path = $self->{rootfs}\n";
    
    return $data;
}

sub __allocate_ve {
    my ($self) = @_;

    my $cid;
    if (my $fd = IO::File->new (".veid")) {
	$cid = <$fd>;
	chomp $cid;
	close ($fd);
    }


    $self->{working_dir} = getcwd;
    $self->{veconffile} = "$self->{working_dir}/config";
    $self->{rootfs} = "$self->{working_dir}/rootfs";

    if ($cid) {
	$self->{veid} = $cid;
	return $cid;
    }

    my $uuid;
    my $uuid_str;
    UUID::generate($uuid);
    UUID::unparse($uuid, $uuid_str);
    $self->{veid} = $uuid_str;

    my $fd = IO::File->new (">.veid") ||
	die "unable to write '.veid'\n";
    print $fd "$self->{veid}\n";
    close ($fd);

    my $cdata = $self->__sample_config();

    my $fh = IO::File->new ($self->{veconffile}, O_WRONLY|O_CREAT|O_EXCL) ||
	die "unable to write lxc config file '$self->{veconffile}' - $!";
    print $fh $cdata;
    close ($fh);

    mkdir $self->{rootfs} || die "unable to create rootfs - $!";

    $self->logmsg ("allocated VE $self->{veid}\n");

    return $self->{veid};
}

# just use some simple heuristic for now, merge usr for releases newer than ubuntu 21.x or debian 11
sub can_usr_merge {
    my ($self) = @_;

    my $ostype = $self->{config}->{ostype};

    # FIXME: add configuration override posibillity

    if ($ostype =~ m/^debian-(\d+)/) {
	return int($1) >= 11;
    } elsif ($ostype =~ m/^ubuntu-(\d+)/) {
	return int($1) >= 21;
    }
    return; # false
}

sub setup_usr_merge {
    my ($self) = @_;

    my $rootfs = $self->{rootfs};
    my $arch = $self->{config}->{architecture};

    # similar to https://salsa.debian.org/installer-team/debootstrap/-/blob/master/functions#L1354
    my @merged_dirs = qw(bin sbin lib);

    if ($arch eq 'amd64') {
	push @merged_dirs, qw(lib32 lib64 libx32);
    } elsif ($arch eq 'i386') {
	push @merged_dirs, qw(lib64 libx32);
    }

    $self->logmsg ("setup usr-merge symlinks for '" . join("', '", @merged_dirs) . "'\n");

    for my $dir (@merged_dirs) {
	symlink("usr/$dir", "$rootfs/$dir") or warn "could not create symlink - $!\n";
	mkpath "$rootfs/usr/$dir";
    }
}

sub get_target_name {
    my ($config) = @_;

    my $name = $config->{name} || die "no 'name' specified\n";
    $name =~ m/^[a-z][0-9a-z\-\*\.]+$/ || die "illegal characters in name '$name'\n";

    my ($version, $arch, $ostype) = $config->@{'version', 'architecture', 'ostype'};
    $name = "${ostype}-${name}" if $name !~ m/^$ostype/;

    return "${name}_${version}_${arch}"
}

sub new {
    my ($class, $config) = @_;

    $class = ref ($class) || $class;
    $config = read_config ('dab.conf') if !$config;

    my $self = {
	config => $config,
    };
    bless $self, $class;

    $self->{logfile} = "logfile";
    $self->{logfd} = IO::File->new (">>$self->{logfile}") || die "unable to open log file";

    my $arch = $config->{architecture} || die "no 'architecture' specified\n";
    die "unsupported architecture '$arch'\n" if $arch !~ m/^(i386|amd64)$/;

    my $suite = $config->{suite} || die "no 'suite' specified\n";

    my $suiteinfo = get_suite_info($suite);
    $suite = $suiteinfo->{suite};
    $config->{ostype} = $suiteinfo->{ostype};

    # assert required dab.conf keys exist
    for my $key (qw(version section headline maintainer)) {
	die "no '$key' specified\n" if !$config->{$key};
    }

    $self->{targetname} = get_target_name($config);

    if (!$config->{source}) {
	if (lc($suiteinfo->{origin}) eq 'debian') {
	    if ($suite eq 'etch' || $suite eq 'lenny') {
		push @{$config->{source}}, (
		    'http://ftp.debian.org/debian SUITE main contrib',
		    'http://security.debian.org SUITE/updates main contrib',
		);
	    } elsif ($suite =~ /^(?:bullseye|bookworm|trixie|forky)$/) {
		push @{$config->{source}}, (
		    "http://deb.debian.org/debian SUITE main contrib",
		    "http://deb.debian.org/debian SUITE-updates main contrib",
		    "http://security.debian.org SUITE-security main contrib",
		);
	    } else {
		push @{$config->{source}}, (
		    "http://ftp.debian.org/debian SUITE main contrib",
		    "http://ftp.debian.org/debian SUITE-updates main contrib",
		    "http://security.debian.org SUITE/updates main contrib",
		);
	    }
	} elsif (lc($suiteinfo->{origin}) eq 'ubuntu') {
	    my $comp = "main restricted universe multiverse";
	    push @{$config->{source}}, (
		"http://archive.ubuntu.com/ubuntu SUITE $comp",
		"http://archive.ubuntu.com/ubuntu SUITE-updates $comp",
		"http://archive.ubuntu.com/ubuntu SUITE-security $comp",
	    );
	} else {
	    die "implement me";
	}
    }

    my $sources = undef;

    foreach my $s (@{$config->{source}}) {
	if ($s =~ m@^\s*((http|ftp)://\S+)\s+(\S+)((\s+(\S+))+)$@) {
	    my ($url, $su, $components) = ($1, $3, $4);
	    $su =~ s/SUITE/$suite/;
	    $components =~ s/^\s+//; 
	    $components =~ s/\s+$//; 
	    my $ca;
	    foreach my $co (split (/\s+/, $components)) {
		push @$ca, $co;
	    }
	    $ca = ['main'] if !$ca;

	    push @$sources, {
		source => $url,
		comp => $ca,
		suite => $su,
	    };
	} else {
	    die "syntax error in source spezification '$s'\n";
	}
    }

    foreach my $m (@{$config->{mirror}}) {
	if ($m =~ m@^\s*((http|ftp)://\S+)\s*=>\s*((http|ftp)://\S+)\s*$@) {
	    my ($ms, $md) = ($1, $3);
	    my $found;
	    foreach my $ss (@$sources) {
		if ($ss->{source} eq $ms) {
		    $found = 1;
		    $ss->{mirror} = $md;
		    last;
		}
	    }
	    die "unusable mirror $ms\n" if !$found;
	} else {
	    die "syntax error in mirror spezification '$m'\n";
	}
    }
    $self->{sources} = $sources;
    $self->{infodir} = "info";

    $self->__allocate_ve();

    $self->{cachedir} = ($config->{cachedir} || 'cache')  . "/$suite";;

    my $incl = [qw (less ssh openssh-server logrotate)];
    my $excl = [qw (modutils reiserfsprogs ppp pppconfig pppoe pppoeconf nfs-common mtools ntp)];

    # ubuntu has too many dependencies on udev, so we cannot exclude it (instead we disable udevd)
    if (lc($suiteinfo->{origin}) eq 'ubuntu' && $suiteinfo->{flags}->{systemd}) {
	push @$incl, 'isc-dhcp-client';
	push @$excl, qw(libmodule-build-perl libdrm-common libdrm2 libplymouth5 plymouth plymouth-theme-ubuntu-text powermgmt-base);
	if ($suite eq 'jammy') {
	    push @$excl, qw(fuse); # avoid fuse2 <-> fuse3 conflict
	}
    } elsif ($suite eq 'trusty') {
	push @$excl, qw(systemd systemd-services libpam-systemd libsystemd-daemon0 memtest86+);
   } elsif ($suite eq 'precise') {
	push @$excl, qw(systemd systemd-services libpam-systemd libsystemd-daemon0 memtest86+ ubuntu-standard);
    } elsif ($suite eq 'hardy') {
	push @$excl, qw(kbd);
	push @$excl, qw(apparmor apparmor-utils ntfs-3g friendly-recovery);
    } elsif ($suite eq 'intrepid' || $suite eq 'jaunty') {
	push @$excl, qw(apparmor apparmor-utils libapparmor1 libapparmor-perl libntfs-3g28);
	push @$excl, qw(ntfs-3g friendly-recovery);
    } elsif ($suite eq 'jessie') {
	push @$incl, 'sysvinit-core'; # avoid systemd and udev
	push @$incl, 'libperl4-corelibs-perl'; # to make lsof happy
	push @$excl, qw(systemd systemd-sysv udev module-init-tools pciutils hdparm memtest86+ parted);
    } elsif ($suite eq 'stretch' || $suite eq 'buster' || $suite eq 'bullseye' || $suite eq 'bookworm') {
	push @$excl, qw(module-init-tools pciutils hdparm memtest86+ parted);
     } else {
	push @$excl, qw(udev module-init-tools pciutils hdparm memtest86+ parted);
    }

    $self->{incl} = $incl;
    $self->{excl} = $excl;

    return $self;
}

sub initialize {
    my ($self) = @_;

    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    rmtree $infodir;
    mkpath $infodir;

    # truncate log
    my $logfd = $self->{logfd} = IO::File->new (">$self->{logfile}") ||
	die "unable to open log file";

    my $COMPRESSORS = [
	{
	    ext => 'xz',
	    decomp => 'xz -d',
	},
	{
	    ext => 'gz',
	    decomp => 'gzip -d',
	},
    ];

    foreach my $ss (@{$self->{sources}}) {
	my $src = $ss->{mirror} || $ss->{source};
	my $path = "dists/$ss->{suite}/Release";
	my $url = "$src/$path";
	my $target = __url_to_filename ("$ss->{source}/$path");
	eval {
	    $self->download ($url, "$infodir/$target");
	    $self->download ("$url.gpg", "$infodir/$target.gpg");
	    # fixme: impl. verify (needs --keyring option)
	};
	if (my $err = $@) { 
	    print $logfd $@; 
	    warn "Release info ignored\n";
	};

	foreach my $comp (@{$ss->{comp}}) {
	    foreach my $compressor (@$COMPRESSORS) {
		$path = "dists/$ss->{suite}/$comp/binary-$arch/Packages.$compressor->{ext}";
		$target = "$infodir/" . __url_to_filename ("$ss->{source}/$path");
		my $pkgsrc = "$src/$path";
		eval {
		    $self->download ($pkgsrc, $target);
		    $self->run_command ("$compressor->{decomp} '$target'");
		};
		if (my $err = $@) {
		    print $logfd "could not download Packages.$compressor->{ext}\n";
		} else {
		    last;
		}
	    }
	}
    }
}

sub write_config {
    my ($self, $filename, $size) = @_;

    my $config = $self->{config};

    my $data = '';

    $data .= "Name: $config->{name}\n";
    $data .= "Version: $config->{version}\n";
    $data .= "Type: lxc\n";
    $data .= "OS: $config->{ostype}\n";
    $data .= "Section: $config->{section}\n";
    $data .= "Maintainer: $config->{maintainer}\n";
    $data .= "Architecture: $config->{architecture}\n";
    $data .= "Installed-Size: $size\n";

    # optional
    $data .= "Infopage: $config->{infopage}\n" if $config->{infopage};
    $data .= "ManageUrl: $config->{manageurl}\n" if $config->{manageurl};
    $data .= "Certified: $config->{certified}\n" if $config->{certified};

    # description
    $data .= "Description: $config->{headline}\n";
    $data .= "$config->{description}\n" if $config->{description};

    write_file ($data, $filename, 0644);
}

sub finalize {
    my ($self, $opts) = @_;

    my $suite = $self->{config}->{suite};
    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    my $instpkgs = $self->read_installed ();
    my $pkginfo = $self->pkginfo();
    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};
    my $rootdir = $self->{rootfs};

    my $vestat = $self->ve_status();
    die "ve not running - unable to finalize\n" if !$vestat->{running};

    # cleanup mysqld
    if (-f "$rootdir/etc/init.d/mysql") {
	$self->ve_command ("/etc/init.d/mysql stop");
    }

    if (!($opts->{keepmycnf} || (-f "$rootdir/etc/init.d/mysql_randompw"))) {
	unlink "$rootdir/root/.my.cnf";
    }

    if ($suite eq 'etch') {
	# enable apache2 startup
	if ($instpkgs->{apache2}) {
	    write_file ("NO_START=0\n", "$rootdir/etc/default/apache2");
	} else {
	    unlink "$rootdir/etc/default/apache2";
	}
    }
    $self->logmsg ("cleanup package status\n");
    # prevent auto selection of all standard, required or important 
    # packages which are not installed
    foreach my $pkg (keys %$pkginfo) {
	my $pri = $pkginfo->{$pkg}->{priority};
	if ($pri && ($pri eq 'required' || $pri eq 'important' 
		     || $pri eq 'standard')) {
	    if (!$instpkgs->{$pkg}) {
		$self->ve_dpkg_set_selection ($pkg, 'purge');
	    }
	}
    }

    $self->ve_command ("apt-get clean");

    $self->logmsg ("update available package list\n");

    $self->ve_command ("dpkg --clear-avail");
    foreach my $ss (@{$self->{sources}}) {
	my $relsrc = __url_to_filename ("$ss->{source}/dists/$ss->{suite}/Release");
	if (-f "$infodir/$relsrc" && -f "$infodir/$relsrc.gpg") {
	    $self->run_command ("cp '$infodir/$relsrc' '$rootdir/var/lib/apt/lists/$relsrc'");
	    $self->run_command ("cp '$infodir/$relsrc.gpg' '$rootdir/var/lib/apt/lists/$relsrc.gpg'");
	}
	foreach my $comp (@{$ss->{comp}}) {
	    my $src = __url_to_filename ("$ss->{source}/dists/$ss->{suite}/" .
					 "$comp/binary-$arch/Packages");
	    my $target = "/var/lib/apt/lists/$src";
	    $self->run_command ("cp '$infodir/$src' '$rootdir/$target'");
	    $self->ve_command ("dpkg --merge-avail '$target'");
	}
    }

    # set dselect default method
    write_file ("apt apt\n", "$rootdir/var/lib/dpkg/cmethopt"); 

    $self->ve_divert_remove ("/usr/sbin/policy-rc.d");

    $self->ve_divert_remove ("/sbin/start-stop-daemon"); 

    $self->ve_divert_remove ("/sbin/init"); 

    # finally stop the VE
    $self->run_command ("lxc-stop -n $veid --rcfile $conffile --kill");

    unlink "$rootdir/sbin/defenv";
    unlink <$rootdir/root/dead.letter*>;
    unlink "$rootdir/var/log/init.log";
    unlink "$rootdir/aquota.group", "$rootdir/aquota.user";

    write_file ("", "$rootdir/var/log/syslog");

    my $get_path_size = sub {
	my ($path) = @_;
	my $sizestr = $self->run_command ("du -sm $path", undef, 1);
	if ($sizestr =~ m/^(\d+)\s+\Q$path\E$/) {
	    return int($1);
	} else {
	    die "unable to detect size for '$path'\n";
	}
    };

    $self->logmsg ("detecting final appliance size: ");
    my $size = $get_path_size->($rootdir);
    $self->logmsg ("$size MB\n");

    $self->write_config ("$rootdir/etc/appliance.info", $size);

    $self->logmsg ("creating final appliance archive\n");

    my $target = "$self->{targetname}.tar";

    my $compressor = $opts->{compressor} // 'gz';
    my $compressor2cmd_map = {
	gz => 'gzip',
	gzip => 'gzip',
	zst => 'zstd --rm -9',
	zstd => 'zstd --rm -9',
	'zstd-max' => 'zstd --rm -19 -T0', # maximal level where the decompressor can still run efficiently
    };
    my $compressor2ending = {
	gzip => 'gz',
	zstd => 'zst',
	'zstd-max' => 'zst',
    };
    my $compressor_cmd = $compressor2cmd_map->{$compressor};
    die "unkown compressor '$compressor', use one of: ". join(', ', sort keys %$compressor2cmd_map)
	if !defined($compressor_cmd);

    my $ending = $compressor2ending->{$compressor} // $compressor;
    my $final_archive = "${target}.${ending}";
    unlink $target;
    unlink $final_archive;

    $self->run_command ("tar cpf $target --numeric-owner -C '$rootdir' ./etc/appliance.info");
    $self->run_command ("tar rpf $target --numeric-owner -C '$rootdir' --exclude ./etc/appliance.info .");
    $self->run_command ("$compressor_cmd $target");

    $self->logmsg ("detecting final commpressed appliance size: ");
    $size = $get_path_size->($final_archive);
    $self->logmsg ("$size MB\n");

    $self->logmsg ("appliance archive: $final_archive\n");
}

sub read_installed {
    my ($self) = @_;

    my $rootdir = $self->{rootfs};

    my $pkgfilelist = "$rootdir/var/lib/dpkg/status";
    local $/ = '';
    open(my $PKGLST, '<', $pkgfilelist) or die "unable to open '$pkgfilelist' - $!";

    my $pkglist = {};

    while (my $rec = <$PKGLST>) {
	chomp $rec;
	$rec =~ s/\n\s+/ /g;
	$rec .= "\n";
	my $res = {};

	while ($rec =~ s/^([^:]+):\s+(.*?)\s*\n//) {
	    $res->{lc $1} = $2;
	}

	my $pkg = $res->{'package'};
	if (my $status = $res->{status}) {
	    my @sa = split (/\s+/, $status);
	    my $stat = $sa[0];
	    if ($stat && ($stat ne 'purge')) {
		$pkglist->{$pkg} = $res;
	    }
	}
    }

    close ($PKGLST);

    return $pkglist;
}

sub ve_status {
    my ($self) = @_;

    my $veid = $self->{veid};

    my $res = { running => 0 };

    $res->{exist} = 1 if -d "$self->{rootfs}/usr";

    my $filename = "/proc/net/unix";

    # similar test is used by lcxcontainers.c: list_active_containers
    my $fh = IO::File->new ($filename, "r");
    return $res if !$fh;

    while (defined(my $line = <$fh>)) {
	if ($line =~ m/^[a-f0-9]+:\s\S+\s\S+\s\S+\s\S+\s\S+\s\d+\s(\S+)$/) {
	    my $path = $1;
	    if ($path =~ m!^@/\S+/$veid/command$!) {
		$res->{running} = 1;
	    }
	}
    }
    close($fh);

    return $res;
}

sub ve_command {
    my ($self, $cmd, $input) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    if (ref ($cmd) eq 'ARRAY') {
	unshift @$cmd, 'lxc-attach', '-n', $veid, '--rcfile', $conffile, '--clear-env', '--', 'defenv';
	$self->run_command($cmd, $input);
    } else {
	$self->run_command("lxc-attach -n $veid --rcfile $conffile --clear-env -- defenv $cmd", $input);
    }
}

# like ve_command, but pipes stdin correctly
sub ve_exec {
    my ($self, @cmd) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    my $reader;
    my $pid = open2($reader, "<&STDIN", 'lxc-attach', '-n', $veid,  '--rcfile', $conffile, '--',
		    'defenv', @cmd) || die "unable to exec command";
    
    while (defined (my $line = <$reader>)) {
	$self->logmsg ($line);
    }

    waitpid ($pid, 0);
    my $rc = $? >> 8;

    die "ve_exec failed - status $rc\n" if $rc != 0;
}

sub ve_divert_add {
    my ($self, $filename) = @_;

    $self->ve_command ("dpkg-divert --add --divert '$filename.distrib' " .
		       "--rename '$filename'");
}
sub ve_divert_remove {
    my ($self, $filename) = @_;

    my $rootdir = $self->{rootfs};

    unlink "$rootdir/$filename";
    $self->ve_command ("dpkg-divert --remove --rename '$filename'");
}

sub ve_debconfig_set {
    my ($self, $dcdata) = @_;

    my $rootdir = $self->{rootfs};
    my $cfgfile = "/tmp/debconf.txt";
    write_file ($dcdata, "$rootdir/$cfgfile");
    $self->ve_command ("debconf-set-selections $cfgfile"); 
    unlink "$rootdir/$cfgfile";    
}

sub ve_dpkg_set_selection {
    my ($self, $pkg, $status) = @_;

    $self->ve_command ("dpkg --set-selections", "$pkg $status");
}

sub ve_dpkg {
    my ($self, $cmd, @pkglist) = @_;

    return if !scalar (@pkglist);

    my $pkginfo = $self->pkginfo();

    my $rootdir = $self->{rootfs};
    my $cachedir = $self->{cachedir};

    my @files;

    foreach my $pkg (@pkglist) {
	my $filename = $self->getpkgfile ($pkg);
	$self->run_command ("cp '$cachedir/$filename' '$rootdir/$filename'");
	push @files, "/$filename";
	$self->logmsg ("$cmd: $pkg\n");
    }

    my $fl = join (' ', @files);

    if ($cmd eq 'install') {
	$self->ve_command ("dpkg --force-depends --force-confold --install $fl");
    } elsif ($cmd eq 'unpack') {
	$self->ve_command ("dpkg --force-depends --unpack $fl");
    } else {
	die "internal error";
    }

    foreach my $fn (@files) { unlink "$rootdir$fn"; }
}

sub ve_destroy {
    my ($self) = @_;

    my $veid = $self->{veid}; # fixme
    my $conffile = $self->{veconffile};

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
	$self->run_command ("lxc-stop -n $veid --rcfile $conffile --kill");
    }

    rmtree $self->{rootfs};
    unlink $self->{veconffile};
}

sub ve_init {
    my ($self) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    $self->logmsg ("initialize VE $veid\n");

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
	$self->run_command ("lxc-stop -n $veid --rcfile $conffile --kill");
    } 

    rmtree $self->{rootfs};
    mkpath $self->{rootfs};
}

sub __deb_version_cmp {
    my ($cur, $op, $new) = @_;

    if (system("dpkg", "--compare-versions", $cur, $op, $new) == 0) {
	return 1;
    }

    return 0;
}

sub __parse_packages {
    my ($pkginfo, $filename, $src) = @_;

    local $/ = '';
    open(my $PKGLST, '<', $filename) or die "unable to open '$filename' - $!";

    while (my $rec = <$PKGLST>) {
	$rec =~ s/\n\s+/ /g;
	chomp $rec;
	$rec .= "\n";

	my $res = {};

	while ($rec =~ s/^([^:]+):\s+(.*?)\s*\n//) {
	    $res->{lc $1} = $2;
	}

	my $pkg = $res->{'package'};
	if ($pkg && $res->{'filename'}) {
	    my $cur;
	    if (my $info = $pkginfo->{$pkg}) {
		$cur = $info->{version};
	    }
	    my $new = $res->{version};
	    if (!$cur || __deb_version_cmp ($cur, 'lt', $new)) {
		if ($src) {
		    $res->{url} = "$src/$res->{'filename'}";
		} else {
		    die "no url for package '$pkg'" if !$res->{url};
		}
		$pkginfo->{$pkg} = $res;
	    }
	}
    }

    close ($PKGLST);
}

sub pkginfo {
    my ($self) = @_;

    return $self->{pkginfo} if $self->{pkginfo};

    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    my $availfn = "$infodir/available";

    my $pkginfo = {};
    my $pkgcount = 0;

    # reading 'available' is faster, because it only contains latest version
    # (no need to do slow version compares)
    if (-f $availfn) {
	    __parse_packages ($pkginfo, $availfn);
	    $self->{pkginfo} = $pkginfo;
	    return $pkginfo;
    }

    $self->logmsg ("generating available package list\n");

    foreach my $ss (@{$self->{sources}}) {
	foreach my $comp (@{$ss->{comp}}) {
	    my $url = "$ss->{source}/dists/$ss->{suite}/$comp/binary-$arch/Packages";
	    my $pkgfilelist = "$infodir/" . __url_to_filename ($url);

	    my $src = $ss->{mirror} || $ss->{source};

	    __parse_packages ($pkginfo, $pkgfilelist, $src);
	}
    }

    if (my $dep = $self->{config}->{depends}) {
	foreach my $d (split (/,/, $dep)) {
	    if ($d =~ m/^\s*(\S+)\s*(\((\S+)\s+(\S+)\)\s*)?$/) {
		my ($pkg, $op, $rver) = ($1, $3, $4);
		$self->logmsg ("checking dependencies: $d\n");
		my $info = $pkginfo->{$pkg};
		die "package '$pkg' not available\n" if !$info;
		if ($op) {
		    my $cver = $info->{version};
		    if (!__deb_version_cmp ($cver, $op, $rver)) {
			die "detected wrong version '$cver'\n";
		    }
		}
	    } else {
		die "syntax error in depends field";
	    }
	}
    }

    $self->{pkginfo} = $pkginfo;

    my $tmpfn = "$availfn.tmp$$";
    my $fd = IO::File->new (">$tmpfn");
    foreach my $pkg (sort keys %$pkginfo) {
	my $info = $pkginfo->{$pkg};
	print $fd "package: $pkg\n";
	foreach my $k (sort keys %$info) {
	    next if $k eq 'description';
	    next if $k eq 'package';
	    my $v = $info->{$k};
	    print $fd "$k: $v\n" if $v;	    
	}
	print $fd "description: $info->{description}\n" if $info->{description};	    
	print $fd "\n";
    }
    close ($fd);

    rename ($tmpfn, $availfn);

    return $pkginfo;
}

sub __record_provides {
    my ($pkginfo, $closure, $list, $skipself) = @_;

    foreach my $pname (@$list) {
	my $info = $pkginfo->{$pname};
	# fixme: if someone install packages directly using dpkg, there
	# is no entry in 'available', only in 'status'. In that case, we
	# should extract info from $instpkgs
	if (!$info) {
	    warn "hint: ignoring provides for '$pname' - package not in 'available' list.\n";
	    next;
	}
	if (my $prov = $info->{provides}) {
	    my @pl = split (',', $prov);
	    foreach my $p (@pl) {
		$p =~ m/\s*(\S+)/;
		if (!($skipself && (grep { $1 eq $_ } @$list))) {
		    $closure->{$1} = 1;
		}
	    }
	}
	$closure->{$pname} = 1 if !$skipself;
    }
}

sub closure {
    my ($self, $closure, $list) = @_;

    my $pkginfo = $self->pkginfo();

    # first, record provided packages
    __record_provides ($pkginfo, $closure, $list, 1);

    my $pkghash = {};
    my $pkglist = [];

    # then resolve dependencies
    foreach my $pname (@$list) {
	__closure_single ($pkginfo, $closure, $pkghash, $pkglist, $pname, $self->{excl});
    }

    return $pkglist;
}

sub __closure_single {
    my ($pkginfo, $closure, $pkghash, $pkglist, $pname, $excl) = @_;

    $pname =~ s/^\s+//;
    $pname =~ s/\s+$//;
    $pname =~ s/:any$//;

    return if $closure->{$pname};

    my $info = $pkginfo->{$pname} || die "no such package '$pname'";

    my $dep = $info->{depends};
    my $predep = $info->{'pre-depends'};

    my $size = $info->{size};
    my $url = $info->{url};

    $url || die "$pname: no url for package '$pname'";

    if (!$pkghash->{$pname}) {
	unshift @$pkglist, $pname;
	$pkghash->{$pname} = 1;
    }

    __record_provides ($pkginfo, $closure, [$pname]) if $info->{provides};

    $closure->{$pname} = 1;
 
    #print "$url\n";

    my @l;

    push  @l, split (/,/, $predep) if $predep;
    push  @l, split (/,/, $dep) if $dep;

  DEPEND: foreach my $p (@l) {
      my @l1 = split (/\|/, $p);
      foreach my $p1 (@l1) {
	  if ($p1 =~ m/^\s*(\S+).*/) {
	      #printf (STDERR "$pname: $p --> $1\n");
	      if ($closure->{$1}) {
		  next DEPEND; # dependency already met
	      }
	  }
      }
      # search for non-excluded alternative
      my $found;
      foreach my $p1 (@l1) {
	  if ($p1 =~ m/^\s*(\S+).*/) {
	      next if grep { $1 eq $_ } @$excl;
	      $found = $1;
	      last;
	  }
      }
      die "package '$pname' depends on exclusion '$p'\n" if !$found;

      #printf (STDERR "$pname: $p --> $found\n");
	  
      __closure_single ($pkginfo, $closure, $pkghash, $pkglist, $found, $excl);
  }
}

sub cache_packages {
    my ($self, $pkglist) = @_;

    foreach my $pkg (@$pkglist) {
	$self->getpkgfile ($pkg);
    }
}

sub getpkgfile {
    my ($self, $pkg) = @_;

    my $pkginfo = $self->pkginfo();
    my $info = $pkginfo->{$pkg} || die "no such package '$pkg'";
    my $cachedir = $self->{cachedir};

    my $url = $info->{url};

    my $filename;
    if ($url =~ m|/([^/]+.deb)$|) {
	$filename = $1;
    } else {
	die "internal error";
    }

    return $filename if -f "$cachedir/$filename";

    mkpath $cachedir;

    $self->download ($url, "$cachedir/$filename");

    return $filename;
}

sub install_init_script {
    my ($self, $script, $runlevel, $prio) = @_;

    my $suite = $self->{config}->{suite};
    my $suiteinfo = get_suite_info($suite);
    my $rootdir = $self->{rootfs};

    my $base = basename ($script);
    my $target = "$rootdir/etc/init.d/$base";

    $self->run_command ("install -m 0755 '$script' '$target'");
    if ($suite eq 'etch' || $suite eq 'lenny') {
	$self->ve_command ("update-rc.d $base start $prio $runlevel .");
    } elsif ($suiteinfo->{flags}->{systemd}) {
	die "unable to install init script (system uses systemd)\n";
    } elsif ($suite eq 'trusty' || $suite eq 'precise') {
	die "unable to install init script (system uses upstart)\n";
    } else {
	$self->ve_command ("insserv $base");
    }

    return $target;
}

sub bootstrap {
    my ($self, $opts) = @_;

    my $pkginfo = $self->pkginfo();
    my $veid = $self->{veid};
    my $suite = $self->{config}->{suite};
    my $suiteinfo = get_suite_info($suite);

    my $important = [ @{$self->{incl}} ];
    my $required;
    my $standard;

    my $mta = $opts->{exim} ? 'exim' : 'postfix';
    if ($mta eq 'postfix') {
	push @$important, "postfix";
    }

    if ($opts->{include}) {
	push @$important, split(',', $opts->{include});
    }

    my $exclude = {};
    if ($opts->{exclude}) {
	$exclude->{$_} = 1 for split(',', $opts->{exclude});
    }

    foreach my $p (sort keys %$pkginfo) {
	next if grep { $p eq $_ } @{$self->{excl}};
	my $pri = $pkginfo->{$p}->{priority};
	next if !$pri;
	next if $mta ne 'exim' && $p =~ m/exim/; 
	next if $p =~ m/(selinux|semanage|policycoreutils)/;

	push @$required, $p  if $pri eq 'required';
	next if $exclude->{$p};
	push @$important, $p if $pri eq 'important';
	push @$standard, $p if $pri eq 'standard' && !$opts->{minimal};
    }

    my $closure = {};
    $required = $self->closure($closure, $required);
    $important = $self->closure($closure, $important);

    if (!$opts->{minimal}) {
	$standard = $self->closure($closure, $standard);
    }

    # test if we have all 'ubuntu-minimal' and 'ubuntu-standard' packages
    # except those explicitly excluded
    if ($suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	my $mdeps = $pkginfo->{'ubuntu-minimal'}->{depends};
	foreach my $d (split (/,/, $mdeps)) {
	    if ($d =~ m/^\s*(\S+)$/) {
		my $pkg = $1;
		next if $closure->{$pkg};
		next if grep { $pkg eq $_ } @{$self->{excl}};
		die "missing ubuntu-minimal package '$pkg'\n";
	    }
	}
	if (!$opts->{minimal}) {
	    $mdeps = $pkginfo->{'ubuntu-standard'}->{depends};
	    foreach my $d (split (/,/, $mdeps)) {
		if ($d =~ m/^\s*(\S+)$/) {
		    my $pkg = $1;
		    next if $closure->{$pkg};
		    next if grep { $pkg eq $_ } @{$self->{excl}};
		    die "missing ubuntu-standard package '$pkg'\n";
		}
	    }
	}
    }

    # download/cache all files first
    $self->cache_packages ($required);
    $self->cache_packages ($important);
    $self->cache_packages ($standard);
 
    my $rootdir = $self->{rootfs};

    # extract required packages first
    $self->logmsg ("create basic environment\n");

    if ($self->can_usr_merge()) {
	$self->setup_usr_merge();
    }

    my $compressor2opt = {
	'zst' => '--zstd',
	'gz' => '--gzip',
	'xz' => '--xz',
    };
    my $compressor_re = join('|', keys $compressor2opt->%*);

    $self->logmsg ("extract required packages to rootfs\n");
    foreach my $p (@$required) {
	my $filename = $self->getpkgfile ($p);
	my $content = $self->run_command("ar -t '$self->{cachedir}/$filename'", undef, 1);
	if ($content =~ m/^(data.tar.($compressor_re))$/m) {
	    my $archive = $1;
	    my $tar_opts = "--keep-directory-symlink $compressor2opt->{$2}";

	    $self->run_command("ar -p '$self->{cachedir}/$filename' '$archive' | tar -C '$rootdir' -xf - $tar_opts");
	} else {
	    die "unexpected error for $p: no data.tar.{xz,gz,zst} found...";
	}
    }

    # fake dpkg status
    my $data = "Package: dpkg\n" .
	"Version: $pkginfo->{dpkg}->{version}\n" .
	"Status: install ok installed\n";

    write_file ($data, "$rootdir/var/lib/dpkg/status");
    write_file ("", "$rootdir/var/lib/dpkg/info/dpkg.list");
    write_file ("", "$rootdir/var/lib/dpkg/available");

    $data = '';
    foreach my $ss (@{$self->{sources}}) {
	my $url = $ss->{source};
	my $comp = join (' ', @{$ss->{comp}});
	$data .= "deb $url $ss->{suite} $comp\n\n";
    }

    write_file ($data, "$rootdir/etc/apt/sources.list");

    $data = "# UNCONFIGURED FSTAB FOR BASE SYSTEM\n";
    write_file ($data, "$rootdir/etc/fstab", 0644);

    write_file ("localhost\n", "$rootdir/etc/hostname", 0644);

    # avoid warnings about non-existent resolv.conf
    write_file ("", "$rootdir/etc/resolv.conf", 0644);

    if (lc($suiteinfo->{origin}) eq 'ubuntu' && $suiteinfo->{flags}->{systemd}) {
	# no need to configure loopback device
	# FIXME: Debian (systemd based?) too?
    } else {
	$data = "auto lo\niface lo inet loopback\n";
	mkdir "$rootdir/etc/network";
	write_file ($data, "$rootdir/etc/network/interfaces", 0644);
    }

    # setup devices
    $self->run_command ("tar xzf '$devicetar' -C '$rootdir'");

    # avoid warnings about missing default locale
    write_file ("LANG=\"C\"\n", "$rootdir/etc/default/locale", 0644);

    # fake init
    rename ("$rootdir/sbin/init", "$rootdir/sbin/init.org");
    $self->run_command ("cp '$fake_init' '$rootdir/sbin/init'");

    $self->run_command ("cp '$default_env' '$rootdir/sbin/defenv'");

    $self->run_command ("lxc-start -n $veid -f $self->{veconffile}");

    $self->logmsg ("initialize ld cache\n");
    $self->ve_command ("/sbin/ldconfig");
    $self->run_command ("ln -sf mawk '$rootdir/usr/bin/awk'");

    $self->logmsg ("installing packages\n");

    $self->ve_dpkg ('install', 'base-files', 'base-passwd');

    $self->ve_dpkg ('install', 'dpkg');

    $self->run_command ("ln -sf /usr/share/zoneinfo/UTC '$rootdir/etc/localtime'");
    
    $self->run_command ("ln -sf bash '$rootdir/bin/sh'");

    $self->ve_dpkg ('install', 'libc6');
    $self->ve_dpkg ('install', 'perl-base');

    unlink "$rootdir/usr/bin/awk";

    $self->ve_dpkg ('install', 'mawk');
    $self->ve_dpkg ('install', 'debconf');

    # unpack required packages
    foreach my $p (@$required) {
	$self->ve_dpkg ('unpack', $p);
    }

    rename ("$rootdir/sbin/init.org", "$rootdir/sbin/init");
    $self->ve_divert_add ("/sbin/init");
    $self->run_command ("cp '$fake_init' '$rootdir/sbin/init'");

    # disable service activation
    $self->ve_divert_add ("/usr/sbin/policy-rc.d");
    $data = "#!/bin/sh\nexit 101\n";
    write_file ($data, "$rootdir/usr/sbin/policy-rc.d", 755);

    # disable start-stop-daemon
    $self->ve_divert_add ("/sbin/start-stop-daemon");
    $data = <<EOD;
#!/bin/sh
echo
echo \"Warning: Fake start-stop-daemon called, doing nothing\"
EOD
    write_file ($data, "$rootdir/sbin/start-stop-daemon", 0755);

    # disable udevd
    $self->ve_divert_add ("/sbin/udevd");

    if ($suite eq 'etch') {
	write_file ("NO_START=1\n", "$rootdir/etc/default/apache2"); # disable apache2 startup
    }

    $self->logmsg ("configure required packages\n");
    $self->ve_command ("dpkg --force-confold --skip-same-version --configure -a");

    # set postfix defaults
    if ($mta eq 'postfix') {
	$data = "postfix postfix/main_mailer_type select Local only\n";
	$self->ve_debconfig_set ($data);

	$data = "postmaster: root\nwebmaster: root\n";
	write_file ($data, "$rootdir/etc/aliases");
    }

    if ($suite eq 'jaunty') {
	# jaunty does not create /var/run/network, so network startup fails.
	# so we do not use tmpfs for /var/run and /var/lock
	$self->run_command ("sed -e 's/RAMRUN=yes/RAMRUN=no/' -e 's/RAMLOCK=yes/RAMLOCK=no/'  -i $rootdir/etc/default/rcS");
	# and create the directory here
	$self->run_command ("mkdir $rootdir/var/run/network");
    }

    # unpack base packages
    foreach my $p (@$important) {
	$self->ve_dpkg ('unpack', $p);
    }

    # start loopback
    if (-x "$rootdir/sbin/ifconfig") {
	$self->ve_command ("ifconfig lo up");
    } else {
	$self->ve_command ("ip link set lo up");
    }

    $self->logmsg ("configure important packages\n");
    $self->ve_command ("dpkg --force-confold --skip-same-version --configure -a");

    if (-d "$rootdir/etc/event.d") {
	unlink <$rootdir/etc/event.d/tty*>;
    }

    if (-f "$rootdir/etc/inittab") {
	$self->run_command ("sed -i -e '/getty\\s38400\\stty[23456]/d' '$rootdir/etc/inittab'");
    }

    # Link /etc/mtab to /proc/mounts, so df and friends will work:
    unlink "$rootdir/etc/mtab";
    $self->ve_command ("ln -s /proc/mounts /etc/mtab");

    # reset password
    $self->ve_command ("usermod -L root");

    if ($mta eq 'postfix') {
	$data = "postfix postfix/main_mailer_type select No configuration\n";
	$self->ve_debconfig_set ($data);

	unlink "$rootdir/etc/mailname";
	write_file ($postfix_main_cf, "$rootdir/etc/postfix/main.cf");
    }

    if (!$opts->{minimal}) {
	# unpack standard packages
	foreach my $p (@$standard) {
	    $self->ve_dpkg ('unpack', $p);
	}

	$self->logmsg ("configure standard packages\n");
	$self->ve_command ("dpkg --force-confold --skip-same-version --configure -a");
    }

    # disable HWCLOCK access
    $self->run_command ("echo 'HWCLOCKACCESS=no' >> '$rootdir/etc/default/rcS'"); 

    # disable hald
    $self->ve_divert_add ("/usr/sbin/hald");

    # disable /dev/urandom init
    $self->run_command ("install -m 0755 '$script_init_urandom' '$rootdir/etc/init.d/urandom'");

    if ($suite eq 'etch' || $suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	# avoid klogd start
	$self->ve_divert_add ("/sbin/klogd");
    }

    # remove unnecessays sysctl entries to avoid warnings
    my $cmd = 'sed';
    $cmd .= ' -e \'s/^\(kernel\.printk.*\)/#\1/\'';
    $cmd .= ' -e \'s/^\(kernel\.maps_protect.*\)/#\1/\'';
    $cmd .= ' -e \'s/^\(fs\.inotify\.max_user_watches.*\)/#\1/\'';
    $cmd .= ' -e \'s/^\(vm\.mmap_min_addr.*\)/#\1/\'';
    $cmd .= " -i '$rootdir/etc/sysctl.conf'";
    $self->run_command ($cmd);

    my $bindv6only = "$rootdir/etc/sysctl.d/bindv6only.conf";
    if (-f $bindv6only) {
	$cmd = 'sed';
	$cmd .= ' -e \'s/^\(net\.ipv6\.bindv6only.*\)/#\1/\'';	
	$cmd .= " -i '$bindv6only'";
	$self->run_command ($cmd);
    }

    if ($suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	# disable tty init (console-setup)
	my $cmd = 'sed';
	$cmd .= ' -e \'s/^\(ACTIVE_CONSOLES=.*\)/ACTIVE_CONSOLES=/\'';
	$cmd .= " -i '$rootdir/etc/default/console-setup'";
	$self->run_command ($cmd);
    }

    if ($suite eq 'intrepid' || $suite eq 'jaunty') {
	# remove sysctl setup (avoid warnings at startup)
	my $filelist = "$rootdir/etc/sysctl.d/10-console-messages.conf";
	$filelist .= " $rootdir/etc/sysctl.d/10-process-security.conf" if $suite eq 'intrepid';
	$filelist .= " $rootdir/etc/sysctl.d/10-network-security.conf";
	$self->run_command ("rm $filelist");
    }

    if (-e "$rootdir/lib/systemd/system/sys-kernel-config.mount") {
	$self->ve_command ("ln -s /dev/null /etc/systemd/system/sys-kernel-debug.mount");
    }
}

sub enter {
    my ($self) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    my $vestat = $self->ve_status();

    if (!$vestat->{exist}) {
	$self->logmsg ("Please create the appliance first (bootstrap)");
	return;
    }

    if (!$vestat->{running}) {
	$self->run_command ("lxc-start -n $veid -f $conffile");
    }

    system ("lxc-attach -n $veid --rcfile $conffile --clear-env");
}

sub ve_mysql_command {
    my ($self, $sql, $password) = @_;

    #my $bootstrap = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables " .
    #"--skip-bdb  --skip-innodb --skip-ndbcluster";

    $self->ve_command ("mysql", $sql);
}

sub ve_mysql_bootstrap {
    my ($self, $sql, $password) = @_;

    my $cmd;

    my $suite = $self->{config}->{suite};

    if ($suite eq 'jessie') {
	my $rootdir = $self->{rootfs};
	$self->run_command ("sed -e 's/^key_buffer\\s*=/key_buffer_size =/' -i $rootdir/etc/mysql/my.cnf");
    }

    if ($suite eq 'squeeze' || $suite eq 'wheezy' || $suite eq 'jessie') {
	$cmd = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables";

    } else {
	$cmd = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables " .
	    "--skip-bdb  --skip-innodb --skip-ndbcluster";
    }

    $self->ve_command ($cmd, $sql);
}

sub compute_required {
    my ($self, $pkglist) = @_;

    my $pkginfo = $self->pkginfo();
    my $instpkgs = $self->read_installed ();

    my $closure = {};
    __record_provides($pkginfo, $closure, [keys $instpkgs->%*]);

    return $self->closure ($closure, $pkglist);
}

sub task_postgres {
    my ($self, $opts) = @_;

    my @supp = ('7.4', '8.1');
    my $pgversion; # NOTE: not setting that defaults to the distro default, normally the best choice

    my $suite = $self->{config}->{suite};

    if ($suite eq 'lenny' || $suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
	@supp = ('8.3');
	$pgversion = '8.3';
    } elsif ($suite eq 'squeeze') {
	@supp = ('8.4');
	$pgversion = '8.4';
    } elsif ($suite eq 'wheezy') {
	@supp = ('9.1');
	$pgversion = '9.1';
    } elsif ($suite eq 'jessie') {
	@supp = ('9.4');
	$pgversion = '9.4';
    } elsif ($suite eq 'stretch') {
	@supp = ('9.6');
	$pgversion = '9.6';
    } elsif ($suite eq 'buster') {
	@supp = ('11');
	$pgversion = '11';
    } elsif ($suite eq 'bullseye') {
	@supp = ('13');
    } elsif ($suite eq 'bookworm') {
	# FIXME: update once froozen
	@supp = ('13', '14');
    }
    $pgversion = $opts->{version} if $opts->{version};

    my $required;
    if (defined($pgversion)) {
	die "unsupported postgres version '$pgversion'\n" if !grep { $pgversion eq $_; } @supp;

	$required = $self->compute_required (["postgresql-$pgversion"]);
    } else {
	$required = $self->compute_required (["postgresql"]);
    }

    $self->cache_packages ($required);
 
    $self->ve_dpkg ('install', @$required);

    my $iscript = "postgresql-$pgversion";
    if ($suite eq 'squeeze' || $suite eq 'wheezy' || $suite eq 'jessie' ||
	$suite eq 'stretch') {
	$iscript = 'postgresql';
    }

    $self->ve_command ("/etc/init.d/$iscript start") if $opts->{start};
}

sub task_mysql {
    my ($self, $opts) = @_;

    my $password = $opts->{password};
    my $rootdir = $self->{rootfs};

    my $suite = $self->{config}->{suite};

    my $ver = '5.0';
    if ($suite eq 'squeeze') {
      $ver = '5.1';
    } elsif ($suite eq 'wheezy' || $suite eq 'jessie') {
      $ver = '5.5';
    } else {
	die "task_mysql: unsupported suite '$suite'";
    }

    my $required = $self->compute_required (['mysql-common', "mysql-server-$ver"]);

    $self->cache_packages ($required);
 
    $self->ve_dpkg ('install', @$required);

    # fix security (see /usr/bin/mysql_secure_installation)
    my $sql = "DELETE FROM mysql.user WHERE User='';\n" .
	"DELETE FROM mysql.user WHERE User='root' AND Host!='localhost';\n" .
	"FLUSH PRIVILEGES;\n";
    $self->ve_mysql_bootstrap ($sql);

    if ($password) {

	my $rpw = $password eq 'random' ? 'admin' : $password;

	my $sql = "USE mysql;\n" .
	    "UPDATE user SET password=PASSWORD(\"$rpw\") WHERE user='root';\n" .
	    "FLUSH PRIVILEGES;\n";
	$self->ve_mysql_bootstrap ($sql);

	write_file ("[client]\nuser=root\npassword=\"$rpw\"\n", "$rootdir/root/.my.cnf", 0600);
	if ($password eq 'random') {
	    $self->install_init_script ($script_mysql_randompw, 2, 20);
	}
    }

    $self->ve_command ("/etc/init.d/mysql start") if $opts->{start};
}

sub task_php {
    my ($self, $opts) = @_;

    my $memlimit = $opts->{memlimit};
    my $rootdir = $self->{rootfs};
    my $suite = $self->{config}->{suite};

    my $base_set = [qw(php-cli libapache2-mod-php php-gd)];
    if ($suite =~ /(?:squeeze|wheezy|jessie)$/) {
	$self->logmsg("WARN: using EOL php release on EOL suite");
	$base_set = [qw(php5 php5-cli libapache2-mod-php5 php5-gd)];
    }
    my $required = $self->compute_required($base_set);

    $self->cache_packages ($required);

    $self->ve_dpkg ('install', @$required);

    if ($memlimit) {
	my $sed_cmd = ['sed', '-e', "s/^\\s*memory_limit\\s*=.*;/memory_limit = ${memlimit}M;/", '-i'];
	if ($suite =~ /(?:squeeze|wheezy|jessie)$/) {
	    push @$sed_cmd, "$rootdir/etc/php5/apache2/php.ini";
	} else {
	    my $found = 0;
	    for my $fn (glob("'${rootdir}/etc/php/*/apache2/php.ini'")) {
		push @$sed_cmd, "$rootdir/$fn";
		$found = 1;
	    }
	    if (!$found) {
		warn "WARN: did not found any php.ini to set the memlimit!\n";
		return;
	    }
	}
	$self->run_command($sed_cmd);
    }
}

sub install {
    my ($self, $pkglist, $unpack) = @_;

    my $required = $self->compute_required ($pkglist);

    $self->cache_packages ($required);

    $self->ve_dpkg ($unpack ? 'unpack' : 'install', @$required);
}

sub cleanup {
    my ($self, $distclean) = @_;

    unlink $self->{logfile};
    unlink "$self->{targetname}.tar";
    unlink "$self->{targetname}.tar.gz";

    $self->ve_destroy ();
    unlink ".veid";

    rmtree $self->{cachedir} if $distclean && !$self->{config}->{cachedir};

    rmtree $self->{infodir};

}

1;
