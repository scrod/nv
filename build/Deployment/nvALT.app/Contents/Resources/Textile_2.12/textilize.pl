#!/usr/bin/perl

# use path inside app
use Cwd 'abs_path';
use File::Basename;
BEGIN { push @INC,dirname(abs_path($0)); }

use	Text::Textile qw(textile);

my $text;
{
	local $/;               # Slurp the whole file
	$text = <>;
}
print textile($text);