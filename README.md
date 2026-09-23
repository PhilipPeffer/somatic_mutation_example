# somatic_mutation_example

Tumor-normal whole-genome somatic variant calling, from FASTQ to VCF, with **Sentieon** on a single **AWS EC2 spot instance**. Everything is driven from this repository in a GitHub Codespace, with no workflow orchestrator.

The example pair comes from SRA:

| role   | run          |
|--------|--------------|
| tumor  | `SRR7890893` |
| normal | `SRR7890943` |

**➡ Step-by-step guide: [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md)**

## The dataset: SEQC2 HCC1395 / HCC1395BL

The two runs are whole-genome sequencing of a tumor/normal cell-line pair from the **SEQC2 Somatic Mutation Working Group**. SEQC2 is the second phase of the FDA-led Sequencing Quality Control consortium. Its goal was a community reference for measuring how accurately somatic mutations are detected.

| sample | what it is |
|---|---|
| **HCC1395** (tumor) | triple-negative breast carcinoma cell line |
| **HCC1395BL** (normal) | B-lymphoblastoid cell line from the **same donor**, i.e. the matched germline normal |

What the consortium did:
- Grew each line as a single large batch and made it commercially available, so any lab can sequence the identical material.
- Sequenced the pair many times: several sequencing centres, platforms and library preparations, WGS and WES, and a range of coverages and tumor purities (tumor diluted into normal).
- Combined those replicates with several independent callers into a **high-confidence somatic truth set** for GRCh38. It has on the order of 40,000 SNVs and 2,000 indels inside defined high-confidence regions. Check the release notes for the exact current numbers.

The raw data are public: NCBI SRA BioProject PRJNA489865, mirrored on AWS Open Data. The truth set is on the NCBI FTP site under `ReferenceSamples/seqc/Somatic_Mutation_WG/`.

Key papers:
- Fang L.T. *et al.*, "Establishing community reference samples, data and call sets for benchmarking cancer mutation detection using whole-genome sequencing", *Nature Biotechnology* 39, 1151–1160 (2021).
- Xiao W. *et al.*, "Toward best practice in cancer mutation detection with whole-genome and whole-exome sequencing", *Nature Biotechnology* 39, 1141–1150 (2021).

### Why this dataset suits a learning example

- **Open access, no data-use agreement.** Real tumor/normal WGS usually comes from patients and sits behind controlled access (dbGaP, EGA). These are consented, commercially available cell lines, so anyone can download the reads and share results.
- **A known answer.** With the truth set you can measure precision and recall of the calls, instead of just counting variants. That makes it easy to see what each step changes: BQSR, the panel of normals, the contamination and orientation filters, or TNhaplotyper2 vs TNscope.
- **Realistic scale and difficulty.** This is a full 30x-plus WGS pair with a highly rearranged, aneuploid cancer genome. It exercises the same compute, storage and cost decisions as a production run, not a toy chr20 subset.
- **A true matched normal.** Both lines come from one individual, which is the design that tumor-normal callers assume.
- **Comparable to published work.** The SEQC2 papers and many tool benchmarks report results on this pair, so your numbers have something to be checked against.
- **Replicates for reproducibility.** Other SEQC2 runs of the same samples, from other centres, platforms and coverages, can be dropped into `config/samples.tsv` to study how results vary by site and platform.
- **Cheap to fetch on AWS.** The runs are in the SRA Open Data bucket in us-east-1, so the pipeline downloads them in-region with no transfer charges.

Caveats to keep in mind when generalising:
- A cell line is essentially 100% tumor, with no infiltrating normal cells, and it's fresh DNA rather than FFPE. Clinical samples with low purity or formalin damage are harder.
- The truth set only covers its high-confidence regions. Restrict any benchmark to those regions.
- Long-term culture adds mutations over time, so the truth set is specific to the distributed cell batches.

## Quick start (in the Codespace)

```bash
# 0. Sentieon trial license in hand, AWS credentials configured (walkthrough steps 1–2)
# 1. Set BUCKET in config/pipeline.env and commit
pixi run -e cloud aws-setup                       # one time: bucket, IAM, security group, launch template
set -a; source config/pipeline.env; set +a
pixi run -e cloud aws s3 cp my.lic "$SENTIEON_LICENSE_S3"
pixi run -e cloud dry-run                         # see every command, no cost
pixi run -e cloud launch --smoke                  # ~30 min, ~$1: validates everything on a subset
pixi run -e cloud launch                          # full run, ~7–12 h, roughly $8–20 on spot
pixi run -e cloud status                          # progress; rerun `launch` to resume after a spot interruption
pixi run -e cloud fetch-results                   # VCFs, metrics, MultiQC report, run manifest → results/
```

## Pipeline

```
SRA (AWS Open Data) → FASTQ → Sentieon BWA-MEM + sort → metrics + dedup → BQSR
                   → TNhaplotyper2 (Mutect2-equivalent) + OrientationBias + ContaminationModel → TNfilter
                   → PASS somatic SNV/indel VCF + QC report + run_manifest.json
```

- Reference: GRCh38 (Broad hg38 bundle). The public resources are gnomAD for germline AF, the 1000G panel of normals, and dbSNP, Mills and known indels for BQSR. All are pinned with MD5s in [`config/references_hg38.tsv`](config/references_hg38.tsv).
- Each step checkpoints to S3. A replacement spot instance resumes where the last one stopped.
- The instance terminates itself when the run finishes, fails, or hits a hard runtime limit.

## Repository layout

| path | purpose |
|---|---|
| `config/pipeline.env` | all run settings: bucket, instance types, Sentieon version and license, caller, RUN_ID |
| `config/samples.tsv` | tumor and normal read groups (SRA accession or S3 FASTQ) |
| `config/references_hg38.tsv` | reference files, source URLs, expected MD5s |
| `aws/` | Codespace-side scripts: `setup_aws.sh`, `launch.sh`, `status.sh`, `logs.sh`, `fetch_results.sh`, `teardown.sh`; EC2 `user_data.sh.tpl`; IAM policies |
| `pipeline/run_pipeline.sh` | the pipeline, run on the instance; the step implementations are in `pipeline/steps/` |
| `pipeline/lib.sh` | checkpointing, S3 helpers, sample sheet, spot-interruption watcher, dry-run stubs |
| `pixi.toml` / `pixi.lock` | pinned tool environments: `cloud` for the Codespace, `pipeline` for the EC2 instance. The default environment keeps the original exploratory GATK toolset |
| `.devcontainer/` | Codespace definition (installs pixi and the environments) |
| `docs/WALKTHROUGH.md` | the full guide: setup, running, monitoring, costs, reproducibility, troubleshooting |
