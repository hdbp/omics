library(tidyverse)

# ============================================================================
# Upstream result paths
# ============================================================================

atac_data <- "../../results/ATACseq/data"
rna_data  <- "../../results/RNAseq/data"
chip_data <- "../../results/ChIPseq/data"

# ============================================================================
# Output directories
# ============================================================================

dirs <- list(
  data  = "../../results/integration/data",    # tables & serialised objects
  plots = "../../results/integration/plots"    # PDFs
)
walk(dirs, dir.create, recursive = TRUE, showWarnings = FALSE)

# ============================================================================
# Shared cell types (harmonized across all projects)
# ============================================================================

cell_types <- c("CD4", "CD8", "B-Cell")
