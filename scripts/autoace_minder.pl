#!/usr/local/bin/perl5.8.0 -w
#
# autoace_minder
# 
# Originally by Dan Lawson with many, many modifications by the Wormbase crew.
#
# Usage : autoace_minder.pl [-options]
#
# Last edited by: $Author: krb $
# Last edited on: $Date: 2003-09-12 15:39:23 $


#################################################################################
# Initialise variables                                                          #
#################################################################################

use strict;
use lib "/wormsrv2/scripts/";
use Wormbase;
use IO::Handle;
use Getopt::Long;
use vars;
use Carp;

# is this script being run as user wormpub???
&test_user_wormpub;

##############################
# command-line options       #
##############################

my $initial;		# Start the build process 
my $unpack;		# unpack primaries	
my $gffdump;		# dump gff files
my $gffsplit;           # split gff files
my $buildpep;		# Build wormpep
my $buildrna;		# Build wormrna
my $prepare_blat;	# Prepare for blat, copy autoace before blatting, run blat_them_all.pl -dump
my $blat_est;           # run blat for ests
my $blat_mrna;          # run blat for mrnas
my $blat_ost;           # run blat for osts
my $blat_embl;          # run blat for non-Wormbase CDS genes in EMBL
my $blat_nematode;      # run blat for non-C. elegans nematode ESTs
my $blat_all;           # run all five types of blat jobs
my $addblat;		# parse (all) blat files
my $addbriggsae;        # add briggsae ace files
my $addhomol;           # parse similarity data from /ensembl_dump
my $addnematode;        # parse parastic nematode EST file
my $utrs;               # generate UTR dataset
my $map;		# map PCR and RNAi
my $acefile;		# Write .acefiles
my $build;		# Build autoace 
my $builddb;		# Build autoace : DB only
my $buildchrom;		# Build autoace : CHROMOSOMES directory	
my $buildrelease;	# Build autoace : Release directory
my $buildtest;          # Test autoace build
my $agp;		# make/check agp files
my $confirm;            # Confirm gene models (EST|mRNA)
my $ftp;		# Public release to FTP site
my $debug;		# Verbose debug mode
my $help;		# Help/Usage page
my $test;               # Test routine 
my $dbcomp;		# runs dbcomp script
our $am_option;         # track which option has been used (for logging purposes)
our $runtime;           # grab runtime to add to logfiles

GetOptions (
	    "agp"	     => \$agp,
	    "initial"        => \$initial,
	    "unpack"         => \$unpack,
	    "gffdump"        => \$gffdump,
	    "gffsplit"       => \$gffsplit,
	    "buildpep"       => \$buildpep,
	    "buildrna"       => \$buildrna,
	    "prepare_blat"   => \$prepare_blat,
	    "blat_est"       => \$blat_est,
	    "blat_ost"       => \$blat_ost,
	    "blat_mrna"      => \$blat_mrna,
	    "blat_embl"      => \$blat_embl,
	    "blat_nematode"  => \$blat_nematode,
	    "blat_all"       => \$blat_all,
	    "addblat"        => \$addblat,
	    "addbriggsae"    => \$addbriggsae,
	    "addhomol"       => \$addhomol,
	    "addnematode"    => \$addnematode,
	    "utrs"           => \$utrs,
	    "map"            => \$map,
	    "acefile"        => \$acefile,
	    "build"          => \$build,
	    "builddb"        => \$builddb,
	    "buildchrom"     => \$buildchrom,
	    "buildrelease"   => \$buildrelease,
            "buildtest"      => \$buildtest,
	    "confirm"        => \$confirm,
	    "dbcomp"	     => \$dbcomp,
	    "debug"          => \$debug,
	    "help"           => \$help,
	    "h"	             => \$help,
	    "test"           => \$test
);

# Help pod if needed
&usage(0) if ($help);


##############################
# Script variables (run)     #
##############################

my $maintainers = "All";

our $rundate    = `date +%y%m%d`; chomp $rundate;
my $scriptdir   = "/wormsrv2/scripts";                   # specify location of scripts

# build flag path

our %flag = (
	     'A1'  => 'A1:Build_in_progress',
	     'A2'  => 'A2:Updated_WS_version',
	     'A3'  => 'A3:Unpack_FTP_databases',
	     'A4'  => 'A4:Primary_databases_on_wormsrv2',
	     'A5'  => 'A5:Wrote_acefiles_to_wormbase', 
	     'B1'  => 'B1:Made_autoace_database',
	     'B1A' => 'B1a:Errors_in_loaded_acefiles',
	     'B2'  => 'B2:Dump_DNA_files',
 	     'B3'  => 'B3:Made_agp_files',
	     'B4'  => 'B4:Errors_in_agp_files',
	     'B5'  => 'B5:Copy_to_midway',
	     'B6'  => 'B6:BLAT_analysis',
	     'B6_est'      => 'B6a:BLAT_analysis_EST',
	     'B6_mrna'     => 'B6b:BLAT_analysis_mRNA',
	     'B6_embl'     => 'B6c:BLAT_analysis_EMBL',
	     'B6_ost'      => 'B6d:BLAT_analysis_OST',
	     'B6_nematode' => 'B6d:BLAT_analysis_NEMATODE',
	     'B7'  => 'B7:Upload_BLAT_data',
	     'B8'  => 'B8:Upload_wublast_data',
	     'B9'  => 'B9:Upload_briggsae_data',
	     'B10' => 'B10:Generate_UTR_data',
	     'C1'  => 'C1:Dumped_GFF_files',
	     'C2'  => 'C2:Split_GFF_files',
	     'C3'  => 'C3:Map_PCR_products',
	     'C4'  => 'C4:Confirm_gene_models',
	     'D1A' => 'D1:Build_wormpep_initial',
	     'D1'  => 'D1:Build_wormpep_final',
	     'D2'  => 'D2:Update_pepace',
	     'D3'  => 'D3:Add_protein_data_to_autoace',
	     'D4'  => 'D4:Build_wormrna',
	     'Z1'  => 'Z1:Make_autoace_complete'
	     );

our @chrom        = ('I','II','III','IV','V','X');
our $logdir       = "/wormsrv2/autoace/logs";
our $WSver_file   = "/wormsrv2/autoace/wspec/database.wrm";
our $tace         =  &tace;
our ($WS_version,$WS_previous) = &get_WS_version;

# deal with logfile issues
$rundate    = `date +%y%m%d`; chomp $rundate;
our $logfile = "/wormsrv2/logs/autoace_minder.WS${WS_version}.${rundate}.$$";
open (LOG,">$logfile");
LOG->autoflush();
# print logfile header
&logfile_details;

# debug mode modifies $maintainers to reduce e-mail load
($maintainers = "dl1\@sanger.ac.uk") if ($debug);

#__ PREPARE SECTION __#

# A1:Build_in_progress & A2:Updated_WS_version
# Requires: 
&initiate_build    if ($initial);


# A3:Unpack_FTP_databases & A4:Primary_databases_on_wormsrv2
# Requires: A1   
&prepare_primaries if ($unpack);


