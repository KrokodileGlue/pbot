# File: IgnoreList.pm
# Author: pragma_
#
# Purpose: Manages ignore list.

package PBot::IgnoreList;

use warnings;
use strict;

use vars qw($VERSION);
$VERSION = $PBot::PBot::VERSION;

use Time::HiRes qw(gettimeofday);

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to Commands should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;

  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;

  my $pbot = delete $conf{pbot};
  if(not defined $pbot) {
    Carp::croak("Missing pbot reference to Channels");
  }

  my $filename = delete $conf{filename};

  $self->{pbot} = $pbot;
  $self->{ignore_list} = {};
  $self->{ignore_flood_counter} = 0;
  $self->{last_timestamp} = gettimeofday;
  $self->{filename} = $filename;

  $pbot->timer->register(sub { $self->check_ignore_timeouts }, 10);
}

sub add {
  my $self = shift;
  my ($hostmask, $channel, $length) = @_;

  if($length == -1) {
    ${ $self->{ignore_list} }{$hostmask}{$channel} = -1;
  } else {
    ${ $self->{ignore_list} }{$hostmask}{$channel} = gettimeofday + $length;
  }

  $self->save_ignores();
}

sub remove {
  my $self = shift;
  my ($hostmask, $channel) = @_;

  delete ${ $self->{ignore_list} }{$hostmask}{$channel};
  $self->save_ignores();
}

sub load_ignores {
  my $self = shift;
  my $filename;

  if(@_) { $filename = shift; } else { $filename = $self->{filename}; }

  if(not defined $filename) {
    Carp::carp "No ignorelist path specified -- skipping loading of ignorelist";
    return;
  }

  $self->{pbot}->logger->log("Loading ignorelist from $filename ...\n");
  
  open(FILE, "< $filename") or Carp::croak "Couldn't open $filename: $!\n";
  my @contents = <FILE>;
  close(FILE);

  my $i = 0;

  foreach my $line (@contents) {
    chomp $line;
    $i++;

    my ($hostmask, $channel, $length) = split(/\s+/, $line);
    
    if(not defined $hostmask || not defined $channel || not defined $length) {
         Carp::croak "Syntax error around line $i of $filename\n";
    }
    
    if(exists ${ $self->{ignore_list} }{$hostmask}{$channel}) {
      Carp::croak "Duplicate ignore [$hostmask][$channel] found in $filename around line $i\n";
    }

    ${ $self->{ignore_list} }{$hostmask}{$channel} = gettimeofday + $length;
  }

  $self->{pbot}->logger->log("  $i entries in ignorelist\n");
  $self->{pbot}->logger->log("Done.\n");
}

sub save_ignores {
  my $self = shift;
  my $filename;

  if(@_) { $filename = shift; } else { $filename = $self->{filename}; }

  if(not defined $filename) {
    Carp::carp "No ignorelist path specified -- skipping saving of ignorelist\n";
    return;
  }

  open(FILE, "> $filename") or die "Couldn't open $filename: $!\n";

  foreach my $ignored (keys %{ $self->{ignore_list} }) {
    foreach my $ignored_channel (keys %{ ${ $self->{ignore_list} }{$ignored} }) {
      my $length = $self->{ignore_list}->{$ignored}{$ignored_channel};
      $length = int($length - gettimeofday) unless $length == -1;
      print FILE "$ignored $ignored_channel $length\n";
    }
  }

  close(FILE);
}

sub check_ignore {
  my $self = shift;
  my ($nick, $user, $host, $channel) = @_;
  my $pbot = $self->{pbot};
  $channel = lc $channel;

  my $hostmask = "$nick!$user\@$host"; 

  my $now = gettimeofday;

  if(defined $channel) { # do not execute following if text is coming from STDIN ($channel undef)
    if($channel =~ /^#/) {
      $self->{ignore_flood_counter}++;  # TODO: make this per channel, e.g., ${ $self->{ignore_flood_counter} }{$channel}++
      $pbot->logger->log("flood_msg: $self->{ignore_flood_counter}\n");
    }

    if($now - $self->{last_timestamp} >= 30) {
      $self->{last_timestamp} = $now;
      if($self->{ignore_flood_counter} > 0) {
        $self->{ignore_flood_counter}--;
        $pbot->logger->log("flood_msg decremented to $self->{ignore_flood_counter}\n");
      }
    }

    if(($self->{ignore_flood_counter} > 4) or ($channel =~ /^#osdev$/i and $self->{ignore_flood_counter} >= 3)) {
      $pbot->logger->log("flood_msg exceeded! [$self->{ignore_flood_counter}]\n");
      $self->{pbot}->{ignorelistcmds}->ignore_user("", "floodcontrol", "", "", ".* $channel 600");
      $self->{ignore_flood_counter} = 0;
      if($channel =~ /^#/) {
        $pbot->conn->me($channel, "has been overwhelmed.");
        $pbot->conn->me($channel, "lies down and falls asleep."); 
        return;
      } 
    }
  }

  foreach my $ignored (keys %{ $self->{ignore_list} }) {
    foreach my $ignored_channel (keys %{ ${ $self->{ignore_list} }{$ignored} }) {
      #$self->{pbot}->logger->log("check_ignore: comparing '$hostmask' against '$ignored' for channel '$channel'\n");
      if(($channel =~ /$ignored_channel/i) && ($hostmask =~ /$ignored/i)) {
        $self->{pbot}->logger->log("$nick!$user\@$host message ignored in channel $channel (matches [$ignored] host and [$ignored_channel] channel)\n");
        return 1;
      }
    }
  }
  return 0;
}

sub check_ignore_timeouts {
  my $self = shift;
  my $now = gettimeofday();

  foreach my $hostmask (keys %{ $self->{ignore_list} }) {
    foreach my $channel (keys %{ $self->{ignore_list}->{$hostmask} }) {
      next if($self->{ignore_list}->{$hostmask}{$channel} == -1); #permanent ignore

      if($self->{ignore_list}->{$hostmask}{$channel} < $now) {
        $self->{pbot}->{ignorelistcmds}->unignore_user("", "floodcontrol", "", "", "$hostmask $channel");
        if($hostmask eq ".*") {
          $self->{pbot}->conn->me($channel, "awakens.");
        }
      } else {
        #my $timediff = $ignore_list{$host}{$channel} - $now;
        #$logger->log "ignore: $host has $timediff seconds remaining\n"
      }
    }
  }
}

1;
