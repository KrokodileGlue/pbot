# File: FactoidCommands.pm
# Author: pragma_
#
# Purpose: Administrative command subroutines.

package PBot::FactoidCommands;

use warnings;
use strict;

use vars qw($VERSION);
$VERSION = $PBot::PBot::VERSION;

use Carp ();
use Time::Duration;
use Time::HiRes qw(gettimeofday);

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to FactoidCommands should be key/value pairs, not hash reference");
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
    Carp::croak("Missing pbot reference to FactoidCommands");
  }

  $self->{pbot} = $pbot;
  
  $pbot->commands->register(sub { return $self->factadd(@_)         },       "learn",        0);
  $pbot->commands->register(sub { return $self->factadd(@_)         },       "factadd",      0);
  $pbot->commands->register(sub { return $self->factrem(@_)         },       "forget",       0);
  $pbot->commands->register(sub { return $self->factrem(@_)         },       "factrem",      0);
  $pbot->commands->register(sub { return $self->factshow(@_)        },       "factshow",     0);
  $pbot->commands->register(sub { return $self->factinfo(@_)        },       "factinfo",     0);
  $pbot->commands->register(sub { return $self->factset(@_)         },       "factset",     10);
  $pbot->commands->register(sub { return $self->factunset(@_)       },       "factunset",   10);
  $pbot->commands->register(sub { return $self->factchange(@_)      },       "factchange",   0);
  $pbot->commands->register(sub { return $self->factalias(@_)       },       "factalias",    0);
  $pbot->commands->register(sub { return $self->call_factoid(@_)    },       "fact",         0);

  $pbot->commands->register(sub { return $self->list(@_)            },       "list",         0);
  $pbot->commands->register(sub { return $self->add_regex(@_)       },       "regex",        0);
  $pbot->commands->register(sub { return $self->histogram(@_)       },       "histogram",    0);
  $pbot->commands->register(sub { return $self->top20(@_)           },       "top20",        0);
  $pbot->commands->register(sub { return $self->count(@_)           },       "count",        0);
  $pbot->commands->register(sub { return $self->find(@_)            },       "find",         0);
  $pbot->commands->register(sub { return $self->load_module(@_)     },       "load",        50);
  $pbot->commands->register(sub { return $self->unload_module(@_)   },       "unload",      50);
  $pbot->commands->register(sub { return $self->enable_command(@_)  },       "enable",      10);
  $pbot->commands->register(sub { return $self->disable_command(@_) },       "disable",     10);
}

sub call_factoid {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my ($chan, $keyword, $args) = split / /, $arguments, 3;

  if(not defined $chan or not defined $keyword) {
    return "Usage: !fact <channel> <keyword> [arguments]";
  }

  my ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($chan, $keyword, $args, 1);

  if(not defined $trigger) {
    return "No such factoid '$keyword' exists for channel '$chan'";
  }

  return $self->{pbot}->factoids->interpreter($channel, $nick, $user, $host, 1, $trigger, $args);
}

sub factset {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my ($channel, $trigger, $key, $value) = split / /, $arguments, 4 if defined $arguments;

  if(not defined $channel or not defined $trigger) {
    return "Usage: factset <channel> <factoid> [key <value>]"
  }

  return $self->{pbot}->factoids->factoids->set($channel, $trigger, $key, $value);
}

sub factunset {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my ($channel, $trigger, $key) = split / /, $arguments, 3 if defined $arguments;

  if(not defined $channel or not defined $trigger) {
    return "Usage: factunset <channel> <factoid> <key>"
  }

  return $self->{pbot}->factoids->factoids->unset($channel, $trigger, $key);
}

