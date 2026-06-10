if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(MASS)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)
library(org.Mm.eg.db)

# ============================================================================
# USER SETTINGS
# Set the normalization to use for each assay after inspecting the panels
# produced by 01_ChIPseq_norm_comparison.R.
# Valid values: "TMM" | "Loess" | "Quantile"
# Names must match assay names in the metadata (check with unique(ip_tbl$assay)).
# ============================================================================

norm_choice <- c(
  H3K27me3 = "TMM",
  H3K36me2 = "TMM"
)

fdr_thresh <- 0.10   # FDR threshold for significance calls
lfc_thresh <- 1      # minimum |log2FC|; 0 = no fold-change filter

cat("\n=== Differential binding analysis ===\n")
cat("Normalizations:", paste(names(norm_choice), norm_choice,
                             sep = " = ", collapse = " | "), "\n")
cat(sprintf("Thresholds: FDR <= %.2f  |  |logFC| >= %.2f\n",
            fdr_thresh, lfc_thresh))

prep <- readRDS(file.path(dirs$data, "chip_norm_prep.rds"))

# ============================================================================
# Plot functions
# ============================================================================

create_ma_plot <- function(res, assay_name, dirs) {

  pdf(file.path(dirs$diff, paste0("chip_ma_plot_", assay_name, ".pdf")),
      width = 12, height = 6)
  par(mfrow = c(1, 2))

  res_tbl     <- res$ql_large$res$table
  sig_windows <- res_tbl$PValue < 0.05 / nrow(res_tbl)
  plotMD(
    res$ql_large$res,
    status = ifelse(sig_windows, "Sig", "NotSig"),
    values = "Sig",
    hl.col = "red",
    bg.col = adjustcolor("black", alpha.f = 0.3),
    cex    = 0.3,
    main   = paste(assay_name, "— 2 kb windows"),
    xlab   = "Average log CPM",
    ylab   = "Log2 FC (cTKO/WT)",
    legend = "topright"
  )
  abline(h = 0, col = "blue", lty = 2)

  com_df <- as_tibble(as.data.frame(res$merged$combined)) %>%
    mutate(
      logCPM = as.numeric(res_tbl$logCPM[rep.test]),
      logFC  = as.numeric(rep.logFC),
      fdr    = as.numeric(FDR)
    ) %>%
    filter(is.finite(logCPM) & is.finite(logFC)) %>%
    mutate(status = case_when(
      fdr > fdr_thresh | abs(logFC) < lfc_thresh ~ "NotSig",
      direction == "up"                          ~ "Gained",
      direction == "down"                        ~ "Lost",
      TRUE                                       ~ "Mixed"
    ))

  pt_col <- c(NotSig = adjustcolor("gray50", alpha.f = 0.4),
              Gained = "red", Lost = "blue", Mixed = "purple")
  plot(
    com_df$logCPM, com_df$logFC,
    col  = pt_col[com_df$status],
    pch  = 16, cex = 0.5,
    main = paste(assay_name, "— merged regions"),
    xlab = "Average log CPM",
    ylab = "Log2 FC (cTKO/WT)"
  )
  legend("topright", legend = names(pt_col), col = pt_col, pch = 16, cex = 0.8)
  abline(h = 0, col = "black", lty = 2)
  dev.off()
}

create_volcano_plot <- function(res, assay_name, dirs) {

  pdf(file.path(dirs$diff, paste0("chip_volcano_", assay_name, ".pdf")),
      width = 8, height = 8)

  df <- as_tibble(as.data.frame(res$merged$combined)) %>%
    transmute(
      logFC       = as.numeric(rep.logFC),
      neg_log_fdr = -log10(as.numeric(FDR))
    ) %>%
    filter(is.finite(logFC) & is.finite(neg_log_fdr))

  h_x <- max(bw.nrd0(df$logFC),       diff(range(df$logFC))       / 10, 0.01)
  h_y <- max(bw.nrd0(df$neg_log_fdr), diff(range(df$neg_log_fdr)) / 10, 0.01)

  dens       <- kde2d(df$logFC, df$neg_log_fdr, n = 100, h = c(h_x, h_y))
  ix         <- pmax(1, pmin(findInterval(df$logFC,       dens$x), length(dens$x)))
  iy         <- pmax(1, pmin(findInterval(df$neg_log_fdr, dens$y), length(dens$y)))
  df$density <- dens$z[cbind(ix, iy)]

  p <- ggplot(df, aes(x = logFC, y = neg_log_fdr)) +
    geom_point(aes(color = density), size = 0.8, alpha = 0.6) +
    scale_color_viridis_c(name = "Density") +
    geom_hline(yintercept = -log10(fdr_thresh), linetype = "dashed", color = "red") +
    geom_vline(xintercept = c(-lfc_thresh, lfc_thresh),
               linetype = "dotted", color = "gray40") +
    labs(
      title    = paste(assay_name, "— Differential Binding"),
      subtitle = "cTKO vs WT",
      x        = "Log2 Fold Change (cTKO/WT)",
      y        = "-log10(FDR)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"),
          panel.grid.minor = element_blank())
  print(p)
  dev.off()
}

