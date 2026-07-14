package PVE::DAB;

use strict;
use warnings;

use Cwd;
use File::Basename;
use File::Path;
use File::Copy;
use IO::File;
use IO::Select;
use IPC::Open2;
use IPC::Open3;
use JSON::PP qw(encode_json decode_json);
use POSIX qw (LONG_MAX);
use UUID;

# resolves the syscall numbers used below for the ABI of the running perl interpreter
require 'syscall.ph';

# fixme: lock container ?

# the override is mainly for running dab directly from a source checkout
my $dab_share_dir = $ENV{DAB_SHARE_DIR} // "/usr/share/dab";
my $devicetar = "$dab_share_dir/devices.tar.gz";
my $default_env = "$dab_share_dir/scripts/defenv";
my $fake_init = "$dab_share_dir/scripts/init.pl";
my $script_ssh_init = "$dab_share_dir/scripts/ssh_gen_host_keys";
my $script_mysql_randompw = "$dab_share_dir/scripts/mysql_randompw";
my $script_init_urandom = "$dab_share_dir/scripts/init_urandom";

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

# global defaults are:
#  origin: debian
#  systemd: true
my $suite_defaults = {
    debian => {
        keyring => '/usr/share/keyrings/debian-archive-keyring.gpg',
    },
    devuan => {
        #keyring => '/usr/share/keyrings/devuan-archive-keyring.gpg', # TODO: verify
        systemd => 0,
    },
    ubuntu => {
        keyring => '/usr/share/keyrings/ubuntu-archive-keyring.gpg',
    },
};

my $supported_suites = {
    'trixie' => {
        ostype => "debian-13",
        modern_apt_sources => 1,
    },
    'bookworm' => {
        ostype => "debian-12",
    },
    'bullseye' => {
        ostype => "debian-11",
    },

    # DEVUAN (imply systemd = 0 default)
    'beowulf' => {
        ostype => "devuan-3.0",
        origin => 'devuan',
    },
    'chimaera' => {
        ostype => "devuan-4.0",
        origin => 'devuan',
    },
    'daedalus' => {
        ostype => "devuan-5.0",
        origin => 'devuan',
    },
    'excalibur' => {
        ostype => "devuan-6.0",
        origin => 'devuan',
    },

    # UBUNTU
    'bionic' => {
        ostype => "ubuntu-18.04",
        origin => 'ubuntu',
    },
    'focal' => {
        ostype => "ubuntu-20.04",
        origin => 'ubuntu',
    },
    'jammy' => {
        ostype => "ubuntu-22.04",
        origin => 'ubuntu',
    },
    'noble' => {
        ostype => "ubuntu-24.04",
        origin => 'ubuntu',
    },
    'oracular' => {
        ostype => "ubuntu-24.10",
        origin => 'ubuntu',
    },
    'plucky' => {
        ostype => "ubuntu-25.04",
        origin => 'ubuntu',
        modern_apt_sources => 1,
    },
    'questing' => {
        ostype => "ubuntu-25.10",
        origin => 'ubuntu',
        modern_apt_sources => 1,
    },
    'resolute' => {
        ostype => "ubuntu-26.04",
        origin => 'ubuntu',
        modern_apt_sources => 1,
    },
};

sub get_suite_info {
    my ($suite) = @_;

    my $suiteinfo = $supported_suites->{$suite} || die "unsupported suite '$suite'!\n";

    # set defaults
    $suiteinfo->{origin} //= 'debian';
    if (my $defaults = $suite_defaults->{ $suiteinfo->{origin} }) {
        $suiteinfo->{$_} //= $defaults->{$_} for keys $defaults->%*;
    }
    $suiteinfo->{suite} //= $suite;
    $suiteinfo->{systemd} //= 1;

    return $suiteinfo;
}

sub download {
    my ($self, $url, $path) = @_;
    my $tmpfn = "$path.tmp$$";

    $self->logmsg("download: $url\n");

    eval { $self->run_command("wget -q '$url'  -O '$tmpfn'") };
    if (my $err = $@) {
        unlink $tmpfn;
        die $err;
    }

    rename($tmpfn, $path);
}

sub write_file {
    my ($data, $file, $perm) = @_;

    die "no filename" if !$file;

    unlink $file;

    my $fh = IO::File->new($file, O_WRONLY | O_CREAT, $perm)
        || die "unable to open file '$file'";

    print $fh $data;

    $fh->close;

    # the perm passed to open above gets masked by the umask, so enforce it explicitly
    chmod($perm, $file) or die "unable to chmod file '$file' - $!\n" if defined($perm);
}

sub read_file {
    my ($file) = @_;

    die "no filename" if !$file;

    my $fh = IO::File->new($file)
        || die "unable to open file '$file'";

    local $/; # slurp mode

    my $data = <$fh>;

    $fh->close;

    return $data // ''; # empty files yield undef in slurp mode
}

# copy a file's contents without preserving any attributes of the source; the destination is
# created with 0666 & ~umask unless an explicit $perm is given.
sub copy_file {
    my ($src, $dst, $perm) = @_;

    copy($src, $dst) or die "unable to copy '$src' to '$dst' - $!\n";
    chmod($perm, $dst) or die "unable to chmod file '$dst' - $!\n" if defined($perm);
}

sub symln {
    my ($a, $b) = @_;
    symlink($a, $b) or die "failed to symlink $a => $b: $!";
}

