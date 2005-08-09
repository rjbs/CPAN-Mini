use 5.006;
use ExtUtils::MakeMaker;

WriteMakefile(
	'NAME'         => 'CPAN::Mini',
	'VERSION_FROM' => 'lib/CPAN/Mini.pm',
	'EXE_FILES'    => [ 'bin/minicpan' ],
	'PREREQ_PM'    => {
		'Compress::Zlib' => '1.20',
		'Pod::Usage'     => 1,
		'LWP' => 5,
		'URI' => 1,
	},
	'PREREQ_PRINT' => 1
);
