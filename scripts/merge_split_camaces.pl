#!/usr/local/bin/perl5.8.0 -w
#
# merge_split_camaces.pl
# 
# A script to make multiple copies of camace for curation, and merge them back again
#
# Last edited by: $Author: krb $
# Last edited on: $Date: 2004-07-09 15:51:05 $


use strict;
use lib "/wormsrv2/scripts/";
use Wormbase;
use Getopt::Long;


##############################
# command-line options       #
##############################

my $merge;                 # Merging databases
my $split;                 # Splitting databases
my $update;                # Update current database
my $debug;                 # Debug option
my $help;                  # Help menu

GetOptions (
	    "merge"      => \$merge,
	    "split"      => \$split,
	    "update"     => \$update,
	    "help"       => \$help,
	    "debug"      => \$debug
	   );

# Help pod if needed
&usage("Help") if ($help);

our $tace       = &tace;
our $WS_version = &get_wormbase_version;

my $WS_previous = $WS_version - 1;
print "WS_version : $WS_version\tWS_previous : $WS_previous\n" if ($debug);

my @databases; #array to store what splits are to be merged.
my $path_new = ();
my $path_ref = ();
my @classes = ('Transposon', 'Transcript', 'Sequence', 'CDS', 'Feature', 'Pseudogene');

# load @databases array with user database names.
push(@databases,"orig");
push(@databases,"ar2");
push(@databases,"dl1");
push(@databases,"pad");
push(@databases,"krb");

# directory paths
our $current     = "/wormsrv1/camace";
our $directory   = "/nfs/disk100/wormpub/camace_orig/WS${WS_previous}-WS${WS_version}";
our $camace_orig = "/nfs/disk100/wormpub/camace_orig";

## (1) Merge split databases #1 - do the diffs ##
if ($merge) {

  print "Make a new directory : '$directory'\n" if ($debug);
  mkdir ($directory) or die "Failed to create ${directory}\n";

  print "You are merging Data from " . (join '-',@databases) ."\n\n";

  # dumps the Pseudogene, Transcript, Feature and Sequence classes from the database
  &dump_camace;

  ###################################################
  #   All of the raw data is now dumped to files    #
  ###################################################

  #remove 1st element of array
  shift (@databases);
  # run acediff on the files tidy up and reformat the diff files ready to be loaded
  foreach my $database (@databases) {
    foreach my $class (@classes) {
      my $path_new = $directory . "/${class}_${database}.ace";
      my $path_ref = $directory . "/${class}_orig.ace";
      system ("acediff $path_ref $path_new > $directory/${class}_diff_${database}.ace") && die "Failed to run acediff for ${path_new}\n";
      system ("reformat_acediff $directory/${class}_diff_${database}.ace   > $directory/update_${class}_${database}.ace") && die "Failed to run reformat ace file for $directory/${class}_diff_${database}.ace\n";
    }
  }

  print "Phase 1 finished and all files can be found in $directory\n";
}

## (2) synchronises /wormsrv1/camace with the split versions ##
if ($update) {
  shift (@databases);
  &update_camace;
  print "Phase 2 finished wormsrv1/camace is now updated\n";
}

## (3) TransferDB calls to move /wormsrv1/camace to the split databases ##
if ($split) {
  print "Removing old split databases and Copying /wormsrv1/database to the split camaces\n";
  shift (@databases);
  &split_databases;
  print "Phase 3 finished. All ~wormpub split camaces can now be used\n\nCheck all TransferDB log files for \"ended SUCCESSFULLY\"\n";
  exit(0);
}

