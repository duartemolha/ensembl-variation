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

=head1 NAME

Bio::EnsEMBL::Variation::Overlap

=head1 SYNOPSIS

    use Bio::EnsEMBL::Variation::VariationFeatureOverlapAllele;
    
    my $vfoa = Bio::EnsEMBL::Variation::VariationFeatureOverlapAllele->new(
        -variation_feature_overlap  => $vfo,
        -variation_feature_seq      => 'A',
        -is_reference               => 0,
    );

    print "sequence with respect to the feature: ", $vfoa->feature_seq, "\n";
    print "sequence with respect to the variation feature: ", $vfoa->variation_feature_seq, "\n";
    print "consequence SO terms: ", (join ",", map { $_->SO_term } @{ $vfoa->get_all_OverlapConsequences }), "\n";

=head1 DESCRIPTION

A VariationFeatureOverlapAllele object represents a single allele of a 
VariationFeatureOverlap. It is the super-class of various feature-specific allele
classes such as TranscriptVariationAllele and RegulatoryFeatureVariationAllele and 
contains methods not specific to any particular feature type. Ordinarily you will 
not create these objects yourself, but instead you would create e.g. a 
TranscriptVariation object which will then VariationFeatureOverlapAlleles based on the 
allele string of the associated VariationFeature. 

=cut


package Bio::EnsEMBL::Variation::OverlapConsequence;

use strict;
use warnings;

use Bio::EnsEMBL::Variation::Utils::VariationEffect;

sub new {
    my $class = shift;
    
    my (
        $SO_accession,
        $SO_term,
        $feature_SO_term,
        $feature_class,
        $predicate,
        $rank,
        $display_term,
        $NCBI_term,
        $description,
        $label,
        $is_default,
    ) = rearrange([qw(
            SO_ACCESSION
            SO_TERM
            FEATURE_SO_TERM
            FEATURE_CLASS
            PREDICATE
            RANK
            NCBI_TERM
            DESCRIPTION
            LABEL
            IS_DEFAULT
        )], @_);

    my $self = bless {
        SO_accession        => $SO_accession,
        SO_term             => $SO_term,
        feature_SO_term     => $feature_SO_term,
        feature_class       => $feature_class,
        predicate           => $predicate,
        rank                => $rank,
        display_term        => $display_term,
        NCBI_term           => $NCBI_term,
        description         => $description,
        label               => $label,
        is_default          => $is_default,
    }, $class;

    return $self;
}

sub new_fast {
    my ($class, $hashref) = @_;
    return bless $hashref, $class;
}

sub SO_accession {
    my ($self, $SO_accession) = @_;
    $self->{SO_accession} = $SO_accession if $SO_accession;
    return $self->{SO_accession};
}

sub SO_term {
    my ($self, $SO_term) = @_;
    $self->{SO_term} = $SO_term if $SO_term;
    return $self->{SO_term};
}

sub feature_SO_term {
    my ($self, $feature_SO_term) = @_;
    $self->{feature_SO_term} = $feature_SO_term if $feature_SO_term;
    return $self->{feature_SO_term};
}

sub feature_class {
    my ($self, $feature_class) = @_;
    $self->{feature_class} = $feature_class if $feature_class;
    return $self->{feature_class} || '';
}

sub predicate {
    my ($self, $predicate) = @_;
    
    $self->{predicate} = $predicate if $predicate;
    
    if ($self->{predicate} && ref $self->{predicate} ne 'CODE') {
        my $name = $self->{predicate};

        if (defined &$name && $name =~ /^Bio::EnsEMBL::Variation::Utils::VariationEffect/) {
            $self->{predicate} = \&$name;
        }
        else {
            die "Can't find a subroutine called $name in the VariationEffect module?";
        }
    }
    
    return $self->{predicate};
}

sub rank {
    my ($self, $rank) = @_;
    $self->{rank} = $rank if $rank;
    return $self->{rank};
}

sub display_term {
    my ($self, $display_term) = @_;
    $self->{display_term} = $display_term if $display_term;
    return $self->{display_term} || $self->SO_term;
}

sub NCBI_term {
    my ($self, $NCBI_term) = @_;
    $self->{NCBI_term} = $NCBI_term if $NCBI_term;
    return $self->{NCBI_term};
}

sub description {
    my ($self, $description) = @_;
    $self->{description} = $description if $description;
    return $self->{description};
}

sub label {
    my ($self, $label) = @_;
    $self->{label} = $label if $label;
    return $self->{label};
}

sub is_default {
    my ($self, $is_default) = @_;
    $self->{is_default} = $is_default if defined $is_default;
    return $self->{is_default};
}

sub is_definitive {
    my ($self, $is_definitive) = @_;
    $self->{is_definitive} = $is_definitive if defined $is_definitive;
    return $self->{is_definitive};
}

sub get_all_parent_SO_terms {
    my ($self) = @_;
    
    if (my $adap = $self->{adaptor}) {
        if (my $goa = $adap->db->get_SOTermAdaptor) {
            
        }
    }
}

1;
