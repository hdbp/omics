if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(edgeR)
library(MASS)

cat("\n=== Differential accessibility plots ===\n")

analysis <- readRDS(file.path(dirs$data, "csaw_atac_analysis_results.rds"))

# ============================================================================
# MA plots  (window-level + peak-level, side by side)
# ============================================================================

create_ma_plot <- function(ct, cell_type_name, dirs) {

  pdf(file.path(dirs$diff, paste0("atac_ma_plot_", cell_type_name, ".pdf")),
      width = 12, height = 6)
  par(mfrow = c(1, 2))

  # Window-level
  sig_windows <- ct$results$table$PValue < 0.05 / nrow(ct$results$table)
  plotMD(
    ct$results,
    status = ifelse(sig_windows, "Sig", "NotSig"),
    values = "Sig",
    hl.col = "red",
    bg.col = adjustcolor("black", alpha.f = 0.3),
    cex    = 0.3,
    main   = paste(cell_type_name, "- Windows"),
    xlab   = "Average log CPM",
    ylab   = "Log2 FC (cTKO/WT)",
    legend = "topright"
  )
  abline(h = 0, col = "blue", lty = 2)

  # Peak-level (logCPM indexed from rep.test window)
  com_df <- as_tibble(ct$merged$combined) %>%
    mutate(logCPM = as.numeric(ct$results$table$logCPM[rep.test]),
           logFC  = as.numeric(rep.logFC),
           fdr    = as.numeric(FDR)) %>%
    filter(is.finite(logCPM) & is.finite(logFC)) %>%
    mutate(status = case_when(
      fdr > 0.05          ~ "NotSig",
      direction == "up"   ~ "Increased",
      direction == "down" ~ "Decreased",
      TRUE                ~ "Mixed"
    ))

  pt_col <- c(
    NotSig    = adjustcolor("gray50", alpha.f = 0.4),
    Increased = "red",
    Decreased = "blue",
    Mixed     = "purple"
  )

  plot(
    com_df$logCPM, com_df$logFC,
    col  = pt_col[com_df$status],
    pch  = 16, cex = 0.5,
    main = paste(cell_type_name, "- Merged Peaks"),
    xlab = "Average log CPM",
    ylab = "Log2 FC (cTKO/WT)"
  )
  legend("topright", legend = names(pt_col), col = pt_col, pch = 16, cex = 0.8)
  abline(h = 0, col = "black", lty = 2)

  dev.off()
}

# ============================================================================
# Volcano plots  (density-coloured)
# ============================================================================

create_volcano_plot <- function(ct, cell_type_name, dirs) {

  pdf(file.path(dirs$diff, paste0("atac_volcano_", cell_type_name, ".pdf")),
      width = 8, height = 8)

  df <- as_tibble(ct$merged$combined) %>%
    transmute(logFC       = as.numeric(rep.logFC),
              neg_log_fdr = -log10(as.numeric(FDR))) %>%
    filter(is.finite(logFC) & is.finite(neg_log_fdr))

  # bw.nrd0 returns 0 on degenerate distributions; clamp so kde2d doesn't fail
  h_x <- max(bw.nrd0(df$logFC),       diff(range(df$logFC))       / 10, 0.01)
  h_y <- max(bw.nrd0(df$neg_log_fdr), diff(range(df$neg_log_fdr)) / 10, 0.01)

  dens       <- kde2d(df$logFC, df$neg_log_fdr, n = 100, h = c(h_x, h_y))
  ix         <- pmax(1, pmin(findInterval(df$logFC,       dens$x), length(dens$x)))
  iy         <- pmax(1, pmin(findInterval(df$neg_log_fdr, dens$y), length(dens$y)))
  df$density <- dens$z[cbind(ix, iy)]

  p <- ggplot(df, aes(x = logFC, y = neg_log_fdr)) +
    geom_point(aes(color = density), size = 0.8, alpha = 0.6) +
    scale_color_viridis_c(name = "Density") +
    geom_hline(yintercept = -log10(0.05), linetype = "dashed", color = "red") +
    labs(
      title    = paste(cell_type_name, "- Differential Accessibility"),
      subtitle = "cTKO vs WT",
      x        = "Log2 Fold Change (cTKO/WT)",
      y        = "-log10(FDR)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title       = element_text(face = "bold"),
          panel.grid.minor = element_blank())

  print(p)
  dev.off()
}

# ============================================================================
# Run
# ============================================================================

walk(names(analysis), function(ct_name) {
  cat(ct_name, "...\n")
  create_ma_plot(analysis[[ct_name]],      ct_name, dirs)
  create_volcano_plot(analysis[[ct_name]], ct_name, dirs)
})

cat("\n=== 02_differential.R complete ===\n")
cat("Output: ../../results/ATACseq/differential/\n")
