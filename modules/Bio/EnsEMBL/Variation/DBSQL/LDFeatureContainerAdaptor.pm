#
# Ensembl module for Bio::EnsEMBL::Variation::DBSQL::LDFeatureContainerAdaptor
#
# Copyright (c) 2004 Ensembl
#
# You may distribute this module under the same terms as perl itself
#
#

=head1 NAME

Bio::EnsEMBL::Variation::DBSQL::LDFeatureContainerAdaptor

=head1 SYNOPSIS

  $vdb = Bio::EnsEMBL::Variation::DBSQL::DBAdaptor->new(...);
  $db  = Bio::EnsEMBL::DBSQL::DBAdaptor->new(...);

  $sa  = $db->get_SliceAdaptor();
  $lda = $vdb->get_LDFeatureContainerAdaptor();
  $vfa =  $vdb->get_VariationFeatureAdaptor();

  # Get a LDFeatureContainer in a region
  $slice = $sa->fetch_by_region('chromosome', 'X', 1e6, 2e6);

  $ldContainer = $lda->fetch_by_Slice($slice);

  print "Name of the ldContainer is: ", $ldContainer->name();

  # fetch ld featureContainer for a particular variation feature

  $vf = $vfa->fetch_by_dbID(145);

  $ldContainer = $lda->fetch_by_VariationFeature($vf);

  print "Name of the ldContainer: ", $ldContainer->name();


=head1 DESCRIPTION

This adaptor provides database connectivity for LDFeature objects.
LD Features may be retrieved from the Ensembl variation database by
several means using this module.

=head1 AUTHOR - Daniel Rios

=head1 CONTACT

Post questions to the Ensembl development list ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Variation::DBSQL::LDFeatureContainerAdaptor;

use Bio::EnsEMBL::DBSQL::BaseFeatureAdaptor;
use Bio::EnsEMBL::Variation::LDFeatureContainer;
use vars qw(@ISA);
use Data::Dumper;

use POSIX;
use FileHandle;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);

use constant MAX_SNP_DISTANCE => 100_000;

@ISA = ('Bio::EnsEMBL::DBSQL::BaseAdaptor');

=head2 fetch_by_Slice

  Arg [1]    : Bio::EnsEMBL::Slice $slice
               The slice to fetch genes on. Assuming it is always correct (in the top level)
  Arg [2]    : (optional) Bio::EnsEMBL::Variation::Population $population. Population where 
                we want to select the LD information
  Example    : $ldFeatureContainer = $ldfeaturecontainer_adaptor->fetch_by_Slice($slice);
  Description: Overwrites superclass method to add the name of the slice to the LDFeatureContainer.
  Returntype : Bio::EnsEMBL::Variation::LDFeatureContainer
  Exceptions : thrown on bad argument
  Caller     : general

=cut

