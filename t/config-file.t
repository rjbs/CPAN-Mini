#!perl

use warnings;
use strict;

use Test::More tests => 21;

use File::Basename;
use File::Temp;

my $class = 'CPAN::Mini';

use_ok($class);
can_ok($class, 'config_file');

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# command line option case
{
  my $filename = 'Changes';
  ok(-e $filename, "file name [$filename] exists");

  local $ENV{CPAN_MINI_CONFIG} = 'Buster';
  my $options = { config_file => $filename, };

  is($class->config_file($options),
    $filename, 'selects config file name from command line');
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# environment variable case
{
  my $filename = $0;
  ok(-e $filename, "file name [$filename] exists");

  local $ENV{CPAN_MINI_CONFIG} = $filename;

  is($class->config_file, $filename,
    'selects config file name from environment with no args');
  is($class->config_file({}),
    $filename, 'selects config file name from environment with empty hash ref');
  is($class->config_file('trash'),
    $filename, 'selects config file name from environment with non-ref arg');
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# default case
# this is the case where there is a ~/.minicpanrc
{

  my $filename = 'Changes';
  ok(-e $filename, "file name [$filename] exists");

  {
    no strict 'refs';
    no warnings 'redefine';

    *{"${class}::__homedir_configfile"} = sub { $filename };
    is($class->__homedir_configfile,
      $filename, "__homedir_configfile returns mocked name");
  }

  local $ENV{CPAN_MINI_CONFIG} = undef;

  is($class->config_file, $filename, 'selects default config file name');
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# last ditch case
# this is the case wehre there is no ~/.minicpanrc
{
  local $ENV{CPAN_MINI_CONFIG} = undef;
  my $is_there_filename = 'Changes';
  ok(-e $is_there_filename, "file name [$is_there_filename] does exist");

  {
    no strict 'refs';
    no warnings 'redefine';

    *{"${class}::__homedir_configfile"} = sub { undef };
    is($class->__homedir_configfile,
      undef, "__homedir_configfile returns mocked name");
    *{"${class}::__default_configfile"} = sub { $is_there_filename };
    is($class->__default_configfile,
      $is_there_filename, "__default_configfile returns mocked name");
  }

  is($class->config_file, $is_there_filename,
    'selects default config file name');
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# bad option in config file case
{
  my $cfg = File::Temp->new();
  $cfg->print(<<'EOF');
local: /home/my-mirror
bad_option: TRUE
EOF
  $cfg->close();

  local $ENV{CPAN_MINI_CONFIG} = $cfg->filename;

  my @warnings;
  local $SIG{__WARN__} = sub {
     push @warnings, @_;
  };

  my %config = $class->read_config();

  is scalar(@warnings), 1, 'exactly one warning';
  like $warnings[0], qr{config option of \[bad_option\] was not recognised}, 'warning of invalid bad_option';

  is_deeply(
    \%config,
    { local => '/home/my-mirror' },
    'config file read with bad options ignored'
  );
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# everything failed case
{
  local $ENV{CPAN_MINI_CONFIG} = undef;

  {
    no strict 'refs';
    no warnings 'redefine';

    *{"${class}::__homedir_configfile"} = sub { undef };
    is($class->__homedir_configfile,
      undef, "__homedir_configfile returns mocked name");
    *{"${class}::__default_configfile"} = sub { undef };
    is($class->__default_configfile,
      undef, "__default_configfile returns mocked name");
  }

  is($class->config_file, undef, 'returns undef when no config file is found');
}
