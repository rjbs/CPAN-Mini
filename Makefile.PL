use 5.006;
use ExtUtils::MakeMaker;

WriteMakefile(
	'NAME'         => 'CPAN::Mini',
	'VERSION_FROM' => 'lib/CPAN/Mini.pm',
	'EXE_FILES'    => [ 'bin/minicpan' ],
  LICENSE        => 'perl',
	'PREREQ_PM'    => {
		'URI' => 1,
		'LWP' => 5,
		'Compress::Zlib' => '1.20',
    'File::HomeDir'  => '0.57', # Win32 Support
		'Pod::Usage'     => 1,
	},
	'PREREQ_PRINT' => 1
);