sub fetch_by_Slice{
    my $self = shift;
    my $slice = shift;
    my $population = shift;

    if(!ref($slice) || !$slice->isa('Bio::EnsEMBL::Slice')) {
	throw('Bio::EnsEMBL::Slice arg expected');
    }
    my $sth;
    my $in_str;
    my $siblings = {};
    #when there is no population selected, return LD in the HapMap and PerlEgen populations
    $in_str = $self->_get_LD_populations($siblings);
    #if a population is passed as an argument, select the LD in the region with the population
    if ($population){
	if(!ref($population) || !$population->isa('Bio::EnsEMBL::Variation::Population')) {
	    throw('Bio::EnsEMBL::Variation::Population arg expected');
	}
	my $population_id = $population->dbID;
	$in_str = " = $population_id";
#	if ($in_str =~ /$population_id/){
#	    $in_str = "IN ($population_id)";
#'	}
#	else{
#	    warning("Not possible to calculate LD for a non HapMap or PerlEgen population: $population_id");
#	    return {};
#	}
    }

    if ($in_str eq ''){
	#there is no population, not a human specie or not passed as an argument, return the empy container
	my $t = Bio::EnsEMBL::Variation::LDFeatureContainer->new(
								 '-ldContainer'=> {},
								 '-name' => $slice->name,
								 '-variationFeatures' => {}
								 );
	return $t
    }

    $sth = $self->prepare(qq{SELECT c.sample_id,c.seq_region_id,c.seq_region_start,c.seq_region_end,c.genotypes,ip.population_sample_id
				 FROM compressed_genotype_single_bp c, individual_population ip
				 WHERE  ip.individual_sample_id = c.sample_id
				 AND   ip.population_sample_id $in_str
				 AND   c.seq_region_id = ?
				 AND   c.seq_region_start >= ? and c.seq_region_start <= ?
				 AND   c.seq_region_end >= ?
				 ORDER BY c.seq_region_id, c.seq_region_start},{mysql_use_result => 1});

    $sth->bind_param(1,$slice->get_seq_region_id,SQL_INTEGER);
    $sth->bind_param(2,$slice->start - MAX_SNP_DISTANCE,SQL_INTEGER);
    $sth->bind_param(3,$slice->end,SQL_INTEGER);
    $sth->bind_param(4,$slice->start,SQL_INTEGER);

    $sth->execute();
    
    my $ldFeatureContainer = $self->_objs_from_sth($sth,$slice,$siblings);

    $sth->finish();
    #and store the name of the slice in the Container
    $ldFeatureContainer->name($slice->name());
    return $ldFeatureContainer;
}

=head2 fetch_by_VariationFeature

  Arg [1]    : Bio::EnsEMBL:Variation::VariationFeature $vf
  Arg [2]    : (optional) int $population_id. Population where we want to select the LD information
  Example    : my $ldFeatureContainer = $ldFetureContainerAdaptor->fetch_by_VariationFeature($vf);  Description: Retrieves LDFeatureContainer for a given variation feature.  Most
               variations should only hit the genome once and only a return
               a single variation feature.
  Returntype : reference to Bio::EnsEMBL::Variation::LDFeatureContainer
  Exceptions : throw on bad argument
  Caller     : general

=cut

sub fetch_by_VariationFeature {
  my $self = shift;
  my $vf  = shift;
  my $pop = shift;

  if(!ref($vf) || !$vf->isa('Bio::EnsEMBL::Variation::VariationFeature')) {
    throw('Bio::EnsEMBL::Variation::VariationFeature arg expected');
  }

  if(!defined($vf->dbID())) {
    throw("VariationFeature arg must have defined dbID");
  }
  my $ldFeatureContainer = $self->fetch_by_Slice($vf->feature_Slice->expand(MAX_SNP_DISTANCE,MAX_SNP_DISTANCE),$pop);
  #we need to filter and only return LD with the vf associated
  my %feature_container = ();
  my %vf_objects = ();
  my %pop_ids = ();

  #iterate all the LD container looking for values related to this variation Feature
  foreach my $ld_key (keys %{$ldFeatureContainer->{'ldContainer'}}){
      my $vf_id = $vf->dbID;
      if ($ld_key =~ /$vf_id/o){
	  #add the value to the new hash
	  my ($vf_id1,$vf_id2) = split /-/,$ld_key;

	  $feature_container{$vf_id1 . '-' . $vf_id2} = $ldFeatureContainer->{'ldContainer'}->{$ld_key};
	  $vf_objects{$vf_id1} = $ldFeatureContainer->{'variationFeatures'}->{$vf_id1};
	  $vf_objects{$vf_id2} = $ldFeatureContainer->{'variationFeatures'}->{$vf_id2};

	  map {$pop_ids{$_}++} keys %{$ldFeatureContainer->{'ldContainer'}->{$ld_key}};	  
      }
  }

  my $new_ldFeatureContainer =  Bio::EnsEMBL::Variation::LDFeatureContainer->new(
 							   '-ldContainer'=> \%feature_container,
							   '-name' => $vf->dbID,
							   '-variationFeatures' => \%vf_objects
										 );
  $new_ldFeatureContainer->{'_pop_ids'} = \%pop_ids;
  return $new_ldFeatureContainer;
  
 
}