# A5:Wrote_acefiles_to_wormbase 
# Requires: A1,A4
&make_acefiles     if ($acefile);

#__ BUILD SECTION __#

# B1:Make_autoace_database & B2:Dump_DNA_files
# Requires: A1,A4,A5
&make_autoace           if ($build || $builddb || $buildchrom || $buildrelease);
&test_build             if ($buildtest);


# B3:Make_agp_files
# Requires: A1,A4,A5,B1
&make_agp		if ($agp);


# Add parasitic nematode ESTs
&add_nematode_ESTs      if ($addnematode);

# B5:Copy_to_midway
# Run blat_them_all.pl -dump
# Requires: A1,A4,A5,B1
&prepare_for_blat       if ($prepare_blat);


# B6:Blat_analysis & B7:Upload_BLAT_data
# Requires: A1,A4,A5,B1
&blat_jobs              if ($blat_est || $blat_ost || $blat_embl || $blat_nematode || $blat_all);
&load_blat_files("all") if ($addblat);


# B8:Upload_wublast_data & B9:Upload_briggsae_data
# Requires: A1,A4,A5,B1
&parse_homol_data       if ($addhomol);
&parse_briggsae_data    if ($addbriggsae);


# B10:Generate_UTR_data
# Requires: A1,A4,A5,B1,B6,B7
&generate_utrs          if ($utrs);


#__ PROCESS SECTION __#

# C1:Dumped_GFF_files  
# Requires: A1,A4,A5,B1
&dump_GFFs         if ($gffdump);


# C2:Split_GFF_files   
# Requires: A1,A4,A5,B1
&split_GFFs        if ($gffsplit);


# C3:Map_PCR_products  
# Requires: A1,A4,A5,B1
&map_features      if ($map);


# C4:Confirm_gene_models
# Requires: A1,A4,A5,B1
&confirm_gene_models   if ($confirm);



#__ ANCILLIARY DATA SECTION __#

# D1:Build_wormpep                    
&make_wormpep      if ($buildpep);

# D4:Build_wormrna                    
&make_wormrna      if ($buildrna);


#__ CHECK SECTION __#
&dbcomp		  if ($dbcomp);


#__ RELEASE SECTION __#



##############################################
# close log file and mail $maintainer report #
##############################################

$rundate    = `date +%y%m%d`; chomp $rundate;
print LOG "\n# autoace_minder finished at: $rundate ",&runtime,"\n";
close LOG;

&mail_maintainer("WormBase Report: $am_option",$maintainers,$logfile);

##############################
# hasta luego                #
##############################

exit(0);



#################################################################################
### Subroutines                                                               ###
#################################################################################

#################################################################################
# initiate autoace build                                                        #
#################################################################################
# Requirements : None
#
# Checks       : [01] - Fail if the build_in_progess flag is present.
#
# Does         : [01] - updates the WS version in database.wrm
#              : [02] - writes the WS version to the build_flag (writes to /wormsrv2/autoace/logs)
#              : [03] - writes log file A2:Update_WS_version to /wormsrv2/autoace/logs
#
# Requirements :
#

sub initiate_build {
  $am_option = "-initial";

  local (*FLAG);
  my $cvs_file = "/wormsrv2/autoace/wspec/database.wrm";

  # exit if build_in_progress flag is present
  &usage(10) if (-e "$logdir/$flag{'A1'}");
    
  # commit to new build ..............
  $WS_version = &get_wormbase_version;
    
  # exit if no WS version is returned
  &usage("No_WormBase_release_number") if (!defined($WS_version));
    
  # manipulate to assign last WS release version
  my $WS_new_name = $WS_version +1;
 
#    [move this step to the end of the build procedure]
#    [i.e. clean up after yourself]
#
#    # tidy up the log directory
#    system ("/usr/bin/rm -f $logdir/*:*");

  # make new build_in_process flag
  system ("touch $logdir/$flag{'A1'}");
  open (FLAG, ">>$logdir/$flag{'A1'}"); 
  print FLAG "WS$WS_new_name\n";
  close FLAG;
    
  # make sure that the database.wrm file is younger
  sleep 10;

  # update database.wrm using cvs
  print "Updating $cvs_file to include new WS number - using sed\n\n";
  system ("sed 's/WS${WS_version}/WS${WS_new_name}/' < $cvs_file > ${cvs_file}.new");
  system ("mv /wormsrv2/autoace/wspec/database.wrm.new $cvs_file");
  
  # make a log file in /wormsrv2/autoace/logs
  system ("touch $logdir/$flag{'A2'}");

  # add lines to the logfile
  print LOG "Updated WormBase version number to WS$WS_new_name\n\n";
  print LOG "You are ready to build another WormBase release\n\n";
  print LOG "Please tell camace and geneace curators to update their database to use the new models!!!\n\n";
    
}
#__ end initiate_build __#

#################################################################################
# get_WS_version                                                                #
#################################################################################
# Requirements : [01] - Presence of the database.wrm file in wspec
#              : [02] - WormBase.pm modules
#
# Checks       : [01] - Fail if no WS_version is returned.

# Does         : [01] - checks the build_in_progess flag is older than the version
#              : [02] - assigns last WS version to WS_version - 1

sub get_WS_version {

    $WS_version = &get_wormbase_version;
    
    # exit if no WS version is returned
    &usage("No_WormBase_release_number") if (!defined($WS_version));

    print "$logdir/$flag{'A1'} : " . (-M "$logdir/$flag{'A1'}") . "\n" if ($debug);
    print "$WSver_file : "         . (-M "$WSver_file") . "\n" if ($debug);



    # exit if WS version (database.wrm) is older than build_in_process flag
    # i.e. the WS version has been changed since the start of the build
    # ignore if the A1 flag doesn't exist
    if (-e "$logdir/$flag{'A1'}") {
	&usage(11) if (-M "$logdir/$flag{'A1'}" < -M "$WSver_file");
    }

    # manipulate to assign last WS release version
    $WS_previous = $WS_version -1;
    return($WS_version,$WS_previous);
}
#__ end get_WS_version __#

#################################################################################
# prepare primary databases                                                     #
#################################################################################
#
# Requirements : [01] - Presence of the Primary_databases_used_in_build file
#
# Checks       : [01] - Fail if the build_in_progess flag is absent.
#              : [02] - Fail if the Primary_databases_used_in_build file is absent
#
# Does         : [01] - checks the Primary_database_used_in_build data
#              : [03] - writes log file A2:Update_WS_version to /wormsrv2/autoace/logs

