#!/usr/bin/env perl
#
# a script to batch request variation ids based on lists of public_names
# Last change by $Author: mh6 $ on $Date: 2015-03-31 10:16:20 $
# usage: perl get_variation_ids.pl -species elegans -user me -pass me < file containing varId_pubId_per_line


use lib $ENV{CVS_DIR};
use lib "$ENV{CVS_DIR}/NAMEDB/lib";

use NameDB_handler;
use Wormbase;
use Storable;
use Getopt::Long;
use IO::File;
use strict;


my ($PASS,$USER, $DB); # mysql ones
my $DOMAIN  = 'Variation'; # hardcoded to variation

my ($wormbase, $debug, $test, $store, $species,$infile,$outfile,$nocheck, 
    $ace_file_template, $input_is_public_names, $input_is_other_names, $input, $output,$public);

GetOptions (
    "debug=s"   => \$debug,   # send log emails only to one user
    "test"      => \$test,    # run against the test database on utlt-db
    "store:s"   => \$store,   # if you want to pass a Storable instead of recreating it
    "species:s" => \$species, # elegans/briggsae/whateva .. needed for logging
    "user:s"	=> \$USER,    # mysql username
    "pass:s"	=> \$PASS,    # mysql password
    'nocheck'   => \$nocheck, # don't check public_names
    'input:s'     => \$input,   # File containing new public_names for new Variations
    "output:s"    => \$output,  # File to capture the new WBVar and name associations
    'acetemplate=s' => \$ace_file_template, #unknown template file that is also printed along with the IDs retrieved by the script
    'public'    => \$public   # The file only contains public_names so these should be used.
    )||die(@!);
    
die "Species option is mandatory\n" unless $species; # need that for NameDB to fetch the correct regexps

if ( $store ) {
  $wormbase = retrieve( $store ) or croak("Can't restore wormbase from $store\n");
} else {
  $wormbase = Wormbase->new( -debug    => $debug,
                             -test     => $test,
                             -organism => $species
      );
}

# establish log file.
my $log = Log_files->make_build_log($wormbase);

$DB = $wormbase->test ? 'test_wbgene_id;utlt-db:3307' : 'nameserver_live;web-wwwdb-core-02:3449';

my $db = NameDB_handler->new($DB,$USER,$PASS,$wormbase->wormpub . '/DATABASES/NameDB');
$db->setDomain($DOMAIN);

# there should be *only* one public_name per line in the input_file
# like:
# abc123
# abc234

if (defined $ace_file_template) {
  my $tmp_str = "";

  open(my $atfh, $ace_file_template) 
      or $log->log_and_die("Could not open $ace_file_template for reading\n");
  while(<$atfh>) {
    /\S/ and $tmp_str .= $_;
  }
  
  $ace_file_template = $tmp_str;
}

my @entries;
open (OUT, ">$output") or $log->log_and_die("Could not open $output for reading\n");
open (IN, "<$input") or $log->log_and_die("Could not open $input for reading\n");
while (<IN>) {
  chomp;

  my @names = split(/\s+/, $_);
  if (scalar(@names) == 2 or scalar(@names) == 1) {
    push @entries, \@names,
  } else {
    $log->log_and_die("Bad line:$_\n");
  }
}

foreach my $entry (@entries) {
    my ($public_name, $other_name);
    if ($public) {
	($public_name, $other_name) = @$entry;
    }
    else {
	($other_name, $public_name) = @$entry;
    }
    if (not $nocheck and defined $public_name and not defined &_check_name($public_name)) {
	next;
    }

  my $id = $db->idCreate;
  
  $public_name = $id if not defined $public_name;

  $db->addName($id,'Public_name'=>$public_name);

  print OUT "\nVariation : \"$id\"\n";
  print OUT "Public_name $public_name\n";
  print OUT "Other_name $other_name\n" if (defined $other_name);
  if (defined $ace_file_template) {
      print OUT "$ace_file_template\n";
  }
}

$log->mail;

# small function to check the variation public_name for sanity
sub _check_name {
  my $name = shift;
  my $var = $db->idGetByTypedName('Public_name'=>$name)->[0];
  if($var) {  
    print STDERR "ERROR: $name already exists as $var\n";
    return undef;
  }
  return 1;
}

__END__

=pod

=head1 NAME - get_variation_ids.pl

=head1 DECRIPTION

This script takes a list of submitter-supplied variation names  and generates new WBVar identifiers in the name server, 
writing the results to the given output file. 

The input file is expected to contain a list of submitter-supplied variation names, one per line. Optionally, each 
line may also contain an additional name, which is added to the NameDB as the public name. If no second name is 
defined, the generated WBVar identifier will be used as the public name

By default, the script will refuse to create new WBVar identifiers for public names that already exist in the
database; this behaviour can be switched off with the -nocheck option. 

-head1 OUTPUT

The default output is a 3-column table of 

WBVarid<tab>Public name<tab>Submitter-supplied name

However, if the -acetemplate  option is used, Ace format can be generated (see -acetemplate below). With Ace format, 
the submitter-supplied name is used to populate the Other_name tag. 


=head1 USAGE EXAMPLES

get_variation_ids.pl -species briggsae input_id_-user me -pass me input file.txt -output output_id_file.txt

get_variation_ids.pl -species elegans -user me -pass me -acetemplate wild_template.ace -input input_id_file.txt -output output_file.ace

=head1 OPTIONS

-species      WormBase species name, required for logging (defaults to elegans)

-user         MySQL NameDB account user name

-pass         MySQL NameDB account password

-acetemplate  Takes the file name of a file containing Ace template format which will be printed to the end of the results to create a fuller entry.
 
-nocheck      Do not check for public name clashes

-input        Takes the file name that you have generated as input

-output       Takes the name of a file that the results from the nameserver are written to. 

=cut