#
# private method, creates ldfeatureContainer objects from an executed statement handle
# ordering of columns must be consistant
#
sub _objs_from_sth {
  my $self = shift;
  return $self->_objs_from_sth_temp_file( @_ );
  my $sth  = shift;
  my $slice = shift;
  my $siblings = shift;

  my ($sample_id,$ld_region_id,$ld_region_start,$ld_region_end,$d_prime,$r2,$sample_count);
  my ($vf_id1,$vf_id2);

  my %feature_container = ();
  my %vf_objects = ();

  #get all Variation Features in Slice
  my $vfa = $self->db->get_VariationFeatureAdaptor();
  my $variations = $vfa->fetch_all_by_Slice($slice); #retrieve all variation features
  #create a hash that maps the position->vf_id
  my %pos_vf = ();
  my $region_Slice = $slice->seq_region_Slice();
  map {$pos_vf{$_->seq_region_start} = $_->transfer($region_Slice)} @{$variations};

  my %alleles_variation = (); #will contain a record of the alleles in the variation. A will be the major, and a the minor. When more than 2 alleles
  #, the genotypes for that variation will be discarded
  my %individual_information = (); #to store the relation of snps->individuals
  my %regions; #will contain all the regions in the population and the number of genotypes in each one
  my $previous_seq_region_id = 0;

  my %_pop_ids;

  my ($individual_id, $seq_region_id, $seq_region_start,$seq_region_end,$genotypes, $population_id);
  my @cmd = qw(calc_genotypes);
  my @path = split /:/,$ENV{PATH};
  my $found_file = grep {-e $_ . '/' . $cmd[0]} @path;
  #open the pipe between processes if the binary file exists in the PATH
  if (! $found_file){
      warning("Binary file calc_genotypes not found. Please, read the ensembl-variation/C_code/README.txt file if you want to use LD calculation\n");
      goto OUT;
  }
  my $pid;
  eval "require IPC::Run"; #check wether the IPC::Run module it is installed
  if ($@){
      warning("IPC::Run it is not installed in you system. Please, read ensembl-variation/C_code/README.txt if you want to use the LD calculation");
      goto OUT;
  }
  else{
      use IPC::Run qw(start finish);
      $pid = start \@cmd,
      '<pipe', \*IN,
      '>pipe', \*OUT,
      '2>pipe', \*ERR 
	  || die "returned $?" ;
  }
    
  #set autoflush
  my $piid = fork;
  if (!defined $piid){
      throw("Not possible to fork: $!\n");
  }
  elsif ($piid !=0){
      close IN || die "Could not close writer filehandle: $!\n";
      #you are the father, read from the pipe
      while(<OUT>){
	  my %ld_values = ();
#     936	965891	164284	166818	0.628094	0.999996	120 
	  #get the ouput into the hashes
	  chomp;
	  ($sample_id,$ld_region_id,$ld_region_start,$ld_region_end,$r2,$d_prime,$sample_count) = split /\s/;
	  $ld_values{'d_prime'} = $d_prime;
	  $ld_values{'r2'} = $r2;
	  $ld_values{'sample_count'} = $sample_count;
	  $vf_id1 = $pos_vf{$ld_region_start}->dbID();
	  $vf_id2 = $pos_vf{$ld_region_end}->dbID();

	  $feature_container{$vf_id1 . '-' . $vf_id2}->{$sample_id} = \%ld_values;
	  $vf_objects{$vf_id1} = $pos_vf{$ld_region_start};
	  $vf_objects{$vf_id2} = $pos_vf{$ld_region_end};

	  $_pop_ids{$sample_id} = 1;	  
      }
      waitpid($piid,0);
      close OUT || die "Could not close filehandle: $!\n";
      finish $pid || die "Could not finish fork..: $!\n";
  }
  else{
      close OUT || die "Could not close filehandle: $!\n";
      #the parent dumps the data from the database and writes in the pipe

      $sth->bind_columns(\$individual_id, \$seq_region_id, \$seq_region_start, \$seq_region_end, \$genotypes, \$population_id); 
  
      while($sth->fetch()) {
	  #only print genotypes without parents genotyped
	  if (!exists $siblings->{$population_id . '-' . $individual_id}){ #necessary to use the population_id
	      $self->_store_genotype(\%individual_information,\%alleles_variation, $individual_id, $seq_region_start, $genotypes, $population_id, $slice);
	      $previous_seq_region_id = $seq_region_id;
	  }      
      }

      $sth->finish();
      select(IN); #necessary to flush the pipe
      $| = 1;
      #we have to print the variations
      foreach my $snp_start (sort{$a<=>$b} keys %alleles_variation){
	  foreach my $population (keys %{$alleles_variation{$snp_start}}){
	      #if the variation has 2 alleles, print all the genotypes to the file
	      if (keys %{$alleles_variation{$snp_start}{$population}} == 2){		
		  $self->_convert_genotype($alleles_variation{$snp_start}{$population},$individual_information{$population}{$snp_start});		  
		  foreach my $individual_id (keys %{$individual_information{$population}{$snp_start}}){
		      print IN join("\t",$previous_seq_region_id,$snp_start, $snp_start,
				      $population, $individual_id,  
				      $individual_information{$population}{$snp_start}{$individual_id}{genotype})."\n" || warn $!;
		  
		  }
	      }
	  }	
      }
      close IN || die "Could not close filehandle: $! and $?\n";
    POSIX:_exit(0);
  }

OUT:
  my $t = Bio::EnsEMBL::Variation::LDFeatureContainer->new(
 							   '-ldContainer'=> \%feature_container,
							   '-name' => '',
							   '-variationFeatures' => \%vf_objects
							   );

  $t->{'_pop_ids'} =\%_pop_ids;

  return $t;      
}