sub list {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $botnick = $self->{pbot}->botnick;
  my $text;
  
  if(not defined $arguments) {
    return "/msg $nick Usage: list <modules|factoids|commands|admins>";
  }

  if($arguments =~/^messages\s+(.*)$/) {
    my ($nick_search, $channel_search, $text_search) = split / /, $1;

    return "/msg $nick Usage: !list messages <nick regex> <channel regex> [text regex]" if not defined $channel_search;
    $text_search = '.*' if not defined $text_search;

    my @results = eval {
      my @ret;
      foreach my $history_nick (keys %{ $self->{pbot}->antiflood->message_history }) {
        if($history_nick =~ m/$nick_search/i) {
          foreach my $history_channel (keys %{ $self->{pbot}->antiflood->message_history->{$history_nick} }) {
            next if $history_channel eq 'hostmask'; # TODO: move channels into {channel} subkey
            if($history_channel =~ m/$channel_search/i) {
              my @messages = @{ ${ $self->{pbot}->antiflood->message_history }{$history_nick}{$history_channel}{messages} };

              for(my $i = 0; $i <= $#messages; $i++) {
                next if $messages[$i]->{msg} =~ /^!login/;
                push @ret, { offenses => ${ $self->{pbot}->antiflood->message_history }{$history_nick}{$history_channel}{offenses}, join_watch => ${ $self->{pbot}->antiflood->message_history }{$history_nick}{$history_channel}{join_watch}, text => $messages[$i]->{msg}, timestamp => $messages[$i]->{timestamp}, nick => $history_nick, channel => $history_channel } if $messages[$i]->{msg} =~ m/$text_search/i;
              }
            }
          }
        }
      }
      return @ret;
    };

    if($@) {
      $self->{pbot}->logger->log("Error in search parameters: $@\n");
      return "Error in search parameters: $@";
    }

    my @sorted = sort { $a->{timestamp} <=> $b->{timestamp} } @results;
    foreach my $msg (@sorted) {
      $self->{pbot}->logger->log("[$msg->{channel}] " . localtime($msg->{timestamp}) . " [o: $msg->{offenses}, j: $msg->{join_watch}] <$msg->{nick}> " . $msg->{text} . "\n");
      $self->{pbot}->conn->privmsg($nick, "[$msg->{channel}] " . localtime($msg->{timestamp}) . " <$msg->{nick}> " . $msg->{text} . "\n") unless $nick =~ /\Q$botnick\E/i;
    }
    return "";
  }

  if($arguments =~ /^modules$/i) {
    $from = '.*' if not defined $from or $from !~ /^#/;
    $text = "Loaded modules for channel $from: ";
    foreach my $channel (sort keys %{ $self->{pbot}->factoids->factoids->hash }) {
      foreach my $command (sort keys %{ $self->{pbot}->factoids->factoids->hash->{$channel} }) {
        if($self->{pbot}->factoids->factoids->hash->{$channel}->{$command}->{type} eq 'module') {
          $text .= "$command ";
        }
      }
    }
    return $text;
  }

  if($arguments =~ /^commands$/i) {
    $text = "Registered commands: ";
    foreach my $command (sort { $a->{name} cmp $b->{name} } @{ $self->{pbot}->commands->{handlers} }) {
      $text .= "$command->{name} ";
      $text .= "($command->{level}) " if $command->{level} > 0;
    }
    return $text;
  }

  if($arguments =~ /^factoids$/i) {
    return "For a list of factoids see " . $self->{pbot}->factoids->export_site;
  }

  if($arguments =~ /^admins$/i) {
    $text = "Admins: ";
    my $last_channel = "";
    my $sep = "";
    foreach my $channel (sort keys %{ $self->{pbot}->admins->admins }) {
      if($last_channel ne $channel) {
        print "texzt: [$text], sep: [$sep]\n";
        $text .= $sep . "Channel " . ($channel eq ".*" ? "all" : $channel) . ": ";
        $last_channel = $channel;
        $sep = "";
      }
      foreach my $hostmask (sort keys %{ $self->{pbot}->admins->admins->{$channel} }) {
        $text .= $sep;
        $text .= "*" if exists ${ $self->{pbot}->admins->admins }{$channel}{$hostmask}{loggedin};
        $text .= ${ $self->{pbot}->admins->admins }{$channel}{$hostmask}{name} . " (" . ${ $self->{pbot}->admins->admins }{$channel}{$hostmask}{level} . ")";
        $sep = "; ";
      }
    }
    return $text;
  }
  return "/msg $nick Usage: list <modules|commands|factoids|admins>";
}

