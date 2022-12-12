include { BAM_JOINT_CALLING_GERMLINE_GATK          } from '../bam_joint_calling_germline_gatk/main'
include { BAM_MERGE_INDEX_SAMTOOLS                 } from '../bam_merge_index_samtools/main'
include { VCF_VARIANT_FILTERING_GATK               } from '../vcf_variant_filtering_gatk/main'
include { GATK4_HAPLOTYPECALLER                    } from '../../../modules/nf-core/gatk4/haplotypecaller/main'
include { GATK4_MERGEVCFS as MERGE_HAPLOTYPECALLER } from '../../../modules/nf-core/gatk4/mergevcfs/main'

workflow BAM_VARIANT_CALLING_HAPLOTYPECALLER {
    take:
    cram                            // channel: [mandatory] [meta, cram, crai, interval.bed]
    fasta                           // channel: [mandatory]
    fasta_fai                       // channel: [mandatory]
    dict                            // channel: [mandatory]
    dbsnp                           // channel: []
    dbsnp_tbi
    known_sites_indels
    known_sites_indels_tbi
    known_sites_snps
    known_sites_snps_tbi
    intervals_bed_combined          // channel: [mandatory] intervals/target regions in one file unzipped, no_intervals.bed if no_intervals
    skip_haplotypecaller_filter

    main:

    versions = Channel.empty()
    vcf = Channel.empty()
    realigned_bam = Channel.empty()

    GATK4_HAPLOTYPECALLER(
        cram,
        fasta,
        fasta_fai,
        dict,
        dbsnp,
        dbsnp_tbi)

    // Figure out if using intervals or no_intervals
    haplotypecaller_vcf_branch = GATK4_HAPLOTYPECALLER.out.vcf.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }

    haplotypecaller_tbi_branch = GATK4_HAPLOTYPECALLER.out.tbi.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }

    haplotypecaller_bam_branch = GATK4_HAPLOTYPECALLER.out.bam.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }

    if (params.joint_germline) {
        // merge vcf and tbis
        genotype_gvcf_to_call = Channel.empty().mix(
                GATK4_HAPLOTYPECALLER.out.vcf
                .join(GATK4_HAPLOTYPECALLER.out.tbi)
                .join(cram)
                .map{ meta, vcf, tbi, cram, crai, intervals, dragstr_model ->
                    [ meta, vcf, tbi, intervals ]
                })

        // make channels from labels
        dbsnp_vqsr        = params.dbsnp_vqsr        ? Channel.value(params.dbsnp_vqsr)        : Channel.empty()
        known_indels_vqsr = params.known_indels_vqsr ? Channel.value(params.known_indels_vqsr) : Channel.empty()
        known_snps_vqsr   = params.known_snps_vqsr   ? Channel.value(params.known_snps_vqsr)   : Channel.empty()


        BAM_JOINT_CALLING_GERMLINE_GATK(
            genotype_gvcf_to_call,
            fasta,
            fasta_fai,
            dict,
            dbsnp,
            dbsnp_tbi,
            dbsnp_vqsr,
            known_sites_indels,
            known_sites_indels_tbi,
            known_indels_vqsr,
            known_sites_snps,
            known_sites_snps_tbi,
            known_snps_vqsr)

        vcf = BAM_JOINT_CALLING_GERMLINE_GATK.out.genotype_vcf
        versions = versions.mix(BAM_JOINT_CALLING_GERMLINE_GATK.out.versions)

    } else {

        // Only when using intervals
        MERGE_HAPLOTYPECALLER(
            haplotypecaller_vcf_branch.intervals
            .map{ meta, vcf ->
                def new_meta = [
                        id:             meta.sample,
                        num_intervals:  meta.num_intervals,
                        patient:        meta.patient,
                        sample:         meta.sample,
                        sex:            meta.sex,
                        status:         meta.status,
                        variantcaller:  "haplotypecaller"
                    ]

                    [groupKey(new_meta, new_meta.num_intervals), vcf]
                }.groupTuple(), dict.map{ it -> [[id:it[0].baseName], it]})

        haplotypecaller_vcf = Channel.empty().mix(
                MERGE_HAPLOTYPECALLER.out.vcf,
                haplotypecaller_vcf_branch.no_intervals)

        haplotypecaller_tbi = Channel.empty().mix(
                MERGE_HAPLOTYPECALLER.out.tbi,
                haplotypecaller_tbi_branch.no_intervals)

        // BAM output
        BAM_MERGE_INDEX_SAMTOOLS(
            haplotypecaller_bam_branch.intervals
                .map{ meta, bam ->

                    def new_meta = [
                        id:             meta.sample,
                        num_intervals:  meta.num_intervals,
                        patient:        meta.patient,
                        sample:         meta.sample,
                        sex:            meta.sex,
                        status:         meta.status
                    ]

                    [groupKey(new_meta, new_meta.num_intervals), bam]
                }.groupTuple()
                .mix(haplotypecaller_bam_branch.no_intervals))

        realigned_bam = BAM_MERGE_INDEX_SAMTOOLS.out.bam_bai

        if (!skip_haplotypecaller_filter) {

            VCF_VARIANT_FILTERING_GATK(
                haplotypecaller_vcf.join(haplotypecaller_tbi),
                fasta,
                fasta_fai,
                dict,
                intervals_bed_combined,
                known_sites_indels.concat(known_sites_snps).flatten().unique().collect(),
                known_sites_indels_tbi.concat(known_sites_snps_tbi).flatten().unique().collect())

            vcf = VCF_VARIANT_FILTERING_GATK.out.filtered_vcf.map{ meta, vcf ->
                [[
                    id:             meta.sample,
                    num_intervals:  meta.num_intervals,
                    patient:        meta.patient,
                    sample:         meta.sample,
                    sex:            meta.sex,
                    status:         meta.status,
                    variantcaller:  "haplotypecaller"
                ], vcf ]}

            versions = versions.mix(VCF_VARIANT_FILTERING_GATK.out.versions)

        } else vcf = haplotypecaller_vcf

        versions = versions.mix(MERGE_HAPLOTYPECALLER.out.versions)

    }
    versions = versions.mix(GATK4_HAPLOTYPECALLER.out.versions)

    emit:
    realigned_bam
    vcf
    versions
}