#for a given population, gets all individuals that are children (have father or mother)
sub _get_siblings{
    my $self = shift;
    my $population_id = shift;
    my $siblings = shift;

    my $sth_individual = $self->db->dbc->prepare(qq{SELECT i.sample_id
							     FROM individual i, individual_population ip
							     WHERE ip.individual_sample_id = i.sample_id
							     AND ip.population_sample_id = ? 
							     AND i.father_individual_sample_id IS NOT NULL
							     AND i.mother_individual_sample_id IS NOT NULL
							 });
    my ($individual_id);
    $sth_individual->execute($population_id);
    $sth_individual->bind_columns(\$individual_id);
    while ($sth_individual->fetch){
	$siblings->{$population_id.'-'.$individual_id}++; #necessary to have in the key the population, since some individuals are shared between
	                                                   #populations
    }
}

#reads one line from the compress_genotypes table, uncompress the data, and writes it to the different hashes: one containing the number of bases for the variation and the other with the actual genotype information we need to print in the file
sub _store_genotype{
    my $self = shift;
    my $individual_information = shift;
    my $alleles_variation = shift;
    my $individual_id = shift;
    my $seq_region_start = shift;
    my $genotype = shift;
    my $population_id = shift;
    my $slice = shift;

    #get the first byte of the string, and unpack it (the genotype, without the gaps)
    my $blob = substr($genotype,2);
    #the array contains the uncompressed value of genotype, always in the format number_gaps . genotype		  
    my @genotypes = unpack("naa" x (length($blob)/4),$blob);
    unshift @genotypes, substr($genotype,1,1); #add the second allele of the first genotype
    unshift @genotypes, substr($genotype,0,1); #add the first allele of the first genotype
    unshift @genotypes, 0; #the first SNP is in the position indicated by the seq_region1
    my $snp_start;
    my $allele_1;
    my $allele_2;
    for (my $i=0; $i < @genotypes -1;$i+=3){
	#number of gaps
	if ($i == 0){
	    $snp_start = $seq_region_start; #first SNP is in the beginning of the region
	}
	else{
	    $snp_start += $genotypes[$i] +1;
	}
	#genotype
	$allele_1 = $genotypes[$i+1];
	$allele_2 = $genotypes[$i+2];
	#only get genotypes in the range
	if (($snp_start >= $slice->start) && ($snp_start <= $slice->end)){
	    #store in structure
	    if ($allele_1 ne 'N' and $allele_2 ne 'N'){
		$alleles_variation->{$snp_start}->{$population_id}->{$allele_1}++;
		$alleles_variation->{$snp_start}->{$population_id}->{$allele_2}++;
		
		$individual_information->{$population_id}->{$snp_start}->{$individual_id}->{allele_1} = $allele_1;
		$individual_information->{$population_id}->{$snp_start}->{$individual_id}->{allele_2} = $allele_2;
	    }
	}
    }
}

