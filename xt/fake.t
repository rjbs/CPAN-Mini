#!perl
use strict;
use warnings;

use File::Find::Rule;
use File::Spec;
use File::Temp qw(tempdir);
use CPAN::Mini;

use Test::More;

my $tempdir = tempdir(CLEANUP => 1);

CPAN::Mini->update_mirror(
  remote => "http://fakecpan.org/fake/minicpan/1.001/cpan",
  local  => $tempdir,
  log_level  => 'fatal',
);

pass("performed initial mirror");

CPAN::Mini->update_mirror(
  remote => "http://fakecpan.org/fake/minicpan/1.002/cpan",
  local  => $tempdir,
  log_level  => 'fatal',
);

pass("performed mirror update");

my @files = File::Find::Rule->file->in($tempdir);
$_ = File::Spec->abs2rel($_, $tempdir) for @files;

my @want = qw(
  RECENT
  authors/01mailrc.txt.gz
  authors/id/O/OP/OPRIME/Bug-Gold-8.91.tar.gz
  authors/id/O/OP/OPRIME/CHECKSUMS
  authors/id/O/OP/OPRIME/XForm-Rollout-1.00.tar.gz
  authors/id/X/XY/XYZZY/CHECKSUMS
  authors/id/X/XY/XYZZY/Hall-MtKing-undef.tar.gz
  authors/id/X/XY/XYZZY/Y-2.tar.gz
  modules/02packages.details.txt.gz
  modules/03modlist.data.gz
);

is_deeply(
  [ sort @files ],
  [ sort @want  ],
  "we end up with just the files we expect",
);

done_testing;
