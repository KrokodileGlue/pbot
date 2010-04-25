#!/usr/bin/perl

use warnings;
use strict;

use LWP::UserAgent;
use URI::Escape;
use HTML::Entities;
use HTML::Parse;
use HTML::FormatText;

my @languages = qw/C C++ D Haskell Lua OCaml PHP Perl Python Ruby Scheme Tcl/;

my %preludes = ( 'C' => "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n",
                 'C++' => "#include <iostream>\n#include <cstdio>\n",
               );

if($#ARGV <= 0) {
  print "Usage: cc [-lang=<language>] <code>\n";
  exit 0;
}

my $nick = shift @ARGV;
my $code = join ' ', @ARGV;

open FILE, ">> codepad_log.txt";
print FILE "$nick: $code\n";

my $lang = "C";
$lang = $1 if $code =~ s/-lang=([^\b\s]+)//i;

my $found = 0;
foreach my $l (@languages) {
  if(uc $lang eq uc $l) {
    $lang = $l;
    $found = 1;
    last;
  }
}

if(not $found) {
  print "$nick: Invalid language '$lang'.  Supported languages are: @languages\n";
  exit 0;
}

my $ua = LWP::UserAgent->new();

$ua->agent("Mozilla/5.0");
push @{ $ua->requests_redirectable }, 'POST';

$code =~ s/#include <([^>]+)>/\n#include <$1>\n/g;
$code =~ s/#([^ ]+) (.*?)\\n/\n#$1 $2\n/g;

$code = $preludes{$lang} . $code;

if(($lang eq "C" or $lang eq "C++") and not $code =~ m/(int|void) main\s*\([^)]*\)\s*{/) {
  my $prelude = '';
  $prelude = "$1$2" if $code =~ s/^\s*(#.*)(#.*?[>\n])//s;
  $code = "$prelude\n int main(int argc, char **argv) { $code ; return 0; }";
}

my %post = ( 'lang' => $lang, 'code' => $code, 'private' => 'True', 'run' => 'True', 'submit' => 'Submit' );
my $response = $ua->post("http://codepad.org", \%post);

if(not $response->is_success) {
  print "There was an error compiling the code.\n";
  die $response->status_line;
}

my $text = $response->decoded_content;
my $url = $response->request->uri;
my $output;

# remove line numbers
$text =~ s/<a style="" name="output-line-\d+">\d+<\/a>//g;

if($text =~ /<span class="heading">Output:<\/span>.+?<div class="code">(.*)<\/div>.+?<\/table>/si) {
  $output = "$1";
} else {
  $output = "<pre>No output.</pre>";
}

$output = decode_entities($output);
$output = HTML::FormatText->new->format(parse_html($output));

$output =~ s/^\s+//;

$output =~ s/ Line \d+ ://g;
$output =~ s/ \(first use in this function\)//g;
$output =~ s/error: \(Each undeclared identifier is reported only once.*?\)//g;
$output =~ s/error: (.*?).error/error: $1; error/g;

print FILE localtime . "\n";
print FILE "$nick: [ $url ] $output\n\n";
close FILE;
print "$nick: $output\n";

