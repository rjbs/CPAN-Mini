use strict;
use warnings;

package CPAN::Mini;
our $VERSION = '0.560_01';

## no critic RequireCarping

=head1 NAME

CPAN::Mini - create a minimal mirror of CPAN

=head1 VERSION

version 0.560_01

 $Id$

=head1 SYNOPSIS

(If you're not going to do something weird, you probably want to look at the
L<minicpan> command, instead.)

 use CPAN::Mini;

 CPAN::Mini->update_mirror(
   remote => "http://cpan.mirrors.comintern.su",
   local  => "/usr/share/mirrors/cpan",
   trace  => 1
 );

=head1 DESCRIPTION

CPAN::Mini provides a simple mechanism to build and update a minimal mirror of
the CPAN on your local disk.  It contains only those files needed to install
the newest version of every distribution.  Those files are:

=over 4

=item * 01mailrc.txt.gz

=item * 02packages.details.txt.gz

=item * 03modlist.data.gz

=item * the last non-developer release of every dist for every author

=back

=cut

use Carp ();

use File::Basename ();
use File::Copy ();
use File::Find ();
use File::Path ();
use File::Spec ();
use File::Temp ();

use URI ();
use LWP::Simple ();

use Compress::Zlib ();

=head1 METHODS

=head2 update_mirror

 CPAN::Mini->update_mirror(
   remote => "http://cpan.mirrors.comintern.su",
   local  => "/usr/share/mirrors/cpan",
   force  => 0,
   trace  => 1
 );

This is the only method that need be called from outside this module.  It will
update the local mirror with the files from the remote mirror.   

If called as a class method, C<update_mirror> creates an ephemeral CPAN::Mini
object on which other methods are called.  That object is used to store mirror
location and state.

This method returns the number of files updated.

The following options are recognized:

=over 4

=item * C<dirmode>

Generally an octal number, this option sets the permissions of created
directories.  It defaults to 0711.

=item * C<exact_mirror>

If true, the C<files_allowed> method will allow all extra files to be mirrored.

=item * C<force>

If true, this option will cause CPAN::Mini to read the entire module list and
update anything out of date, even if the module list itself wasn't out of date
on this run.

=item * C<skip_perl>

If true, CPAN::Mini will skip the major language distributions: perl, parrot,
and ponie.

=item * C<trace>

If true, CPAN::Mini will print status messages to STDOUT as it works.

=item * C<errors>

If true, CPAN::Mini will warn with status messages on errors.  (default: true)

=item * C<path_filters>

This options provides a set of rules for filtering paths.  If a distribution
matches one of the rules in C<path_filters>, it will not be mirrored.  A regex
rule is matched if the path matches the regex; a code rule is matched if the
code returns 1 when the path is passed to it.  For example, the following
setting would skip all distributions from RJBS and SUNGO:

 path_filters => [
   qr/RJBS/,
   sub { $_[0] =~ /SUNGO/ }
 ]

=item * C<module_filters>

This option provides a set of rules for filtering modules.  It behaves like
path_filters, but acts only on module names.  (Since most modules are in
distributions with more than one module, this setting will probably be less
useful than C<path_filters>.)  For example, this setting will skip any
distribution containing only modules with the word "Acme" in them:

 module_filters => [ qr/Acme/i ]

=item * C<also_mirror>

This option should be an arrayref of extra files in the remote CPAN to mirror
locally.

=item * C<skip_cleanup>

If this option is true, CPAN::Mini will not try delete unmirrored files when it
has finished mirroring

=back

=cut

sub update_mirror {
	my $self  = shift;
	$self = $self->new(@_) unless ref $self;

	# mirrored tracks the already done, keyed by filename
	# 1 = local-checked, 2 = remote-mirrored
	$self->mirror_indices;

	return unless $self->{force} or $self->{changes_made};

  $self->_mirror_extras;

	# now walk the packages list
	my $details = File::Spec->catfile(
    $self->{scratch},
    qw(modules 02packages.details.txt.gz)
  );

	my $gz = Compress::Zlib::gzopen($details, "rb")
    or die "Cannot open details: $Compress::Zlib::gzerrno";

	my $inheader = 1;
	while ($gz->gzreadline($_) > 0) {
		if ($inheader) {
			$inheader = 0 unless /\S/;
			next;
		}

		my ($module, $version, $path) = split;
		next if $self->_filter_module({
			module  => $module,
			version => $version,
			path    => $path,
		});

		$self->mirror_file("authors/id/$path", 1);
	}

  $self->_install_indices;

	# eliminate files we don't need
	$self->clean_unmirrored unless $self->{skip_cleanup};
	return $self->{changes_made};
}