create_gene_ma_plot <- function(gene_tbl, ql_large, assay_name, dirs) {

  sig    <- !is.na(gene_tbl$FDR) & gene_tbl$FDR <= fdr_thresh &
              abs(gene_tbl$rep.logFC) >= lfc_thresh
  status <- case_when(
    sig & gene_tbl$rep.logFC > 0 ~ "Gained",
    sig & gene_tbl$rep.logFC < 0 ~ "Lost",
    TRUE                         ~ "NotSig"
  )
  logcpm <- ql_large$res$table$logCPM[gene_tbl$rep.test]

  pt_col <- c(NotSig = adjustcolor("black", alpha.f = 0.3),
              Gained = "red", Lost = "blue")

  pdf(file.path(dirs$diff, paste0("chip_gene_ma_", assay_name, ".pdf")),
      width = 8, height = 6)
  plot(
    logcpm, gene_tbl$rep.logFC,
    col  = pt_col[status],
    pch  = 16, cex = 0.4,
    main = paste(assay_name, "— gene bodies (cTKO vs WT)"),
    xlab = "Average log CPM (representative window)",
    ylab = "Log2 FC (cTKO/WT)"
  )
  legend("topright",
         legend = c("Gained", "Lost", "NotSig"),
         col    = pt_col[c("Gained", "Lost", "NotSig")],
         pch    = 16, cex = 0.8)
  abline(h = 0,                      col = "gray50", lty = 2)
  abline(h = c(-lfc_thresh, lfc_thresh), col = "gray70", lty = 3)
  dev.off()
}

# ============================================================================
# Per-assay differential analysis
# ============================================================================

