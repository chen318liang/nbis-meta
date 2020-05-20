from scripts.common import binning_input, get_fw_reads
from scripts.common import get_binners, get_tree_settings

localrules:
    concoct_cutup,
    merge_cutup,
    extract_fasta,
    contig_map,
    binning_stats,
    download_checkm, 
    checkm_qa,
    aggregate_checkm_stats,
    checkm_profile,
    download_gtdb,
    aggregate_gtdbtk

##### master rule for binning #####

rule bin:
    input:
        binning_input(config, assemblies)

##### metabat2 #####

rule metabat_coverage:
    input:
        bam=get_all_files(samples, opj(config["paths"]["results"], "assembly",
                                       "{group}", "mapping"), ".bam")
    output:
        depth=opj(config["paths"]["results"], "binning", "metabat", "{group}",
                  "cov", "depth.txt")
    log:
        opj(config["paths"]["results"], "binning", "metabat", "{group}",
                  "cov", "log")
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60*2
    conda:
        "../envs/metabat.yml"
    shell:
        """
        jgi_summarize_bam_contig_depths \
            --outputDepth {output.depth} {input.bam} >{log} 2>&1
        """

rule metabat:
    input:
        fa=opj(config["paths"]["results"], "assembly", "{group}",
               "final_contigs.fa"),
        depth=opj(config["paths"]["results"], "binning", "metabat", "{group}",
                  "cov", "depth.txt")
    output:
        touch(temp(opj(config["paths"]["results"], "binning", "metabat", "{group}",
                       "{l}", "done")))
    log:
        opj(config["paths"]["results"], "binning", "metabat", "{group}", "{l}", "metabat.log")
    params:
        n=opj(config["paths"]["results"], "binning", "metabat", "{group}", "{l}", "metabat")
    conda:
        "../envs/metabat.yml"
    threads: 8
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60*4
    shell:
        """
        metabat2 -i {input.fa} -a {input.depth} -m {wildcards.l} -t {threads} \
            -o {params.n} > {log} 2>&1
        """

##### maxbin2 #####

rule maxbin:
    input:
        opj(config["paths"]["results"], "assembly", "{group}", "final_contigs.fa")
    output:
        touch(temp(opj(config["paths"]["results"], "binning", "maxbin", "{group}",
                 "{l}", "done")))
    log:
        opj(config["paths"]["results"], "binning", "maxbin", "{group}", "{l}", "maxbin.log")
    params:
        dir=opj(config["paths"]["results"], "binning", "maxbin", "{group}", "{l}"),
        tmp_dir=opj(config["paths"]["temp"], "{group}", "{l}"),
        reads=get_fw_reads(config, samples, PREPROCESS),
        markerset=config["maxbin_markerset"]
    threads: config["maxbin_threads"]
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60*5
    conda:
        "../envs/maxbin.yml"
    shell:
        """
        mkdir -p {params.dir}
        mkdir -p {params.tmp_dir}
        run_MaxBin.pl -markerset {params.markerset} -contig {input} \
            {params.reads} -min_contig_length {wildcards.l} -thread {threads} \
            -out {params.tmp_dir}/{wildcards.group} >{log} 2>{log}
        # Rename fasta files
        for f in {params.tmp_dir}/*.fasta ; do mv $f ${{f%.fasta}}.fa ; done
        # Move output from temporary dir
        mv {params.tmp_dir}/* {params.dir}
        # Clean up
        rm -r {params.tmp_dir}
        """

##### concoct #####

rule concoct_coverage_table:
    input:
        bam=get_all_files(samples, opj(config["paths"]["results"], "assembly",
                                       "{group}", "mapping"), ".bam"),
        bai=get_all_files(samples, opj(config["paths"]["results"], "assembly",
                                       "{group}", "mapping"), ".bam.bai"),
        bed=opj(config["paths"]["results"], "assembly", "{group}",
                "final_contigs_cutup.bed")
    output:
        cov=opj(config["paths"]["results"], "binning", "concoct", "{group}",
                "cov", "concoct_inputtable.tsv")
    conda:
        "../envs/concoct.yml"
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60*2
    params:
        samplenames=opj(config["paths"]["results"], "binning", "concoct",
                        "{group}", "cov", "samplenames"),
        p=POSTPROCESS
    shell:
        """
        for f in {input.bam} ; 
            do 
                n=$(basename $f); 
                s=$(echo -e $n | sed 's/_[ps]e{params.p}.bam//g'); 
                echo $s; 
            done > {params.samplenames}
        concoct_coverage_table.py \
            --samplenames {params.samplenames} \
            {input.bed} {input.bam} > {output.cov}
        rm {params.samplenames}
        """