=head2 new

  my $minicpan = CPAN::Mini->new;

This method constructs a new CPAN::Mini object.  Its parameters are described
above, under C<update_mirror>.

=cut

sub new {
	my $class = shift;
	my %defaults = (
    changes_made => 0,
    dirmode      => 0711, ## no critic Zero
    errors       => 1,
    mirrored     => {}
  );

	my $self = bless { %defaults, @_ } => $class;

  $self->{scratch} ||= File::Temp::tempdir(CLEANUP => 1);

	Carp::croak "no local mirror supplied"  unless $self->{local};

  substr($self->{local}, 0, 1, $class->__homedir)
    if substr($self->{local}, 0, 1) eq q{~};

  Carp::croak "local mirror path exists but is not a directory"
    if (-e $self->{local}) and not (-d $self->{local});

  File::Path::mkpath($self->{local}, $self->{trace}, $self->{dirmode})
    unless -e $self->{local};

  Carp::croak "no write permission to local mirror" unless -w $self->{local};

	Carp::croak "no remote mirror supplied" unless $self->{remote};
  Carp::croak "unable to contact the remote mirror"
    unless LWP::Simple::head($self->{remote});

	return $self;
}

=head2 mirror_indices

  $minicpan->mirror_indices;

This method updates the index files from the CPAN.

=cut

sub mirror_indices {
	my $self = shift;

  my @fixed_mirrors = qw(
    authors/01mailrc.txt.gz
    modules/02packages.details.txt.gz
    modules/03modlist.data.gz
  );

  File::Path::mkpath(File::Spec->catdir($self->{scratch}, $_))
    for qw(authors modules);

  for my $path (@fixed_mirrors, @{$self->{also_mirror}}) {
    my $local_file   = File::Spec->catfile($self->{local}, split m{/}, $path);
    my $scratch_file = File::Spec->catfile($self->{scratch}, split m{/}, $path);

    File::Copy::copy($local_file, $scratch_file);

    utime((stat $local_file)[8,9], $scratch_file);

    $self->mirror_file($path, undef, { to_scratch => 1 });
  }
}

sub _mirror_extras {
	my $self = shift;

  for my $path (@{$self->{also_mirror}}) {
    $self->mirror_file($path, undef);
  }
}

sub _install_indices {
	my $self = shift;

  my @fixed_mirrors = qw(
    authors/01mailrc.txt.gz
    modules/02packages.details.txt.gz
    modules/03modlist.data.gz
  );

  for my $path (@fixed_mirrors) {
    my $local_file = File::Spec->catfile($self->{local}, split m{/}, $path);

    unlink $local_file;

    File::Copy::copy(
      File::Spec->catfile($self->{scratch}, split m{/}, $path),
      File::Spec->catfile($self->{local},   split m{/}, $path),
    );

		$self->{mirrored}{$local_file} = 1;
  }
}

=head2 mirror_file

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
    $arg->{to_scratch} ? $self->{scratch} : $self->{local},
    split m{/}, $path
  );

	my $checksum_might_be_up_to_date = 1;

	if ($skip_if_present and -f $local_file) {
		## upgrade to checked if not already
		$self->{mirrored}{$local_file} = 1 unless $self->{mirrored}{$local_file};
	} elsif (($self->{mirrored}{$local_file} || 0) < 2) {
		## upgrade to full mirror
		$self->{mirrored}{$local_file} = 2;

		File::Path::mkpath(
      File::Basename::dirname($local_file),
      $self->{trace},
      $self->{dirmode}
    );

		$self->trace($path);
		my $status = LWP::Simple::mirror($remote_uri, $local_file);

		if ($status == LWP::Simple::RC_OK) {
      utime undef, undef, $local_file if $arg->{update_times};
			$checksum_might_be_up_to_date = 0;
			$self->trace(" ... updated\n");
			$self->{changes_made}++;
		} elsif ($status != LWP::Simple::RC_NOT_MODIFIED) {
			warn( ($self->{trace} ? "\n" : q{})
        . "$remote_uri: $status\n") if $self->{errors};
			return;
		} else {
			$self->trace(" ... up to date\n");
		}
	}

	if ($path =~ m{^authors/id}) { # maybe fetch CHECKSUMS
		my $checksum_path =
			URI->new_abs("CHECKSUMS", $remote_uri)->rel($self->{remote})->as_string;
		if ($path ne $checksum_path) {
			$self->mirror_file($checksum_path, $checksum_might_be_up_to_date);
		}
	}
}

=begin devel

