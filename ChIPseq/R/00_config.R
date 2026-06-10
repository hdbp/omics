library(tidyverse)

# ============================================================================
# Metadata
# ============================================================================

metadata  <- read_delim("../metadata/metadata.txt", show_col_types = FALSE)

ip_tbl    <- filter(metadata, assay != "Input")
input_tbl <- filter(metadata, assay == "Input")

bam.files <- metadata$path
samples   <- metadata$sample_name

# ============================================================================
# Output directories
# ============================================================================

dirs <- list(
  peaks  = "../../results/ChIPseq/peaks",          # called peaks
  diff   = "../../results/ChIPseq/differential",   # differential binding tables
  annot  = "../../results/ChIPseq/annotation",     # peak annotation tables & feature plots
  go     = "../../results/ChIPseq/go",             # GO enrichment results
  data   = "../../results/ChIPseq/data",           # serialised objects & summary tables
  tracks = "../../results/ChIPseq/tracks"          # bigWig tracks and metagene PDFs
)
walk(dirs, dir.create, recursive = TRUE, showWarnings = FALSE)