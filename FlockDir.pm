
sub Version { $VERSION; }
$VERSION = sprintf("%d.%02d", q$Revision: 0.93 $ =~ /(\d+)\.(\d+)/);

package File::FlockDir;
# File::FlockDir.pm

# Copyright (c) 1999 William Herrera. All rights reserved.
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself. Also, see the CREDITS.

use strict;
use Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(open close flock);

# see perlsub under "Overriding Builtin Functions" regarding
# the use (when needed to implement flock used by a I<different> 
# package than the importing package) of the syntax
# use File::FlockDir qw(GLOBAL_open GLOBAL_close GLOBAL_flock)
sub import {
    my $pkg = shift;
    return unless @_;
    my $sym = shift;
    my $where = ($sym =~ s/^GLOBAL_// ? 'CORE::GLOBAL' : caller(0));
    $pkg->export($where, $sym, @_);
}

use vars qw($Max_SH_Processes $Check_Interval %handles_to_names 
            %handles_to_SH_netlocks %locked_SH %locked_EX);
$Max_SH_Processes ||= 20; # predefined or 20 LOCK_SH processes per file
$Check_Interval ||= 2;    # predefined or 2 sec. between checks while blocked

# The File::LockDir module required below is available at 
# ftp.oreilly.com/examples/perl/cookbook if not included with
# this module's distribution.
use File::LockDir qw(nflock nunflock);

use Carp;

# the module archive File-PathConvert-xxx is on CPAN
use File::PathConvert qw(&rel2abs);

# override open to save pathname for the handle
sub open (*;$) {
    my($fh) = shift;
    my($spec) = shift;
    my($retval) = CORE::open(*$fh, $spec); 
    if($retval) {
        $spec =~ /\A[\s+<>]*(.+)/; 
        if($1) {
            $handles_to_names{$fh} = rel2abs($1) 
                          unless($handles_to_names{$fh});
        }
        else { carp("syntax error in File::FlockDir open for $spec\n"); }
    }    
    return $retval;    
}

# override perl close
sub close (*) {
    my($fh) = shift || select ; # for close(FH);  or  close;
    if(handles_to_names{$fh}) { 
        $locked_SH{$fh} = 1 if($locked_SH{$fh}); 
        __unlock($fh, 1 | 2);  # release both SH and EX locks
        delete $handles_to_names{$fh};
    }
    return CORE::close(*$fh);  # delegate rest of close to regular close
}

# override perl flock
sub flock (*;$) {    
    my($fh) = shift;
    my($lock) = shift; 
    my($s, $t, $i);
    my($retval) = 0;
    return __unlock($fh, $lock) if ($lock & 8);
    if($lock & 1) { 
        $s = $handles_to_names{$fh}; # fetch file name
        if($s) {              
            while (!nflock($s . 'EX', 1)) {
                return if($lock & 4); # non-blocking
                sleep $Check_Interval - 1;            
            }
            if($locked_SH{$fh}) {
                $locked_SH{$fh}++;  
                $retval |= 1; # success
            }
            else {
                for($i = 0; $i < $Max_SH_Processes; ++$i) {
                    $t = $s . 'SH' . $i;
                    if(nflock($t, 0)) {                      
                        $handles_to_SH_netlocks{$fh} = $t;
                        $locked_SH{$fh} = 1;
                        $retval |= 1;  # success
                        last;
                    }
                }
            }       
            nunflock($s . 'EX');  # release LOCK_EX 
        }
    } 
    if($lock & 2) {
        $s = $handles_to_names{$fh};
        if($s) {              
            while (!nflock($s . 'EX', 1)) { 
                return if($lock & 4); # non-blocking
                sleep $Check_Interval - 1;            
            }
            for($i = 0; $i < $Max_SH_Processes; ++$i) {
                $t = $s . 'SH' . $i;
                while(!nflock($t, 1)) { # failed?                     
                    if ($lock & 4) { # non-blocking
                        while(--$i >= 0) { nunflock($s . 'SH'. $i); }
                        nunflock($s . 'EX');
                        return;
                    }
                    sleep $Check_Interval - 1; 
                }
            }           
            $locked_EX{$fh} = $s; # keep exclusive lock name
            while($i >= 0)  { nunflock($s . 'SH' . $i--); } 
            $retval |= 2;  # success
        }
    } 
    return $retval;  # 1 for LOCK_SH, 2 for LOCK_EX, 3 for both set.
}

# "private" helper function __unlock
sub __unlock {
    my($fh) = shift;
    my($lock) = shift;
    my($s);
    if ( ($lock & 1) && $locked_SH{$fh} ) {
        if (--$locked_SH{$fh} <= 0) {
            $s = $handles_to_SH_netlocks{$fh};
            if($s) {
                nunflock($s);                
                delete $handles_to_SH_netlocks{$fh};
            }
            delete $locked_SH{$fh};
        }
    }
    if ( ($lock & 2) && $locked_EX{$fh} ) {
        $s = $handles_to_names{$fh};
        if($s) {
            nunflock($s . 'EX');
        }
        delete $locked_EX{$fh};
    }
    return $lock;
}

# default cleanup to avoid leftover temp directories
END {
    my ($fh);
    foreach $fh (keys %locked_EX) {
        __unlock($fh, 2);
    }
    foreach $fh (keys %locked_SH) {
        $locked_SH{$fh} = 1;
        __unlock($fh, 1);
    }
}

# end of package
1;

__END__

=head1 NAME

FlockDir - override perl flock() for network or portability purposes

=head1 SYNOPSIS

use File::FlockDir qw (open close flock);

open (FH, ">$path");

flock(FH, 2);

close FH;


=head1 DESCRIPTION

A flock module for Windows9x and other systems lacking 
a good perl flock() function (not platform specific)

Usage:

use File::FlockDir qw (open close flock);

OR (careful)

use File::FlockDir qw (GLOBAL_open GLOBAL_close GLOBAL_flock);

Rationale: flock on Win95/98 is badly broken but
perl code needs to be portable. One way to do
this is to override perl's open(), flock(), and close().
We then get an absolute file specification for all opened 
files and and use it in a hash to create a unique lock for 
the file using the File::LockDir module from I<Perl Cookbook>, 
by Christiansen and Torkington (O'Reilly, 1998). This module may 
be included in the CPAN distribution but belongs to those authors.
New code is deliberately kept at a minimum. As with nflock(),
this will allow flock() to work over a network (usually).

=head1 KNOWN PROBLEMS AND LIMITATIONS

=over 4

=item *

May be slow compared to unix flock().

=item *

Abnormal termination may leave File::LockDir entries still on 
the drive. This means the directory locks set by File::LockDir 
will have to be removed after a system crash to prevent the module 
from assuming that files locked at the time of the crash are still 
locked later.

=item *

Since the implementation creates a subdirectory in the directory
containing the file that you flock(), you must have permission to
create a directory where the file is located in order to flock()
that file over the network.

=back

=head1 CREDITS

I<Perl Cookbook>, by Tom Christiansen and Nathan Torkington.

This module is an extension of I<Perl Cookbook>'s nflock(), in 
chapter 7, section 21 (7.21, pp 264-266).

=head1 AUTHOR

William Herrera <wherrera@lynxview.com>

=cut

