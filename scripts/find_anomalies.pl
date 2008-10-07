#!/software/bin/perl -w
#
# find_anomalies.pl                           
# 
# by Gary Williams                        
#
# This looks for anomalous things such as protein homologies not
# matching a CDS and stores the results in in a data file ready to be read into the SQL database
# 'worm_anomaly'
#
# Last updated by: $Author: gw3 $     
# Last updated on: $Date: 2008-10-07 13:39:59 $      

# Changes required by Ant: 2008-02-19
# 
# Improve signal to noise ration generally by changing thresholds and
# heavily weighting realy good anomalies.
# 
# Confirmed_intron - weight 10 (Done 2008-02-21)
# 
# Frameshifted_protein - improve.  (not done yet)
#  - Change from linear scoring to
# log10(Blast score) with min threshold of 50 giving an anomaly score
# of 1.x to 3 (Done 2008-02-20)
# 
# long_exon - remove (Done 2008-02-20)
# 
# merge_genes_by_proteins - want to use coordinate data so that false
# positives are filtered out. (not done yet)
# - Score as for merge_genes_by_proteins (Done 2008-02-20)
# 
# mismatched_est - output to a separate file for curators to look at (Done 2008-02-28)
# 
# overlapping_exons - score increased to 5 (Done 2008-02-20)
# 
# repeat_overlaps_exons - ignore overlaps of circa <20 bases.  (Done 2008-02-22)
# - Report the types and frequency of overlaps. (Done 2008-02-28)
# 
# short_exons - remove (Done 2008-02-20)
# 
# split_genes_by_protein - score as for merge_genes_by_proteins (Done 2008-02-20)
# 
# split_gene_by_protein_groups - score as for merge_genes_by_proteins (Done 2008-02-20)
# 
# unattached_tsl - remove (Done 2008-02-20)
# 
# unmatched_protein - score as for merge_genes_by_proteins (Done 2008-02-20)
# 
# unmatched_sage - make use of the score which is now in the GFF file (Done 2008-02-21)
# 
# unmatched_tsl - score increased to 5.   (Done 2008-02-20)
# - Add TSL inside genes but not near start of isoform. (not done yet)
# 
# unmatched_waba - get anomaly score 1 to 2 as a log10 transform of
# the waba score.  (Done 2008-02-20)
# 
# weak_intron_splice_site - Check splice site against confirmed introns.  (Done 2008-02-26)
# - Make use of splice score GFF files output by giface. (not done yet)
# 
# unmatched_genefinder - don't report if it overlaps with a repeat (Done 2008-02-22)
# 
# unmatched_twinscan - don't report if it overlaps with a repeat (Done 2008-02-22)
# 
# 
# Add:
# 
# incomplete_pfam_motif - speak to Rob Finn (pfam project leader)
# about the utility of these. (Mail sent: 2008-02-20)
# 
# Compare SignalP in known proteins to the number I predicted and send to Ant.
# Have as anomaly. (not done yet)

use strict;                                      
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Getopt::Long;
use Carp;
use Log_files;
use Storable;
use Ace;
use Coords_converter;
use Modules::Overlap;
use Modules::PWM;
use POSIX qw(log10);

######################################
# variables and command-line options # 
######################################

my ($help, $debug, $test, $verbose, $store, $wormbase);
my ($database, $species, $supplementary);

GetOptions ("help"       => \$help,
            "debug=s"    => \$debug,
	    "test"       => \$test,
	    "verbose"    => \$verbose,
	    "store:s"    => \$store,
	    "database:s" => \$database,	    # use the specified database instead of currentdb
	    "species:s"  => \$species,
	    "supplementary" => \$supplementary, # add GFF files to the SUPPLEMENTARY_DATA directory of the specified database
	    );

