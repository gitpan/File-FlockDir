#!/usr/bin/perl -w

# this dummy test file testdata.t must be flockable for tests in use.t to work

use strict;
use Test;
BEGIN { plan tests => 1 }

    ok(1);

exit;
__END__