sub prepare_primaries {
  $am_option = "-unpack";
  # exit unless build_in_progress flag is present
  &usage(12) unless (-e "$logdir/$flag{'A1'}");

  # exit if the Primary_databases_used_in_build is absent
  &usage(13) unless (-e "$logdir/Primary_databases_used_in_build");
 
  local (*LAST_VER);
  my ($stlace_date,$brigdb_date,$citace_date,$cshace_date) = &FTP_versions;
  my ($stlace_last,$brigdb_last,$citace_last,$cshace_last) = &last_versions;
  my $options = "";

  # stlace
  print "\nstlace : $stlace_date last_build $stlace_last";
  unless ($stlace_last eq $stlace_date) {
    $options .= " -s $stlace_date";
    print "  => Update stlace";
  }
  
  # brigdb
  print "\nbrigdb : $brigdb_date last_build $brigdb_last";
  unless ($brigdb_last eq $brigdb_date) {
    $options .= " -b $brigdb_date";
    print "  => Update brigdb";
  }
  
  # citace
  print "\ncitace : $citace_date last_build $citace_last";
  unless ($citace_last eq $citace_date) {
    $options .= " -i $citace_date";
    print "  => Update citace";
  }
  
  # cshace
  print "\ncshace : $cshace_date last_build $cshace_last";
  unless ($cshace_last eq $cshace_date) {
    $options .= " -c $cshace_date";
    print "  => Update cshace";
  }
  
  print "\n\nrunning unpack_db.pl $options\n";
  
  # confirm unpack_db details and execute
  unless ($options eq "") {
    print "Do you want to unpack these databases ?\n";
    my $answer=<STDIN>;
    &usage(2) if ($answer ne "y\n");
    
    system ("$scriptdir/unpack_db.pl $options");
  }
  
  # make a unpack_db.pl log file in /logs
  system ("touch $logdir/$flag{'A3'}");
  
  # transfer /wormsrv1/camace to /wormsrv2/camace 
  system("TransferDB.pl -start /wormsrv1/camace -end /wormsrv2/camace -database -name camace")
    && die "Couldn't run TransferDB for camace\n";
  
  # transfer /wormsrv1/geneace to /wormsrv2/geneace 
    system("TransferDB.pl -start /wormsrv1/geneace -end /wormsrv2/geneace -database -name geneace")
      && die "Couldn't run TransferDB for geneace\n";

  #################################################
  # Check that the database have unpack correctly #
  #################################################
    
  # rewrite /wormsrv2/autoace/Primary_databases_used_in_build
  open (LAST_VER, ">$logdir/Primary_databases_used_in_build");
  print LAST_VER "stlace : $stlace_date\n"; 
  print LAST_VER "brigdb : $brigdb_date\n"; 
  print LAST_VER "citace : $citace_date\n"; 
  print LAST_VER "cshace : $cshace_date\n"; 
  close LAST_VER;
  
  # make a unpack_db.pl log file in /logs
  system ("touch $logdir/$flag{'A4'}");
  
}
#__ end of prepare_primaries __#

##################
# FTP_versions   #
##################

sub FTP_versions {

    local (*STLACE_FTP,*BRIGDB_FTP,*CITACE_FTP,*CSHACE_FTP);

    my $stlace_FTP = "/nfs/disk100/wormpub/private_ftp/incoming/stl/stlace_*";
    my $brigdb_FTP = "/nfs/disk100/wormpub/private_ftp/incoming/stl/brigdb_*";
    my $citace_FTP = "/nfs/disk100/wormpub/private_ftp/incoming/caltech/citace_*";
    my $cshace_FTP = "/nfs/disk100/wormpub/private_ftp/incoming/csh/cshl_*";
    my ($stlace_date,$brigdb_date,$citace_date,$cshace_date);

    # stlace
    open (STLACE_FTP, "/bin/ls -t $stlace_FTP |")  || die "cannot open $stlace_FTP\n";
    while (<STLACE_FTP>) { chomp; (/\_(\d+)\-(\d+)\-(\d+)\./); $stlace_date = substr($1,-2).$2.$3; last; }
    close STLACE_FTP; 

    # brigdb
    open (BRIGDB_FTP, "/bin/ls -t $brigdb_FTP |") || die "cannot open $brigdb_FTP\n";
    while (<BRIGDB_FTP>) { chomp; (/\_(\d+)\-(\d+)\-(\d+)\./); $brigdb_date = substr($1,-2).$2.$3; last; }
    close BRIGDB_FTP; 

    # citace
    open (CITACE_FTP, "/bin/ls -t $citace_FTP |") || die "cannot open $citace_FTP\n";
    while (<CITACE_FTP>) { chomp; (/\_(\d+)\-(\d+)\-(\d+)\./); $citace_date = substr($1,-2).$2.$3; last; }
    close CITACE_FTP; 

    # cshace
    open (CSHACE_FTP, "/bin/ls -t $cshace_FTP |") || die "cannot open $cshace_FTP\n";
    while (<CSHACE_FTP>) { chomp; (/\_(\d+)\-(\d+)\-(\d+)\./); $cshace_date = substr($1,-2).$2.$3; last; }
    close CSHACE_FTP; 
    
    # return current dates as 6-figure string
    return($stlace_date,$brigdb_date,$citace_date,$cshace_date);
}

#####################################################################################################################

sub last_versions {
    
    local (*LAST_VER);
    my ($stlace_last,$brigdb_last,$citace_last,$cshace_last);

    open (LAST_VER, "<$logdir/Primary_databases_used_in_build") || usage("Primary_databases_file_error");
    while (<LAST_VER>) {
	$stlace_last = $1 if /^stlace \: (\d+)$/;
	$brigdb_last = $1 if /^brigdb \: (\d+)$/;
	$citace_last = $1 if /^citace \: (\d+)$/;
	$cshace_last = $1 if /^cshace \: (\d+)$/;
    }
    close LAST_VER;

    usage("Absent_stlace_database") if (!defined $stlace_last);
    usage("Absent_brigdb_database") if (!defined $brigdb_last);
    usage("Absent_citace_database") if (!defined $citace_last);
    usage("Absent_cshace_database") if (!defined $cshace_last);

    # return last version dates as 6-figure string
    return($stlace_last,$brigdb_last,$citace_last,$cshace_last);

}
#__ end prepare_primaries __#


#################################################################################
# make_acefiles                                                               
#################################################################################

sub make_acefiles {
  $am_option = "-acefile";

  # exit unless build_in_progress flag is present
  &usage("Build_in_progress_absent") unless (-e "$logdir/$flag{'A1'}");
  
  # exit unless A4:Primary_databases_on_wormsrv2
  &usage("Build_in_progress_absent") unless (-e "$logdir/$flag{'A4'}");
  
  system ("$scriptdir/make_acefiles.pl") && die "Couldn't run make_acefiles.pl\n";
  $runtime = &runtime;
  print LOG "Finished running make_acefiles.pl at $runtime\n";

  # make a make_acefiles log file in /logs
  system ("touch $logdir/$flag{'A5'}");
  
}
#__ end make_acefiles __#


#################################################################################
# make_autoace                                                                  #
#################################################################################
# Requirements : [01] acefiles in /wormsrv2/wormbase directories
#                [02] config file to drive loading of data (autoace.config)

# Checks       : [01] - Fail if the build_in_progess flag is absent.
#              : [02] - Fail if the Primary_databases_used_in_build file is absent

# Does         : [01] - checks the Primary_database_used_in_build data
#              : [03] - writes log file A1:Update_WS_version to /wormsrv2/autoace/logs

