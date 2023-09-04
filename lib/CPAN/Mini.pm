use 5.006;
use strict;
use warnings;

package CPAN::Mini;

# ABSTRACT: create a minimal mirror of CPAN

## no critic RequireCarping

=head1 SYNOPSIS

(If you're not going to do something weird, you probably want to look at the
L<minicpan> command, instead.)

  use CPAN::Mini;

  CPAN::Mini->update_mirror(
    remote => "http://cpan.mirrors.comintern.su",
    local  => "/usr/share/mirrors/cpan",
    log_level => 'debug',
  );

=head1 DESCRIPTION

CPAN::Mini provides a simple mechanism to build and update a minimal mirror of
the CPAN on your local disk.  It contains only those files needed to install
the newest version of every distribution.  Those files are:

=for :list
* 01mailrc.txt.gz
* 02packages.details.txt.gz
* 03modlist.data.gz
* the last non-developer release of every dist for every author

Once you have the files downloaded you can install modules straight from
the folder.

    cpanm -M /usr/share/mirrors/cpan CPAN::Mini

Or make the files available via a web server to allow install of the
modules from other machines.

    cd /usr/share/mirrors/cpan
    python -m SimpleHTTPServer 8000 &
    cpanm -M http://localhost:8000 CPAN::Mini

=cut

use Carp ();

use File::Basename ();
use File::Copy     ();
use File::HomeDir 0.57 ();  # Win32 support
use File::Find ();
use File::Path 2.04 ();     # new API, bugfixes
use File::Spec ();
use File::Temp ();

use URI 1            ();
use LWP::UserAgent 5 ();

use Compress::Zlib 1.20 ();

=method update_mirror

  CPAN::Mini->update_mirror(
    remote => "http://cpan.mirrors.comintern.su",
    local  => "/usr/share/mirrors/cpan",
    force  => 0,
    log_level => 'debug',
  );

This is the only method that need be called from outside this module.  It will
update the local mirror with the files from the remote mirror.

If called as a class method, C<update_mirror> creates an ephemeral CPAN::Mini
object on which other methods are called.  That object is used to store mirror
location and state.

This method returns the number of files updated.

The following options are recognized:

=begin :list

* C<local>

This is the local file path where the mirror will be written or updated.

* C<remote>

This is the URL of the CPAN mirror from which to work.  A reasonable default
will be picked by default.  A list of CPAN mirrors can be found at
L<http://www.cpan.org/SITES.html>

* C<dirmode>

Generally an octal number, this option sets the permissions of created
directories.  It defaults to 0711.

* C<exact_mirror>

If true, the C<file_allowed> method will allow all extra files to be mirrored.

* C<ignore_source_control>

If true, CPAN::Mini will not try to remove source control files during
cleanup. See C<clean_unmirrored> for details.

* C<force>

If true, this option will cause CPAN::Mini to read the entire module list and
update anything out of date, even if the module list itself wasn't out of date
on this run.

* C<skip_perl>

If true, CPAN::Mini will skip the major language distributions: perl, parrot,
and ponie.  It will also skip embperl, sybperl, bioperl, and kurila.

* C<log_level>

This defines the minimum level of message to log: debug, info, warn, or fatal

* C<errors>

If true, CPAN::Mini will warn with status messages on errors.  (default: true)

* C<path_filters>

This options provides a set of rules for filtering paths.  If a distribution
matches one of the rules in C<path_filters>, it will not be mirrored.  A regex
rule is matched if the path matches the regex; a code rule is matched if the
code returns 1 when the path is passed to it.  For example, the following
setting would skip all distributions from RJBS and SUNGO:

 path_filters => [
   qr/RJBS/,
   sub { $_[0] =~ /SUNGO/ }
 ]

* C<module_filters>

This option provides a set of rules for filtering modules.  It behaves like
path_filters, but acts only on module names.  (Since most modules are in
distributions with more than one module, this setting will probably be less
useful than C<path_filters>.)  For example, this setting will skip any
distribution containing only modules with the word "Acme" in them:

 module_filters => [ qr/Acme/i ]

* C<also_mirror>

This option should be an arrayref of extra files in the remote CPAN to mirror
locally.

* C<skip_cleanup>

If this option is true, CPAN::Mini will not try delete unmirrored files when it
has finished mirroring

* C<offline>

If offline, CPAN::Mini will not attempt to contact remote resources.