run_differential <- function(assay_name, prep, norm_choice, dirs) {

  ct       <- prep[[assay_name]]
  nm_input <- norm_choice[assay_name]
  nm       <- names(ct$norm)[tolower(names(ct$norm)) == tolower(nm_input)]
  if (length(nm) == 0)
    stop("Unknown normalization '", nm_input, "'. Choose from: ",
         paste(names(ct$norm), collapse = ", "))
  res <- ct$norm[[nm]]

  cat("\n", strrep("=", 60), "\n", sep = "")
  cat("Differential analysis:", assay_name, " — normalization:", nm, "\n")
  cat(strrep("=", 60), "\n", sep = "")

  meta_ip <- ct$metadata
  design  <- ct$design

  # Significant region summary
  com    <- res$merged$combined
  is_sig <- !is.na(com$FDR) & com$FDR <= fdr_thresh &
              abs(as.numeric(com$rep.logFC)) >= lfc_thresh
  cat("Total merged regions:", nrow(com), "\n")
  cat(sprintf("Significant (FDR <= %.2f, |logFC| >= %.2f): %d\n",
              fdr_thresh, lfc_thresh, sum(is_sig)))
  if (sum(is_sig) > 0) {
    cat("  Gained:", sum(com$direction == "up"   & is_sig, na.rm = TRUE), "\n")
    cat("  Lost:",   sum(com$direction == "down" & is_sig, na.rm = TRUE), "\n")
  }

  # Save normalization factors
  nf_tbl <- tibble(
    sample        = ct$metadata$sample_name,
    condition     = ct$metadata$condition,
    normalization = nm,
    norm_factor   = switch(nm,
      TMM      = ct$nf_tmm,
      Quantile = ct$nf_q,
      Loess    = rep(NA_real_, nrow(ct$metadata))
    )
  )
  cat("\nNorm factors:\n")
  print(nf_tbl)
  write_csv(nf_tbl,
            file.path(dirs$diff, paste0("chip_norm_factors_", assay_name, ".csv")))

  # Save region tables
  write_csv(
    as_tibble(as.data.frame(com)),
    file.path(dirs$diff, paste0("chip_results_", assay_name, ".csv"))
  )
  if (sum(is_sig) > 0)
    write_csv(
      as_tibble(as.data.frame(com)) %>% filter(is_sig),
      file.path(dirs$diff, paste0("chip_significant_", assay_name, ".csv"))
    )

  # --- Gene-level analysis via overlapResults ---
  cat("\nGene-level analysis...\n")
  gene_ranges <- genes(TxDb.Mmusculus.UCSC.mm10.knownGene)
  olap_gene   <- overlapResults(ct$filtered_se,
                                tab     = res$ql_large$res$table,
                                regions = gene_ranges)

  gene_tbl <- as_tibble(as.data.frame(olap_gene$combined)) %>%
    mutate(
      entrez = names(gene_ranges),
      symbol = mapIds(org.Mm.eg.db, entrez, "SYMBOL", "ENTREZID",
                      multiVals = "first")
    ) %>%
    arrange(PValue)

  is_sig_gene <- !is.na(gene_tbl$FDR) & gene_tbl$FDR <= fdr_thresh &
                   abs(gene_tbl$rep.logFC) >= lfc_thresh
  n_sig_gene  <- sum(is_sig_gene)
  cat(sprintf("Significant genes (FDR <= %.2f, |logFC| >= %.2f): %d\n",
              fdr_thresh, lfc_thresh, n_sig_gene))
  if (n_sig_gene > 0) {
    cat("  Gained:", sum(is_sig_gene & gene_tbl$rep.logFC > 0, na.rm = TRUE), "\n")
    cat("  Lost:",   sum(is_sig_gene & gene_tbl$rep.logFC < 0, na.rm = TRUE), "\n")
  }
  write_csv(gene_tbl,
            file.path(dirs$diff, paste0("chip_gene_results_", assay_name, ".csv")))

  # --- Plots ---
  cat("Producing plots...\n")
  create_ma_plot(res, assay_name, dirs)
  create_volcano_plot(res, assay_name, dirs)
  create_gene_ma_plot(gene_tbl, res$ql_large, assay_name, dirs)

  # Return: structure compatible with 03_ChIPseq_annotation.R
  list(
    metadata = meta_ip,
    ql_large = res$ql_large,
    merged   = res$merged,
    genes_ql = list(olap = olap_gene, table = gene_tbl)
  )
}

# ============================================================================
# Run
# ============================================================================

assays <- names(prep)

analysis <- setNames(
  lapply(assays, run_differential,
         prep = prep, norm_choice = norm_choice, dirs = dirs),
  assays
)

# ============================================================================
# Summary table + save
# ============================================================================

summary_stats <- map_dfr(names(analysis), function(assay_name) {
  ct   <- analysis[[assay_name]]
  com  <- ct$merged$combined
  is_s <- !is.na(com$FDR) & com$FDR <= fdr_thresh &
            abs(as.numeric(com$rep.logFC)) >= lfc_thresh
  gtbl  <- ct$genes_ql$table
  tibble(
    assay         = assay_name,
    normalization = norm_choice[assay_name],
    fdr_threshold = fdr_thresh,
    lfc_threshold = lfc_thresh,
    n_wt          = sum(ct$metadata$condition == "WT"),
    n_ctko        = sum(ct$metadata$condition == "cTKO"),
    total_regions = nrow(com),
    sig_regions   = sum(is_s, na.rm = TRUE),
    gained        = sum(com$direction == "up"   & is_s, na.rm = TRUE),
    lost          = sum(com$direction == "down" & is_s, na.rm = TRUE),
    sig_genes     = sum(!is.na(gtbl$FDR) & gtbl$FDR <= fdr_thresh &
                          abs(gtbl$rep.logFC) >= lfc_thresh, na.rm = TRUE)
  )
})

print(summary_stats)
write_csv(summary_stats, file.path(dirs$data, "chip_summary_statistics.csv"))

saveRDS(analysis, file.path(dirs$data, "csaw_chip_analysis_results.rds"))
save(analysis, metadata, file = file.path(dirs$data, "chip_csaw_analysis.RData"))

cat("\n=== 02_ChIPseq_differential.R complete ===\n")
cat("Output: ../../results/ChIPseq/data/\n")