rule concoct_cutup:
    input:
        fa=opj(config["paths"]["results"], "assembly", "{group}", "final_contigs.fa")
    output:
        fa=opj(config["paths"]["results"], "assembly", "{group}",
               "final_contigs_cutup.fa"),
        bed=opj(config["paths"]["results"], "assembly", "{group}",
                "final_contigs_cutup.bed")
    log:
        opj(config["paths"]["results"], "assembly", "{group}",
               "final_contigs_cutup.log")
    conda:
        "../envs/concoct.yml"
    shell:
        """
        cut_up_fasta.py -b {output.bed} -c 10000 -o 0 -m {input.fa} \
            > {output.fa} 2>{log}
        """

rule concoct:
    input:
        cov=opj(config["paths"]["results"], "binning", "concoct", "{group}",
                "cov", "concoct_inputtable.tsv"),
        fa=opj(config["paths"]["results"], "assembly", "{group}",
               "final_contigs_cutup.fa")
    output:
        opj(config["paths"]["results"], "binning", "concoct", "{group}", "{l}",
            "clustering_gt{l}.csv")
    log:
        opj(config["paths"]["results"], "binning", "concoct", "{group}", "{l}", "log.txt")
    params:
        basename=lambda wildcards, output: os.path.dirname(output[0]),
        length="{l}"
    threads: config["concoct_threads"]
    conda:
        "../envs/concoct.yml"
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60*2
    shell:
        """
        concoct -t {threads} --coverage_file {input.cov} -l {params.length} \
            --composition_file {input.fa} -b {params.basename}/ >/dev/null 2>&1
        """

rule merge_cutup:
    input:
        opj(config["paths"]["results"], "binning", "concoct", "{group}",
            "{l}", "clustering_gt{l}.csv")
    output:
        opj(config["paths"]["results"], "binning", "concoct", "{group}",
            "{l}", "clustering_gt{l}_merged.csv"),
    log:
        opj(config["paths"]["results"], "binning", "concoct", "{group}",
            "{l}", "clustering_gt{l}_merged.log")
    conda:
        "../envs/concoct.yml"
    shell:
        """
        merge_cutup_clustering.py {input[0]} > {output[0]} 2> {log}
        """

rule extract_fasta:
    input:
        opj(config["paths"]["results"], "assembly", "{group}", "final_contigs.fa"),
        opj(config["paths"]["results"], "binning", "concoct", "{group}",
            "{l}", "clustering_gt{l}_merged.csv")
    output:
        temp(opj(config["paths"]["results"], "binning", "concoct", "{group}",
                  "{l}", "done"))
    log:
        opj(config["paths"]["results"], "binning", "concoct", "{group}",
                  "{l}", "extract_fasta.log")
    params:
        dir=lambda wildcards, output: os.path.dirname(output[0])
    conda:
        "../envs/concoct.yml"
    shell:
        """
        extract_fasta_bins.py {input[0]} {input[1]} --output_path {params.dir} \
            2> {log}
        """

##### map contigs to bins #####

rule contig_map:
    input:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}",
                  "{l}", "done")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}",
                  "{l}", "contig_map.tsv")
    params:
        dir=lambda wildcards, input: os.path.dirname(input[0])
    script:
        "../scripts/binning_utils.py"

##### bin qc #####

rule binning_stats:
    input:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}",
            "contig_map.tsv")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}",
            "{l}", "summary_stats.tsv")
    params:
        dir=lambda wildcards, output: os.path.dirname(output[0])
    script:
        "../scripts/binning_utils.py"

rule download_checkm:
    output:
        db=opj(config["resource_path"], "checkm", ".dmanifest")
    log:
        opj(config["resource_path"], "checkm", "checkm.log")
    params:
        tar=lambda wildcards, output: opj(os.path.dirname(output.db), "checkm_data.tar.gz"),
        dir=lambda wildcards, output: os.path.dirname(output.db)
    conda:
        "../envs/checkm.yml"
    shell:
        """
        # Download
        curl -L https://data.ace.uq.edu.au/public/CheckM_databases/checkm_data_2015_01_16.tar.gz -o {params.tar} -s
        # Extract
        tar -C {params.dir} -xf {params.tar}
        # Set root
        checkm data setRoot {params.dir} > {log} 2>&1
        """