sub factalias {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my ($chan, $alias, $command) = split / /, $arguments, 3 if defined $arguments;
  
  if(not defined $command) {
    return "Usage: factalias <channel> <keyword> <command>";
  }

  my ($channel, $alias_trigger) = $self->{pbot}->factoids->find_factoid($chan, $alias, undef, 1);
  
  if(defined $alias_trigger) {
    $self->{pbot}->logger->log("attempt to overwrite existing command\n");
    return "/msg $nick '$alias_trigger' already exists for channel $channel";
  }
  
  $self->{pbot}->factoids->add_factoid('text', $chan, $nick, $alias, "/call $command");

  $self->{pbot}->logger->log("$nick!$user\@$host [$chan] aliased $alias => $command\n");
  $self->{pbot}->factoids->save_factoids();
  return "/msg $nick '$alias' aliases '$command' for channel $chan";  
}

sub add_regex {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids->hash;
  my ($keyword, $text) = $arguments =~ /^(.*?)\s+(.*)$/ if defined $arguments;

  $from = '.*' if not defined $from or $from !~ /^#/;

  if(not defined $keyword) {
    $text = "";
    foreach my $trigger (sort keys %{ $factoids->{$from} }) {
      if($factoids->{$from}->{$trigger}->{type} eq 'regex') {
        $text .= $trigger . " ";
      }
    }
    return "Stored regexs for channel $from: $text";
  }

  if(not defined $text) {
    return "Usage: regex <regex> <command>";
  }

  my ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($from, $keyword, undef, 1);

  if(defined $trigger) {
    $self->{pbot}->logger->log("$nick!$user\@$host attempt to overwrite $trigger\n");
    return "/msg $nick $trigger already exists for channel $channel.";
  }

  $self->{pbot}->factoids->add_factoid('regex', $from, $nick, $keyword, $text);
  $self->{pbot}->logger->log("$nick!$user\@$host added [$keyword] => [$text]\n");
  return "/msg $nick $keyword added.";
}

sub factadd {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my ($from_chan, $keyword, $text) = $arguments =~ /^(.*?)\s+(.*?)\s+is\s+(.*)$/i if defined $arguments;

  if(not defined $from_chan or not defined $text or not defined $keyword) {
    return "/msg $nick Usage: factadd <channel> <keyword> is <factoid>";
  }

  my ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($from_chan, $keyword, undef, 1);

  if(defined $trigger) {
    $self->{pbot}->logger->log("$nick!$user\@$host attempt to overwrite $keyword\n");
    return undef;
    return "/msg $nick $keyword already exists.";
  }

  $self->{pbot}->factoids->add_factoid('text', $from_chan, $nick, $keyword, $text);
  
  $self->{pbot}->logger->log("$nick!$user\@$host added $keyword => $text\n");
  return "/msg $nick '$keyword' added.";
}

sub factrem {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids->hash;

  my ($from_chan, $from_trigger) = split / /, $arguments;

  if(not defined $from_chan or not defined $from_trigger) {
    return "/msg $nick Usage: factrem <channel> <keyword>";
  }

  my ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($from_chan, $from_trigger, undef, 1);

  if(not defined $trigger) {
    return "/msg $nick $from_trigger not found in channel $from_chan.";
  }

  if($factoids->{$channel}->{$trigger}->{type} eq 'module') {
    $self->{pbot}->logger->log("$nick!$user\@$host attempted to remove $trigger [not factoid]\n");
    return "/msg $nick $trigger is not a factoid.";
  }

  if(($nick ne $factoids->{$channel}->{$trigger}->{owner}) and (not $self->{pbot}->admins->loggedin($from, "$nick!$user\@$host"))) {
    $self->{pbot}->logger->log("$nick!$user\@$host attempted to remove $trigger [not owner]\n");
    return "/msg $nick You are not the owner of '$trigger'";
  }

  $self->{pbot}->logger->log("$nick!$user\@$host removed [$channel][$trigger][" . $factoids->{$channel}->{$trigger}->{action} . "]\n");
  $self->{pbot}->factoids->remove_factoid($channel, $trigger);
  return "/msg $nick $trigger removed from channel $channel.";
}

sub histogram {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;
  my %hash;
  my $factoid_count = 0;

  foreach my $command (keys %{ $factoids }) {
    if(exists $factoids->{$command}{text}) {
      $hash{$factoids->{$command}{owner}}++;
      $factoid_count++;
    }
  }

  my $text;
  my $i = 0;

  foreach my $owner (sort {$hash{$b} <=> $hash{$a}} keys %hash) {
    my $percent = int($hash{$owner} / $factoid_count * 100);
    $percent = 1 if $percent == 0;
    $text .= "$owner: $hash{$owner} ($percent". "%) ";  
    $i++;
    last if $i >= 10;
  }
  return "$factoid_count factoids, top 10 submitters: $text";
}

