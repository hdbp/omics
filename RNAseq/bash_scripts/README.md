# RNA-seq Bash Scripts

Three modular Bash scripts covering the core steps of a bulk RNA-seq pipeline: adapter trimming, genome alignment, and transcript quantification. Each script auto-detects paired-end vs. single-end layout per sample, supports resuming interrupted runs, and accepts a `--dry-run` flag for safe validation before execution.

## Pipeline overview

```
Raw FASTQs
    │
    ▼
fastp_trimming.sh       # adapter/quality trimming → ./trimmed/
    │
    ├──► 01_star_alignment.sh   # splice-aware genome alignment → ./bam/
    │
    └──► salmon_quantify.sh     # quasi-mapping quantification → ./salmon/
```

STAR alignment and Salmon quantification can be run independently on the same trimmed FASTQs.

---

## Dependencies

| Tool | Purpose |
|------|---------|
| [fastp](https://github.com/OpenGEN/fastp) | Read trimming and QC |
| [STAR](https://github.com/alexdobin/STAR) | Splice-aware genome alignment |
| [samtools](http://www.htslib.org/) | BAM indexing (used by STAR script) |
| [salmon](https://salmon.readthedocs.io/) | Transcript-level quantification |
| [refgenie](http://refgenie.databio.org/) | Genome asset management (optional — can supply paths directly) |

---

## Scripts

### `fastp_trimming.sh`

Trims adapter sequences and low-quality bases from all FASTQ files in a directory using [fastp](https://github.com/OpenGEN/fastp).

**Key behaviours:**
- Auto-detects paired-end vs. single-end per sample based on R2 file presence
- Filters reads shorter than 20 bp (`--length_required 20`)
- Trims poly-G tails (`--trim_poly_g`)
- Auto-detects adapters for paired-end data
- Skips completed samples unless `--force` is passed
- Writes per-sample JSON and HTML QC reports alongside trimmed FASTQs

**Usage:**
```bash
bash fastp_trimming.sh [options]

# Minimal — processes ./fastq/, writes to ./trimmed/
bash fastp_trimming.sh

# Custom directories
bash fastp_trimming.sh --fastq-dir /data/fastq --out-dir /data/trimmed --threads 16

# Preview commands without running
bash fastp_trimming.sh --dry-run

# Re-run samples that already have output
bash fastp_trimming.sh --force
```

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--fastq-dir` | `./fastq` | Input FASTQ directory |
| `--out-dir` | `./trimmed` | Output directory for trimmed reads |
| `--log-dir` | `./logs` | Directory for per-sample logs |
| `--r1-suffix` | `_R1_001.fastq.gz` | R1 filename suffix |
| `--r2-suffix` | `_R2_001.fastq.gz` | R2 filename suffix |
| `--threads` | `nproc - 4` | Number of threads |
| `--dry-run` | — | Print commands without executing |
| `--force` | — | Overwrite existing outputs |

**Outputs per sample:**
```
trimmed/
├── <prefix>_R1_001.fastq.gz
├── <prefix>_R2_001.fastq.gz   # paired-end only
├── <prefix>_fastp.json
└── <prefix>_fastp.html
logs/
└── <prefix>.fastp.<timestamp>.log
```

---

### `01_star_alignment.sh`

Aligns trimmed reads to a reference genome using [STAR](https://github.com/alexdobin/STAR) in two-pass mode and generates coordinate-sorted BAMs and gene count tables.

**Key behaviours:**
- Two-pass STAR alignment (`--twopassMode Basic`) for improved splice junction detection
- Auto-detects paired-end vs. single-end per sample
- Automatically decompresses `.gz` GTF files
- Detects and corrects UCSC ↔ Ensembl chromosome naming mismatches (e.g. `chrM` ↔ `MT`)
- Resolves genome index and GTF via [refgenie](http://refgenie.databio.org/) by default; paths can also be supplied directly
- Generates gene count tables (`ReadsPerGene.out.tab`) alongside BAMs
- Skips completed samples (existing BAM + BAI) unless `--force` is passed
- Sample names are built from metadata columns: `{celltype}-{genotype}-{id}`

**Usage:**
```bash
bash 01_star_alignment.sh [options]

# Minimal — refgenie resolves mm10 STAR index and GTF automatically
bash 01_star_alignment.sh --refgenie-genome mm10

# Supply genome resources directly (no refgenie required)
bash 01_star_alignment.sh --genome-dir /idx/mm10 --gtf /ref/mm10.gtf

# Custom FASTQ directory and metadata
bash 01_star_alignment.sh --fastq-dir ./trimmed --metadata ./metadata/metadata.txt

# Preview, then force re-run
bash 01_star_alignment.sh --dry-run
bash 01_star_alignment.sh --force
```

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--fastq-dir` | `./fastq` | Input FASTQ directory |
| `--metadata` | `./metadata/metadata.txt` | Tab-separated sample metadata |
| `--genome-dir` | *(refgenie)* | Path to STAR genome index |
| `--gtf` | *(refgenie)* | Path to GTF annotation file |
| `--refgenie-genome` | `mm10` | Genome key for refgenie lookup |
| `--out-dir` | `./bam` | Output directory for BAMs |
| `--log-dir` | `./logs` | Directory for per-sample logs |
| `--threads` | `nproc - 4` | Number of threads |
| `--col-prefix` | `1` | Metadata column: FASTQ prefix |
| `--col-celltype` | `8` | Metadata column: cell type |
| `--col-genotype` | `9` | Metadata column: genotype |
| `--col-id` | `11` | Metadata column: sample ID |
| `--dry-run` | — | Print STAR command without executing |
| `--verbose` | — | Log the exact STAR command to the sample log |
| `--force` | — | Remove existing outputs and re-run |

**Outputs per sample:**
```
bam/
└── <celltype>-<genotype>-<id>/
    ├── Aligned.sortedByCoord.out.bam
    ├── Aligned.sortedByCoord.out.bam.bai
    └── ReadsPerGene.out.tab
logs/
└── <celltype>-<genotype>-<id>.star.<timestamp>.log
```

**Metadata format (tab-separated, header on row 1):**

Column positions are configurable via `--col-*` options. Default mapping:

| Column | Content | Example |
|--------|---------|---------|
| 1 | FASTQ file prefix | `sample_001` |
| 8 | Cell type | `B`, `CD4`, `CD8` |
| 9 | Genotype | `WT`, `cTKO` |
| 11 | Sample ID | `2M`, `1F` |

Output sample name example: `B-WT-2M`

---

### `salmon_quantify.sh`

Quantifies transcript abundance from trimmed FASTQs using [Salmon](https://salmon.readthedocs.io/) quasi-mapping.

**Key behaviours:**
- Auto-detects paired-end vs. single-end per sample
- Library type auto-detected (`--libType A`)
- GC bias correction applied for paired-end samples (`--gcBias`)
- Validates mappings by default (`--validateMappings`)
- Resolves salmon index via [refgenie](http://refgenie.databio.org/) by default; index path can be supplied directly
- Sample metadata lookup maps FASTQ prefix → sample name
- Skips completed samples (existing `quant.sf`) unless `--force` is passed

**Usage:**
```bash
bash salmon_quantify.sh [options]

# Minimal — reads ./trimmed/, refgenie resolves mm10_primary salmon index
bash salmon_quantify.sh

# Supply index directly (no refgenie required)
bash salmon_quantify.sh --salmon-index /path/to/salmon_index

# Custom FASTQ directory and metadata
bash salmon_quantify.sh --fastq-dir ./trimmed --metadata ./metadata/metadata.txt

# Preview, then force re-run
bash salmon_quantify.sh --dry-run
bash salmon_quantify.sh --force
```

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--fastq-dir` | `./trimmed` | Input FASTQ directory |
| `--metadata` | `./metadata/metadata.txt` | Tab-separated sample metadata |
| `--salmon-index` | *(refgenie)* | Path to salmon index |
| `--refgenie-genome` | `mm10_primary` | Genome key for refgenie lookup |
| `--out-dir` | `./salmon` | Output directory for quantification results |
| `--log-dir` | `./logs` | Directory for per-sample logs |
| `--threads` | `nproc - 4` | Number of threads |
| `--col-prefix` | `1` | Metadata column: FASTQ prefix |
| `--col-celltype` | `8` | Metadata column: cell type |
| `--col-genotype` | `9` | Metadata column: genotype |
| `--col-id` | `11` | Metadata column: sample ID |
| `--dry-run` | — | Print salmon command without executing |
| `--force` | — | Remove existing outputs and re-run |

**Outputs per sample:**
```
salmon/
└── <celltype>-<genotype>-<id>/
    └── quant.sf
logs/
└── <celltype>-<genotype>-<id>.salmon.<timestamp>.log
```

---

## Recommended directory layout

```
project/
├── fastq/                    # raw FASTQs
├── trimmed/                  # fastp output
├── bam/                      # STAR output
├── salmon/                   # Salmon output
├── metadata/
│   └── metadata.txt          # tab-separated sample sheet
├── logs/                     # per-sample logs from all steps
└── bash_scripts/
    ├── fastp_trimming.sh
    ├── 01_star_alignment.sh
    └── salmon_quantify.sh
```

Run `--help` on any script for the full option list:
```bash
bash fastp_trimming.sh --help
bash 01_star_alignment.sh --help
bash salmon_quantify.sh --help
```
