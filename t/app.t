use strict;
use warnings;
use Test::More;

use CPAN::Mini::App;
use File::Spec;
use File::Temp qw(tempdir);

my $TARGET  = tempdir(CLEANUP => 1);
my @LR_ARGS = (qw(-r http://example.com/cpan -l), $TARGET);

sub config_dir {
  my ($config) = @_;

  my $tempdir = tempdir(CLEANUP => 1);

  return unless defined $config;

  my $filename = File::Spec->catfile($tempdir, '.minicpanrc');
  open my $config_fh, '>', $filename or die "can't write to $filename: $!";

  for my $key (keys %$config) {
    print {$config_fh} "$key: $config->{$key}\n";
  }

  close $config_fh or die "error closing $filename: $!";

  return $tempdir;
}

subtest "defaults" => sub {
  local $ENV{HOME} = config_dir;
  local @ARGV = @LR_ARGS;

  my $minicpan = CPAN::Mini::App->initialize_minicpan;
  isa_ok($minicpan, 'CPAN::Mini');

  is($minicpan->log_level, 'info', "default log level is info");
};

subtest "--debug" => sub {
  local $ENV{HOME} = config_dir;
  local @ARGV = (qw(--debug), @LR_ARGS);

  my $minicpan = CPAN::Mini::App->initialize_minicpan;
  isa_ok($minicpan, 'CPAN::Mini');

  is($minicpan->log_level, 'debug', "--debug to get log level debug");
};

subtest "config: log_level" => sub {
  local $ENV{HOME} = config_dir({ log_level => 'debug' });
  local @ARGV = @LR_ARGS;

  my $minicpan = CPAN::Mini::App->initialize_minicpan;
  isa_ok($minicpan, 'CPAN::Mini');

  is($minicpan->log_level, 'debug', "debug from config file");
};

subtest "--debug overrides config" => sub {
  local $ENV{HOME} = config_dir({ log_level => 'fatal' });
  local @ARGV = (qw(--debug), @LR_ARGS);

  my $minicpan = CPAN::Mini::App->initialize_minicpan;
  isa_ok($minicpan, 'CPAN::Mini');

  is($minicpan->log_level, 'debug', "--debug overrides config file");
};

subtest "--log-level" => sub {
  local $ENV{HOME} = config_dir;
  local @ARGV = (qw(--log-level debug), @LR_ARGS);

  my $minicpan = CPAN::Mini::App->initialize_minicpan;
  isa_ok($minicpan, 'CPAN::Mini');

  is($minicpan->log_level, 'debug', "--debug to get log level debug");
};

subtest "only one log-level-like switch allowed" => sub {
  for my $combo (
    [ qw(--debug -q) ],
    [ qw(--debug --log-level debug) ],
  ) {
    local $ENV{HOME} = config_dir;
    local @ARGV = (@$combo, @LR_ARGS);

    my $minicpan = eval { CPAN::Mini::App->initialize_minicpan };
    like($@, qr/can't mix/, "can't use @$combo together");
  };
};

for my $switch (qw(-qq --qq)) {
  subtest "extra quiet with $switch" => sub {
    local $ENV{HOME} = config_dir;
    local @ARGV = ($switch, @LR_ARGS);

    my $minicpan = CPAN::Mini::App->initialize_minicpan;
    isa_ok($minicpan, 'CPAN::Mini');

    is($minicpan->log_level, 'fatal', "$switch gets us log level 'fatal'");
  };
}

done_testing;

1;