sub factshow {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids->hash;

  my ($chan, $trig) = split / /, $arguments;

  if(not defined $chan or not defined $trig) {
    return "Usage: factshow <channel> <trigger>";
  }

  my ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($chan, $trig);

  if(not defined $trigger) {
    return "/msg $nick '$trig' not found in channel '$chan'";
  }

  if($factoids->{$channel}->{$trigger}->{type} eq 'module') {
    return "/msg $nick $trigger is not a factoid";
  }

  return "$trigger: " . $factoids->{$channel}->{$trigger}->{action};
}

sub factinfo {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids->hash;

  my ($chan, $trig) = split / /, $arguments;

  if(not defined $chan or not defined $trig) {
    return "Usage: factinfo <channel> <trigger>";
  }

  my ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($chan, $trig);

  if(not defined $trigger) {
    return "'$trig' not found in channel '$chan'";
  }

  my $created_ago = ago(gettimeofday - $factoids->{$channel}->{$trigger}->{created_on});
  my $ref_ago = ago(gettimeofday - $factoids->{$channel}->{$trigger}->{last_referenced_on}) if defined $factoids->{$channel}->{$trigger}->{last_referenced_on};

  $chan = ($channel eq '.*' ? 'all channels' : $channel);

  # factoid
  if($factoids->{$channel}->{$trigger}->{type} eq 'text') {
    return "$trigger: Factoid submitted by " . $factoids->{$channel}->{$trigger}->{owner} . " for $chan on " . localtime($factoids->{$channel}->{$trigger}->{created_on}) . " [$created_ago], referenced " . $factoids->{$channel}->{$trigger}->{ref_count} . " times (last by " . $factoids->{$channel}->{$trigger}->{ref_user} . (exists $factoids->{$channel}->{$trigger}->{last_referenced_on} ? " on " . localtime($factoids->{$channel}->{$trigger}->{last_referenced_on}) . " [$ref_ago]" : "") . ")"; 
  }

  # module
  if($factoids->{$channel}->{$trigger}->{type} eq 'module') {
    return "$trigger: Module loaded by " . $factoids->{$channel}->{$trigger}->{owner} . " for $chan on " . localtime($factoids->{$channel}->{$trigger}->{created_on}) . " [$created_ago] -> http://code.google.com/p/pbot2-pl/source/browse/trunk/modules/" . $factoids->{$channel}->{$trigger}->{action} . ", used " . $factoids->{$channel}->{$trigger}->{ref_count} . " times (last by " . $factoids->{$channel}->{$trigger}->{ref_user} . (exists $factoids->{$channel}->{$trigger}->{last_referenced_on} ? " on " . localtime($factoids->{$channel}->{$trigger}->{last_referenced_on}) . " [$ref_ago]" : "") . ")"; 
  }

  # regex
  if($factoids->{$channel}->{$trigger}->{type} eq 'regex') {
    return "$trigger: Regex created by " . $factoids->{$channel}->{$trigger}->{owner} . " for $chan on " . localtime($factoids->{$channel}->{$trigger}->{created_on}) . " [$created_ago], used " . $factoids->{$channel}->{$trigger}->{ref_count} . " times (last by " . $factoids->{$channel}->{$trigger}->{ref_user} . (exists $factoids->{$channel}->{$trigger}->{last_referenced_on} ? " on " . localtime($factoids->{$channel}->{$trigger}->{last_referenced_on}) . " [$ref_ago]" : "") . ")"; 
  }

  return "/msg $nick $trigger is not a factoid or a module";
}

