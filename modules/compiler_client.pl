#!/usr/bin/perl

# compiler_client.pl connects to compiler_server.pl hosted at PeerAddr/PeerPort below
# and sends a nick, language and code, then retreives and prints the compilation/execution output.
#
# this way we can run the compiler virtual machine on any remote server.

use warnings;
use strict;

use IO::Socket;

my $sock = IO::Socket::INET->new(
  PeerAddr => '127.0.0.1', 
  PeerPort => 9000, 
  Proto => 'tcp');

if(not defined $sock) {
  print "Fatal error compiling: $!; try the !cc2 command instead\n";
  die $!;
}

my $nick = shift @ARGV;
my $code = join ' ', @ARGV;

my $lang = "C99";

if($code =~ s/-lang=([^ ]+)//) {
  $lang = uc $1;
}

print $sock "compile:$nick:$lang\n";
print $sock "$code\n";
print $sock "compile:end\n";

while(my $line = <$sock>) {
  print "$line";
}

close $sock;