* C<no_conn_cache>

If true, no connection cache will be established.  This is mostly useful as a
workaround for connection cache failures.

=end :list

=cut

sub update_mirror {
  my $self = shift;
  $self = $self->new(@_) unless ref $self;

  unless ($self->{offline}) {
    my $local = $self->{local};

    $self->log("Updating $local");
    $self->log("Mirroring from $self->{remote}");
    $self->log("=" x 63);

    die "local mirror target $local is not writable" unless -w $local;

    # mirrored tracks the already done, keyed by filename
    # 1 = local-checked, 2 = remote-mirrored
    $self->mirror_indices;

    return unless $self->{force} or $self->{changes_made};

    # mirror all the files
    $self->_mirror_extras;
    $self->mirror_file($_, 1) for @{ $self->_get_mirror_list };

    # install indices after files are mirrored in case we're interrupted
    # so indices will seem new again when continuing
    $self->_install_indices;

    $self->_write_out_recent;

    # eliminate files we don't need
    $self->clean_unmirrored unless $self->{skip_cleanup};
  }

  return $self->{changes_made};
}

sub _recent { $_[0]->{recent}{ $_[1] } = 1 }

sub _write_out_recent {
  my ($self) = @_;
  return unless my @keys = keys %{ $self->{recent} };

  my $recent = File::Spec->catfile($self->{local}, 'RECENT');
  open my $recent_fh, '>', $recent or die "can't open $recent for writing: $!";

  for my $file (sort keys %{ $self->{recent} }) {
    print {$recent_fh} "$file\n" or die "can't write to $recent: $!";
  }

  die "error closing $recent: $!" unless close $recent_fh;
  return;
}

sub _get_mirror_list {
  my $self = shift;

  my %mirror_list;

  # now walk the packages list
  my $details = File::Spec->catfile(
    $self->_scratch_dir,
    qw(modules 02packages.details.txt.gz)
  );

  my $gz = Compress::Zlib::gzopen($details, "rb")
    or die "Cannot open details: $Compress::Zlib::gzerrno";

  my $inheader = 1;
  my $file_ok  = 0;
  while ($gz->gzreadline($_) > 0) {
    if ($inheader) {
      if (/\S/) {
        my ($header, $value) = split /:\s*/, $_, 2;
        chomp $value;
        if ($header eq 'File'
            and ($value eq '02packages.details.txt'
                 or $value eq '02packages.details.txt.gz')) {
          $file_ok = 1;
        }
      } else {
        $inheader = 0;
      }

      next;
    }

    die "02packages.details.txt file is not a valid index\n"
      unless $file_ok;

    my ($module, $version, $path) = split;
    next if $self->_filter_module({
      module  => $module,
      version => $version,
      path    => $path,
    });

    $mirror_list{"authors/id/$path"}++;
  }

  return [ sort keys %mirror_list ];
}

=method new

  my $minicpan = CPAN::Mini->new;

This method constructs a new CPAN::Mini object.  Its parameters are described
above, under C<update_mirror>.

=cut

sub new {
  my $class    = shift;
  my %defaults = (
    changes_made => 0,
    dirmode      => 0711,  ## no critic Zero
    errors       => 1,
    mirrored     => {},
    log_level    => 'info',
  );

  my $self = bless { %defaults, @_ } => $class;

  $self->{dirmode} = $defaults{dirmode} unless defined $self->{dirmode};

  $self->{recent} = {};

  Carp::croak "no local mirror supplied" unless $self->{local};

  substr($self->{local}, 0, 1, $class->__homedir)
    if substr($self->{local}, 0, 1) eq q{~};

  $self->{local} = File::Spec->rel2abs($self->{local});

  Carp::croak "local mirror path exists but is not a directory"
    if (-e $self->{local})
    and not(-d $self->{local});

  unless (-e $self->{local}) {
    File::Path::mkpath(
      $self->{local},
      {
        verbose => $self->{log_level} eq 'debug',
        mode    => $self->{dirmode},
      },
    );
  }

  Carp::croak "no write permission to local mirror" unless -w $self->{local};

  Carp::croak "no remote mirror supplied" unless $self->{remote};

  $self->{remote} = "$self->{remote}/" if substr($self->{remote}, -1) ne '/';

  my $version = $class->VERSION;
  $version = 'v?' unless defined $version;

  $self->{__lwp} = LWP::UserAgent->new(
    agent     => "$class/$version",
    env_proxy => 1,
    ($self->{no_conn_cache} ? () : (keep_alive => 5)),
    ($self->{timeout} ? (timeout => $self->{timeout}) : ()),
  );

  unless ($self->{offline}) {
    my $test_uri = URI->new_abs(
      'modules/02packages.details.txt.gz',
      $self->{remote},
    )->as_string;

    Carp::croak "unable to contact the remote mirror"
      unless eval { $self->__lwp->head($test_uri)->is_success };
  }

  return $self;
}

