#!/usr/local/bin/perl5.8.0 -w          
#
# map_features.pl
#
# by Dan Lawson
#
# This maps features to the genome based on their flanking sequence.
# Uses Ant's Feature_mapper.pm module
#
#
# Last updated by: $Author: pad $                      # These lines will get filled in by cvs and helps us
# Last updated on: $Date: 2012-12-20 11:04:29 $        # quickly see when script was last changed and by whom


$|=1;
use strict;
use lib $ENV{'CVS_DIR'};
use Feature_mapper;
use Wormbase;
use Ace;
use Getopt::Long;
use Modules::Remap_Sequence_Change;


my ($feature,$target,$flanking_left,$flanking_right,$coords,$span,$store);
my $database;                # spcify a database to pull data from.....used when testing new models etc.
my $noload;                  # don't load the data back to the database.
my $outfile;                 # specify an output file for data.
my $help;                    # Help menu
my $debug;                   # Debug mode 
my $verbose;                 # Verbose mode
my $all;                     # Do all the following features:
my $SL1;                     #  SL1 trans-splice leader acceptors
my $SL2;                     #  SL2 trans-splice leader acceptors
my $polyA_site;              #  polyA_site
my $polyA_signal;            #  polyA_signal
my $binding_site;            #  binding_site feature data.
my $binding_site_reg;        #  binding_site_region feature data
my $TF_binding_site;
my $TF_binding_site_reg;
my $histone_binding_site;
my $histone_binding_site_reg;
my $segmental_duplication;          #  segmental_duplication features
my $genome_sequence_error;   # genome_sequence_error
my $genome_sequence_correction;   # genome_sequence_correction
my $transcription_start_site;# transcription_start_site
my $transcription_end_site;  # transcription_end_site
my $three_prime_UTR;         # three prime UTRs
my $DNAseI_hypersensitive_site; # DNAseI_hypersensitive_site
my $promoter;                # promoter region
my $regulatory_region;       # regulatory region
my $id_file;                 # takes a list of objects from a file
my $start;
my $stop;
my $test;
my $no_load;
my $micro;
my $outdir;
my $curout;

GetOptions (
	    "database:s"                 => \$database,
	    "all"                        => \$all,
	    "SL1"                        => \$SL1,
	    "SL2"                        => \$SL2,
	    "polyA_site"                 => \$polyA_site,
	    "polyA_signal"               => \$polyA_signal,
	    "binding_site"               => \$binding_site,
	    "binding_site_reg"           => \$binding_site_reg,
	    "tf_binding_site"            => \$TF_binding_site,
	    "tf_binding_site_reg"        => \$TF_binding_site_reg,
	    "histone_binding_site"       => \$histone_binding_site,
	    "histone_binding_site_reg"   => \$histone_binding_site_reg,  
	    "segmental_duplication"      => \$segmental_duplication,
	    "Genome_sequence_error"      => \$genome_sequence_error,
	    "Genome_sequence_correction" => \$genome_sequence_correction,
	    "transcription_start_site"   => \$transcription_start_site,
	    "transcription_end_site"     => \$transcription_end_site,
	    "three_prime_UTR"            => \$three_prime_UTR,
	    "DNAseI_hypersensitive_site" => \$DNAseI_hypersensitive_site,
	    "promoter"                   => \$promoter,
	    "regulatory_region"          => \$regulatory_region,
            "idfile=s"                   => \$id_file,
            "debug=s"                    => \$debug,
            "verbose"                    => \$verbose,
	    "help"                       => \$help,
    	    'store=s'                    => \$store,
	    'test'                       => \$test,
            'noload'                     => \$no_load,
	    'outdir:s'                   => \$outdir,
	    'curout:s'                   => \$curout,
	    'micro'                      => \$micro,
		);

# Help pod if needed
exec ('perldoc',$0) if ($help);

# recreate configuration  
my $wb;
if ($store) { $wb = Storable::retrieve($store) or croak("cant restore wormbase from $store\n") }
else { $wb = Wormbase->new( -debug => $debug, 
			    -test  => $test 
			    ) }

my $log = Log_files->make_build_log($wb);

#######################
# Remapping stuff
#######################

# some database paths
my $currentdb = $wb->database('current');
my $version = $wb->get_wormbase_version;