if config["checkm_taxonomy_wf"]:
    rule checkm_taxonomy_wf:
        input:
            db=opj(config["resource_path"], "checkm", ".dmanifest"),
            tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv")
        output:
            tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                      "genome_stats.tsv"),
            ms=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                      "lineage.ms")
        log:
            opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                "checkm.log")
        conda:
            "../envs/checkm.yml"
        threads: 10
        resources:
            runtime=lambda wildcards, attempt: attempt**2*60
        params:
            suff='fa',
            indir=lambda wildcards, input: os.path.dirname(input.tsv),
            outdir=lambda wildcards, output: os.path.dirname(output.tsv),
            rank=config["checkm_rank"],
            taxon=config["checkm_taxon"]
        shell:
            """
            bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
            if [ $bins == 0 ] ; then
                echo "NO BINS FOUND" > {output.tsv}
                touch {output.ms}
            else
                checkm taxonomy_wf -t {threads} -x {params.suff} -q \
                    --tab_table -f {output.tsv} \
                    {params.rank} {params.taxon} {params.indir} {params.outdir} \
                    > {log} 2>&1
            fi
            ln -s {params.taxon}.ms {output.ms}
            """
else:
    rule checkm_lineage_wf:
        input:
            db=opj(config["resource_path"], "checkm", ".dmanifest"),
            tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv")
        output:
            tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                      "genome_stats.tsv"),
            ms=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                      "lineage.ms")
        log:
            opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                "checkm.log")
        conda:
            "../envs/checkm.yml"
        threads: 10
        resources:
            runtime=lambda wildcards, attempt: attempt**2*60
        params:
            suff='fa',
            indir=lambda wildcards, input: os.path.dirname(input.tsv),
            outdir=lambda wildcards, output: os.path.dirname(output.tsv),
            tree=get_tree_settings(config)
        shell:
            """
            bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
            if [ $bins == 0 ] ; then
                echo "NO BINS FOUND" > {output.tsv}
                touch {output.ms}
            else
                checkm lineage_wf -t {threads} --pplacer_threads {threads} \
                    -x {params.suff} {params.tree} -q \
                    --tab_table -f {output.tsv} \
                    {params.indir} {params.outdir} \
                    > {log} 2>&1
            fi
            """

rule checkm_qa:
    """
    Runs checkm qa to generate output format 2 with extended summaries of bins
    """
    input:
        tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv"),
        ms=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                  "lineage.ms")
    output:
        tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                  "genome_stats.extended.tsv")
    log:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                  "qa.log")
    conda:
        "../envs/checkm.yml"
    params:
        dir=lambda wildcards, output: os.path.dirname(output.tsv)
    shell:
        """
        bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
        if [ $bins == 0 ] ; then
            echo "NO BINS FOUND" > {output.tsv}
        else
            checkm qa -o 2 --tab_table -f {output.tsv} \
                {input.ms} {params.dir} > {log} 2>&1
        fi 
        """

rule checkm_coverage:
    input:
        tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv"),
        bam=get_all_files(samples, opj(config["paths"]["results"], "assembly",
                                         "{group}", "mapping"), ".markdup.bam"),
        bai=get_all_files(samples, opj(config["paths"]["results"], "assembly",
                                         "{group}", "mapping"), ".markdup.bam.bai")
    output:
        cov=temp(opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm", "coverage.tsv"))
    log:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm", "checkm_coverage.log")
    params:
        dir=lambda wildcards, input: os.path.dirname(input.tsv)
    threads: 10
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60
    conda:
        "../envs/checkm.yml"
    shell:
        """
        bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
        if [ $bins == 0 ] ; then
            echo "NO BINS FOUND" > {output}
        else
            checkm coverage -x fa -t {threads} {params.dir} \
                {output} {input.bam} > {log} 2>&1
        fi
        """

rule checkm_profile:
    input:
        cov=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm", "coverage.tsv"),
        stats=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm", "profile.tsv")
    log:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm", "checkm_profile.log")
    conda:
        "../envs/checkm.yml"
    shell:
        """
        bins=$(wc -l {input.stats} | cut -f1 -d ' ')
        if [ $bins == 0 ] ; then
            echo "NO BINS FOUND" > {output}
        else
            checkm profile -f {output} --tab_table {input.cov} > {log} 2>&1
        fi
        """

rule aggregate_checkm_profiles:
    input:
        expand(opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "checkm",
                  "profile.tsv"),
               group=assemblies.keys(),
               l=config["min_contig_length"],
               binner=get_binners(config))
    output:
        tsv=opj(config["paths"]["results"], "report", "checkm", "checkm.profiles.tsv")
    run:
        df=concatenate(input)
        df.to_csv(output.tsv, sep="\t", index=True)

