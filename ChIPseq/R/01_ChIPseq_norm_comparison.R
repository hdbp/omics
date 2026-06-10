if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(limma)
library(MASS)
library(patchwork)

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

frag_ext     <- 200
window_width <- 2000
window_space <- 500

# Global-background enrichment threshold (log2 scale) for filterWindowsGlobal.
# log2(2) = 1 means 2-fold above the genome-wide average IP signal.
# Inspect chip_norm_comparison_{assay}.pdf and adjust before re-running.
filter_fold <- log2(2)

# Significance thresholds used in the summary table and MA plot colouring.
# These are for visual inspection only — the definitive calls are in 02.
fdr_thresh <- 0.10   # FDR threshold
lfc_thresh <- 1      # minimum |log2FC|; 0 = no fold-change filter

source("helper_functions/helpers.R")

# ============================================================================
# Per-assay normalization comparison
#
# H3K27me3 and H3K36me2 are broad marks; a single 2 kb window is appropriate.
# Adjacent significant windows are merged via mergeResults (mergeWindows +
# combineTests).
# Filtering uses filterWindowsGlobal on 10 kb IP bins — no input BAMs used.
# Three normalization strategies (TMM, loess, quantile) are compared and
# saved; 02_ChIPseq_differential.R selects one per assay.
# ============================================================================