print "Getting mapping data for WS$version\n";
my $assembly_mapper = Remap_Sequence_Change->new($version - 1, $version, $wb->species, $wb->genome_diffs);

#######################
# ACEDB and databases #
#######################

my $tace   = $wb->tace;
my $dbdir;
if ($database) {
  $dbdir = $database;
}
else {
  $dbdir  = $wb->autoace;
}
unless ($outdir) {$outdir = $wb->acefiles;}
$log->write_to("// writing to ".$outdir."\n\n");
unless ($curout) {$curout = "/nfs/wormpub/DATABASES/camace/${version}_feature_parents.ace";}

# WS version for output files
our ($WS_version) = $wb->get_wormbase_version_name;

# coordinates for Feature_mapper.pm module

my $mapper      = Feature_mapper->new($dbdir,undef, $wb);

# sanity checks for the length of feature types
my %sanity = (
	      'SL1'                      => [0,0],
	      'SL2'                      => [0,0],
	      'polyA_site'               => [0,0],
	      'polyA_signal_sequence'    => [6,6],
	      'transcription_end_site'   => [1,1],
	      'transcription_start_site' => [1,1],
	      'Genome_sequence_error'       => undef,
	      'Genome_sequence_error'       => undef,
              'Corrected_genome_sequence_error' => undef,
	      'binding_site'                => undef,
	      'binding_site_region'         => undef,
	      'TF_binding_site'             => undef,
	      'TF_binding_site_region'      => undef,
	      'histone_binding_site'        => undef,
	      'histone_binding_site_region' => undef,
	      'segmental_duplication'       => undef,
	      'promoter'                    => undef,
	      'regulatory_region'           => undef,
	      'three_prime_UTR'             => undef,
	      'DNAseI_hypersensitive_site'  => undef,
	      'micro_ORF'                   => undef,
	      );

# queue which Feature types you want to map
my @features2map;
push (@features2map, "SL1")                              if (($SL1) || ($all));
push (@features2map, "SL2")                              if (($SL2) || ($all));
push (@features2map, "polyA_signal_sequence")            if (($polyA_signal) || ($all));
push (@features2map, "polyA_site")                       if (($polyA_site) || ($all));
push (@features2map, "binding_site")                     if (($binding_site) || ($all));
push (@features2map, "binding_site_region")              if (($binding_site_reg) || ($all));
push (@features2map, "TF_binding_site")                  if (($TF_binding_site) || ($all));
push (@features2map, "TF_binding_site_region")           if (($TF_binding_site_reg) || ($all));
push (@features2map, "histone_binding_site")             if (($histone_binding_site) || ($all));
push (@features2map, "histone_binding_site_region")      if (($histone_binding_site_reg) || ($all));
push (@features2map, "segmental_duplication")            if (($segmental_duplication) || ($all));
push (@features2map, "Genome_sequence_error")            if (($genome_sequence_error) || ($all));
push (@features2map, "Corrected_genome_sequence_error") if (($genome_sequence_correction) || ($all));
push (@features2map, "transcription_end_site")           if (($transcription_end_site) || ($all));
push (@features2map, "transcription_start_site")         if (($transcription_start_site) || ($all));
push (@features2map, "promoter")                         if (($promoter) || ($all));
push (@features2map, "regulatory_region")                if (($regulatory_region) || ($all));
push (@features2map, "three_prime_UTR")                  if (($three_prime_UTR) || ($all));
push (@features2map, "DNAseI_hypersensitive_site")       if (($DNAseI_hypersensitive_site) || ($all));
push (@features2map, "micro_ORF")                        if (($micro) || ($all));
push (@features2map, "IDFILE") if $id_file;

#############
# main loop #
#############