rule aggregate_checkm_stats:
    input:
        expand(opj(config["paths"]["results"], "binning", "{binner}", "{group}",
                   "{l}", "checkm", "genome_stats.extended.tsv"),
               group=assemblies.keys(),
               l=config["min_contig_length"],
               binner=get_binners(config))
    output:
        tsv=opj(config["paths"]["results"], "report", "checkm", "checkm.stats.tsv")
    run:
        df=concatenate(input)
        df.to_csv(output.tsv, sep="\t", index=True)

##### classify bins with gtdb-tk #####

rule download_gtdb:
    output:
        met=opj(config["resource_path"], "gtdb", "metadata",
                  "metadata.txt")
    log:
        opj(config["resource_path"], "gtdb", "download.log")
    params:
        url="https://data.ace.uq.edu.au/public/gtdb/data/releases/release89/89.0/gtdbtk_r89_data.tar.gz",
        tar=lambda wildcards, output: opj(os.path.dirname(output.met), "gtdbtk_r89_data.tar.gz"),
        dir=lambda wildcards, output: os.path.dirname(output.met)
    shell:
        """
        curl -L -o {params.tar} {params.url} > {log} 2>&1
        tar xzf {params.tar} -C {params.dir} --strip 1 > {log} 2>&1
        """

rule gtdbtk_classify:
    input:
        met=opj(config["resource_path"], "gtdb", "metadata",
                  "metadata.txt"),
        tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv")
    output:
        touch(opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "gtdbtk", "done"))
    log:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "gtdbtk", "gtdbtk.log")
    params:
        suff='fa',
        indir=lambda wildcards, input: os.path.dirname(input.tsv),
        dbdir=lambda wildcards, input: os.path.abspath(os.path.dirname(os.path.dirname(input.met))),
        outdir=lambda wildcards, output: os.path.dirname(output[0])
    threads: 20
    resources:
        runtime=lambda wildcards, attempt: attempt**2*60
    conda:
        "../envs/gtdbtk.yml"
    shell:
        """
        bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
        if [ $bins == 0 ] ; then
            echo "NO BINS FOUND" > {output}
        else
            export PYTHONPATH=$(which python)
            export GTDBTK_DATA_PATH={params.dbdir}
            gtdbtk classify_wf -x {params.suff} --out_dir {params.outdir} \
                --cpus {threads} --pplacer_cpus {threads} \
                --genome_dir {params.indir} > {log} 2>&1
        fi
        """

rule aggregate_gtdbtk:
    """
    Aggregates GTDB-TK phylogenetic results from several assemblies into a 
    single table.
    """
    input:
        expand(opj(config["paths"]["results"], "binning", "{binner}", "{group}",
                   "{l}", "gtdbtk", "done"),
               binner=get_binners(config),
               group=assemblies.keys(),
               l=config["min_contig_length"])
    output:
        summary=opj(config["paths"]["results"], "report", "gtdbtk", "gtdbtk.summary.tsv")
    run:
        summaries=[]
        for f in input:
            gtdb_dir=os.path.dirname(f)
            for m in ["bac120", "ar122"]:
                summary=opj(gtdb_dir, "gtdbtk.{}.summary.tsv".format(m))
                if os.path.exists(summary):
                    summaries.append(summary)
        df=concatenate(summaries)
        df.to_csv(output.summary, sep="\t")

##### annotate bins #####

