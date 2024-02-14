//
// Check input samplesheet and get read channels
//

include { COMBINE_SCOREFILES  } from '../../modules/local/combine_scorefiles'

//sp = new SamplesheetParser()
//println sp.hi()

workflow INPUT_CHECK {
    take:
    input_path // file: /path/to/samplesheet.csv
    format // csv or JSON
    scorefile // flat list of paths
    chain_files

    main:
    /* all genomic data should be represented as a list of : [[meta], file]

       meta hashmap structure:
        id: experiment label, possibly shared across split genomic files
        is_vcf: boolean, is in variant call format
        is_bfile: boolean, is in PLINK1 fileset format
        is_pfile: boolean, is in PLINK2 fileset format
        chrom: The chromosome associated with the file. If multiple chroms, null.
        n_chrom: Total separate chromosome files per experiment ID
     */

    ch_versions = Channel.empty()
    parsed_input = Channel.empty()
    
    input = Channel.fromPath(input_path, checkIfExists: true)

    if (format.equals("csv")) {
        in_ch = input.splitCsv(header:true)       
        verifySamplesheet(in_ch)
        def n_chrom
        n_chrom = file(input_path).countLines() - 1 // ignore header
        in_ch
            .map { row -> parseSamplesheet(row, input_path, n_chrom) }
            .set { parsed_input }
    } else if (format.equals("json")) {
        in_ch = input.splitJson()
        def n_chrom
        n_chrom = file(input_path).countJson() // ignore header
        throw new Exception("Not implemented")
    }

    parsed_input.branch {
                vcf: it[0].is_vcf
                bfile: it[0].is_bfile
                pfile: it[0].is_pfile
        }
        .set { ch_branched }

    // branch is like a switch statement, so only one bed / bim was being
    // returned
    ch_branched.bfile.multiMap { it ->
        bed: [it[0], it[1][0]]
        bim: [it[0], it[1][1]]
        fam: [it[0], it[1][2]]
    }
        .set { ch_bfiles }

    ch_branched.pfile.multiMap { it ->
        pgen: [it[0], it[1][0]]
        psam: [it[0], it[1][1]]
        pvar: [it[0], it[1][2]]
    }
        .set { ch_pfiles }
    
    COMBINE_SCOREFILES ( scorefile, chain_files )

    versions = ch_versions.mix(COMBINE_SCOREFILES.out.versions)

    ch_bfiles.bed.mix(ch_pfiles.pgen).dump(tag: 'input').set { geno }
    ch_bfiles.bim.mix(ch_pfiles.pvar).dump(tag: 'input').set { variants }
    ch_bfiles.fam.mix(ch_pfiles.psam).dump(tag: 'input').set { pheno }
    ch_branched.vcf.dump(tag: 'input').set{vcf}
    COMBINE_SCOREFILES.out.scorefiles.dump(tag: 'input').set{ scorefiles }
    COMBINE_SCOREFILES.out.log_scorefiles.dump(tag: 'input').set{ log_scorefiles }

    emit:
    geno = Channel.empty()
    variants = Channel.empty()
    pheno = Channel.empty()
    vcf = Channel.empty()
    scorefiles = Channel.empty()
    log_scorefiles = Channel.empty()
    versions = Channel.empty()
}

import java.nio.file.Paths
import java.nio.file.NoSuchFileException

def parseSamplesheet(row, samplesheet_path, n_chrom) {
    // [[meta], [path, to targets]]
    def chrom = truncateChrom(row)
    def dosage = importDosage(row)
    def paths = getFilePaths(row, samplesheet_path)
    
    path_list = paths["path"]
    path_map = paths.subMap("is_bfile", "is_pfile", "is_vcf", "format")
    return [[sampleset: row.sampleset, chrom: chrom, vcf_import_dosage: dosage, n_chrom: n_chrom] + path_map, path_list]
}

def importDosage(row) {
    def vcf_import_dosage = false
    if (row.containsKey("vcf_genotype_field")) {
        if (row["vcf_genotype_field"] == "DS") {
            vcf_import_dosage = true
        }
    }

    return vcf_import_dosage
}