sub __lwp { $_[0]->{__lwp} }

=method mirror_indices

  $minicpan->mirror_indices;

This method updates the index files from the CPAN.

=cut

sub _fixed_mirrors {
  qw(
    authors/01mailrc.txt.gz
    modules/02packages.details.txt.gz
    modules/03modlist.data.gz
  );
}

sub _scratch_dir {
  my ($self) = @_;

  $self->{scratch} ||= File::Temp::tempdir(CLEANUP => 1);
  return $self->{scratch};
}

sub mirror_indices {
  my $self = shift;

  $self->_make_index_dirs($self->_scratch_dir);

  for my $path ($self->_fixed_mirrors) {
    my $local_file   = File::Spec->catfile($self->{local},   split m{/}, $path);
    my $scratch_file = File::Spec->catfile(
      $self->_scratch_dir,
      split(m{/}, $path),
    );

    File::Copy::copy($local_file, $scratch_file);

    utime((stat $local_file)[ 8, 9 ], $scratch_file);

    $self->mirror_file($path, undef, { to_scratch => 1 });
  }
}

sub _mirror_extras {
  my $self = shift;

  for my $path (@{ $self->{also_mirror} }) {
    $self->mirror_file($path, undef);
  }
}

sub _make_index_dirs {
  my ($self, $base_dir, $dir_mode, $trace) = @_;
  $base_dir ||= $self->_scratch_dir;
  $dir_mode = 0711 if !defined $dir_mode;  ## no critic Zero
  $trace    = 0    if !defined $trace;

  for my $index ($self->_fixed_mirrors) {
    my $dir = File::Basename::dirname($index);
    my $needed = File::Spec->catdir($base_dir, $dir);
    File::Path::mkpath($needed, { verbose => $trace, mode => $dir_mode });
    die "couldn't create $needed: $!" unless -d $needed;
  }
}

sub _install_indices {
  my $self = shift;

  $self->_make_index_dirs(
    $self->{local},
    $self->{dirmode},
    $self->{log_level} eq 'debug',
  );

  for my $file ($self->_fixed_mirrors) {
    my $local_file = File::Spec->catfile($self->{local}, split m{/}, $file);

    unlink $local_file;

    File::Copy::copy(
      File::Spec->catfile($self->_scratch_dir, split m{/}, $file),
      $local_file,
    );

    $self->{mirrored}{$local_file} = 1;
  }
}

=method mirror_file

  $minicpan->mirror_file($path, $skip_if_present)

This method will mirror the given file from the remote to the local mirror,
overwriting any existing file unless C<$skip_if_present> is true.

=cut

sub mirror_file {
  my ($self, $path, $skip_if_present, $arg) = @_;

  $arg ||= {};

  # full URL
  my $remote_uri = eval { $path->isa('URI') }
                 ? $path
                 : URI->new_abs($path, $self->{remote})->as_string;

  # native absolute file
  my $local_file = File::Spec->catfile(
    $arg->{to_scratch} ? $self->_scratch_dir : $self->{local},
    split m{/}, $path
  );

  my $checksum_might_be_up_to_date = 1;

  if ($skip_if_present and -f $local_file) {
    ## upgrade to checked if not already
    $self->{mirrored}{$local_file} ||= 1;
  } elsif (($self->{mirrored}{$local_file} || 0) < 2) {
    ## upgrade to full mirror
    $self->{mirrored}{$local_file} = 2;

    File::Path::mkpath(
      File::Basename::dirname($local_file),
      {
        verbose => $self->{log_level} eq 'debug',
        mode    => $self->{dirmode},
      },
    );

    $self->log($path, { no_nl => 1 });
    my $res = eval { $self->{__lwp}->mirror($remote_uri, $local_file) };

    if (! $res) {
      my $error = $@ || "(unknown error)";
      $self->log(" ... resulted in an HTTP client error");
      $self->log_warn("$remote_uri: $error");
      return;
    } elsif ($res->is_success) {
      utime undef, undef, $local_file if $arg->{update_times};
      $checksum_might_be_up_to_date = 0;
      $self->_recent($path);
      $self->log(" ... updated");
      $self->{changes_made}++;
    } elsif ($res->code != 304) {  # not modified
      $self->log(" ... resulted in an HTTP error with status " . $res->code);
      $self->log_warn("$remote_uri: " . $res->status_line);
      return;
    } else {
      $self->log(" ... up to date");
    }
  }

  if ($path =~ m{^authors/id}) {   # maybe fetch CHECKSUMS
    my $checksum_path
      = URI->new_abs("CHECKSUMS", $remote_uri)->rel($self->{remote})->as_string;

    if ($path ne $checksum_path) {
      $self->mirror_file($checksum_path, $checksum_might_be_up_to_date);
    }
  }
}

