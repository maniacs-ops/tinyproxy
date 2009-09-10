#!/usr/bin/perl -w

# Simple WEB server.
#
# Inspired by some examples from the perlipc and other perl manual pages.
#
# Copyright (C) 2009 Michael Adam
#
# License: GPL

use strict;

use IO::Socket;
use IO::Select;
use Carp;
use POSIX qw(setsid :sys_wait_h);
use Errno;
use Getopt::Long;
use Pod::Usage;
use Fcntl ':flock'; # import LOCK_* constants

my $EOL = "\015\012";

my $port = 2345;
my $proto = getprotobyname('tcp');
my $pid_file = "./webserver.pid";
my $log_dir = "./";
my $access_log_file;
my $error_log_file;
my $document_root = "./";
my $help = 0;

sub create_child($$$);

sub logmsg {
	print STDERR "[", scalar localtime, ", $$] $0: @_\n";
}

sub start_server($$) {
	my $proto = shift;
	my $port = shift;
	my $server;

	$server = IO::Socket::INET->new(Proto => $proto,
					LocalPort => $port,
					Listen => SOMAXCONN,
					Reuse => 1);

	logmsg "server started listening on port $port";

	return $server;
}

sub REAPER {
	local $!;   # don't let waitpid() overwrite current error

	while ((my $pid = waitpid(-1,WNOHANG)) > 0 && WIFEXITED($?)) {
		logmsg "reaped $pid" . ($? ? " with exit code $?" : '');
	}

	$SIG{CHLD} = \&REAPER;
}

sub child_action($) {
	my $client = shift;
	my $client_ip = shift;

	logmsg "client_action: client $client_ip";

	$client->autoflush();

	my $fortune_bin = "/usr/games/fortune";
	my $fortune = "";
	if ( -x $fortune_bin) {
		$fortune = qx(/usr/games/fortune);
		$fortune =~ s/\n/$EOL/g;
	}

	my $request = "";
	while (my $request_line = <$client>) {
		$request .= $request_line;
		last if ($request_line eq $EOL);
	}

	logmsg  "request:\n" .
		"------------------------------\n" .
		"$request" .
		"------------------------------";

	print $client "HTTP/1.0 200 OK$EOL";
	print $client "Server:  Tinyproxy Test Web Server$EOL";
	print $client "Content-Type: text/html$EOL";
	print $client "$EOL";
	print $client "<html>$EOL";
	print $client "<h1>Tinyproxy test WEB server</h1>$EOL";
	print $client "<h2>Fortune</h2>$EOL";
	if ($fortune) {
		print $client "<pre>$fortune</pre>$EOL";
	} else {
		print $client "Sorry, no $fortune_bin not found.$EOL";
	}
	print $client "<h2>Your request:</h2>$EOL";
	print $client "<pre>$request<pre>$EOL";
	print $client "</html>$EOL";

	close $client;

	return 0;
}

sub create_child($$$) {
	my $client = shift;
	my $action = shift;
	my $client_ip = shift;

	unless (@_ == 0 && $action && ref($action) eq 'CODE') {
	    confess "internal error. create_child needs code reference as argument";
	}

	my $pid = fork();
	if (not defined($pid)) {
		# error
		logmsg "cannot fork: $!";
		return;
	} elsif ($pid) {
		# parent
		logmsg "child process created with pid $pid";
		return;
	} else {
		# child
		exit &$action($client, $client_ip);
	}
}

sub process_options() {
	my $result = GetOptions("help|?" => \$help,
				"port=s" => \$port,
				"pid-file=s" => \$pid_file,
				"log-dir=s" => \$log_dir,
				"root|document-root=s" => \$document_root);
	die "Error reading cmdline options! $!" unless $result;

	pod2usage(1) if $help;

	# some post-processing:

	($port) = $port =~ /^(\d+)$/ or die "invalid port";
	$access_log_file = "$log_dir/webserver.access_log";
	$error_log_file = "$log_dir/webserver.error_log";
}

sub daemonize() {
	umask 0;
	chdir "/" or die "daemonize: can't chdir to /: $!";
	open STDIN, "/dev/null" or
		die "daemonize: Can't read from /dev/null: $!";

	my $pid = fork();
	die "daemonize: can't fork: $!" if not defined($pid);
	exit(0) if $pid != 0; # parent

	# child (daemon)
	setsid or die "damonize: Can't create a new session: $!";
}

sub reopen_logs() {
	open STDOUT, ">> $access_log_file" or
		die "daemonize: Can't write to '$access_log_file': $!";
	open STDERR, ">> $error_log_file" or
		die "daemonize: Can't write to '$error_log_file': $!";
}

sub get_pid_lock() {
	open LOCKFILE, "> $pid_file" or
		die "Error opening pid-file $pid_file: $!";
	unless (flock(LOCKFILE, LOCK_EX|LOCK_NB)) {
		my $other_pid = qx(cat $pid_file);
		print "Webserver is already running (pid $other_pid)";
		exit(0);
	}

	print LOCKFILE "$$";
}

sub release_pid_lock() {
	flock(LOCKFILE, LOCK_UN);
	close LOCKFILE;
}

# "main" ...

$|=1; # autoflush

process_options();

daemonize();
get_pid_lock();
reopen_logs();

$SIG{CHLD} = \&REAPER;

my $server = start_server($proto, $port);
my $slct = IO::Select->new($server);

while (1) {
	my @ready_for_reading = $slct->can_read();
	foreach my $fh (@ready_for_reading) {
		if ($fh != $server) {
			logmsg "select: fh ready for reading but not server",
				"don't know what to do...";
		}

		# new connection:
		my $client = $server->accept() or do {
			# try again if accept() returned because
			# a signal was received
			if ($!{EINTR}) {
				logmsg "accept: got signal EINTR ...";
				next;
			}
			die "accept: $!";
		};
		my $client_ip = inet_ntoa($client->peeraddr);
		logmsg "connection from $client_ip at port " . $client->peerport;
		create_child($client, \&child_action, $client_ip);
		close $client;
	}
}

# never reached...
logmsg "Server done - ooops!\n";

release_pid_lock();

exit(0);

__END__

=head1 webserver.pl

A simple WEB server written in perl.

=head1 SYNOPSIS

webserver.pl [options]

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exit.

=item B<--port>

Specify the port number for the server to listen on.

=item B<--root|--document-root>

Specify the document root directory from which to serve web content.

=item B<--log-dir>

Specify the directory where the log files should be stored.

=item B<--pid-file>

Specify the location of the  pid lock file.

=back

=head1 DESCRIPTION

This is a very simple web server. It currently does not deliver the specific web
page requested, but constructs the same kind of answer for each request, citing
a fortune if fortune is available, and printing the originating request.

=cut
