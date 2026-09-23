# Walkthrough: tumor-normal WGS, FASTQ → somatic VCF, with Sentieon on an AWS spot instance

This guide takes you from an empty AWS account to a filtered somatic VCF for the pair

| role   | SRA run      | notes |
|--------|--------------|-------|
| tumor  | `SRR7890893` | ~80 GB `.sra` |
| normal | `SRR7890943` | ~67 GB `.sra` |

These runs appear to be part of the SEQC2 somatic reference study: breast cancer line HCC1395 and matched normal HCC1395BL. Check the run metadata on the SRA page before relying on that.

Everything runs from this repository in a GitHub Codespace. There's no workflow orchestrator: one bash pipeline runs top to bottom on one EC2 spot instance. Each step checkpoints to S3, so a spot interruption costs at most one step.

---

## Contents

0. [How it works](#0-how-it-works)
1. [Get a Sentieon trial license](#1-get-a-sentieon-trial-license)
2. [Open the Codespace and connect AWS](#2-open-the-codespace-and-connect-aws)
3. [Configure the run](#3-configure-the-run)
4. [One-time AWS setup](#4-one-time-aws-setup)
5. [Upload the license](#5-upload-the-license)
6. [Dry runs (no cost)](#6-dry-runs-no-cost)
7. [Smoke test (~$1)](#7-smoke-test-1)
8. [Full run](#8-full-run)
9. [Monitoring, spot interruptions and resuming](#9-monitoring-spot-interruptions-and-resuming)
10. [Results](#10-results)
11. [Costs and cleanup](#11-costs-and-cleanup)
12. [Reproducibility](#12-reproducibility)
13. [Pipeline steps in detail](#13-pipeline-steps-in-detail)
14. [Customising](#14-customising)
15. [Troubleshooting](#15-troubleshooting)

---

## 0. How it works

```
 GitHub Codespace (control plane)                 AWS us-east-1
 ───────────────────────────────                  ─────────────────────────────────────────────
 pixi run -e cloud aws-setup   ──────────────▶    S3 bucket, IAM role, security group, launch template
 pixi run -e cloud launch      ── git archive ─▶  s3://BUCKET/code/<git-sha>.tar.gz
                               ── create-fleet ▶  1 spot instance (cheapest available of ~7 types)
                                                   │ user-data: NVMe RAID0 → /scratch, pixi env,
                                                   │            pipeline/run_pipeline.sh
                                                   │   0 Sentieon + license
                                                   │   1 GRCh38 bundle ◀── public Broad/GATK buckets (cached in S3)
                                                   │   2 FASTQ         ◀── s3://sra-pub-run-odp (AWS Open Data)
                                                   │   3 align  4 dedup  5 BQSR  6 call  7 report
                                                   │   each step → s3://BUCKET/runs/<RUN_ID>/checkpoints/*.done
                                                   └─ uploads logs, terminates itself
 pixi run -e cloud status / logs / fetch-results ◀─ s3://BUCKET/runs/<RUN_ID>/
```

Design choices, and why:

- **Region `us-east-1`.** AWS mirrors the SRA runs there as Open Data. Downloads are fast, there are no data-transfer charges, and spot capacity is deep.
- **Spot instances with local NVMe.** The candidate types are `c6id`/`m6id`/`r6id`/`m5d`/`c5ad`, 12xlarge or 16xlarge (48–64 vCPU). Sentieon scales well with cores. The instance-store disks are included in the price and are faster than EBS, so there's no large EBS volume to pay for.
- **`price-capacity-optimized` EC2 Fleet.** AWS picks the candidate type with the lowest interruption risk at a low price.
- **S3 is the source of truth.** The instance is disposable. The reference bundle and converted FASTQs are cached in your bucket and reused by later runs.
- **Access through SSM Session Manager.** No SSH keys, no open ports.

---

## 1. Get a Sentieon trial license

1. Request a free trial at <https://www.sentieon.com/> (the "Free Trial" link on the site, or email `support@sentieon.com`).
2. **Tell them where it will run:** *"AWS EC2 spot instances in us-east-1. Instances are replaced for every run, so hostname, IP and MAC address change each time."* A node-locked license tied to one machine won't work here.
3. Sentieon will send one of these:
   - **A license file** (`*.lic`) that works on cloud instances → step 5 uploads it to S3.
   - **A license server address** (`host:port`), sometimes with extra authentication variables (`SENTIEON_AUTH_MECH`, `SENTIEON_AUTH_DATA`) → set these in `config/pipeline.env`.
4. Note the **software version** they recommend. The repo defaults to `202503.04`, the newest release in Sentieon's public bucket as of September 2026.

The pipeline supports either license form. With a license server it runs `sentieon licclnt ping` before doing any work.

---

## 2. Open the Codespace and connect AWS

### 2a. Codespace

On GitHub: **Code → Codespaces → Create codespace on `aws_sentieon`**.

The dev container installs pixi and runs `pixi install` for the default and `cloud` environments. Check it worked:

```bash
pixi run -e cloud aws --version        # aws-cli/2.x
pixi task list -e cloud                # aws-setup, launch, status, logs, fetch-results, teardown, dry-run, lint
```

> The `cloud` environment holds the tools the Codespace needs (AWS CLI, jq, shellcheck). The `pipeline` environment holds the tools the EC2 instance needs (samtools, bcftools, htslib, sra-tools, pigz, MultiQC, AWS CLI). Both are pinned exactly in `pixi.lock`. Sentieon itself isn't a conda package; it's installed from its release tarball at a pinned version.

### 2b. AWS credentials

**Option A (recommended): IAM Identity Center (SSO).** You get short-lived credentials and nothing stored in GitHub.

```bash
pixi run -e cloud aws configure sso      # follow the prompts; name the profile e.g. "wgs"
export AWS_PROFILE=wgs
pixi run -e cloud aws sts get-caller-identity
```

**Option B: an IAM user's access keys as Codespaces secrets.**
In GitHub → **Settings → Codespaces → Secrets**, add `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, scoped to this repository. Restart the Codespace so they're picked up. Never commit keys.

The identity needs permissions to:
- manage one S3 bucket;
- create an IAM role and instance profile, including `iam:PassRole` on that role;
- use EC2 launch templates, fleets, security groups and describe calls;
- read `ssm:GetParameter` (to look up the AMI);
- read Service Quotas (optional).

An account admin can run the one-time `aws-setup` (step 4). After that, a narrower identity is enough to launch and monitor runs.

---

## 3. Configure the run

Edit `config/pipeline.env`. You only need to change one setting:

```bash
BUCKET=yourname-sentieon-wgs-123456789012   # globally unique; account ID suffix is a good habit
```

Everything else has working defaults:
- `AWS_REGION=us-east-1`.
- The instance-type list.
- `SENTIEON_VERSION`.
- `SENTIEON_LICENSE_S3=s3://$BUCKET/license/sentieon.lic`, or `SENTIEON_LICENSE_SERVER=host:port`.
- `CALLER=tnhaplotyper2`.
- `RUN_ID=seqc2_wgs_SRR7890893_vs_SRR7890943_v1`.

`config/samples.tsv` already contains the pair:

```
#sample            role    source           rg_id       library     platform
TUMOR_SRR7890893   tumor   sra:SRR7890893   SRR7890893  SRR7890893  ILLUMINA
NORMAL_SRR7890943  normal  sra:SRR7890943   SRR7890943  SRR7890943  ILLUMINA
```

**Commit your changes.** `launch` ships a `git archive` of `HEAD` to the instance and refuses to run with uncommitted changes, so every result is tied to a commit. The config file holds no secrets.

```bash
git add config/pipeline.env && git commit -m "Configure bucket for WGS run" && git push
```

---

## 4. One-time AWS setup

```bash
pixi run -e cloud aws-setup
```

This is idempotent, so it's safe to re-run. It creates:

| resource | details |
|---|---|
| S3 bucket | private (public access blocked), SSE-S3 encrypted. Lifecycle rules expire `intermediate/` after 14 days and abort stale multipart uploads |
| IAM role + instance profile `sentieon-wgs-node-*` | read/write to **this bucket only**, plus `AmazonSSMManagedInstanceCore` for Session Manager |
| security group `sentieon-wgs-node-sg` | **no inbound rules**; egress only |
| launch template `sentieon-wgs-node` | Amazon Linux 2023. The AMI ID is resolved now and pinned. IMDSv2 required, encrypted 60 GB gp3 root, *shutdown = terminate* |
| service-linked roles | for EC2 Spot/Fleet, if they don't exist yet |

It also prints your **spot vCPU quota**. New accounts often start below the 64 vCPUs one 16xlarge needs. If it warns you, request an increase; this is often approved within minutes to hours:

```bash
set -a; source config/pipeline.env; set +a      # region + bucket for ad-hoc aws commands
pixi run -e cloud aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-34B43A08 --desired-value 128
```

The setup uses the **default VPC**, whose subnets have internet access. It needs internet to reach GitHub (pixi binary), conda-forge/bioconda and the Broad/GATK reference buckets. If you have no default VPC, set `SUBNET_IDS` to subnets with a public IP or a NAT gateway.

---

## 5. Upload the license

The ad-hoc `aws` commands in this guide use `$BUCKET` and the region from your config. Load both into your shell once per terminal:

```bash
set -a; source config/pipeline.env; set +a
```

License file:

```bash
pixi run -e cloud aws s3 cp ~/Downloads/YourCompany_cloud.lic s3://$BUCKET/license/sentieon.lic
```

The bucket is private and only your instance role can read it. The license never goes into git; `.gitignore` excludes `*.lic`.

License server: set `SENTIEON_LICENSE_SERVER=host:port` in `config/pipeline.env`. Set `SENTIEON_LICENSE_S3=""`, plus any `SENTIEON_AUTH_*` values Sentieon gave you. Then commit.

---

## 6. Dry runs (no cost)

Neither command contacts AWS or needs Sentieon.

```bash
pixi run -e cloud dry-run              # prints every pipeline command in order, with resolved paths
pixi run -e cloud launch --dry-run     # prints the rendered user-data and the create-fleet request
pixi run -e cloud lint                 # shellcheck on all scripts
```

Read through the `dry-run` output once. It shows exactly what will run on the instance.

---

## 7. Smoke test (~$1)

Before paying for a full WGS run, run the whole pipeline on a subset to check license, IAM, S3, spot capacity and every step:

- the first 2 M read pairs of each run;
- variant calling only on `chr22`;
- a 16-vCPU instance.

```bash
pixi run -e cloud launch --smoke
pixi run -e cloud status --smoke       # repeat every few minutes
pixi run -e cloud logs --smoke
pixi run -e cloud fetch-results --smoke
```

It takes about 30–45 minutes, mostly for downloading the two `.sra` files and building the reference cache. The reference cache is reused by the full run.

The smoke run uses `RUN_ID=<RUN_ID>_smoke` and its own FASTQ cache (`fastq/<run>/subsample_2000000/`), so it never mixes with the real run.

What to check in `results/<RUN_ID>_smoke/`:
- `logs/pipeline.log` ends with `PIPELINE FINISHED OK`;
- `vcf/*.tnhaplotyper2.pass.vcf.gz` exists (with 2 M read pairs expect only a handful of calls);
- `report/run_manifest.json` shows the Sentieon version and instance type.

If the license is the problem, the log fails within the first few minutes with a Sentieon license error. See [Troubleshooting](#15-troubleshooting).

---

## 8. Full run

```bash
pixi run -e cloud launch
```

Output:

```
Launched i-0abc... (c6id.16xlarge, spot) for run seqc2_wgs_SRR7890893_vs_SRR7890943_v1
```

Close the Codespace if you like; the instance works on its own and terminates itself at the end. It has two safety nets:
- it also terminates itself on failure;
- whatever happens, it terminates after `MAX_RUNTIME_HOURS=36`.

**Rough timeline** on a 64-vCPU instance. These are estimates, not measurements: they depend on coverage, which is roughly 50x tumor and 45x normal judging by the `.sra` sizes, and on the instance type you get.

| step | approx. time |
|---|---|
| boot, NVMe setup, pixi env, Sentieon install | 5–10 min |
| reference bundle (first run only, then cached) | 5–10 min |
| SRA → FASTQ.gz, both samples (first run only, then cached) | 1–2 h |
| alignment, both samples | 2.5–4 h |
| metrics + dedup, both | 40–60 min |
| BQSR + coverage, both | 30–45 min |
| TNhaplotyper2 + filters | 2–4 h |
| report | < 5 min |
| **total** | **~7–12 h** |

Actual per-step times are recorded in `logs/step_timings.tsv` and in the manifest.

---

## 9. Monitoring, spot interruptions and resuming

```bash
pixi run -e cloud status        # instance state, completed steps, timings, last log lines
pixi run -e cloud logs 200      # last 200 lines (the log syncs to S3 every ~2 min)
pixi run -e cloud logs --bootstrap   # boot log (NVMe, pixi install), useful if nothing else appears
```

**Live shell** (optional). Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) in the Codespace, then:

```bash
pixi run -e cloud aws ssm start-session --target i-0abc...
sudo tail -f /scratch/runs/<RUN_ID>/logs/pipeline.log
htop   # (dnf install -y htop) to watch CPU use
```

**Spot interruption.** AWS can reclaim a spot instance with 2 minutes' notice. The pipeline logs the notice and uploads its log. To resume:

```bash
pixi run -e cloud status        # confirm the instance is gone and see which steps finished
pixi run -e cloud launch        # same RUN_ID → completed steps are skipped
```

What a resumed run does and doesn't redo:
- Checkpoints are per step and per sample, e.g. `align_SRR7890893.done`. A relaunch pulls the outputs it needs from S3 and continues.
- Only the step that was running when the instance was reclaimed is redone.
- Converted FASTQs and the reference are never rebuilt.
- Relaunch from the same commit so the whole run comes from one code version. `launch` records the commit on every instance (tag `GitSha`), and the manifest records it too.

If spot capacity is scarce:
- add types to `INSTANCE_TYPES`;
- or set `SPOT_MAX_PRICE`;
- or retry later.

---

## 10. Results

```bash
pixi run -e cloud fetch-results            # add --bams to also download the BAMs (~200 GB)
```

`results/<RUN_ID>/`:

| path | contents |
|---|---|
| `vcf/<RUN_ID>.tnhaplotyper2.filtered.vcf.gz` | all candidate somatic calls, `FILTER` column set by TNfilter |
| `vcf/<RUN_ID>.tnhaplotyper2.pass.vcf.gz` (+ `.tbi`) | **final somatic SNVs/indels (`FILTER=PASS`)** |
| `vcf/<RUN_ID>.tnhaplotyper2.unfiltered.vcf.gz` | raw caller output |
| `vcf/<RUN_ID>.contamination.txt`, `*_segments.txt`, `*.orientation_priors.txt` | contamination estimate and filter inputs |
| `metrics/<sample>.*` | alignment, insert size, GC bias, base quality, duplication, WGS coverage (+ PDF plots) |
| `metrics/<RUN_ID>.*.bcftools_stats.txt` | VCF summary statistics |
| `report/<RUN_ID>.multiqc.html` | one-page QC report (open it in the browser) |
| `report/run_manifest.json` | git SHA, instance/AMI, tool versions, parameters, per-step timings, VCF checksum, call counts |
| `logs/` | full pipeline log, bootstrap logs, step timings |
| `config/` | the exact `pipeline.env`, `samples.tsv` (and smoke overrides) used |
| `bam/` (S3, or with `--bams`) | `<sample>.deduped.bam` (+ `.bai`) and BQSR tables |

Quick look:

```bash
pixi run -e pipeline bcftools view -H results/<RUN_ID>/vcf/<RUN_ID>.tnhaplotyper2.pass.vcf.gz | head
pixi run -e pipeline bcftools view -H -v snps   results/<RUN_ID>/vcf/*.pass.vcf.gz | wc -l
jq . results/<RUN_ID>/report/run_manifest.json
```

**QC to review:**
- mean coverage (`*.wgs_metrics.txt`);
- duplication rate (`*.dedup_metrics.txt`);
- insert size;
- estimated contamination (`contamination.txt`; it should be low for a cell line);
- the SNV:indel ratio and Ti/Tv in the bcftools stats.

If these runs are the SEQC2 HCC1395 pair, the SEQC2 consortium publishes a high-confidence somatic truth set. You can benchmark the PASS VCF against it with a tool such as `som.py` or `rtg vcfeval`. That's outside this pipeline.

---

## 11. Costs and cleanup

Estimates only. Spot prices move; check the EC2 console's *Spot Requests → Pricing history*.

| item | estimate |
|---|---|
| Sentieon | free (trial) |
| EC2 spot, 64 vCPU with NVMe, ~7–12 h at ~$1.0–1.6/h | **~$8–20** |
| smoke test | ~$0.5–1 |
| S3 storage after the run (FASTQ ~190 GB, BAMs ~200 GB, reference ~30 GB) | ~$10/month until deleted |
| data transfer | ~$0: SRA and S3 are in-region; `fetch-results` without BAMs is < 1 GB |

For comparison, the same instance on-demand costs about $3.2/h.

Cleanup:

```bash
pixi run -e cloud teardown                 # terminate this run's instance, if any is still running
pixi run -e cloud aws s3 rm --recursive s3://$BUCKET/fastq/            # re-creatable from SRA
pixi run -e cloud aws s3 rm --recursive s3://$BUCKET/runs/<RUN_ID>/bam/ # keep if you need the BAMs
pixi run -e cloud teardown --infra         # remove IAM role, SG, launch template (bucket is kept)
```

---

## 12. Reproducibility

What is pinned, and where:

| what | pinned by |
|---|---|
| pipeline code + config | git commit; `launch` ships a `git archive` of that commit, recorded as the `GitSha` tag and in the manifest |
| samtools / bcftools / htslib / sra-tools / MultiQC / AWS CLI | `pixi.lock` (`pixi install --frozen` on the instance); lock hash in the manifest |
| pixi itself | `PIXI_VERSION` in `config/pipeline.env` and `.devcontainer/Dockerfile` |
| Sentieon | `SENTIEON_VERSION`; the tarball is cached in `s3://$BUCKET/software/` so it stays available |
| reference + resources | URLs and **MD5s** in `config/references_hg38.tsv`, verified on download; cached in S3 with `md5sums.txt` |
| OS image | AMI resolved once by `aws-setup`, pinned in the launch template, recorded in the manifest |
| input data | SRA accessions; FASTQ MD5s stored next to the cached FASTQ and verified before alignment |
| alignment determinism | `bwa mem -K 10000000`: results don't depend on thread count or instance type |

To reproduce a run later:
1. Check out the `git_sha` from its `run_manifest.json`.
2. Keep the same `SENTIEON_VERSION`.
3. Launch with a new `RUN_ID`.

The only part that isn't pinned is the Sentieon license, which doesn't affect results.

---

## 13. Pipeline steps in detail

All commands are in `pipeline/steps/*.sh`, one short, commented file per step. `pixi run -e cloud dry-run` prints them fully expanded.

| # | step | Sentieon command | GATK/Picard equivalent |
|---|---|---|---|
| 0 | install + license | `sentieon licclnt ping` (server licenses) | — |
| 1 | reference | Broad hg38 v0 FASTA + bwa index (with `.alt`), dbSNP 138, Mills + known indels, af-only gnomAD, 1000G PON, small_exac_common_3 | GATK resource bundle |
| 2 | FASTQ | `fasterq-dump --split-3` → `pigz` (smoke test: `fastq-dump -X N`) | — |
| 3 | align, per read group | `sentieon bwa mem -K 10000000 -R @RG… \| sentieon util sort --sam2bam` | `bwa mem \| samtools sort` |
| 4 | metrics + dedup, per sample | `driver --algo MeanQualityByCycle/QualDistribution/GCBias/AlignmentStat/InsertSizeMetricAlgo`; `LocusCollector` + `Dedup` | CollectMultipleMetrics; MarkDuplicates |
| 5 | BQSR + coverage, per sample | `driver --algo QualCal -k dbSNP -k Mills -k known_indels --algo WgsMetricsAlgo` | BaseRecalibrator; CollectWgsMetrics |
| 6 | somatic calling | `driver -i T -q T.table -i N -q N.table --algo TNhaplotyper2 --germline_vcf gnomAD --pon PON --algo OrientationBias --algo ContaminationModel`, then `--algo TNfilter` | Mutect2 + LearnReadOrientationModel + GetPileupSummaries/CalculateContamination + FilterMutectCalls |
| 7 | report | `bcftools stats`, MultiQC, `run_manifest.json` | — |

Notes:
- The recalibration tables are applied on the fly (`-q`) during calling, so no second copy of each BAM is written.
- `TNhaplotyper2` is the default because it needs only public resources and matches the widely used GATK Mutect2 best practice.
- Sentieon's own `TNscope` caller is available with `CALLER=tnscope`. For WGS, Sentieon recommends using it with their machine-learning model: set `TNSCOPE_MODEL_S3`, plus any model-specific options in `TNSCOPE_ARGS`, as given in the model's documentation.
- Duplicates are *marked*, not removed.

---

## 14. Customising

- **Your own FASTQ:** upload it to S3 and use `s3://…/R1.fastq.gz,s3://…/R2.fastq.gz` as the `source` in `config/samples.tsv`.
- **Multiple lanes:** add one row per lane or read group with the same `sample` and a unique `rg_id`. Lanes are aligned separately and merged at dedup.
- **Different pair:** edit `config/samples.tsv` and use a new `RUN_ID`. The reference cache is shared.
- **Bigger or smaller instances:** edit `INSTANCE_TYPES`. Keep types with ≥ 1.9 TB of local NVMe for WGS; otherwise `/scratch` falls back to the 60 GB root volume, which is far too small.
- **Other regions:** possible, but the SRA download then crosses regions and you pay the transfer cost.

---

## 15. Troubleshooting

| symptom | cause / fix |
|---|---|
| `launch`: *no spot capacity granted* / `MaxSpotInstanceCountExceeded` / `VcpuLimitExceeded` | spot vCPU quota too low (step 4), or no capacity right now. Add instance types, retry later, or set `SPOT_MAX_PRICE` |
| `status` shows no instance and no pipeline log | read `pixi run -e cloud logs --bootstrap`. Usual causes: no internet from the subnet (use the default VPC or a NAT), or a pixi download error |
| log: *Please set environment variable SENTIEON_LICENSE…* or a license error | license missing or wrong. Check `SENTIEON_LICENSE_S3` points to the uploaded file, or the server settings. Ask Sentieon support whether the license allows cloud/ephemeral hosts |
| log: *cannot reach Sentieon license server* | wrong `host:port`, missing `SENTIEON_AUTH_*` values, or egress blocked |
| log: *MD5 mismatch* for a reference file | transient download corruption. Relaunch; the reference step retries because its `_READY` marker was never written |
| log: *FASTQ checksum mismatch* | corrupt FASTQ cache. Delete `s3://$BUCKET/fastq/<rg>/` and relaunch |
| `No space left on device` | the instance had no NVMe (a type outside the list), or the input is much bigger than expected. Use types with more instance storage (e.g. `*.24xlarge`, `i4i`) |
| `launch`: *uncommitted changes* | commit (recommended), or pass `--allow-dirty` for experiments; the SHA is then tagged `-dirty-<timestamp>` |
| want to debug a failed instance | set `KEEP_INSTANCE_ON_FAILURE=1`, commit, relaunch, connect with SSM. Run `teardown` when done |