=begin devel

=method _filter_module

 next
   if $self->_filter_module({ module => $foo, version => $foo, path => $foo });

This method holds the filter chain logic. C<update_mirror> takes an optional
set of filter parameters.  As C<update_mirror> encounters a distribution, it
calls this method to figure out whether or not it should be downloaded. The
user provided filters are taken into account. Returns 1 if the distribution is
filtered (to be skipped).  Returns 0 if the distribution is to not filtered
(not to be skipped).

=end devel

=cut

sub __do_filter {
  my ($self, $what, $filter, $file) = @_;
  return unless $filter;

  if (ref($filter) eq 'ARRAY') {
    for (@$filter) {
      return 1 if $self->__do_filter($what, $_, $file);
    }
    return;
  }

  my $match;
  if (ref($filter) eq 'CODE') {
    $match = $filter->($file);
  } else {
    $match = $file =~ $filter;
  }

  $self->log_debug("skipping $file because $what matches $filter") if $match;
  return 1 if $match;
  return;
}

sub _filter_module {
  my $self = shift;
  my $args = shift;

  if ($self->{skip_perl}) {
    return 1 if $args->{path} =~ m{/(?:emb|syb|bio)?perl-\d}i;
    return 1 if $args->{path} =~ m{/(?:parrot|ponie)-\d}i;
    return 1 if $args->{path} =~ m{/(?:kurila)-\d}i;
    return 1 if $args->{path} =~ m{/\bperl-?5\.004}i;
    return 1 if $args->{path} =~ m{/\bperl_mlb\.zip}i;
  }

  return 1 if $self->__do_filter(path   => $self->{path_filters}, $args->{path});
  return 1 if $self->__do_filter(module => $self->{module_filters}, $args->{module});
  return 0;
}

=method file_allowed

  next unless $minicpan->file_allowed($filename);

This method returns true if the given file is allowed to exist in the local
mirror, even if it isn't one of the required mirror files.

By default, only dot-files are allowed.  If the C<exact_mirror> option is true,
all files are allowed.

=cut

sub file_allowed {
  my ($self, $file) = @_;
  return 1 if $self->{exact_mirror};

  # It's a cheap hack, but it gets the job done.
  return 1 if $file eq File::Spec->catfile($self->{local}, 'RECENT');

  return (substr(File::Basename::basename($file), 0, 1) eq q{.}) ? 1 : 0;
}

=method clean_unmirrored

  $minicpan->clean_unmirrored;

This method looks through the local mirror's files.  If it finds a file that
neither belongs in the mirror nor is allowed (see the C<file_allowed> method),
C<clean_file> is called on the file.

If you set C<ignore_source_control> to a true value, then this doesn't clean
up files that belong to source control systems. Currently this ignores:

	.cvs .cvsignore
	.svn .svnignore
	.git .gitignore

Send patches for other source control files that you would like to have added.

=cut

my %Source_control_files;
BEGIN {
  %Source_control_files = map { $_ => 1 }
    qw(.cvs .svn .git .cvsignore .svnignore .gitignore);
}

sub clean_unmirrored {
  my $self = shift;

  File::Find::find sub {
    my $file = File::Spec->canonpath($File::Find::name);  ## no critic Package
    my $basename = File::Basename::basename( $file );

    if (
      $self->{ignore_source_control}
      and exists $Source_control_files{$basename}
    ) {
      $File::Find::prune = 1;
      return;
    }

    return unless (-f $file and not $self->{mirrored}{$file});
    return if $self->file_allowed($file);

    $self->clean_file($file);

  }, $self->{local};
}