foreach my $query (@features2map) {
  my $count_features = "0";
  $log->write_to("// Mapping $query features\n\n");
  
  my (@features, @unmapped_feats);

  # open output files
  open (OUTPUT, ">$outdir/feature_${query}.ace") or die "Failed to open output file\n";
  open (PRIMARYOUT, ">$curout") or die "Failed to open update file $curout\n";
  
  if ($query eq 'IDFILE') {
    open (my $idfh, "<$id_file") or $log->log_and_die("Failed to open input file: $id_file\n");
    my $ace_db = Ace->connect( -path => $dbdir ) || do { print "cannot connect to $dbdir}:", Ace->error; die };
    while(<$idfh>) {
      /^(\S+)/ and do {
        my $feat =  $ace_db->fetch(-name => $1, -class => "Feature", -fill  => 1);
        my $fname = $feat->name;
        my $meth = $feat->Method;
        my $target = $feat->Mapping_target->name;
        my $left = $feat->get('Flanking_sequences', 1);
        my $right = $feat->get('Flanking_sequences', 2);
        if (not defined $target or not defined $left or not defined $right) {
          $log->write_to("Feat $feat did not have complete flanks; skipping\n");
          next;
        }
        push @features, [
          $feat,
          $meth,
          $target,
          $left,
          $right,
        ];
      }
    }
  }
  else {
    my $table_file = "/tmp/map_features_table_$query.def";

    my $species_name = $wb->full_name;
    my $table = <<EOF;
Sortcolumn 1

Colonne 1 
Width 12 
Optional 
Visible 
Class 
Class Feature 
From 1 
Condition Method = "$query" AND Species = "$species_name"
 
Colonne 2 
Width 32 
Mandatory 
Visible 
Class 
Class Method 
From 1 
Tag Method 
 
Colonne 3 
Width 12 
Mandatory 
Visible 
Class 
Class Sequence 
From 1 
Tag Mapping_target 
 
Colonne 4 
Width 32 
Optional
Visible 
Text 
From 1 
Tag Flanking_sequences 
 
Colonne 5 
Width 32 
Optional
Visible 
Text 
Right_of 4 
Tag  HERE


// End of these definitions
EOF
    open (TABLE, ">$table_file") || die "Can't open $table_file: $!";
    print TABLE $table;
    close(TABLE);

    open (TACE, "echo 'Table-maker -p $table_file\nquit\n' | $tace $dbdir | ");

    while (<TACE>) {    
      # when it finds a good line
      if (/^\"(\S+)\"\s+\"(\S+)\"\s+\"(\S+)\"\s+\"(\S+)\"\s+\"(\S+)\"\s+/) {
        my ($feat,$meth,$target,$flank_left,$flank_right) = ($1,$2,$3,$4,$5);
        #print "NEXT FEATURE: $feature,$target,$flanking_left,$flanking_right\n" if ($debug);
	
        $count_features ++;
        if ($flank_left eq "" && $flank_right eq "") {
          $log->write_to("// WARNING: Feature $feat has no flanking sequence - not mapped\n");
          next;
        }
	if ($target eq "") {
	  $log->write_to("// WARNING: Feature $feat has no target sequence - not mapped\n");
          next;
	}
        push @features, [$feat,$meth,$target,$flank_left,$flank_right];
      } elsif (/^\"(\S+)\"/) {
        # lines that look like features but there is a problem eg. whitespace in flanks.
        $log->write_to("// ERROR: $1, please check data - parent:\"$3\" flanks:\"$4\" \"$5\"\n");
        $log->error;
      }
    }
  }	

  foreach my $list (@features) {
    my ($feature,$method,$target,$flanking_left,$flanking_right) = @$list;
    # note below that we pass through an expected mapping distance where possible. This
    # can help with the mapping
    print "Feature:@$list[0] Method:@$list[1] Target_seq:@$list[2] Left_flank:@$list[3] Right_flank:@$list[4]\n" if ($debug);
    my @coords = $mapper->map_feature($target,
                                      $flanking_left,
                                      $flanking_right, 
                                      ($sanity{$method}) ? $sanity{$method}->[0] : undef,
                                      ($sanity{$method}) ? $sanity{$method}->[1] : undef,
				     );

    if (!defined $coords[2]) {
      push @unmapped_feats, $list;
      next;
    }
    
    my $new_clone = $coords[0];
    $start = $coords[1];
    $stop  = $coords[2];
    
    # Deal with polyA_signal_sequence features which have the
    # flanking sequences outside of the feature, but
    # Feature_mapper::map_feature expects the flanking sequences to
    # overlap the feature by one base to enable correct mapping of
    # features less than 2bp
    
    # munge returned coordinates to get the span of the mapped feature
    
    if (abs($stop - $start) == 1) {
      # this is  zero-length (i.e. between bases) feature. We cannot represent 
      # these properly in Acedb as 0-length, so we instead represent them as 2bp features
      # (including 1bp if each flank in the feature extent)
      if ($start > $stop) {
        $span = $start - $stop - 1;
      }
      else {
        $span = $stop - $start - 1;
      }
    } else {
      # non-zero-bp feature, therefore need to adjust for fact
      # that reported coords contain 1bp of the flanks
      if ($start < $stop) {
        $start++;
        $stop--;
        $span = $stop - $start + 1;
      }
      else {
        $start--;
        $stop++;
        $span = $start - $stop + 1;
      }
    }
    
    print OUTPUT "//$feature maps to $new_clone $start -> $stop, feature span is $span bp\n" if ($debug);
    print OUTPUT "\nSequence : \"$new_clone\"\n";
    print OUTPUT "Feature_object $feature $start $stop\n\n";
    
    if ($target ne $new_clone) {
      $log->write_to("// Feature $feature maps to different clone than suggested $target -> $new_clone; changing parent\n");
      print OUTPUT "\nFeature : \"$feature\"\n";
      print OUTPUT "Flanking_sequences $flanking_left $flanking_right\n";
      print OUTPUT "Mapping_target  $new_clone\n\n";
      print PRIMARYOUT "\nFeature : \"$feature\"\n";
      print PRIMARYOUT "Flanking_sequences $flanking_left $flanking_right\n";
      print PRIMARYOUT "Mapping_target  $new_clone\n\n";
    }
  }

  if (@unmapped_feats) {
    my %all_ids;
    map { $all_ids{$_->[0]} =  0 } @unmapped_feats;

    foreach my $list (@unmapped_feats) {
      my ($feature,$method,$target,$flanking_left,$flanking_right) = @$list;
      
      $log->write_to(sprintf("// ERROR: Cannot map feature %s on clone %s (%s) flanking sequences: %s %s\n", 
                             $feature,
                             $target,
                             ($sanity{$method}) ? "defined range @{$sanity{$method}}" : "no defined range",
                             $flanking_left, 
                             $flanking_right));
      $log->error;
      
      # if the max leng is defined, and it is 0, we assert that all features of this kind are 0-length.
      # this info is passed through to suggest_fix, which uses it to work out the correct coords in 
      my @suggested_fix = $mapper->suggest_fix($feature, 
                                               ($sanity{$method} and $sanity{$method}->[0] == $sanity{$method}->[1]) ? $sanity{$method}->[0] : undef,
                                               $target, 
                                               $flanking_left, 
                                               $flanking_right, 
                                               $assembly_mapper,
                                               \%all_ids
          );
      if ($suggested_fix[4]) { # FIXED :-)
        $log->write_to("// Suggested fix for $feature : $suggested_fix[3]\n");
        $log->write_to("\nFeature : $feature\n");
        $log->write_to("Flanking_sequences $suggested_fix[0] $suggested_fix[1] $suggested_fix[2]\n");
        $log->write_to("Remark \"Flanking sequence automatically fixed: $suggested_fix[3]\"\n\n");
      } else { # NOT_FIXED :-(
        $log->write_to("// $feature : $suggested_fix[3]\n");
      }
    }
  }
  close(OUTPUT);
    $wb->load_to_database($wb->autoace, "$outdir/feature_${query}.ace", "feature_mapping", $log) unless $no_load;
  $log->write_to("// Processed $count_features $query features\n\n");
}





###############
# hasta luego #
###############

$log->mail();
exit(0);

__END__

=pod

=head2 NAME - map_features.pl

=head1 USAGE

=over 4

=item map_features.pl [-options]

=back

map_features.pl mandatory arguments:

=over 4

=item none

=back

map_features.pl optional arguments:

=over 4

=item -all 

map all of the following feature types:

=item -SL1

map SL1 trans-splice leader acceptor sites (2 bp feature)

=item -SL2

map SL2 trans-splice leader acceptor sites (2 bp feature)

=item -polyA_site

map polyA attachement sites (2 bp feature)

=item -polyA_signal

map polyA signal sequence sites (6 bp feature)

=item -debug <user> 

Queries current_DB rather than autoace

=item -build

Assumes you are building, so therefore loads data into autoace and writes acefiles to
autoace/acefiles
=item -store <storefile>

specifies an storable file with saved options

"<feature_name>" "<Method>" "<S_parent>" "<clone>" "<flanking_sequence_left>" "<flanking_sequence_right>" 

=item -help      

This help page

=cut
