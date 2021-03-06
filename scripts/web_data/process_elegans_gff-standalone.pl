#!/usr/bin/env perl

use strict;
use Getopt::Long;

use lib $ENV{CVS_DIR};
use Wormbase;
use Ace;
use Log_files;

my (
  $debug, 
  $test,
  $species,
  $species_full,
  $store,
  $wormbase,
  $outfile,
  $outfh,
  $database,
    );

GetOptions('species:s' => \$species,
           'debug:s'   => \$debug,
           'test'      => \$test,
           'store=s'   => \$store,
           'outfile=s' => \$outfile,
           'database=s' => \$database,
           )||die(@!);


# Note: because this script pulls in comparative data and up-to-date gene names,
# it is only ever run on a post-merge autoace. 

if ( $store ) {
  $wormbase = retrieve( $store ) or croak("Can't restore wormbase from $store\n");
} else {
  $wormbase = Wormbase->new( -debug   => $debug,
                             -test    => $test,                             );
}


my $log = Log_files->make_build_log($wormbase);

$database = $wormbase->autoace if not defined $database;
$log->log_and_die("Database $database could not be found\n") if not -d $database;

if (not defined $species) {
  $species = $wormbase->species;
  $species_full = $wormbase->full_name;
} else {
  if ($species ne $wormbase->species) {
    my %sa = $wormbase->species_accessors;
    if (exists $sa{$species}) {
      $species_full = $sa{$species}->full_name;
    } else {
      $log->log_and_die("Species '$species' is not a recognised WormBase tierII species\n");
    }
  } else {
    $species_full = $wormbase->full_name;
  }
}

my $db = Ace->connect( $database ) or $log->log_and_die("Can't open ace database:". Ace->error );

my (
  %LOCUS,
  %CONFIRMED,
  %GENES,
  %GENE_EXTENTS,
  %WORMPEP,
  %TRANSCRIPT2CDS,
  %genes_seen,
  %loci_seen,
);

# setting up things
if (defined $outfile) {
  open($outfh, ">$outfile") or $log->log_and_die("Could not open $outfile for writing\n");
} else {
  $outfh = \*STDOUT;
}

$log->write_to("getting confirmed genes\n") if $debug;
get_confirmed( $db, \%CONFIRMED );

$log->write_to("getting transcript2cds\n") if $debug;
get_transcripts( $db, \%TRANSCRIPT2CDS );

$log->write_to("getting wormpep\n") if $debug;
get_wormpep( $db, \%WORMPEP );

$log->write_to("getting loci information\n") if $debug;
get_loci( $db, \%LOCUS );

$log->write_to("getting genes\n") if $debug;
get_genes( $db, \%GENES );


