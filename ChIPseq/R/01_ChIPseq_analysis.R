if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(limma)
library(patchwork)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)
library(org.Mm.eg.db)

# ============================================================================
# Parameters
# ============================================================================

param <- readParam(
  minq     = 20,
  dedup    = TRUE,
  pe       = "both",
  max.frag = 1000,
  discard  = GRanges()
)

frag_ext      <- 200
window_large  <- 2000
spacing_large <- 500
window_small  <- 500
spacing_small <- 100

# Default IP/Input enrichment threshold (log2 scale).
# Inspect the enrichment distribution panel and adjust before re-running.
enrich_min <- log2(2)

# ============================================================================
# Helpers
# ============================================================================

source("helper_functions/helpers.R")

# ============================================================================
# Per-assay analysis
#
# H3K27me3 and H3K36me2 are broad marks analyzed at two window sizes (2 kb
# and 500 bp); results are merged via mergeResultsList.
# Peaks are defined as windows with IP/Input enrichment > enrich_min over a
# pooled (all-sample) input; Input is not used for normalization.
# Three normalizations are compared (TMM, loess, quantile); downstream scripts
# use TMM until the user selects a normalization.
# ============================================================================

analyze_assay <- function(assay_name, metadata, dirs) {

  cat("\n", strrep("=", 60), "\n", sep = "")
  cat("Analyzing:", assay_name, "\n")
  cat(strrep("=", 60), "\n", sep = "")

  meta_ip       <- filter(metadata, assay == assay_name)
  meta_input    <- filter(metadata, assay == "Input")
  sample_labels <- meta_ip$sample_name

  cat("IP samples:", nrow(meta_ip),
      " | WT:", sum(meta_ip$condition == "WT"),
      " | cTKO:", sum(meta_ip$condition == "cTKO"), "\n")
  cat("Input samples:", nrow(meta_input), "(pooled for filtering)\n")

  # --- 10 kb IP bins (TMM normalization reference) ---
  ip_bins <- windowCounts(meta_ip$path, param = param, bin = TRUE, width = 10000)

  # --- Window counts at two sizes ---
  cat("\nCounting reads in windows...\n")
  counts_large <- windowCounts(meta_ip$path, param = param,
                               width = window_large, spacing = spacing_large,
                               ext = frag_ext, filter = 10)
  counts_small <- windowCounts(meta_ip$path, param = param,
                               width = window_small, spacing = spacing_small,
                               ext = frag_ext, filter = 10)
  cat("Windows — 2 kb:", length(counts_large), "| 500 bp:", length(counts_small), "\n")

  # --- Pool all inputs and count at same windows as IP ---
  cat("Counting pooled input at IP windows...\n")
  pooled_lg <- pool_input_at(counts_large, meta_input$path, param, frag_ext)
  pooled_sm <- pool_input_at(counts_small, meta_input$path, param, frag_ext)

  # --- Enrichment over pooled input ---
  enrich_lg <- suppressWarnings(filterWindowsControl(counts_large, pooled_lg))
  enrich_sm <- suppressWarnings(filterWindowsControl(counts_small, pooled_sm))

  # --- Filter: IP/Input enrichment > enrich_min ---
  filtered_large <- counts_large[enrich_lg$filter > enrich_min, ]
  filtered_small <- counts_small[enrich_sm$filter > enrich_min, ]

  pct_lg <- round(100 * length(filtered_large) / length(counts_large), 1)
  pct_sm <- round(100 * length(filtered_small) / length(counts_small), 1)
  cat("Retained — 2 kb:", length(filtered_large), "(", pct_lg, "%)",
      "| 500 bp:", length(filtered_small), "(", pct_sm, "%)\n")

  condition <- factor(meta_ip$condition, levels = c("WT", "cTKO"))
  design    <- model.matrix(~ condition)
  cat("\nDesign matrix:\n"); print(design)

  # ==========================================================================
  # Three normalizations (IP only — Input not used)
  # ==========================================================================

  cat("\nTMM normalization...\n")
  filt_lg_tmm <- normFactors(ip_bins, se.out = filtered_large)
  filt_sm_tmm <- filtered_small
  filt_sm_tmm$norm.factors <- filt_lg_tmm$norm.factors
  res_tmm <- fit_and_merge_dual(filt_lg_tmm, filt_sm_tmm, design)

  cat("Loess normalization...\n")
  filt_lg_loess <- normOffsets(filtered_large)
  filt_sm_loess <- normOffsets(filtered_large, se.out = filtered_small)
  res_loess <- fit_and_merge_dual(filt_lg_loess, filt_sm_loess, design)

  cat("Quantile normalization...\n")
  nf_q <- quantile_norm_factors(ip_bins)
  filt_lg_qnorm <- filtered_large; filt_lg_qnorm$norm.factors <- nf_q
  filt_sm_qnorm <- filtered_small; filt_sm_qnorm$norm.factors <- nf_q
  res_qnorm <- fit_and_merge_dual(filt_lg_qnorm, filt_sm_qnorm, design)

  nf_tmm <- filt_lg_tmm$norm.factors
  cat("\nNorm factors:\n")
  cat("  TMM:     ", paste(round(nf_tmm, 4), collapse = ", "), "\n")
  cat("  Quantile:", paste(round(nf_q,   4), collapse = ", "), "\n")

  # ==========================================================================
  # Per-normalization summary
  # ==========================================================================

  norm_list <- list(TMM = res_tmm, Loess = res_loess, Quantile = res_qnorm)

  cat("\nSignificant regions (FDR <= 0.05):\n")
  walk(names(norm_list), function(nm) {
    com  <- norm_list[[nm]]$merged$combined
    is_s <- !is.na(com$FDR) & com$FDR <= 0.05
    cat(sprintf("  %-10s total: %d  sig: %d  gained: %d  lost: %d\n",
                nm, nrow(com), sum(is_s),
                sum(com$direction == "up"   & is_s, na.rm = TRUE),
                sum(com$direction == "down" & is_s, na.rm = TRUE)))
  })

  # BCV (TMM)
  pdf(file.path(dirs$diff, paste0("chip_bcv_", assay_name, ".pdf")),
      width = 8, height = 6)
  plotBCV(res_tmm$ql_large$y, main = paste("BCV —", assay_name, "(2 kb, TMM)"))
  dev.off()

  # ==========================================================================
  # Comparison panel
  # Row 1: IP/Input enrichment distribution
  # Row 2: MA plots (TMM | Loess | Quantile)
  # Row 3: logFC density | norm factors | loess offsets
  # ==========================================================================

  # --- Row 1: enrichment distribution ---
  thresh_df <- tibble(
    x     = c(log2(2), log2(3), log2(4)),
    label = c("2×", "3×", "4×"),
    col   = c("#E6AB02", "#D95F02", "#7570B3")
  )
  thresh_df$pct <- map_dbl(
    thresh_df$x, ~ round(mean(enrich_lg$filter > .x) * 100, 1)
  )
  cur_pct <- round(mean(enrich_lg$filter > enrich_min) * 100, 1)

  p_enrich <- ggplot(tibble(enrich = enrich_lg$filter), aes(x = enrich)) +
    geom_histogram(bins = 100, fill = "steelblue", color = "white",
                   linewidth = 0.1) +
    geom_vline(aes(xintercept = enrich_min), linetype = "solid",
               color = "black", linewidth = 0.8) +
    geom_vline(data = thresh_df, aes(xintercept = x, color = label),
               linetype = "dashed", linewidth = 0.8) +
    geom_text(data = thresh_df,
              aes(x = x, y = Inf, label = sprintf("%s  %.0f%%", label, pct),
                  color = label),
              vjust = 1.6, hjust = -0.1, size = 3.2, fontface = "bold") +
    scale_color_manual(values = setNames(thresh_df$col, thresh_df$label),
                       name = NULL) +
    labs(
      title    = paste(assay_name, "— IP / pooled Input enrichment (2 kb windows)"),
      subtitle = sprintf(
        "Applied threshold: log2(%.2g) = %.2f  |  %.1f%% of windows retained",
        2^enrich_min, enrich_min, cur_pct),
      x = "log2(IP / pooled Input)", y = "Window count"
    ) +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(), legend.position = "none")

  # --- Row 2: MA plots ---
  merged_df <- map_dfr(names(norm_list), function(nm) {
    nr      <- norm_list[[nm]]
    com     <- as_tibble(as.data.frame(nr$merged$combined))
    res_tbl <- nr$ql_large$res$table
    com %>%
      transmute(
        norm   = nm,
        logCPM = as.numeric(res_tbl$logCPM[rep.test]),
        logFC  = as.numeric(rep.logFC),
        fdr    = as.numeric(FDR),
        dir    = direction
      ) %>%
      filter(is.finite(logCPM) & is.finite(logFC)) %>%
      mutate(
        status = case_when(
          fdr > 0.05    ~ "NS",
          dir == "up"   ~ "Gained",
          dir == "down" ~ "Lost",
          TRUE          ~ "Mixed"
        ),
        norm = factor(norm, levels = c("TMM", "Loess", "Quantile"))
      )
  })

  pt_col <- c(NS = adjustcolor("gray60", 0.4), Gained = "#E41A1C",
              Lost = "#377EB8", Mixed = "#984EA3")

  p_ma <- ggplot(merged_df, aes(x = logCPM, y = logFC, color = status)) +
    geom_point(size = 0.4, alpha = 0.6) +
    scale_color_manual(values = pt_col, name = NULL) +
    geom_hline(yintercept = 0, linetype = "dashed", linewidth = 0.4) +
    facet_wrap(~ norm, nrow = 1) +
    labs(title = paste(assay_name, "— MA plots by normalization"),
         x = "Average log CPM", y = "Log2 FC (cTKO/WT)") +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(),
          strip.text       = element_text(face = "bold"),
          legend.position  = "bottom")

  # --- Row 3, col 1: logFC density ---
  p_dens <- ggplot(merged_df, aes(x = logFC, color = norm, fill = norm)) +
    geom_density(alpha = 0.15, linewidth = 0.8) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "gray40") +
    scale_color_brewer(palette = "Set1", name = NULL) +
    scale_fill_brewer(palette = "Set1",  name = NULL) +
    labs(title = "logFC distribution", x = "Log2 FC (cTKO/WT)", y = "Density") +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(), legend.position = "bottom")

  # --- Row 3, col 2: TMM + quantile norm factors ---
  nf_df <- tibble(
    sample = factor(rep(sample_labels, 2), levels = sample_labels),
    norm   = rep(c("TMM", "Quantile"), each = length(sample_labels)),
    nf     = c(nf_tmm, nf_q)
  )
  p_nf <- ggplot(nf_df, aes(x = sample, y = nf, fill = norm)) +
    geom_col(position = position_dodge(0.7), width = 0.65) +
    geom_hline(yintercept = 1, linetype = "dashed") +
    scale_fill_brewer(palette = "Set1", name = NULL) +
    labs(title = "Norm factors", x = NULL, y = "Norm factor") +
    theme_minimal(base_size = 11) +
    theme(axis.text.x    = element_text(angle = 45, hjust = 1),
          panel.grid.minor = element_blank(), legend.position = "bottom")

  # --- Row 3, col 3: loess offset distributions ---
  off_mat <- assay(filt_lg_loess, "offset")
  colnames(off_mat) <- sample_labels
  off_df <- as.data.frame(off_mat) %>%
    pivot_longer(everything(), names_to = "sample", values_to = "offset") %>%
    mutate(sample = factor(sample, levels = sample_labels))

  p_off <- ggplot(off_df, aes(x = sample, y = offset)) +
    geom_boxplot(fill = "#4DAF4A", alpha = 0.7,
                 outlier.size = 0.2, outlier.alpha = 0.2) +
    geom_hline(yintercept = 0, linetype = "dashed") +
    labs(title = "Loess offsets", x = NULL, y = "Log-space offset") +
    theme_minimal(base_size = 11) +
    theme(axis.text.x    = element_text(angle = 45, hjust = 1),
          panel.grid.minor = element_blank())

  combined <- p_enrich / p_ma / (p_dens | p_nf | p_off) +
    plot_layout(heights = c(1.2, 2, 1.2)) +
    plot_annotation(
      title = paste(assay_name, "— normalization comparison"),
      theme = theme(plot.title = element_text(face = "bold", size = 14))
    )

  pdf(file.path(dirs$diff, paste0("chip_norm_comparison_", assay_name, ".pdf")),
      width = 14, height = 13)
  print(combined)
  dev.off()
  cat("Norm comparison panel saved.\n")

  # ==========================================================================
  # Save result tables (all three normalizations)
  # ==========================================================================

  walk(names(norm_list), function(nm) {
    tag <- tolower(nm)
    com <- as_tibble(as.data.frame(norm_list[[nm]]$merged$combined))
    write_csv(com, file.path(dirs$diff,
              paste0("chip_results_", assay_name, "_", tag, ".csv")))
    is_s <- !is.na(com$FDR) & com$FDR <= 0.05
    if (any(is_s))
      write_csv(filter(com, is_s), file.path(dirs$diff,
                paste0("chip_significant_", assay_name, "_", tag, ".csv")))
  })

  # ==========================================================================
  # Gene-level analysis (TMM — update after normalization decision)
  # ==========================================================================

  cat("\nGene-level analysis (TMM)...\n")
  gene_ranges <- genes(TxDb.Mmusculus.UCSC.mm10.knownGene)
  gene_counts <- regionCounts(meta_ip$path, regions = gene_ranges, param = param)
  gene_counts$norm.factors <- nf_tmm

  y_gene   <- asDGEList(gene_counts)
  y_gene   <- estimateDisp(y_gene, design)
  fit_gene <- glmQLFit(y_gene, design, robust = TRUE)
  res_gene <- glmQLFTest(fit_gene, coef = "conditioncTKO")

  gene_tbl <- as_tibble(res_gene$table) %>%
    mutate(
      entrez = names(gene_ranges),
      symbol = mapIds(org.Mm.eg.db, entrez, "SYMBOL", "ENTREZID",
                      multiVals = "first"),
      FDR    = p.adjust(PValue, method = "BH")
    ) %>%
    arrange(PValue)

  n_sig_gene <- sum(gene_tbl$FDR <= 0.05, na.rm = TRUE)
  cat("Significant genes (FDR < 0.05):", n_sig_gene, "\n")
  write_csv(gene_tbl,
            file.path(dirs$diff, paste0("chip_gene_results_", assay_name, ".csv")))

  # ==========================================================================
  # Return — downstream scripts use TMM via top-level aliases
  # ==========================================================================

  list(
    metadata      = meta_ip,
    counts_large  = filtered_large,
    counts_small  = filtered_small,
    norm          = norm_list,
    ql_large      = res_tmm$ql_large,
    ql_small      = res_tmm$ql_small,
    merged        = res_tmm$merged,
    genes_ql      = list(y = y_gene, fit = fit_gene, res = res_gene, table = gene_tbl)
  )
}

