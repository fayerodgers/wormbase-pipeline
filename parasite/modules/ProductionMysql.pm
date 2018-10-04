use strict;
use Carp;
package ProductionMysql;
use Bio::EnsEMBL::Registry;
# Ensembl has a nice production environment.
# The databases we need are all in PATH so we can alias them.
# To get parameters in command line you can e.g. `$PARASITE_STAGING_MYSQL details host`
# Sometimes we need to prepare configs and stuff, and we want the same from Perl.
# This module interfaces the production env to Perl. The format is right for passing into Ensembl's pipelines as config, hopefully :)
# Usage: 
#  ProductionMysql->staging->url
#  ProductionMysql->new("mysql-ps-prod")->conn->{host}
#  ProductionMysql->new("mysql-pan-1")->conn("ncbi_taxonomy")
sub new { 
 my ($class, $db_cmd) = @_;
 return bless {db_cmd => $db_cmd}, $class;
}
sub staging {
  my $v = $ENV{PARASITE_STAGING_MYSQL} or die "PARASITE_STAGING_MYSQL not in env. You need to module load parasite_prod_relx";
  return new(shift, $v);
}
sub previous_staging {
  my $v = $ENV{PREVIOUS_PARASITE_STAGING_MYSQL} or die "PREVIOUS_PARASITE_STAGING_MYSQL not in env. You need to module load parasite_prod_relx";
  return new(shift, $v);
}
sub staging_writable {
  my $v = $ENV{PARASITE_STAGING_MYSQL} or die "PARASITE_STAGING_MYSQL not in env. You need to module load parasite_prod_relx";
  return new(shift,"$v-ensrw"); 
}
sub core_databases {
  my $db_cmd= shift -> {db_cmd};
  my @patterns = @_;
  my @all_core_dbs;
  open(my $fh, " { $db_cmd  -Ne 'show databases like \"%core%\" ' 2>&1 1>&3 | grep -v \"can be insecure\" 1>&2; } 3>&1 |") or Carp::croak "ProductionMysql: $db_cmd not in your PATH\n";
  while(<$fh>) {
   chomp;
   push @all_core_dbs, $_ if $_;
  }
  return @all_core_dbs unless @patterns;

  my @result;
  for my $core_db (@all_core_dbs){
    my $include;
    for my $pat (@patterns){
      chomp $pat;
      $include = 1 if $core_db =~ /$pat/;
    }
    push @result, $core_db if $include;
  }
  return @result;
}
sub core_db {
  my ($core_db, @others) = shift->core_databases(@_);
  Carp::croak "ProductionMysql: no db for: @_" unless $core_db;
  Carp::croak "ProductionMysql: multiple dbs for: @_" if @others;
  return $core_db;
}
sub species {
  my ($spe, $cies, $bp ) = split "_", &core_db(@_);
  return join "_", $spe, $cies, $bp;
}
sub all_species {
   my @result;
   for (&core_databases(@_)){
     s/_core.*//;
     push @result, $_;
   }
   return @result;
}
sub meta_value {
  my $db_cmd= shift -> {db_cmd};
  my $db_name = shift;
  my $pattern = shift;
  my @result;
  open(my $fh, "$db_cmd $db_name -Ne 'select meta_value from  meta where meta_key like \"$pattern\" ' |") or Carp::croak "ProductionMysql: $db_cmd not in your PATH\n";
  while(<$fh>) {
   chomp;
   push @result, $_ if $_;
  }
  return @result if wantarray;
  return $result[0] if @result;
  return undef;
}

sub conn {
  my $db_cmd= shift -> {db_cmd};
  my $db_name = shift;
  open(my $fh, "$db_cmd details script |") or Carp::croak "ProductionMysql: $db_cmd not in your PATH\n";
  my %conn;
  while(<$fh>) {
    /host\s+(\S+)/ and $conn{host}     = $1;
    /port\s+(\d+)/ and $conn{port}     = $1;
    /user\s+(\S+)/ and $conn{user}     = $1;
    /pass\s+(\S+)/ and $conn{password} = $1;
  }
  $conn{dbname}=$db_name if $db_name;
  return \%conn;
}
sub url {
  my $db_cmd= shift -> {db_cmd};

  my $url;

  open(my $fh, "$db_cmd details url |") or Carp::croak "ProductionMysql: $db_cmd not in your PATH\n";
  while(<$fh>) {
    /^(mysql:\S+)/ and $url = $1;
  }

  $url =~ s/\/$//;

  return $url;
}

sub dbc {
   my ($self, $pattern ) = @_;
   my $registry = 'Bio::EnsEMBL::Registry';
   $registry->load_registry_from_url( $self->url );
   return $registry->get_DBAdaptor($self->species($pattern), 'core')->dbc;
}
1;
