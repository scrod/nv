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

# Thanks to Sen Haerens for the UTF8 fix
my $textile = new Text::Textile;
$textile->charset('utf-8');
print $textile->process($text);