#
# Converts the genotype into the required format for the calculation of the pairwise_ld value: AA, Aa or aa
# From the Allele table, will select the alleles and compare to the alleles in the genotype
#

sub _convert_genotype{
    my $self = shift;
    my $alleles_variation = shift; #reference to the hash containing the alleles for the variation present in the genotypes
    my $individual_information = shift; #reference to a hash containing the values to be written to the file
    my @alleles_ordered; #the array will contain the alleles ordered by apparitions in the genotypes (only 2 values possible)
    
    @alleles_ordered = sort({$alleles_variation->{$b} <=> $alleles_variation->{$a}} keys %{$alleles_variation});
    
    #let's convert the allele_1 allele_2 to a genotype in the AA, Aa or aa format, where A corresponds to the major allele and a to the minor
    foreach my $individual_id (keys %{$individual_information}){
	#if both alleles are different, this is the Aa genotype
	if ($individual_information->{$individual_id}{allele_1} ne $individual_information->{$individual_id}{allele_2}){
	    $individual_information->{$individual_id}{genotype} = 'Aa';
	}
	#when they are the same, must find out which is the major
	else{	    
	    if ($alleles_ordered[0] eq $individual_information->{$individual_id}{allele_1}){
		#it is the major allele
		$individual_information->{$individual_id}{genotype} = 'AA';
	    }
	    else{
		$individual_information->{$individual_id}{genotype} = 'aa';
	    }
	    
	}
    }
}

sub _get_LD_populations{
    my $self = shift;
    my $siblings = shift;
    my ($pop_id,$population_name);
    my $sth = $self->db->dbc->prepare(qq{SELECT s.sample_id, s.name
				     FROM population p, sample s
				     WHERE (s.name like 'PERLEGEN:AFD%'
				     OR s.name like 'CSHL-HAPMAP%')
				     AND s.sample_id = p.sample_id});

    $sth->execute();
    $sth->bind_columns(\$pop_id,\$population_name);
    #get all the children that we do not want in the genotypes
    my @pops;
    while($sth->fetch){
	if($population_name =~ /CEU|YRI/){
	    $self->_get_siblings($pop_id,$siblings);
	}
	push @pops, $pop_id;
    }
    
    my $in_str = " IN (" . join(',', @pops). ")";
    
    return $in_str if (defined $pops[0]);
    return '' if (!defined $pops[0]);

}

