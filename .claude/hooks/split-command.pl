#!/usr/bin/env perl
# Splits a shell command line (stdin) into simple commands, one per output line, with
# words separated by \x1f. Quote-aware, so a quoted commit message stays one word.
#   - separators: ; & | && || newline ( )
#   - $( ... ) and `...` start a new command even inside double quotes, because they run
#   - >&, &> and 2>&1 stay part of a word
# Not a full shell parser (no here-docs, no arithmetic); the guards that use it are a
# guard rail, with CI and branch protection behind them.
use strict;
use warnings;

my $s = do { local $/; <STDIN> } // '';
my @c = split //, $s;
my (@segments, @words);
my ($word, $has, $quote) = ('', 0, '');
my @resume;    # quote state to restore when a command substitution closes
my $depth = 0; # plain ( ) nesting inside the current substitution

sub end_word {
  if ($has) { (my $w = $word) =~ s/\n/ /g; push @words, $w }
  ($word, $has) = ('', 0);
}
sub end_command { end_word(); push @segments, join("\x1f", @words) if @words; @words = () }
sub next_is { my ($i, $ch) = @_; return ($c[$i + 1] // '') eq $ch }

for (my $i = 0; $i < @c; $i++) {
  my $ch = $c[$i];

  if ($quote eq "'") {
    if ($ch eq "'") { $quote = '' } else { $word .= $ch }
    next;
  }
  if ($quote eq '"') {
    if ($ch eq '"') { $quote = ''; next }
    if ($ch eq '\\' && $i + 1 < @c) { $word .= $c[++$i]; next }
    if ($ch eq '$' && next_is($i, '(')) { end_command(); push @resume, ['"', ')', $depth]; ($quote, $depth) = ('', 0); $i++; next }
    if ($ch eq '`') { end_command(); push @resume, ['"', '`', $depth]; ($quote, $depth) = ('', 0); next }
    $word .= $ch;
    next;
  }

  if ($ch eq "'" || $ch eq '"') { $quote = $ch; $has = 1; next }
  if ($ch eq '\\' && $i + 1 < @c) { $word .= $c[++$i]; $has = 1; next }
  if ($ch eq "\n") { end_command(); next }
  if ($ch =~ /\s/) { end_word(); next }
  if ($ch eq '&' && (($i > 0 && $c[$i - 1] eq '>') || next_is($i, '>'))) { $word .= $ch; $has = 1; next }
  if ($ch eq '$' && next_is($i, '(')) { end_command(); push @resume, ['', ')', $depth]; $depth = 0; $i++; next }
  if ($ch eq '`') {
    end_command();
    if (@resume && $resume[-1][1] eq '`') { my $r = pop @resume; ($quote, $depth) = ($r->[0], $r->[2]) }
    else { push @resume, ['', '`', $depth]; $depth = 0 }
    next;
  }
  if ($ch eq '(') { end_command(); $depth++; next }
  if ($ch eq ')') {
    end_command();
    if ($depth > 0) { $depth-- }
    elsif (@resume && $resume[-1][1] eq ')') { my $r = pop @resume; ($quote, $depth) = ($r->[0], $r->[2]) }
    next;
  }
  if ($ch =~ /[;&|]/) { end_command(); next }
  $word .= $ch;
  $has = 1;
}
end_command();
print "$_\n" for @segments;