sub top20 {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;
  my %hash = ();
  my $text = "";
  my $i = 0;

  if(not defined $arguments) {
    foreach my $command (sort {$factoids->{$b}{ref_count} <=> $factoids->{$a}{ref_count}} keys %{ $factoids }) {
      if($factoids->{$command}{ref_count} > 0 && exists $factoids->{$command}{text}) {
        $text .= "$command ($factoids->{$command}{ref_count}) ";
        $i++;
        last if $i >= 20;
      }
    }
    $text = "Top $i referenced factoids: $text" if $i > 0;
    return $text;
  } else {

    if(lc $arguments eq "recent") {
      foreach my $command (sort { $factoids->{$b}{created_on} <=> $factoids->{$a}{created_on} } keys %{ $factoids }) {
        #my ($seconds, $minutes, $hours, $day_of_month, $month, $year, $wday, $yday, $isdst) = localtime($factoids->{$command}{created_on});
        #my $t = sprintf("%04d/%02d/%02d", $year+1900, $month+1, $day_of_month);
                
        $text .= "$command ";
        $i++;
        last if $i >= 50;
      }
      $text = "$i most recent submissions: $text" if $i > 0;
      return $text;
    }

    my $user = lc $arguments;
    foreach my $command (sort keys %{ $factoids }) {
      if($factoids->{$command}{ref_user} =~ /\Q$arguments\E/i) {
        if($user ne lc $factoids->{$command}{ref_user} && not $user =~ /$factoids->{$command}{ref_user}/i) {
          $user .= " ($factoids->{$command}{ref_user})";
        }
        $text .= "$command ";
        $i++;
        last if $i >= 20;
      }
    }
    $text = "$i factoids last referenced by $user: $text" if $i > 0;
    return $text;
  }
}

sub count {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;
  my $i = 0;
  my $total = 0;

  if(not defined $arguments) {
    return "/msg $nick Usage:  count <nick|factoids>";
  }

  $arguments = ".*" if($arguments =~ /^factoids$/);

  eval {
    foreach my $command (keys %{ $factoids }) {
      $total++ if exists $factoids->{$command}{text};
      my $regex = qr/^\Q$arguments\E$/;
      if($factoids->{$command}{owner} =~ /$regex/i && exists $factoids->{$command}{text}) {
        $i++;
      }
    }
  };
  return "/msg $nick $arguments: $@" if $@;

  return "I have $i factoids" if($arguments eq ".*");

  if($i > 0) {
    my $percent = int($i / $total * 100);
    $percent = 1 if $percent == 0;
    return "$arguments has submitted $i factoids out of $total ($percent"."%)";
  } else {
    return "$arguments hasn't submitted any factoids";
  }
}

sub find {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;
  my $text;
  my $type;



  if(not defined $arguments) {
    return "/msg $nick Usage: !find [-owner nick] [-by nick] [text]";
  }

  my ($owner, $by);

  $owner = $1 if $arguments =~ s/-owner\s+([^\b\s]+)//i;
  $by = $1 if $arguments =~ s/-by\s+([^\b\s]+)//i;

  $owner = '.*' if not defined $owner;
  $by = '.*' if not defined $by;

  $arguments =~ s/^\s+//;
  $arguments =~ s/\s+$//;
  $arguments =~ s/\s+/ /g;

  my $argtype = undef;

  if($owner ne '.*') {
    $argtype = "owned by $owner";
  }

  if($by ne '.*') {
    if(not defined $argtype) {
      $argtype = "last referenced by $by";
    } else {
      $argtype .= " and last referenced by $by";
    }
  }

  if($arguments ne "") {
    if(not defined $argtype) {
      $argtype = "with text matching '$arguments'";
    } else {
      $argtype .= " and with text matching '$arguments'";
    }
  }

  if(not defined $argtype) {
    return "/msg $nick Usage: !find [-owner nick] [-by nick] [text]";
  }

  my $i = 0;
  eval {
    foreach my $command (sort keys %{ $factoids }) {
      if(exists $factoids->{$command}{text} || exists $factoids->{$command}{regex}) {
        $type = 'text' if(exists $factoids->{$command}{text});
        $type = 'regex' if(exists $factoids->{$command}{regex});

        if($factoids->{$command}{owner} =~ /$owner/i && $factoids->{$command}{ref_user} =~ /$by/i) {
          next if($arguments ne "" && $factoids->{$command}{$type} !~ /$arguments/i && $command !~ /$arguments/i);
          $i++;
          $text .= "$command ";
        }
      }
    }
  };

  return "/msg $nick $arguments: $@" if $@;

  if($i == 1) {
    chop $text;
    $type = 'text' if exists $factoids->{$text}{text};
    $type = 'regex' if exists $factoids->{$text}{regex};
    return "found one factoid " . $argtype . ": '$text' is '$factoids->{$text}{$type}'";
  } else {
    return "$i factoids " . $argtype . ": $text" unless $i == 0;
    return "No factoids " . $argtype;
  }
}

