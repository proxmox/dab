#!/usr/bin/perl -w

use strict;
use POSIX qw (:sys_wait_h strftime);
use POSIX qw(EINTR);
use IO::Socket::UNIX;

$SIG{CHLD} =  sub {
    1 while waitpid(-1, WNOHANG) > 0;
};
$SIG{INT} =  sub {
    print "stopping init\n";
    exit (0);
};

mkdir "/dev";
mkdir "/var/";
mkdir "/var/log";

my $logfile = "/var/log/init.log";

close (STDOUT);
open (STDOUT, ">>$logfile");
close (STDERR);
open STDERR, ">&STDOUT";

select STDERR; $| = 1;      # make unbuffered
select STDOUT; $| = 1;      # make unbuffered

my $args = join (" ", @ARGV);

if ($$ != 1) {
    my $l = shift @ARGV;

    if (defined ($l) && $l eq '0') {
	print "initctl $args\n";
	kill 2, 1;
    } else {
	print "initctl $args (ignored)\n";
    }

    exit (0);
}

print "starting init $args\n";

# only start once when pid == 1
# ignore runlevel change requests
exit (0) if $$ != 1; 

if (! -d "/proc/$$") {
    system ("mount -t proc proc /proc") == 0 ||
	die "unable to mount proc filesystem\n";
}

system ("hostname localhost") == 0 ||
    die "unable to set hostname\n";


# start one child doing nothing - to avoid that we get killed
if (fork() == 0) {
    $0 = 'dummy child';
    for (;;) { sleep 5; }
    exit 0;
}

# provide simple syslog

my $sock =  IO::Socket::UNIX->new (Local => "/dev/log", Listen => 5) ||
    die "can't open socket /dev/log -  $!\n";

while ((my $fd = $sock->accept()) ||($! == EINTR)) {
    
    next if !$fd; # EINTR
	    
    while (defined (my $line = <$fd>)) {
	$line =~ s/\0/\n/g;
	chomp $line;
	$line =~ s/^<\d+>//mg;
	next if $line =~ m/^\s*$/;
	print "$line\n";
    }

    close ($fd);
}

print "exit init: $!\n";
exit (0);
