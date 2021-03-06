#!/nfs/disk100/wormpub/bin/perl -w
#
# make_keysets.pl
#
# dl 021025
#
# Usage : make_keysets.pl [-options]
#
# Last edited by: $Author: mh6 $
# Last edited on: $Date: 2014-10-22 14:23:27 $

#################################################################################
# variables                                                                     #
#################################################################################

use strict;                                      
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Getopt::Long;
use Carp;
use Log_files;
use Storable;
use IO::Handle;
use Socket;


##############################
# command-line options       #
##############################

my ($help, $debug, $test, $verbose, $store, $wormbase);

use vars qw/ $all $rnai $history $pcr $touched $noload $debug $help /;

GetOptions (
	    "all"       => \$all,
	    "rnai"      => \$rnai,
	    "pcr"       => \$pcr,
	    "touched"   => \$touched,
	    "history=s" => \$history,
	    "noload"    => \$noload,
	    "test"      => \$test,
	    "debug=s"   => \$debug,
	    "help"      => \$help,
	    "verbose"   => \$verbose,
	    "store:s"   => \$store,
	    );

if ( $store ) {
  $wormbase = retrieve( $store ) or croak("Can't restore wormbase from $store\n");
} else {
  $wormbase = Wormbase->new( -debug   => $debug,
                             -test    => $test,
			     );
}

# Display help if required
&usage("Help") if ($help);

# in test mode?
if ($test) {
  print "In test mode\n" if ($verbose);

}

# establish log file.
my $log = Log_files->make_build_log($wormbase);


##############################
# Paths etc                  #
##############################

our $tace     = $wormbase->tace;    # tace executable path
our $dbpath   = $wormbase->autoace; # Database path (live runs)
our $outpath  = "$dbpath/acefiles"; # Output directory

# Use current_DB if you are testing 
$dbpath   = $wormbase->databases('current') if ($test);        # Database path (test runs)
print "Database = ${dbpath}\n" if ($debug);

#################################################
# series of if loops for each keyset to be made #
#################################################

# CDS with RNAi
if (($rnai) || ($all)) {
    print "Tace query for CDS_with_RNAi\t" if ($debug);
    my $command ="nosave\nquery find elegans_CDS where RNAi_result\nlist -a\nquit\n";
    &tace_it($command,'CDS_with_RNAi');
    print "....load into db\t" if ($debug);
    &load_it('CDS_with_RNAi','keyset_lists') unless ($noload);
    print "...hasta luego\n\n" if ($debug);
}

# CDS with PCR_product
if (($pcr) || ($all)) {
    print "Tace query for CDS_with_PCR_product\t" if ($debug);
    my $command ="nosave\nquery find elegans_CDS where Corresponding_PCR_product\nlist -a\nquit\n";
    &tace_it($command,'CDS_with_PCR_product');
    print "....load into db\t" if ($debug);
    &load_it('CDS_with_PCR_product','keyset_lists') unless ($noload);
    print "...hasta luego\n\n" if ($debug);
}

# CDS with transcript_evidence
if (($touched) || ($all)) {
    print "Tace query for CDS_with_transcript_evidence\t" if ($debug);
    my $command ="nosave\nquery find elegans_CDS where Matching_cDNA\nlist -a\nquit\n";
    &tace_it($command,'CDS_with_transcript_evidence');
    print "....load into db\t" if (($debug) && (!$noload));
    &load_it('CDS_with_transcript_evidence','keyset_lists') unless ($noload);
    print "...hasta luego\n\n" if ($debug);
}

# wormpep histories
if ($history) {
  print "Generating wormpep_mods release files\n" if ($debug);
  my @releases;
  my $fr_dir = $wormbase->ftp_site . '/FROZEN_RELEASES/';
  my @rdirs = glob("$fr_dir/WS*");
  my $rdirs;
  foreach $rdirs(@rdirs){
    if ($rdirs =~ /WS(\d+)$/){
      push (@releases,$1);
    }
  }
  push (@releases,$history-1);

  foreach my $i (@releases) {
    my $wsname = "wormpep_mods_since_WS" . $i;
    (print "Tace query for " . $wsname . "\t") if ($debug);
    my $command ="nosave\nquery find wormpep where history AND NEXT > $i\nlist -a\nquit\n";
    &tace_it($command,$wsname);
    print "....load into db\t" if ($debug);
    &load_it($wsname,'keyset_lists') unless ($noload);
  }
  print "calculated keysets of changed wormpep entries\n\n";
}

my $misc_static_dir = $wormbase->misc_static;
$wormbase->load_to_database($dbpath, "$misc_static_dir/represent_clone.ace", "clone_check", $log) if $all;


$log->mail();
print "Finished.\n" if ($verbose);
exit(0);

#################
## SUBROUTINES ##
#################

sub tace_it {
    my ($command,$name) = @_;
    my @results if ($debug);
    
    open (OUTPUT, ">$outpath/$name.ace") || die "Can't open the output file\n";
    open (TACE,"echo '$command' | $tace $dbpath |");
    while (<TACE>) { 
	next if /\/\//;
	next if /acedb\>/;
	next if ($_ eq "");
	s/KeySet : Answer_1/Keyset : $name/g;
	push (@results,$_) if ($debug);
	print OUTPUT;
    }
    close TACE;
    close OUTPUT;

    return (@results) if ($debug);
}
#_ end of tace_it _#


sub load_it {
    my ($name,$user) = @_;

    $wormbase->load_to_database($dbpath, "$outpath/$name.ace", $user, $log);

}
#_ end of load_it _#

#######################################################################
# Help and error trap outputs                                         #
#######################################################################

sub usage {
    my $error = shift;

    if ($error eq "No_WormBase_release_number") {
        # No WormBase release number file
        print "The WormBase release number cannot be parsed\n";
        print "Check File: $dbpath/wspec/database.wrm\n\n";
        exit(0);
    }
    elsif ($error eq "help") {
        # Normal help menu
        exec ('perldoc',$0);
    }
}




  
__END__

=pod

=head2   NAME - make_keysets.pl

=head1 USAGE

=over 4

=item make_keysets.pl [-options]

=back

make_keysets.pl is a wee perl script to drive acedb queries via tace which
result in a keyset of objects. The keyset is then loaded back into the
database. These keysets act as a extendable version of the subclass methodology
which can be delicately configured.

make_keysets.pl  mandatory arguments:

=over 4

=item none, (but it won't do anything)

=back

make_keysets.pl OPTIONAL arguments:

=over 4

=item B<-all,> Make all of the following keysets

=item B<-rnai,> CDS sequences with RNAi experimental data

=item B<-pcr,> CDS sequences which are amplified within PCR_product objects

=item B<-touched,> CDS sequences with partial/full transcript evidence

=item B<-history XX,> wormpep accessions touched since release of wormpepXX

=item B<-noload,> create keysets but do not load them into the database

=item B<-debug,> verbose debug mode

=item B<-help,> these help pages

=back

=head1 AUTHOR (& person to blame)

=over 4

=item Dan Lawson dl1@sanger.ac.uk

=back

