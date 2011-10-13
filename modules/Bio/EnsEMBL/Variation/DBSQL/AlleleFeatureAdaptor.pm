=head1 LICENSE

 Copyright (c) 1999-2011 The European Bioinformatics Institute and
 Genome Research Limited.  All rights reserved.

 This software is distributed under a modified Apache license.
 For license details, please see

   http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <dev@ensembl.org>.

 Questions may also be sent to the Ensembl help desk at
 <helpdesk@ensembl.org>.

=cut

#
# Ensembl module for Bio::EnsEMBL::Variation::DBSQL::AlleleFeatureAdaptor
#
# Copyright (c) 2004 Ensembl
#
# You may distribute this module under the same terms as perl itself
#
#

=head1 NAME

Bio::EnsEMBL::Variation::DBSQL::AlleleFeatureAdaptor

=head1 SYNOPSIS
  $reg = 'Bio::EnsEMBL::Registry';
  
  $reg->load_registry_from_db(-host => 'ensembldb.ensembl.org',-user => 'anonymous');
  
  $afa = $reg->get_adaptor("human","variation","allelefeature");
  $sa = $reg->get_adaptor("human","core","slice");

  # Get a VariationFeature by its internal identifier
  $af = $afa->fetch_by_dbID(145);

  # get all AlleleFeatures in a region
  $slice = $sa->fetch_by_region('chromosome', 'X', 1e6, 2e6);
  foreach $af (@{$afa->fetch_all_by_Slice($slice)}) {
    print $af->start(), '-', $af->end(), ' ', $af->allele(), "\n";
  }


=head1 DESCRIPTION

This adaptor provides database connectivity for AlleleFeature objects.
Genomic locations of alleles in samples can be obtained from the 
database using this adaptor.  See the base class BaseFeatureAdaptor for more information.

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Variation::DBSQL::AlleleFeatureAdaptor;

use Bio::EnsEMBL::Variation::AlleleFeature;
use Bio::EnsEMBL::DBSQL::BaseFeatureAdaptor;
use Bio::EnsEMBL::Variation::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(throw);
use Bio::EnsEMBL::Utils::Sequence qw(expand);
use Bio::EnsEMBL::Variation::Utils::Constants qw(%OVERLAP_CONSEQUENCES);

our @ISA = ('Bio::EnsEMBL::Variation::DBSQL::BaseAdaptor', 'Bio::EnsEMBL::DBSQL::BaseFeatureAdaptor');


=head2 fetch_all_by_Slice

   Arg[0]      : Bio::EnsEMBL::Slice $slice
   Arg[1]      : (optional) Bio::EnsEMBL::Variation::Individual $individual
   Example     : my $vf = $vfa->fetch_all_by_Slice($slice,$individual);   
   Description : Gets all the VariationFeatures in a certain Slice for a given
                 Individual (optional). Individual must be a designated strain.
   ReturnType  : listref of Bio::EnsEMBL::Variation::AlleleFeature
   Exceptions  : thrown on bad arguments
   Caller      : general
   Status      : At Risk
   
=cut

sub fetch_all_by_Slice{
    my $self = shift;
    my $slice = shift; 
    my $individual = shift;

    if(!ref($slice) || !$slice->isa('Bio::EnsEMBL::Slice')) {
	throw('Bio::EnsEMBL::Slice arg expected');
    }
    
    if (defined $individual){
		if(!ref($individual) || !$individual->isa('Bio::EnsEMBL::Variation::Individual')) {
			throw('Bio::EnsEMBL::Variation::Individual arg expected');
		}
		if(!defined($individual->dbID())) {
			throw("Individual arg must have defined dbID");
		}
    }
	
    %{$self->{'_slice_feature_cache'}} = (); #clean the cache to avoid caching problems
    
	my $genotype_adaptor = $self->db->get_IndividualGenotypeFeatureAdaptor; #get genotype adaptor
    my $genotypes = $genotype_adaptor->fetch_all_by_Slice($slice, $individual); #and get all genotype data 
    my $afs = $self->SUPER::fetch_all_by_Slice($slice); #get all AlleleFeatures within the Slice
    my @new_afs = ();
	
    # merge AlleleFeatures with genotypes
    foreach my $af (@{$afs}){
		
		# get the variation ID of this AF
		my $af_variation_id = $af->{_variation_id} || $af->variation->dbID;
		
		# get all genotypes that have this var id
		foreach my $gt(grep {$_->{_variation_id} == $af_variation_id} @$genotypes) {
			
			# create a clone of the AF
			my $new_af = { %$af };
			bless $new_af, ref $af;
			
			# add the genotype
			$new_af->allele_string($gt->ambiguity_code);
			
			# add the individual
			$new_af->individual($gt->individual);
			
			push @new_afs, $new_af;
		}
	}
	
    return \@new_afs;
}

