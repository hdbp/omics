if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)

# ============================================================================
# csaw parameters
# ============================================================================

param <- readParam(
  minq     = 20,
  dedup    = TRUE,
  pe       = "both",
  max.frag = 1000,
  discard  = GRanges()
)

window_width <- 150
spacing      <- 50

# ============================================================================
# Per-cell-type analysis
#
# Each cell type is analyzed fully independently: window counting, background
# estimation, filtering, normalization, dispersion, testing, and merging all
# use only that cell type's samples.
#
# Normalization uses large (10 kb) background bins rather than the test
# windows themselves, because global chromatin changes are expected in cTKO
# and TMM on the test windows would absorb real signal as composition bias.
# ============================================================================

analyze_cell_type <- function(cell_type_name, metadata, dirs) {

  cat("\n", strrep("=", 60), "\n", sep = "")
  cat("Analyzing:", cell_type_name, "\n")
  cat(strrep("=", 60), "\n", sep = "")

  meta_ct <- filter(metadata, `Cell type` == cell_type_name)
  cat("Samples:", nrow(meta_ct),
      " | WT:", sum(meta_ct$Genotype == "WT"),
      " | cTKO:", sum(meta_ct$Genotype == "cTKO"), "\n")

  # --- Window counting ---
  cat("\nCounting reads in windows...\n")
  counts <- windowCounts(
    bam.files = meta_ct$bam.files,
    param     = param,
    width     = window_width,
    spacing   = spacing,
    filter    = 10
  )
  cat("Total windows:", length(counts), "\n")

  # --- Background bins (10 kb) ---
  bin_counts <- windowCounts(
    bam.files = meta_ct$bam.files,
    param     = param,
    bin       = TRUE,
    width     = 10000
  )

  # --- Filtering: keep windows >= 3x enrichment over genomic background ---
  filter_stats <- filterWindowsGlobal(counts, bin_counts)
  keep         <- filter_stats$filter > log2(3)
  filtered     <- counts[keep, ]
  cat("Retained windows:", sum(keep),
      "(", round(100 * sum(keep) / length(counts), 1), "%)\n")

  # --- Normalization via background bins ---
  filtered <- normFactors(bin_counts, se.out = filtered)

  # --- Differential testing ---
  y        <- asDGEList(filtered)
  genotype <- factor(meta_ct$Genotype, levels = c("WT", "cTKO"))
  design   <- model.matrix(~ genotype)

  cat("\nDesign matrix:\n")
  print(design)

  y <- estimateDisp(y, design)
  cat("BCV:", round(sqrt(y$common.dispersion), 3), "\n")

  pdf(file.path(dirs$diff, paste0("atac_bcv_", cell_type_name, ".pdf")),
      width = 8, height = 6)
  plotBCV(y, main = paste("BCV -", cell_type_name))
  dev.off()

  # QL F-test requires >= 4 residual df to be well-calibrated; fall back to
  # LRT for cell types with only 2 samples/group.
  n_samples <- nrow(meta_ct)
  resid_df  <- n_samples - ncol(design)

  if (resid_df >= 4) {
    fit     <- glmQLFit(y, design, robust = TRUE)
    results <- glmQLFTest(fit, coef = "genotypecTKO")
    cat("Test: QL F-test (residual df =", resid_df, ")\n")
  } else {
    fit     <- glmFit(y, design)
    results <- glmLRT(fit, coef = "genotypecTKO")
    cat("Test: LRT (residual df =", resid_df, "— QL F-test too conservative)\n")
  }

  n_sig <- sum(p.adjust(results$table$PValue, method = "BH") < 0.05)
  cat("Windows FDR < 0.05:", n_sig, "\n")

  # --- Merge windows into peaks ---
  cat("\nMerging windows...\n")
  merged <- mergeResults(
    ranges     = rowRanges(filtered),
    tab        = results$table,
    tol        = 1000L,
    merge.args = list(max.width = 5000)
  )

  is.sig  <- merged$combined$FDR <= 0.05
  n_total <- nrow(merged$combined)
  n_sig_r <- sum(is.sig, na.rm = TRUE)
  cat("Total merged regions:", n_total, "\n")
  cat("Significant (FDR < 0.05):", n_sig_r, "\n")

  if (n_sig_r > 0) {
    cat("  Increased:", sum(merged$combined$direction == "up"   & is.sig, na.rm = TRUE), "\n")
    cat("  Decreased:", sum(merged$combined$direction == "down" & is.sig, na.rm = TRUE), "\n")
  }

  # --- Save tables ---
  write_csv(
    as_tibble(merged$combined),
    file.path(dirs$diff, paste0("atac_results_", cell_type_name, ".csv"))
  )
  if (n_sig_r > 0) {
    write_csv(
      as_tibble(merged$combined) %>% filter(is.sig),
      file.path(dirs$diff, paste0("atac_significant_", cell_type_name, ".csv"))
    )
  }

  list(
    metadata = meta_ct,
    counts   = filtered,
    dge      = y,
    fit      = fit,
    results  = results,
    merged   = merged
  )
}

# ============================================================================
# Run
# ============================================================================

analysis <- list(
  CD4              = analyze_cell_type("CD4",    metadata, dirs),
  CD8              = analyze_cell_type("CD8",    metadata, dirs),
  `B-Cell`         = analyze_cell_type("B-Cell", metadata, dirs)
)

saveRDS(analysis, file.path(dirs$data, "csaw_atac_analysis_results.rds"))

# ============================================================================
# Summary table
# ============================================================================

summary_stats <- map_dfr(names(analysis), function(ct_name) {
  ct     <- analysis[[ct_name]]
  com    <- ct$merged$combined
  is.sig <- com$FDR <= 0.05

  tibble(
    cell_type     = ct_name,
    n_wt          = sum(ct$metadata$Genotype == "WT"),
    n_ctko        = sum(ct$metadata$Genotype == "cTKO"),
    total_regions = nrow(com),
    sig_regions   = sum(is.sig, na.rm = TRUE),
    increased     = sum(com$direction == "up"   & is.sig, na.rm = TRUE),
    decreased     = sum(com$direction == "down" & is.sig, na.rm = TRUE)
  )
})

print(summary_stats)
write_csv(summary_stats, file.path(dirs$data, "atac_summary_statistics.csv"))
save(analysis, metadata, file = file.path(dirs$data, "atac_csaw_analysis.RData"))

cat("\n=== 01_analysis.R complete ===\n")
cat("Output: ../../results/ATACseq/data/\n")