while (<>) {
    
    # skip comments unless it is a seq-region definition
    if (/^\#/) {
      if (/^##sequence-region/){
        print $outfh $_;
      }
      next;
    }

    chomp;

    my ( $ref, $source, $method, $start, $stop, $score, $strand, $phase, $group ) = split /\t/;
    
    next if $source eq 'assembly_tag';    # don't want 'em, don't need 'em
    next if $method eq 'HOMOL_GAP';       # don't want that neither
    next if $method eq 'intron' and $source ne 'RNASeq_splice';

    $ref   =~ s/^CHROMOSOME_//;
    $group =~ s/CHROMOSOME_//;

    $source = '.' if $source eq '*UNKNOWN*';

    # Process top-level CDS and Transcript entries
    #if ( $method=~/Transcript|CDS|.*primary_transcript/ && $source=~/Coding_transcript|curated|.*RNA|miRNA/i && $group=~/[Transcript|CDS] "(\w+\.\d+[a-z]?\.?\d?)"/ ) {
    if ( $method=~/Transcript|CDS|.*primary_transcript/ && $source=~/Coding_transcript|curated|.*RNA|miRNA/i && $group=~/[Transcript|CDS] "(\S+)"/ ) {
        ### Need to pick up transcript IDs, too

        my $match = $1;
        remember_gene_extents( $1, $ref, $start, $stop, $strand );
        my @notes;

        # Many of the hash lookups are keyed by CDS *only*
        my $lookup = ( $group =~ /Transcript/ ) ? $TRANSCRIPT2CDS{$match} : $match;

        # This probably needs to be more restrictive
        my $loci = $LOCUS{$lookup} || $LOCUS{$match};

        # WS133: Still required
        # ADD IN A SEPERATE ENTRY FOR EACH LOCUS
        if ($loci) {    # These are really genes...
            foreach (@$loci) {
                my $bestname = bestname($_);

                # Span for curated loci - only once per WBGene
                print $outfh join( "\t", $ref, 'curated', 'gene', $start, $stop, $score, $strand, $phase, "Locus $bestname" ), "\n"
                  if ( !$loci_seen{$bestname}++ );
            }
        }
        
        if($source eq 'curated' && $method eq 'CDS' ){
	 $group=~/(WBGene\d+)/;
         my $gene_id = $1;
         my $gene = $db->fetch(Gene => $gene_id);

         if ($gene){
            #grab all C.elegans orthologs
            my @elegansOrthologs = grep {$_->Species eq 'Caenorhabditis elegans'} $gene->Ortholog;
            foreach my $eGene(@elegansOrthologs){
                    map {$group.=" ; Alias \"$_\"" if $_}($eGene->CGC_name,$eGene->Sequence_name,"$eGene")
            }	
         }
        }

        if ( $method =~ /.*primary_transcript/ ) {

            # Add a CDS attribute to Transcript entries
            # (Need to be able to associate CDSes with Transcripts)
            push @notes, qq(CDS "$lookup") if $TRANSCRIPT2CDS{$match};

            # Create a top level feature for Coding_transcript to accomodate
            # GBrowse modification on feature aggregation. Although Sanger
            # supplies Coding_transcript:protein_coding_primary_transcript
            # entries, we need individual entries of
            # Coding_transcript:Transcript to ensure proper aggregation.

            # What are the ramifications of this on things like RNAs?
            $group = join ' ; ', $group, @notes;
            if ( $method =~ /protein_coding_primary_transcript/ ) {
                print $outfh join( "\t",
                    $ref, 'Coding_transcript', 'Transcript', $start, $stop,
                    $score, $strand, $phase, $group ), "\n";
            }
            else {

                # This will be RNAs and such.
                # Should I also preserve the original entries? (This is basicallt the original entry)
                # Do I need a top level feature of method Transcript in order for aggregation to work correctly?
                
                print $outfh join( "\t", $ref, $source, $method, $start, $stop, $score, $strand, $phase, $group ), "\n";
            }
            next;
        }

        $group = join ' ; ', $group, @notes;
        print $outfh join( "\t", $ref, $source, $method, $start, $stop, $score, $strand, $phase, $group ), "\n";

        next;
    }

    # Skip Ant's fix for WBGenes
    elsif ($source eq 'Gene' && $method eq 'processed_transcript'){next}

    elsif ( $method eq 'intron' && $source =~ /^tRNAscan/ ){next} # messing up tRNA scanning

    # Tier II id flunkification
    elsif ( $source eq 'gene' && $method eq 'gene'){
	$group=~/(WBGene\d+)/;
        my $gene_id = $1;
        my $gene = $db->fetch(Gene => $gene_id);

        if ($gene){
            #grab all C.elegans orthologs
            my @elegansOrthologs = grep {$_->Species eq 'Caenorhabditis elegans'} $gene->Ortholog;
            foreach my $eGene(@elegansOrthologs){
                    map {$group.=" ; Alias \"$_\"" if $_}($eGene->CGC_name,$eGene->Sequence_name,"$eGene")
            }	
        }
        else {
            $log->write_to("ERROR: cannot find $gene_id from ($group) in line:\nERROR: $_\n");
        }
    }
    
    # fix reversed targets
    if ( $group =~ /Target \S+ (\d+) (\d+)/ ) {
        if ( $2 < $1 ) {
            $group =~ s/(\d+) (\d+)/$2 $1/;
            $strand = '-';
        }
    }
    print $outfh join( "\t",
        $ref,   $source, $method, $start, $stop,
        $score, $strand, $phase,  $group ),
        "\n";
}

# write out the extents of the genes
my %seenit;
for my $cds ( keys %GENES ) {
    ( my $base = $cds ) =~ s/[a-z]$//;
    next if $seenit{$base}++;
    next unless $GENE_EXTENTS{$base};
    my ( $seqid, $start, $stop, $strand ) = @{ $GENE_EXTENTS{$base} }{qw(seqid start stop strand)};
    for my $gene ( keys %{$GENES{$cds}} ) {    # there *should* be only one gene per cds
      print $outfh join( "\t", $seqid, 'gene', 'processed_transcript', $start, $stop, '.', $strand, '.', qq(Gene "$gene") ), "\n";
    }
}