sub _objs_from_sth_temp_file {
  my $self = shift;
  my $sth  = shift;
  my $slice = shift;
  my $siblings = shift;

  my ($sample_id,$ld_region_id,$ld_region_start,$ld_region_end,$d_prime,$r2,$sample_count);
  my ($vf_id1,$vf_id2);

  my %feature_container = ();
  my %vf_objects = ();

  #get all Variation Features in Slice
  my $vfa = $self->db->get_VariationFeatureAdaptor();
  my $variations = $vfa->fetch_all_by_Slice($slice); #retrieve all variation features
  #create a hash that maps the position->vf_id
  my %pos_vf = ();
  my $region_Slice = $slice->seq_region_Slice();
  map {$pos_vf{$_->seq_region_start} = $_->transfer($region_Slice)} @{$variations};

  my %alleles_variation = (); #will contain a record of the alleles in the variation. A will be the major, and a the minor. When more than 2 alleles
  #, the genotypes for that variation will be discarded
  my %individual_information = (); #to store the relation of snps->individuals
  my %regions; #will contain all the regions in the population and the number of genotypes in each one
  my $previous_seq_region_id = 0;

  my %_pop_ids;

  my ($individual_id, $seq_region_id, $seq_region_start,$seq_region_end,$genotypes, $population_id);
  my @cmd = qw(calc_genotypes);
  my @path = split /:/,$ENV{PATH};
  my $found_file = grep {-e $_ . '/' . $cmd[0]} @path;
  #open the pipe between processes if the binary file exists in the PATH
  if (! $found_file){
      warning("Binary file calc_genotypes not found. Please, read the ensembl-variation/C_code/README.txt file if you want to use LD calculation\n");
      goto OUT;
  }
  my $pid;
#  my $IN = "/tmp/ld-$ENV{SERVER_ADDR}-$$.in";
  my $IN = "/tmp/ld-$$.in";
#  my $OUT = "/tmp/ld-$ENV{SERVER_ADDR}-$$.out";
  my $OUT = "/tmp/ld-$$.out";
  warn ">>> $IN $OUT <<<";
  open IN, ">$IN";
  $sth->bind_columns(\$individual_id, \$seq_region_id, \$seq_region_start, \$seq_region_end, \$genotypes, \$population_id);
  while($sth->fetch()) {
    #only print genotypes without parents genotyped
    if (!exists $siblings->{$population_id . '-' . $individual_id}){ #necessary to use the population_id
      $self->_store_genotype(\%individual_information,\%alleles_variation, $individual_id, $seq_region_start, $genotypes, $population_id, $slice);
      $previous_seq_region_id = $seq_region_id;
    }
  }
  $sth->finish();
      #we have to print the variations
      foreach my $snp_start (sort{$a<=>$b} keys %alleles_variation){
          foreach my $population (keys %{$alleles_variation{$snp_start}}){
              #if the variation has 2 alleles, print all the genotypes to the file
              if (keys %{$alleles_variation{$snp_start}{$population}} == 2){
                  $self->_convert_genotype($alleles_variation{$snp_start}{$population},$individual_information{$population}{$snp_start});
                  foreach my $individual_id (keys %{$individual_information{$population}{$snp_start}}){
                      print IN join("\t",$previous_seq_region_id,$snp_start, $snp_start,
                                      $population, $individual_id,
                                      $individual_information{$population}{$snp_start}{$individual_id}{genotype})."\n" || warn $!;

                  }
              }
          }
      }
  close IN;
  `calc_genotypes <$IN >$OUT`;
  open OUT, $OUT;
  while(<OUT>){
  my %ld_values = ();
#     936	965891	164284	166818	0.628094	0.999996	120 
	  #get the ouput into the hashes
	  chomp;
	  ($sample_id,$ld_region_id,$ld_region_start,$ld_region_end,$r2,$d_prime,$sample_count) = split /\s/;
	  $ld_values{'d_prime'} = $d_prime;
	  $ld_values{'r2'} = $r2;
	  $ld_values{'sample_count'} = $sample_count;
          if (!defined $pos_vf{$ld_region_start} || !defined $pos_vf{$ld_region_end}){
	       next; #problem to fix in the compressed genotype table: some of the positions seem to be wrong
	   }
	  $vf_id1 = $pos_vf{$ld_region_start}->dbID();
	  $vf_id2 = $pos_vf{$ld_region_end}->dbID();

	  $feature_container{$vf_id1 . '-' . $vf_id2}->{$sample_id} = \%ld_values;
	  $vf_objects{$vf_id1} = $pos_vf{$ld_region_start};
	  $vf_objects{$vf_id2} = $pos_vf{$ld_region_end};

	  $_pop_ids{$sample_id} = 1;	  
      }
      close OUT || die "Could not close filehandle: $!\n";
  unlink( $IN );
  unlink( $OUT );
OUT:
  my $t = Bio::EnsEMBL::Variation::LDFeatureContainer->new(
 							   '-ldContainer'=> \%feature_container,
							   '-name' => '',
							   '-variationFeatures' => \%vf_objects
							   );

  $t->{'_pop_ids'} =\%_pop_ids;

  return $t;      
}

1;