sub make_autoace {
  $am_option = "-build";
  # quit if make_acefiles has not been run
  &usage(8) unless (-e "$logdir/$flag{'A5'}");
  
  if ($build || $builddb) { 

    open (EMAIL,  "|/bin/mailx -s \"WormBase build reminder\" \"wormbase\@sanger.ac.uk\" ");
    print EMAIL "Dear builder,\n\n";
    print EMAIL "You have just run autoace_minder.pl -build.  This will probably take 5-6 hours\n";
    print EMAIL "to run.  You should therefore start work on the blast pipeline. So put down that\n";
    print EMAIL "coffee and do some work.\n\n";
    print EMAIL "Yours sincerely,\nOtto\n";
    close (EMAIL);


    system ("$scriptdir/make_autoace --database /wormsrv2/autoace --buildautoace") && die "Couldn't run make_autoace\n";
    $runtime = &runtime;
    print LOG "Finished running make_autoace at $runtime\n";
    
    # test the build for loading errors
    my $builderrors = &test_build;
    
    # errors in the make_autoace log file
    if ($builderrors > 1) {
      system ("touch $logdir/$flag{'B1A'}");
      &usage("Errors_in_loaded_acefiles");
    }
    
    # make a make_autoace log file in /logs
    system ("touch $logdir/$flag{'B1'}");

    # Update Common_data clone2accession info
    system ("Common_data.pm -in_build -update -accession");
    
  }
  
  if ($build || $buildchrom) {
    
    # quit if you haven't built a database
    &usage(14) unless (-e "$logdir/$flag{'B1'}");
    
    # quit if you have errors in the build
    &usage("Errors_in_loaded_acefiles") if (-e "$logdir/$flag{'B1A'}");
    
    system ("$scriptdir/chromosome_dump.pl --dna --composition") && die "Couldn't run chromosome_dump -dc\n" ;
    $runtime = &runtime;
    print LOG " Finished running chromosome_dump.pl at $runtime\n";
    
    # make a make_autoace log file in /logs
    system ("touch $logdir/$flag{'B2'}");
  }
  
  if ($buildrelease) {
    
    # quit if the build is not complete
    &usage(13) unless (-e "$logdir/$flag{'B1'}");
    
    # quit if you have errors in the build
    &usage("Errors_in_loaded_acefiles") if (-e "$logdir/$flag{'B1A'}");
    
    local (*MD5SUM_IN,*MD5SUM_OUT);
    
    system ("$scriptdir/make_autoace -database /wormsrv2/autoace --buildrelease")  && die "Couldn't run make_autoace\n"; 
    $runtime = &runtime;
    print LOG "Finished running make_autoace at $runtime\n";

    
    # make a make_autoace log file in /logs
    system ("touch $logdir/$flag{'D1'}");
    
    # modify the md5sum output file to remove the Sanger specific path
    open (MD5SUM_OUT, ">/wormsrv2/autoace/release/md5sum.temp")            || die "Couldn't open md5sum file out\n";
    open (MD5SUM_IN, "</wormsrv2/autoace/release/md5sum.WS${WS_version}")  || die "Couldn't open md5sum file in\n";
    while (<MD5SUM_IN>) {
      s/\/wormsrv2\/autoace\/release\///g;
      print MD5SUM_OUT $_;
    }
    close MD5SUM_IN;
    close MD5SUM_OUT;
    
    system ("mv -f /wormsrv2/autoace/release/md5sum.temp /wormsrv2/autoace/release/md5sum.WS${WS_version}");
    $runtime = &runtime;
    print LOG "Finished making md5sum files at $runtime\n";
  }
}
#__ end make_autoace __#

#########################################################################################################################

sub test_build {
  local (*BUILDLOOK,*BUILDLOG);
  my $logfile;

  $runtime = &runtime;
  print LOG "Entering test_build subroutine at $runtime\n";

  print "Looking at log file: /wormsrv2/logs/make_autoace.WS${WS_version}*\n" if ($debug);
  
  open (BUILDLOOK, "ls /wormsrv2/logs/make_autoace.WS${WS_version}* |") || die "Couldn't list logfile out\n";
  while (<BUILDLOOK>) {
    chomp;
    $logfile = $_;
  }
  close BUILDLOOK;
  
  print "Open log file $logfile\n" if ($debug);
  
  my ($parsefile,$parsefilename);
  my $builderrors = 0;

  open (BUILDLOG, "<$logfile") || die "Couldn't open logfile out\n";
  while (<BUILDLOG>) {
    if (/^\* Reinitdb: reading in new database  (\S+)/) {
      $parsefile = $1;
    }
    if ((/^\/\/ objects processed: (\d+) found, (\d+) parsed ok, (\d+) parse failed/) && ($parsefile ne "")) {
      (printf "%6s parse failures of %6s objects from file: $parsefile\n", $3,$1) if $debug;
      if ($3 > 0) {
	$parsefilename = substr($parsefile,18);
	printf LOG "%6s parse failures of %6s objects from file: $parsefilename\n", $3,$1;
	$builderrors++;
      }
      ($parsefile,$parsefilename) = "";
    }
  }
  close BUILDLOG;
  $runtime = &runtime;
  print LOG "Leaving test_build subroutine at $runtime\n";

  return ($builderrors);
}

############################################################################################################################

sub test {

    local (*MD5SUM_IN,*MD5SUM_OUT);
    open (MD5SUM_OUT, ">/wormsrv2/autoace/release/md5sum.temp")             || die "Couldn't open md5sum file out\n";
    open (MD5SUM_IN,  "</wormsrv2/autoace/release/md5sum.WS${WS_version}")  || die "Couldn't open md5sum file in\n";
    while (<MD5SUM_IN>) {
	s/\/wormsrv2\/autoace\/release\///g;
	print MD5SUM_OUT $_;
    }
    close MD5SUM_IN;
    close MD5SUM_OUT;
    
    system ("mv -f /wormsrv2/autoace/release/md5sum.temp /wormsrv2/autoace/release/md5sum.WS${WS_version}");
    
}


#################################################################################
# make_agp                                                                      #
#################################################################################

sub make_agp {
  $am_option = "-agp";

  # This is about checking the DNA and then making agp files.  This step
  # now gets run twice during build, the first time might have errors due to 
  # EMBL synchronisation problems but the second time should be run at the end
  # of the build and errors should have gone away

  # have you run GFFsplitter?
  unless ((-e "$logdir/$flag{'C2'}") && (-e "$logdir/$flag{'B3'}")) {
    &dump_GFFs;
  }   

  system ("$scriptdir/check_DNA.pl")     && die "Couldn't run check_DNA.pl\n";
  $runtime = &runtime;; print LOG "check_DNA.pl finished at $runtime\n";  
  system ("$scriptdir/make_agp_file.pl") && die "Couldn't run make_agp_file.pl\n";
  $runtime = &runtime; print LOG "make_agp_file.pl finished at $runtime\n";  
  system ("$scriptdir/agp2dna.pl")       && die "Couldn't run agp2dna.pl\n";
  $runtime = &runtime; print LOG "agp2dna.pl finished at $runtime\n";  

  # make a B3 log file if this is first run of -agp (i.e. no B3 log file there)
  system ("touch $logdir/$flag{'B3'}") unless ((-e "$logdir/$flag{'B3'}"));

  # check for errors in the agp file 
  local (*AGP);
  my $chrom;
  my @errors;
  
  foreach $chrom (@chrom) {
    open (AGP, "</wormsrv2/autoace/yellow_brick_road/CHROMOSOME_${chrom}.agp_seq.log") or die "Couldn't open agp file : $!";
    while (<AGP>) {
      push (@errors,$_) if (/ERROR/);
    }
    close AGP;
  }
    
  # No errors
  if (scalar @errors > 1) {
  # make 'agp_files_errors' log file in /logs
  # this will halt the process if you are running blat
    system ("touch $logdir/$flag{'B4'}");
  }
        
}

