# Multiomics Analysis — H1 Histone Epigenetic Regulation

Reproducible R analysis pipeline integrating **RNA-seq**, **ATAC-seq**, and **ChIP-seq** to characterise the epigenetic consequences of H1 histone loss in immune cells (cTKO vs WT).

Based on data from:

> Willcockson MA, Healton SE, Weiss CN, et al. **H1 histones control the epigenetic landscape by local chromatin compaction.** *Nature* 589, 293–298 (2021). https://doi.org/10.1038/s41586-020-3032-z

GEO Accession: GSE141187
---

## Workspace structure

Items marked 🚫 are excluded from version control (see `.gitignore`) and must be downloaded or generated locally. Items marked ✅ are tracked.

```
multiomics/
│
├── ATACseq/
│   ├── data/                          🚫 Sorted, deduplicated BAM files + .bai indices
│   │                                      16 samples (CD4, CD8, B-cell × WT/cTKO)
│   ├── metadata/
│   │   └── metadata.txt               ✅ Sample sheet: genewizName, cell type, genotype,
│   │                                      organ, BAM filename
│   └── R/
│       ├── 00_config.R                ✅ Loads metadata, builds BAM↔sample table, creates output dirs
│       ├── 01_ATAC_analysis.R         ✅ csaw window counting, TMM/loess/quantile normalisations,
│       │                                  IP-vs-input enrichment filtering, differential testing
│       ├── 02_ATAC_differential.R     ✅ MA and volcano plots coloured by direction
│       ├── 03_ATAC_annotation.R       ✅ ChIPseeker peak annotation, genomic feature bar charts
│       ├── 04_ATAC_go.R               ✅ GO:BP enrichment on gained-accessibility promoters
│       ├── 05_ATAC_metagene.R         ✅ metagene2 coverage profiles at differential peaks
│       ├── 06_ATAC_nrl_profiles.R     ✅ Fragment-size distributions and nucleosome repeat
│       │                                  length (NRL) estimation via FFT
│       └── helper_functions/
│           └── helpers.R              ✅ csaw helpers: pool_input_at(), fit_and_merge_dual()
│
├── ChIPseq/
│   ├── data/                          🚫 Sorted BAM files + .bai indices
│   │                                      H3K27me3, H3K36me2, Input × WT/cTKO (12 samples)
│   ├── metadata/
│   │   └── metadata.txt               ✅ Sample sheet: BAM path, sample name, condition,
│   │                                      replicate, assay
│   └── R/
│       ├── 00_config.R                ✅ Loads metadata, splits IP/Input tables, creates output dirs
│       ├── 01_ChIPseq_norm_comparison.R  ✅ Side-by-side enrichment distribution, MA plots, and
│       │                                     norm-factor panels for TMM / loess / quantile
│       ├── 02_ChIPseq_differential.R     ✅ Differential binding with chosen normalisation,
│       │                                     gene-level counts via regionCounts()
│       ├── 03_ChIPseq_annotation.R       ✅ ChIPseeker peak annotation, UpSet plots of
│       │                                     mark overlap across conditions
│       ├── 04_ChIPseq_breadth.R          ✅ H3K36me2 domain breadth analysis
│       ├── 05_ChIPseq_domain_expansion.R ✅ H3K36me2 expansion into H3K27me3 territory
│       ├── 05b_ChIPseq_domain_contraction.R  ✅ H3K27me3 contraction and reciprocal H3K36me2 gain
│       ├── 06_ChIPseq_visualization.R   ✅ Gviz genome-browser track plots
│       ├── 07_ChIPseq_metagene_h3k27me3.R ✅ Metagene profiles at H3K27me3 domain boundaries
│       └── helper_functions/
│           └── helpers.R              ✅ csaw helpers: pool_input_at(), fit_and_merge_dual(),
│                                          quantile_norm_factors()
│
├── RNAseq/
│   ├── data/
│   │   └── salmon/                    🚫 Salmon quantification output; one subdirectory per sample
│   │                                      (quant.sf + aux files); 16 samples across CD4, CD8, B-cell
│   ├── fastq/
│   │   └── README.md                  ✅ Points to GEO accession for raw FASTQ files
│   ├── bash_scripts/                  ✅ fastp trimming and STAR alignment shell scripts
│   ├── metadata/
│   │   └── metadata.txt               ✅ Sample sheet: sample name, condition, cell type,
│   │                                      sex, organ, path to quant.sf
│   └── R/
│       ├── 00_config.R                ✅ Loads metadata, creates output dirs
│       ├── 01_deseq2.R                ✅ tximeta import → summarizeToGene → DESeq2 per cell type;
│       │                                  ENSEMBL→SYMBOL annotation; PCA and dispersion QC plots
│       ├── 02_de_plots.R              ✅ MA and volcano plots
│       ├── 03_gsea.R                  ✅ GO:BP and Hallmark GSEA (clusterProfiler / msigdbr)
│       ├── phantom_cage.R             ✅ FANTOM5 CAGE expression analysis of H1 histone genes
│       └── helper_functions/
│           └── functions.R            ✅ DESeq2 wrappers and shared plotting utilities
│
├── integration/
│   └── R/
│       ├── 00_config.R                ✅ Points to upstream result dirs (RNAseq, ATACseq, ChIPseq),
│       │                                  creates output dirs, defines shared cell-type levels
│       ├── 01_atac_rna_integration.R  ✅ ATAC × RNA concordance: accessibility changes vs
│       │                                  expression changes at gene promoters
│       ├── 02_atac_chip_integration.R ✅ ATAC × H3K27me3 overlap in CD8 T cells:
│       │                                  chromatin state vs accessibility (mm9 → mm10 liftOver)
│       └── helper_functions/
│           └── helpers.R              ✅ liftOver utilities and integration helpers
│
├── packages/
│   └── GenomicUtils/                  ✅ Local R package providing NRL/FFT analysis, genome-browser
│                                          plotting (Gviz wrappers), and ENCODE data utilities.
│                                          Must be installed before running any pipeline (see below).
│
├── preprocessing_scripts/             ✅ Shared fastp trimming and STAR alignment shell scripts
│                                          (mirrored from RNAseq/bash_scripts/)
│
├── session_info.txt                   ✅ R and package versions captured with sessionInfo()
│
└── results/                           🚫 All pipeline outputs — created on first run, not committed
    ├── ATACseq/
    │   ├── data/          → serialised csaw objects (.rds), summary tables (.csv)
    │   ├── differential/  → MA/volcano PDFs, BCV plots, window-level result tables (.csv)
    │   ├── annotation/    → ChIPseeker annotation tables and genomic-feature distribution PDFs
    │   ├── go/            → GO enrichment result tables and dotplot PDFs
    │   └── metagene/      → metagene2 profile PDFs
    ├── ChIPseq/
    │   ├── data/          → serialised csaw objects (.rds), workspace (.RData), summary table
    │   ├── differential/  → BCV and normalisation-comparison PDFs, result tables (.csv)
    │   ├── annotation/    → ChIPseeker annotation tables and UpSet PDFs
    │   ├── go/            → GO enrichment result tables and dotplot PDFs
    │   ├── tracks/        → Gviz browser track PDFs and metagene profile PDFs
    │   └── peaks/         → peak-call outputs
    ├── RNAseq/
    │   ├── data/          → dds_list.rds, res_list.rds, annotated DESeq2 result tables (.csv)
    │   └── plots/         → PCA, dispersion, MA, volcano, and GSEA PDFs
    └── integration/
        ├── data/          → overlap tables (.csv), liftOver intermediates
        └── plots/         → concordance scatter plots and heatmaps (PDF)
```