run_norm_comparison <- function(assay_name, metadata, dirs) {

  cat("\n", strrep("=", 60), "\n", sep = "")
  cat("Normalization comparison:", assay_name, "\n")
  cat(strrep("=", 60), "\n", sep = "")

  meta_ip       <- filter(metadata, assay == assay_name)
  sample_labels <- meta_ip$sample_name

  cat("IP:", nrow(meta_ip),
      " | WT:", sum(meta_ip$condition == "WT"),
      " | cTKO:", sum(meta_ip$condition == "cTKO"), "\n")

  # --- 10 kb IP bins (global background for filtering + TMM/quantile reference) ---
  ip_bins <- windowCounts(meta_ip$path, param = param, bin = TRUE, width = 10000)

  # --- 2 kb windows ---
  cat("\nCounting reads in 2 kb windows...\n")
  counts <- windowCounts(meta_ip$path, param = param,
                         width = window_width, spacing = window_space,
                         ext = frag_ext, filter = 10)
  cat("Windows:", length(counts), "\n")

  # --- Filter: keep windows >= filter_fold above global IP background ---
  stats    <- filterWindowsGlobal(counts, ip_bins)
  filtered <- counts[stats$filter > filter_fold, ]
  pct      <- round(100 * length(filtered) / length(counts), 1)
  cat("Retained:", length(filtered), "(", pct, "%) windows\n")

  condition <- factor(meta_ip$condition, levels = c("WT", "cTKO"))
  design    <- model.matrix(~ condition)
  cat("\nDesign matrix:\n"); print(design)

  # ==========================================================================
  # Three normalizations (IP only)
  # ==========================================================================

  cat("\nTMM...\n")
  filt_tmm <- normFactors(ip_bins, se.out = filtered)
  res_tmm  <- fit_and_merge_single(filt_tmm, design)

  cat("Loess...\n")
  filt_loess <- normOffsets(filtered)
  res_loess  <- fit_and_merge_single(filt_loess, design)

  cat("Quantile...\n")
  nf_q       <- quantile_norm_factors(ip_bins)
  filt_qnorm <- filtered; filt_qnorm$norm.factors <- nf_q
  res_qnorm  <- fit_and_merge_single(filt_qnorm, design)

  nf_tmm    <- filt_tmm$norm.factors
  norm_list <- list(TMM      = res_tmm,
                    Loess    = res_loess,
                    Quantile = res_qnorm)

  cat("\nNorm factors:\n")
  cat("  TMM:      ", paste(round(nf_tmm, 4), collapse = ", "), "\n")
  cat("  Quantile: ", paste(round(nf_q,   4), collapse = ", "), "\n")

  cat(sprintf("\nSignificant regions (FDR <= %.2f, |logFC| >= %.2f):\n",
              fdr_thresh, lfc_thresh))
  walk(names(norm_list), function(nm) {
    com  <- norm_list[[nm]]$merged$combined
    is_s <- !is.na(com$FDR) & com$FDR <= fdr_thresh &
              abs(as.numeric(com$rep.logFC)) >= lfc_thresh
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
  # Row 1: enrichment over global IP background distribution
  # Row 2: MA plots (TMM | Loess | Quantile)
  # Row 3: logFC density | norm factors | loess offsets
  # ==========================================================================

  thresh_df <- tibble(
    x     = c(log2(1.5), log2(2), log2(3)),
    label = c("1.5×", "2×", "3×"),
    col   = c("#E6AB02", "#D95F02", "#7570B3")
  )
  thresh_df$pct <- map_dbl(thresh_df$x,
                            ~ round(mean(stats$filter > .x) * 100, 1))
  cur_pct <- round(mean(stats$filter > filter_fold) * 100, 1)

  p_enrich <- ggplot(tibble(enrich = stats$filter), aes(x = enrich)) +
    geom_histogram(bins = 100, fill = "steelblue", color = "white",
                   linewidth = 0.1) +
    geom_vline(aes(xintercept = filter_fold),
               color = "black", linewidth = 1) +
    geom_vline(data = thresh_df, aes(xintercept = x, color = label),
               linetype = "dashed", linewidth = 0.8) +
    geom_text(data = thresh_df,
              aes(x = x, y = Inf,
                  label = sprintf("%s  %.0f%%", label, pct), color = label),
              vjust = 1.6, hjust = -0.1, size = 3.2, fontface = "bold") +
    scale_color_manual(values = setNames(thresh_df$col, thresh_df$label),
                       name = NULL) +
    labs(
      title    = paste(assay_name,
                       "— enrichment over global IP background (2 kb windows)"),
      subtitle = sprintf(
        "Applied threshold: log2(%.2g) = %.2f  |  %.1f%% of windows retained",
        2^filter_fold, filter_fold, cur_pct),
      x = "log2(window CPM / global background CPM)", y = "Window count"
    ) +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(), legend.position = "none")

  merged_df <- map_dfr(names(norm_list), function(nm) {
    nr      <- norm_list[[nm]]
    com     <- as_tibble(as.data.frame(nr$merged$combined))
    res_tbl <- nr$ql_large$res$table
    df <- com %>%
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
          fdr > fdr_thresh | abs(logFC) < lfc_thresh ~ "NS",
          dir == "up"                                ~ "Gained",
          dir == "down"                              ~ "Lost",
          TRUE                                       ~ "Mixed"
        ),
        norm = factor(norm, levels = c("TMM", "Loess", "Quantile"))
      )
    dens       <- kde2d(df$logCPM, df$logFC, n = 100)
    ix         <- pmax(1, pmin(findInterval(df$logCPM, dens$x), length(dens$x)))
    iy         <- pmax(1, pmin(findInterval(df$logFC,  dens$y), length(dens$y)))
    df$density <- dens$z[cbind(ix, iy)]
    df
  })

  ns_df   <- filter(merged_df, status == "NS")
  sig_df  <- filter(merged_df, status != "NS")
  sig_col <- c(Gained = "#E41A1C", Lost = "#377EB8", Mixed = "#984EA3")

  p_ma <- ggplot(mapping = aes(x = logCPM, y = logFC)) +
    geom_point(data = ns_df,  aes(color = density),
               size = 0.4, alpha = 0.7) +
    scale_color_viridis_c(option = "B", name = "Density", guide = "none") +
    geom_point(data = sig_df, aes(fill = status),
               shape = 21, size = 1.2, color = NA, alpha = 0.9) +
    scale_fill_manual(values = sig_col, name = NULL) +
    geom_hline(yintercept = 0, linetype = "dashed", linewidth = 0.4) +
    facet_wrap(~ norm, nrow = 1) +
    labs(title = paste(assay_name, "— MA plots by normalization"),
         x = "Average log CPM", y = "Log2 FC (cTKO/WT)") +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(),
          strip.text        = element_text(face = "bold"),
          legend.position   = "bottom")

  p_dens <- ggplot(merged_df, aes(x = logFC, color = norm, fill = norm)) +
    geom_density(alpha = 0.15, linewidth = 0.8) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "gray40") +
    scale_color_brewer(palette = "Set1", name = NULL) +
    scale_fill_brewer(palette  = "Set1", name = NULL) +
    labs(title = "logFC distribution", x = "Log2 FC (cTKO/WT)", y = "Density") +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(), legend.position = "bottom")

  nf_df <- tibble(
    sample = factor(rep(sample_labels, 2), levels = sample_labels),
    norm   = rep(c("TMM", "Quantile"), each = length(sample_labels)),
    nf     = c(nf_tmm, nf_q)
  )
  p_nf <- ggplot(nf_df, aes(x = sample, y = nf, fill = norm)) +
    geom_col(position = position_dodge(0.7), width = 0.65) +
    geom_hline(yintercept = 1, linetype = "dashed") +
    scale_fill_brewer(palette = "Set1", name = NULL) +
    labs(title = "Norm factors (TMM & Quantile)", x = NULL, y = "Norm factor") +
    theme_minimal(base_size = 11) +
    theme(axis.text.x      = element_text(angle = 45, hjust = 1),
          panel.grid.minor  = element_blank(), legend.position = "bottom")

  off_mat <- assay(filt_loess, "offset")
  colnames(off_mat) <- sample_labels
  off_df <- as.data.frame(off_mat) %>%
    pivot_longer(everything(), names_to = "sample", values_to = "offset") %>%
    mutate(sample = factor(sample, levels = sample_labels))

  p_off <- ggplot(off_df, aes(x = sample, y = offset)) +
    geom_boxplot(fill = "#4DAF4A", alpha = 0.7,
                 outlier.size = 0.2, outlier.alpha = 0.2) +
    geom_hline(yintercept = 0, linetype = "dashed") +
    labs(title = "Loess offsets per sample", x = NULL, y = "Log-space offset") +
    theme_minimal(base_size = 11) +
    theme(axis.text.x      = element_text(angle = 45, hjust = 1),
          panel.grid.minor  = element_blank())

  combined <- p_enrich / p_ma / (p_dens | p_nf | p_off) +
    plot_layout(heights = c(1.2, 2, 1.2)) +
    plot_annotation(
      title = paste(assay_name, "— normalization comparison"),
      theme = theme(plot.title = element_text(face = "bold", size = 14))
    )

  pdf(file.path(dirs$diff,
                paste0("chip_norm_comparison_", assay_name, ".pdf")),
      width = 14, height = 13)
  print(combined)
  dev.off()
  cat("Panel saved: chip_norm_comparison_", assay_name, ".pdf\n", sep = "")

  # ==========================================================================
  # Return: everything 02_ChIPseq_differential.R needs
  # ==========================================================================

  list(
    metadata    = meta_ip,
    design      = design,
    nf_tmm      = nf_tmm,
    nf_q        = nf_q,
    norm        = norm_list,
    enrich_dist = stats$filter,
    filtered_se = filtered
  )
}

# ============================================================================
# Run
# ============================================================================

assays <- unique(ip_tbl$assay)

prep <- setNames(
  lapply(assays, run_norm_comparison, metadata = metadata, dirs = dirs),
  assays
)

saveRDS(prep, file.path(dirs$data, "chip_norm_prep.rds"))

cat("\n=== 01_ChIPseq_norm_comparison.R complete ===\n")
cat("Inspect ../../results/ChIPseq/differential/chip_norm_comparison_{assay}.pdf\n")
cat("then set norm_choice in 02_ChIPseq_differential.R and re-run.\n")
