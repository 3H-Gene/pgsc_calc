process PLINK2_SCORE {
    tag "$meta.id"
    label 'process_medium'

    conda (params.enable_conda ? "bioconda::plink2=2.00a2.3" : null)
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/plink2:2.00a2.3--h712d239_1' :
        'quay.io/biocontainers/plink2:2.00a2.3--h712d239_1' }"

    input:
    tuple val(meta), path(geno), path(pheno), path(variants), val(scoremeta), path(scorefile)

    output:
    path "*.sscore"    , emit: scores
    path "versions.yml", emit: versions
    path "*.log"       , emit: log

    script:
    def args = task.ext.args ?: ''
    def args2 = task.ext.args2 ?: ''
    def mem_mb = task.memory.toMega() // plink is greedy

    // dynamic input option
    def input = (meta.is_pfile) ? '--pfile' : '--bfile'

    // custom args2
    def maxcol = (scoremeta.n_scores + 2) // id + effect allele = 2 cols
    def no_imputation = (meta.n_samples < 50) ? 'no-mean-imputation' : ''
    def recessive = (scoremeta.effect_type == 'recessive') ? ' recessive ' : ''
    def dominant = (scoremeta.effect_type == 'dominant') ? ' dominant ' : ''

    args2 = [args2, no_imputation, recessive, dominant].join(' ')

    if (scoremeta.n_scores == 1)
        """
        plink2 \\
            --threads $task.cpus \\
            --memory $mem_mb \\
            $args \\
            --score $scorefile $args2 \\
            $input ${geno.baseName} \\
            --out ${meta.id}_${meta.chrom}_${scoremeta.effect_type}_${scoremeta.n}

        cat <<-END_VERSIONS > versions.yml
        ${task.process.tokenize(':').last()}:
            plink2: \$(plink2 --version 2>&1 | sed 's/^PLINK v//; s/ 64.*\$//' )
        END_VERSIONS
        """
    else if (scoremeta.n_scores > 1)
        """
        plink2 \\
            --threads $task.cpus \\
            --memory $mem_mb \\
            $args \\
            --score $scorefile $args2 \\
            --score-col-nums 3-$maxcol \\
            $input ${geno.baseName} \\
            --out ${meta.id}_${meta.chrom}_${scoremeta.effect_type}_${scoremeta.n}

        cat <<-END_VERSIONS > versions.yml
        ${task.process.tokenize(':').last()}:
            plink2: \$(plink2 --version 2>&1 | sed 's/^PLINK v//; s/ 64.*\$//' )
        END_VERSIONS
        """
}