#__ end make_agp __#

#################################################################################
# run dbcomp.pl                                                                 #
#################################################################################

sub dbcomp{
  $am_option = "-dbcomp";	
  # need to perform class by class comparison against previous release

  $runtime = &runtime; print LOG "dbcomp.pl started at $runtime\n";	
  system ("$scriptdir/dbcomp.pl") && die "Couldn't run dbcomp.pl\n";	      
  $runtime = &runtime; print LOG "dbcomp.pl finished at $runtime\n";      
}
#__ end dbcomp __#


#################################################################################
# prepare for blat jobs                                                         #
#################################################################################

sub prepare_for_blat{
  $am_option = "-prepare_blat";
  &usage(15) if (-e "$logdir/$flag{'B4'}");
  
  # TransferDB the current autoace to safe directory 
  print LOG "Starting TransferDB at ",&runtime,"\n";
  system("TransferDB.pl -start /wormsrv2/autoace -end /wormsrv2/autoace_midway -database -wspec -name autoace_midway")
    && die "Couldn't run TransferDB for autoace\n";
  print LOG "Finished TransferDB at ",&runtime,"\n";
  
  # make a copy_autoace_midway log file in /logs
  system ("touch $logdir/$flag{'B5'}");  

  # Now make blat target database using autoace (will be needed for all possible blat jobs)
  # Need to run blat_them_all -dump
  print LOG "Starting blat_them_all.pl -dump at ",&runtime,"\n";
  system ("$scriptdir/blat_them_all.pl -dump")   && die "Couldn't blat_them_all -dump\n";
  print LOG "Finishing blat_them_all.pl -dump at ",&runtime,"\n";

}

#################################################################################

sub blat_jobs{
  $am_option = "-blat";
  # Should only be here if there are new sequences to blat with, or genome sequence has changed.

  # Also check that autoace has been copied to autoace_midway
  &usage(16) unless (-e "$logdir/$flag{'B5'}");
  
  # what blat jobs should I run? Do everything if blat_all selected
  my @blat_jobs;
  push(@blat_jobs,"est")      if $blat_est;
  push(@blat_jobs,"ost")      if $blat_ost;
  push(@blat_jobs,"mrna")     if $blat_mrna;
  push(@blat_jobs,"embl")     if $blat_embl;
  push(@blat_jobs,"nematode") if $blat_nematode;  # nematode should always be last job to tackle
  push(@blat_jobs,"est","ost","mrna","embl","nematode") if $blat_all;

  my $status;
  my $nematode_flag = 0; # have nematode blats been run?

  # run each blat job in turn 
  foreach my $job(@blat_jobs){

    # If all other blat jobs are finished can load all non-nematode blat data into autoace this allows 
    # gff dump and gff split to be run, this is because nematode ESTs take a long time to blat/load
    if ($job eq "nematode"){
      &load_blat_results("est","mrna","embl","ost");
      # dump gff from the database and then split them for when you want to make UTRs later
      &dump_GFFs;
      &split_GFFs;
      system ("touch $logdir/UTR_gff_dump");
      $nematode_flag = 1;
    }
    
    # run the main blat job
    print LOG "Starting blat_them_all.pl -blat -process -$job at ",&runtime,"\n\n";
    $status = system ("$scriptdir/blat_them_all.pl -blat -process -$job"); die "-process -$job: $?" unless ($status == 0);
    print LOG "Finishing blat_them_all.pl -blat -process -$job at ",&runtime,"\n\n";
    
    # also create virtual objects
    print LOG "Starting blat_them_all.pl -virtual -$job at ",&runtime,"\n\n";
    $status = system ("$scriptdir/blat_them_all.pl -virtual -$job");  die "-virtual -$job: $?" unless ($status == 0);
    print LOG "Finishing blat_them_all.pl -virtual -$job at ",&runtime,"\n\n";
    
    # Run aceprocess to make cleaner files
    print LOG "Starting acecompress.pl at ",&runtime,"\n\n";
    system ("$scriptdir/acecompress.pl -homol autoace.blat.$job.ace > autoace.blat.${job}lite.ace");
    system ("mv -f autoace.blat.${job}lite.ace autoace.blat.$job.ace");
    unless($job eq "nematode"){
      # don't need to do this for nematode ESTs
      system ("$scriptdir/acecompress.pl -feature autoace.good_introns.$job.ace > autoace.good_introns.${job}lite.ace");
      system ("mv -f autoace.good_introns.${job}lite.ace autoace.good_introns.$job.ace");
    }
    print LOG "Finishing acecompress.pl at ",&runtime,"\n\n";
      
    # make blat job specific lock file
    system ("touch $logdir/$flag{'B6_$job'}");
    
  }
  # generic lock file
  system ("touch $logdir/$flag{'B6'}");  

  # now load blat results into autoace
  # if blat_nematode was selected then only need to load just those results as other results would have been loaded above.
  # otherwise load everything
  if($nematode_flag == 1){
    &load_blat_results("nematode");
  }
  else{
    &load_blat_results("all");
  }
}

################################################################################
sub load_blat_results{

  # generic subroutine for loading blat data into autoace
  # will load all types of blat result if 'all' is passed to the subroutine
  my $first_blat_type = $_;
  my @blat_types = @_;
  @blat_types = ("est","mrna","ost","embl","nematode") if ($first_blat_type eq "all");
  
  my $command;
  foreach my $type (@blat_types){    
    print LOG "Adding BLAT $type data to autoace at ",&runtime,"\n";
    $command =  "pparse /wormsrv2/autoace/BLAT/virtual_objects.autoace.blat.$type.ace\n";
    # Don't need to add confirmed introns from nematode data (because there are none!)
    $command .= "pparse /wormsrv2/autoace/BLAT/virtual_objects.autoace.ci.$type.ace\n" unless ($type eq "nematode");
    $command .= "pparse /wormsrv2/autoace/BLAT/autoace.blat.$type.ace\n";           
    $command .= "save\nquit\n";
    open (WRITEDB, "| $tace -tsuser Sanger_BLAT_data /wormsrv2/autoace |") || die "Couldn't open pipe to autoace\n";
    print WRITEDB $command;
    close WRITEDB;
    print LOG "Finished adding BLAT $type data at ",&runtime,"\n";  
  }
  system ("touch $logdir/$flag{'B7A'}");    


}