# Look up the sub-id ranges for the user in $file (/etc/subuid or /etc/subgid); entries may be
# keyed on the user name or the numeric uid. Returns a hash with 'base' (first id) and 'count'
# (range size) for the first entry covering at least $needed ids; dies if there is none.
sub __parse_subid_range {
    my ($user, $uid, $file, $needed) = @_;

    my $fh = IO::File->new($file, 'r')
        || die "unable to open '$file' - $!\n";

    my @ranges;
    while (defined(my $line = <$fh>)) {
        next if $line =~ m/^\s*(?:\#|$)/;
        if ($line =~ m/^([^:]+):(\d+):(\d+)\s*$/) {
            push @ranges, { base => $2, count => $3 } if $1 eq $user || $1 eq "$uid";
        }
    }
    close($fh);

    for my $range (@ranges) {
        return $range if $range->{count} >= $needed;
    }
    die "no entry for user '$user' in '$file' - allocate a sub-id range first\n" if !@ranges;
    die "all sub-id ranges for '$user' in '$file' are too small (need >= $needed ids)\n";
}

use constant CLONE_NEWNS => 0x00020000;
use constant CLONE_NEWUSER => 0x10000000;
use constant MS_REC => 0x4000;
use constant MS_SLAVE => 0x80000;

# Thin wrapper around the unshare(2) syscall. Returns true on success.
sub __unshare {
    my ($flags) = @_;
    return 0 == syscall(&SYS_unshare, $flags);
}

# Thin wrapper around the mount(2) syscall. Pass undef for any argument that should be a NULL
# pointer. Returns true on success.
sub __mount {
    my ($source, $target, $fstype, $flags, $data) = @_;
    return 0 == syscall(&SYS_mount, $source // 0, $target // 0, $fstype // 0, $flags, $data // 0);
}

sub read_config {
    my ($filename) = @_;

    my $res = {};

    my $fh = IO::File->new("<$filename") || return $res;
    my $rec = '';

    while (defined(my $line = <$fh>)) {
        next if $line =~ m/^\#/;
        next if $line =~ m/^\s*$/;
        $rec .= $line;
    }

    close($fh);

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
            my ($key, $value) = (lc($1), $2);
            if ($key eq 'source' || $key eq 'mirror' || $key eq 'install-source') {
                push @{ $res->{$key} }, $value;
            } else {
                die "duplicate key '$key'\n" if defined($res->{$key});
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
    my $error = IO::File->new();

    my $orig_pid = $$;

    my $cmdstr = ref($cmd) eq 'ARRAY' ? join(' ', @$cmd) : $cmd;

    my $pid;
    eval {
        if (ref($cmd) eq 'ARRAY') {
            $pid = open3($writer, $reader, $error, @$cmd) || die $!;
        } else {
            $pid = open3($writer, $reader, $error, $cmdstr) || die $!;
        }
    };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
        $self->logmsg("ERROR: command '$cmdstr' failed - fork failed\n");
        POSIX::_exit(1);
        kill('KILL', $$);
    }

    die $err if $err;

    print $writer $input if defined $input;
    close $writer;

    my $select = IO::Select->new();
    $select->add($reader);
    $select->add($error);

    my $res = '';
    my $logfd = $self->{logfd};

    while ($select->count) {
        my @handles = $select->can_read();

        foreach my $h (@handles) {
            my $buf = '';
            my $count = sysread($h, $buf, 4096);
            if (!defined($count)) {
                waitpid($pid, 0);
                die "command '$cmdstr' failed: $!";
            }
            $select->remove($h) if !$count;

            print $logfd $buf;

            $res .= $buf if $getoutput;
        }
    }

    waitpid($pid, 0);
    my $ec = ($? >> 8);

    die "command '$cmdstr' failed with exit code $ec\n" if $ec;

    return $res;
}

# Run a Perl closure in an isolated subprocess. Always provides:
#   * a forked process, so a die or crash in $code does not affect the caller,
#   * a fresh mount namespace whose root is rslave of the host, so any mounts the closure makes
#     stay contained and cannot propagate back to the host,
#   * a fixed umask of 022, so file modes inside the rootfs do not depend on the caller's umask.
# When the caller is unprivileged, additionally provides a user namespace with the configured
# sub-id range mapped to 0..count and the invoking user mapped right after it, with $code
# executing as uid 0/gid 0 inside that namespace. That way native Perl IO creates files with the
# right ownership for the build without shelling out through lxc-usernsexec, while files owned by
# the invoking user (package cache, working directory) stay accessible via CAP_DAC_OVERRIDE.
#
# The closure may return any JSON-serializable value; that value is round-tripped through a pipe
# and returned to the caller. Errors raised in the closure are likewise propagated and re-raised
# in the caller's process.
sub run_isolated {
    my ($self, $code) = @_;

    # resolve before forking, so a missing sub-id allocation fails with a clean error
    my $idmap = $self->{unprivileged} ? $self->__idmap() : undef;

    pipe(my $ready_r, my $ready_w) or die "pipe(ready): $!\n"; # child -> parent: unshare(2) done
    pipe(my $sync_r, my $sync_w) or die "pipe(sync): $!\n"; # parent -> child: id maps installed
    pipe(my $payload_r, my $payload_w) or die "pipe(payload): $!\n";

    my $pid = fork() // die "fork failed: $!\n";

    if ($pid == 0) {
        # child: enter the isolated namespaces, then wait for parent's go-ahead.
        close($ready_r);
        close($sync_w);
        close($payload_r);

        my $payload = eval {
            my $flags = CLONE_NEWNS;
            $flags |= CLONE_NEWUSER if $self->{unprivileged};
            __unshare($flags)
                or die "unshare() failed: $!\n";

            # detach our mount tree so mount events stay in this namespace
            __mount(undef, '/', undef, MS_REC | MS_SLAVE, undef)
                or die "make-rslave on '/' failed: $!\n";

            # the id maps can only be installed once the user namespace exists, so signal the
            # parent that it is safe to run newuidmap/newgidmap now
            syswrite($ready_w, 'r') // die "failed to signal namespace readiness: $!\n";
            close($ready_w);

            my $n = sysread($sync_r, my $byte, 1);
            die "reading from sync pipe failed: $!\n" if !defined($n);
            die "parent closed sync pipe before signaling - id mapping setup failed\n" if !$n;
            close($sync_r);

            if ($self->{unprivileged}) {
                # a failing POSIX::set[ug]id returns undef, and as undef == 0 is true, an
                # explicit defined check is required to detect errors
                defined(POSIX::setgid(0)) or die "setgid(0) inside userns failed: $!\n";
                defined(POSIX::setuid(0)) or die "setuid(0) inside userns failed: $!\n";
            }
            umask(0022);

            my $result = $code->();
            encode_json({ result => $result });
        };
        my $had_error = 0;
        if (my $err = $@) {
            $had_error = 1;
            $payload = eval { encode_json({ error => $err }) }
                // '{"error":"failed to encode child error"}';
        }

        print {$payload_w} $payload;
        close($payload_w);
        POSIX::_exit($had_error ? 1 : 0);
    }

    # parent: install the id maps when needed, then signal child to proceed.
    close($ready_w);
    close($sync_r);
    close($payload_w);

    my $n = sysread($ready_r, my $ready_byte, 1);
    die "reading from ready pipe failed: $!\n" if !defined($n);
    close($ready_r);

    my $setup_err;
    if ($n && $self->{unprivileged}) {
        my ($egid) = split(/\s+/, $));
        eval {
            # map the sub-id range to 0..count and additionally the invoking user right after
            # it, so the child can still access the caller's files (package cache, working
            # directory) as namespace-root via CAP_DAC_OVERRIDE
            $self->run_command([
                'newuidmap',
                $pid,
                0,
                $idmap->{uid_base},
                $idmap->{count},
                $idmap->{count},
                $>,
                1,
            ]);
            $self->run_command([
                'newgidmap',
                $pid,
                0,
                $idmap->{gid_base},
                $idmap->{count},
                $idmap->{count},
                $egid,
                1,
            ]);
        };
        $setup_err = $@;
    }

    if ($n && !$setup_err) {
        # if the child died early, an unhandled SIGPIPE here would kill us too
        local $SIG{PIPE} = 'IGNORE';
        syswrite($sync_w, 'x');
    }
    close($sync_w); # on setup errors, the child sees EOF instead and aborts

    my $raw = do { local $/; <$payload_r> };
    close($payload_r);

    waitpid($pid, 0);
    my $status = $?;

    die $setup_err if $setup_err;

    if (!defined($raw) || $raw eq '') {
        my $detail =
            ($status & 127)
            ? "killed by signal " . ($status & 127)
            : "exit code " . ($status >> 8);
        die "isolated child produced no payload ($detail)\n";
    }

    my $decoded = eval { decode_json($raw) };
    die "isolated child returned undecodable payload: $@" if $@;
    die $decoded->{error} if defined $decoded->{error};

    return $decoded->{result};
}

sub logmsg {
    my $self = shift;
    print STDERR @_;
    $self->writelog(@_);
}

sub writelog {
    my $self = shift;
    my $fd = $self->{logfd};
    print $fd @_;
}

# Resolve and validate the sub-id mapping for unprivileged use on first call, so that commands
# which never touch namespaces keep working for users without a sub-id allocation.
sub __idmap {
    my ($self) = @_;

    return $self->{idmap} if $self->{idmap};

    my $user = getpwuid($>) // die "cannot resolve current user (uid=$>)\n";

    my $needed = 65536;
    my $subuid = __parse_subid_range($user, $>, '/etc/subuid', $needed);
    my $subgid = __parse_subid_range($user, $>, '/etc/subgid', $needed);

    for my $tool ('newuidmap', 'newgidmap') {
        die "required tool '$tool' not found in PATH (install package 'uidmap')\n"
            if !grep { -x "$_/$tool" } split(/:/, $ENV{PATH} // '/usr/sbin:/usr/bin:/sbin:/bin');
    }

    return $self->{idmap} = {
        uid_base => $subuid->{base},
        gid_base => $subgid->{base},
        count => $needed,
    };
}

sub __sample_config {
    my ($self) = @_;

    my $data = '';
    my $arch = $self->{config}->{architecture};

    my $ostype = $self->{config}->{ostype};

    if ($ostype =~ m/^de(bi|vu)an-/) {
        $data .= "lxc.include = /usr/share/lxc/config/debian.common.conf\n";
        $data .= "lxc.include = /usr/share/lxc/config/debian.userns.conf\n"
            if $self->{unprivileged};
    } elsif ($ostype =~ m/^ubuntu-/) {
        $data .= "lxc.include = /usr/share/lxc/config/ubuntu.common.conf\n";
        $data .= "lxc.include = /usr/share/lxc/config/ubuntu.userns.conf\n"
            if $self->{unprivileged};
    } else {
        die "unknown os type '$ostype'\n";
    }
    if ($self->{unprivileged}) {
        my $idmap = $self->__idmap();
        $data .= "lxc.idmap = u 0 $idmap->{uid_base} $idmap->{count}\n";
        $data .= "lxc.idmap = g 0 $idmap->{gid_base} $idmap->{count}\n";
    }
    $data .= "lxc.uts.name = localhost\n";
    $data .= "lxc.rootfs.path = $self->{rootfs}\n";

    return $data;
}

sub __default_workdir_base {
    return '/var/tmp/dab-' . (getpwuid($>) // $>);
}

# The default work directory base has a predictable name inside the world-writable /var/tmp, so
# refuse to use it if another local user squatted the path (or planted a symbolic link) before
# the first build of the invoking user created it. This is not racy: once the directory
# verifies as owned by the user, the sticky bit of /var/tmp prevents other users from replacing
# the entry, and its 0711 mode prevents touching anything inside.
sub __assert_owned_dir {
    my ($dir) = @_;

    die "'$dir' is a symbolic link, refusing to use it as work directory\n" if -l $dir;

    my @st = stat($dir);
    die "cannot stat '$dir' - $!\n" if !@st;
    die "work directory '$dir' is not owned by the current user (owner has uid $st[4])\n"
        if $st[4] != $>;
    die "work directory '$dir' is writable by others\n" if $st[2] & 0002;
}

sub __allocate_ve {
    my ($self) = @_;

    my $cid;
    if (my $fd = IO::File->new(".veid")) {
        $cid = <$fd>;
        chomp $cid;
        close($fd);
    }

    $self->{working_dir} = getcwd;
    $self->{veconffile} = "$self->{working_dir}/config";

    # the work directory hosts the container root file system and runtime state, so that those
    # can live outside of restricted (home) directories for unprivileged builds; default to a
    # per-user directory below the world-traversable /var/tmp for those, as any place below the
    # user's home is normally not traversable for the container's mapped ids
    my $workdir = $self->{cli_opts}->{workdir} // $self->{config}->{workdir};
    $workdir //= __default_workdir_base() if $self->{unprivileged};

    if ($workdir) {
        $workdir = "$self->{working_dir}/$workdir" if $workdir !~ m|^/|;
        my $base = $workdir;
        my $default_base = $base eq __default_workdir_base();
        die "'$base' is a symbolic link, refusing to use it as work directory\n"
            if $default_base && -l $base;
        $workdir .= "/$self->{targetname}"; # allow sharing one work directory across projects
        my @created = mkpath($workdir, 0, 0711);
        chmod(0711, @created) if @created; # mkpath modes get masked by the umask
        die "work directory '$workdir' does not exist and could not be created\n"
            if !-d $workdir;

        if ($default_base) {
            __assert_owned_dir($base);
        } else {
            # explicitly configured bases may be shared or user-managed, but if others can
            # write to the base they must not be able to swap the per-target entry underneath
            # us, which only the sticky bit prevents then
            my @st = stat($base);
            die "cannot stat work directory '$base' - $!\n" if !@st;
            die "work directory '$base' is writable by others without the sticky bit set\n"
                if ($st[2] & 0002) && !($st[2] & 01000);
        }
        __assert_owned_dir($workdir);
        $self->{build_dir} = $workdir;
    } else {
        $self->{build_dir} = $self->{working_dir};
    }
    $self->{rootfs} = "$self->{build_dir}/rootfs";

    if ($cid) {
        $self->{veid} = $cid;
        # the root file system location recorded at allocation time is authoritative, lxc
        # mounts that path; adopt it so that changing the work directory of an existing
        # allocation cannot orphan the current root file system
        if (
            -f $self->{veconffile}
            && read_file($self->{veconffile}) =~ m|^lxc\.rootfs\.path = (\S+)$|m
        ) {
            my $allocated_rootfs = $1;
            if ($allocated_rootfs ne $self->{rootfs}) {
                $self->logmsg("note: keeping root file system at '$allocated_rootfs' from the"
                    . " existing allocation, run dist-clean first to move the work directory\n"
                );
                $self->{rootfs} = $allocated_rootfs;
                $self->{build_dir} = dirname($allocated_rootfs);
            }
        }
        $self->__assert_config_compat();
        return $cid;
    }

    my $uuid;
    my $uuid_str;
    UUID::generate($uuid);
    UUID::unparse($uuid, $uuid_str);
    $self->{veid} = $uuid_str;

    my $fd = IO::File->new(">.veid")
        || die "unable to write '.veid'\n";
    print $fd "$self->{veid}\n";
    close($fd);

    my $cdata = $self->__sample_config();

    my $fh = IO::File->new($self->{veconffile}, O_WRONLY | O_CREAT | O_EXCL)
        || die "unable to write lxc config file '$self->{veconffile}' - $!";
    print $fh $cdata;
    close($fh);

    # create the rootfs directory in the namespace, so its owner maps to root inside it and the
    # archived './' entry ends up with the right ownership
    $self->run_isolated(sub {
        mkdir($self->{rootfs}) or die "unable to create rootfs - $!\n";
    });

    $self->logmsg("allocated VE $self->{veid}\n");

    return $self->{veid};
}

# The lxc config generated at allocation time bakes in whether the build is unprivileged and
# which sub-id range it maps, so later invocations must match: mixing them would create files
# in the rootfs that the other mode cannot access, or even delete, anymore.
sub __assert_config_compat {
    my ($self) = @_;

    my $conffile = $self->{veconffile};
    return if !-f $conffile;

    my $conf = read_file($conffile);
    my $conf_unprivileged = $conf =~ m/^lxc\.idmap\s*=/m ? 1 : 0;
    if ($conf_unprivileged != $self->{unprivileged}) {
        my ($mode, $other) =
            $conf_unprivileged ? ('unprivileged', 'root') : ('root', 'unprivileged');
        die "this working directory was set up for $mode builds, but dab now runs as $other -"
            . " use the same user as before, or start over in a clean directory\n";
    }
    if ($self->{unprivileged}) {
        my $idmap = $self->__idmap();
        die "the sub-id range changed since this working directory was set up -"
            . " start over in a clean directory\n"
            if $conf !~ m/^lxc\.idmap = u 0 \Q$idmap->{uid_base}\E \Q$idmap->{count}\E$/m;
    }
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

    $self->logmsg("setup usr-merge symlinks for '" . join("', '", @merged_dirs) . "'\n");

    # callers run this inside run_isolated (when unprivileged) or as host root, so native Perl
    # IO produces the right ownership in either case
    for my $dir (@merged_dirs) {
        symlink("usr/$dir", "$rootfs/$dir") or warn "could not create symlink - $!\n";
        mkpath "$rootfs/usr/$dir";
    }
}

sub get_target_name {
    my ($config) = @_;

    my $name = $config->{name} || die "no 'name' specified\n";
    $name =~ m/^[a-z][0-9a-z\-\*\.]+$/ || die "illegal characters in name '$name'\n";

    my ($version, $arch, $ostype) = $config->@{ 'version', 'architecture', 'ostype' };
    $name = "${ostype}-${name}" if $name !~ m/^$ostype/;

    return "${name}_${version}_${arch}";
}

sub new {
    my ($class, $config, $cli_opts) = @_;

    $class = ref($class) || $class;
    $config = read_config('dab.conf') if !$config;

    my $self = {
        config => $config,
        cli_opts => $cli_opts // {},
    };
    bless $self, $class;

    $self->{logfile} = "logfile";
    $self->{logfd} = IO::File->new(">>$self->{logfile}") || die "unable to open log file";
    # flush writes immediately, also so that nothing is lost when forked children (which cannot
    # flush inherited buffers on exit) log through this handle
    $self->{logfd}->autoflush(1);

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
            push @{ $config->{source} },
                (
                    "http://deb.debian.org/debian SUITE main contrib",
                    "http://deb.debian.org/debian SUITE-updates main contrib",
                    "http://security.debian.org SUITE-security main contrib",
                );
        } elsif (lc($suiteinfo->{origin}) eq 'ubuntu') {
            my $comp = "main restricted universe multiverse";
            push @{ $config->{source} },
                (
                    "http://archive.ubuntu.com/ubuntu SUITE $comp",
                    "http://archive.ubuntu.com/ubuntu SUITE-updates $comp",
                    "http://archive.ubuntu.com/ubuntu SUITE-security $comp",
                );
        } else {
            die "implement me";
        }
    }

    my $sources = undef;

    foreach my $s (@{ $config->{source} }) {
        if ($s =~ m@^\s*((https?|ftp)://\S+)\s+(\S+)((\s+(\S+))+)$@) {
            my ($url, $su, $components) = ($1, $3, $4);
            $su =~ s/SUITE/$suite/;
            $components =~ s/^\s+//;
            $components =~ s/\s+$//;
            my $ca;
            foreach my $co (split(/\s+/, $components)) {
                push @$ca, $co;
            }
            $ca = ['main'] if !$ca;

            push @$sources,
                {
                    source => $url,
                    comp => $ca,
                    suite => $su,
                    keep => 1,
                };
        } else {
            die "syntax error in source specification '$s'\n";
        }
    }

    foreach my $is (@{ $config->{'install-source'} }) {
        if ($is =~ m@^\s*((https?|ftp)://\S+)\s+(\S+)((\s+(\S+))+)$@) {
            my ($url, $su, $components) = ($1, $3, $4);
            $su =~ s/SUITE/$suite/;
            $components =~ s/^\s+//;
            $components =~ s/\s+$//;
            my $ca;
            foreach my $co (split(/\s+/, $components)) {
                push @$ca, $co;
            }
            $ca = ['main'] if !$ca;

            push @$sources,
                {
                    source => $url,
                    comp => $ca,
                    suite => $su,
                    keep => 0,
                };
        } else {
            die "syntax error in install-source specification '$is'\n";
        }
    }

    foreach my $m (@{ $config->{mirror} }) {
        if ($m =~ m@^\s*((https?|ftp)://\S+)\s*=>\s*((https?|ftp)://\S+)\s*$@) {
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

    # unprivileged builds use user namespaces to get correct file ownership, see run_isolated
    $self->{unprivileged} = $> != 0 ? 1 : 0;

    $self->__allocate_ve();

    $self->{cachedir} = ($config->{cachedir} || 'cache') . "/$suite";

    my $incl = [qw (less ssh openssh-server logrotate)];
    my $excl = [qw (modutils reiserfsprogs ppp pppconfig pppoe pppoeconf nfs-common mtools ntp)];

    # ubuntu has too many dependencies on udev, so we cannot exclude it (instead we disable udevd)
    if (lc($suiteinfo->{origin}) eq 'ubuntu' && $suiteinfo->{systemd}) {
        push @$incl, 'isc-dhcp-client';
        push @$excl,
            qw(libmodule-build-perl libdrm-common libdrm2 libplymouth5 plymouth plymouth-theme-ubuntu-text powermgmt-base);
        if ($suite eq 'jammy') {
            push @$excl, qw(fuse); # avoid fuse2 <-> fuse3 conflict
        }
    } else {
        push @$excl, qw(module-init-tools pciutils hdparm memtest86+ parted);
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
    my $logfd = $self->{logfd} = IO::File->new(">$self->{logfile}")
        || die "unable to open log file";
    $logfd->autoflush(1);

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

    foreach my $ss (@{ $self->{sources} }) {
        my $src = $ss->{mirror} || $ss->{source};
        my $path = "dists/$ss->{suite}/Release";
        my $url = "$src/$path";
        my $target = __url_to_filename("$ss->{source}/$path");
        eval {
            $self->download($url, "$infodir/$target");
            $self->download("$url.gpg", "$infodir/$target.gpg");
            # fixme: impl. verify (needs --keyring option)
        };
        if (my $err = $@) {
            print $logfd $@;
            warn "Release info ignored\n";
        }

        foreach my $comp (@{ $ss->{comp} }) {
            foreach my $compressor (@$COMPRESSORS) {
                $path = "dists/$ss->{suite}/$comp/binary-$arch/Packages.$compressor->{ext}";
                $target = "$infodir/" . __url_to_filename("$ss->{source}/$path");
                my $pkgsrc = "$src/$path";
                eval {
                    $self->download($pkgsrc, $target);
                    $self->run_command("$compressor->{decomp} '$target'");
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

    write_file($data, $filename, 0644);
}

sub finalize {
    my ($self, $opts) = @_;

    my $suite = $self->{config}->{suite};
    my $infodir = $self->{infodir};
    my $arch = $self->{config}->{architecture};

    my $instpkgs = $self->read_installed();
    my $pkginfo = $self->pkginfo();
    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};
    my $rootdir = $self->{rootfs};

    my $vestat = $self->ve_status();
    die "ve not running - unable to finalize\n" if !$vestat->{running};

    # cleanup mysqld
    if (-f "$rootdir/etc/init.d/mysql") {
        $self->ve_command("/etc/init.d/mysql stop");
    }

    if (!($opts->{keepmycnf} || (-f "$rootdir/etc/init.d/mysql_randompw"))) {
        $self->run_isolated(sub { unlink "$rootdir/root/.my.cnf"; });
    }

    $self->logmsg("cleanup package status\n");
    # prevent auto selection of all standard, required, or important packages which are not installed
    foreach my $pkg (keys %$pkginfo) {
        my $pri = $pkginfo->{$pkg}->{priority};
        if ($pri && ($pri eq 'required' || $pri eq 'important' || $pri eq 'standard')) {
            if (!$instpkgs->{$pkg}) {
                $self->ve_dpkg_set_selection($pkg, 'purge');
            }
        }
    }

    $self->ve_command("apt-get clean");

    $self->logmsg("update available package list\n");

    $self->ve_command("dpkg --clear-avail");
    foreach my $ss (@{ $self->{sources} }) {
        my $relsrc = __url_to_filename("$ss->{source}/dists/$ss->{suite}/Release");
        if (-f "$infodir/$relsrc" && -f "$infodir/$relsrc.gpg") {
            $self->run_isolated(sub {
                copy_file("$infodir/$relsrc", "$rootdir/var/lib/apt/lists/$relsrc", 0644);
                copy_file(
                    "$infodir/$relsrc.gpg", "$rootdir/var/lib/apt/lists/$relsrc.gpg", 0644,
                );
            });
        }
        foreach my $comp (@{ $ss->{comp} }) {
            my $src = __url_to_filename(
                "$ss->{source}/dists/$ss->{suite}/${comp}/binary-${arch}/Packages");
            my $target = "/var/lib/apt/lists/$src";
            $self->run_isolated(sub {
                copy_file("$infodir/$src", "$rootdir/$target", 0644);
            });
            $self->ve_command("dpkg --merge-avail '$target'");
        }
    }

    $self->run_isolated(sub {
        # set dselect default method
        write_file("apt apt\n", "$rootdir/var/lib/dpkg/cmethopt");
    });

    $self->ve_divert_remove("/usr/sbin/policy-rc.d");

    $self->ve_divert_remove("/sbin/start-stop-daemon");

    $self->ve_divert_remove("/sbin/init");

    # finally stop the VE
    $self->run_command("lxc-stop -n $veid -P $self->{build_dir} --rcfile $conffile --kill");

    $self->run_isolated(sub {
        unlink "$rootdir/sbin/defenv";
        unlink <$rootdir/root/dead.letter*>;
        unlink "$rootdir/var/log/init.log";
        unlink "$rootdir/aquota.group", "$rootdir/aquota.user";
        write_file("", "$rootdir/var/log/syslog");
    });

    my $get_path_size = sub {
        my ($path) = @_;
        my $sizestr = $self->run_command("du -sm $path", undef, 1);
        if ($sizestr =~ m/^(\d+)\s+\Q$path\E$/) {
            return int($1);
        } else {
            die "unable to detect size for '$path'\n";
        }
    };

    $self->logmsg("detecting final appliance size: ");
    # the rootfs contains sub-id-owned directories without world access (like /root), so the
    # size detection must also run inside the user namespace
    my $size = $self->run_isolated(sub { return $get_path_size->($rootdir); });
    $self->logmsg("$size MB\n");

    $self->logmsg("creating final appliance archive\n");

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
    die "unkown compressor '$compressor', use one of: " . join(', ', sort keys %$compressor2cmd_map)
        if !defined($compressor_cmd);

    my $ending = $compressor2ending->{$compressor} // $compressor;
    my $final_archive = "${target}.${ending}";
    unlink $target;
    unlink $final_archive;

    # write appliance.info and archive the rootfs inside the user namespace, so ownerships in
    # the resulting tar are recorded as 0:0 (and not as the host sub-id base).
    $self->run_isolated(sub {
        $self->write_config("$rootdir/etc/appliance.info", $size);
        $self->run_command(
            ['tar', 'cpf', $target, '--numeric-owner', '-C', $rootdir, './etc/appliance.info']);
        $self->run_command([
            'tar',
            'rpf',
            $target,
            '--numeric-owner',
            '-C',
            $rootdir,
            '--exclude',
            './etc/appliance.info',
            '.',
        ]);
    });

    # the intermediate tar is owned by the sub-id base but world-readable (run_isolated forces
    # umask 022); running the compressor in the parent (uid of the operator) writes the final
    # compressed artifact owned by that operator, and the compressors we wrap (gzip default,
    # zstd --rm) remove the intermediate after success.
    $self->run_command("$compressor_cmd $target");

    $self->logmsg("detecting final commpressed appliance size: ");
    $size = $get_path_size->($final_archive);
    $self->logmsg("$size MB\n");

    $self->logmsg("appliance archive: $final_archive\n");
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
            $res->{ lc $1 } = $2;
        }

        my $pkg = $res->{'package'};
        if (my $status = $res->{status}) {
            my @sa = split(/\s+/, $status);
            my $stat = $sa[0];
            if ($stat && ($stat ne 'purge')) {
                $pkglist->{$pkg} = $res;
            }
        }
    }

    close($PKGLST);

    return $pkglist;
}

sub ve_status {
    my ($self) = @_;

    my $veid = $self->{veid};

    my $res = { running => 0 };

    $res->{exist} = 1 if -d "$self->{rootfs}/usr";

    my $filename = "/proc/net/unix";

    # similar test is used by lcxcontainers.c: list_active_containers
    my $fh = IO::File->new($filename, "r");
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

    if (ref($cmd) eq 'ARRAY') {
        unshift @$cmd, 'lxc-attach', '-n', $veid, '-P', $self->{build_dir}, '--rcfile',
            $conffile, '--clear-env', '--', 'defenv';
        $self->run_command($cmd, $input);
    } else {
        $self->run_command(
            "lxc-attach -n $veid -P $self->{build_dir} --rcfile $conffile --clear-env"
                . " -- defenv $cmd",
            $input,
        );
    }
}

# like ve_command, but pipes stdin correctly
sub ve_exec {
    my ($self, @cmd) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    my $reader;
    my $pid = open2(
        $reader,
        "<&STDIN",
        'lxc-attach',
        '-n',
        $veid,
        '-P',
        $self->{build_dir},
        '--rcfile',
        $conffile,
        '--',
        'defenv',
        @cmd,
    ) || die "unable to exec command";

    while (defined(my $line = <$reader>)) {
        $self->logmsg($line);
    }

    waitpid($pid, 0);
    my $rc = $? >> 8;

    die "ve_exec failed - status $rc\n" if $rc != 0;
}

sub ve_divert_add {
    my ($self, $filename) = @_;

    $self->ve_command("dpkg-divert --add --divert '$filename.distrib' --rename '$filename'");
}

sub ve_divert_remove {
    my ($self, $filename) = @_;

    my $rootdir = $self->{rootfs};

    $self->run_isolated(sub { unlink "$rootdir/$filename"; });
    $self->ve_command("dpkg-divert --remove --rename '$filename'");
}

sub ve_debconfig_set {
    my ($self, $dcdata) = @_;

    my $rootdir = $self->{rootfs};
    my $cfgfile = "/tmp/debconf.txt";
    $self->run_isolated(sub { write_file($dcdata, "$rootdir/$cfgfile"); });
    $self->ve_command("debconf-set-selections $cfgfile");
    $self->run_isolated(sub { unlink "$rootdir/$cfgfile"; });
}

sub ve_dpkg_set_selection {
    my ($self, $pkg, $status) = @_;

    $self->ve_command("dpkg --set-selections", "$pkg $status");
}

sub ve_dpkg {
    my ($self, $cmd, @pkglist) = @_;

    return if !scalar(@pkglist);

    my $pkginfo = $self->pkginfo();

    my $rootdir = $self->{rootfs};
    my $cachedir = $self->{cachedir};

    my @files;
    foreach my $pkg (@pkglist) {
        my $filename = $self->getpkgfile($pkg);
        push @files, "/$filename";
        $self->logmsg("$cmd: $pkg\n");
    }

    $self->run_isolated(sub {
        copy_file("$cachedir$_", "$rootdir$_") for @files;
    });

    my $fl = join(' ', @files);

    if ($cmd eq 'install') {
        $self->ve_command("dpkg --force-depends --force-confold --install $fl");
    } elsif ($cmd eq 'unpack') {
        $self->ve_command("dpkg --force-depends --unpack $fl");
    } else {
        die "internal error";
    }

    $self->run_isolated(sub {
        unlink "$rootdir$_" for @files;
    });
}

sub ve_destroy {
    my ($self) = @_;

    my $veid = $self->{veid}; # fixme
    my $conffile = $self->{veconffile};

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
        $self->run_command("lxc-stop -n $veid -P $self->{build_dir} --rcfile $conffile --kill");
    }

    $self->__rmtree_rootfs();
    unlink $self->{veconffile};
}

sub ve_init {
    my ($self) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    $self->logmsg("initialize VE $veid\n");

    my $vestat = $self->ve_status();
    if ($vestat->{running}) {
        $self->run_command("lxc-stop -n $veid -P $self->{build_dir} --rcfile $conffile --kill");
    }

    $self->__rmtree_rootfs();
    # recreate in the namespace, so the directory owner maps to root inside it
    $self->run_isolated(sub { mkpath $self->{rootfs}; });
}

# Remove the rootfs tree. When unprivileged the contents are owned by mapped sub-ids, so we have
# to delete them from inside the user namespace.
sub __rmtree_rootfs {
    my ($self) = @_;

    return if !-d $self->{rootfs};

    $self->run_isolated(sub { rmtree $self->{rootfs}; });
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
            $res->{ lc $1 } = $2;
        }

        my $pkg = $res->{'package'};
        if ($pkg && $res->{'filename'}) {
            my $cur;
            if (my $info = $pkginfo->{$pkg}) {
                $cur = $info->{version};
            }
            my $new = $res->{version};
            if (!$cur || __deb_version_cmp($cur, 'lt', $new)) {
                if ($src) {
                    $res->{url} = "$src/$res->{'filename'}";
                } else {
                    die "no url for package '$pkg'" if !$res->{url};
                }
                $pkginfo->{$pkg} = $res;
            }
        }
    }

    close($PKGLST);
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
        __parse_packages($pkginfo, $availfn);
        $self->{pkginfo} = $pkginfo;
        return $pkginfo;
    }

    $self->logmsg("generating available package list\n");

    foreach my $ss (@{ $self->{sources} }) {
        foreach my $comp (@{ $ss->{comp} }) {
            my $url = "$ss->{source}/dists/$ss->{suite}/$comp/binary-$arch/Packages";
            my $pkgfilelist = "$infodir/" . __url_to_filename($url);

            my $src = $ss->{mirror} || $ss->{source};

            __parse_packages($pkginfo, $pkgfilelist, $src);
        }
    }

    if (my $dep = $self->{config}->{depends}) {
        foreach my $d (split(/,/, $dep)) {
            if ($d =~ m/^\s*(\S+)\s*(\((\S+)\s+(\S+)\)\s*)?$/) {
                my ($pkg, $op, $rver) = ($1, $3, $4);
                $self->logmsg("checking dependencies: $d\n");
                my $info = $pkginfo->{$pkg};
                die "package '$pkg' not available\n" if !$info;
                if ($op) {
                    my $cver = $info->{version};
                    if (!__deb_version_cmp($cver, $op, $rver)) {
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
    my $fd = IO::File->new(">$tmpfn");
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
    close($fd);

    rename($tmpfn, $availfn);

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
            my @pl = split(',', $prov);
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
    __record_provides($pkginfo, $closure, $list, 1);

    my $pkghash = {};
    my $pkglist = [];

    # then resolve dependencies
    foreach my $pname (@$list) {
        __closure_single($pkginfo, $closure, $pkghash, $pkglist, $pname, $self->{excl});
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

    __record_provides($pkginfo, $closure, [$pname]) if $info->{provides};

    $closure->{$pname} = 1;

    #print "$url\n";

    my @l;

    push @l, split(/,/, $predep) if $predep;
    push @l, split(/,/, $dep) if $dep;

DEPEND: foreach my $p (@l) {
        my @l1 = split(/\|/, $p);
        foreach my $p1 (@l1) {
            if ($p1 =~ m/^\s*(\S+).*/) {
                #printf (STDERR "$pname: $p --> $1\n");
                if ($closure->{$1}) {
                    next DEPEND; # dependency already met
                }
            }
        }
        # search for non-excluded alternative
        my $success;
        foreach my $p1 (@l1) {
            next unless $p1 =~ /^\s*(\S+)/;
            my $candidate = $1;

            next if grep { $candidate eq $_ } @$excl;

            #print STDERR "$pname: trying $candidate for '$p'\n";

            my $ok = eval {
                __closure_single($pkginfo, $closure, $pkghash, $pkglist, $candidate, $excl);
                1;
            };

            if ($ok) {
                $success = 1;
                last;
            } else {
                print STDERR "$pname: $candidate failed, trying next alternative...\n";
            }
        }

        die "package '$pname' could not satisfy dependency '$p' (all alternatives failed)\n"
            unless $success;
    }
}

sub cache_packages {
    my ($self, $pkglist) = @_;

    foreach my $pkg (@$pkglist) {
        $self->getpkgfile($pkg);
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

    $self->download($url, "$cachedir/$filename");

    return $filename;
}

sub install_init_script {
    my ($self, $script, $runlevel, $prio) = @_;

    my $suite = $self->{config}->{suite};
    my $suiteinfo = get_suite_info($suite);
    my $rootdir = $self->{rootfs};

    my $base = basename($script);
    my $target = "$rootdir/etc/init.d/$base";

    $self->run_isolated(sub {
        copy_file($script, $target, 0755);
    });
    if ($suiteinfo->{systemd}) {
        die "unable to install init script (system uses systemd)\n";
    } elsif ($suite eq 'trusty' || $suite eq 'precise') {
        die "unable to install init script (system uses upstart)\n";
    } else {
        $self->ve_command("insserv $base");
    }

    return $target;
}

sub mask_systemd_unit {
    my ($self, $unit) = @_;

    my $root = $self->{rootfs};
    symln('/dev/null', "$root/etc/systemd/system/$unit");
}

sub bootstrap {
    my ($self, $opts) = @_;

    die "--device-skelleton requires root (mknod is unavailable in user namespaces)\n"
        if $opts->{'device-skelleton'} && $self->{unprivileged};

    my $pkginfo = $self->pkginfo();
    my $veid = $self->{veid};
    my $suite = $self->{config}->{suite};
    my $suiteinfo = get_suite_info($suite);

    my $important = [@{ $self->{incl} }];
    my $required;
    my $standard;

    # some releases do not have the init metapackage in the rquired set anymore, but DAB assumes
    # that, so explicitly add systemd-sysv, which provides the /sbin/init symlink to systemd.
    my $add_systemd_sysv_as_required = $suiteinfo->{systemd};
    push @$required, 'systemd-sysv' if $add_systemd_sysv_as_required;

    if ($opts->{'no-ssh'}) {
        my %remove = (
            'ssh' => 1,
            'openssh-server' => 1,
        );

        @{$important} = grep { !$remove{$_} } @{$important};
    }

    my $mta = $opts->{mta} ? $opts->{mta} : "postfix";

    # Maintain compatibility with `--exim` flag
    if ($opts->{exim}) {
        $mta = "exim";
    }

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
        next if grep { $p eq $_ } @{ $self->{excl} };
        my $pri = $pkginfo->{$p}->{priority};
        next if !$pri;
        next if $mta ne 'exim' && $p =~ m/exim/;
        next if $p =~ m/(selinux|semanage|policycoreutils)/;

        push @$required, $p if $pri eq 'required';
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
        foreach my $d (split(/,/, $mdeps)) {
            if ($d =~ m/^\s*(\S+)$/) {
                my $pkg = $1;
                next if $closure->{$pkg};
                next if grep { $pkg eq $_ } @{ $self->{excl} };
                die "missing ubuntu-minimal package '$pkg'\n";
            }
        }
        if (!$opts->{minimal}) {
            $mdeps = $pkginfo->{'ubuntu-standard'}->{depends};
            foreach my $d (split(/,/, $mdeps)) {
                if ($d =~ m/^\s*(\S+)$/) {
                    my $pkg = $1;
                    next if $closure->{$pkg};
                    next if grep { $pkg eq $_ } @{ $self->{excl} };
                    die "missing ubuntu-standard package '$pkg'\n";
                }
            }
        }
    }

    # download/cache all files first
    $self->cache_packages($required);
    $self->cache_packages($important);
    $self->cache_packages($standard);

    my $rootdir = $self->{rootfs};

    $self->logmsg("create basic environment\n");

    my $compressor2opt = {
        'zst' => '--zstd',
        'gz' => '--gzip',
        'xz' => '--xz',
    };
    my $compressor_re = join('|', keys $compressor2opt->%*);

    # everything below up to lxc-start touches the rootfs from outside the container; do it in
    # one isolated subprocess so native Perl IO yields correct ownership without each call
    # having to wrap in lxc-usernsexec
    $self->run_isolated(sub {
        if ($self->can_usr_merge()) {
            $self->setup_usr_merge();
        }

        $self->logmsg("extract required packages to rootfs\n");
        foreach my $p (@$required) {
            my $filename = $self->getpkgfile($p);
            my $content = $self->run_command("ar -t '$self->{cachedir}/$filename'", undef, 1);
            if ($content =~ m/^(data.tar.($compressor_re))$/m) {
                my $archive = $1;
                my $tar_opts = "--keep-directory-symlink $compressor2opt->{$2}";

                $self->run_command(
                    "ar -p '$self->{cachedir}/$filename' '$archive' | tar -C '$rootdir' -xf - $tar_opts"
                );
            } else {
                die "unexpected error for $p: no data.tar.{xz,gz,zst} found...";
            }
        }

        # fake dpkg status
        my $data =
            "Package: dpkg\n"
            . "Version: $pkginfo->{dpkg}->{version}\n"
            . "Status: install ok installed\n";

        write_file($data, "$rootdir/var/lib/dpkg/status");
        write_file("", "$rootdir/var/lib/dpkg/info/dpkg.list");
        write_file("", "$rootdir/var/lib/dpkg/available");

        $data = '';
        if ($suiteinfo->{modern_apt_sources}) {
            mkdir "$rootdir/etc/apt/sources.list.d";
            my $origin = lc($suiteinfo->{origin});
            my $keyring = $suiteinfo->{keyring} or die "missing keyring for origin '$origin'";
            my @keep_sources = grep { $_->{keep} } $self->{sources}->@*;
            my $uris = { map { $_->{source} => 1 } @keep_sources };

            for my $uri (keys $uris->%*) {
                my $sources = [grep { $_->{source} eq $uri } $self->{sources}->@*];

                my $suites = join(' ', (map { $_->{suite} } $sources->@*));
                my $unique_components =
                    { map { $_ => 1 } (map { $_->{comp}->@* } $sources->@*) };
                my $components = join(' ', (sort keys $unique_components->%*));

                $data .= "\n" if $data ne '';
                $data .= "Types: deb\n";
                $data .= "URIs: $uri\n";
                $data .= "Suites: $suites\n";
                $data .= "Components: $components\n";
                $data .= "Signed-By: $keyring\n";
            }

            write_file($data, "$rootdir/etc/apt/sources.list.d/${origin}.sources");
        } else {
            foreach my $ss (@{ $self->{sources} }) {
                my $url = $ss->{source};
                my $comp = join(' ', @{ $ss->{comp} });
                $data .= "deb $url $ss->{suite} $comp\n\n";
            }

            write_file($data, "$rootdir/etc/apt/sources.list");
        }

        write_file("# UNCONFIGURED FSTAB FOR BASE SYSTEM\n", "$rootdir/etc/fstab", 0644);
        write_file("localhost\n", "$rootdir/etc/hostname", 0644);
        write_file("", "$rootdir/etc/resolv.conf", 0644);

        if (lc($suiteinfo->{origin}) eq 'ubuntu' && $suiteinfo->{systemd}) {
            # no need to configure loopback device
            # FIXME: Debian (systemd based?) too?
        } else {
            mkdir "$rootdir/etc/network";
            write_file(
                "auto lo\niface lo inet loopback\n",
                "$rootdir/etc/network/interfaces",
                0644,
            );
        }

        if ($opts->{'device-skelleton'}) {
            $self->run_command("tar xzf '$devicetar' -C '$rootdir'");
        }

        write_file("LANG=\"C\"\n", "$rootdir/etc/default/locale", 0644);

        # fake init
        rename("$rootdir/sbin/init", "$rootdir/sbin/init.org")
            or die "failed to backup distro 'init' for manual diversion - $!";
        copy_file($fake_init, "$rootdir/sbin/init", 0755);
        copy_file($default_env, "$rootdir/sbin/defenv", 0755);
    });

    # use the working directory as lxcpath, the default under $HOME is often not traversable
    # for the mapped ids of unprivileged containers
    $self->run_command("lxc-start -n $veid -P $self->{build_dir} -f $self->{veconffile}");

    $self->logmsg("initialize ld cache\n");
    $self->ve_command("/sbin/ldconfig");
    $self->run_isolated(sub {
        unlink "$rootdir/usr/bin/awk";
        symln('mawk', "$rootdir/usr/bin/awk");
    });

    $self->logmsg("installing packages\n");

    $self->ve_dpkg('install', 'base-files', 'base-passwd');

    $self->ve_dpkg('install', 'dpkg');

    $self->run_isolated(sub {
        unlink "$rootdir/etc/localtime";
        symln('/usr/share/zoneinfo/UTC', "$rootdir/etc/localtime");
        unlink "$rootdir/bin/sh";
        symln('bash', "$rootdir/bin/sh");
    });

    $self->ve_dpkg('install', 'libc6');
    $self->ve_dpkg('install', 'perl-base');

    $self->run_isolated(sub { unlink "$rootdir/usr/bin/awk"; });

    $self->ve_dpkg('install', 'mawk');
    $self->ve_dpkg('install', 'debconf');

    # unpack required packages
    foreach my $p (@$required) {
        $self->ve_dpkg('unpack', $p);
    }

    $self->run_isolated(sub {
        rename("$rootdir/sbin/init.org", "$rootdir/sbin/init")
            or die "failed to restore distro 'init' for actual diversion - $!";
    });
    $self->ve_divert_add("/sbin/init");
    $self->run_isolated(sub {
        unlink "$rootdir/sbin/init";
        copy_file($fake_init, "$rootdir/sbin/init", 0755);
    });

    # disable service activation
    $self->ve_divert_add("/usr/sbin/policy-rc.d");
    $self->run_isolated(sub {
        write_file("#!/bin/sh\nexit 101\n", "$rootdir/usr/sbin/policy-rc.d", 0755);
    });

    # disable start-stop-daemon
    $self->ve_divert_add("/sbin/start-stop-daemon");
    $self->run_isolated(sub {
        write_file(
            "#!/bin/sh\necho\necho \"Warning: Fake start-stop-daemon called, doing nothing\"\n",
            "$rootdir/sbin/start-stop-daemon",
            0755,
        );
    });

    # disable udevd
    $self->ve_divert_add("/sbin/udevd");

    if ($suite eq 'etch') {
        $self->run_isolated(sub {
            write_file("NO_START=1\n", "$rootdir/etc/default/apache2"); # disable apache2 startup
        });
    }

    $self->logmsg("configure required packages\n");
    $self->ve_command("dpkg --force-confold --skip-same-version --configure -a");

    # set postfix defaults
    if ($mta eq 'postfix') {
        $self->ve_debconfig_set("postfix postfix/main_mailer_type select Local only\n");
        $self->run_isolated(sub {
            write_file("postmaster: root\nwebmaster: root\n", "$rootdir/etc/aliases");
        });
    }

    if ($suite eq 'jaunty') {
        # jaunty does not create /var/run/network, so network startup fails.
        # so we do not use tmpfs for /var/run and /var/lock
        $self->run_isolated(sub {
            $self->run_command(
                "sed -e 's/RAMRUN=yes/RAMRUN=no/' -e 's/RAMLOCK=yes/RAMLOCK=no/'  -i $rootdir/etc/default/rcS"
            );
            mkdir("$rootdir/var/run/network")
                or die "unable to create '/var/run/network' - $!\n";
        });
    }

    # unpack base packages
    foreach my $p (@$important) {
        $self->ve_dpkg('unpack', $p);
    }

    # start loopback
    if (-x "$rootdir/sbin/ifconfig") {
        $self->ve_command("ifconfig lo up");
    } else {
        $self->ve_command("ip link set lo up");
    }

    $self->logmsg("configure important packages\n");
    $self->ve_command("dpkg --force-confold --skip-same-version --configure -a");

    $self->run_isolated(sub {
        if (-d "$rootdir/etc/event.d") {
            unlink <$rootdir/etc/event.d/tty*>;
        }
        if (-f "$rootdir/etc/inittab") {
            $self->run_command(
                ['sed', '-i', '-e', '/getty\s38400\stty[23456]/d', "$rootdir/etc/inittab"]);
        }
        # Link /etc/mtab to /proc/mounts, so df and friends will work
        unlink "$rootdir/etc/mtab";
    });
    $self->ve_command("ln -s /proc/mounts /etc/mtab");

    # reset password
    $self->ve_command("usermod -L root");

    if ($mta eq 'postfix') {
        $self->ve_debconfig_set("postfix postfix/main_mailer_type select No configuration\n");
        $self->run_isolated(sub {
            unlink "$rootdir/etc/mailname";
            write_file($postfix_main_cf, "$rootdir/etc/postfix/main.cf");
        });
    }

    if (!$opts->{minimal}) {
        # unpack standard packages
        foreach my $p (@$standard) {
            $self->ve_dpkg('unpack', $p);
        }

        $self->logmsg("configure standard packages\n");
        $self->ve_command("dpkg --force-confold --skip-same-version --configure -a");
    }

    $self->run_isolated(sub {
        # disable HWCLOCK access
        my $rcS = "$rootdir/etc/default/rcS";
        my $existing = -f $rcS ? read_file($rcS) : '';
        write_file($existing . "HWCLOCKACCESS=no\n", $rcS);
    });

    # disable hald
    $self->ve_divert_add("/usr/sbin/hald");

    $self->run_isolated(sub {
        # disable /dev/urandom init
        copy_file($script_init_urandom, "$rootdir/etc/init.d/urandom", 0755);

        my $cmd = 'find';
        $cmd .= " '$rootdir/etc/sysctl.conf'" if -e "$rootdir/etc/sysctl.conf";
        $cmd .= " '$rootdir/etc/sysctl.d/'" if -d "$rootdir/etc/sysctl.d";
        $cmd .= ' -type f -iname \'*.conf\' -print0';
        $cmd .= '| xargs -0 --no-run-if-empty -- sed';
        $cmd .= ' -e \'s/^\(kernel\.printk.*\)/#\1/\'';
        $cmd .= ' -e \'s/^\(kernel\.maps_protect.*\)/#\1/\'';
        $cmd .= ' -e \'s/^\(fs\.inotify\.max_user_watches.*\)/#\1/\'';
        $cmd .= ' -e \'s/^\(vm\.mmap_min_addr.*\)/#\1/\'';
        $cmd .= " -i";
        $self->run_command($cmd);

        my $bindv6only = "$rootdir/etc/sysctl.d/bindv6only.conf";
        if (-f $bindv6only) {
            $self->run_command(
                ['sed', '-e', 's/^\(net\.ipv6\.bindv6only.*\)/#\1/', '-i', $bindv6only]);
        }
    });

    if ($suite eq 'etch' || $suite eq 'hardy' || $suite eq 'intrepid' || $suite eq 'jaunty') {
        # avoid klogd start
        $self->ve_divert_add("/sbin/klogd");
    }

    if ($suiteinfo->{systemd}) {
        $self->run_isolated(sub {
            for my $unit (
                qw(sys-kernel-config.mount sys-kernel-debug.mount systemd-journald-audit.socket)
            ) {
                $self->logmsg("Masking problematic systemd unit '$unit'\n");
                $self->mask_systemd_unit($unit);
            }
        });
    }
}

sub enter {
    my ($self) = @_;

    my $veid = $self->{veid};
    my $conffile = $self->{veconffile};

    my $vestat = $self->ve_status();

    if (!$vestat->{exist}) {
        $self->logmsg("Please create the appliance first (bootstrap)");
        return;
    }

    if (!$vestat->{running}) {
        $self->run_command("lxc-start -n $veid -P $self->{build_dir} -f $conffile");
    }

    system("lxc-attach -n $veid -P $self->{build_dir} --rcfile $conffile --clear-env");
}

sub ve_mysql_command {
    my ($self, $sql, $password) = @_;

    #my $bootstrap = "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables " .
    #"--skip-bdb  --skip-innodb --skip-ndbcluster";

    $self->ve_command("mysql", $sql);
}

sub ve_mysql_bootstrap {
    my ($self, $sql, $password) = @_;

    my $cmd =
        "/usr/sbin/mysqld --bootstrap --user=mysql --skip-grant-tables --skip-bdb  --skip-innodb --skip-ndbcluster";
    $self->ve_command($cmd, $sql);
}

sub compute_required {
    my ($self, $pkglist) = @_;

    my $pkginfo = $self->pkginfo();
    my $instpkgs = $self->read_installed();

    my $closure = {};
    __record_provides($pkginfo, $closure, [keys $instpkgs->%*]);

    return $self->closure($closure, $pkglist);
}

sub task_postgres {
    my ($self, $opts) = @_;

    my @supp = ('7.4', '8.1');
    my $pgversion; # NOTE: not setting that defaults to the distro default, normally the best choice

    my $suite = $self->{config}->{suite};

    if ($suite eq 'buster') {
        @supp = ('11');
        $pgversion = '11';
    } elsif ($suite eq 'bullseye') {
        @supp = ('13');
    } elsif ($suite eq 'bookworm') {
        @supp = ('15');
    } elsif ($suite eq 'trixie') {
        @supp = ('16', '17');
    }
    $pgversion = $opts->{version} if $opts->{version};

    my $required;
    if (defined($pgversion)) {
        die "unsupported postgres version '$pgversion'\n" if !grep { $pgversion eq $_; } @supp;

        $required = $self->compute_required(["postgresql-$pgversion"]);
    } else {
        $required = $self->compute_required(["postgresql"]);
    }

    $self->cache_packages($required);

    $self->ve_dpkg('install', @$required);

    my $iscript = "postgresql-$pgversion";
    $self->ve_command("/etc/init.d/$iscript start") if $opts->{start};
}

sub task_mysql {
    my ($self, $opts) = @_;

    my $password = $opts->{password};
    my $rootdir = $self->{rootfs};

    my $suite = $self->{config}->{suite};

    my $required = $self->compute_required(['mariadb-server']);

    $self->cache_packages($required);

    $self->ve_dpkg('install', @$required);

    # fix security (see /usr/bin/mysql_secure_installation)
    my $sql =
        "DELETE FROM mysql.user WHERE User='';\n"
        . "DELETE FROM mysql.user WHERE User='root' AND Host!='localhost';\n"
        . "FLUSH PRIVILEGES;\n";
    $self->ve_mysql_bootstrap($sql);

    if ($password) {

        my $rpw = $password eq 'random' ? 'admin' : $password;

        my $sql =
            "USE mysql;\n"
            . "UPDATE user SET password=PASSWORD(\"$rpw\") WHERE user='root';\n"
            . "FLUSH PRIVILEGES;\n";
        $self->ve_mysql_bootstrap($sql);

        $self->run_isolated(sub {
            write_file(
                "[client]\nuser=root\npassword=\"$rpw\"\n",
                "$rootdir/root/.my.cnf",
                0600,
            );
        });
        if ($password eq 'random') {
            $self->install_init_script($script_mysql_randompw, 2, 20);
        }
    }

    $self->ve_command("/etc/init.d/mysql start") if $opts->{start}; # FIXME: use systemd service?!
}

sub task_php {
    my ($self, $opts) = @_;

    my $memlimit = $opts->{memlimit};
    my $rootdir = $self->{rootfs};
    my $suite = $self->{config}->{suite};

    my $base_set = [qw(php-cli libapache2-mod-php php-gd)];
    my $required = $self->compute_required($base_set);

    $self->cache_packages($required);

    $self->ve_dpkg('install', @$required);

    if ($memlimit) {
        my $sed_cmd =
            ['sed', '-e', "s/^\\s*memory_limit\\s*=.*;/memory_limit = ${memlimit}M;/", '-i'];
        my $found = 0;
        for my $fn (glob("'${rootdir}/etc/php/*/apache2/php.ini'")) {
            push @$sed_cmd, "$rootdir/$fn";
            $found = 1;
        }
        if (!$found) {
            warn "WARN: did not found any php.ini to set the memlimit!\n";
            return;
        }
        $self->run_isolated(sub { $self->run_command($sed_cmd); });
    }
}

sub install {
    my ($self, $pkglist, $unpack) = @_;

    my $required = $self->compute_required($pkglist);

    $self->cache_packages($required);

    $self->ve_dpkg($unpack ? 'unpack' : 'install', @$required);
}

sub cleanup {
    my ($self, $distclean) = @_;

    unlink $self->{logfile};
    unlink "$self->{targetname}.tar";
    unlink "$self->{targetname}.tar.gz";

    $self->ve_destroy();
    unlink ".veid";

    # remove the per-target directory below a separate work directory if empty; also remove the
    # default per-user base then, explicitly configured locations may be shared or user-managed
    if ($self->{build_dir} ne $self->{working_dir}) {
        rmdir $self->{build_dir};
        rmdir dirname($self->{build_dir})
            if dirname($self->{build_dir}) eq __default_workdir_base();
    }

    rmtree $self->{cachedir} if $distclean && !$self->{config}->{cachedir};

    rmtree $self->{infodir};

}

1;