if (defined $outfile) {
  close($outfh);
}
$db->close;
$log->mail();

exit 0;

# remember the extreme left and right of transcripts
# for translating into gene extents.  This is called with
# CDS and UTR groups.
sub remember_gene_extents {
    my ( $group, $seqid, $start, $stop, $strand ) = @_;
    $group =~ s/[a-z]$//;    # get the base name of the CDS/UTR group
    
    $GENE_EXTENTS{$group}{start} = $start if !defined $GENE_EXTENTS{$group}{start} || $GENE_EXTENTS{$group}{start} > $start;
    $GENE_EXTENTS{$group}{stop}  = $stop if !defined $GENE_EXTENTS{$group}{stop} || $GENE_EXTENTS{$group}{stop} < $stop;
    $GENE_EXTENTS{$group}{strand} ||= $strand;
    $GENE_EXTENTS{$group}{seqid}  ||= $seqid;
}

# grab gene2cds.commondata
sub get_genes {
  my ($db,$hash) = @_;  # Keys are CDSes; values are WBGeneIDs
  #  my @genes = $db->fetch(-query=>'find Gene IS WBGene0* AND Corresponding_CDS');
  my @genes = $db->fetch(-query=> sprintf("find GENE WHERE Species = \"%s\"", $species_full));
  foreach my $obj (@genes) {
    my @cds = ($obj->Corresponding_CDS,$obj->Corresponding_Transcript);
    next unless @cds;
    foreach (@cds) {
      $hash->{$_}->{$obj} = 1;
    }
  }
}

sub get_transcripts {
    my ( $db, $hash ) = @_;    # Keys are transcript; values are CDSids
    my @transcripts = $db->fetch( -query => sprintf("find Transcript WHERE Species = \"%s\"", $species_full ));
    foreach my $obj (@transcripts) {
        my $cds = $obj->Corresponding_CDS;
        $hash->{$obj} = $cds;
    }
}

# New gene model ( > WS123 approach)
# Fetch all genes that are also loci
sub get_loci {

    # hash keys are predicted gene names, values are one or more gene objects
    # (These gene objects will be translated into three-letter locus names prior to dumping)
    my ( $db, $hash ) = @_;

    # Fetch out all the cloned loci
    # This approach means that some genes will have duplicate entries (arising form the Other_names)
    my @loci = $db->fetch( -query => sprintf("find Gene Molecular_info AND (CGC_name OR Other_name) AND Species = \"%s\"", $species_full));

    foreach my $obj (@loci) {
        my @genomic = ( $obj->Corresponding_CDS, $obj->Corresponding_Transcript );
        @genomic >= 1 or next;
        foreach (@genomic) {
            push @{ $hash->{$_} }, $obj;
        }
    }
}

# allow lookup by wormpep id
sub get_wormpep {
    my ( $db, $hash ) = @_ ; # hash keys are predicted CDS names, values are one or more wormpep names
#   $hash = $wb->FetchData( 'cds2wormpep', $hash );

    my @genes = $db->fetch(-query => sprintf("find CDS Corresponding_protein AND Species = \"%s\"", $species_full), 
                           -filltag =>'Corresponding_protein');
    foreach my $obj (@genes) {
      my $wormpep = $obj->Corresponding_protein or next;
      $hash->{"$obj"} = "$wormpep";
    }
}


# What is the confirmed status for CDSes?
# This has changed with WS133
sub get_confirmed {
    my ( $db, $hash ) = @_; # hash keys are predicted gene names, values are confirmation type
    my @confirmed = $db->fetch( -query => sprintf("find CDS Prediction_status AND Species = \"%s\"", $species_full));
    foreach my $obj (@confirmed) {
        my ($tag) = $obj->Prediction_status->row if ( $obj->Prediction_status );
        $hash->{$obj} = $tag;
    }
}


# Translate WB gene IDs into more useful molecular or three-letter names
sub bestname {
    my $gene = shift;
    # Public name is, oddly, never filled in.
    my $bestname =
         $gene->Public_name
      || $gene->CGC_name
      || $gene->Molecular_name
      || $gene->Sequence_name;
    return $bestname;
}