sub factchange {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids->hash;
  my ($channel, $trigger, $keyword, $delim, $tochange, $changeto, $modifier);

  if(defined $arguments) {
    if($arguments =~ /^([^\s]+) ([^\s]+)\s+s(.)/) {
      $channel = $1;
      $keyword = $2; 
      $delim = $3;
    }
    
    if($arguments =~ /$delim(.*?)$delim(.*)$delim(.*)?$/) {
      $tochange = $1; 
      $changeto = $2;
      $modifier  = $3;
    }
  }

  if(not defined $channel or not defined $changeto) {
    return "/msg $nick Usage: factchange <channel> <keyword> s/<pattern>/<replacement>/";
  }

  ($channel, $trigger) = $self->{pbot}->factoids->find_factoid($channel, $keyword);

  if(not defined $trigger) {
    return "/msg $nick $keyword not found in channel $from.";
  }

  my $ret = eval {
    if(not $factoids->{$channel}->{$trigger}->{action} =~ s|$tochange|$changeto|) {
      $self->{pbot}->logger->log("($from) $nick!$user\@$host: failed to change '$trigger' 's$delim$tochange$delim$changeto$delim\n");
      return "/msg $nick Change $trigger failed.";
    } else {
      $self->{pbot}->logger->log("($from) $nick!$user\@$host: changed '$trigger' 's/$tochange/$changeto/\n");
      $self->{pbot}->factoids->save_factoids();
      return "Changed: $trigger is " . $factoids->{$channel}->{$trigger}->{action};
    }
  };
  return "/msg $nick Change $trigger: $@" if $@;
  return $ret;
}

sub load_module {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;
  my ($keyword, $module) = $arguments =~ /^(.*?)\s+(.*)$/ if defined $arguments;

  if(not defined $module) {
    return "/msg $nick Usage: load <command> <module>";
  }

  if(not exists($factoids->{$keyword})) {
    $factoids->{$keyword}{module} = $module;
    $factoids->{$keyword}{enabled} = 1;
    $factoids->{$keyword}{owner} = $nick;
    $factoids->{$keyword}{created_on} = time();
    $self->{pbot}->logger->log("$nick!$user\@$host loaded $keyword => $module\n");
    $self->{pbot}->factoids->save_factoids();
    return "/msg $nick Loaded $keyword => $module";
  } else {
    return "/msg $nick There is already a command named $keyword.";
  }
}

sub unload_module {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;

  if(not defined $arguments) {
    return "/msg $nick Usage: unload <module>";
  } elsif(not exists $factoids->{$arguments}) {
    return "/msg $nick $arguments not found.";
  } elsif(not exists $factoids->{$arguments}{module}) {
    return "/msg $nick $arguments is not a module.";
  } else {
    delete $factoids->{$arguments};
    $self->{pbot}->factoids->save_factoids();
    $self->{pbot}->logger->log("$nick!$user\@$host unloaded module $arguments\n");
    return "/msg $nick $arguments unloaded.";
  } 
}

sub enable_command {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;
  
  if(not defined $arguments) {
    return "/msg $nick Usage: enable <command>";
  } elsif(not exists $factoids->{$arguments}) {
    return "/msg $nick $arguments not found.";
  } else {
    $factoids->{$arguments}{enabled} = 1;
    $self->{pbot}->factoids->save_factoids();
    $self->{pbot}->logger->log("$nick!$user\@$host enabled $arguments\n");
    return "/msg $nick $arguments enabled.";
  }   
}

sub disable_command {
  my $self = shift;
  my ($from, $nick, $user, $host, $arguments) = @_;
  my $factoids = $self->{pbot}->factoids->factoids;

  if(not defined $arguments) {
    return "/msg $nick Usage: disable <command>";
  } elsif(not exists $factoids->{$arguments}) {
    return "/msg $nick $arguments not found.";
  } else {
    $factoids->{$arguments}{enabled} = 0;
    $self->{pbot}->factoids->save_factoids();
    $self->{pbot}->logger->log("$nick!$user\@$host disabled $arguments\n");
    return "/msg $nick $arguments disabled.";
  }   
}

1;