=method clean_file

  $minicpan->clean_file($filename);

This method, called by C<clean_unmirrored>, deletes the named file.  It returns
true if the file is successfully unlinked.  Otherwise, it returns false.

=cut

sub clean_file {
  my ($self, $file) = @_;

  unless (unlink $file) {
    $self->log_warn("$file cannot be removed: $!");
    return;
  }

  $self->log("$file removed");

  return 1;
}

=method log_warn

=method log

=method log_debug

  $minicpan->log($message);

This will log (print) the given message unless the log level is too low.

C<log>, which logs at the I<info> level, may also be called as C<trace> for
backward compatibility reasons.

=cut

sub log_level {
  return $_[0]->{log_level} if ref $_[0];
  return 'info';
}

sub log_unconditionally {
  my ($self, $message, $arg) = @_;
  $arg ||= {};

  print($message, $arg->{no_nl} ? () : "\n");
}

sub log_warn {
  return if $_[0]->log_level eq 'fatal';
  $_[0]->log_unconditionally($_[1], $_[2]);
}

sub log {
  return unless $_[0]->log_level =~ /\A(?:info|debug)\z/;
  $_[0]->log_unconditionally($_[1], $_[2]);
}

sub trace {
  my $self = shift;
  $self->log(@_);
}

sub log_debug {
  my ($self, @rest) = @_;
  return unless ($_[0]->log_level || '') eq 'debug';
  $_[0]->log_unconditionally($_[1], $_[2]);
}

=method read_config

  my %config = CPAN::Mini->read_config(\%options);

This routine returns a set of arguments that can be passed to CPAN::Mini's
C<new> or C<update_mirror> methods.  It will look for a file called
F<.minicpanrc> in the user's home directory as determined by
L<File::HomeDir|File::HomeDir>.

=cut

sub __homedir {
  my ($class) = @_;

  my $homedir = File::HomeDir->my_home || $ENV{HOME};

  Carp::croak "couldn't determine your home directory!  set HOME env variable"
    unless defined $homedir;

  return $homedir;
}

sub __homedir_configfile {
  my ($class) = @_;
  my $default = File::Spec->catfile($class->__homedir, '.minicpanrc');
}

sub __default_configfile {
  my ($self) = @_;

  (my $pm_loc = $INC{'CPAN/Mini.pm'}) =~ s/Mini\.pm\z//;
  File::Spec->catfile($pm_loc, 'minicpan.conf');
}

sub read_config {
  my ($class, $options) = @_;

  my $config_file = $class->config_file($options);

  return unless defined $config_file;

  # This is ugly, but lets us respect -qq for now even before we have an
  # object.  I think a better fix is warranted. -- rjbs, 2010-03-04
  $class->log("Using config from $config_file")
    if ($options->{log_level}||'info') =~ /\A(?:warn|fatal)\z/;

  substr($config_file, 0, 1, $class->__homedir)
    if substr($config_file, 0, 1) eq q{~};

  return unless -e $config_file;

  open my $config_fh, '<', $config_file
    or die "couldn't open config file $config_file: $!";

  my %config;
  my %is_multivalue = map {; $_ => 1 }
                      qw(also_mirror module_filters path_filters);

  $config{$_} = [] for keys %is_multivalue;

  while (<$config_fh>) {
    chomp;
    next if /\A\s*\Z/sm;

    if (/\A(\w+):\s*(\S.*?)\s*\Z/sm) {
      my ($key, $value) = ($1, $2);

      if ($is_multivalue{ $key }) {
        push @{ $config{$key} }, split /\s+/, $value;
      } else {
        $config{ $key } = $value;
      }
    }
  }

  for (qw(also_mirror)) {
    $config{$_} = [ grep { length } @{ $config{$_} } ];
  }

  for (qw(module_filters path_filters)) {
    $config{$_} = [ map { qr/$_/ } @{ $config{$_} } ];
  }

  for (keys %is_multivalue) {
    delete $config{$_} unless @{ $config{$_} };
  }

  return %config;
}

=method config_file

  my $config_file = CPAN::Mini->config_file( { options } );

This routine returns the config file name. It first looks at for the
C<config_file> setting, then the C<CPAN_MINI_CONFIG> environment
variable, then the default F<~/.minicpanrc>, and finally the
F<CPAN/Mini/minicpan.conf>. It uses the first defined value it finds.
If the filename it selects does not exist, it returns false.