=head2 _filter_module

 next if
   $self->_filter_module({ module => $foo, version => $foo, path => $foo });

This method holds the filter chain logic. C<update_mirror> takes an optional
set of filter parameters.  As C<update_mirror> encounters a distribution, it
calls this method to figure out whether or not it should be downloaded. The
user provided filters are taken into account. Returns 1 if the distribution is
filtered (to be skipped).  Returns 0 if the distribution is to not filtered
(not to be skipped).

=end devel

=cut

sub __do_filter {
	my ($self, $filter, $file) = @_;
	return unless $filter;
	if (ref($filter) eq 'ARRAY') {
		for (@$filter) {
			return 1 if $self->__do_filter($_, $file);
		}
	}
	if (ref($filter) eq 'CODE') {
		return $filter->($file);
	} else {
		return $file =~ $filter;
	}
}

sub _filter_module {
	my $self = shift;
	my $args = shift;

	if ($self->{skip_perl}) {
		return 1 if $args->{path} =~ m{/(?:emb|syb|bio)?perl-\d}i;
		return 1 if $args->{path} =~ m{/(?:parrot|ponie)-\d}i;
		return 1 if $args->{path} =~ m{/(?:kurila)-\d}i;
		return 1 if $args->{path} =~ m{/\bperl-5\.004}i;
		return 1 if $args->{path} =~ m{/\bperl_mlb\.zip}i;
	}

	return 1 if $self->__do_filter($self->{path_filters}, $args->{path});
	return 1 if $self->__do_filter($self->{module_filters}, $args->{module});
	return 0;
}

=head2 file_allowed

  next unless $minicpan->file_allowed($filename);

This method returns true if the given file is allowed to exist in the local
mirror, even if it isn't one of the required mirror files.

By default, only dot-files are allowed.  If the C<exact_mirror> option is true,
all files are allowed.

=cut

sub file_allowed {
	my ($self, $file) = @_;
	return if $self->{exact_mirror};
	return (substr(File::Basename::basename($file),0,1) eq q{.}) ? 1 : 0;
}

=head2 clean_unmirrored

  $minicpan->clean_unmirrored;

This method looks through the local mirror's files.  If it finds a file that
neither belongs in the mirror nor is allowed (see the C<file_allowed> method),
C<clean_file> is called on the file.

=cut

sub clean_unmirrored {
	my $self = shift;

	File::Find::find sub {
		my $file = File::Spec->canonpath($File::Find::name); ## no critic Package
    return unless (-f $file and not $self->{mirrored}{$file});
    return if $self->file_allowed($file);
    $self->trace("cleaning $file ...");
		if ($self->clean_file($file)) {
      $self->trace("done\n");
    } else {
      $self->trace("couldn't be cleaned\n");
    }
	}, $self->{local};
}

=head2 clean_file

  $minicpan->clean_file($filename);

This method, called by C<clean_unmirrored>, deletes the named file.  It returns
true if the file is successfully unlinked.  Otherwise, it returns false.

=cut

sub clean_file {
	my ($self, $file) = @_;

	unless (unlink $file) {
    warn "$file ... cannot be removed: $!\n" if $self->{errors};
    return;
  }
  return 1;
}

=head2 trace

  $minicpan->trace($message);

If the object is mirroring verbosely, this method will print messages sent to
it.

=cut

sub trace {
	my ($self, $message) = @_;
	print "$message" if $self->{trace};
}

=head2 read_config

  my %config = CPAN::Mini->read_config;

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

sub read_config {
  my ($class) = @_;

  my $filename = File::Spec->catfile($class->__homedir, '.minicpanrc');

  return unless -e $filename;

  open my $config_file, '<', $filename
    or die "couldn't open config file $filename: $!";
  
  my %config;
  while (<$config_file>) { 
    chomp;
    next if /\A\s*\Z/sm;
    if (/\A(\w+):\s*(.+)\Z/sm) { $config{$1} = $2; }
  }
  for (qw(also_mirror)) {
    $config{$_} = [ grep { length } split /\s+/, $config{$_}] if $config{$_};
  }
  for (qw(module_filters path_filters)) {
    $config{$_} = [ map { qr/$_/ } split /\s+/, $config{$_} ] if $config{$_};
  }
  return %config;
}

=head2 

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

=head1 AUTHORS

Randal Schwartz <F<merlyn@stonehenge.com>> wrote the original F<minicpan>
script.

Ricardo SIGNES <F<rjbs@cpan.org>> turned Randal's script into a module and CPAN
distribution, and has maintained it since its release as such.

This code was copyrighted in 2004, and is released under the same terms as Perl
itself.

=cut

1;