def getFilePaths(row, samplesheet_path) {
    // return a list in order of geno, variants, pheno
    def resolved_path = resolvePath(row.path_prefix, samplesheet_path)
    def suffix = [:]
    def is_vcf = false
    def is_bfile = false
    def is_pfile = false

    switch(row.format) {
        case "pfile":
            suffix = [variants: ".pvar", geno: ".pgen", pheno: ".psam"]
            is_pfile = true
            break
        case "bfile":
            suffix = [variants: ".bim", geno: ".bed", pheno: ".fam"]
            is_bfile = true
            break
        case "vcf":
            suffix = [variants: ".vcf.gz", geno: ".vcf.gz", pheno: ".vcf.gz"]
            is_vcf = true
            break
        default:
            throw new Exception("Invalid format: ${format}")
    }

    variant_paths = suffix.subMap("variants").collect { k, v ->
        try {
            // always prefer zstd compressed data
            f = file(resolved_path + v + ".zst", checkIfExists: true)
        }
        catch (NoSuchFileException exception) {
            f = file(resolved_path + v, checkIfExists: true)
        }
        return [(k): f]
    }.first()

    other_paths = suffix.subMap(["geno", "pheno"]).collect { k, v ->
        [(k) : file(resolved_path + v, checkIfExists:true)]
    }

    // flatten the list of maps
    flat_path_map = other_paths.inject([:], { item, other -> item + other }) + variant_paths

    // call unique to remove duplicate VCF entries
    path_list = [flat_path_map.geno, flat_path_map.variants, flat_path_map.pheno].unique()
    return [path: path_list, is_bfile: is_bfile, is_pfile: is_pfile, is_vcf: is_vcf, format: row.format]
}

def resolvePath(path, samplesheet_path) {
    // isAbsolute() was causing weird issues
    def is_absolute = path.startsWith('/')

    def resolved_path
    if (is_absolute) {
        resolved_path = file(path).resolve()
    } else {
        resolved_path = file(samplesheet_path).getParent().resolve(path)
    }

    return resolved_path
}

def truncateChrom(row) {
    return row.chrom ? row.chrom.toString().replaceFirst("chr", "") : "ALL"
}


def verifySamplesheet(samplesheet) {
    // input must be a file split with headers e.g. splitCsv or splitJSON
    checkChroms(samplesheet)
    checkOneSampleset(samplesheet)
    checkReservedName(samplesheet)
    checkDuplicateChromosomes(samplesheet)

}

def checkChroms(samplesheet) {
    // one missing chromosome (i.e. a combined file) is OK. more than this isn't
    samplesheet.collect{ row -> row.chrom }.map { it ->
        n_empty_chrom = it.count { it == "" }
          if (n_empty_chrom > 1) {
            throw new Exception("${n_empty_chrom} missing chromosomes detected! Maximum is 1. Check your samplesheet.")    
          }
    }    
}

def checkOneSampleset(samplesheet) {
    samplesheet.collect{ row -> row.sampleset }.map { it -> 
        n_samplesets = it.toSet().size() 
          if (n_samplesets > 1) {
            throw new Exception("${n_samplesets} missing chromosomes detected! Maximum is 1. Check your samplesheet.")    
          }
    }    
}

def checkReservedName(samplesheet) {
    samplesheet.collect{ row -> row.sampleset }.map { it -> 
          n_bad_name = it.count { it == "reference" }    

          if (n_bad_name > 0) {
            throw new Exception("Reserved sampleset name detected. Please don't call your sampleset 'reference'")
          }
    }    
}

def checkDuplicateChromosomes(samplesheet) {
    samplesheet.collect{ row -> row.chrom }.map { it ->
          n_unique_chroms = it.toSet().size()
          n_chroms = it.size()

          if (n_unique_chroms != n_chroms) {
             throw new Exception("Duplicated chromosome entries detected in samplesheet")
          }
    }    
}