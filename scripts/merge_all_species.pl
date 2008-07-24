#/software/bin/perl -w
#
# Last updated by: $Author: mh6 $
# Last updated on: $Date: 2008-07-24 15:36:03 $

#################################################################################
# Variables                                                                     #
#################################################################################

use strict;
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Getopt::Long;
use Log_files;
use Storable;
use LSF RaiseError => 0, PrintError => 1, PrintOutput => 0;
use LSF::JobManager;

##############################
# command-line options       #
##############################

my $debug;      # Debug mode, verbose output to runner only
my $test;        # If set, script will use TEST_BUILD directory under ~wormpub
my $db;
my $database;
my $basedir;
my $store;

GetOptions (	"debug=s"    => \$debug,
		"database=s" => \$database,
		"db:s"       => \$db,
		"test"       => \$test,
		"store:s"    => \$store,
	   	);
#this script is always run as elegans so no species option req.

my $wormbase;
if( $store ) {
    $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
}
else {
    $wormbase = Wormbase->new( -debug   => $debug,
			       -test    => $test,
			       );
}

my $log = Log_files->make_build_log($wormbase);

my %accessors = $wormbase->species_accessors;

# dump out the files in parallel.
my $lsf =  LSF::JobManager->new();
$log->write_to("Dumping acefile from . . .\n");
foreach my $spDB (values %accessors) {
  $log->write_to("\t".$spDB->full_name('-short' => 1));
  $lsf->submit(-J => $spDB->species, $spDB->build_cmd("make_acefiles.pl -merge"));
}

$lsf->wait_all_children( history => 1 );

$log->write_to("\nFinished writing acefiles\nAbout to load . .\n");
#and then load then one after another.
foreach my $spDB (values %accessors) {
  my @loaded;
  my $dir = $spDB->acefiles."/MERGE/".$spDB->species."/";
  next unless -e $dir;
  push(@loaded,$spDB->species);
  foreach my $file ( &read_dir($dir) ) {
    $wormbase->load_to_database($wormbase->orgdb, $file, "merge_all_species", $log);
  }
  $log->write_to("\tloaded ".join(', ',@loaded)." in to ".$wormbase->orgdb."\n");
}

$log->write_to("\nNow loading blast data\n");
foreach my $spDB (values %accessors) {
  my @blastfiles = qw( SPECIES_blastp.ace SPECIES_blastx.ace worm_ensembl_SPECIES_interpro_motif_info.ace worm_ensembl_SPECIES_motif_info.ace);
  foreach my $f (@blastfiles){
    my $file = $f;		# don't use $f as it is a reference to the array element
    my $species = $spDB->species;
    $file =~ s/SPECIES/$species/;
    if (-e $sbDB->acefiles."/$file") {
      $log->write_to("Loading: $file\n");
      $wormbase->load_to_database($wormbase->orgdb, $spDB->acefiles."/$file", "merge_all_species", $log);
    } else {
      $log->write_to("WARNING: Can't find $file\n");
    }
  }
}

$log->mail;

exit;
	
sub read_dir {
  my $dir = shift;
  opendir (DIR,$dir) or $log->log_and_die("cant open directory $dir\n");
  $log->write_to("\treading $dir\n");
  my @files = readdir DIR;
  my @to_load;
  foreach my $file ( @files ) {
    next if( $file eq '.' or $file eq '..');
    if( (-T $dir."/".$file) and substr($file,-3,3 ) eq "ace" ) {
      push (@to_load, "$dir"."$file");
    }
  }
  close DIR;
  return @to_load;
}
	
	
	