---

## Requirements

- R >= 4.3
- Bioconductor >= 3.18

### Installing dependencies

**1. Install the local `GenomicUtils` package and its dependencies:**

```r
library(desc)
library(BiocManager)

d <- desc::desc("packages/GenomicUtils/")

required <- d$get_deps() |>
  dplyr::filter(type == "Imports", package != "R") |>
  dplyr::pull(package)

BiocManager::install(required)
BiocManager::install("packages/GenomicUtils", repos = NULL, type = "source")
```

**2. Install remaining analysis packages:**

```r
BiocManager::install(c(
  # RNA-seq
  "tximeta", "DESeq2", "clusterProfiler", "enrichplot", "msigdbr",
  # ATAC-seq
  "csaw", "edgeR", "ChIPseeker", "metagene2", "BRGenomics",
  "TxDb.Mmusculus.UCSC.mm9.knownGene",
  # ChIP-seq
  "limma", "ComplexHeatmap", "Gviz", "GenomicAlignments",
  "TxDb.Mmusculus.UCSC.mm10.knownGene",
  # Shared
  "org.Mm.eg.db",
  # CRAN
  "tidyverse", "patchwork", "ggrepel", "cowplot", "ggplotify"
))
```

---

## Session info

Exact R and package versions are recorded in `session_info.txt` (generated with `sessionInfo()`). To regenerate it after installing all dependencies:

