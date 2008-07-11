#!/usr/local/bin/perl -w
# Last edited by: $Author: mh6 $
# Last edited on: $Date: 2008-07-11 12:24:59 $

use strict;
use lib  $ENV{'CVS_DIR'};
use Wormbase;
use Storable;
use Getopt::Long;
use Log_files;

our ($help, $debug, $test, $stage);
my $store;
my @chromosomes;

GetOptions ("help"         => \$help,
            "debug=s"      => \$debug,
	    "test"         => \$test,
	    "store:s"      => \$store,
	    "stage:s"      => \$stage,
	    "chromosomes:s"=> \@chromosomes,
	   );

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
$log->log_and_die("stage not specified\n") unless defined $stage;

my $cmd;
if ( $stage eq 'final' ){
  $cmd = "dump_gff_batch.pl -database ".$wormbase->autoace." -dump_dir ".$wormbase->chromosomes;
  $cmd .= " -chromosomes ". join(",",@chromosomes) if @chromosomes;
}
else {
  my $methods;
  my @methods;
 READARRAY: while (<DATA>) {
    chomp;
    my ($type,$method,@speciestodo) = split;
    push(@methods,"$method") if ( $type eq $stage and (grep($wormbase->species eq $_,@speciestodo)) ) ;
  }
  $methods = join(',',@methods);

  $log->write_to("Dumping methods $methods from ".$wormbase->autoace."\n");

  $cmd = "dump_gff_batch.pl -database ".$wormbase->autoace." -methods $methods -dump_dir ".$wormbase->autoace."/GFF_SPLITS";
  $cmd .= " -chromosomes ". join(",",@chromosomes) if @chromosomes;
}

$wormbase->run_script($cmd,$log);

$log->mail();
exit(0);

__DATA__
init Genomic_canonical elegans briggsae remanei
init Link elegans briggsae remanei
init Pseudogene elegans briggsae remanei
init Transposon elegans
init Transposon_CDS elegans
init curated  elegans briggsae remanei
init history elegans briggsae
init miRNA elegans
init tRNAscan-SE-1.23 elegans
init Non_coding_transcript elegans
init SAGE_tag elegans
init snRNA elegans
init rRNA elegans
init scRNA elegans
init snoRNA elegans
init tRNA elegans
init stRNA elegans
init ncRNA elegans
init GenePairs elegans
init Oligo_set elegans
init SAGE_transcript elegans
init RNAi_primary elegans
init RNAi_secondary elegans
init Expr_profile elegans
init Orfeome elegans
blat BLAT_EST_BEST elegans briggsae remanei
blat BLAT_EST_OTHER elegans
blat BLAT_NEMATODE elegans
blat BLAT_OST_BEST elegans
blat BLAT_OST_OTHER elegans
blat BLAT_RST_BEST elegans
blat BLAT_RST_OTHER elegans
blat BLAT_TC1_BEST elegans
blat BLAT_TC1_OTHER elegans
blat BLAT_mRNA_BEST elegans briggsae remanei
blat BLAT_mRNA_OTHER elegans
blat BLAT_ncRNA_BEST elegans
blat BLAT_ncRNA_OTHER elegans
blat BLAT_WASHU elegans
blat BLAT_NEMBASE elegans
blat SL1 elegans
blat SL2 elegans
blat polyA_signal_sequence elegans
blat polyA_site elegans
homol waba_coding elegans
homol waba_strong elegans
homol waba_weak elegans
homol tandem elegans
homol RepeatMasker elegans
homol wublastx elegans
homol inverted elegans
__END__