# ============================================================================
# Run
# ============================================================================

assays <- unique(ip_tbl$assay)

analysis <- setNames(
  lapply(assays, analyze_assay, metadata = metadata, dirs = dirs),
  assays
)

saveRDS(analysis, file.path(dirs$data, "csaw_chip_analysis_results.rds"))

# ============================================================================
# Summary table (all three normalizations)
# ============================================================================

summary_stats <- map_dfr(names(analysis), function(assay_name) {
  ct <- analysis[[assay_name]]
  map_dfr(names(ct$norm), function(nm) {
    com  <- ct$norm[[nm]]$merged$combined
    is_s <- !is.na(com$FDR) & com$FDR <= 0.05
    tibble(
      assay         = assay_name,
      normalization = nm,
      n_wt          = sum(ct$metadata$condition == "WT"),
      n_ctko        = sum(ct$metadata$condition == "cTKO"),
      total_regions = nrow(com),
      sig_regions   = sum(is_s, na.rm = TRUE),
      gained        = sum(com$direction == "up"   & is_s, na.rm = TRUE),
      lost          = sum(com$direction == "down" & is_s, na.rm = TRUE)
    )
  })
})

print(summary_stats)
write_csv(summary_stats, file.path(dirs$data, "chip_summary_statistics.csv"))
save(analysis, metadata, file = file.path(dirs$data, "chip_csaw_analysis.RData"))

cat("\n=== 01_ChIPseq_analysis.R complete ===\n")
cat("Output: ../../results/ChIPseq/data/\n")
