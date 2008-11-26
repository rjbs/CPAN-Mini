use 5.006;
use strict;
use warnings;

use inc::Module::Install;

name          ('CPAN-Mini');
author        ('Ricardo SIGNES <rjbs@cpan.org>');
license       ('perl');
all_from      ('lib/CPAN/Mini.pm');

requires(URI => 1);
requires(LWP => 5);
requires('Compress::Zlib' => '1.20');
requires('File::Path'     => '2.04'); # new interface, bugfixes
requires('File::HomeDir'  => '0.57'); # Win32 Support
requires('Pod::Usage'     => '1.00');

extra_tests;

install_script('bin/minicpan');

WriteAll();