if ( $store ) {
  $wormbase = retrieve( $store ) or croak("Can't restore wormbase from $store\n");
} else {
  # check that the given species is correct
  if (!defined $species) {
    if (defined $database && (glob($database) ne glob("~wormpub/BUILD/autoace") && glob($database) ne glob("~wormpub/DATABASES/current_DB)"))) {
      croak("Please give the -species parameter if using a non-standard database\n");
    } else {
      $species = 'elegans';
    }
  }
  $wormbase = Wormbase->new( -debug   => $debug,
                             -test    => $test,
			     -organism => $species,
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

my $currentdb = $wormbase->database('current');		# set currentdb explicitly as the default
$database = $currentdb unless $database;
$species = $wormbase->species;	                        # set the species if it was given


#################################
# Set up some useful paths      #
#################################

my $tace = $wormbase->tace;        # TACE PATH

##########################
# MAIN BODY OF SCRIPT
##########################

my %dna_entry;		# store for dna sequences for when reading remanei-style multi-entry sequence file

my $ovlp;			# Overlap object

# output file of data to write to database, primarily for St. Louis to read in
my $datafile = $wormbase->wormpub . "/CURATION_DATA/anomalies_$species.dat";
open (DAT, "> $datafile") || die "Can't open $datafile\n";

# and output the species line for the data file
print DAT "SPECIES\t$species\n\n";

my $coords = Coords_converter->invoke($database, 0, $wormbase);

# open an ACE connection to parse details for mapping to genome
print "Connecting to Ace\n";
my $ace = Ace->connect (-path => $database,
                       -program => $tace) || die "cannot connect to database at $database\n";

my $pwm = PWM->new;

my $chromosome_prefix=$wormbase->chromosome_prefix;

my %clonelab;
if ($species eq 'elegans') {
  $wormbase->FetchData('clone2centre', \%clonelab, "$database/COMMON_DATA/");
}

# list of frequencies of repeat motifs that overlap coding exons
my %repeat_count;

# list of ESTs which have small mismatches to the genome sequence
my @est_mismatches;

# hash of anomaly counts
my %anomaly_count;

# read the list of which analyses are being done by which species
my %run;
while (my $run = <DATA>) {
  if ($run =~ /START_DATA/) {last;}
}
while (my $run = <DATA>) {
  if ($run =~ /END_DATA/) {last;}
  my ($analysis, $allowed_species) = $run =~ /(\S+)\s*(.*)/;
  if ($allowed_species =~ /$species/) {$run{$analysis} = 1;}
}


# now delete things that have not been updated in this run that you
# would expect to have been updated like protein-homology-based
# anomalies that might have gone away.  This also deletes anomalies
# that we are no longer putting into the database and which can be
# removed.
&delete_anomalies("UNMATCHED_PROTEIN");
&delete_anomalies("SPLIT_GENES_BY_PROTEIN");
&delete_anomalies("SPLIT_GENE_BY_PROTEIN_GROUPS");
&delete_anomalies("SHORT_EXON");
&delete_anomalies("SPLIT_GENES_BY_EST");
&delete_anomalies("MERGE_GENES_BY_EST");
&delete_anomalies("UNMATCHED_EST");
&delete_anomalies("UNATTACHED_EST");
&delete_anomalies("UNATTACHED_TSL");
&delete_anomalies("UNMATCHED_TSL");
&delete_anomalies("UNMATCHED_RST5");
&delete_anomalies("FRAMESHIFTED_PROTEIN");
&delete_anomalies("OVERLAPPING_EXONS");
&delete_anomalies("LONG_EXON");
&delete_anomalies("SHORT_EXON");
&delete_anomalies("UNMATCHED_WABA");
&delete_anomalies("UNMATCHED_SAGE");
&delete_anomalies("REPEAT_OVERLAPS_EXON");
&delete_anomalies("MERGE_GENES_BY_PROTEIN");
&delete_anomalies("WEAK_INTRON_SPLICE_SITE");
&delete_anomalies("UNMATCHED_TWINSCAN");
&delete_anomalies("UNMATCHED_GENEFINDER");
&delete_anomalies("CONFIRMED_INTRON");
&delete_anomalies("UNCONFIRMED_INTRON");
&delete_anomalies("CONFIRMED_EST_INTRON");
&delete_anomalies("CONFIRMED_cDNA_INTRON");
&delete_anomalies("INTRONS_IN_UTR");
&delete_anomalies("SPLIT_GENE_BY_TWINSCAN");
&delete_anomalies("MERGE_GENES_BY_TWINSCAN");
&delete_anomalies("UNMATCHED_MASS_SPEC_PEPTIDE");
&delete_anomalies("EST_OVERLAPS_INTRON");
&delete_anomalies("OST_OVERLAPS_INTRON");
&delete_anomalies("RST_OVERLAPS_INTRON");
&delete_anomalies("MRNA_OVERLAPS_INTRON");
&delete_anomalies("INCOMPLETE_PFAM_MOTIF");
&delete_anomalies("UNMATCHED_EXPRESSION");
&delete_anomalies("TWINSCAN_WITH_SIGNALP");
&delete_anomalies("JIGSAW_WITH_SIGNALP");
&delete_anomalies("JIGSAW_DIFFERS_FROM_CDS");
&delete_anomalies("CDS_DIFFERS_FROM_JIGSAW");


# if we want the anomalies GFF file
if ($supplementary) {
  my $gff_file = "$database/CHROMOSOMES/SUPPLEMENTARY_GFF/${species}_curation_anomalies.gff";
  open (OUTPUT_GFF, ">$gff_file") || die "Can't open $gff_file";      
}


my $ace_output = $wormbase->wormpub . "/CURATION_DATA/anomalies_$species.ace";
open (OUT, "> $ace_output") || die "Can't open $ace_output to write the Method\n";
print OUT "\n\n";
print OUT "Method : \"curation_anomaly\"\n";
print OUT "Colour   RED\n";
print OUT "Strand_sensitive Show_up_strand\n";
print OUT "Right_priority   1.45\n";
print OUT "Width   2\n";
print OUT "Score_by_width\n";
print OUT "Score_bounds 0.01 1.0\n";
print OUT "Remark \"This method is used by acedb to display curation anomaly regions\"\n";
print OUT "\n\n";
close(OUT);

my $brugia_count_contigs = 0;	# in brugia count the contigs that we test

# loop through the chromosomes
my @chromosomes = $wormbase->get_chromosome_names(-mito => 0, -prefix => 1);

foreach my $chromosome (@chromosomes) {

  # get the Overlap object
  $ovlp = Overlap->new($database, $wormbase);

# for brugia, test to see if the jigsaw and tigr genes are the same -
# it so then we don't need to get their anomalies for this test as
# there is no difference between them
  if ($species =~ /brugia/) {

    # don't bother to test the degenerate contigs
    if ($chromosome =~ /supercontigDegenerate/) {next;}

# taken from get_Coding_transcript_exons
    my %GFF_data = 
	(
	 file		=> "~wormpub/DATABASES/TEST_DATABASES/brugia/brugia/CHROMOSOMES/${chromosome}.gff", # jigsaw
	 gff_source		=> "jigsaw", # jigsaw
	 gff_type		=> "exon", # jigsaw
	 ID_after		=> "CDS\\s+", # jigsaw
	 );

    my @jigsaw_exons = $ovlp->read_GFF_file($chromosome, \%GFF_data);

    %GFF_data = 
	(
	 file		=> "~wormpub/DATABASES/TEST_DATABASES/brugia/brugia/CHROMOSOMES2/brugia/${chromosome}.gff3",
	 gff_source		=> "WormBase",
	 gff_type		=> "exon",
	 ID_after		=> "Parent=transcript\:",
	 );

    my @tigr_exons = $ovlp->read_GFF_file($chromosome, \%GFF_data);

    my $match = 1;
    if (@jigsaw_exons == @tigr_exons) {
      foreach my $jigsaw (@jigsaw_exons) {
	my $tigr = shift @tigr_exons;
	if ($jigsaw->[1] != $tigr->[1] || $jigsaw->[2] != $tigr->[2]) {
	  $match = 0; # difference in lengths, so not a perfect match
	  print "no match in $jigsaw->[1] .. $jigsaw->[2] vs $tigr->[1] .. $tigr->[2]\n";
	}
      }
    } else {
      print "different number of exons: ", scalar @jigsaw_exons, " ", scalar @tigr_exons, "\n";
      $match = 0;		# different numbers of exons, so not a perfect match
    }
    if ($match) {
      print "NOT testing $chromosome - both the same. Have done: $brugia_count_contigs contigs\n";
      next;  # both sets of exons are the same, so don't test this supercontig
    }		
    $brugia_count_contigs++;
    print "TESTING $chromosome. Have done: $brugia_count_contigs contigs\n";
  }


  $log->write_to("Processing chromosome $chromosome\n");

  print "reading GFF data\n";
  my @est_hsp = $ovlp->get_EST_BEST($chromosome);                      # EST hits (exons)
  #my @est_paired_span = $ovlp->get_paired_span(@est_hsp); # change the ESTs from HSPs to start-to-end span of paired reads
  my @rst_hsp = $ovlp->get_RST_BEST($chromosome);
  my @ost_hsp = $ovlp->get_OST_BEST($chromosome);
  my @mrna_hsp = $ovlp->get_mRNA_BEST($chromosome);

  my @CDS = $ovlp->get_curated_CDS($chromosome);                       # coding transcript (START to STOP)
  my @pseudogenes = $ovlp->get_pseudogene($chromosome);                
  my @coding_transcripts = $ovlp->get_Coding_transcripts($chromosome); # coding transcripts with UTRs
  my @transposons = $ovlp->get_transposons($chromosome);

  my @cds_exons  = $ovlp->get_curated_CDS_exons($chromosome);          # coding exons (START to STOP) 
  my @transposon_exons = $ovlp->get_transposon_exons($chromosome);
  my @noncoding_transcript_exons = $ovlp->get_Non_coding_transcript_exons($chromosome);
  my @coding_transcript_exons = $ovlp->get_Coding_transcript_exons($chromosome); # exons of complete transcript with UTRs

  my @CDS_introns = $ovlp->get_CDS_introns($chromosome);               # coding introns

  my @TSL_SL1 = $ovlp->get_TSL_SL1($chromosome);
  my @TSL_SL2 = $ovlp->get_TSL_SL2($chromosome);

  my @homologies = $ovlp->get_blastx_homologies($chromosome);

  my @twinscan_exons = $ovlp->get_twinscan_exons($chromosome);
  my @twinscan_transcripts = $ovlp->get_twinscan_transcripts($chromosome);

  my @genefinder = $ovlp->get_genefinder_exons($chromosome);

  my @jigsaw = $ovlp->get_jigsaw_CDS($chromosome);                     # jigsaw coding transcript (START to STOP)
  my @jigsaw_exons = $ovlp->get_jigsaw_exons($chromosome);             # jigsaw coding exons 

  my @UTRs_5 = $ovlp->get_5_UTRs($chromosome);
  my @UTRs_3 = $ovlp->get_3_UTRs($chromosome);

  my @rRNA = $ovlp->get_rRNA_transcripts($chromosome);
  my @miRNA = $ovlp->get_miRNA($chromosome);
  my @ncRNA = $ovlp->get_ncRNA($chromosome);
  my @scRNA = $ovlp->get_scRNA($chromosome);
  my @snRNA = $ovlp->get_snRNA($chromosome);
  my @snoRNA = $ovlp->get_snoRNA($chromosome);
  my @stRNA = $ovlp->get_stRNA($chromosome);
  my @tRNA = $ovlp->get_tRNA($chromosome);
  my @tRNAscan_SE_1_23 = $ovlp->get_tRNAscan_SE_1_23RNA($chromosome);

  my @waba_coding = $ovlp->get_waba_coding($chromosome);
  my @repeatmasked = $ovlp->get_repeatmasked($chromosome);
  my @repeatmasked_complex = $ovlp->get_repeatmasked_complex(@repeatmasked);
  my @mass_spec_peptides = $ovlp->get_mass_spec_peptides($chromosome);
  my @SAGE_tags = $ovlp->get_SAGE_tags($chromosome);

  my @check_introns_EST  = $ovlp->get_check_introns_EST($chromosome);
  my @check_introns_cDNA = $ovlp->get_check_introns_cDNA($chromosome);

  my @expression = &get_expression($chromosome) if (exists $run{UNMATCHED_EXPRESSION});


######################################################################

  print "finding anomalies\n";

#  if (0) {

  print "finding protein homologies not overlapping CDS exons\n";
  my $matched_protein_aref = &get_protein_differences(\@cds_exons, \@pseudogenes, \@homologies, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome) if (exists $run{UNMATCHED_PROTEIN});

  print "finding frameshifts\n";
  &get_frameshifts(\@homologies, \@CDS_introns, $chromosome) if (exists $run{FRAMESHIFTED_PROTEIN});

  print "finding genes to be split/merged based on protein homology\n";
  &get_protein_split_merged($matched_protein_aref, $chromosome) if (exists $run{MERGE_GENES_BY_PROTEIN});

  print "finding genes to be split based on protein homology groups\n";
  &get_protein_split($matched_protein_aref, $chromosome) if (exists $run{SPLIT_GENE_BY_PROTEIN_GROUPS});

  print "finding short CDS exons\n";
  &get_short_exons(\@coding_transcripts, $chromosome) if (exists $run{SHORT_EXON});

  # this finds TEC-RED TSL sites more than 100 bases upstream that are not mentioned in the remarks or evidence
  print "finding isolated TSL sites\n";
  &get_isolated_TSL(\@TSL_SL1, \@TSL_SL2, \@CDS, \@coding_transcripts, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome) if (exists $run{UNMATCHED_TSL});

  print "finding twinscan exons not overlapping CDS exons\n";
  &get_unmatched_twinscan_exons(\@twinscan_exons, \@cds_exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, \@repeatmasked_complex, $chromosome) if (exists $run{UNMATCHED_TWINSCAN});

  print "finding genefinder exons not overlapping CDS exons\n";
  &get_unmatched_genefinder_exons(\@genefinder, \@cds_exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, \@repeatmasked_complex, $chromosome) if (exists $run{UNMATCHED_GENEFINDER});


  print "finding WABA coding regions not overlapping CDS exons\n";
  &get_unmatched_waba_coding(\@waba_coding, \@cds_exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, \@repeatmasked_complex, $chromosome) if (exists $run{UNMATCHED_WABA});

  print "finding CDS exons overlapping repeatmasker regions\n";
  &get_matched_repeatmasker(\@cds_exons, \@repeatmasked_complex, $chromosome) if (exists $run{REPEAT_OVERLAPS_EXON});

  print "finding CDS exons overlapping other genes\n";
  &get_matched_exons(\@cds_exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome) if (exists $run{OVERLAPPING_EXONS});

  print "finding EST/genome mismatches\n";
  &get_est_mismatches(\@est_hsp, $chromosome) if (exists $run{UNMATCHED_EST});

  print "finding weak CDS exon splice sites\n";
  &get_weak_exon_splice_sites(\@CDS_introns, $chromosome) if (exists $run{WEAK_INTRON_SPLICE_SITE});

  print "finding multiple UTR introns\n";
  &get_multiple_utr_introns(\@UTRs_5, $chromosome) if (exists $run{INTRONS_IN_UTR});
  &get_multiple_utr_introns(\@UTRs_3, $chromosome) if (exists $run{INTRONS_IN_UTR});

  print "read confirmed checked introns\n";
  &get_checked_confirmed_introns(\@check_introns_EST, \@check_introns_cDNA, $chromosome) if (exists $run{CONFIRMED_INTRON});

  print "finding genes to be split/merged based on twinscan\n";
  &get_twinscan_split_merged(\@twinscan_transcripts, \@CDS, $chromosome) if (exists $run{MERGE_GENES_BY_TWINSCAN});

  print "finding unmatched mass spec peptides\n";
  &get_unmatched_mass_spec_peptides(\@mass_spec_peptides, \@cds_exons, \@transposon_exons, $chromosome) if (exists $run{UNMATCHED_MASS_SPEC_PEPTIDE});

  print "finding introns refuted by EST\n";
  &get_introns_refuted_by_est(\@CDS_introns, \@cds_exons, \@est_hsp, \@rst_hsp, \@ost_hsp, \@mrna_hsp, $chromosome) if (exists $run{EST_OVERLAPS_INTRON});

  print "finding unmatched high expression regions\n";
  &get_expression_outside_transcripts(\@expression,
				      \@twinscan_exons,
				      \@coding_transcript_exons, 
				      \@pseudogenes, 
				      \@transposons, 
				      \@transposon_exons, 
				      \@noncoding_transcript_exons,  
				      \@rRNA, 
				      \@miRNA, 
				      \@ncRNA, 
				      \@scRNA, 
				      \@snRNA, 
				      \@snoRNA, 
				      \@stRNA, 
				      \@tRNA, 
				      \@tRNAscan_SE_1_23, 
				      $chromosome) if (exists $run{UNMATCHED_EXPRESSION});

  print "finding confirmed introns not matching CDS introns - for brugia\n"; 
  &get_unconfirmed_introns(\@est_hsp, \@mrna_hsp, \@CDS_introns, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome) if (exists $run{UNCONFIRMED_INTRON});

  print "finding isolated RST5\n";
  &get_isolated_RST5(\@rst_hsp, \@CDS, \@coding_transcripts, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome) if (exists $run{UNMATCHED_RST5});

#}

  print "get jigsaw different to curated CDS\n";
  my @unmatched_jigsaw = &get_jigsaw_different_to_curated_CDS(\@jigsaw_exons, \@cds_exons, \@pseudogenes, $chromosome) if (exists $run{JIGSAW_DIFFERS_FROM_CDS});

  print "get jigsaw differing from curated CDS with SignalP where the CDS has no signalP\n";
  &get_jigsaw_with_signalp(\@unmatched_jigsaw, \@jigsaw_exons, \@CDS, $chromosome) if (exists $run{JIGSAW_WITH_SIGNALP});



#################################################
# these don't work very well - don't use

##  this looks at the ESTs  finds those not attached to a transcript
##  print "finding ESTs sites not attached to a transcript\n";
##  &get_unattached_EST(\@est_hsp, $chromosome) if (exists $run{UNATTACHED_EST});

##  # ESTs not matching exons
##  # and those with a match to a coding exon
##  print "finding EST homologies not overlapping exons\n";
##  my $matched_EST_aref = &get_EST_differences(\@exons, \@pseudogenes, \@est_hsp, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome) if (exists $run{UNMATCHED_EST});

##  print "finding split/merged genes based on EST homology\n";
##  &get_EST_split_merged($matched_EST_aref, $chromosome, %Show_in_reverse_orientation) if (exists $run{MERGE_GENES_BY_EST});

#################################################
# we don't value these anomalies very much - don't run them for now

#  # this looks at the EST TSL sites and finds those not attached to genes
#  print "finding TSL sites not attached to genes\n";
#  &get_unattached_TSL(\@TSL_SL1, \@TSL_SL2, $chromosome) if (exists $run{UNATTACHED_TSL});

#  # get SAGE tags that don't match a gene with score based on frequency
#  print "finding non-overlapping SAGE_tags\n";
#  &get_unmatched_SAGE(\@coding_transcripts, \@pseudogenes, \@SAGE_tags, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, \@miRNA, \@ncRNA, \@scRNA, \@snRNA, \@snoRNA, \@stRNA, \@tRNA, \@tRNAscan_SE_1_23, $chromosome) if (exists $run{UNMATCHED_SAGE});


#################################################





}


# get the incomplete Pfam motif anomalies - this is currently chromosome independent
&find_incomplete_pfam_motifs() if (exists $run{INCOMPLETE_PFAM_MOTIF});

# close the output datafile for St. Louis
if ($datafile) {
  close(DAT);			
}

# close the ouput GFF file
if ($supplementary) {
  close (OUTPUT_GFF);
}

# output file of repeat motifs that overlap coding exons
my $repeatsfile = $wormbase->wormpub . "/CURATION_DATA/repeats_overlapping_exons_$species.dat";
open (REPEATS, "> $repeatsfile") || die "Can't open $repeatsfile\n";
print REPEATS "# Frequencies of repeat motifs overlapping coding exons by more than 20 bases\n\n";
foreach my $repeat (sort {$repeat_count{$a} <=> $repeat_count{$b} } keys %repeat_count) { # sort the keys by the value to get a nice table
  print REPEATS "$repeat\t$repeat_count{$repeat}\n";
}
close(REPEATS);			

# output file of ESTs with small mismatches to the genomic sequence
my $est_mismatch_file = $wormbase->wormpub . "/CURATION_DATA/est_mismatch_genome_$species.dat";
open (EST_MISMATCH, "> $est_mismatch_file") || die "Can't open $est_mismatch_file\n";
print EST_MISMATCH "# ESTs which have small mismatches to the genomic sequence\n";
print EST_MISMATCH "# EST\tchromosome\tstart\tend\tstrand\tproportion of ESTs mismatching\n\n";
foreach my $mismatch (@est_mismatches) {
  print EST_MISMATCH "@{$mismatch}\n";
}
close(EST_MISMATCH);

# close the ACE connection
$ace->close;


##################
# Check the files
##################

if ($database eq $wormbase->{'autoace'}) {
  my $gff_file = $wormbase->{'chromosomes'} . "/SUPPLEMENTARY_GFF/curation_anomalies.gff";
  $wormbase->check_file($gff_file, $log,
			minsize => 700000,
			lines => ['^##',
				  "^\\S+\\s+curation_anomaly\\s+\\S+\\s+\\d+\\s+\\d+\\s+\\S+\\s+[-+\\.]\\s+\\S+\\s+Evidence\\s+\\S+"],
			);
}

# report the numbers of anomalies found
$log->write_to("\n");
foreach my $anomaly_type (keys %anomaly_count) {
  my $count = $anomaly_count{$anomaly_type};
  my $error_msg;
  if ($count == 0) {
    $error_msg = "*** POSSIBLE ERROR";
    $log->error;
  } else {
    $error_msg = "";
  }
  $log->write_to("$anomaly_type\t$count\t$error_msg\n");
}

$log->mail();
print "Finished.\n" if ($verbose);
exit(0);






##############################################################
#
# Subroutines
#
##############################################################

##############################################################
# get the GFF data of the tiling array high expression regions
# precomputed by ~gw3/Dev/TilingArrays/tiling_array_to_GFF.pl

sub get_expression {
  my ($chromosome) = @_;

  if ($wormbase->species eq 'elegans') {

  my %GFF_data = 
   (
    file => "~wormpub/CURATION_DATA/Tiling_array_data/tiling_array_${chromosome}.gff",
    gff_source => 'tiling_array',
    gff_type   => 'tiling_array',
    ID_after   => 'ID\s+',
    );

  return $ovlp->read_GFF_file($chromosome, \%GFF_data);

} else {
  return ();
}

}

##########################################
# get the homologies with no matching exons or pseudogenes or transposons
# and those which do match exons or transposons (but not pseudogenes)

#  my @matched_homologies = get_differences(\@transcripts, \@pseudogenes, \@protein_coverage);

sub get_protein_differences {
  my ($exons_aref, $pseudogenes_aref, $homologies_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_PROTEIN} = 0 if (! exists $anomaly_count{UNMATCHED_PROTEIN});

  my @homologies = @{$homologies_aref};

  my @not_matched = ();		# the resulting list of hashes of homologies with no matching exons/transposons/pseudogenes
  my @matched = ();		# the resulting list of hashes of homologies which match a coding exon
  my @matching_exons;
  my %sorted_proteins;		# protein hash keyed by protein name holding the homology and match data to find unmatched proteins that have other local matches

  my $SMALL_OVERLAP = -20;	# amount of small overlap to ignore
      
  # we allow the protein to be in either sense compared to the coding exons
  my $exons_match = $ovlp->compare($exons_aref, near => $SMALL_OVERLAP, same_sense => 0);
  my $pseud_match = $ovlp->compare($pseudogenes_aref);
  my $trans_match = $ovlp->compare($transposons_aref);
  my $trane_match = $ovlp->compare($transposon_exons_aref);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref);
  my $rrna_match  = $ovlp->compare($rRNA_aref);

  foreach my $homology (@homologies) { # $protein_id, $chrom_start, $chrom_end, $chrom_strand

    my $protein_name = $homology->[0];
    my $protein_score = $homology->[6];

    # don't want the low-scoring trembl proteins - they are not informative
    if ($protein_name =~ /TR:/ &&  $protein_score < 200) {next;}

    # don't want any protein less than 100 - too much noise
    if ($protein_score < 100) {next;}

    my $got_a_match = 0;	        # not yet seen a match to anything
    my $got_a_match_to_coding_exon = 0;	# not yet seen a match to a coding exon
    my $matching_exon = "";	        # the name of the exon that matches;
    my $match_in_same_sense = 0;        # default is assumed to be a match in the opposite sense

    if (@matching_exons = $exons_match->match($homology)) {               #&match($homology, $exons_aref, \%exons_match)) 
      $got_a_match = 1;
      $got_a_match_to_coding_exon = 1;
      $matching_exon = $matching_exons[0][0];
      if (grep /1/, $exons_match->matching_sense) {$match_in_same_sense = 1;}
    }

    if ( $pseud_match->match($homology)) {              #&match($homology, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
    }

    if (@matching_exons = $trans_match->match($homology)) {               #&match($homology, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
      $got_a_match_to_coding_exon = 1;
      $matching_exon = $matching_exons[0][0];
      if (grep /1/, $exons_match->matching_sense) {$match_in_same_sense = 1;}
    }

    if ($trane_match->match($homology)) {               #&match($homology, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
    }

    if ($nonco_match->match($homology)) {               #&match($homology, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
    }

    if ($rrna_match->match($homology)) {                #&match($homology, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    # store the homology object in a hash keyed by its name together with its 'match' status
    # 
    # here we want a NEW COPY of the data in $homology, not just a copy of
    # the reference pointing to the same data, so we force this by getting
    # the array and making a new [] reference to it, then we won't have a
    # problem when we push $matching_exon on the end of $homology in the
    # next section
    # 
    my $tmp_homology = [@{$homology}]; 
    push @{$tmp_homology}, $got_a_match;
    push @{$sorted_proteins{$protein_name}}, $tmp_homology;

    # add to the list of homologies to a coding regions
    if ($got_a_match_to_coding_exon && $match_in_same_sense) { # only want the protein matches in the same sense as the genes
      push @{$homology}, $matching_exon; # make a note of the exon we matched
      push @matched, $homology;
    }
  }


  # now find the proteins that have other local matches (within 2 Kb)
  # and which have the same score (so are probably HSPs from the same alignment)
  # but which do not have a match to a gene
  foreach my $prot_name (keys %sorted_proteins) {
    for (my $i = 0; $i < @{$sorted_proteins{$prot_name}}; $i++) {
      my $homology = $sorted_proteins{$prot_name}->[$i];
      my $got_a_match = $homology->[8];
      my $protein_id = $homology->[0];
      my $chrom_start = $homology->[1];
      my $chrom_end = $homology->[2];
      my $chrom_strand = $homology->[3];
      my $protein_score = $homology->[6];
      # make the anomaly score based on the protein alignment score normalised between 1 and 3
      # using the log10 of the blast score
      # the BLAST scores seem to be between 0 and 1000
      # use the average of the two alignment's scores
      my $anomaly_score = POSIX::log10($protein_score);
      if ($anomaly_score > 3) {$anomaly_score = 3;}
      if ($anomaly_score < 0) {$anomaly_score = 0;}
	
      my $prev_homology = undef;
      my $next_homology = undef;
      $prev_homology = $sorted_proteins{$prot_name}->[$i-1] unless ($i == 0);
      $next_homology = $sorted_proteins{$prot_name}->[$i+1] unless ($i == @{$sorted_proteins{$prot_name}} - 1);

      if      (! $got_a_match && defined $prev_homology && $chrom_start - $prev_homology->[2] < 2000 && $prev_homology->[3] eq $chrom_strand && $protein_score == $prev_homology->[6]) {
	#print "UNMATCHED_PROTEIN, $chromosome, $protein_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
	&output_to_database("UNMATCHED_PROTEIN", $chromosome, $protein_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
      } elsif (! $got_a_match && defined $next_homology && $next_homology->[1] - $chrom_end < 2000   && $next_homology->[3] eq $chrom_strand && $protein_score == $next_homology->[6]) {
	#print "UNMATCHED_PROTEIN, $chromosome, $protein_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
	&output_to_database("UNMATCHED_PROTEIN", $chromosome, $protein_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
      }
    }
  }

  return (\@matched);
}

##########################################
# get the EST homologies with no matching exons or pseudogenes or transposons
# and those which do match exons or transposons (but not pseudogenes)
# my $matched_EST_aref = &get_EST_differences(\@exons, \@pseudogenes, \@est, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, $chromosome);

sub get_EST_differences {
  my ($exons_aref, $pseudogenes_aref, $est_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_EST} = 0 if (! exists $anomaly_count{UNMATCHED_EST});

  my @est = @{$est_aref};

  my @not_matched = ();		# the resulting list of hashes of est with no matching exons/transposons/pseudogenes
  my @matched = ();		# the resulting list of hashes of est which match a coding exon
  my @matching_exons;

  my $exons_match = $ovlp->compare($exons_aref, same_sense => 1);
  my $pseud_match = $ovlp->compare($pseudogenes_aref);
  my $trans_match = $ovlp->compare($transposons_aref);
  my $trane_match = $ovlp->compare($transposon_exons_aref);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref);
  my $rrna_match  = $ovlp->compare($rRNA_aref);


  foreach my $homology (@est) { # $est_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;	        # not yet seen a match to anything
    my $got_a_match_to_coding_exon = 0;	# not yet seen a match to a coding exon
    my $matching_exon = "";	        # the name of the exon that matches;

    if (@matching_exons = $exons_match->match($homology)) {               #&match($homology, $exons_aref, \%exons_match)) 
      $got_a_match = 1;
      $got_a_match_to_coding_exon = 1;
      $matching_exon = $matching_exons[0][0];
    }

    if ($pseud_match->match($homology)) {              #&match($homology, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
    }

    if (@matching_exons = $trans_match->match($homology)) {               #&match($homology, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
      $got_a_match_to_coding_exon = 1;
      $matching_exon = $matching_exons[0][0];
    }

    if ($trane_match->match($homology)) {               #&match($homology, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
    }

    if ($nonco_match->match($homology)) {               #&match($homology, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
    }

    if ($rrna_match->match($homology)) {                #&match($homology, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    # output unmatched est to the database
    if (! $got_a_match) {
      my $est_id = $homology->[0];
      my $chrom_start = $homology->[1];
      my $chrom_end = $homology->[2];
      my $chrom_strand = $homology->[3];
      my $est_score = $homology->[6];
      # make the anomaly score based on the protein alignment score normalised between 0 and 1
      # BLAT scores are between 0 and 100
      my $anomaly_score = $est_score/100;
      if ($anomaly_score > 1) {$anomaly_score = 1;}
      if ($anomaly_score < 0) {$anomaly_score = 0;}
      #print "NOT got an EST match ANOMALY: $est_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_EST", $chromosome, $est_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }

    # add to the list of homologies to a coding regions
    if ($got_a_match_to_coding_exon) {
      push @{$homology}, $matching_exon; # make a note of the exon we matched
      push @matched, $homology;

    }
  }

  return (\@matched);
}

##########################################

# get the frameshifts evident in adjacent homologies of a group of HSPs for proteins

#  my @frameshifts = get_frameshifts(\@homologies, \@CDS_introns);

sub get_frameshifts {
  my ($homologies_aref, $CDS_introns_aref, $chromosome) = @_;

  $anomaly_count{FRAMESHIFTED_PROTEIN} = 0 if (! exists $anomaly_count{FRAMESHIFTED_PROTEIN});

  my $SCORE_THRESHOLD = 40;
  my $MAX_CHROM_DIFF = 15;	# maximum distance that the ends of the alignment are allowed to be on the chromosome
  my $MIN_CHROM_DIFF = -25;	# minimum distance that the ends of the alignment are allowed to be on the chromosome
  my $MAX_PROT_DIFF = 15;	# maximum distance that the ends of the HSPs are allowed to be from each other in the protein



  ###########################################
  # find out which introns are confirmed
  ###########################################
  my @confirmed_introns;

  foreach my $intron (@{$CDS_introns_aref}) { # $intron_id, $chrom_start, $chrom_end, $chrom_strand, other

    my $other_data = $intron->[4];
    if (defined $other_data) {	# in some species we may not have this cnofirmed information
      if ($other_data =~ /Confirmed_/) { # test to see if this intron is confirmed
	push @confirmed_introns, $intron;
      }
    }

  }

  ###########################################
  # find the frameshifts
  ###########################################

  # sort the homologies grouped by protein ID and then score and then chromosomal position
  my @homologies = sort {$a->[0] cmp $b->[0] or $a->[6] <=> $b->[6] or $a->[1] <=> $b->[1]} @{$homologies_aref};

  # for each protein, compare all if HSPs with all its downstream HSPs
  for (my $i = 0; $i < scalar @homologies; $i++) {
    my $homology = $homologies[$i];
    my $prev_protein_id = $homology->[0];
    my $prev_chrom_start = $homology->[1];
    my $prev_chrom_end = $homology->[2];
    my $prev_hit_end = $homology->[5];
    my $prev_protein_score = $homology->[6];
    if ($prev_protein_score < $SCORE_THRESHOLD) {next;} # only look at high-scoring proteins

    # get the next downstream HSP
    for (my $j = $i+1; $j < scalar @homologies; $j++) {
      if ($homologies[$j]->[0] ne $prev_protein_id) {last;} # no longer looking at HSPs of the same protein
      if ($homologies[$j]->[6] != $prev_protein_score) {last;} # no longer looking at HSPs of an alignment with all the same score
      if ($homologies[$j]->[6] < $SCORE_THRESHOLD) {next;} # only look at high-scoring proteins
      my $protein_id = $homologies[$j]->[0];
      my $chrom_start = $homologies[$j]->[1];
      my $chrom_strand = $homologies[$j]->[3];
      my $hit_start = $homologies[$j]->[4];
      my $protein_score = $homologies[$j]->[6];

      my $chrom_diff = $chrom_start - $prev_chrom_end;
      my $prot_diff = $hit_start - $prev_hit_end;

      # get the difference in the frame aligned to
      # if diff % 2 is not 1 then it is a frameshift
      my $frameshift = (abs($chrom_diff) % 3) - 1; 

      # if we are getting too far away from the end of $homologies[$i], then increment $i to stop searching it
      if ($chrom_diff > $MAX_CHROM_DIFF) {last;}

      #print "$prev_protein_id $prev_chrom_start..$prev_chrom_end ($i) $protein_id $chrom_start.. ($j) chrom_diff $chrom_diff prot_diff $prot_diff frameshift $frameshift protein_score $protein_score prev_protein_score $prev_protein_score\n";

      # output any frameshifts found to the database
      # want the frame to have changed, so look at the chrom_start to prev_chrom_end difference mod 3
      if ($frameshift && $chrom_diff > $MIN_CHROM_DIFF && $chrom_diff < $MAX_CHROM_DIFF && abs($prot_diff) < $MAX_PROT_DIFF) {

	# make a dummy GFF line for this frameshift
	my $homol = [$prev_protein_id, $prev_chrom_end, $chrom_start, $chrom_strand]; 
	# see if the line overlaps a confirmed intron, if so then ignore it
	# start a new search every time because the protein homologies are not sorted in chromosomal order
	my $confirmed_match  = $ovlp->compare(\@confirmed_introns, same_sense => 1);
	if ($confirmed_match->match($homol)) {next;}

	# get the region to display
	my $anomaly_start = $prev_chrom_end;
	my $anomaly_end = $chrom_start;
	# get the start and end in the right order
	if ($anomaly_end < $anomaly_start) {
	  my $tmp = $anomaly_end;
	  $anomaly_end = $anomaly_start;
	  $anomaly_start = $tmp; 
	}
	# expand the region to display a little
	$anomaly_start -= 10;
	$anomaly_end += 10;

	# make the anomaly score based on the protein alignment score normalised between 1 and 3
	# using the log10 of the blast score
	# the BLAST scores seem to be between 0 and 1000
	# use the average of the two alignment's scores
	my $average_blast_score = ($protein_score+$prev_protein_score)/2;
	my $anomaly_score = POSIX::log10($average_blast_score);
	if ($anomaly_score > 3) {$anomaly_score = 3;}
	if ($anomaly_score < 0) {$anomaly_score = 0;}

	#print "FRAMESHIFTED_PROTEIN ANOMALY: $protein_id, $anomaly_start, $anomaly_end, $chrom_strand, $anomaly_score\n";
	&output_to_database("FRAMESHIFTED_PROTEIN", $chromosome, $protein_id, $anomaly_start, $anomaly_end, $chrom_strand, $anomaly_score, "Between protein positions: $prev_hit_end, $hit_start");
      }
    }
  }
}



##########################################

#  my @split_merged = &get_split_merged($matched_aref);

# find groups of homology that indicate that the genes they match should be split or merged
# look for non-overlapping HSPs that jump back down the position in the protein that is aligned as you move along the chromosome -> split
# look for matches to exons with HSPs that do not jump back down the position in the protein that is aligned as you move along the chromosome -> merge

sub get_protein_split_merged {
  my ($matched_aref, $chromosome) = @_;

  $anomaly_count{MERGE_GENES_BY_PROTEIN} = 0 if (! exists $anomaly_count{MERGE_GENES_BY_PROTEIN});
  $anomaly_count{SPLIT_GENES_BY_PROTEIN} = 0 if (! exists $anomaly_count{SPLIT_GENES_BY_PROTEIN});

  my @matched = @{$matched_aref};

  my $prev_protein_id = "";	# use to collect alignments for a protein's homology when looking for frameshifts
  my $prev_exon = "";
  my $prev_hit_start = -1;
  my $prev_hit_end = -1;
  my $prev_chrom_start = -1;
  my $prev_chrom_end = -1;
  my $prev_score = 0;
  my $prev_chrom_strand = "";

  my $got_a_new_exon;
  my $got_a_big_decrease_in_HSP_start;
  my $got_a_continuation_of_the_HSPs;
  my $average_blast_score;
  my $anomaly_score;

  # sort the homologies grouped by protein ID and then score and then chromosomal position
  #my @homologies = sort {$a->[0] cmp $b->[0] or $a->[1] <=> $b->[1]} @matched;
  my @homologies = sort {$a->[0] cmp $b->[0] or $a->[6] <=> $b->[6] or $a->[1] <=> $b->[1]} @matched;

  foreach my $homology (@homologies) { # $protein_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $protein_score, $matching_exon, $matching_sense

    my $protein_id = $homology->[0];
    my $chrom_start = $homology->[1];
    my $chrom_end = $homology->[2];
    my $chrom_strand = $homology->[3];
    my $hit_start = $homology->[4];
    my $hit_end = $homology->[5];
    my $protein_score = $homology->[6];
    # $homology->[7] can hold the the other_data field from the GFF line, but is usually undef
    my $matching_exon = $homology->[8];

    # we don't use the briggsae or remanei proteins in this analysis
    # because their predictions are heavily based on twinscan
    # predictions and so we would be simply confirming possibly
    # erroneous twinscan data.
    if ($protein_id =~ /^BP:/ || $protein_id =~ /^RP:/) {next;}

    #  check if these are isoforms of the same gene and if so then treat them as the same gene
    if ($matching_exon =~ /(\S+\.\d+)[a-z]/) {
      $matching_exon = $1;
    }
    # and change the strange transcript names like H25P06.1.1, H25P06.1.2 to H25P06.1
    if ($matching_exon =~ /(\S+\.\d+)\.\d+/) {
      $matching_exon = $1;
    }

    #print "Matched: $protein_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $protein_score, $matching_exon\n";

    # look for homologies which cover two genes or genes which cover a repeated homology
    if ($protein_id eq $prev_protein_id && $protein_score == $prev_score && $chrom_strand eq $prev_chrom_strand) {

      # see if exon has changed
      if ($prev_exon ne "" && $prev_exon ne $matching_exon) {
	$got_a_new_exon = 1;
	#print "Merge? prev $prev_exon this $matching_exon\n";
      } else {
	$got_a_new_exon = 0;
      }

      # see if the protein HSP order is unchanged - a possible case for merging if continued over into the next gene
      # same sense, non-overlapping on the chromosome and jump in HSP start
      #
      # We want to avoid picking up the case where there are two duplicated single-exon genes
      # and the homologies have a hit_start that differs by only a few bases - this should be ignored.
      # So we look for cases where the start continues as greater than
      # the previous mid point for evidence of a possible merge.
      #
      my $prev_midpoint = $prev_hit_start + ($prev_hit_end - $prev_hit_start)/2;
      my $midpoint = $hit_start + ($hit_end - $hit_start)/2;
      if (($chrom_strand eq '+' && $prev_chrom_end < $chrom_start && $hit_start > $prev_midpoint) ||
	  ($chrom_strand eq '-' && $prev_chrom_end < $chrom_start && $hit_start < $prev_midpoint && $prev_hit_start != -1)) {
	$got_a_continuation_of_the_HSPs = 1;
      } else {
	$got_a_continuation_of_the_HSPs = 0;
      }
      
      # see if we have a big decrease in the start of the HSP - a possible case for splitting
      if (($chrom_strand eq '+' && $prev_chrom_end < $chrom_start && ($prev_hit_start > $hit_start + 100 || ($prev_hit_end > 100 && $hit_start < 30))) ||
	  ($chrom_strand eq '-' && $prev_chrom_end < $chrom_start && ($prev_hit_start < $hit_start - 100 && $prev_hit_start != -1 || ($prev_hit_start < 30 && $hit_start > 100 && $prev_hit_start != -1)))) {
	$got_a_big_decrease_in_HSP_start = 1;
	#print "Split? $protein_id chrom_start $chrom_end prev_chrom_start $prev_chrom_start $chrom_strand prev_hit_start $prev_hit_start hit_start $hit_start\n";
      } else {
	$got_a_big_decrease_in_HSP_start = 0;
      }


      # we have a merge if the pattern of HSPs shows a continuation of
      # the protein matching in order and this is a new gene and the
      # distance between the alignments is less than 5 kb
      if ($got_a_new_exon && $got_a_continuation_of_the_HSPs && $chrom_start - $prev_chrom_end < 5000) {
	# reject any hits where either of the proteins have a Blast score < 50
	if ($protein_score < 50 || $prev_score < 50) {next;}

	# make the anomaly score based on the protein alignment score normalised between 1 and 3
	# using the log10 of the blast score
	# the BLAST scores seem to be between 0 and 1000
	# use the average of the two alignment's scores
	$average_blast_score = ($protein_score+$prev_score)/2;
	$anomaly_score = POSIX::log10($average_blast_score);
	if ($anomaly_score > 3) {$anomaly_score = 3;}
	if ($anomaly_score < 0) {$anomaly_score = 0;}

	if ($anomaly_score > 0.1) {
	  &output_to_database("MERGE_GENES_BY_PROTEIN", $chromosome, $protein_id, $prev_chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "merge $prev_exon and $matching_exon");
	}

      }

      if ($got_a_big_decrease_in_HSP_start && ! $got_a_new_exon) {
	# reject any hits where either of the proteins have a Blast score < 50
	if ($protein_score < 50 || $prev_score < 50) {next;}

	# make the anomaly score based on the protein alignment score normalised between 1 and 3
	# using the log10 of the blast score
	# the BLAST scores seem to be between 0 and 1000
	# use the average of the two alignment's scores
	$average_blast_score = ($protein_score+$prev_score)/2;
	$anomaly_score = POSIX::log10($average_blast_score);
	if ($anomaly_score > 3) {$anomaly_score = 3;}
	if ($anomaly_score < 0) {$anomaly_score = 0;}

	&output_to_database("SPLIT_GENES_BY_PROTEIN", $chromosome, $protein_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "split $matching_exon");
      }
    }

    $prev_exon = $matching_exon;
    $prev_hit_start = $hit_start;
    $prev_hit_end = $hit_end;
    $prev_score = $protein_score;
    $prev_chrom_start = $chrom_start;
    $prev_chrom_end = $chrom_end;
    $prev_protein_id = $protein_id;
    $prev_chrom_strand = $chrom_strand;
  }

}


##########################################

#  my &get_protein_split($matched_aref, $chromosome);

# find groups of homology that indicate that the genes they match should be split
# look for genes that have two or more non-overlapping groups of homology from different sets of genes

sub get_protein_split {
  my ($matched_aref, $chromosome) = @_;

  $anomaly_count{SPLIT_GENE_BY_PROTEIN_GROUPS} = 0 if (! exists $anomaly_count{SPLIT_GENE_BY_PROTEIN_GROUPS});

  my @matched = @{$matched_aref};

  my $prev_transcript = "";

  my @brigpep = ();
  my @rempep = ();
  my @wormpep = ();

  # sort the homologies grouped by matching transcript and then protein_id
  my @homologies = sort {$a->[8] cmp $b->[8] or $a->[0] cmp $b->[0]} @matched;

  foreach my $homology (@homologies) { # $protein_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $protein_score, $matching_transcript

    my $protein_id = $homology->[0];
    my $chrom_start = $homology->[1];
    my $chrom_end = $homology->[2];
    my $chrom_strand = $homology->[3];
    my $hit_start = $homology->[4];
    my $hit_end = $homology->[5];
    my $protein_score = $homology->[6];
    # $homology->[7] can hold the the other_data field from the GFF line, but is usually undef
    my $matching_transcript = $homology->[8];

    #  check if these are isoforms of the same gene and if so then treat them as the same gene
    if ($matching_transcript =~ /(\S+\.\d+)[a-z]/) {
      $matching_transcript = $1;
    }
    # and change the strange transcript names like H25P06.1.1, H25P06.1.2 to H25P06.1
    if ($matching_transcript =~ /(\S+\.\d+)\.\d+/) {
      $matching_transcript = $1;
    }

    # do we have a new matching transcript? If so, see if the transcript we were doing should be split
    if ($matching_transcript ne $prev_transcript && $prev_transcript ne "") {

      #print "Got all homologies for $prev_transcript\n";

      # check if there are two or more different boxes with more than one protein in them and score over the box cutoff
      # if so, then output a database record for each contributing protein in the boxes
      my @box_results;
      if (@box_results = split_check(@brigpep)) {
	foreach my $pep (@box_results) {
	  my $pep_protein_id = $pep->[0];
	  my $pep_chrom_start = $pep->[1];
	  my $pep_chrom_end = $pep->[2];
	  my $pep_chrom_strand = $pep->[3];
	  my $pep_protein_score = $pep->[6];
	  my $pep_matching_transcript = $pep->[8];

	  # reject any hits where either of the proteins have a Blast score < 50
	  if ($pep_protein_score < 50) {next;}
	  # make the anomaly score based on the protein alignment score normalised between 1 and 3
	  # using the log10 of the blast score
	  # the BLAST scores seem to be between 0 and 1000
	  # use the average of the two alignment's scores
	  my $anomaly_score = POSIX::log10($pep_protein_score);
	  if ($anomaly_score > 3) {$anomaly_score = 3;}
	  if ($anomaly_score < 0) {$anomaly_score = 0;}

	  output_to_database("SPLIT_GENE_BY_PROTEIN_GROUPS", $chromosome, $pep_protein_id, $pep_chrom_start, $pep_chrom_end, $pep_chrom_strand, $anomaly_score, "split $pep_matching_transcript");

	}
      }

      if (@box_results = split_check(@rempep)) {
	foreach my $pep (@box_results) {
	  my $pep_protein_id = $pep->[0];
	  my $pep_chrom_start = $pep->[1];
	  my $pep_chrom_end = $pep->[2];
	  my $pep_chrom_strand = $pep->[3];
	  my $pep_protein_score = $pep->[6];
	  my $pep_matching_transcript = $pep->[8];

	  # reject any hits where either of the proteins have a Blast score < 50
	  if ($pep_protein_score < 50) {next;}
	  # make the anomaly score based on the protein alignment score normalised between 1 and 3
	  # using the log10 of the blast score
	  # the BLAST scores seem to be between 0 and 1000
	  # use the average of the two alignment's scores
	  my $anomaly_score = POSIX::log10($pep_protein_score);
	  if ($anomaly_score > 3) {$anomaly_score = 3;}
	  if ($anomaly_score < 0) {$anomaly_score = 0;}

	  output_to_database("SPLIT_GENE_BY_PROTEIN_GROUPS", $chromosome, $pep_protein_id, $pep_chrom_start, $pep_chrom_end, $pep_chrom_strand, $anomaly_score, "split $pep_matching_transcript");
	}
      }

      if (@box_results = split_check(@wormpep)) {
	foreach my $pep (@box_results) {
	  my $pep_protein_id = $pep->[0];
	  my $pep_chrom_start = $pep->[1];
	  my $pep_chrom_end = $pep->[2];
	  my $pep_chrom_strand = $pep->[3];
	  my $pep_protein_score = $pep->[6];
	  my $pep_matching_transcript = $pep->[8];

	  # reject any hits where either of the proteins have a Blast score < 50
	  if ($pep_protein_score < 50) {next;}
	  # make the anomaly score based on the protein alignment score normalised between 1 and 3
	  # using the log10 of the blast score
	  # the BLAST scores seem to be between 0 and 1000
	  # use the average of the two alignment's scores
	  my $anomaly_score = POSIX::log10($pep_protein_score);
	  if ($anomaly_score > 3) {$anomaly_score = 3;}
	  if ($anomaly_score < 0) {$anomaly_score = 0;}

	  output_to_database("SPLIT_GENE_BY_PROTEIN_GROUPS", $chromosome, $pep_protein_id, $pep_chrom_start, $pep_chrom_end, $pep_chrom_strand, $anomaly_score, "split $pep_matching_transcript");
	}
      }



      # initialise the new lists to be put into boxes
      @brigpep = ();
      @rempep = ();
      @wormpep = ();
    }

    # only want to store details from briggsae, remanei and elegans
    if ($protein_id =~ /^BP:/) {
	
      # add this protein to the list of homologies to be put into boxes
      push @brigpep, $homology;

    } elsif ($protein_id =~ /^RP:/) {

      # add this protein to the list of homologies to be put into boxes
      push @rempep, $homology;

    } elsif ($protein_id =~ /^WP:/) {
      
      # add this protein to the list of homologies to be put into boxes
      push @wormpep, $homology;
    }
    
    $prev_transcript = $matching_transcript;
  }

}

##########################################
#    @box_results = split_check(@wormpep);
# put the homologies into non-overlapping boxes
# find non-overlapping ranges of proteins that do not share protein IDs
# the boxes of protein homology must have at least two different proteins in them and must have a total Blast score greater than 100
# return the list of proteins that contribute to the two or more boxes

sub split_check {
  my (@peplist) = @_;

  my @box_result = ();


  my @boxes = ();
 
  my $last_sense = '';
 
  foreach my $homology (@peplist) {
    my $protein_id = $homology->[0];
    my $chrom_start = $homology->[1];
    my $chrom_end = $homology->[2];
    my $sense = $homology->[3];
    my $hit_start = $homology->[4];
    my $hit_end = $homology->[5];
    my $protein_score = $homology->[6];
    my $matching_transcript = $homology->[8];

    #print "$protein_id $chrom_start $chrom_end\n";

    $last_sense = $sense;
 
    my $got_a_match = 0;

    #print "Have @boxes boxes in the list\n";

    foreach my $box (@boxes) {
      # find an existing box to merge to
      # merge if it contains a previous block of this protein's homology or it has an overlap to this block of homology
      #print "$protein_id Box   " . $box->{'chrom_start'} . " " . $box->{'chrom_end'} . " IDs:  " , @{$box->{'ID'}} , "\n";
      if (((grep /$protein_id/, @{$box->{'ID'}}) ||
	  $box->{'chrom_start'} <= $chrom_end && $box->{'chrom_end'} >= $chrom_start) &&
          ! exists $box->{'deleted'}) {

        #print "*** Box $box->{'chrom_start'}..$box->{'chrom_end'}, matches $protein_id, $chrom_start, $chrom_end, $protein_score\n";

	# add this homology to the box
        $box->{'count'}++;        # add to the count of matches in this box
        $box->{'total_score'} += $protein_score;        # add to the sum of the alignment scores
        push @{$box->{'ID'}}, ($protein_id);        # add to the protein IDs

        # update start/end
        if ($box->{'chrom_start'} > $chrom_start) {$box->{'chrom_start'} = $chrom_start;}
        if ($box->{'chrom_end'} < $chrom_end) {$box->{'chrom_end'} = $chrom_end;}

        $got_a_match = 1;

        # check to see if we now need to merge two overlapping boxes
        my $past_first_box = 0;
        foreach my $other_box (@boxes) {
         if (! $past_first_box) {
            # see if this is our current $box
            if ($other_box->{'chrom_start'} == $box->{'chrom_start'} &&
                $other_box->{'chrom_end'} == $box->{'chrom_end'} &&
                ! exists $other_box->{'deleted'}
                ) {
              $past_first_box = 1;
            }
            next;
          };

          # now start checks for overlaps of boxes
          if (((grep /$protein_id/, @{$other_box->{'ID'}}) ||
	       $other_box->{'chrom_start'} <= $box->{'chrom_end'} && $other_box->{'chrom_end'} >= $box->{'chrom_start'}) &&
              ! exists $other_box->{'deleted'}
              ) {
            $box->{'count'} += $other_box->{'count'};
            $box->{'total_score'} += $other_box->{'total_score'};
            push @{$box->{'ID'}},  @{$other_box->{'ID'}};
            if ($box->{'chrom_start'} > $other_box->{'chrom_start'}) {$box->{'chrom_start'} = $other_box->{'chrom_start'}};
            if ($box->{'chrom_end'} < $other_box->{'chrom_end'}) {$box->{'chrom_end'} = $other_box->{'chrom_end'}};
            # delete the other box
            #print "deleted $other_box->{'type'} $other_box->{'chrom_start'} $other_box->{'chrom_end'} \n";
            $other_box->{'deleted'} = 1; # mark this box as deleted
          }
        }
      }
    }

    # no existing boxes found, so start a new one
    if (! $got_a_match) {
      #print "New box for $protein_id, $chrom_start, $chrom_end, $protein_score\n";
      # want to store: $chromosome_start, $chromosome_end, $sense, $protein_id, $protein_score
      my $new_box = {};             # reference to hash
      $new_box->{'sense'} = $sense;
      $new_box->{'chrom_start'} = $chrom_start;
      $new_box->{'chrom_end'} = $chrom_end;
      $new_box->{'total_score'} = $protein_score;
      push @{$new_box->{'ID'}}, ($protein_id);
      $new_box->{'count'} = 1;
      push @boxes, $new_box;
    }
  }

# now look at each box to see if it has passed our tests
  my $count_of_boxes_passing_tests = 0;
  foreach my $box (@boxes) {
    if (! exists $box->{'deleted'} &&
	$box->{'total_score'} > 200 &&
	$box->{'count'} > 1
	) {
      $count_of_boxes_passing_tests++;
      $box->{'passed_test'} = 1;
      #print "Box passed test with $box->{'chrom_start'}..$box->{'chrom_end'} IDs @{$box->{'ID'}}\n";
    }
  }

# now look to see if we have more than one box and return the details of the IDs in those boxes
  #print "Found $count_of_boxes_passing_tests boxes passing test\n";
  if ($count_of_boxes_passing_tests > 1) {
    foreach my $box (@boxes) {
      if (exists $box->{'passed_test'}) {
	# foreach of the IDs in this box, put the details in @box_result
	foreach my $id (@{$box->{'ID'}}) {
	  foreach my $homology (@peplist) {
	    if ($homology->[0] eq $id) {
	      push @box_result, $homology;
	    }
	  }
	}
      }
    }
  }

  return @box_result
}

##########################################
#
#  &get_EST_split_merged($matched_EST_aref, $chromosome, %Show_in_reverse_orientation);

# find groups of homology that indicate that the genes they match should be split or merged
# look for non-overlapping HSPs that jump back down the position in the protein that is aligned as you move along the chromosome -> split
# look for matches to transcripts with HSPs that do not jump back down the position in the protein that is aligned as you move along the chromosome -> merge

sub get_EST_split_merged {
  my ($matched_EST_aref, $chromosome, %Show_in_reverse_orientation) = @_;

  $anomaly_count{MERGE_GENES_BY_EST} = 0 if (! exists $anomaly_count{MERGE_GENES_BY_EST});
  $anomaly_count{SPLIT_GENES_BY_EST} = 0 if (! exists $anomaly_count{SPLIT_GENES_BY_EST});

  my @matched = @{$matched_EST_aref};

  my $prev_EST_id = "";	# use to collect alignments for a EST's homology when looking for frameshifts
  my $prev_transcript = "";
  my $prev_hit_start = -1;
  my $prev_hit_end = -1;
  my $prev_chrom_start = -1;
  my $prev_chrom_end = -1;
  my $prev_score = 0;
  my $prev_chrom_strand = "";

  my $got_a_new_transcript;
  my $got_a_big_decrease_in_HSP_start;
  my $got_a_continuation_of_the_HSPs;
 

  # sort the homologies grouped by EST ID and then chromosomal position
  my @homologies = sort {$a->[0] cmp $b->[0] or $a->[1] <=> $b->[1]} @matched;

  foreach my $homology (@homologies) { # $EST_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $EST_score, other_data, $matching_transcript

    my $EST_id = $homology->[0];
    my $chrom_start = $homology->[1];
    my $chrom_end = $homology->[2];
    my $chrom_strand = $homology->[3];
    my $hit_start = $homology->[4];
    my $hit_end = $homology->[5];
    my $EST_score = $homology->[6];
    my $matching_transcript = $homology->[8];

    #  check if these are isoforms of the same gene and if so then treat them as the same gene
    if ($matching_transcript =~ /(\S+\.\d+)[a-z]/) {
      $matching_transcript = $1;
    }
    # and change the strange transcript names like H25P06.1.1, H25P06.1.2 to H25P06.1
    if ($matching_transcript =~ /(\S+\.\d+)\.\d+/) {
      $matching_transcript = $1;
    }

    #print "Matched: $EST_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $EST_score, $matching_transcript\n";

    # look for homologies which cover two genes or genes which cover a repeated homology
    if ($EST_id eq $prev_EST_id && $chrom_strand eq $prev_chrom_strand) {

      # see if transcript has changed
      if ($prev_transcript ne "" && $prev_transcript ne $matching_transcript) {
	$got_a_new_transcript = 1;
	#print "Merge? prev $prev_transcript this $matching_transcript\n";
      } else {
	$got_a_new_transcript = 0;
      }

      # see if the EST HSP order is unchanged - a possible case for merging if continued over into the next gene
      # same sense, non-overlapping on the chromosome and jump in HSP start
      #
      # NB. The logic here is slightly different to that used when
      # looking for split/merges by protein homology because the 3'
      # EST reads are in the opposite sense (although the sense has
      # been flipped in the routine that reads them in). The EST
      # hit_start and hit_end positions therefore will be going in the
      # wrong direction in those ESTs, so we need to identify them and
      # account for the hit-positions going the 'wrong' way.
      # 
      # We want to avoid picking up the case where there are two duplicated single-exon genes
      # and the homologies have a hit_start that differs by only a few bases - this should be ignored.
      # So we look for cases where the start continues as greater than
      # the previous mid point for evidence of a possible merge.
      #
      if (exists $Show_in_reverse_orientation{$EST_id}) {	# flip the logic of these around
	my $prev_midpoint = $prev_hit_start + ($prev_hit_end - $prev_hit_start)/2;
	my $midpoint = $hit_start + ($hit_end - $hit_start)/2;
	if (($chrom_strand eq '+' && $prev_chrom_end < $chrom_start && $hit_start < $prev_midpoint) ||
	    ($chrom_strand eq '-' && $prev_chrom_end < $chrom_start && $hit_start > $prev_midpoint && $prev_hit_start != -1)) {
	  $got_a_continuation_of_the_HSPs = 1;
	} else {
	  $got_a_continuation_of_the_HSPs = 0;
	}
      
	# see if we have a big increase in the start of the HSP - a possible case for splitting
	if (($chrom_strand eq '+' && $prev_chrom_end < $chrom_start && $prev_hit_start < $hit_start - 100) ||
	    ($chrom_strand eq '-' && $prev_chrom_end < $chrom_start && $prev_hit_start > $hit_start + 100 && $prev_hit_start != -1)) {
	  $got_a_big_decrease_in_HSP_start = 1;
	  #print "Split? $EST_id chrom_start $chrom_end prev_chrom_start $prev_chrom_start $chrom_strand prev_hit_start $prev_hit_start hit_start $hit_start\n";
	} else {
	  $got_a_big_decrease_in_HSP_start = 0;
	}

      } else {			# normal case - just like the proteins
	my $prev_midpoint = $prev_hit_start + ($prev_hit_end - $prev_hit_start)/2;
	my $midpoint = $hit_start + ($hit_end - $hit_start)/2;
	if (($chrom_strand eq '+' && $prev_chrom_end < $chrom_start && $hit_start > $prev_midpoint) ||
	    ($chrom_strand eq '-' && $prev_chrom_end < $chrom_start && $hit_start < $prev_midpoint && $prev_hit_start != -1)) {
	  $got_a_continuation_of_the_HSPs = 1;
	} else {
	  $got_a_continuation_of_the_HSPs = 0;
	}
      
	# see if we have a big decrease in the start of the HSP - a possible case for splitting
	if (($chrom_strand eq '+' && $prev_chrom_end < $chrom_start && $prev_hit_start > $hit_start + 100) ||
	    ($chrom_strand eq '-' && $prev_chrom_end < $chrom_start && $prev_hit_start < $hit_start - 100 && $prev_hit_start != -1)) {
	  $got_a_big_decrease_in_HSP_start = 1;
	  #print "Split? $EST_id chrom_start $chrom_end prev_chrom_start $prev_chrom_start $chrom_strand prev_hit_start $prev_hit_start hit_start $hit_start\n";
	} else {
	  $got_a_big_decrease_in_HSP_start = 0;
	}

      }


      # we have a merge if the pattern of HSPs shows a continuation of
      # the EST matching in order and this is a new gene and the
      # distance between the alignments is less than 10 kb
      if ($got_a_new_transcript && $got_a_continuation_of_the_HSPs && ($chrom_start - $prev_chrom_end) < 10000) {
	# output to database
	# make the anomaly score based on the EST alignment score normalised between 0 and 1
	# the BLAT scores are between 0 and 100
	# use the average of the two alignment's scores to discourage reporting cases where one is very poor
	my $anomaly_score = ($EST_score+$prev_score)/200;
	if ($anomaly_score > 1) {$anomaly_score = 1;}
	if ($anomaly_score < 0) {$anomaly_score = 0;}
	#print "MERGE genes ANOMALY $prev_transcript and $matching_transcript\t$EST_id, $prev_chrom_start, $chrom_end, $chrom_strand, $anomaly_score, 'merge $prev_transcript and $matching_transcript'\n";
	&output_to_database("MERGE_GENES_BY_EST", $chromosome, $EST_id, $prev_chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "merge $prev_transcript and $matching_transcript");


      }

      if ($got_a_big_decrease_in_HSP_start && ! $got_a_new_transcript) {
	# output to database
	# make the anomaly score based on the EST alignment score normalised between 0 and 1
	# the BLAT scores are between 0 and 100
	# use the average of the two alignment's scores to discourage reporting cases where one is very poor
	my $anomaly_score = ($EST_score+$prev_score)/200;
	if ($anomaly_score > 1) {$anomaly_score = 1;}
	if ($anomaly_score < 0) {$anomaly_score = 0;}
	#print "SPLIT gene ANOMALY $matching_transcript\t$EST_id, $prev_chrom_start, $chrom_end, $chrom_strand, $anomaly_score, 'split $matching_transcript'\n";
	&output_to_database("SPLIT_GENES_BY_EST", $chromosome, $EST_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "split $matching_transcript");
      }
    }

    $prev_transcript = $matching_transcript;
    $prev_hit_start = $hit_start;
    $prev_hit_end = $hit_end;
    $prev_score = $EST_score;
    $prev_chrom_start = $chrom_start;
    $prev_chrom_end = $chrom_end;
    $prev_EST_id = $EST_id;
    $prev_chrom_strand = $chrom_strand;
  }

}

##########################################
# find ESTs that have no association with a transcript in their object
#  &get_unattached_EST(\@est, $chromosome)

sub get_unattached_EST {
  my ($est_aref, $chromosome) = @_;

  $anomaly_count{UNATTACHED_EST} = 0 if (! exists $anomaly_count{UNATTACHED_EST});

  my $anomaly_score = 1.0;	# we must look at this with high priority

  foreach my $EST (@$est_aref) { # $id, $start, $end, $sense

    my $EST_id = $EST->[0];
    my $chrom_start = $EST->[1];
    my $chrom_end = $EST->[2];
    my $chrom_strand = $EST->[3];
    #print "EST: $EST_id, $chrom_start, $chrom_end, $chrom_strand\n";

    my $sequence_obj = $ace->fetch(Sequence => $EST_id);

    my @transcripts = $sequence_obj->get('Matching_transcript');
    if ($#transcripts == -1) {
      #print "Not associated with a transcript\n";
      #print "NOT ASSOCIATED: $EST_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNATTACHED_EST", $chromosome, $EST_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, 'EST not attached to any transcript');
    }
  }

}



##########################################
# find TSL sites that are defined by an EST but have no association with a transcript in their object
#  &get_unattached_TSL(\@TSL_SL1, \@TSL_SL2, $chromosome)

sub get_unattached_TSL {
  my ($SL1_aref, $SL2_aref, $chromosome) = @_;

  $anomaly_count{UNATTACHED_TSL} = 0 if (! exists $anomaly_count{UNATTACHED_TSL});

  my @SL1 = @$SL1_aref;
  my @SL2 = @$SL2_aref;
  my @SL = sort {$a->[1] <=> $b->[1]} (@SL1, @SL2); # merge and sort the two TSL lists

  my $anomaly_score = 1.0;	# we must look at this with high priority

  foreach my $TSL (@SL) { # $id, $start, $end, $sense

    my $TSL_id = $TSL->[0];
    my $chrom_start = $TSL->[1];
    my $chrom_end = $TSL->[2];
    my $chrom_strand = $TSL->[3];
    #print "TSL: $TSL_id, $chrom_start, $chrom_end, $chrom_strand\n";

    my $feature_obj = $ace->fetch(Feature => $TSL_id);

    my @sequences = $feature_obj->get('Defined_by_sequence');

    # see if we are defined by at least one EST, rather than a TEC-RED
    my $got_an_EST = 0;
    foreach my $sequence (@sequences) {
      #print "> $sequence\n";
      my $seq_obj = $ace->fetch('Sequence' => $sequence);
      if (! $seq_obj->fetch('TSL_tag')) { # ignore TEC-RED sequences
	$got_an_EST = 1;
	last;
      }
    }

    if ($got_an_EST) {
      my @transcripts = $feature_obj->get('Associated_with_transcript');
      if ($#transcripts == -1) {
	#print "Not associated with a transcript\n";
        #print "NOT ASSOCIATED: $TSL_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
	&output_to_database("UNATTACHED_TSL", $chromosome, $TSL_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, 'Trim CDS to start at the TSL? - also beware of chimeric ESTs.');
      }
    }
  }

}

##########################################
# get TSL sites that do not match a coding transcript or pseudogene
#  &get_isolated_TSL(\@TSL_SL1, \@TSL_SL2, \@CDS, \@coding_transcript, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, $chromosome);

sub get_isolated_TSL {

  my ($SL1_aref, $SL2_aref, $CDS_aref, $transcripts_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_TSL} = 0 if (! exists $anomaly_count{UNMATCHED_TSL});

  my @SL1 = @$SL1_aref;
  my @SL2 = @$SL2_aref;
  my @SL = sort {$a->[1] <=> $b->[1]} (@SL1, @SL2); # merge and sort the two TSL lists
      
  # allow the TSL to be within 75 bases of the CDS to give a match
  my $CDS1_match = $ovlp->compare($CDS_aref, near_5 => 75, same_sense => 1); # look for overlap or near to the 5' end
  my $CDS2_match = $ovlp->compare($CDS_aref, near_5 => -3, same_sense => 1); # only look for overlap (don't count a bit of overlap at the start)
  # allow the TSL to be within 75 bases of the transcript to give a match
  my $transcripts1_match = $ovlp->compare($transcripts_aref, near_5 => 75, same_sense => 1); # look for overlap or near to the 5' end
  my $transcripts2_match = $ovlp->compare($transcripts_aref, near_5 => -3, same_sense => 1); # only look for overlap (don't count a bit of overlap at the start)
  my $pseud_match = $ovlp->compare($pseudogenes_aref, same_sense => 1);
  my $trans_match = $ovlp->compare($transposons_aref, same_sense => 1);
  my $trane_match = $ovlp->compare($transposon_exons_aref, same_sense => 1);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, same_sense => 1);
  my $rrna_match  = $ovlp->compare($rRNA_aref, same_sense => 1);

  foreach my $tsl (@SL) { # $TSL_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
    my @result1;
    my @result2;

    @result1 = $CDS1_match->match($tsl);
    @result2 = $CDS2_match->match($tsl);

    # see if we have the same number of matches from an overlap
    # including 75 bases the the 5' end and a simple overlap - if not
    # then we have an overlap at the 5' end in one of the transcripts
    # of this gene and so we have a match
    if (scalar @result1 != scalar @result2) {
      $got_a_match = 1;
    }

    @result1 = $transcripts1_match->match($tsl);
    @result2 = $transcripts2_match->match($tsl);

    # see if we have the same number of matches from an overlap
    # including 75 bases the the 5' end and a simple overlap - if not
    # then we have an overlap at the 5' end in one of the transcripts
    # of this gene and so we have a match
    if (scalar @result1 != scalar @result2) {
      $got_a_match = 1;
    }

    if ($pseud_match->match($tsl)) { 
      $got_a_match = 1;
    }

    if ($trans_match->match($tsl)) { 
      $got_a_match = 1;
    }

    if ($nonco_match->match($tsl)) { 
      $got_a_match = 1;
    }

    if ($trane_match->match($tsl)) { 
      $got_a_match = 1;
    }

    if ($rrna_match->match($tsl)) { 
      $got_a_match = 1;
    }

    # output unmatched TSL sites to the database
    if (! $got_a_match) {
      my $TSL_id = $tsl->[0];
      my $chrom_start = $tsl->[1];
      my $chrom_end = $tsl->[2];
      my $chrom_strand = $tsl->[3];

      # make the anomaly score 5 because this is very informative
      my $anomaly_score = 5;
      #print "TSL NOT got a match ANOMALY: $TSL_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_TSL", $chromosome, $TSL_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }

}

##########################################
# get TSL sites that do not match a coding transcript or pseudogene
#  #  &get_isolated_RST5(\@rst_hsp, \@CDS, \@coding_transcripts, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome);

sub get_isolated_RST5 {

  my ($rst_aref, $CDS_aref, $transcripts_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_RST5} = 0 if (! exists $anomaly_count{UNMATCHED_RST5});

  # get just the RST5 sequences
  my @rst = @$rst_aref;
  my %seen_this_rst;		# a hash of RST IDs that we have already seen so we only bother with the 5'-most HSP hit

  foreach my $rst5 (@rst) { # $RST_id, $chrom_start, $chrom_end, $chrom_strand
    my $id = $rst5->[0];
    if ($id =~ /RST5/) {
      if ($rst5->[3] eq '+') {
	$rst5->[2] =  $rst5->[1] + 2; # make the thing to match a small area around the start
      } else {
	$rst5->[1] =  $rst5->[2] + 2; # make the thing to match a small area around the start	
      }
      if ($rst5->[3] eq '+' && !exists $seen_this_rst{$id}) {
	$seen_this_rst{$id} = $rst5;
      }
      if ($rst5->[3] eq '-') {
	$seen_this_rst{$id} = $rst5; # get the last one of these in the list
      }
    }
  }

  # change the hash to an array sorted by start position
  my @rst5;
  foreach my $rst5 (keys %seen_this_rst) {
    push @rst5, $seen_this_rst{$rst5};
  }
  @rst5 = sort {$a->[1] <=> $b->[1]} @rst5;
  #print "Have ", scalar @rst5 ," RST5s\n";

  # allow the RST to be within 150 bases of the CDS to give a match
  my $CDS1_match = $ovlp->compare($CDS_aref, near_5 => 150, same_sense => 1); # look for overlap or near to the 5' end
  my $CDS2_match = $ovlp->compare($CDS_aref, near_5 => -5, same_sense => 1); # only look for overlap (don't count a bit of overlap at the start)

  my $pseud_match = $ovlp->compare($pseudogenes_aref, same_sense => 1);
  my $trans_match = $ovlp->compare($transposons_aref, same_sense => 1);
  my $trane_match = $ovlp->compare($transposon_exons_aref, same_sense => 1);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, same_sense => 1);
  my $rrna_match  = $ovlp->compare($rRNA_aref, same_sense => 1);

  foreach my $rst5 (@rst5) { # $RST_id, $chrom_start, $chrom_end, $chrom_strand

    # ignore this hit if we have already seen this RST, so we only look at the 5'-most hit
    my $id = $rst5->[0];

    my $got_a_match = 0;
    my @result1;
    my @result2;

    @result1 = $CDS1_match->match($rst5);
    @result2 = $CDS2_match->match($rst5);

    # see if we have the same number of matches from an overlap
    # including 75 bases the the 5' end and a simple overlap - if not
    # then we have an overlap at the 5' end in one of the transcripts
    # of this gene and so we have a match
    if (scalar @result1 != scalar @result2) {
      $got_a_match = 1;
    }
    else {
      print "$id equal match on CDS ", scalar @result1, " vs ",  scalar @result2, "\n";
    }

    if ($pseud_match->match($rst5)) { 
      $got_a_match = 1;
    }

    if ($trans_match->match($rst5)) { 
      $got_a_match = 1;
    }

    if ($nonco_match->match($rst5)) { 
      $got_a_match = 1;
    }

    if ($trane_match->match($rst5)) { 
      $got_a_match = 1;
    }

    if ($rrna_match->match($rst5)) { 
      $got_a_match = 1;
    }

    # output unmatched RST5 sites to the database
    if (! $got_a_match) {
      my $RST5_id = $rst5->[0];
      my $chrom_start = $rst5->[1];
      my $chrom_end = $rst5->[2];
      my $chrom_strand = $rst5->[3];

      # make the anomaly score 5 because this is very informative
      my $anomaly_score = 5;
      #print "RST5 NOT got a match ANOMALY: $RST5_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_RST5", $chromosome, $RST5_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }

}


##########################################
# get twinscan exons that do not match a coding transcript or pseudogene
# &get_unmatched_twinscan_exons(\@twinscan, \@exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, $chromosome)


sub get_unmatched_twinscan_exons {

  my ($twinscan_aref, $exons_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $repeatmasked_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_TWINSCAN} = 0 if (! exists $anomaly_count{UNMATCHED_TWINSCAN});

  my $exons_match = $ovlp->compare($exons_aref, same_sense => 1);
  my $pseud_match = $ovlp->compare($pseudogenes_aref, same_sense => 1);
  my $trans_match = $ovlp->compare($transposons_aref, same_sense => 1);
  my $trane_match = $ovlp->compare($transposon_exons_aref, same_sense => 1);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, same_sense => 1);
  my $rrna_match  = $ovlp->compare($rRNA_aref, same_sense => 1);
  my $repeat_match= $ovlp->compare($repeatmasked_aref, near => -20);

  foreach my $twinscan (@{$twinscan_aref}) { # $twinscan_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
  
    if ($exons_match->match($twinscan)) { #&match($twinscan, $exons_aref, \%exons_match)) {
      $got_a_match = 1;
    }

    if ($pseud_match->match($twinscan)) { #&match($twinscan, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
    }

    if ($trans_match->match($twinscan)) { #&match($twinscan, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
    }

    if ($trane_match->match($twinscan)) { #&match($twinscan, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
    }

    if ($nonco_match->match($twinscan)) { #&match($twinscan, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
    }

    if ($rrna_match->match($twinscan)) { #&match($twinscan, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    # don't want to report unmatched twinscan that overlaps with a repeat
    if ($repeat_match->match($twinscan)) { #&match($twinscan, $repeatmasked_aref, \%repeat_match)) { 
      $got_a_match = 1;
    }

    # output unmatched TWINSCAN sites to the database
    if (! $got_a_match) {
      my $TWINSCAN_id = $twinscan->[0];
      my $chrom_start = $twinscan->[1];
      my $chrom_end = $twinscan->[2];
      my $chrom_strand = $twinscan->[3];

      # make the anomaly score 1
      my $anomaly_score = 1.0;
      #print "TWINSCAN NOT got a match ANOMALY: $TWINSCAN_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_TWINSCAN", $chromosome, $TWINSCAN_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }

}


##########################################
# get genefinder exons that do not match a coding transcript or pseudogene
# &get_unmatched_genefinder_exons(\@genefinder, \@exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, $chromosome)


sub get_unmatched_genefinder_exons {

  my ($genefinder_aref, $exons_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $repeatmasked_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_GENEFINDER} = 0 if (! exists $anomaly_count{UNMATCHED_GENEFINDER});

  my $exons_match = $ovlp->compare($exons_aref, same_sense => 1);
  my $pseud_match = $ovlp->compare($pseudogenes_aref, same_sense => 1);
  my $trans_match = $ovlp->compare($transposons_aref, same_sense => 1);
  my $trane_match = $ovlp->compare($transposon_exons_aref, same_sense => 1);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, same_sense => 1);
  my $rrna_match  = $ovlp->compare($rRNA_aref, same_sense => 1);
  my $repeat_match= $ovlp->compare($repeatmasked_aref, near => -20);	# allow 20 bases overlap in either sense with a repeat before we call it a hit

  foreach my $genefinder (@{$genefinder_aref}) { # $genefinder_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
  
    if ($exons_match->match($genefinder)) { #&match($genefinder, $exons_aref, \%exons_match)) {
      $got_a_match = 1;
    }

    if ($pseud_match->match($genefinder)) { #&match($genefinder, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
    }

    if ($trans_match->match($genefinder)) { #&match($genefinder, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
    }

    if ($trane_match->match($genefinder)) { #&match($genefinder, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
    }

    if ($nonco_match->match($genefinder)) { #&match($genefinder, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
    }

    if ($rrna_match->match($genefinder)) { #&match($genefinder, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    # don't want to report unmatched genefinder that overlaps with a repeat
    if ($repeat_match->match($genefinder)) { #&match($genefinder, $repeatmasked_aref, \%repeat_match)) {
      $got_a_match = 1;
    }

    # output unmatched GENEFINDER sites to the database
    if (! $got_a_match) {
      my $GENEFINDER_id = $genefinder->[0];
      my $chrom_start = $genefinder->[1];
      my $chrom_end = $genefinder->[2];
      my $chrom_strand = $genefinder->[3];

      # make the anomaly score 1
      my $anomaly_score = 1.0;
      #print "GENEFINDER NOT got a match ANOMALY: $GENEFINDER_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_GENEFINDER", $chromosome, $GENEFINDER_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }

}

##########################################
# find the SAGE transcripts that don't overlap the coding transcripts and pseudogenes
#  &get_unmatched_SAGE(\@coding_transcripts, \@SAGE_tags);

sub get_unmatched_SAGE {

  my ($coding_transcripts_aref, $pseudogenes_aref, $SAGE_tags_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $miRNA_aref, $ncRNA_aref, $scRNA_aref, $snRNA_aref, $snoRNA_aref, $stRNA_aref, $tRNA_aref, $tRNAscan_SE_1_23RNA_aref, $chromosome) = @_;
 
  $anomaly_count{UNMATCHED_SAGE} = 0 if (! exists $anomaly_count{UNMATCHED_SAGE});

  my @SAGE_tags = @{$SAGE_tags_aref};

  # count a hit within 20 bases as a match, so tags have to be more
  # than 20bp away before they are counted as unmatched
  my $NEAR = 20;		

  my $coding_transcripts_match = $ovlp->compare($coding_transcripts_aref, near => $NEAR);
  my $pseud_match = $ovlp->compare($pseudogenes_aref, near => $NEAR);
  my $trans_match = $ovlp->compare($transposons_aref, near => $NEAR);
  my $trane_match = $ovlp->compare($transposon_exons_aref, near => $NEAR);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, near => $NEAR);
  my $rrna_match = $ovlp->compare($rRNA_aref, near => $NEAR);
  my $mirna_match = $ovlp->compare($miRNA_aref, near => $NEAR);
  my $ncrna_match = $ovlp->compare($ncRNA_aref, near => $NEAR);
  my $scrna_match = $ovlp->compare($scRNA_aref, near => $NEAR);
  my $snrna_match = $ovlp->compare($snRNA_aref, near => $NEAR);
  my $snorna_match = $ovlp->compare($snoRNA_aref, near => $NEAR);
  my $strna_match = $ovlp->compare($stRNA_aref, near => $NEAR);
  my $trna_match = $ovlp->compare($tRNA_aref, near => $NEAR);
  my $tRNAscan_SE_1_23rna_match = $ovlp->compare($tRNAscan_SE_1_23RNA_aref, near => $NEAR);

  foreach my $sage (@SAGE_tags) { # $SAGE_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
  
    if ($coding_transcripts_match->match($sage)) { #&match($sage, $coding_transcripts_aref, \%coding_transcripts_match)) {
      $got_a_match = 1;
    }

    if ($pseud_match->match($sage)) { #&match($sage, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
    }

    if ($trans_match->match($sage)) { #&match($sage, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
    }

    if ($trane_match->match($sage)) { #&match($sage, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
    }

    if ($nonco_match->match($sage)) { #&match($sage, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
    }

    if ($rrna_match->match($sage)) { #&match($sage, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($mirna_match->match($sage)) { #&match($sage, $miRNA_aref, \%mirna_match)) {
      $got_a_match = 1;
    }

    if ($ncrna_match->match($sage)) { #&match($sage, $ncRNA_aref, \%ncrna_match)) {
      $got_a_match = 1;
    }

    if ($scrna_match->match($sage)) { #&match($sage, $scRNA_aref, \%scrna_match)) {
      $got_a_match = 1;
    }

    if ($snrna_match->match($sage)) { #&match($sage, $snRNA_aref, \%snrna_match)) {
      $got_a_match = 1;
    }

    if ($snorna_match->match($sage)) { #&match($sage, $snoRNA_aref, \%snorna_match)) {
      $got_a_match = 1;
    }

    if ($strna_match->match($sage)) { #&match($sage, $stRNA_aref, \%strna_match)) {
      $got_a_match = 1;
    }

    if ($trna_match->match($sage)) { #&match($sage, $tRNA_aref, \%trna_match)) {
      $got_a_match = 1;
    }

    if ($tRNAscan_SE_1_23rna_match->match($sage)) { #&match($sage, $tRNAscan_SE_1_23RNA_aref, \%tRNAscan_SE_1_23rna_match)) {
      $got_a_match = 1;
    }

    # output unmatched SAGE sites to the database
    if (! $got_a_match) {
      my $SAGE_id = $sage->[0];
      my $chrom_start = $sage->[1];
      my $chrom_end = $sage->[2];
      my $chrom_strand = $sage->[3];
      my $other_data = $sage->[4];
      my ($score) = ($other_data =~ /count\s+(\d+)/); # get the score from the 'count' field of the 'other' data

      my $anomaly_score = $score/50;	# the SAGE_tag scores are between 1 and about 100, so get an anomaly score of from 0 to about 2
      if ($anomaly_score > 2.5) {$anomaly_score = 2.5;}	# cap the score so we don't get extraordinarily large ones

      #print "NOT got a match ANOMALY: $SAGE_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_SAGE", $chromosome, $SAGE_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }

}



##########################################
# get genefinder exons that do not match a coding transcript or pseudogene
#  &get_unmatched_waba_coding(\@waba_coding, \@exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, \@repeatmasked, $chromosome);



sub get_unmatched_waba_coding {

  my ($waba_aref, $exons_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $repeatmasked_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_WABA} = 0 if (! exists $anomaly_count{UNMATCHED_WABA});

  my $exons_match = $ovlp->compare($exons_aref);
  my $pseud_match = $ovlp->compare($pseudogenes_aref);
  my $trans_match = $ovlp->compare($transposons_aref);
  my $trane_match = $ovlp->compare($transposon_exons_aref);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref);
  my $rrna_match  = $ovlp->compare($rRNA_aref);
  my $repeat_match= $ovlp->compare($repeatmasked_aref);

  foreach my $waba (@{$waba_aref}) { # $waba_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
  
    if ($exons_match->match($waba)) { #&match($waba, $exons_aref, \%exons_match)) {
      $got_a_match = 1;
    }

    if ($pseud_match->match($waba)) { #&match($waba, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
    }

    if ($trans_match->match($waba)) { #&match($waba, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
    }

    if ($trane_match->match($waba)) { #&match($waba, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
    }

    if ($nonco_match->match($waba)) { #&match($waba, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
    }

    if ($rrna_match->match($waba)) { #&match($waba, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($repeat_match->match($waba)) { #&match($waba, $repeatmasked_aref, \%repeat_match)) {
      $got_a_match = 1;
    }

    # output unmatched WABA sites to the database
    if (! $got_a_match) {
      my $WABA_id = $waba->[0];
      my $chrom_start = $waba->[1];
      my $chrom_end = $waba->[2];
      my $chrom_strand = $waba->[3];
      my $waba_score = $waba->[6];

      # reject any hits there is a  WABA score < 75
      if ($waba_score < 75) {next;}

      # make the anomaly score based on the protein alignment score normalised between 1 and about 2.5
      # using the log10 of the waba score
      # the waba scores seem to be between 0 and about 250
      my $anomaly_score = POSIX::log10($waba_score);
      if ($anomaly_score > 2.5) {$anomaly_score = 2.5;}
      if ($anomaly_score < 0) {$anomaly_score = 0;}

      #print "WABA NOT got a match ANOMALY: $WABA_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_WABA", $chromosome, $WABA_id, $chrom_start, $chrom_end, '.', $anomaly_score, '');
    }
  }

}
##########################################
# get CDS exons that overlap a CDS exon on the opposite sense
#  &get_matched_exons(\@cds_exons, \@pseudogenes, \@transposons, \@transposon_exons, \@noncoding_transcript_exons, \@rRNA, $chromosome);



sub get_matched_exons {

  my ($cds_exons_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $chromosome) = @_;

  $anomaly_count{OVERLAPPING_EXONS} = 0 if (! exists $anomaly_count{OVERLAPPING_EXONS});

  my $exons_match = $ovlp->compare($cds_exons_aref, other_sense => 1);
  my $pseud_match = $ovlp->compare($pseudogenes_aref, other_sense => 1);
  my $trans_match = $ovlp->compare($transposons_aref, other_sense => 1);
  my $trane_match = $ovlp->compare($transposon_exons_aref, other_sense => 1);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, other_sense => 1);
  my $rrna_match  = $ovlp->compare($rRNA_aref, other_sense => 1);

  foreach my $exon (@{$cds_exons_aref}) { # $exon_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
    my $matching_thing;
    my @result;
    my @names;

    if (@result = $exons_match->match($exon)) { #&match($exon, $cds_exons_aref, \%exons_match)) { # look for matches of exons against exons
      $got_a_match = 1;
      @names = $exons_match->matching_IDs;
      $matching_thing = "Overlaps gene: @names";
    }

    if (@result = $pseud_match->match($exon)) { #&match($exon, $pseudogenes_aref, \%pseud_match)) {
      $got_a_match = 1;
      @names = $pseud_match->matching_IDs;
      $matching_thing = "Overlaps pseudogene: @names";
    }

    if (@result = $trans_match->match($exon)) { #&match($exon, $transposons_aref, \%trans_match)) {
      $got_a_match = 1;
      @names = $trans_match->matching_IDs;
      $matching_thing = "Overlaps transposon: @names";
    }

    if (@result = $trane_match->match($exon)) { #&match($exon, $transposon_exons_aref, \%trane_match)) {
      $got_a_match = 1;
      @names = $trane_match->matching_IDs;
      $matching_thing = "Overlaps transposon: @names";
    }

    if (@result = $nonco_match->match($exon)) { #&match($exon, $noncoding_transcript_exons_aref, \%nonco_match)) {
      $got_a_match = 1;
      @names = $nonco_match->matching_IDs;
      $matching_thing = "Overlaps non-coding transcript: @names";
    }

    if (@result = $rrna_match->match($exon)) { #&match($exon, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
      @names = $rrna_match->matching_IDs;
      $matching_thing = "Overlaps rRNA: @names";
    }

    # output matched EXON sites to the database
    if ($got_a_match) {
      my $exon_id = $exon->[0];
      my $chrom_start = $exon->[1];
      my $chrom_end = $exon->[2];
      my $chrom_strand = $exon->[3];
      my $exon_score = $exon->[6];

      my $anomaly_score = 5;

      #print "EXON overlapping other thing ANOMALY: $exon_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("OVERLAPPING_EXONS", $chromosome, $exon_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, $matching_thing);
    }
  }

}

##########################################
# Finding short CDS exons
# note any exons shorter than 30 bases
#  &get_short_exons(\@exons, $chromosome);

sub get_short_exons {
  my ($exons_aref, $chromosome) = @_;

  $anomaly_count{SHORT_EXON} = 0 if (! exists $anomaly_count{SHORT_EXON});

  foreach my $exon (@{$exons_aref}) { # $exon_id, $chrom_start, $chrom_end, $chrom_strand

    my $exon_id = $exon->[0];
    my $chrom_start = $exon->[1];
    my $chrom_end = $exon->[2];
    my $chrom_strand = $exon->[3];
    my $exon_score = $exon->[6];

    my $anomaly_score = 1;

    if ($chrom_end - $chrom_start + 1< 30) { # note any exons shorter than 30 bases
      &output_to_database("SHORT_EXON", $chromosome, $exon_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }
}

##########################################
# Finding EST/genome mismatches
# note any 1 to 3 base misalignment that is seen in two or more ESTs
# this might indicate a genomic sequencing error or some RNA editing
# &get_est_mismatches(\@est, $chromosome);

sub get_est_mismatches {
  my ($est_aref, $chromosome) = @_;

  $anomaly_count{MISMATCHED_EST} = 0 if (! exists $anomaly_count{MISMATCHED_EST});

  my @ests = @{$est_aref};

  my $prev_EST_id = "";	
  my $prev_chrom_start = -1;
  my $prev_chrom_end = -1;
  my $prev_score = 0;
  my $prev_chrom_strand = "";
  my $prev_hit_start = -1;
  my $prev_hit_end = -1;


  
  # sort the homologies grouped by EST ID and then chromosomal position
  my @sorted_ests = sort {$a->[0] cmp $b->[0] or $a->[1] <=> $b->[1]} @ests;

  my %mismatch_counts;
  foreach my $alignment (@sorted_ests) { # $EST_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $EST_score, $matching_transcript

    my $EST_id = $alignment->[0];
    my $chrom_start = $alignment->[1];
    my $chrom_end = $alignment->[2];
    my $chrom_strand = $alignment->[3];
    my $hit_start = $alignment->[4];
    my $hit_end = $alignment->[5];
    my $EST_score = $alignment->[6];

    if ($prev_EST_id eq $EST_id && # the same EST as the previous hit
	$EST_score > 99.0 &&	# good quality
	$chrom_end - $chrom_start > 30 && # a decent length
	$prev_chrom_end - $prev_chrom_start > 30) { # the previous hit was a decent length
      if ((($hit_start - $prev_hit_end == 1) && ($chrom_start - $prev_chrom_end) < 4) ||
	  (($hit_start - $prev_hit_end < 4) && ($chrom_start - $prev_chrom_end) == 1)) {
	my $key = "$chrom_start-$chrom_end";
	$mismatch_counts{$key}{count}++;
	$mismatch_counts{$key}{EST_id} = $EST_id;
	$mismatch_counts{$key}{chrom_start} = $chrom_start;
	$mismatch_counts{$key}{chrom_end} = $chrom_end;
	$mismatch_counts{$key}{chrom_strand} = $chrom_strand;
	$mismatch_counts{$key}{overlaps} = 0;
      }
    }

    $prev_EST_id = $EST_id;
    $prev_chrom_start = $chrom_start;
    $prev_chrom_end = $chrom_end;
    $prev_chrom_strand = $chrom_strand;
    $prev_hit_start = $hit_start;
    $prev_hit_end = $hit_end;
    $prev_score = $EST_score;
  }

  # we now have the set of small misalignments in %mismatch_counts

  # get rid of the singleton misalignments
  foreach my $key (keys %mismatch_counts) {
    if ($mismatch_counts{$key}{count} == 1) {
      delete $mismatch_counts{$key};
    }
  }


  # now count how many good alignments overlap with them
  foreach my $alignment (@sorted_ests) { # $EST_id, $chrom_start, $chrom_end, $chrom_strand, $hit_start, $hit_end, $EST_score, $matching_transcript

    my $chrom_start = $alignment->[1];
    my $chrom_end = $alignment->[2];
    my $chrom_strand = $alignment->[3];

    foreach my $key (keys %mismatch_counts) {
      if ($chrom_start < $mismatch_counts{$key}{chrom_start} && 
	  $chrom_end > $mismatch_counts{$key}{chrom_start} &&
	  $chrom_strand eq $mismatch_counts{$key}{chrom_strand}) {
	$mismatch_counts{$key}{overlaps}++;
      }
    }
  }

  foreach my $key (keys %mismatch_counts) {
    if ($mismatch_counts{$key}{count} > 1) { # this should now always be true
      # get score as proportion of ESTs there that have the misalignment
      my $anomaly_score = $mismatch_counts{$key}{count}/($mismatch_counts{$key}{overlaps} + $mismatch_counts{$key}{count});
      if ($anomaly_score >= 0.5) { # we don't want the dubious cases

	# save the details for outputting to the MISMATCHED_EST file at the end of the program
	push @est_mismatches, [$mismatch_counts{$key}{EST_id}, $chromosome, $mismatch_counts{$key}{chrom_start}, $mismatch_counts{$key}{chrom_end}, $mismatch_counts{$key}{chrom_strand}, $anomaly_score];

	#print "MISMATCHED_EST ", $chromosome, " ID ", $mismatch_counts{$key}{EST_id}, " start ", $mismatch_counts{$key}{chrom_start}, " end ", $mismatch_counts{$key}{chrom_end}, " strand ", $mismatch_counts{$key}{chrom_strand}, "score $anomaly_score\n";
	&output_to_database("MISMATCHED_EST", $chromosome, $mismatch_counts{$key}{EST_id}, $mismatch_counts{$key}{chrom_start}, $mismatch_counts{$key}{chrom_end}, $mismatch_counts{$key}{chrom_strand}, $anomaly_score, 'possible genomic sequence error or evidence of RNA editing');
      }
    }
  }
}
##########################################
# Finding weak exon splice sites
# output to database any splice sites with a score < 0.1
# output to database any splice sites with a score < 0.5 if there are two or more such splice sites in a gene
# get_weak_exon_splice_sites(\@exons, $chromosome);

sub get_weak_exon_splice_sites {
  my ($CDS_introns_aref, $chromosome) = @_;

  $anomaly_count{WEAK_INTRON_SPLICE_SITE} = 0 if (! exists $anomaly_count{WEAK_INTRON_SPLICE_SITE});


# intron splice sites with key = "ID,strand,pos" value as list 
# value[0] = 0 if not confirmed, > 0 if confirmed 
# value[1] is CDS ID
# value[2] is strand
# value[3] is chromosomal pos
# value[4] is 5 or 3 (for the 5' or 3' end)

  my %splice_sites;

  ###########################################
  # find out which splice sites are confirmed
  ###########################################

  foreach my $intron (@{$CDS_introns_aref}) { # $intron_id, $chrom_start, $chrom_end, $chrom_strand, other

    my $CDS_id = $intron->[0];
    my $chrom_start = $intron->[1];
    my $chrom_end = $intron->[2];
    my $chrom_strand = $intron->[3];
    my $other_data = $intron->[4];
    my $confirmed;
    if (defined $other_data) {
      $confirmed = $other_data =~ /Confirmed_/; # test to see if this intron is confirmed
    } else {
      $confirmed = 0;		# assume all introns are not confirmed if we have no info on this
    }

    # 5' splice site
    if (exists $splice_sites{"$CDS_id$chrom_strand$chrom_start"}) {
      $splice_sites{"$CDS_id$chrom_strand$chrom_start"}[0] += $confirmed;
    } else {
      $splice_sites{"$CDS_id$chrom_strand$chrom_start"} = [$confirmed, $CDS_id, $chrom_strand, $chrom_start-1, 5]; # we want the base before the cut
    }

    # 3' splice site
    if (exists $splice_sites{"$CDS_id$chrom_strand$chrom_end"}) {
      $splice_sites{"$CDS_id$chrom_strand$chrom_end"}[0] += $confirmed;
    } else {
      $splice_sites{"$CDS_id$chrom_strand$chrom_end"} = [$confirmed, $CDS_id, $chrom_strand, $chrom_end, 3];       
    }
  }

  my @splices;			# list of unconfirmed splice sites
   

  #########################################################
  # get a list of unconfirmed splice sites sorted by CDS_id
  #########################################################

  foreach my $splice (keys %splice_sites) {
    my $confirmed  = $splice_sites{$splice}->[0];
    my $CDS_id     = $splice_sites{$splice}->[1];
    my $strand     = $splice_sites{$splice}->[2];
    my $splice_pos = $splice_sites{$splice}->[3];
    my $splice_end = $splice_sites{$splice}->[4];
    if ($confirmed == 0) {
      push @splices, [$CDS_id, $strand, $splice_pos, $splice_end];
    }
  }
  print "Have ", scalar (keys %splice_sites), " splice sites, of which ", scalar @splices," are not confirmed\n";
  # sort splices by CDS_id so we can find out how many weak splices there are in a CDS
  my @splices_sorted = sort {$a->[0] cmp $b->[0] } @splices;


  #################################################################
  # foreach splice site, see if it is below the cutoff or
  # cutoff_single thresholds output it if it is below the
  # cutoff_single threshold and output if two or more are below the
  # cutoff threshold (store any that might need to be output)
  #################################################################

  my $pwm = PWM->new;
  my $seq = read_chromosome($chromosome);

  my $splice_cutoff = 0.5;	# if we have two or more splice sites below this value, then report them
  my $splice_cutoff_single = 0.1; # if we have only one splice site, it has to be below this value before we report it
  my $count_low_sites = 0;

  my $anomaly_score = 1;

  my $prev_CDS = "";
  my @prev_details = ();	# details to store in database of any previous splice site in this CDS with a score < $splice_cutoff

  foreach my $splice (@splices_sorted) {
    my $CDS_id     = $splice->[0];
    my $strand     = $splice->[1];
    my $splice_pos = $splice->[2];
    my $splice_end = $splice->[3];

    if ($prev_CDS ne $CDS_id) {	# we have a new CDS, so reset the count of low-scoring sites in this CDS
      $prev_CDS = $CDS_id;
      $count_low_sites = 0;
      @prev_details = ();
    }

    my $score;			# score of this splice site
    if ($strand eq '+') {
      #$desc= "seq=". substr($seq, $splice_pos-10, 9)."/".substr($seq, $splice_pos-1, 10).  "\n";
      if ($splice_end == 5) {	# is it a 5' end of the intron
	$score = $pwm->splice5($seq, $splice_pos-1, '+'); # -1 to convert from acedb sequence pos to perl string coords
      } else {			# or the 3' end of the intron
	$score = $pwm->splice3($seq, $splice_pos-1, '+'); # -1 to convert from acedb sequence pos to perl string coords	
      }

    } else {			# strand eq '-'
      if ($splice_end == 3) {	# is it a 5' end of the intron (yes, we test for 3 here to get a real 5' in the reverse sense!)
	$score = $pwm->splice5($seq, $splice_pos, '-'); # -1 to convert from acedb sequence pos to perl string coords
      } else {                  # or the 3' end of the intron
	$score = $pwm->splice3($seq, $splice_pos, '-'); # -1 to convert from acedb sequence pos to perl string coords
      } 
    }

    if ($score < $splice_cutoff) {
      if ($score < $splice_cutoff_single || $count_low_sites > 0) {
	&output_to_database("WEAK_INTRON_SPLICE_SITE", $chromosome, $CDS_id, $splice_pos-1, $splice_pos+1, $strand, $anomaly_score, "splice site score = $score");
	if ($count_low_sites == 1 && @prev_details) { # output the stored details of the first site
	  &output_to_database("WEAK_INTRON_SPLICE_SITE", @prev_details);
	}
      } else {		# store the details in case we find a second low-scoring site in this CDS
	@prev_details = ($chromosome, $CDS_id, $splice_pos-1, $splice_pos+1, $strand, $anomaly_score, "splice site score = $score");
      }
      $count_low_sites++;
    }

  }				# foreach $splice
}


##########################################
##########################################
# read the chromosmal sequence
#  my $seq = read_chromosome($chromosome);

sub read_chromosome {

  my $chromosome = shift;

  # if we have already read in the sequence entries, return the one for this chromosome
  if (exists $dna_entry{$chromosome}) {return $dna_entry{$chromosome};}

  my $seq_file = "$database/CHROMOSOMES/$chromosome.dna";
  my $seq = &read_file($seq_file);

  if (! defined $seq) {
    $seq = &read_entry("$database/CHROMOSOMES", $chromosome)
  }

  return $seq;

}

##########################################
# read file

sub read_file {
  my ($file) = @_;

  my $seq;

  # try to open a single-chromosome entry file e.g. for elegans, briggsae
  if (open (SEQ, $file)) {
    $/ = "";
    $seq = <SEQ>;
    close SEQ;
    $/ = "\n";
    
    $seq =~ s/>.*\n//;           # remove one title line
    $seq =~ s/\n//g;
  } else {
    print "Can't open the dna file for $file : $!\n" if ($verbose);
  }

  return $seq
}


##########################################
# read entry in a file if the file consists of lots of entries

sub read_entry {
  my ($dir, $chromosome) = @_;

  # if we have already read in the sequence entries, return the one for this chromosome
  if (exists $dna_entry{$chromosome}) {return $dna_entry{$chromosome};}

  my $file = "$dir/supercontigs.fa"; # it might be called this
  print "Trying: $file\n" if ($verbose);
  if (! -e $file) {
    print "Can't open the dna file for $file : $!\n" if ($verbose);
    $file = "$dir/" . $wormbase->species . ".fa"; # or it might be called this - the nomenclature is not yet certain
    print "Trying: $file\n" if ($verbose);

  } elsif (! -e $file) {
    die "Can't find chromosome sequence file for $dir, $chromosome\n";
  }

  print "Reading DNA sequence entries\n";
  my $seq;

  if (open (SEQ, $file)) {
    my $entry;
    while (my $line = <SEQ>) {
      chomp $line;
      if ($line =~ /^>(\S+)/) {
	if (defined $entry) {	# store the previous sequence entry
	  $dna_entry{$entry} = $seq;
	}
	$seq = "";
	$entry = $1;
      } else {
	$seq .= $line;
      }
    }
    if (defined $entry) {	# store the last entry
      $dna_entry{$entry} = $seq;
    }
    close SEQ;
  } else {
    die "Can't open the dna file for $file : $!\n";
  }

  if (! exists $dna_entry{$chromosome}) {$log->log_and_die("No DNA sequence was found for $chromosome\n");}
  return $dna_entry{$chromosome};
}


##########################################
# Finding short CDS introns
# note any introns shorter than 30 bases
#  &get_short_introns(\@exons, $chromosome);

sub get_short_introns {
  my ($exons_aref, $chromosome) = @_;

  $anomaly_count{SHORT_INTRON} = 0 if (! exists $anomaly_count{SHORT_INTRON});

  my $prev_end = 0;
  my $prev_exon = "";

  foreach my $exon (@{$exons_aref}) { # $exon_id, $chrom_start, $chrom_end, $chrom_strand

    my $exon_id = $exon->[0];
    my $chrom_start = $exon->[1];
    my $chrom_end = $exon->[2];
    my $chrom_strand = $exon->[3];
    my $exon_score = $exon->[6];

    my $anomaly_score = 1;

    # we want: 
    # not the first exon in the chromosome
    # and the previous exon came from this CDS
    # and the intron is < 30 bases
    if ($prev_end != 0 && $prev_exon eq $exon_id && $chrom_start - $prev_end + 1< 30) { # note any introns shorter than 30 bases
      &output_to_database("SHORT_INTRON", $chromosome, $exon_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
    $prev_end = $chrom_end;
    $prev_exon = $exon_id;
  }
}

##########################################
# find coding exons that match repeatmasked regions 
#  &get_matched_repeatmasker(\@exons, \@repeatmasked, $chromosome);


sub get_matched_repeatmasker {

  my ($exons_aref, $repeatmasked_aref, $chromosome) = @_;

  $anomaly_count{REPEAT_OVERLAPS_EXON} = 0 if (! exists $anomaly_count{REPEAT_OVERLAPS_EXON});


  # remove the low-complexity repeat regions from the repeats list

  my $repeat_match = $ovlp->compare($repeatmasked_aref, near => -20);
  my @results;
  my @names;

  foreach my $exon (@{$exons_aref}) { # $exon_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
  
    if (@results = $repeat_match->match($exon)) { #&match($exon, $repeatmasked_aref, \%repeat_match)) {
      $got_a_match = 1;
      @names = $repeat_match->matching_IDs;

      # store a count of the times the repeat motifs have been seen overlapping a coding exons
      # this is output at the end of the program
      foreach my $name (@names) {
	$repeat_count{$name}++;
      }
    }

    # output matched exons to the database
    if ($got_a_match) {
      my $exon_id = $exon->[0];
      my $chrom_start = $exon->[1];
      my $chrom_end = $exon->[2];
      my $chrom_strand = $exon->[3];
      my $exon_score = $exon->[6];

      my $anomaly_score = 1;

      #print "REPEAT got a match ANOMALY: $exon_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("REPEAT_OVERLAPS_EXON", $chromosome, $exon_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }
  }

}

##########################################
# get the UTRs which have got 3 or more exons
sub get_multiple_utr_introns {

  my ($UTR_aref, $chromosome) = @_;

  $anomaly_count{INTRONS_IN_UTR} = 0 if (! exists $anomaly_count{INTRONS_IN_UTR});


  my %output;
  my %output_start;
  my %output_end;
  my %output_strand;

  my $count;
  my $prev = "";

  foreach my $utr (@{$UTR_aref}) { # $id, $chrom_start, $chrom_end, $chrom_strand

    # output multiple UTR exons to the database
    my $id = $utr->[0];
    my $chrom_start = $utr->[1];
    my $chrom_end = $utr->[2];
    my $chrom_strand = $utr->[3];

    # we don't want to see UTRs from isoform transcripts - there are too many mangled UTRs in them
    if ($id !~ /^\S+\.\d+$/ || $id =~ /^\S+\.\d+[a-z]\.\d+$/) {next;} 

    if ($prev ne $id) {
      $prev = $id;
      $count = 0;
    }
    $count++;
    if ($count > 2) {
      $output{$id} = $count;
      if ($count == 3) {$output_start{$id} = $chrom_start;}
      $output_end{$id} = $chrom_end;
      $output_strand{$id} = $chrom_strand;
    }
  }

  # now output the ones we have found
  foreach my $id (keys %output) {
    &output_to_database("INTRONS_IN_UTR", $chromosome, $id, $output_start{$id}, $output_end{$id}, $output_strand{$id}, $output{$id}, '');
  }

}

##########################################
# get genes to be split/merged based on twinscan

sub get_twinscan_split_merged {

  my ($twinscan_aref, $CDS_aref, $chromosome) = @_;

  $anomaly_count{SPLIT_GENE_BY_TWINSCAN} = 0 if (! exists $anomaly_count{SPLIT_GENE_BY_TWINSCAN});
  $anomaly_count{MERGE_GENES_BY_TWINSCAN} = 0 if (! exists $anomaly_count{MERGE_GENES_BY_TWINSCAN});


  my $twin_match = $ovlp->compare($twinscan_aref, same_sense => 1);
  my @results;
  my @names;

  foreach my $CDS (@{$CDS_aref}) { # $CDS_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;
    my $matching_ids;

    if (@results = $twin_match->match($CDS)) { # &match($CDS, $twinscan_aref, \%twin_match)) {
      @names = $twin_match->matching_IDs;
      #print "SPLIT $CDS->[0] @names\n";
      if (@results > 1) {$got_a_match = 1;}
    }

    # output matched CDS to the database
    if ($got_a_match) {
      my $CDS_id = $CDS->[0];
      my $chrom_start = $CDS->[1];
      my $chrom_end = $CDS->[2];
      my $chrom_strand = $CDS->[3];

      my $anomaly_score = 1;

      #print "SPLIT_GENE_BY_TWINSCAN, $chromosome, $CDS_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, Twinscan: @names\n";
      &output_to_database("SPLIT_GENE_BY_TWINSCAN", $chromosome, $CDS_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "Twinscan: @names");
    }
  }

  my $CDS_match = $ovlp->compare($CDS_aref, same_sense => 1);

  foreach my $twin (@{$twinscan_aref}) { # $twin_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_merge = 0;
    my $matching_ids;

    if (@results = $CDS_match->match($twin)) { #&match($twin, $CDS_aref, \%CDS_match)) {
      @names = $CDS_match->matching_IDs;
      #  check if these are isoforms of the same gene and if so then treat them as the same gene
      my $prev_name = "";

      foreach my $name (@names) {
	my $simple_name = $name;
	if ($name =~ /(\S+\.\d+)[a-z]/) {
	  $simple_name = $1;
	}
	#if (! defined $simple_name) {print "simple name not defined with name = $name\n";}
	if ($prev_name ne "" && $simple_name ne $prev_name) {
	  $got_a_merge = 1;
	}
	$prev_name = $simple_name;
      }

      #print "MERGE $twin->[0] @names\n";
    }

    # output matched twinscans to the database
    if ($got_a_merge) {
      my $twin_id = $twin->[0];
      my $chrom_start = $twin->[1];
      my $chrom_end = $twin->[2];
      my $chrom_strand = $twin->[3];

      my $anomaly_score = 1;

      #print "MERGE_GENES_BY_TWINSCAN, $chromosome, $twin_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, CDS: @names\n";
      &output_to_database("MERGE_GENES_BY_TWINSCAN", $chromosome, $twin_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "CDS: @names");
    }
  }

}

####################################################################################
sub get_checked_confirmed_introns {
  my ($check_introns_EST_aref, $check_introns_cDNA_aref, $chromosome) = @_;

  $anomaly_count{CONFIRMED_INTRON} = 0 if (! exists $anomaly_count{CONFIRMED_INTRON});

  foreach my $check (@{$check_introns_EST_aref}, @{$check_introns_cDNA_aref}) {
    my $anomaly_score = 10;	# high priority
    my $check_id     = $check->[0];
    my $chrom_start  = $check->[1];
    my $chrom_end    = $check->[2];
    my $chrom_strand = $check->[3];


    &output_to_database("CONFIRMED_INTRON", $chromosome, $check_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
  }

}

##########################################
# get ESTs not matching transcripts

sub get_unmatched_ests {

  my ($est_aref, $trans_aref, $pseud_aref, $tposon_aref, $nctrans_aref, $rrna_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_EST} = 0 if (! exists $anomaly_count{UNMATCHED_EST});

  # set up the overlap compare objects for the secondary lists
  my $trans_match = $ovlp->compare($trans_aref);
  my $pseud_match = $ovlp->compare($pseud_aref);
  my $tposon_match = $ovlp->compare($tposon_aref);
  my $nctrans_match = $ovlp->compare($nctrans_aref);
  my $rrna_match = $ovlp->compare($rrna_aref);

  foreach my $est (@{$est_aref}) { # $id, $chrom_start, $chrom_end, $chrom_strand
 
    my @matching = $trans_match->match($est);
    push @matching, $pseud_match->match($est);
    push @matching, $tposon_match->match($est);
    push @matching, $nctrans_match->match($est);
    push @matching, $rrna_match->match($est);

    if (@matching == 0) {

    # output unmatched ests to the database
      my $id = $est->[0];
      my $chrom_start = $est->[1];
      my $chrom_end = $est->[2];
      my $chrom_strand = $est->[3];
      if ($chrom_end - $chrom_start < 50) {next;}

      my $anomaly_score = 1;

      &output_to_database("UNMATCHED_EST", $chromosome, $id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "");
    }
  }
}

##########################################
# get mass-spec peptides not matching coding exons
#  &get_unmatched_mass_spec_peptides(\@mass_spec_peptides, \@cds_exons, \@transposon_exons, $chromosome);

sub get_unmatched_mass_spec_peptides {
  my ($mass_spec_peptides_aref, $cds_exons_aref, $transposon_exons_aref, $chromosome) = @_;

  $anomaly_count{UNMATCHED_MASS_SPEC_PEPTIDE} = 0 if (! exists $anomaly_count{UNMATCHED_MASS_SPEC_PEPTIDE});

  my $cds_match   = $ovlp->compare($cds_exons_aref, same_sense => 0); # the sense of the mass-spec peptide is not well established
  my $trans_match = $ovlp->compare($transposon_exons_aref, same_sense => 0); # the sense of the mass-spec peptide is not well established

  foreach my $msp (@{$mass_spec_peptides_aref}) { # $msp_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;

    if (my @results = $cds_match->match($msp)) { 
      # want the mass_spec peptide to be entirely overlapped by the CDS exon
      # print "no. of results=", scalar @results, "\n";
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $cds_match->matching_proportions($result);
	if ($prop1 == 1) {$got_a_match = 1;}
      }
    }

    if (my @results = $trans_match->match($msp)) { 
      # want the mass_spec peptide to be entirely overlapped by the transposon_CDS exon
      # print "no. of results=", scalar @results, "\n";
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $trans_match->matching_proportions($result);
	if ($prop1 == 1) {$got_a_match = 1;}
      }
    }

    # output unmatched mass-spec protein to the database
    if (!$got_a_match) {
      my $msp_id = $msp->[0];
      my $chrom_start = $msp->[1];
      my $chrom_end = $msp->[2];
      my $chrom_strand = $msp->[3];

      my $anomaly_score = 10;	# huge score!

      #print "UNMATCHED_MASS_SPEC_PEPTIDE, $chromosome, $msp_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, \n";
      &output_to_database("UNMATCHED_MASS_SPEC_PEPTIDE", $chromosome, $msp_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "");
    }
  }
}



####################################################################################
# find introns refuted by EST - i.e. intron with an est aligned across it
#  &get_introns_refuted_by_est(\@CDS_introns, \@cds_exons, \@est_hsp, \@rst_hsp, \@ost_hsp, \@mrna_hsp, $chromosome);
sub get_introns_refuted_by_est {

  my ($CDS_introns_aref, $cds_exons_aref, $est_hsp_aref, $rst_hsp_aref, $ost_hsp_aref, $mrna_hsp_aref, $chromosome) = @_;

  $anomaly_count{EST_OVERLAPS_INTRON} = 0 if (! exists $anomaly_count{EST_OVERLAPS_INTRON});
  $anomaly_count{OST_OVERLAPS_INTRON} = 0 if (! exists $anomaly_count{OST_OVERLAPS_INTRON});
  $anomaly_count{RST_OVERLAPS_INTRON} = 0 if (! exists $anomaly_count{RST_OVERLAPS_INTRON});
  $anomaly_count{MRNA_OVERLAPS_INTRON} = 0 if (! exists $anomaly_count{MRNA_OVERLAPS_INTRON});


# want to get all introns with no completely overlapping (isoform)
# exons, because if there was an EST aligned across an intron
# completely overlapped by an exon, the EST is simply confirming the
# exon and says nothing about the correctness or otherwise of the
# intron.

  my $cds_match   = $ovlp->compare($cds_exons_aref, same_sense => 1); 
  my @single_introns;		# the list of introns with no completely overlapping (isoform) exons
  my $got_a_match = 0;

  foreach my $intron (@{$CDS_introns_aref}) { # $intron_id, $chrom_start, $chrom_end, $chrom_strand
    $got_a_match = 0;
    if (my @results = $cds_match->match($intron)) { 
      # don't want the intron to be entirely overlapped by the CDS exon
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $cds_match->matching_proportions($result);
	if ($prop1 == 1) {
	  $got_a_match = 1;
	}
      }
      if (! $got_a_match) {
	push @single_introns, $intron;
      }
    }
  }
  # it should be sorted by start position already, but just in case, do it again
  @single_introns = sort {$a->[1] <=> $b->[1]} (@single_introns); 

# now check to see if any of these non-overlapped introns have an EST/OST/RST/mRNA
# aligned across them, in which case they are an anomaly

  my $intron_match   = $ovlp->compare(\@single_introns, same_sense => 1); 
    

  foreach my $est (@{$est_hsp_aref}) { # $est_id, $chrom_start, $chrom_end, $chrom_strand
    $got_a_match = 0;
    if (my @results = $intron_match->match($est)) { 
      # check to see if the intron is completely covered by the EST
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $intron_match->matching_proportions($result);
	if ($prop2 == 1) {
	  $got_a_match = 1;
	}
      }
    }

    # output unmatched mass-spec protein to the database
    if ($got_a_match) {
      my $est_id = $est->[0];
      my $chrom_start = $est->[1];
      my $chrom_end = $est->[2];
      my $chrom_strand = $est->[3];

      my $anomaly_score = 5;	# huge score!

      &output_to_database("EST_OVERLAPS_INTRON", $chromosome, $est_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "");
    }
  }

  $intron_match   = $ovlp->compare(\@single_introns, same_sense => 1); 

  foreach my $ost (@{$ost_hsp_aref}) { # $ost_id, $chrom_start, $chrom_end, $chrom_strand
    $got_a_match = 0;
    if (my @results = $intron_match->match($ost)) { 
      # check to see if the intron is completely covered by the OST
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $intron_match->matching_proportions($result);
	if ($prop2 == 1) {
	  $got_a_match = 1;
	}
      }
    }

    # output unmatched mass-spec protein to the database
    if ($got_a_match) {
      my $ost_id = $ost->[0];
      my $chrom_start = $ost->[1];
      my $chrom_end = $ost->[2];
      my $chrom_strand = $ost->[3];
      
      my $anomaly_score = 1;	# OST are not so reliable, so give them a medium score

      &output_to_database("OST_OVERLAPS_INTRON", $chromosome, $ost_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "");
    }
  }

  $intron_match   = $ovlp->compare(\@single_introns, same_sense => 1); 

  foreach my $rst (@{$rst_hsp_aref}) { # $rst_id, $chrom_start, $chrom_end, $chrom_strand
    $got_a_match = 0;
    if (my @results = $intron_match->match($rst)) { 
      # check to see if the intron is completely covered by the RST
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $intron_match->matching_proportions($result);
	if ($prop2 == 1) {
	  $got_a_match = 1;
	}
      }
    }

    # output unmatched mass-spec protein to the database
    if ($got_a_match) {
      my $rst_id = $rst->[0];
      my $chrom_start = $rst->[1];
      my $chrom_end = $rst->[2];
      my $chrom_strand = $rst->[3];

      my $anomaly_score = 5;	# huge score!

      &output_to_database("RST_OVERLAPS_INTRON", $chromosome, $rst_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "");
    }
  }

  $intron_match   = $ovlp->compare(\@single_introns, same_sense => 1); 

  foreach my $mrna (@{$mrna_hsp_aref}) { # $mrna_id, $chrom_start, $chrom_end, $chrom_strand
    $got_a_match = 0;
    if (my @results = $intron_match->match($mrna)) { 
      # check to see if the intron is completely covered by the MRNA
      foreach my $result (@results) {
	my ($prop1, $prop2)   = $intron_match->matching_proportions($result);
	if ($prop2 == 1) {
	  $got_a_match = 1;
	}
      }
    }

    # output unmatched mass-spec protein to the database
    if ($got_a_match) {
      my $mrna_id = $mrna->[0];
      my $chrom_start = $mrna->[1];
      my $chrom_end = $mrna->[2];
      my $chrom_strand = $mrna->[3];

      my $anomaly_score = 5;	# huge score!

      &output_to_database("MRNA_OVERLAPS_INTRON", $chromosome, $mrna_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "");
    }
  }

}

####################################################################################
# get regions of high tiling array expression outside of known exons
# but matching unused twinscan exons

sub get_expression_outside_transcripts {
  my ($expression_aref, 
      $twinscan_exons_aref,
      $coding_transcript_exons_aref, 
      $pseudogenes_aref, 
      $transposons_aref, 
      $transposon_exons_aref, 
      $noncoding_transcript_exons_aref, 
      $rRNA_aref, 
      $miRNA_aref, 
      $ncRNA_aref, 
      $scRNA_aref, 
      $snRNA_aref, 
      $snoRNA_aref, 
      $stRNA_aref, 
      $tRNA_aref, 
      $tRNAscan_SE_1_23_aref, 
      $chromosome) = @_;

  $anomaly_count{UNMATCHED_EXPRESSION} = 0 if (! exists $anomaly_count{UNMATCHED_EXPRESSION});

  my @expression = @{$expression_aref};

      
  # we allow the expression to be in either sense compared to the coding exons
  my $twinscan_match = $ovlp->compare($twinscan_exons_aref, same_sense => 0);

  my $exons_match = $ovlp->compare($coding_transcript_exons_aref, same_sense => 0);
  my $pseud_match = $ovlp->compare($pseudogenes_aref, same_sense => 0);
  my $trans_match = $ovlp->compare($transposons_aref, same_sense => 0);
  my $trane_match = $ovlp->compare($transposon_exons_aref, same_sense => 0);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref, same_sense => 0);
  my $rrna_match  = $ovlp->compare($rRNA_aref, same_sense => 0);

  my $mirna_match  = $ovlp->compare($miRNA_aref, same_sense => 0);
  my $ncrna_match  = $ovlp->compare($ncRNA_aref, same_sense => 0);
  my $scrna_match  = $ovlp->compare($scRNA_aref, same_sense => 0);
  my $snrna_match  = $ovlp->compare($snRNA_aref, same_sense => 0);
  my $snorna_match  = $ovlp->compare($snoRNA_aref, same_sense => 0);
  my $strna_match  = $ovlp->compare($stRNA_aref, same_sense => 0);
  my $trna_match  = $ovlp->compare($tRNA_aref, same_sense => 0);
  my $trnascan_match  = $ovlp->compare($tRNAscan_SE_1_23_aref, same_sense => 0);

  foreach my $expression (@expression) { # $expression_id, $chrom_start, $chrom_end, $chrom_strand

    if ($expression->[2] - $expression->[1] < 60) {next;}		# don't want itty bitty small expression regions

    my $got_a_match = 1;	        # default until we have a twinscan match is that we DO have a match - twinscan resets this

    if ($twinscan_match->match($expression)) {               
      $got_a_match = 0;		# only can NOT have a match to a gene if we also have a match to a twinscan, so we find unmatched twinscan with high expression
    }

    if ($exons_match->match($expression)) {               
      $got_a_match = 1;
    }

    if ( $pseud_match->match($expression)) {              
      $got_a_match = 1;
    }

    if ($trans_match->match($expression)) {               
      $got_a_match = 1;
    }

    if ($trane_match->match($expression)) {               
      $got_a_match = 1;
    }

    if ($nonco_match->match($expression)) {               
      $got_a_match = 1;
    }

    if ($rrna_match->match($expression)) {                
      $got_a_match = 1;
    }





    if ($mirna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($ncrna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($scrna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($snrna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($snorna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($strna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($trna_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    if ($trnascan_match->match($expression)) {                #&match($expression, $rRNA_aref, \%rrna_match)) {
      $got_a_match = 1;
    }

    # output unmatched expression with twinscan to the database
    if (! $got_a_match) {
      my $expression_id = "tiling_array";
      my $chrom_start = $expression->[1];
      my $chrom_end = $expression->[2];
      my $chrom_strand = $expression->[3];
      my $protein_score = $expression->[6];

      my $anomaly_score = 10;

      #print "NOT got a match ANOMALY: $protein_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNMATCHED_EXPRESSION", $chromosome, $expression_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }

  }

}





####################################################################################
#
# get confirmed introns not matching a gene model 
# for use when there are no pre-computed confirmed intron data
#
####################################################################################

sub get_confirmed_introns {

  my ($est_aref) = @_;

  my @est = @{$est_aref};


  # change the ESTs into introns
  my @introns = $ovlp->get_intron_from_exons(@est);


  # want to check the introns look reasonable
  # length > 25 bases
  # contiguous in the EST
  # ends of the intron sequence: (not done here yet)
  # ((start eq 'gt' || start eq 'gc') && end eq 'ag') || # forward sense
  #  (start eq 'ct' && (end  eq 'ac' ||  end eq 'gc'))   # reverse sense
  my @checked_introns;
  foreach my $intron (@introns) {
    if ($intron->[2] - $intron->[1] > 25 &&
	abs($intron->[5] - $intron->[4]) == 1) {
      push @checked_introns, $intron;
    }
  }

  return @checked_introns;

}

####################################################################################
# get confirmed introns that don't match the curated gene models or pseudogenes, etc.
# used by brugia and other genomes that don't have a Build-generated list of confirmed exons
####################################################################################

sub get_unconfirmed_introns {

  my ($est_aref, $mrna_aref, $cds_introns_aref, $pseudogenes_aref, $transposons_aref, $transposon_exons_aref, $noncoding_transcript_exons_aref, $rRNA_aref, $chromosome) = @_;

  $anomaly_count{UNCONFIRMED_INTRON} = 0 if (! exists $anomaly_count{UNCONFIRMED_INTRON});

  my @est_introns = &get_confirmed_introns($est_aref); # change the ESTs into confirmed introns
  my @mrna_introns = &get_confirmed_introns($mrna_aref);

  my @not_matched = ();		# the resulting list of hashes of est with no matching exons/transposons/pseudogenes
  my @matched = ();		# the resulting list of hashes of est which match a coding exon

  # we want an exact match of the CDS inron to the EST confirmed intron
  # we are not too sure of the orientation (hence sense) of the EST hit
  my $cds_introns_match = $ovlp->compare($cds_introns_aref, exact_match => 1);
  my $pseud_match = $ovlp->compare($pseudogenes_aref);
  my $trans_match = $ovlp->compare($transposons_aref);
  my $trane_match = $ovlp->compare($transposon_exons_aref);
  my $nonco_match = $ovlp->compare($noncoding_transcript_exons_aref);
  my $rrna_match  = $ovlp->compare($rRNA_aref);

  # join the ESTs and mRNA hits and sort by start position 
  my @introns = sort {$a->[1] <=> $b->[1]} (@est_introns, @mrna_introns);

  # do both the EST and mRNA intons together
  foreach my $homology (@introns) { # $est_id, $chrom_start, $chrom_end, $chrom_strand

    my $got_a_match = 0;	        # not yet seen a match to anything

    if ($cds_introns_match->match($homology)) {
      $got_a_match = 1;
    }

    if ($pseud_match->match($homology)) { 
      $got_a_match = 1;
    }

    if ($trans_match->match($homology)) {   
      $got_a_match = 1;
    }

    if ($trane_match->match($homology)) {      
      $got_a_match = 1;
    }

    if ($nonco_match->match($homology)) {      
      $got_a_match = 1;
    }

    if ($rrna_match->match($homology)) {       
      $got_a_match = 1;
    }

    # output unmatched est to the database
    if (! $got_a_match) {
      my $est_id = $homology->[0];
      my $chrom_start = $homology->[1];
      my $chrom_end = $homology->[2];
      my $chrom_strand = $homology->[3];
      my $est_score = $homology->[6];
      my $anomaly_score = 1;
      #print "NOT got an EST match ANOMALY: $est_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("UNCONFIRMED_INTRON", $chromosome, $est_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
    }

  }

}

####################################################################################
# get jigsaw different to curated CDS

sub get_jigsaw_different_to_curated_CDS {

  my ($jigsaw_exons_aref, $CDS_exons_aref, $pseudogenes_aref, $chromosome) = @_;

  $anomaly_count{JIGSAW_DIFFERS_FROM_CDS} = 0 if (! exists $anomaly_count{JIGSAW_DIFFERS_FROM_CDS});

  # find the jigsaw prediction exons that don't overlap with a pseudogene
  my @jigsaw_not_pseudogene;
  my $pseud_match = $ovlp->compare($pseudogenes_aref);
  foreach my $jigsaw (@{$jigsaw_exons_aref}) { # $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand
    if (! $pseud_match->match($jigsaw)) {
      push @jigsaw_not_pseudogene, $jigsaw;
    }
  }

  # find CDS IDs that overlap jigsaw
  my %cds_overlaps_jigsaw;
  my $cds_match = $ovlp->compare($CDS_exons_aref);
  foreach my $jigsaw (@{$jigsaw_exons_aref}) { # $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand
    if (my @results = $cds_match->match($jigsaw)) {
      foreach my $cds_hit (@results) {
	push @{$cds_overlaps_jigsaw{$jigsaw}}, $cds_hit->[0]; # store the CDS ID
      }
    }
  }

  # here we don't use the overlap module, we do it more efficiently using a hash
  my %unmatched_jigsaw;		# list of jigsaw exons left when we remove matching CDS exons
  my %all_jigsaw_exons;		# list of all jigsaw exons

  # first load all the jigsaw exons into the hash
  foreach my $jigsaw (@jigsaw_not_pseudogene) { # $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand
    my $key = $jigsaw->[3]."_".$jigsaw->[1]."_".$jigsaw->[2];  # the key is the chromosomal sense and position
    $unmatched_jigsaw{$key} = $jigsaw;
    $all_jigsaw_exons{$key} = 1;
  }

  # now remove any jigsaw hash entries that have a key that matches the position of any curated CDS exon 
  my @unmatched_cds;		# list of CDS exons that don't match a jigsaw exon
  my %matched_cds;		# hash of CDS IDs where there is at least one exon in the CDS that matches a jigsaw exon
  foreach my $cds (@{$CDS_exons_aref}) { # $cds_id, $chrom_start, $chrom_end, $chrom_strand
    my $key = $cds->[3]."_".$cds->[1]."_".$cds->[2];
    my $cds_id = $cds->[0];
    
    if (exists $all_jigsaw_exons{$key}) { # check we have got a match
      $matched_cds{$cds_id} = 1; # note that this CDS matched a jigsaw exon

      if (exists $unmatched_jigsaw{$key}) {
	delete $unmatched_jigsaw{$key};	# delete the jigsaw exon that matches a CDS exon
      }
      
    } else {			# no match
      push @unmatched_cds, $cds; # store the CDS exon that doesn't match a jigsaw exon

    }
  }

  # now to cut down the numbers of CDS isoforms that differ slightly
  # from jigsaw, only report those isoforms which have no exons
  # that are the same as jigsaw.
  my @completely_unmatched_cds;
  foreach my $cds (@unmatched_cds) {
    my $cds_id = $cds->[0];
    if (! exists $matched_cds{$cds_id}) {
      push @completely_unmatched_cds, $cds;
    }
  }

  # now we output a hash of jigsaw details that don't match a CDS exon
  foreach my $jigsaw (values %unmatched_jigsaw) {

    # output unmatched jigsaw to the database
      my $jigsaw_id = $jigsaw->[0];
      my $chrom_start = $jigsaw->[1];
      my $chrom_end = $jigsaw->[2];
      my $chrom_strand = $jigsaw->[3];
      my $est_score = $jigsaw->[6];
      my $anomaly_score = 1;
      #print "JIGSAW_DIFFERS_FROM_CDS ANOMALY: $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      # get the unique list of CDS IDs that overlap with this JIGSAW (see p124 in the Perl Cookbook)
      my %seen;
      my @cds_ids = grep {! $seen{$_} ++ } @{$cds_overlaps_jigsaw{$jigsaw_id}};
      my $cds_ids="";
      foreach my $cds (@cds_ids) {
	$cds_ids .= "$cds ";
      }
      &output_to_database("JIGSAW_DIFFERS_FROM_CDS", $chromosome, $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, "See: $cds_ids");
  }

  # now we output a list of CDS details where no exon of the CDS has a match to a jigsaw exon
  foreach my $cds (@completely_unmatched_cds) {

    # output unmatched cds to the database
      my $cds_id = $cds->[0];
      my $chrom_start = $cds->[1];
      my $chrom_end = $cds->[2];
      my $chrom_strand = $cds->[3];
      my $est_score = $cds->[6];
      my $anomaly_score = 1;
      #print "CDS_DIFFERS_FROM_JIGSAW ANOMALY: $cds_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("CDS_DIFFERS_FROM_JIGSAW", $chromosome, $cds_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, '');
  }

  return (values %unmatched_jigsaw);
}

####################################################################################
# get jigsaw differing from curated CDS with SignalP where the CDS has no signalP

sub get_jigsaw_with_signalp {

  my ($unmatched_jigsaw_aref, $jigsaw_exons_aref, $CDS_aref, $chromosome) = @_;

  $anomaly_count{JIGSAW_WITH_SIGNALP} = 0 if (! exists $anomaly_count{JIGSAW_WITH_SIGNALP});

  # read in the pre-computed hash of jigsaw predictions that have signalP sites
  my %jigsaw_signalp;
  if (! -e $wormbase->wormpub . "/CURATION_DATA/${species}_jigsaw_signalp.dat") {
    print "WARNING: Can't find the file of jigsaw signalp predictions\n";
    return;
  }
  $wormbase->FetchData("${species}_jigsaw_signalp", \%jigsaw_signalp, $wormbase->wormpub . "/CURATION_DATA/");
  


  # get a list of jigsaw IDs that differ from the curated CDS
  my %jigsaw_differ_IDs;
  foreach my $jigsaw (@{$unmatched_jigsaw_aref}) {
    $jigsaw_differ_IDs{$jigsaw->[0]} = 1;
  }

  # for each differing jigsaw gene
  my @jigsaw_diff;
  # get the set of jigsaw exons that differ from the curated CDS
  foreach my $jigsaw (@{$jigsaw_exons_aref}) {
    if (exists $jigsaw_differ_IDs{$jigsaw->[0]}) { # this is a differing jigsaw gene
      push @jigsaw_diff, $jigsaw; # so save this jigsaw exon
    }
  }

  # get the curated CDS transcript (if any) that they overlap
  my %matching_cds;
  my $jigsaw_match   = $ovlp->compare(\@jigsaw_diff, same_sense => 1); 
  foreach my $cds (@{$CDS_aref}) { # $cds_id, $chrom_start, $chrom_end, $chrom_strand
    if (my @results = $jigsaw_match->match($cds)) { 
      my $cds_id = $cds->[0];
      foreach my $result (@results) {
	$matching_cds{$result->[0]} = $cds->[0]; # store the pairs of overlapping gene IDs for jigsaw and CDS
      }
    }
  }

  # foreach jigsaw gene that differs
  foreach my $jigsaw (@{$unmatched_jigsaw_aref}) {
    my $jigsaw_id = $jigsaw->[0];

    # get the protein sequence of the jigsaw gene
    my $jigsaw_obj = $ace->fetch("CDS" => $jigsaw_id);
    my $jigsaw_seq = $jigsaw_obj->asPeptide();
    my $title;
    ($title, $jigsaw_seq) = ($jigsaw_seq =~ /(.+)\n(.+)\n/); # get the first and second lines
    if (length $jigsaw_seq < 50) {next;}

    my $desc = "";

    # retrieve the protein sequence of the CDS (if it exists) from acedb
    if (exists $matching_cds{$jigsaw_id}) {

      $desc = "$jigsaw_id has a SignalP but $matching_cds{$jigsaw_id} doesn't";

      my $cds_obj = $ace->fetch("CDS" => $matching_cds{$jigsaw_id});
      my $cds_seq = $cds_obj->asPeptide();
      ($title, $cds_seq) = ($cds_seq =~ /(.+)\n(.+)\n/); # get the first and second lines

      # get the first 50 residues of the jigsaw and curated CDS proteins
      $jigsaw_seq = substr($jigsaw_seq, 0, 50);
      $cds_seq =    substr($cds_seq, 0, 50);

      # if the two sequences differ
      if ($jigsaw_seq eq $cds_seq) {next;}

      # if the curated CDS protein does not have a signalP site
      my $cds_protein_obj = $cds_obj->Corresponding_protein;
      if (! defined $cds_protein_obj) {
	print "WARNING: $matching_cds{$jigsaw_id} doesn't have a corresponding protein\n";
      } else {
	if (defined $cds_protein_obj->at('Feature.Signalp')) {next;}
      }
    } else {
      $desc = "$jigsaw_id has a SignalP - no corresponding curated CDS was found";
    }

    # if the jigsaw protein has a signalP site then output the anomaly
    if (exists $jigsaw_signalp{$jigsaw_id}) {
      my $jigsaw_id = $jigsaw->[0];
      my $chrom_start = $jigsaw->[1];
      my $chrom_end = $jigsaw->[2];
      my $chrom_strand = $jigsaw->[3];
      my $anomaly_score = 1;
      #print "JIGSAW_WITH_SIGNALP ANOMALY: $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score\n";
      &output_to_database("JIGSAW_WITH_SIGNALP", $chromosome, $jigsaw_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, $desc);
    }

  }

}

####################################################################################
####################################################################################
####################################################################################
####################################################################################
####################################################################################

####################################################################################
# look at high-scoring pfam motifs and report ones that are missing substantial bits at their ends

sub find_incomplete_pfam_motifs {


  $anomaly_count{INCOMPLETE_PFAM_MOTIF} = 0 if (! exists $anomaly_count{INCOMPLETE_PFAM_MOTIF});

  my $MOTIF_THRESHOLD = 100;	# amount of motif that can be missing before we report it

  my $pfam_id;

# get the lengths of the Pfam motifs
#  print "get lengths of Pfam motifs\n";
  my %pfam_length;
  my $pfam_file = "/tmp/Pfam";
  $wormbase->run_command("scp -q farm-login:/data/blastdb/Worms/interpro_scan/iprscan/data/Pfam $pfam_file", $log);
  open (PFAM, "< $pfam_file") || die "can't open $pfam_file\n";
  while (my $line = <PFAM>) {
    if ($line =~ /^ACC\s+(PF\d+)/) {
      $pfam_id = $1;
    }
    if ($line =~ /^LENG\s+(\d+)/) {
      $pfam_length{$pfam_id} = $1;
    }
  }
  close(PFAM);
  $wormbase->run_command("rm -f $pfam_file", $log);

# find the incomplete Pfam motifs

# open tace connection to Protein object and slurp up the contents
  my $prefix = $wormbase->wormpep_prefix;
  my $cmd = "query find Protein \"${prefix}:*\" Motif_homol Pfam\nshow -a Motif_homol\nquit\n";
  open (TACE, "echo '$cmd' | $tace $database |");
  my @slurp = <TACE>;
  close TACE;

# Now have data like:
#Protein : "WP:CE42042"
#Motif_homol      "PFAM:PF00635" "pfam" 43.099998 16 120 1 114
#Motif_homol      "INTERPRO:IPR000535" "interpro" 0.000000 16 133 1 118
#Motif_homol      "INTERPRO:IPR008962" "interpro" 0.000000 7 134 1 126

  my $protein_id;

#  print "find incomplete Pfam motifs\n";
  foreach my $line (@slurp) {
#  print "$line\n";
    if ($line =~ /^Protein\s+\:\s+\"(\S+)\"/) {$protein_id = $1;}
    if ($line =~ /PFAM/) {
      my @split = split /\s+/, $line;
      my ($pfam_id) = $split[1] =~ /PFAM\:(\S+)\"/;
      my $score = $split[3];
      my $prot_start = $split[4];
      my $prot_end = $split[5];
      my $motif_start = $split[6];
      my $motif_end = $split[7];

      if ($score < 100) {next;}
      # see if we have a partial match at the start
      if ($motif_start > $MOTIF_THRESHOLD) {
	#print "$protein_id : score: $score not start of $pfam_id (1) $motif_start..$motif_end\n";
	my ($chromosome, $chrom_start, $chrom_end) = &convert_protein_coords_to_chrom_coords($protein_id, $prot_start, $prot_end);
	if (! defined $chromosome) {next;} # found an isoform or other problem

	# ouput details of the region to the anomalies database
	if (defined $chromosome) {
	  my $chrom_strand = '+';
	  if ($chrom_start > $chrom_end) {
	    $chrom_strand = '-';
	    my $tmp = $chrom_end;
	    $chrom_end = $chrom_start;
	    $chrom_start = $tmp;
	  }

	  # if we want the anomalies GFF file, output these details
	  if ($supplementary) {
	    my $gff_file = "$database/CHROMOSOMES/SUPPLEMENTARY_GFF/${chromosome}_curation_anomalies.gff";
	    open (OUTPUT_GFF, ">>$gff_file") || die "Can't open $gff_file";
	  }
	  
#	  print "$chromosome, $chrom_start, $chrom_end, $chrom_strand $pfam_id missing motif at start\n";
	  my $anomaly_score = 2;
	  &output_to_database("INCOMPLETE_PFAM_MOTIF", $chromosome, $pfam_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, 'missing part of motif at start');
	  
	  if ($supplementary) {
	    close(OUTPUT_GFF);
	  }
	}

      } elsif (exists $pfam_length{$pfam_id} && $motif_end < $pfam_length{$pfam_id} - $MOTIF_THRESHOLD) {
	# ... and at the end

	#print "$protein_id : score: $score not end of $pfam_id $motif_start..$motif_end ($pfam_length{$pfam_id})\n";
	my ($chromosome, $chrom_start, $chrom_end) = &convert_protein_coords_to_chrom_coords($protein_id, $prot_start, $prot_end);
	if (! defined $chromosome) {next;} # found an isoform or other problem

	# ouput details of the region to the anomalies database
	if (defined $chromosome) {
	  my $chrom_strand = '+';
	  if ($chrom_start > $chrom_end) {
	    $chrom_strand = '-';
	    my $tmp = $chrom_end;
	    $chrom_end = $chrom_start;
	    $chrom_start = $tmp;
	  }

	  # if we want the anomalies GFF file, output these details
	  if ($supplementary) {
	    my $gff_file = "$database/CHROMOSOMES/SUPPLEMENTARY_GFF/${chromosome}_curation_anomalies.gff";
	    open (OUTPUT_GFF, ">>$gff_file") || die "Can't open $gff_file";
	  }
	  
#	  print "$chromosome, $chrom_start, $chrom_end, $chrom_strand $pfam_id missing motif at end\n";
	  my $anomaly_score = 2;
	  &output_to_database("INCOMPLETE_PFAM_MOTIF", $chromosome, $pfam_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, 'missing part of motif at end');
	  
	  if ($supplementary) {
	    close(OUTPUT_GFF);
	  }
	}
	
	
      }
    }
  }

}



##############################################################
#
# Subroutines for mapping proteins to the genome
#
##############################################################


#      my ($chromosome, $chrom_start, $chrom_end) = &convert_protein_coords_to_chrom_coords($protein_id, $prot_start, $prot_end);

sub convert_protein_coords_to_chrom_coords {

  my ($protein_id, $prot_start, $prot_end) = @_;

 # get CDS ID for this protein
  my ($cds_name) = &get_cds_from_protein($protein_id);
  if (! defined $cds_name) {return (undef, undef, undef);} # this is a history CDS

 # we don't want isoforms because these naturally have fragments of domains 
  if ($cds_name =~ /(\S+\.\d+)[a-z]/) {
    return (undef, undef, undef);
  }

 # get the CDS details
  my ($clone, $cds_start, $cds_end, $exons_start_ref, $exons_end_ref) = &get_cds_details($cds_name);
  if (! defined $clone) {return (undef, undef, undef);} # some problem here

 # map the positions in the protein to the genome
  my ($chromosome, $chrom_start, $chrom_end);
  ($chromosome, $chrom_start) = &get_genome_mapping($cds_name, $clone, $cds_start, $cds_end, $exons_start_ref, $exons_end_ref, $prot_start); 
  if (! defined $chromosome) {return (undef, undef, undef);} # some problem here
  ($chromosome, $chrom_end)   = &get_genome_mapping($cds_name, $clone, $cds_start, $cds_end, $exons_start_ref, $exons_end_ref, $prot_end); 


  return ($chromosome, $chrom_start, $chrom_end);

}
##########################################
#  my (cds_name) = &get_cds_from_protein($protein_id);
# get the CDS ID from the Protein ID

sub get_cds_from_protein {
  my ($protein_id) = @_;


  my $protein_obj = $ace->fetch("Protein" => $protein_id);
  #print "get CDS for $protein_id\n";
  my $cds_id = $protein_obj->Corresponding_CDS;
  $protein_obj->DESTROY();
  if (! defined $cds_id) {
    #print "history CDS\n";
    return undef;
  }
  return $cds_id->name;

}

##########################################
# my ($clone, $cds_start, $exons_start_ref, $exons_end_ref) = &get_cds_details($protein_name);
# get the clone, clone start position and exons list from a CDS
#

sub get_cds_details {
  my ($cds_name) = @_;

  #print "Ace fetch->" if ($verbose);
  #print "$cds_name\n" if ($verbose);
  my $cds_obj = $ace->fetch("CDS" => $cds_name);
  # debug
  if (! defined $cds_obj) {
    #print "cds problem\n";
    return (undef, undef, undef, undef, undef);
  }

  my $clone = $cds_obj->Sequence;
  if (! defined $clone) {
    #print "clone problem\n";
    return (undef, undef, undef, undef, undef);
  }

  # get the named object
  # then get the data following a tag in that object
  # and the NEXT data following the tag
  my @exons_start = $cds_obj->Source_exons;
  my @exons_end = $cds_obj->Source_exons(2);
  $cds_obj->DESTROY();
  if (! @exons_start || ! @exons_end) {
    #print "exons problem\n";
    return (undef, undef, undef, undef, undef);
  }

  # get the start position of the CDS in the clone's SMap
  #print "Ace fetch->clone = $clone\n" if ($verbose);
  my $clone_obj = $ace->fetch("Sequence" => $clone);
  if (! defined $clone_obj) {
    #print "cds start problem\n";
    return (undef, undef, undef, undef, undef);
  }

  # You have to creep up on the data you want by using the $obj->at()
  # structure, in which you can specify exactly the path of tags and
  # data through the object that you wish to traverse and then you can
  # get the list of resulting positions under the sub-path that you
  # want. This means that you must break up the query into a loop
  # looking at every score value of every wormbase homology and then
  # you can get the positions under that score.

  my $foundit = 0;
  my ($cds, $cds_start, $cds_end);
  foreach $clone_obj ($clone_obj->at('SMap.S_child.CDS_child')) {
    ($cds, $cds_start, $cds_end) = $clone_obj->row;
    if ($cds eq $cds_name) {
      $foundit = 1;
      last;
    }
  }

  if (! $foundit || ! defined $cds_start || ! defined $cds_end) {
    #print "Can't fetch start/end positions for $cds_name in $clone\n";
    return (undef, undef, undef, undef, undef);
  }

  # if the CDS is on the reverse sense, then $cds_end > $cds_start
  return ($clone, $cds_start, $cds_end, \@exons_start, \@exons_end);

}

##########################################
# my @homol_lines = &get_genome_mapping($cds_name, $clone, $cds_start, $exons_start_ref, $exons_end_ref, $prot_pos);
# Convert a protein position to a genomic position

sub get_genome_mapping {
  my ($cds_name, $clone_name, $cds_start, $cds_end, $exons_start_ref, $exons_end_ref, $prot_pos) = @_;

  my ($chromosome, $chrom_pos);
  my $clone_pos;

  # the positions of the exons on the clone relative to the start of the CDS
  my @exons_start = @{$exons_start_ref};
  my @exons_end = @{$exons_end_ref};

  # convert the protein position to CDS coding position
  my $cds_pos = ($prot_pos * 3) - 2; # start at the beginning of the codon, not the end :-)

  # go through the exons seeing which one the position we want is in
  my $exon_count = 0;
  my $prev_end = 0;
  foreach my $exon_start (@exons_start) {
    my $exon_length = $exons_end[$exon_count] - $exon_start + 1;
    my $cds_exon_start = $prev_end + 1;	# position of the start of this exon in the CDS
    my $cds_exon_end = $cds_exon_start + $exon_length - 1;
    
    if ($cds_pos >= $cds_exon_start && $cds_pos <= $cds_exon_end) {
      #print "pos is in this exon\n";
      my $pos_in_this_exon = $cds_pos - $cds_exon_start;
      if ($cds_start < $cds_end) { # forward sense
	$clone_pos = $cds_start + $exon_start + $pos_in_this_exon  - 1;
      } else {			# reverse sense
	$clone_pos = $cds_start - ($exon_start + $pos_in_this_exon  - 1);
      }
      ($chromosome, $chrom_pos) = $coords->Coords_2chrom_coords($clone_name, $clone_pos);
      last;
    }

    $prev_end = $cds_exon_end;
    $exon_count++;
  }


  return ($chromosome, $chrom_pos);
}


####################################################################################
#
# General Subroutines
#
####################################################################################

##########################################
# checks if there is sense = + or - and if not, outputs two anomaly records, one for each sense.
# else it just outputs one record for the specified sense.

sub output_to_database {
  my ($anomaly_type, $chromosome, $anomaly_id, $chrom_start, $chrom_end, $chrom_strand, $anomaly_score, $explanation ) = @_;

  # get the clone and lab for this location
  my ($clone, $clone_start, $clone_end) = $coords->LocateSpan("$chromosome", $chrom_start, $chrom_end);
  my $lab;
  if ($wormbase->species eq 'elegans') {
    $lab =  $clonelab{$clone};          # get the lab that sequenced this clone  
    if (! defined $lab) {
      if ($clone =~ /SUPERLINK_CB_/) {
	$lab = 'HX';
      } else {
	$lab = 'RW';
      }
    }
  } elsif ($wormbase->species eq 'briggsae') {
    $lab = 'RW';
  } elsif ($wormbase->species eq 'brugia') {
    $lab = 'RW';
  } elsif ($wormbase->species eq 'remanei') {
    $lab = 'RW';
  } else {
    print "*** ERROR - WE DON'T KNOW WHICH LAB IS CURATING SPECIES: $wormbase->species\n";
  }
  #print "clone $clone is in lab $lab\n";

  # calculate the window value as blocks of 10 kb
  my $window =  int($chrom_start/10000);

  # truncate the $anomaly_id string to 32 characters (the width of the 'thing_id' field in the 'anomaly' table)
  $anomaly_id = substr($anomaly_id, 0, 32);

  # if there is no strand information, put one anomaly in for each strand
  if ($chrom_strand ne '+' && $chrom_strand ne '-') {
    &put_anomaly_record_in_database($anomaly_type, $chromosome, $anomaly_id, $chrom_start, $chrom_end, '+', $window, $anomaly_score, $explanation, $clone, $clone_start, $clone_end, $lab);
    &put_anomaly_record_in_database($anomaly_type, $chromosome, $anomaly_id, $chrom_start, $chrom_end, '-', $window, $anomaly_score, $explanation, $clone, $clone_start, $clone_end, $lab);

  } else {
    &put_anomaly_record_in_database($anomaly_type, $chromosome, $anomaly_id, $chrom_start, $chrom_end, $chrom_strand, $window, $anomaly_score, $explanation, $clone, $clone_start, $clone_end, $lab);

  }
}

##########################################
# output the record to the database.
# checks if there is a record there already and doesn't change the 'ignore' flag if there is
# already a record in existence.

sub put_anomaly_record_in_database {

  my ($anomaly_type, $chromosome, $anomaly_id, $chrom_start, $chrom_end, $chrom_strand, $window, $anomaly_score, $explanation, $clone, $clone_start, $clone_end, $lab) = @_;


  # ignore this if the score is less than 0.01
  if ($anomaly_score < 0.01) {return;}

  #################################
  # output the data to the GFF file
  #################################

  if ($supplementary) {
    print OUTPUT_GFF "$chromosome\tcuration_anomaly\t$anomaly_type\t$chrom_start\t$chrom_end\t$anomaly_score\t$chrom_strand\t.\tEvidence \"$anomaly_id\"\n";
  }

  ####################################
  # output the anomaly to the ace file
  ####################################

  open (OUT, ">> $ace_output") || die "Can't open $ace_output\n";
  print OUT "\n\n";

  # get length of the clone
  my $clone_len = $coords->Superlink_length($clone);

  #Sequence : "AC3"
  #Homol_data "AC3:curation_anomaly" 1 38951

  print OUT "\nSequence : \"$clone\"\n";
  print OUT "Homol_data \"$clone:curation_anomaly\" 1 $clone_len\n\n";

  #Homol_data : "AC3:curation_anomaly"
  #Sequence "AC3"
  #Motif_homol "curation_anomaly" curation_anomaly 15   189   215  1      15

  my $anomaly_len = $chrom_end - $chrom_start + 1;

  print OUT "\nHomol_data : \"$clone:curation_anomaly\"\n";
  print OUT "Sequence \"$clone\"\n";
  if ($chrom_strand eq '+') {
    print OUT "Motif_homol \"$anomaly_type:$anomaly_id:curation_anomaly\" \"curation_anomaly\" $anomaly_score $clone_start $clone_end 1 $anomaly_len\n\n";
  } else {
    print OUT "Motif_homol \"$anomaly_type:$anomaly_id:curation_anomaly\" \"curation_anomaly\" $anomaly_score $clone_start $clone_end $anomaly_len 1\n\n";
  }
      
  #Motif : "signal_peptide_motif"
  #Homol_homol "AC3:signal_peptide"

  print OUT "\nMotif : \"$anomaly_type:$anomaly_id:curation_anomaly\"\n";
  print OUT "Homol_homol \"$clone:curation_anomaly\"\n\n";
    
  close(OUT);

  #############################################
  # write the anomaly data to the data file
  #############################################

  # count the anomalies found
  $anomaly_count{$anomaly_type}++;

  # and output the line for the St. Louis datafile
  my $prefix = $wormbase->chromosome_prefix;
  $chromosome =~ s/$prefix//;
  print DAT "INSERT\t$anomaly_type\t$chromosome\t$anomaly_id\t$chrom_start\t$chrom_end\t$chrom_strand\t$anomaly_score\t$explanation\t$clone\t$clone_start\t$clone_end\t$lab\n";


}

##########################################
# now delete things that have not been updated in this run that you
# would expect to have been updated like protein-homology-based
# anomalies that might have gone away.  This also deletes anomalies
# that we are no longer putting into the database and which can now be
# removed.
#
# This means that an anomaly based on something like a similarity to a
# protein where the protein is no longer existing will be removed from
# the database

sub delete_anomalies{

  my ($type) = @_;

  # output the line for the St. Louis datafile
  print DAT "DELETE\t$type\n";

}

##########################################

sub usage {
  my $error = shift;

  if ($error eq "Help") {
    # Normal help menu
    system ('perldoc',$0);
    exit (0);
  }
}

##########################################




# Add perl documentation in POD format
# This should expand on your brief description above and 
# add details of any options that can be used with the program.  
# Such documentation can be viewed using the perldoc command.


__END__

# table of which analyses to use with which organisms


START_DATA
UNMATCHED_PROTEIN            elegans remanei briggsae japonica brugia
UNMATCHED_EST                
FRAMESHIFTED_PROTEIN         elegans remanei briggsae japonica brugia
MERGE_GENES_BY_PROTEIN       elegans remanei briggsae japonica brugia
SPLIT_GENE_BY_PROTEIN_GROUPS elegans remanei briggsae japonica brugia
MERGE_GENES_BY_EST
UNATTACHED_EST
UNATTACHED_TSL
UNMATCHED_TSL                elegans
UNMATCHED_RST5               elegans
UNMATCHED_TWINSCAN           elegans
UNMATCHED_GENEFINDER         elegans
JIGSAW_DIFFERS_FROM_CDS      elegans
JIGSAW_WITH_SIGNALP          elegans
UNMATCHED_SAGE               elegans
UNMATCHED_WABA               elegans
OVERLAPPING_EXONS            elegans remanei briggsae japonica brugia
MISMATCHED_EST               elegans remanei briggsae japonica brugia
WEAK_INTRON_SPLICE_SITE      elegans remanei briggsae japonica brugia
SHORT_EXON                   elegans remanei briggsae japonica brugia
SHORT_INTRON                 elegans remanei briggsae japonica brugia
REPEAT_OVERLAPS_EXON         elegans remanei briggsae japonica brugia
INTRONS_IN_UTR               elegans remanei briggsae japonica brugia
SPLIT_GENE_BY_TWINSCAN       elegans
MERGE_GENES_BY_TWINSCAN      elegans
CONFIRMED_INTRON             elegans remanei briggsae japonica 
UNCONFIRMED_INTRON                   brugia
UNMATCHED_MASS_SPEC_PEPTIDE  elegans
EST_OVERLAPS_INTRON          elegans remanei briggsae japonica brugia
UNMATCHED_EXPRESSION         elegans
INCOMPLETE_PFAM_MOTIF        elegans remanei briggsae japonica 
END_DATA

=pod

=head2 NAME - find_anomalies.pl

=head1 USAGE

=over 4

=item find_anomalies.pl  [-options]

=back

This writes a data file ready to populate the worm_anomaly mysql
database with data describing some types of anomalies.

It can be run periodicaly e.g. every build which is especially useful
if there have been corrections made to the genomic sequence

These anomalies can be inspected using the script:

history_maker.pl -anomalies -chromosome X

script_template.pl MANDATORY arguments:

=over 4

=item none

=back

script_template.pl  OPTIONAL arguments:

=over 4

=item -database

This specifies an ACeDB database to use to read GFF data etc.

The default is to use autoace.

=over 4

=item -species

The species - the default is 'elegans'

=over 4

=item -h, Help

=back

=over 4
 
=item -debug, Verbose/Debug mode
 
=back

=over 4

=item -test, Test mode

=back

=over 4
    
=item -verbose, output lots of chatty test messages

=back
                                                                                             

=head1 REQUIREMENTS

=over 4

=item GFF files for the input data

=back

=head1 AUTHOR

=over 4

=item Gary Williams (gw3@sanger.ac.uk)

=back

=cut


