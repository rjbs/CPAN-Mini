
use strict;
use warnings;

package CPAN::Mini::App;

=head1 NAME

CPAN::Mini::App - the guts of the minicpan command

=head1 SYNOPSIS

  #!/usr/bin/perl
  use CPAN::Mini::App;
  CPAN::Mini::App->run;

=cut

use CPAN::Mini;
use File::HomeDir;
use File::Spec;
use Getopt::Long qw(GetOptions);
use Pod::Usage;

sub _display_version {
  my $class = shift;
  no strict 'refs';
  print "minicpan",
    ($class ne 'CPAN::Mini' ? ' (from CPAN::Mini)' : q{}),
    ", powered by $class ", $class->VERSION, "\n\n";
  exit;
}

=head2 run

This method is called by F<minicpan> to do all the work.  Don't rely on what it
does just yet.

=cut

sub run {
  my %config = CPAN::Mini->read_config;
  my $class  = 'CPAN::Mini';
  my $version;

  GetOptions(
    "c|class=s"   => \$class,
    "h|help"      => sub { pod2usage(1); },
    "v|version"   => sub { $version = 1 },
    "l|local=s"   => \$config{local},
    "r|remote=s"  => \$config{remote},
    "d|dirmode=s" => \$config{dirmode},
    "qq"          => sub { $config{quiet} = 2; $config{errors} = 0; },
    "q+" => \$config{quiet},
    "f+" => \$config{force},
    "p+" => \$config{perl},
    "x+" => \$config{exact_mirror},
  ) or pod2usage(2);

  eval "require $class";
  die $@ if $@;

  _display_version($class) if $version;
  pod2usage(2) unless $config{local} and $config{remote};

  $|++;
  $config{dirmode} &&= oct($config{dirmode});

  CPAN::Mini->update_mirror(
    remote  => $config{remote},
    local   => $config{local},
    trace   => (not $config{quiet}),
    force   => $config{force},
    dirmode => $config{dirmode},
    also_mirror    => $config{also_mirror},
    exact_mirror   => ($config{exact_mirror}),
    module_filters => ($config{module_filters}),
    path_filters   => ($config{path_filters}),
    skip_perl      => (not $config{perl}),
    (defined $config{errors} ? (errors  => $config{errors}) : ()),
  );
}

=head1 SEE ALSO 

Randal Schwartz's original article, which can be found here:

  http://www.stonehenge.com/merlyn/LinuxMag/col42.html

=head1 AUTHORS

Randal Schwartz <F<merlyn@stonehenge.com>>

Ricardo SIGNES <F<rjbs@cpan.org>>

Copyright 2004, released under the same terms as Perl itself.

=cut

1;
