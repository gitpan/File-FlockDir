package File::FlockDir;
# File::FlockDir.pm

sub Version { $VERSION; }
$VERSION = sprintf("%d.%02d", q$Revision: 1.02 $ =~ /(\d+)\.(\d+)/);

# Copyright (c) 1999, 2000 William Herrera. All rights reserved.
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself. Also, see the CREDITS.

use strict;
use Exporter;
use vars qw(@ISA @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT_OK = qw(open close flock
	$Max_SH_Processes $Check_Interval $Assume_LockDir_Zombie_Minutes);

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

use vars qw(%handles_to_names %handles_to_SH_netlocks %locked_SH %locked_EX
		$Max_SH_Processes $Check_Interval $Assume_LockDir_Zombie_Minutes);
$Max_SH_Processes ||= 20; # predefined or maximum of 20 LOCK_SH processes per file
$Check_Interval ||= 2;    # predefined or about 2 sec. between checks while blocked
# This is the timeout for eliminating dead lockdir entries in minutes.
#   One week is the default; for one day, set to 1440, for forever, set to 0.
$Assume_LockDir_Zombie_Minutes ||= 10080; 

# The File::LockDir module required below is available at 
# ftp.oreilly.com/examples/perl/cookbook if not included with
# this module's distribution.
use File::LockDir qw(nflock nunflock);

use Carp;

# override open to save pathname for the handle
sub open (*;$) {
    my $fh = shift;
    my $spec = shift;
    my $retval;
    no strict 'refs';
    $retval = CORE::open(*$fh, $spec); 
    # hack for > 5.005 compatibility...
    eval('*' . (caller(0))[0] . '::' . $fh . '= $fh;');
    use strict 'refs';
    if($retval) {
        $spec =~ /\A[\s+<>]*(.+)\s*/; 
        if($1) {
            my $t = $1;
            # FATxx File::Basename module file system bug workaround
            $t =~ s|:[\\/]([^\\/]*\Z)|:/../$1|;
            $handles_to_names{$fh} = $t 
                          unless($handles_to_names{$fh});
        }
        else { carp("syntax error in File::FlockDir open for $spec\n"); }
    }    
    return $retval;    
}


# override perl close
sub close (*) {
    my $fh = shift || select ; # for close(FH);  or  close;
    if($handles_to_names{$fh}) { 
        $locked_SH{$fh} = 1 if($locked_SH{$fh}); 
        __unlock($fh, 1 | 2);  # release both SH and EX locks
        delete $handles_to_names{$fh};
    }
    no strict 'refs';
    return CORE::close(*$fh);  # delegate rest of close to regular close
    use strict 'refs';
}


# override perl flock
sub flock (*;$) {    
    my $fh = shift;
    my $lock = shift; 
    my($s, $t, $i);
    if ($lock & 8) {
        return __unlock($fh, $lock);
    }
    elsif($lock & 1) { 
        $s = $handles_to_names{$fh}; # fetch file name
        if($s) {
            $t = $s . 'EX';
            $t =~ s|:[\\/]([^\\/]*\Z)|:/../$1|;
            __expire_zombies($t);
            while (!nflock($t, 1)) {	
                return if($lock & 4); # non-blocking
                sleep $Check_Interval - 1;            
            }
            if($locked_SH{$fh}) {
                $locked_SH{$fh}++;  
            }
            else {
                for($i = 0; $i < $Max_SH_Processes; ++$i) {
                    $t = $s . 'SH' . $i;
                    if(nflock($t, 1)) {   
                        $handles_to_SH_netlocks{$fh} = $t;
                        $locked_SH{$fh} = 1;
                        last;
                    }
                    else { __expire_zombies($t) }
                }
            }       
            nunflock($s . 'EX');  # release LOCK_EX 
        }
    } 
    elsif($lock & 2) {
        $s = $handles_to_names{$fh};
        if($s) {              
            $t = $s . 'EX';
            __expire_zombies($t);
            while (!nflock($t, 1)) { 
                return if($lock & 4); # non-blocking
                sleep $Check_Interval - 1;            
            }
            for($i = 0; $i < $Max_SH_Processes; ++$i) {
                $t = $s . 'SH' . $i;
                __expire_zombies($t);
                while(!nflock($t, 1)) { # failed?                     
                    if ($lock & 4) { # non-blocking
                        while(--$i >= 0) { nunflock($s . 'SH'. $i) }
                        nunflock($s . 'EX');
                        return; # failure
                    }
                    sleep $Check_Interval - 1; 
                }
            }           
            $locked_EX{$fh} = $s; # keep exclusive lock name
            while($i >= 0)  { nunflock($s . 'SH' . $i--) } 
        }
    } 
    else { 
        carp "Bad second argument ( $lock ) for flock";
        return;
    }   
    return 1;  
}


# "private" helper function __unlock
sub __unlock {
    my $fh = shift;
    my $lock = shift;
    my $success = 1;
    my $s;
    if ( ($lock & 1) && $locked_SH{$fh} ) {
        if (--$locked_SH{$fh} <= 0) {
            $s = $handles_to_SH_netlocks{$fh};
            if($s) {
                nunflock($s) or $success = 0;
                delete $handles_to_SH_netlocks{$fh};
            }
            delete $locked_SH{$fh};
        }
    }
    if ( ($lock & 2) && $locked_EX{$fh} ) {
        $s = $handles_to_names{$fh};
        if($s) {
            nunflock($s . 'EX') or $success = 0; # can't remove a dir so FALSE return
        }
        delete $locked_EX{$fh};
    }
    if($success) { return 1 } else { return }
}

# "private" helper function __expire_zombies
# for more info read the code in the File::LockDir package
sub __expire_zombies {
    return if $Assume_LockDir_Zombie_Minutes <= 0;
    my $lock = shift;
    my $lockname = File::LockDir::name2lock($lock);
    my @sa = stat("$lockname/owner");
    if(@sa && (time - $sa[9])/60 > $Assume_LockDir_Zombie_Minutes) {
        carp( "Removing expired FlockDir $lock set on " . scalar localtime($sa[9]) );
        nunflock($lock) or croak "Cannot remove $lock: $!";
    }
}     


# default cleanup to avoid leftover temp directories
END {
    my $fh;
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

May be slow compared to unix flock(). This is mainly due to the fact
it depends upon non-buffered disk writes (directory creation) for its 
implementation. May be speeded up somewhat by importing and setting 
the variable I<$Max_SH_Processes> to a smaller value as long as no more 
than a few processes will be using shared locks at a time on any one file.

=item *

Abnormal termination may leave File::LockDir entries still on 
the drive. This means the directory locks set by File::LockDir 
may have to be removed after a system crash to prevent the module 
from assuming that files locked at the time of the crash are still 
locked later. This may be partially overcome by importing and setting the 
variable I<$Assume_LockDir_Zombie_Minutes> to a value equal to the 
maximal number of minutes a lock is to be allowed to exist 
(defaults to one week or 10040 minutes).

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