OPTIONS is an optional hash reference of the C<CPAN::Mini> config hash.

=cut

sub config_file {
  my ($class, $options) = @_;

  my $config_file = do {
    if (defined eval { $options->{config_file} }) {
      $options->{config_file};
    } elsif (defined $ENV{CPAN_MINI_CONFIG}) {
      $ENV{CPAN_MINI_CONFIG};
    } elsif (defined $class->__homedir_configfile) {
      $class->__homedir_configfile;
    } elsif (defined $class->__default_configfile) {
      $class->__default_configfile;
    } else {
      ();
    }
  };

  return (
    (defined $config_file && -e $config_file)
    ? $config_file
    : ()
  );
}

=head2 remote_from

  my $remote = CPAN::Mini->remote_from( $remote_from, $orig_remote, $quiet );

This routine take an string argument and turn it into a method
call to handle to retrieve the a cpan mirror url from a source.
Currently supported methods:

    cpan     - fetch the first mirror from your CPAN.pm config
    cpanplus - fetch the first mirror from your CPANPLUS.pm config

=cut

sub remote_from {
  my ( $class, $remote_from, $orig_remote, $quiet ) = @_;

  my $method = lc "remote_from_" . $remote_from;

  Carp::croak "unknown remote_from value: $remote_from"
    unless $class->can($method);

  my $new_remote = $class->$method;

  warn "overriding '$orig_remote' with '$new_remote' via $method\n"
    if !$quiet && $orig_remote;

  return $new_remote;
}

=head2 remote_from_cpan

  my $remote = CPAN::Mini->remote_from_cpan;

This routine loads your CPAN.pm config and returns the first mirror in mirror
list.  You can set this as your default by setting remote_from:cpan in your
F<.minicpanrc> file.

=cut

sub remote_from_cpan {
  my ($self) = @_;

  Carp::croak "unable find a CPAN, maybe you need to install it"
    unless eval { require CPAN; 1 };

  CPAN::HandleConfig::require_myconfig_or_config();

  Carp::croak "unable to find mirror list in your CPAN config"
    unless exists $CPAN::Config->{urllist};

  Carp::croak "unable to find first mirror url in your CPAN config"
    unless ref( $CPAN::Config->{urllist} ) eq 'ARRAY' && $CPAN::Config->{urllist}[0];

  return $CPAN::Config->{urllist}[0];
}

=head2 remote_from_cpanplus

  my $remote = CPAN::Mini->remote_from_cpanplus;

This routine loads your CPANPLUS.pm config and returns the first mirror in
mirror list.  You can set this as your default by setting remote_from:cpanplus
in your F<.minicpanrc> file.

=cut

sub remote_from_cpanplus {
  my ($self) = @_;

  Carp::croak "unable find a CPANPLUS, maybe you need to install it"
    unless eval { require CPANPLUS::Backend };

  my $cb = CPANPLUS::Backend->new;
  my $hosts = $cb->configure_object->get_conf('hosts');

  Carp::croak "unable to find mirror list in your CPANPLUS config"
    unless $hosts;

  Carp::croak "unable to find first mirror in your CPANPLUS config"
    unless ref($hosts) eq 'ARRAY' && $hosts->[0];

  my $url_parts = $hosts->[0];
  return $url_parts->{scheme} . "://" . $url_parts->{host} . ( $url_parts->{path} || '' );
}

=head1 SEE ALSO

Randal Schwartz's original article on minicpan, here:

	http://www.stonehenge.com/merlyn/LinuxMag/col42.html

L<CPANPLUS::Backend>, which provides the C<local_mirror> method, which performs
the same task as this module.

=head1 THANKS

Thanks to David Dyck for letting me know about my stupid documentation errors.

Thanks to Roy Fulbright for finding an obnoxious bug on Win32.

Thanks to Shawn Sorichetti for fixing a stupid octal-number-as-string bug.

Thanks to sungo for implementing the filters, so I can finally stop mirroring
bioperl, and Robert Rothenberg for suggesting adding coderef rules.

Thanks to Adam Kennedy for noticing and complaining about a lot of stupid
little design decisions.

Thanks to Michael Schwern and Jason Kohles, for pointing out missing
documentation.

Thanks to David Golden for some important bugfixes and refactoring.

=cut

1;
