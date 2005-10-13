use 5.006;
use ExtUtils::MakeMaker;

WriteMakefile(
	'NAME'         => 'CPAN::Mini',
	'VERSION_FROM' => 'lib/CPAN/Mini.pm',
	'EXE_FILES'    => [ 'bin/minicpan' ],
	'PREREQ_PM'    => {
		'URI' => 1,
		'LWP' => 5,
		'Compress::Zlib' => '1.20',
    'File::HomeDir'  => 0,
    ($^O eq 'MSWin32' ? ('File::HomeDir::Win32' => 0) : ()),
		'Pod::Usage'     => 1,
	},
	'PREREQ_PRINT' => 1
);
