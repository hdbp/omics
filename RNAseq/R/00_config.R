library(tidyverse)

# ============================================================================
# Metadata
# ============================================================================

coldata <- read_delim("../metadata/metadata.txt", show_col_types = FALSE) %>%
  dplyr::rename(names = sample_name) %>%
  mutate(condition = factor(condition, levels = c("WT", "cTKO")))

# ============================================================================
# Output directories
# ============================================================================

dirs <- list(
  data  = "../../results/RNAseq/data",    # DESeq2 tables & serialised objects
  plots = "../../results/RNAseq/plots"    # QC, MA, volcano, GSEA PDFs
)
walk(dirs, dir.create, recursive = TRUE, showWarnings = FALSE)