```r
writeLines(capture.output(sessionInfo()), "session_info.txt")
```

---

## Input data

| Project | Input | Location |
|---|---|---|
| RNA-seq | Salmon `quant.sf` files (16 samples) | `RNAseq/data/salmon/` |
| ATAC-seq | Sorted, deduplicated BAM files + `.bai` (16 samples) | `ATACseq/data/` |
| ChIP-seq | Sorted BAM files + `.bai` — H3K27me3, H3K36me2, Input × WT/cTKO (12 samples) | `ChIPseq/data/` |

Raw data is available at GEO under accession **GSE141187**.

---

## Running the analysis

Each project is run independently from its own `R/` directory. Scripts are numbered in execution order. Open the desired script in RStudio or Positron and run — the working directory is set automatically via `rstudioapi`.

### RNA-seq

```
01_deseq2.R            → DESeq2 differential expression per cell type
02_de_plots.R          → MA and volcano plots
03_gsea.R              → GO and Hallmark gene set enrichment
phantom_cage.R         → FANTOM5 CAGE H1 expression analysis
```

### ATAC-seq

```
01_ATAC_analysis.R     → csaw window counting, normalization, differential testing
02_ATAC_differential.R → MA and volcano plots
03_ATAC_annotation.R   → Peak annotation and genomic feature distributions
04_ATAC_go.R           → GO enrichment on increased-accessibility promoters
05_ATAC_metagene.R     → Metagene profiles at differential peaks
06_ATAC_nrl_profiles.R → Fragment size distributions and NRL profiles
```

### ChIP-seq

```
01_ChIPseq_norm_comparison.R     → Compare TMM / loess / quantile normalisations
02_ChIPseq_differential.R        → Differential binding analysis (chosen normalisation)
03_ChIPseq_annotation.R          → Peak annotation and UpSet plots
04_ChIPseq_breadth.R             → H3K36me2 domain breadth analysis
05_ChIPseq_domain_expansion.R    → H3K36me2 expansion into H3K27me3 territory
05b_ChIPseq_domain_contraction.R → H3K27me3 contraction and H3K36me2 reciprocal gain
06_ChIPseq_visualization.R       → Gviz genome browser tracks
07_ChIPseq_metagene_h3k27me3.R   → Metagene profiles at H3K27me3 domain boundaries
```

### Multiomics integration

Run after both RNA-seq and ATAC-seq pipelines are complete.

```
01_atac_rna_integration.R  → Concordance between chromatin accessibility and gene expression
02_atac_chip_integration.R → ATAC × H3K27me3 overlap in CD8 T cells
```
