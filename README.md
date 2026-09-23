# somatic_mutation_example

Tumor-normal whole-genome somatic variant calling, from FASTQ to VCF, with **Sentieon** on a single **AWS EC2 spot instance**. Everything is driven from this repository in a GitHub Codespace, with no workflow orchestrator.

The example pair comes from SRA:

| role   | run          |
|--------|--------------|
| tumor  | `SRR7890893` |
| normal | `SRR7890943` |

**➡ Step-by-step guide: [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md)**

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
