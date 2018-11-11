#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More tests => 27;

use Digest::MD5;
use File::Basename;
use IPC::Open3;
use Symbol 'gensym';

my $opustags = '../opustags';
BAIL_OUT("$opustags does not exist or is not executable") if (! -x $opustags);

my $t = dirname(__FILE__);

sub opustags {
	my %opt;
	%opt = %{pop @_} if ref $_[-1];
	my ($pid, $pin, $pout, $perr);
	$perr = gensym;
	$pid = open3($pin, $pout, $perr, $opustags, @_);
	binmode($pin, $opt{mode} // ':utf8');
	binmode($pout, $opt{mode} // ':utf8');
	binmode($perr, ':utf8');
	local $/;
	print $pin $opt{in} if defined $opt{in};
	close $pin;
	my $out = <$pout>;
	my $err = <$perr>;
	waitpid($pid, 0);
	[$out, $err, $?]
}

####################################################################################################
# Tests related to the overall opustags executable, like the help message.
# No Opus file is manipulated here.

my $usage = opustags();
$usage->[0] =~ /^([^\n]*+)/;
my $version = $1;
like($version, qr/^opustags version (\d+\.\d+\.\d+)/, 'get the version string');

is_deeply($usage, [<<"EOF", "", 0], 'no options show the usage');
$version
Usage: opustags --help
       opustags [OPTIONS] FILE
       opustags OPTIONS FILE -o FILE
EOF

my $help = <<"EOF";
$version

Usage: opustags --help
       opustags [OPTIONS] FILE
       opustags OPTIONS FILE -o FILE

Options:
  -h, --help              print this help
  -o, --output            write the modified tags to a file
  -i, --in-place [SUFFIX] use a temporary file then replace the original file
  -y, --overwrite         overwrite the output file if it already exists
  -d, --delete FIELD      delete all the fields of a specified type
  -a, --add FIELD=VALUE   add a field
  -s, --set FIELD=VALUE   delete then add a field
  -D, --delete-all        delete all the fields!
  -S, --set-all           read the fields from stdin

See the man page for extensive documentation.
EOF

is_deeply(opustags('--help'), [$help, '', 0], '--help displays the help message');
is_deeply(opustags('-h'), [$help, '', 0], '-h displays the help message too');

is_deeply(opustags('--derp'), ['', <<"EOF", 256], 'unrecognized option shows an error');
$opustags: unrecognized option '--derp'
EOF

####################################################################################################
# Test the main features of opustags on an Ogg Opus sample file.

sub md5 {
	my ($file) = @_;
	open(my $fh, '<', $file) or return;
	my $ctx = Digest::MD5->new;
	$ctx->addfile($fh);
	$ctx->hexdigest
}

is(md5("$t/gobble.opus"), '111a483596ac32352fbce4d14d16abd2', 'the sample is the one we expect');
is_deeply(opustags("$t/gobble.opus"), [<<'EOF', '', 0], 'read the initial tags');
encoder=Lavc58.18.100 libopus
EOF

unlink('out.opus');
is_deeply(opustags("$t/gobble.opus", '-o', 'out.opus'), ['', '', 0], 'copy the file without changes');
is(md5('out.opus'), '111a483596ac32352fbce4d14d16abd2', 'the copy is faithful');

# empty out.opus
{ my $fh; open($fh, '>', 'out.opus') and close($fh) or die }
is_deeply(opustags("$t/gobble.opus", '-o' , 'out.opus'), ['', <<'EOF', 256], 'refuse to override');
'out.opus' already exists (use -y to overwrite)
EOF
is(md5('out.opus'), 'd41d8cd98f00b204e9800998ecf8427e', 'the output wasn\'t written');

is_deeply(opustags(qw(out.opus -o out.opus)), ['', <<'EOF', 256], 'output and input can\'t be the same');
error: the input and output files are the same
EOF

is_deeply(opustags("$t/gobble.opus", '-o', 'out.opus', '--overwrite'), ['', '', 0], 'overwrite');
is(md5('out.opus'), '111a483596ac32352fbce4d14d16abd2', 'successfully overwritten');

is_deeply(opustags(qw(--in-place out.opus -a A=B --add=A=C --add), "TITLE=Foo Bar",
                   qw(--delete A --add TITLE=七面鳥 --set encoder=whatever -s 1=2 -s X=1 -a X=2 -s X=3)),
          ['', '', 0], 'complex tag editing');
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'check the footprint');

is_deeply(opustags('out.opus'), [<<'EOF', '', 0], 'check the tags written');
A=B
A=C
TITLE=Foo Bar
TITLE=七面鳥
encoder=whatever
1=2
X=1
X=2
X=3
EOF

is_deeply(opustags(qw(out.opus -d A -d foo -s X=4 -a TITLE=gobble -d TITLE)), [<<'EOF', '', 0], 'dry editing');
encoder=whatever
1=2
X=4
TITLE=gobble
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(-i out.opus -a fatal=yes -a FOO -a BAR)), ['', <<'EOF', 256], 'bad tag with --add');
invalid comment: 'FOO'
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(-i out.opus -s fatal=yes -s FOO -s BAR)), ['', <<'EOF', 256], 'bad tag with --set');
invalid comment: 'FOO'
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(out.opus --delete-all -a OK=yes)), [<<'EOF', '', 0], 'delete all');
OK=yes
EOF

is_deeply(opustags(qw(out.opus --set-all -a A=B -s X=Z -d OK), {in => <<'END_IN'}), [<<'END_OUT', '', 0], 'set all');
OK=yes again
ARTIST=七面鳥
A=A
X=Y
END_IN
OK=yes again
ARTIST=七面鳥
A=A
X=Y
A=B
X=Z
END_OUT

is_deeply(opustags(qw(out.opus -S), {in => <<'END_IN'}), [<<'END_OUT', <<'END_ERR', 0], 'set all with bad tags');
whatever

# thing
!
wrong=yes
END_IN
wrong=yes
END_OUT
warning: skipping malformed tag
warning: skipping malformed tag
warning: skipping malformed tag
END_ERR

sub slurp {
	my ($filename) = @_;
	local $/;
	open(my $fh, '<', $filename);
	binmode($fh);
	my $data = <$fh>;
	$data
}

my $data = slurp 'out.opus';
is_deeply(opustags('-', '-o', '-', {in => $data, mode => ':raw'}), [$data, '', 0], 'read opus from stdin and write to stdout');

unlink('out.opus');
