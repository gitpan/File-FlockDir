#!/usr/bin/perl -w

# the file testdata.t must be available as 't/testdata.t' or as 'testdata.t' rel to path

use strict;
use Test;
BEGIN { plan tests => 3 }

use File::FlockDir qw (open close flock); 

my $f1 = 't/testdata.t';
my $f2 = 'testdata.t';
my $f;

if (-f $f1) { $f = $f1; ok(1) } elsif(-f $f2) { $f = $f2; ok(1) } 

if($f) { 
    ok( open(FFILE, $f) );
    flock(FFILE, 2);
    ok( close FFILE ) ;
}

exit;
__END__

