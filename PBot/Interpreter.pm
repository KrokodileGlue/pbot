# File: Interpreter.pm
# Author: pragma_
#
# Purpose: 

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package PBot::Interpreter;

use warnings;
use strict;

use base 'PBot::Registerable';

use Time::HiRes qw/gettimeofday/;
use Time::Duration;
use Text::Balanced qw/extract_bracketed extract_quotelike/;
use Carp ();

use PBot::Utils::ValidateString;

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to " . __FILE__ . " should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;
  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;

  $self->SUPER::initialize(%conf);

  $self->{pbot} = delete $conf{pbot} // Carp::croak("Missing pbot reference to " . __FILE__);

  $self->{pbot}->{registry}->add_default('text',  'general', 'compile_blocks',                  $conf{compile_blocks}                  // 1);
  $self->{pbot}->{registry}->add_default('array', 'general', 'compile_blocks_channels',         $conf{compile_blocks_channels}         // '.*');
  $self->{pbot}->{registry}->add_default('array', 'general', 'compile_blocks_ignore_channels',  $conf{compile_blocks_ignore_channels}  // 'none');
  $self->{pbot}->{registry}->add_default('text',  'interpreter', 'max_recursion',  10);

  $self->{output_queue}  = {};
  $self->{command_queue} = {};

  $self->{pbot}->{timer}->register(sub { $self->process_output_queue  }, 1);
  $self->{pbot}->{timer}->register(sub { $self->process_command_queue }, 1);
}

sub process_line {
  my $self = shift;
  my ($from, $nick, $user, $host, $text) = @_;
  $from = lc $from if defined $from;

  my $stuff = { from => $from, nick => $nick, user => $user, host => $host, text => $text };
  my $pbot = $self->{pbot};

  my $message_account = $pbot->{messagehistory}->get_message_account($nick, $user, $host);
  $pbot->{messagehistory}->add_message($message_account, "$nick!$user\@$host", $from, $text, $pbot->{messagehistory}->{MSG_CHAT});
  $stuff->{message_account} = $message_account;

  my $flood_threshold      = $pbot->{registry}->get_value($from, 'chat_flood_threshold');
  my $flood_time_threshold = $pbot->{registry}->get_value($from, 'chat_flood_time_threshold');

  $flood_threshold      = $pbot->{registry}->get_value('antiflood', 'chat_flood_threshold')      if not defined $flood_threshold;
  $flood_time_threshold = $pbot->{registry}->get_value('antiflood', 'chat_flood_time_threshold') if not defined $flood_time_threshold;

  $pbot->{antiflood}->check_flood($from, $nick, $user, $host, $text,
    $flood_threshold, $flood_time_threshold,
    $pbot->{messagehistory}->{MSG_CHAT}) if defined $from;

  if (defined $from and $from =~ m/^#/) {
    my $chanmodes = $self->{pbot}->{channels}->get_meta($from, 'MODE');
    if (defined $chanmodes and $chanmodes =~ m/z/) {
      if ($self->{pbot}->{bantracker}->is_banned($nick, $user, $host, $from)) {
        $self->{pbot}->{logger}->log("Disregarding banned user message (channel $from is +z).\n");
        return 1;
      }
    }
  }

  my $botnick = $self->{pbot}->{registry}->get_value('irc', 'botnick');

  # get channel-specific trigger if available
  my $bot_trigger = $pbot->{registry}->get_value($from, 'trigger');

  # otherwise get general trigger
  if (not defined $bot_trigger) {
    $bot_trigger = $pbot->{registry}->get_value('general', 'trigger');
  }

  my $nick_regex = qr/[^%!,:\(\)\+\*\/ ]+/;

  my $nick_override;
  my $processed = 0;
  my $preserve_whitespace = 0;

  $text =~ s/^\s+//;
  $text =~ s/\s+$//;
  $text = validate_string($text, 0);

  my $cmd_text = $text;
  $cmd_text =~ s/^\/me\s+//;

  # check for bot command invocation
  my @commands;
  my $command;
  my $embedded = 0;

  if ($cmd_text =~ m/^\s*($nick_regex)[,:]?\s+$bot_trigger\{\s*(.+?)\s*\}\s*$/) {
    goto CHECK_EMBEDDED_CMD;
  } elsif ($cmd_text =~ m/^\s*$bot_trigger\{\s*(.+?)\s*\}\s*$/) {
    goto CHECK_EMBEDDED_CMD;
  } elsif ($cmd_text =~ m/^\s*($nick_regex)[,:]\s+$bot_trigger\s*(.+)$/) {
    my $possible_nick_override = $1;
    $command = $2;

    my $similar = $self->{pbot}->{nicklist}->is_present_similar($from, $possible_nick_override);
    if ($similar) {
      $nick_override = $similar;
    } else {
      $self->{pbot}->{logger}->log("No similar nick for $possible_nick_override\n");
      return 0;
    }
  } elsif ($cmd_text =~ m/^$bot_trigger\s*(.+)$/) {
    $command = $1;
  } elsif ($cmd_text =~ m/^.?$botnick.?\s*(.+)$/i) {
    $command = $1;
  } elsif ($cmd_text =~ m/^(.+?),?\s*$botnick[?!.]*$/i) {
    $command = $1;
  }

  # check for embedded commands
  CHECK_EMBEDDED_CMD:
  if (not defined $command or $command =~ m/^\{.*\}/) {
    if ($cmd_text =~ s/^\s*($nick_regex)[,:]\s+//) {
      my $possible_nick_override = $1;
      my $similar = $self->{pbot}->{nicklist}->is_present_similar($from, $possible_nick_override);
      if ($similar) {
        $nick_override = $similar;
      }
    }

    for (my $count = 0; $count < 3; $count++) {
      my ($extracted) = extract_bracketed $cmd_text, '{"\'}', "(?s).*?$bot_trigger(?=\{)";
      last if not defined $extracted;
      $extracted =~ s/^\{\s*//;
      $extracted =~ s/\s*\}$//;
      push @commands, $extracted;
      $embedded = 1;
    }
  } else {
    push @commands, $command;
  }

  foreach $command (@commands) {
    # check if user is ignored (and command isn't `login`)
    if ($command !~ /^login / && defined $from && $pbot->{ignorelist}->check_ignore($nick, $user, $host, $from)) {
      my $admin = $pbot->{admins}->loggedin($from, "$nick!$user\@$host");
      if (!defined $admin || $admin->{level} < 10) {
        # hostmask ignored
        return 1;
      }
    }

    $stuff->{text} = $text;
    $stuff->{command} = $command;
    $stuff->{nickoverride} = $nick_override if $nick_override;
    $stuff->{force_nickoverride} = 1 if $nick_override;
    $stuff->{referenced} = $embedded;
    $stuff->{interpret_depth} = 1;
    $stuff->{preserve_whitespace} = $preserve_whitespace;

    $stuff->{result} = $self->interpret($stuff);
    $self->handle_result($stuff);
    $processed++;
  }
  return $processed;
}

sub interpret {
  my ($self, $stuff) = @_;
  my ($keyword, $arguments) = ("", "");
  my $text;
  my $pbot = $self->{pbot};

  $pbot->{logger}->log("=== Enter interpret_command: [" . (defined $stuff->{from} ? $stuff->{from} : "(undef)") . "][$stuff->{nick}!$stuff->{user}\@$stuff->{host}][$stuff->{interpret_depth}][$stuff->{command}]\n");

  $stuff->{special} = "";

  if ($self->{pbot}->{registry}->get_value('general', 'debugcontext')) {
    use Data::Dumper;
    $Data::Dumper::Sortkeys  = 1;
    $self->{pbot}->{logger}->log("Interpreter::interpret\n");
    $self->{pbot}->{logger}->log(Dumper $stuff);
  }

  return "Too many levels of recursion, aborted." if(++$stuff->{interpret_depth} > $self->{pbot}->{registry}->get_value('interpreter', 'max_recursion'));

  if (not defined $stuff->{nick} || not defined $stuff->{user} || not defined $stuff->{host} || not defined $stuff->{command}) {
    $pbot->{logger}->log("Error 1, bad parameters to interpret_command\n");
    return undef;
  }

  my $cmdlist = $self->make_args($stuff->{command});
  if ($self->arglist_size($cmdlist) >= 4 and lc $cmdlist->[0] eq 'tell' and lc $cmdlist->[2] eq 'about') {
    # tell nick about cmd [args]
    $stuff->{nickoverride} = $cmdlist->[1];
    ($keyword, $arguments) = $self->split_args($cmdlist, 2, 3);
    $arguments = '' if not defined $arguments;
    my $similar = $self->{pbot}->{nicklist}->is_present_similar($stuff->{from}, $stuff->{nickoverride});
    if ($similar) {
      $stuff->{nickoverride} = $similar;
      $stuff->{force_nickoverride} = 1;
    } else {
      delete $stuff->{nickoverride};
      delete $stuff->{force_nickoverride};
    }
  } else {
    # normal command
    ($keyword, $arguments) = $self->split_args($cmdlist, 2);
    $arguments = "" if not defined $arguments;
  }

  # FIXME: make this a registry item
  if (length $keyword > 128) {
    $keyword = substr($keyword, 0, 128);
    $self->{pbot}->{logger}->log("Truncating keyword to 128 chars: $keyword\n");
  }

  # parse out a substituted command
  if (defined $arguments && $arguments =~ m/(?<!\\)&\{/) {
    my ($command) = extract_bracketed $arguments, '{"\'}', '(?s).*?(?<!\\\\)&';

    if (defined $command) {
      $arguments =~ s/&\Q$command\E/&{subcmd}/;

      $command =~ s/^\{\s*//;
      $command =~ s/\s*\}$//;

      push @{$stuff->{subcmd}}, "$keyword $arguments";
      $stuff->{command} = $command;
      $stuff->{result} = $self->interpret($stuff);
      return $stuff->{result};
    }
  }

  # parse out a pipe
  if (defined $arguments && $arguments =~ m/(?<!\\)\|\s*\{\s*[^}]+\}\s*$/) {
    my ($pipe, $rest, $args) = extract_bracketed $arguments, '{"\'}', '(?s).*?(?<!\\\\)\|\s*';

    $pipe =~ s/^\{\s*//;
    $pipe =~ s/\s*\}$//;
    $args =~ s/\s*(?<!\\)\|\s*//;

    $self->{pbot}->{logger}->log("piping: [$args][$pipe][$rest]\n");

    $arguments = $args;

    if (exists $stuff->{pipe}) {
      $stuff->{pipe_rest} = "$rest | { $stuff->{pipe} }$stuff->{pipe_rest}";
    } else {
      $stuff->{pipe_rest} = $rest;
    }
    $stuff->{pipe} = $pipe;
  }

  $stuff->{nickoverride} = $stuff->{nick} if defined $stuff->{nickoverride} and lc $stuff->{nickoverride} eq 'me';

  if ($keyword !~ /^(?:factrem|forget|set|factdel|factadd|add|factfind|find|factshow|show|forget|factdel|factset|factchange|change|msg|tell|cc|eval|u|udict|ud|actiontrigger|urban|perl|ban|mute|spinach|choose|c|lie|l|adminadd|unmute|unban)$/) {
    $keyword =~ s/(\w+)([?!.]+)$/$1/;
    $arguments =~ s/(?<![\w\/\-\\])i am\b/$stuff->{nick} is/gi if defined $arguments && $stuff->{interpret_depth} <= 2;
    $arguments =~ s/(?<![\w\/\-\\])me\b/$stuff->{nick}/gi if defined $arguments && $stuff->{interpret_depth} <= 2;
    $arguments =~ s/(?<![\w\/\-\\])my\b/$stuff->{nick}'s/gi if defined $arguments && $stuff->{interpret_depth} <= 2;
    $arguments =~ s/\\my\b/my/gi if defined $arguments && $stuff->{interpret_depth} <= 2;
    $arguments =~ s/\\me\b/me/gi if defined $arguments && $stuff->{interpret_depth} <= 2;
    $arguments =~ s/\\i am\b/i am/gi if defined $arguments && $stuff->{interpret_depth} <= 2;

    my $botnick = $self->{pbot}->{registry}->get_value('irc', 'botnick');

    if (defined $arguments && ($arguments =~ m/^(your|him|her|its|it|them|their)(self|selves)$/i || $arguments =~ m/^$botnick$/i)) {
      my $delay = (rand 10) + 8;
      my $message = {
        nick => $stuff->{nick}, user => $stuff->{user}, host => $stuff->{host}, command => $stuff->{command}, checkflood => 1,
        message => "$stuff->{nick}: Why would I want to do that to myself?"
      };
      $self->add_message_to_output_queue($stuff->{from}, $message, $delay);
      $delay = duration($delay);
      $self->{pbot}->{logger}->log("Final result ($delay delay) [$message->{message}]\n");
      return undef;
    }
  }

  if(not defined $keyword) {
    $pbot->{logger}->log("Error 2, no keyword\n");
    return undef;
  }

  if (not exists $stuff->{root_keyword}) {
    $stuff->{root_keyword} = $keyword;
  }

  $stuff->{keyword} = $keyword;
  $stuff->{original_arguments} = $arguments;

  # unescape any escaped substituted commands
  $arguments =~ s/\\&\{/&{/g if defined $arguments;

  # unescape any escaped pipes
  $arguments =~ s/\\\|\s*\{/| {/g if defined $arguments;

  $arguments = validate_string($arguments);

  # set arguments as a plain string
  $stuff->{arguments} = $arguments;

  # set arguments as an array
  $stuff->{arglist} = $self->make_args($arguments);

  # handle this shit
  return $self->SUPER::execute_all($stuff);
}

# creates an array of arguments from a string
sub make_args {
  my ($self, $string) = @_;

  my @args = split / /, $string;
  my @arglist;
  my @arglist_quotes;

  while (@args) {
    my $arg = shift @args;

    # is this a quoted argument?
    if ($arg =~ /^["']/) {
      my $string = $arg;
      if (@args) {
        $string .= ' ';
        $string .= join(' ', @args);
      }
      my ($extracted, $rest) = extract_quotelike $string;
      if (defined $extracted) {
        # preserve quotes for $rest in split_args()
        push @arglist_quotes, $extracted;

        # strip quote characters
        $extracted =~ s/^(.)//;
        $extracted =~ s/$1$//;
        push @arglist, $extracted;

        $rest =~ s/^ //;
        @args = split / /, $rest;
      } else {
        # mismatched quotes, shove the remainder as the last positional argument
        push @arglist, $rest;
        last;
      }
    } else {
      push @arglist, $arg;
      push @arglist_quotes, $arg;
    }
  }

  # copy original args with quotes intact to end of arglist
  push @arglist, @arglist_quotes;
  return \@arglist;
}

# returns size of array of arguments
sub arglist_size {
  my ($self, $args) = @_;
  return @$args / 2;
}

# shifts first argument off array of arguments
sub shift_arg {
  my ($self, $args) = @_;
  splice @$args, @$args / 2, 1; # remove original quoted argument
  return shift @$args;
}

# splits array of arguments into array with overflow arguments filling up last position
# split_args(qw/dog cat bird hamster/, 3) => ("dog", "cat", "bird hamster")
sub split_args {
  my ($self, $args, $count, $offset) = @_;
  my @result;

  my $max = $self->arglist_size($args);

  my $i = $offset // 0;
  do {
    my $arg = $args->[$i++];
    push @result, $arg;
  } while (--$count > 1 and $i < $max);

  # get rest from 2nd half of arglist, which contains original quotes
  my $rest = join ' ', @$args[@$args / 2 + $i .. @$args - 1];
  push @result, $rest if length $rest;
  return @result;
}

# lowercases array of arguments
sub lc_args {
  my ($self, $args) = @_;
  for (my $i = 0; $i < @$args; $i++) {
    $args->[$i] = lc $args->[$i];
  }
}

sub truncate_result {
  my ($self, $from, $nick, $text, $original_result, $result, $paste) = @_;
  my $max_msg_len = $self->{pbot}->{registry}->get_value('irc', 'max_msg_len');

  if(length $result > $max_msg_len) {
    my $link;
    if($paste) {
      $original_result = substr $original_result, 0, 8000;
      $link = $self->{pbot}->{webpaste}->paste("[" . (defined $from ? $from : "stdin") . "] <$nick> $text\n\n$original_result");
    } else {
      $link = 'undef';
    }

    my $trunc = "... [truncated; ";
    if ($link =~ m/^http/) {
      $trunc .= "see $link for full text.]";
    } else {
      $trunc .= "$link]";
    }

    $self->{pbot}->{logger}->log("Message truncated -- pasted to $link\n") if $paste;

    my $trunc_len = length $result < $max_msg_len ? length $result : $max_msg_len;
    $result = substr($result, 0, $trunc_len);
    substr($result, $trunc_len - length $trunc) = $trunc;
  }

  return $result;
}

sub handle_result {
  my ($self, $stuff, $result) = @_;
  $result = $stuff->{result} if not defined $result;
  $stuff->{preserve_whitespace} = 0 if not defined $stuff->{preserve_whitespace};

  if ($self->{pbot}->{registry}->get_value('general', 'debugcontext') and length $stuff->{result}) {
    use Data::Dumper;
    $Data::Dumper::Sortkeys  = 1;
    $self->{pbot}->{logger}->log("Interpreter::handle_result [$result]\n");
    $self->{pbot}->{logger}->log(Dumper $stuff);
  }

  if (not defined $result or length $result == 0) {
    return 0;
  }

  if ($result =~ s#^(/say|/me) ##) {
    $stuff->{prepend} = $1;
  } elsif ($result =~ s#^(/msg \S+) ##) {
    $stuff->{prepend} = $1;
  }

  if (exists $stuff->{subcmd}) {
    my $command = pop @{$stuff->{subcmd}};

    if (@{$stuff->{subcmd}} == 0) {
      delete $stuff->{subcmd};
    }

    $command =~ s/&\{subcmd\}/$result/;

    $stuff->{command} = $command;
    $result = $self->interpret($stuff);
    $stuff->{result}= $result;
    $self->{pbot}->{logger}->log("subcmd result [$result]\n");
    $self->handle_result($stuff);
    return 0;
  }

  if ($stuff->{pipe} and not $stuff->{authorized}) {
    my ($pipe, $pipe_rest) = (delete $stuff->{pipe}, delete $stuff->{pipe_rest});
    $self->{pbot}->{logger}->log("Handling pipe [$result][$pipe][$pipe_rest]\n");
    $stuff->{command} = "$pipe $result$pipe_rest";
    $result = $self->interpret($stuff);
    $stuff->{result} = $result;
    $self->handle_result($stuff, $result);
    return 0;
  }

  if ($stuff->{prepend}) {
    $result = "$stuff->{prepend} $result";
  }

  my $original_result = $result;

  my $use_output_queue = 0;

  if (defined $stuff->{command}) {
    my $cmdlist = $self->make_args($stuff->{command});
    my ($cmd, $args) = $self->split_args($cmdlist, 2);
    if (not $self->{pbot}->{commands}->exists($cmd)) {
      my ($chan, $trigger) = $self->{pbot}->{factoids}->find_factoid($stuff->{from}, $cmd, $args, 1, 0, 1);
      if(defined $trigger) {
        if ($stuff->{preserve_whitespace} == 0) {
          $stuff->{preserve_whitespace} = $self->{pbot}->{factoids}->{factoids}->hash->{$chan}->{$trigger}->{preserve_whitespace};
          $stuff->{preserve_whitespace} = 0 if not defined $stuff->{preserve_whitespace};
        }

        $use_output_queue = $self->{pbot}->{factoids}->{factoids}->hash->{$chan}->{$trigger}->{use_output_queue};
        $use_output_queue = 0 if not defined $use_output_queue;
      }
    }
  }

  my $preserve_newlines = $self->{pbot}->{registry}->get_value($stuff->{from}, 'preserve_newlines');

  $result =~ s/[\n\r]/ /g unless $preserve_newlines;
  $result =~ s/[ \t]+/ /g unless $stuff->{preserve_whitespace};

  my $max_lines = $self->{pbot}->{registry}->get_value($stuff->{from}, 'max_newlines');
  $max_lines = 4 if not defined $max_lines;
  my $lines = 0;

  my $stripped_line;
  foreach my $line (split /[\n\r]+/, $result) {
    $stripped_line = $line;
    $stripped_line =~ s/^\s+//;
    $stripped_line =~ s/\s+$//;
    next if not length $stripped_line;

    if (++$lines >= $max_lines) {
      my $link = $self->{pbot}->{webpaste}->paste("[" . (defined $stuff->{from} ? $stuff->{from} : "stdin") . "] <$stuff->{nick}> $stuff->{text}\n\n$original_result");
      if ($use_output_queue) {
        my $message = {
          nick => $stuff->{nick}, user => $stuff->{user}, host => $stuff->{host}, command => $stuff->{command},
          message => "And that's all I have to say about that. See $link for full text.",
          checkflood => 1
        };
        $self->add_message_to_output_queue($stuff->{from}, $message, 0);
      } else {
        $self->{pbot}->{conn}->privmsg($stuff->{from}, "And that's all I have to say about that. See $link for full text.");
      }
      last;
    }

    if ($preserve_newlines) {
      $line = $self->truncate_result($stuff->{from}, $stuff->{nick}, $stuff->{text}, $line, $line, 1);
    } else {
      $line = $self->truncate_result($stuff->{from}, $stuff->{nick}, $stuff->{text}, $original_result, $line, 1);
    }

    if ($use_output_queue) {
      my $delay = (rand 5) + 5;     # initial delay for reading/processing user's message
      $delay += (length $line) / 7; # additional delay of 7 characters per second typing speed
      my $message = {
        nick => $stuff->{nick}, user => $stuff->{user}, host => $stuff->{host}, command => $stuff->{command},
        message => $line, checkflood => 1
      };
      $self->add_message_to_output_queue($stuff->{from}, $message, $delay);
      $delay = duration($delay);
      $self->{pbot}->{logger}->log("Final result ($delay delay) [$line]\n");
    } else {
      $stuff->{line} = $line;
      $self->output_result($stuff);
      $self->{pbot}->{logger}->log("Final result: [$line]\n");
    }
  }
  $self->{pbot}->{logger}->log("---------------------------------------------\n");
  return 1;
}

sub output_result {
  my ($self, $stuff) = @_;
  my ($pbot, $botnick) = ($self->{pbot}, $self->{pbot}->{registry}->get_value('irc', 'botnick'));

  if ($self->{pbot}->{registry}->get_value('general', 'debugcontext')) {
    use Data::Dumper;
    $Data::Dumper::Sortkeys  = 1;
    $self->{pbot}->{logger}->log("Interpreter::output_result\n");
    $self->{pbot}->{logger}->log(Dumper $stuff);
  }

  my $line = $stuff->{line};

  return if not defined $line or not length $line;

  if ($line =~ s/^\/say\s+//i) {
    if (defined $stuff->{nickoverride} and ($stuff->{no_nickoverride} == 0 or $stuff->{force_nickoverride} == 1)) {
      $line = "$stuff->{nickoverride}: $line";
    }
    $pbot->{conn}->privmsg($stuff->{from}, $line) if defined $stuff->{from} && $stuff->{from} !~ /\Q$botnick\E/i;
    $pbot->{antiflood}->check_flood($stuff->{from}, $botnick, $pbot->{registry}->get_value('irc', 'username'), 'localhost', $line, 0, 0, 0) if $stuff->{checkflood};
  } elsif ($line =~ s/^\/me\s+//i) {
=cut
    if (defined $stuff->{nickoverride}) {
      $line = "$line (for $stuff->{nickoverride})";
    }
=cut
    $pbot->{conn}->me($stuff->{from}, $line) if defined $stuff->{from} && $stuff->{from} !~ /\Q$botnick\E/i;
    $pbot->{antiflood}->check_flood($stuff->{from}, $botnick, $pbot->{registry}->get_value('irc', 'username'), 'localhost', '/me ' . $line, 0, 0, 0) if $stuff->{checkflood};
  } elsif ($line =~ s/^\/msg\s+([^\s]+)\s+//i) {
    my $to = $1;
    if ($to =~ /,/) {
      $pbot->{logger}->log("[HACK] Possible HACK ATTEMPT /msg multiple users: [$stuff->{nick}!$stuff->{user}\@$stuff->{host}] [$stuff->{command}] [$line]\n");
    } elsif ($to =~ /.*serv(?:@.*)?$/i) {
      $pbot->{logger}->log("[HACK] Possible HACK ATTEMPT /msg *serv: [$stuff->{nick}!$stuff->{user}\@$stuff->{host}] [$stuff->{command}] [$line]\n");
    } elsif ($line =~ s/^\/me\s+//i) {
=cut
      if (defined $stuff->{nickoverride}) {
        $line = "$line (for $stuff->{nickoverride})";
      }
=cut
      $pbot->{conn}->me($to, $line) if $to !~ /\Q$botnick\E/i;
      $pbot->{antiflood}->check_flood($to, $botnick, $pbot->{registry}->get_value('irc', 'username'), 'localhost', '/me ' . $line, 0, 0, 0) if $stuff->{checkflood};
    } else {
      $line =~ s/^\/say\s+//i;
      if (defined $stuff->{nickoverride} and ($stuff->{no_nickoverride} == 0 or $stuff->{force_nickoverride} == 1)) {
        $line = "$stuff->{nickoverride}: $line";
      }
      $pbot->{conn}->privmsg($to, $line) if $to !~ /\Q$botnick\E/i;
      $pbot->{antiflood}->check_flood($to, $botnick, $pbot->{registry}->get_value('irc', 'username'), 'localhost', $line, 0, 0, 0) if $stuff->{checkflood};
    }
  } elsif ($stuff->{authorized} && $line =~ s/^\/kick\s+//) {
    $pbot->{antiflood}->check_flood($stuff->{from}, $botnick, $pbot->{registry}->get_value('irc', 'username'), 'localhost', '/kick ' . $line, 0, 0, 0) if $stuff->{checkflood};
    my ($victim, $reason) = split /\s+/, $line, 2;

    if (not defined $reason) {
      if (open my $fh, '<',  $self->{pbot}->{registry}->get_value('general', 'module_dir') . '/insults.txt') {
        my @insults = <$fh>;
        close $fh;
        $reason = $insults[rand @insults];
        chomp $reason;
      } else {
        $reason = 'Bye!';
      }
    }

    if ($self->{pbot}->{chanops}->can_gain_ops($stuff->{from})) {
      $self->{pbot}->{chanops}->add_op_command($stuff->{from}, "kick $stuff->{from} $victim $reason");
      $self->{pbot}->{chanops}->gain_ops($stuff->{from});
    } else {
      $pbot->{conn}->privmsg($stuff->{from}, "$victim: $reason") if defined $stuff->{from} && $stuff->{from} !~ /\Q$botnick\E/i;
    }
  } else {
    if (defined $stuff->{nickoverride} and ($stuff->{no_nickoverride} == 0 or $stuff->{force_nickoverride} == 1)) {
      $line = "$stuff->{nickoverride}: $line";
    }
    $pbot->{conn}->privmsg($stuff->{from}, $line) if defined $stuff->{from} && $stuff->{from} !~ /\Q$botnick\E/i;
    $pbot->{antiflood}->check_flood($stuff->{from}, $botnick, $pbot->{registry}->get_value('irc', 'username'), 'localhost', $line, 0, 0, 0) if $stuff->{checkflood};
  }
}

sub add_message_to_output_queue {
  my ($self, $channel, $message, $delay) = @_;

  if ($delay > 0 and exists $self->{output_queue}->{$channel}) {
    my $last_when = $self->{output_queue}->{$channel}->[-1]->{when};
    $message->{when} = $last_when + $delay;
  } else {
    $message->{when} = gettimeofday + $delay;
  }

  push @{$self->{output_queue}->{$channel}}, $message;

  $self->process_output_queue if $delay <= 0;
}

sub process_output_queue {
  my $self = shift;

  foreach my $channel (keys %{$self->{output_queue}}) {
    for (my $i = 0; $i < @{$self->{output_queue}->{$channel}}; $i++) {
      my $message = $self->{output_queue}->{$channel}->[$i];
      if (gettimeofday >= $message->{when}) {
        my $stuff = {
          from => $channel,
          nick => $message->{nick},
          user => $message->{user},
          host => $message->{host},
          line => $message->{message},
          command => $message->{command},
          checkflood => $message->{checkflood}
        };

        $self->output_result($stuff);
        splice @{$self->{output_queue}->{$channel}}, $i--, 1;
      }
    }

    if (not @{$self->{output_queue}->{$channel}}) {
      delete $self->{output_queue}->{$channel};
    }
  }
}

sub add_to_command_queue {
  my ($self, $channel, $command, $delay) = @_;

  $command->{when} = gettimeofday + $delay;

  push @{$self->{command_queue}->{$channel}}, $command;
}

sub add_botcmd_to_command_queue {
  my ($self, $channel, $command, $delay) = @_;

  my $botcmd = {
    nick => $self->{pbot}->{registry}->get_value('irc', 'botnick'),
    user => 'stdin',
    host => 'localhost',
    command => $command
  };

  $self->add_to_command_queue($channel, $botcmd, $delay);
}

sub process_command_queue {
  my $self = shift;

  foreach my $channel (keys %{$self->{command_queue}}) {
    for (my $i = 0; $i < @{$self->{command_queue}->{$channel}}; $i++) {
      my $command = $self->{command_queue}->{$channel}->[$i];
      if (gettimeofday >= $command->{when}) {
        my $stuff = {
          from => $channel,
          nick => $command->{nick},
          user => $command->{user},
          host => $command->{host},
          command => $command->{command},
          interpret_depth => 0,
          checkflood => 0,
          preserve_whitespace => 0
        };

        if (exists $command->{level}) {
          $self->{pbot}->{logger}->log("Override command effective-level to $command->{level}\n");
          $stuff->{'effective-level'} = $command->{level};
        }

        my $result = $self->interpret($stuff);
        $stuff->{result} = $result;
        $self->handle_result($stuff, $result);
        splice @{$self->{command_queue}->{$channel}}, $i--, 1;
      }
    }

    if (not @{$self->{command_queue}->{$channel}}) {
      delete $self->{command_queue}->{$channel};
    }
  }
}

1;