sub _tables{    
    my $self = shift;

    return (['variation_feature','vf'],  ['source','s FORCE INDEX(PRIMARY)'], [ 'failed_variation', 'fv']);
}

#�Add a left join to the failed_variation table
sub _left_join { return ([ 'failed_variation', 'fv.variation_id = vf.variation_id']); }

sub _columns{
    my $self = shift;
	
    return qw(vf.variation_id 
	      vf.seq_region_id vf.seq_region_start vf.seq_region_end 
	      vf.seq_region_strand vf.variation_name s.name vf.variation_feature_id vf.allele_string vf.consequence_type);
}

sub _default_where_clause{
    my $self = shift;
    return "vf.source_id = s.source_id";
}

sub _objs_from_sth{
	my ($self, $sth, $mapper, $dest_slice) = @_;
	
	#
	# This code is ugly because an attempt has been made to remove as many
	# function calls as possible for speed purposes.  Thus many caches and
	# a fair bit of gymnastics is used.
	#
	
	my $sa = $self->db()->dnadb()->get_SliceAdaptor();
	
	my @features;
	my %slice_hash;
	my %sr_name_hash;
	my %sr_cs_hash;
	
	my (
		$variation_id, $seq_region_id, $seq_region_start, $seq_region_end,
		$seq_region_strand, $variation_name, $source_name,
		$variation_feature_id, $allele_string, $cons, $last_vf_id
	);
	
	$sth->bind_columns(
		\$variation_id, \$seq_region_id, \$seq_region_start, \$seq_region_end,
		\$seq_region_strand, \$variation_name, \$source_name,
		\$variation_feature_id, \$allele_string, \$cons
	);
	
	my $asm_cs;
	my $cmp_cs;
	my $asm_cs_vers;
	my $asm_cs_name;
	my $cmp_cs_vers;
	my $cmp_cs_name;
	if($mapper) {
		$asm_cs = $mapper->assembled_CoordSystem();
		$cmp_cs = $mapper->component_CoordSystem();
		$asm_cs_name = $asm_cs->name();
		$asm_cs_vers = $asm_cs->version();
		$cmp_cs_name = $cmp_cs->name();
		$cmp_cs_vers = $cmp_cs->version();
	}
	
	my $dest_slice_start;
	my $dest_slice_end;
	my $dest_slice_strand;
	my $dest_slice_length;
	if($dest_slice) {
		$dest_slice_start  = $dest_slice->start();
		$dest_slice_end    = $dest_slice->end();
		$dest_slice_strand = $dest_slice->strand();
		$dest_slice_length = $dest_slice->length();
	}
	
	FEATURE: while($sth->fetch()) {
	
		next if (defined($last_vf_id) && $last_vf_id == $variation_feature_id);
		$last_vf_id = $variation_feature_id;
		
		#get the slice object
		my $slice = $slice_hash{"ID:".$seq_region_id};
		if(!$slice) {
			$slice = $sa->fetch_by_seq_region_id($seq_region_id);
			$slice_hash{"ID:".$seq_region_id} = $slice;
			$sr_name_hash{$seq_region_id} = $slice->seq_region_name();
			$sr_cs_hash{$seq_region_id} = $slice->coord_system();
		}
		#
		# remap the feature coordinates to another coord system
		# if a mapper was provided
		#
		if($mapper) {
			my $sr_name = $sr_name_hash{$seq_region_id};
			my $sr_cs   = $sr_cs_hash{$seq_region_id};
			
			($sr_name,$seq_region_start,$seq_region_end,$seq_region_strand) =
			$mapper->fastmap($sr_name, $seq_region_start, $seq_region_end,
			$seq_region_strand, $sr_cs);
			
			#skip features that map to gaps or coord system boundaries
			next FEATURE if(!defined($sr_name));
			
			#get a slice in the coord system we just mapped to
			if($asm_cs == $sr_cs || ($cmp_cs != $sr_cs && $asm_cs->equals($sr_cs))) {
				$slice = $slice_hash{"NAME:$sr_name:$cmp_cs_name:$cmp_cs_vers"} ||=
					$sa->fetch_by_region($cmp_cs_name, $sr_name,undef, undef, undef,$cmp_cs_vers);
			}
			else {
				$slice = $slice_hash{"NAME:$sr_name:$asm_cs_name:$asm_cs_vers"} ||=
					$sa->fetch_by_region($asm_cs_name, $sr_name, undef, undef, undef, $asm_cs_vers);
			}
		}
		
		#
		# If a destination slice was provided convert the coords
		# If the dest_slice starts at 1 and is foward strand, nothing needs doing
		#
		if($dest_slice) {
			if($dest_slice_start != 1 || $dest_slice_strand != 1) {
				if($dest_slice_strand == 1) {
					$seq_region_start = $seq_region_start - $dest_slice_start + 1;
					$seq_region_end   = $seq_region_end   - $dest_slice_start + 1;
				}
				
				else {
					my $tmp_seq_region_start = $seq_region_start;
					$seq_region_start = $dest_slice_end - $seq_region_end + 1;
					$seq_region_end   = $dest_slice_end - $tmp_seq_region_start + 1;
					$seq_region_strand *= -1;
				}
				
				#throw away features off the end of the requested slice
				if($seq_region_end < 1 || $seq_region_start > $dest_slice_length) {
					next FEATURE;
				}
			}
			$slice = $dest_slice;   
		}
		
		my $overlap_consequences = [ map { $OVERLAP_CONSEQUENCES{$_} } split /,/, $cons ];
		
		push @features, Bio::EnsEMBL::Variation::AlleleFeature->new_fast({
			'start'    => $seq_region_start,
			'end'      => $seq_region_end,
			'strand'   => $seq_region_strand,
			'slice'    => $slice,
			'allele_string' => '',
			'overlap_consequences' => $overlap_consequences,
			'variation_name' => $variation_name,
			'adaptor'  => $self,
			'source'   => $source_name,
			'_variation_id' => $variation_id,
			'_variation_feature_id' => $variation_feature_id,
			'_vf_allele_string' => $allele_string,
			'_sample_id' => ''
		});      
	}
	
	return\@features;
}