rule barrnap:
    """
    Identify rRNA genes in genome bins
    """
    input:
        tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv"),
        gtdbtk=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "gtdbtk", "done")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "barrnap", "rRNA.gff")
    log:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "barrnap", "log")
    conda:
        "../envs/barrnap.yml"
    params:
        indir=lambda wildcards, input: os.path.dirname(input.tsv),
        gtdbtk_dir=lambda wildcards, input: os.path.dirname(input.gtdbtk)
    resources:
        runtime=lambda wildcards, attempt: attempt**2*30
    threads: 1
    shell:
        """
        bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
        if [ $bins == 0 ] ; then
            touch {output}
        else
            cat {params.gtdbtk_dir}/gtdbtk.*.summary.tsv | cut -f1 -d ';' | grep -v "user_genome" | \
                while read line;
                do
                    d=$(echo -e "$line" | cut -f2)
                    g=$(echo -e "$line" | cut -f1)
                    if [ "$d" == "d__Bacteria" ]; then
                        k="bac"
                    else
                        k="arc"
                    fi
                    barrnap --kingdom $k --quiet {params.indir}/$g.fa | \
                        egrep -v "^#" | sed "s/$/;genome=$g/g" >> {output}
                done
        fi              
        """

rule count_rRNA:
    input:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}",
            "barrnap", "rRNA.gff")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}",
            "barrnap", "rRNA.types.tsv")
    script:
        "../scripts/binning_utils.py"

rule trnascan_bins:
    #TODO: Run with general model if neither bacteria nor archaea
    """
    Identify tRNA genes in genome bins
    """
    input:
        tsv=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "summary_stats.tsv"),
        gtdbtk=opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "gtdbtk", "done")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "tRNAscan", "tRNA.tsv")
    log:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", "tRNAscan", "tRNA.log")
    params:
        indir=lambda wildcards, input: os.path.dirname(input.tsv),
        gtdbtk_dir=lambda wildcards, input: os.path.dirname(input.gtdbtk)
    resources:
        runtime=lambda wildcards, attempt: attempt*30
    threads: 4
    conda:
        "../envs/annotation.yml"
    shell:
        """
        bins=$(wc -l {input.tsv} | cut -f1 -d ' ')
        if [ $bins == 0 ] ; then
            touch {output}
        else
            echo -e "Name\ttRNA#\ttRNA_Begin\ttRNA_End\ttRNA_type\tAnti_Codon\tIntron_Begin\tIntron_End\tInf_Score\tNote\tBin_Id" > {output}
            cat {params.gtdbtk_dir}/gtdbtk.*.summary.tsv | cut -f1 -d ';' | grep -v "user_genome" | \
                while read line;
                do
                    d=$(echo -e "$line" | cut -f2)
                    g=$(echo -e "$line" | cut -f1)
                    if [ "$d" == "d__Bacteria" ]; then
                        model="-B"
                    else
                        model="-A"
                    fi
                    tRNAscan-SE $model --quiet --thread {threads} \
                        {params.indir}/$g.fa | tail -n +4 | sed "s/$/\t$g/g" >> {output}
                done
        fi          
        """

rule count_tRNA:
    input:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", 
            "tRNAscan", "tRNA.tsv")
    output:
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", 
            "tRNAscan", "tRNA.types.tsv"),
        opj(config["paths"]["results"], "binning", "{binner}", "{group}", "{l}", 
            "tRNAscan", "tRNA.total.tsv")
    script:
        "../scripts/binning_utils.py"

rule aggregate_bin_annot:
    input:
        trna=expand(opj(config["paths"]["results"], "binning", "{binner}", 
                        "{group}", "{l}", "tRNAscan", "tRNA.total.tsv"),
                    binner=get_binners(config),
                    group=assemblies.keys(),
                    l=config["min_contig_length"]),
        rrna=expand(opj(config["paths"]["results"], "binning", "{binner}",
                        "{group}", "{l}", "barrnap", "rRNA.types.tsv"),
                    binner=get_binners(config),
                    group=assemblies.keys(),
                    l=config["min_contig_length"])
    output:
        trna=opj(config["paths"]["results"], "report", "bin_annotation", "tRNA.total.tsv"),
        rrna=opj(config["paths"]["results"], "report", "bin_annotation", "rRNA.types.tsv")
    run:
        df=concatenate(input.trna)
        df.to_csv(output.trna, sep="\t", index=True)
        df=concatenate(input.rrna)
        df.to_csv(output.rrna, sep="\t", index=True)