$0 =~ m/\/*([^\/]+)$/; system ("touch /wormsrv2/logs/history/$1.`date +%y%m%d`");

print "hasta luego\n";

exit(0);

###################################################################################################
###################################################################################################

#(1)dump files from camace splits#
sub dump_camace {
  #dumps out subset of classes from camace splits and processes the files to be loaded back to /wormsrv1/camace
  #array of classes to be dumped
  my $camace_path;
  my $path;

  foreach my $database (@databases) {

    $camace_path = "/nfs/disk100/wormpub/camace_${database}";
    $ENV{'ACEDB'} = $camace_path;

    foreach my $class (@classes) {

      print "dumping $class class from camace_${database}\n";
      $path = "$directory/" . "${class}_${database}.ace";
      &dumpace("$class",$path);
      print "dumped $class class from camace_${database}\n\n";
    }
  }
}

#(1a)data retrieval#
sub dumpace {
  my $class    = shift;
  my $filepath = shift;
  
  my $command = "nosave\nquery find $class\nshow -a -f $filepath\nquit\n";
  
  # dump out from ACEDB
  print "\nFilename: $filepath\n";
  open (TACE,"| $tace") or die "Failed to open database connection\n";
  print TACE $command;
  close TACE;
}

#(2)data upload#
sub loadace {
  my $filepath = shift;
  my $tsuser   = shift;
  my $command = "pparse $filepath\nsave\nquit\n";
  
  # dump out from ACEDB
  print "\nFilename: $filepath\n";
  open (TACE,"| $tace -tsuser $tsuser") or die "Failed to open database connection\n";
  print TACE $command;
  close TACE;
}

#(2a)upload data to wormsrv1/camace#
sub update_camace {
  # upload processed diff files into /wormsrv1/camace
  print "Upload diff files to /wormsrv1/camace";
  $ENV{'ACEDB'} = $current;
  
  foreach my $database (@databases) {
    foreach my $class (@classes) {
      &loadace("$directory/update_${class}_${database}.ace","${database}");
    }
  }
  # uplaod new mRNAs into camace
  print "Upload new mRNAs in /wormsrv1/camace\n";
  &loadace("/nfs/disk100/wormpub/analysis/ESTs/elegans_mRNAs.ace",'NDB_data') or die "Failed to load new mRNA data";
  
  # upload BLAT results to database
  print "Update BLAT results in /wormsrv1/camace\n";
  system ("load_blat2db.pl -all -dbdir $current") && die "Failed to run load_blat2db.pl\n";

  # synchronize the gene -> sequence connections
  print  "Update gene2CDS/Transcript/Pseudogene connections in /wormsrv1/camace\n";
#  system ("cgc_names_for_worm_genes.pl -update_camace") && die "Failed to run cgc_names_for_worm_genes.pl\n";

  #check wormsrv1/camace to see if there are any errors prior to the build starting.
  system ("camcheck.pl") && die "Failed to run camcheck.pl\n";
}

#(3)Data dispersion#
sub split_databases {
  # it has been decided that it is better to remove the database directory to make transfer db more stable #
  # initialise camace_orig and copy data from wormsrv1/camace.
  system("rm -rf /nfs/disk100/wormpub/camace_orig/database") && die "Failed to remove camace_orig/database\n";
  system ("TransferDB.pl -start /wormsrv1/camace -end $camace_orig -split -database -wspec -name camace_orig_WS$WS_version");

  #Do the same for each split database but transfer data from camace_orig.
  foreach my $database (@databases) {
    system("rm -rf /nfs/disk100/wormpub/camace_${database}/database") && die "Failed to remove camace_${database}/database\n";
    system ("TransferDB.pl -start $camace_orig -end ~wormpub/camace_${database} -split -database -wspec -name camace_${database}_WS$WS_version");
  }
  print "CAMACE SPLITS UPDATED\n";
}

sub usage {
  my $error = shift;

  if ($error eq "Help") {
    # Normal help menu
    system ('perldoc',$0);
    exit (0);
  }
}

__END__

=pod

=head2 NAME - merge_split_camaces

=head1 USAGE:

=over 4

=item merge_split_camaces [-options]

=back

merge_split_camaces is a wrapper with options to automate the merging of the
working split copies of camace, load the updates into the current version
of camace (with some additional housekeeping), and finally running the
TransferDB.pl jobs to (re)generate the working split copies of camace.

merge_split_camaces mandatory arguments:

=over 4

=item none

=back

merge_split_camaces optional arguments:

=over 4

=item -merge, Generate diff files from split camace databases
 
=item -update, Upload diff files to /wormsrv1/camace and add BLAT, Locus data

=item -split, Transfer /wormsrv1/camace into split camace databases

=item -help, Help page

=item -debug, Verbose/Debug mode

=back

=head1 RUN REQUIREMENTS:

=back

merge_split_camaces must be able to see the /wormsrv1 disk

=head1 RUN OUTPUT:

=back

=head1 EXAMPLES:

=over 4

=item merge_split_camaces -merge -all 

=back

Dumps the relevant classes from camace_orig and the split databases, runs an
acediff to calculate the changes. This acediff file is then reformated to take
account of the acediff bug.

=head1 AUTHOR - Daniel Lawson

Email dl1@sanger.ac.uk

=cut