#__ end load_blat_results __#

####################################################################################


##################################
# load BLASTX data
#################################
sub parse_homol_data {
  $am_option = "-addhomol";
  my $command;

  my @files2Load = (
		    "blastp_ensembl.ace",
		    "blastx_ensembl.ace",
		    "ensembl_protein_info.ace",
		    "waba.ace",
		    "wormprot_motif_info.ace",
		    "worm_brigprot_motif_info.ace",
		    "brigprot_blastp_ensembl.ace"
		   );

  foreach my $file ( @files2Load ) {
    print LOG "Adding $file at ",&runtime,"\n";

    # make sure file exists
    unless ( -e "/wormsrv2/wormbase/ensembl_dumps/$file" ) {
      print LOG "ERROR *** $file doesn't exist \n\n";
      next;
    }

    # tsuser cant contain '.' so strip of .ace
    my $tsuser = substr($file,0,-4);

    $command = "pparse /wormsrv2/wormbase/ensembl_dumps/$file\nsave\nquit\n";
    open (WRITEDB, "| $tace -tsuser $tsuser /wormsrv2/autoace  |") || warn  "Couldn't open pipe to autoace while loading $file\n";
    print WRITEDB $command;
    close WRITEDB;
  }
 
  # upload_homol data log file in /logs
  system ("touch $logdir/$flag{'B8'}");

}
#__ end parse_homol_data __#


##################################
# load nematode EST data
#################################