=head2 get_all_synonym_sources

    Args[1]     : Bio::EnsEMBL::Variation::AlleleFeature vf
    Example     : my @sources = @{$af_adaptor->get_all_synonym_sources($af)};
    Description : returns a list of all the sources for synonyms of this
                  AlleleFeature
    ReturnType  : reference to list of strings
    Exceptions  : none
    Caller      : general
    Status      : At Risk
                : Variation database is under development.
=cut

sub get_all_synonym_sources{
    my $self = shift;
    my $af = shift;
    my %sources;
    my @sources;

    if(!ref($af) || !$af->isa('Bio::EnsEMBL::Variation::AlleleFeature')) {
	 throw("Bio::EnsEMBL::Variation::AlleleFeature argument expected");
    }
    
    if (!defined($af->{'_variation_id'}) && !defined($af->{'variation'})){
	warning("Not possible to get synonym sources for the AlleleFeature: you need to attach a Variation first");
	return \@sources;
    }
    #get the variation_id
    my $variation_id;
    if (defined ($af->{'_variation_id'})){
	$variation_id = $af->{'_variation_id'};
    }
    else{
	$variation_id = $af->variation->dbID();
    }
    #and go to the varyation_synonym table to get the extra sources
    my $source_name;
    my $sth = $self->prepare(qq{SELECT s.name 
				FROM variation_synonym vs, source s 
				WHERE s.source_id = vs.source_id
			        AND   vs.variation_id = ?
			    });
    $sth->bind_param(1,$variation_id,SQL_INTEGER);
    $sth->execute();
    $sth->bind_columns(\$source_name);
    while ($sth->fetch){
	$sources{$source_name}++;
    }
    @sources = keys(%sources); 
    return \@sources;
}

1;
