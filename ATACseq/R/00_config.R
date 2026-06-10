library(tidyverse)

# ============================================================================
# Metadata
# ============================================================================

bam.files <- list.files(path = "../data", pattern = "\\.sorted\\.bam$", full.names = TRUE)
metadata  <- read_delim("../metadata/metadata.txt", show_col_types = FALSE)

bam_tbl <- tibble(
  bam.files   = bam.files,
  genewizName = basename(bam.files) %>%
    str_remove("\\.sort\\.qc\\.rd\\.mt\\.sorted\\.bam$")
)

metadata <- left_join(metadata, bam_tbl, by = "genewizName") %>%
  dplyr::select(bam.files, sample = genewizName, `Cell type`, Genotype, Organ, ID)

# ============================================================================
# Output directories
# ============================================================================

dirs <- list(
  diff  = "../../results/ATACseq/differential",   # DE tables, BCV, MA, volcano
  annot = "../../results/ATACseq/annotation",     # peak annotation tables & feature plots
  go    = "../../results/ATACseq/go",             # GO BP results
  meta  = "../../results/ATACseq/metagene",       # metagene2 profiles
  data  = "../../results/ATACseq/data"            # serialised objects & summary table
)
walk(dirs, dir.create, recursive = TRUE, showWarnings = FALSE)

source("helper_functions/helpers.R")
