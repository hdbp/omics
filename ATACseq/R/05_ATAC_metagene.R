if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(metagene2)
library(GenomicRanges)
library(patchwork)

cat("\n=== Metagene2 profiles ===\n")

analysis <- readRDS(file.path(dirs$data, "csaw_atac_analysis_results.rds"))

# ============================================================================
# Per-cell-type metagene2 profiles
# Peaks +/- 1 kb, FDR-significant regions only, WT vs cTKO overlaid.
# ============================================================================

metas <- list()

for (cell_type in names(analysis)) {
  cat("\n---", cell_type, "---\n")

  ct <- analysis[[cell_type]]

  peaks.idx <- ct$merged$combined$FDR <= 0.05
  peaks.gr  <- trim(resize(ct$merged$regions[peaks.idx], width = 2001L, fix = "center"))
  peaks.gr  <- BRGenomics::tidyChromosomes(
    peaks.gr,
    keep.X = FALSE, keep.Y = FALSE, keep.M = FALSE, keep.nonstandard = FALSE,
    genome = "mm9"
  )

  mg <- metagene2::metagene2$new(
    regions    = GRangesList(Peaks = peaks.gr),
    bam_files  = metadata$bam.files[metadata$`Cell type` == cell_type],
    assay      = "chipseq",
    paired_end = TRUE,
    cores      = 8L
  )

  design <- data.frame(
    Samples = metadata$bam.files[metadata$`Cell type` == cell_type],
    WT      = ifelse(metadata$Genotype[metadata$`Cell type` == cell_type] == "WT",   1L, 0L),
    cTKO    = ifelse(metadata$Genotype[metadata$`Cell type` == cell_type] == "cTKO", 1L, 0L),
    stringsAsFactors = FALSE
  )

  metas[[cell_type]] <- mg$produce_metagene(
    design        = design,
    normalization = "RPM",
    bin_count     = 100L,
    group_by      = "design"
  ) +
    scale_x_continuous(
      breaks = seq(0, 100, 25),
      labels = c("-1 kb", "-0.5 kb", "Peak center", "+0.5 kb", "+1 kb")
    ) +
    scale_colour_manual(values = c(WT = "black", cTKO = "red")) +
    labs(
      title = paste0(cell_type, " — Peaks ± 1 kb [FDR-significant]"),
      x     = NULL,
      y     = "Mean ATAC signal (RPM)"
    )

  ggsave(
    metas[[cell_type]],
    filename = file.path(dirs$meta, paste0("atac_metagene2_", cell_type, ".pdf")),
    width = 8, height = 5
  )
}

# ============================================================================
# Combined panel
# ============================================================================

panel <- wrap_plots(metas, ncol = 3) +
  plot_annotation(title = "ATAC-seq metaplots — all cell types")

ggsave(
  panel,
  filename = file.path(dirs$meta, "atac_metagene2_panel.pdf"),
  width = 18, height = 5
)

cat("\n=== 05_metagene.R complete ===\n")
cat("Output: ../../results/ATACseq/metagene/\n")