sub add_nematode_ESTs {
    my $command;
    
    $runtime = &runtime; print LOG "Adding nematode EST data files at $runtime\n";
    $command = "pparse /wormsrv2/wormbase/misc/misc_nonelegansests.ace\nsave\nquit\n";
    open (WRITEDB, "| $tace -tsuser nematode_ESTs /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
    print WRITEDB $command;
    close WRITEDB;
    $runtime = &runtime; print LOG "Finished adding nematode EST data files at $runtime\n";


}

#__ end add_nematode_ESTs_data __#




##################################
# load briggsae data
#################################

sub parse_briggsae_data {
  my $command;
  $am_option = "-addbriggsae";

  # load four raw briggsae data files		   
  $runtime = &runtime; print LOG "Adding raw briggsae assembly data files at $runtime\n";
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_DNA.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_assembly_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_fosmid.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_assembly_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_agplink.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_assembly_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_sequence.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_assembly_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  $runtime = &runtime; print LOG "Finished adding raw briggsae assembly data files at $runtime\n";
  
  # load gene prediction sets
  $runtime = &runtime;print LOG "Adding briggsae gene prediction data files at $runtime\n";
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_genefinder.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_gene_prediction_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_fgenesh.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_gene_prediction_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_twinscan.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_gene_prediction_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_ensembl.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_gene_prediction_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;

  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_hybrid.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_gene_prediction_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;

  $command = "pparse /wormsrv2/wormbase/briggsae/briggsae_cb25.agp8_rna.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser briggsae_gene_prediction_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;

  $runtime = &runtime;print LOG "Finished adding briggsae gene prediction data files at $runtime\n";
  # upload_homol data log file in /logs
  system ("touch $logdir/$flag{'B9'}");
  
}
#__ end parse_briggsae_data __#

#################################################################################
# generate_utrs                                                                 #
#################################################################################

sub generate_utrs {
  $am_option = "-utrs";
  my $command;
  
  #split GFF prior to UTR generation if not already done by BLAT routine
  unless ( -e "/$logdir/UTR_gff_dump" ){
    &dump_GFFs; 
    &split_GFFs;
    # create a lockfile to indicate that this is done (helpful if you need to rerun
    # this step (autoace_minder.pl -utr) but don't want to keep on redumping GFF)
    system ("touch $logdir/UTR_gff_dump");
  }

  # run find_utrs.pl to generate data
  $runtime = &runtime; print LOG "Running find_utrs.pl at $runtime\n";
  system("find_utrs.pl -d autoace -r /wormsrv2/autoace/UTR") && die "Couldn't run find_utrs.pl\n";

  $runtime = &runtime; print LOG "Adding UTRs.ace file to autoace at $runtime\n";
  $command = "pparse /wormsrv2/autoace/UTR/UTRs.ace\nsave\nquit\n"; 
  open (WRITEDB, "| $tace -tsuser utr_data /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;

  # make a log file in /autoace/logs
  system ("touch $logdir/B10:Generate_UTR_data");
}
#__ end generate_utrs __#


#################################################################################################################


sub make_wormpep {
  $am_option = "-buildpep";
  # make wormpep database but also perform all the other related protein steps in the build
  unless( -e "$logdir/D1A:Build_wormpep_initial" ) {
    # make wormpep -i
    $runtime = &runtime; print LOG "Running make_wormpep -i at $runtime\n";
    system ("$scriptdir/make_wormpep -i") && die "Couldn't run make_wormpep -i\n";
    $runtime = &runtime; print LOG "Finished running make_wormpep -i at $runtime\n"; 
   
    #generate file to ad new peptides to mySQL database.
    $runtime = &runtime; print LOG "\nRunning new_wormpep_entries.pl at $runtime\n";
    system ("$scriptdir/new_wormpep_entries.pl") and die "Couldn't run new_wormpep_entries.pl\n";
    $runtime = &runtime; print LOG "Finished running new_wormpep_entries.pl at $runtime\n";
    print "Updating CE2gene COMMON_DATA : ",&runtime,"\n";
    system ("$scriptdir/update_Common_data.pl -update -in_build -ce") and carp "Update of COMMON_DATA CE2gene failed.\n";
    print "DONE : ",&runtime,"\n\n";

    system ("touch $logdir/D1A:Build_wormpep_initial");
  }
  else {
    # Get protein IDs (this step writes to ~wormpub/analysis/SWALL
    $runtime = &runtime; print LOG "Started getProteinID at $runtime\n";
    system("getProteinID") && die "Couldn't run getProteinID";
    $runtime = &runtime; print LOG "Finished getProteinID at $runtime\n";
    
    # load into autoace
    my $command = "pparse /wormsrv2/autoace/wormpep_ace/WormpepACandIDs.ace\nsave\nquit\n"; 
    open (WRITEDB, "| $tace -tsuser Protein_ID /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
    print WRITEDB $command;
    close WRITEDB;
    $runtime = &runtime; print LOG "Finished loading proteinID info into autoace at $runtime\n";
    
    # make wormpep
    $runtime = &runtime; print LOG "Running make_wormpep -f at $runtime\n";
    system ("$scriptdir/make_wormpep -f") && die "Couldn't run make_wormpep -f\n";
    $runtime = &runtime; print LOG "Finished running make_wormpep -f at $runtime\n";
 
    
    # make acefile of peptides etc to add to autoace (replacement for pepace)
    print LOG &runtime," : Running build_pepace.pl\n";
    system ("$scriptdir/build_pepace.pl") && die "Couldn't run build_pepace.pl\n";
    print LOG &runtime," : Finished running build_pepace.pl\n";

    print "Updating gene2pid COMMON_DATA : ",&runtime,"\n";
    system ("$scriptdir/update_Common_data.pl -update -in_build -pid") and carp "Update of COMMON_DATA gene2pid failed.\n";
    print "DONE : ",&runtime,"\n\n";

    system ("touch $logdir/D1A:Build_wormpep_initial");
   
    
    # make a make_autoace log file in /logs
    system ("touch $logdir/D1:Build_wormpep_final");
  }
}
#__ end make_wormpep  __#

#################################################################################
# make_wormrna                                                                  #
#################################################################################

sub make_wormrna {
  $am_option = "-buidrna";
  system ("$scriptdir/make_wormrna.pl -release $WS_version") && die "Couldn't run make_wormrna.pl -r\n";
  $runtime = &runtime; print LOG "Finished running make_wormrna.pl -r at $runtime\n";
}
#__ end make_wormrna __#


#################################################################################
# dump GFF files                                                                #
#################################################################################

sub dump_GFFs {
  $am_option .= " -gffdump";
  $runtime = &runtime; print LOG "chromosome_dump.pl started at $runtime\n";  
  system ("$scriptdir/chromosome_dump.pl --gff") && die "Couldn't make GFF files\n";
  $runtime = &runtime; print LOG "chromosome_dump.pl finished at $runtime\n";  

  # make dumped_GFF_file in /logs
  system ("touch $logdir/C1:Dumped_GFF_files");
}
#__ end dump_GFFs __#

####################################################################################

sub split_GFFs {
  $am_option .= " -gffsplit";
  $runtime = &runtime; print LOG "GFFsplitter.pl started at $runtime\n";  
  system ("$scriptdir/GFFsplitter.pl") && die "Couldn't split GFF files\n";
  $runtime = &runtime; print LOG "GFFsplitter finished at $runtime\n";  
  # make GFF_splitter file in /logs
  system ("touch $logdir/C2:Split_GFF_files");
}
#__ end split_GFFs __#


#################################################################################
# map PCR and RNAi                                                              #
#################################################################################

sub map_features {
  $am_option = "-map";
  # PCR products
  $runtime = &runtime; print LOG "map_PCR_products started at $runtime\n";  
  system("$scriptdir/map_PCR_products") && die "Couldn't run map_PCR_products\n";
  $runtime = &runtime; print LOG "map_PCR_products finished at $runtime\n";  
  
  # RNAi experiments
  $runtime = &runtime; print LOG "map_PCR_RNAi.pl started at $runtime\n";  
  system("$scriptdir/map_RNAi.pl") && die "Couldn't run map_RNAi.pl\n";
  $runtime = &runtime; print LOG "map_PCR_RNAi.pl finished at $runtime\n";  

  # alleles
  print LOG "map_alleles.pl started at ",&runtime,"\n";  
  system("$scriptdir/map_alleles.pl") && die "Couldn't run map_alleles.pl\n";
  print LOG "map_alleles.pl finished at ",&runtime,"\n";  


}
#__ end map_features __#

#################################################################################
# confirm_gene models                                                           #
#################################################################################

sub confirm_gene_models {
  $am_option = "-confirm";

  # confirm_genes from EST (-e) and mRNA (-m) data sets and OST (-o)
  $runtime = &runtime; print LOG "confirm_genes.pl -e started at $runtime\n";  
  system ("$scriptdir/confirm_genes.pl -e");
  $runtime = &runtime; print LOG "confirm_genes.pl -e finished at $runtime\n";  
  $runtime = &runtime; print LOG "confirm_genes.pl -m started at $runtime\n";  
  system ("$scriptdir/confirm_genes.pl -m");
  $runtime = &runtime; print LOG "confirm_genes.pl -m finished at $runtime\n";  

my $command=<<END;
pparse /wormsrv2/wormbase/misc/misc_confirmed_by_EST.ace
pparse /wormsrv2/wormbase/misc/misc_confirmed_by_mRNA.ace
save 
quit
END
  $runtime = &runtime; print LOG "Adding confirmed genes info to autoace at $runtime\n";  
  open (WRITEDB, "| $tace -tsuser confirmed_genes /wormsrv2/autoace  |") || die "Couldn't open pipe to autoace\n";
  print WRITEDB $command;
  close WRITEDB;
  
  # make dumped_GFF_file in /logs
  system ("touch $logdir/C4:Confirm_gene_models");

    print "Updating predicted_CDS COMMON_DATA : ",&runtime,"\n";
    system ("$scriptdir/update_Common_data.pl -update -in_build -predicted_CDS") and carp "Update of COMMON_DATA predicted CDSs failed.\n";
    print "DONE : ",&runtime,"\n\n";

}
#__ end confirm_gene_models __#



#################################################################################
# Open logfile                                                                  #
#################################################################################

sub logfile_details {
  $rundate    = `date +%y%m%d`; chomp $rundate;
  print LOG "# autoace_minder.pl started at: $rundate ",&runtime,"\n";
  print LOG "# WormBase/Wormpep version: WS${WS_version}\n\n";  
  print LOG "#  -initial      : Prepare for a new build, update WSnn version number\n"                 if ($initial);
  print LOG "#  -unpack       : Unpack databases from FTP site and copy Sanger dbs\n"                  if ($unpack);
  print LOG "#  -acefile      : Write .acefiles from WormBase copies of the databases\n"               if ($acefile);
  print LOG "#  -build        : Build autoace\n"                                                       if ($build);
  print LOG "#  -builddb      : Build autoace : DB only\n"                                             if ($builddb);
  print LOG "#  -buildchrom   : Build autoace : DNA data\n"                                            if ($buildchrom);
  print LOG "#  -buildtest    : Build autoace : Test for failed .ace object uploads\n"                 if ($buildtest);
  print LOG "#  -buildrelease : Build autoace : Release directory\n"                                   if ($buildrelease);
  print LOG "#  -agp          : Make and check agp files\n"		                               if ($agp);
  print LOG "#  -dbcomp       : Check DB consistency and diffs from previous version\n"                if ($dbcomp);
  print LOG "#  -buildpep     : Build wormpep database\n"                                              if ($buildpep);
  print LOG "#  -buildrna     : Build wormrna database\n"                                              if ($buildrna);
  print LOG "#  -blat_est     : perform blat analysis on ESTs\n"                                       if ($blat_est);
  print LOG "#  -blat_ost     : perform blat analysis on OSTs\n"                                       if ($blat_ost);
  print LOG "#  -blat_mrna    : perform blat analysis on mRNAs\n"                                      if ($blat_mrna);
  print LOG "#  -blat_embl    : perform blat analysis on non-WormBase CDSs from EMBL\n"                if ($blat_embl);
  print LOG "#  -blat_nematode: perform blat analysis on non-C. elegans ESTs\n"                        if ($blat_nematode);
  print LOG "#  -blat_all     : perform blat analysis on everything\n"                                 if ($blat_all);
  print LOG "#  -addblat      : Load blat data into autoace\n"                                         if ($addblat);
  print LOG "#  -addhomol     : Load blast data into autoace\n"                                        if ($addhomol);
  print LOG "#  -addbriggsae  : Load briggsae data into autoace\n"                                     if ($addbriggsae);
  print LOG "#  -utrs         : Generates and load UTR data into autoace\n"                            if ($utrs);
  print LOG "#  -debug        : Verbose/Debug mode\n"                                                  if ($debug);
  print LOG "#  -gffdump      : Dump GFF files\n"                                                      if ($gffdump);
  print LOG "#  -gffsplit     : Split GFF files\n"                                                     if ($gffsplit);
  print LOG "#  -map          : map PCR and RNAi\n"                                                    if ($map);
  print LOG "======================================================================\n\n";

}

#######################################################################
# Help and error trap outputs                                         #
#######################################################################

sub usage {
    my $error = shift;

    if ($error eq "No_WormBase_release_number") {
	# No WormBase release number file
	print "The WormBase release number cannot be parsed\n";
	print "Check File: /wormsrv2/autoace/wspec/database.wrm\n\n";
	exit(0);
    }
    elsif ($error eq "Failed_to_update_cvs_repository") {
	# Failed to update cvs repository with new WormBase release number
	print "The 'database.wrm' file in the cvs repository was not updated\n";
	print "Try to do this by hand.\n\n";
	exit(0);
    }
    elsif ($error == 2) {
	# Abort unpack_db.pl script
	print "Abort unpack_db run.\n";
	print "\n\n";
	exit(0);
    }
    elsif ($error eq "Primary_databases_file_error") {
	# No Primary_databases_used_in_build file
	print "The 'Primary_databases_used_in_build' is absent or unreadable.\nAbort build.\n";
	print "\n\n";
	exit(0);
    }
    elsif ($error eq "Absent_stlace_database") {
	# No last_version date for stlace
	print "Abort unpack_db run. stlace\n";
	print "\n\n";
	exit(0);
    }
    elsif ($error eq "Absent_brigdb_database") {
	# No last_version date for brigdb
	print "Abort unpack_db run. brigdb\n";
	print "\n\n";
	exit(0);
    }
    elsif ($error eq "Absent_citace_database") {
	# No last_version date for citace
	print "Abort unpack_db run. citace\n";
	print "\n\n";
	exit(0);
    }
    elsif ($error eq "Absent_cshace_database") {
	# No last_version date for cshace
	print "Abort unpack_db run. cshace\n";
	print "\n\n";
	exit(0);
    }
    elsif ($error == 7) {
	# Check build prior to building
	print "You haven't built the database yet!\n";
	exit(0);
    }
    elsif ($error == 8) {
	# Check acefile dump prior to building
	print "You haven't written up-to-date .acefiles yet!\n";
	exit(0);
    }
    elsif ($error eq "Errors_in_loaded_acefiles") {
	# Errors in loaded acefiles, check log file
	print "There were errors in the loaded acefiles.\n";
	print "Check the logfile and correct before continuing.\n\n";
	exit(0);
    }
    elsif ($error == 9) {
	# Check blat run
	print "You haven't run blat_them_all.\n";
	exit(0);
    }
    elsif ($error == 10) {
	# Build_in_progress flag already exists when build initiation attempted
	print "\nautoace build aborted:\n";
	print "The 'build_in_progress' flag already exists\n";
	print "You cannot start a new build until this flag is removed\n\n";
	exit(0);
    }
    elsif ($error == 11) {
	# Build_in_progress flag is newer than WormBase version number
	print "\nautoace build aborted:\n";
	print "The WS version predates the 'build_in_progress' flag \n";
	print "Check that the WS version number is correct\n\n";
	exit(0);
    }
    elsif ($error eq "Build_in_progress_absent") {
	# Build_in_progress flag is absent when preparing primaries
	print "\nautoace build aborted:\n";
	print "The 'build_in_progress' flag is absent. \n";
	print "You can't overwrite the primary databases on wormsrv2 prior to a new build.\n\n";
	exit(0);
    }
    elsif ($error == 13) {
	# B2:Build_autoace_database absent when making release .tar.gz files
	print "\nautoace build aborted:\n";
	print "The 'Build_autoace_database' flag is absent. \n";
	print "You can't write the release .tar.gz files prior to a completing the  build.\n\n";
	exit(0);
    }
    elsif ($error == 14) {
	# Dump_dna before the database is finished
	print "\nautoace build aborted:\n";
	print "The '$flag{'B1'} flag is absent. \n";
	print "You can't write the chromosome DNA files prior to a completing the build.\n\n";
	exit(0);
    }
    elsif ($error == 15) {
	# attempted BLAT analysis with agp errors 
	print "\nautoace build aborted:\n";
	print "The '$flag{'B4'} flag is set indicating errors in the agp file. \n";
	print "You must remove this file before you can run the BLAT analysis.\n\n";
	exit(0);
    }
    elsif ($error == 16) {
	# atempted BLAT analysis without copying to autoace_midway 
	print "\nautoace build aborted:\n";
	print "The '$flag{'B5'} flag is absent indicating that the copy of autoace has not been made. \n";
	print "You must add this file if you want to run the BLAT analysis or run autoace_minder.pl -prepare_blat.\n\n";
	exit(0);
    }
    elsif ($error == 0) {
	# Normal help menu
	exec ('perldoc',$0);
    }
}


__END__

=pod

=head2   NAME - autoace_minder.pl

=head1 USAGE

=over 4

=item autoace_minder.pl [-options]

=back

autoace_minder.pl is a wrapper to drive the various scripts utilised in the
build of a C.elegans WS database release.

autoace_minder.pl mandatory arguments:

=over 4

=item none, (but it won\'t do anything)

=back

autoace_minder.pl OPTIONAL arguments:

=over 4

=item -acefile, Write .acefiles from WormBase copies of the databases

=item -build, Build autoace : (performs options 1 & 2 below)

=item -builddb, Build autoace : Database only

=item -buildchrom, Build autoace : Dump DNA

=item -buildrelease, Build autoace : release directory

=item -dbcomp, Check DB consistency and diffs from previous version

=item -buildpep, Build wormpep database

=item -ftp, Move WS release to the external FTP site (Full public release)

=item -debug, Verbose/Debug mode

=item -agp, creates and checks agp files

=item -gffdump, dump GFF files

=item -gffsplit, split GFF files

=item -map, map PCR and RNAi

=item -blat_est, map all blat EST similarities, load into autoace

=item -blat_ost, map all blat OST similarities, load into autoace

=item -blat_mrna, map all blat similarities, load into autoace

=item -blat_embl, map all blat EMBL gene similarities, load into autoace

=item -blat_nematode, map all blat other nematode ESTs similarities, load into autoace

=item -blat_all, map all blat similarities (BLAT jobs)

=item -addblat, parse all BLAT files (ESTs, OSTs, mRNAs, EMBL genes, nematode ESTs) into autoace

=item -addhomol, parse BLASTX and BLASTP data from pre-build

=item -addbriggsae, parse briggsae assembly data and briggsae gene predictions

=item -utrs, generate UTR datatset and add to autoace
 
=back

=cut
