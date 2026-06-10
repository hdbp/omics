if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(ChIPseeker)
library(TxDb.Mmusculus.UCSC.mm9.knownGene)
library(org.Mm.eg.db)
library(ggrepel)
library(patchwork)

cat("\n=== Genomic feature annotation ===\n")

analysis <- readRDS(file.path(dirs$data, "csaw_atac_analysis_results.rds"))

txdb    <- TxDb.Mmusculus.UCSC.mm9.knownGene
anno_db <- "org.Mm.eg.db"

simplify_annotation <- function(annotation_col) {
  case_when(
    str_detect(annotation_col, "Promoter")          ~ "Promoter",
    str_detect(annotation_col, "5' UTR")            ~ "5' UTR",
    str_detect(annotation_col, "3' UTR")            ~ "3' UTR",
    str_detect(annotation_col, "Exon")              ~ "Exon",
    str_detect(annotation_col, "Intron")            ~ "Intron",
    str_detect(annotation_col, "Downstream")        ~ "Downstream",
    str_detect(annotation_col, "Distal Intergenic") ~ "Distal intergenic",
    TRUE                                            ~ "Other"
  )
}

feature_order <- c("Promoter", "5' UTR", "Exon", "Intron",
                   "3' UTR", "Downstream", "Distal intergenic", "Other")

# ============================================================================
# Size distribution of increased-accessibility regions
# ============================================================================

cat("\nSize distributions...\n")

size_data <- map_dfr(names(analysis), function(ct_name) {
  ct  <- analysis[[ct_name]]
  sel <- .select_increased(ct)
  cat(ct_name, ": using", sel$label, "\n")
  tibble(
    cell_type = ct_name,
    label     = sel$label,
    width_bp  = width(ct$merged$regions[sel$idx])
  )
})

if (nrow(size_data) > 0) {

  strip_labels <- size_data %>%
    distinct(cell_type, label) %>%
    mutate(strip = paste0(cell_type, "\n(", label, ")"))
  size_data <- left_join(size_data, strip_labels, by = c("cell_type", "label"))

  p_size <- ggplot(size_data, aes(x = width_bp, fill = cell_type)) +
    geom_histogram(bins = 60, color = "white", linewidth = 0.2) +
    facet_wrap(~ strip, scales = "free_y") +
    scale_x_continuous(limits = c(0, NA), labels = scales::label_comma()) +
    scale_fill_brewer(palette = "Set1", guide = "none") +
    labs(title = "Size distribution of increased-accessibility regions",
         x = "Region width (bp)", y = "Count") +
    theme_minimal(base_size = 12) +
    theme(plot.title       = element_text(face = "bold"),
          panel.grid.minor = element_blank(),
          strip.text       = element_text(face = "bold", size = 8))

  pdf(file.path(dirs$annot, "atac_size_distribution_increased.pdf"),
      width = 10, height = 4)
  print(p_size)
  dev.off()

  cat("Median sizes (bp):\n")
  print(size_data %>% group_by(cell_type) %>%
        summarise(n = n(), median_bp = median(width_bp), max_bp = max(width_bp)))
}

# ============================================================================
# Feature annotation bar charts
# ============================================================================

cat("\nAnnotating peaks...\n")

anno_data <- map_dfr(names(analysis), function(ct_name) {
  ct  <- analysis[[ct_name]]
  sel <- .select_increased(ct)
  cat(ct_name, ": using", sel$label, "\n")

  regions_sel <- ct$merged$regions[sel$idx]
  peak_anno   <- annotatePeak(regions_sel, TxDb = txdb, annoDb = anno_db,
                              verbose = FALSE)
  anno_df     <- as_tibble(as.data.frame(peak_anno))

  write_csv(anno_df,
            file.path(dirs$annot, paste0("atac_annotated_increased_", ct_name, ".csv")))

  anno_df %>%
    transmute(cell_type = ct_name,
              peak_set  = sel$label,
              feature   = simplify_annotation(annotation))
})

if (nrow(anno_data) > 0) {

  feature_pct <- anno_data %>%
    dplyr::count(cell_type, peak_set, feature) %>%
    group_by(cell_type) %>%
    mutate(pct      = n / sum(n) * 100,
           feature  = factor(feature, levels = feature_order),
           ct_label = paste0(cell_type, "\n(", peak_set, ")")) %>%
    filter(!is.na(feature)) %>%
    ungroup()

  p_anno <- ggplot(feature_pct, aes(x = ct_label, y = pct, fill = feature)) +
    geom_col(width = 0.6) +
    geom_text(aes(label = if_else(pct >= 3, sprintf("%.1f%%", pct), "")),
              position = position_stack(vjust = 0.5),
              size = 3, color = "white", fontface = "bold") +
    scale_fill_brewer(palette = "Set2", name = "Feature") +
    scale_y_continuous(labels = scales::label_percent(scale = 1),
                       expand = expansion(mult = c(0, 0.02))) +
    labs(title    = "Genomic feature distribution — increased accessibility",
         subtitle = "FDR-significant peaks where available; top 500 by p-value otherwise",
         x = NULL, y = "Percentage") +
    theme_minimal(base_size = 12) +
    theme(plot.title         = element_text(face = "bold"),
          axis.text.x        = element_text(size = 8),
          panel.grid.major.x = element_blank(),
          panel.grid.minor   = element_blank(),
          legend.position    = "right")

  pdf(file.path(dirs$annot, "atac_feature_annotation_increased.pdf"),
      width = 11, height = 5)
  print(p_anno)
  dev.off()
}

# ============================================================================
# Feature annotation by logFC quantile
# Regions ranked by rep.logFC and split into quartiles to test whether
# strongly vs weakly increased regions differ in genomic feature composition.
# ============================================================================

cat("\nQuantile annotation...\n")

n_quantiles <- 4

anno_quant_data <- map_dfr(names(analysis), function(ct_name) {
  ct  <- analysis[[ct_name]]
  sel <- .select_increased(ct)

  combined_sel <- as_tibble(as.data.frame(ct$merged$combined[sel$idx, ])) %>%
    mutate(q = ntile(rep.logFC, n_quantiles), .row = row_number())
  regions_sel  <- ct$merged$regions[sel$idx]

  map_dfr(seq_len(n_quantiles), function(q_val) {
    sub <- filter(combined_sel, q == q_val)
    if (nrow(sub) == 0L) return(NULL)
    peak_anno <- annotatePeak(regions_sel[pull(sub, .row)], TxDb = txdb,
                              annoDb = anno_db, verbose = FALSE)
    as_tibble(as.data.frame(peak_anno)) %>%
      transmute(
        cell_type = ct_name,
        quantile  = factor(paste0("Q", q_val), levels = paste0("Q", seq_len(n_quantiles))),
        logFC_min = min(pull(sub, rep.logFC), na.rm = TRUE),
        logFC_max = max(pull(sub, rep.logFC), na.rm = TRUE),
        feature   = simplify_annotation(annotation)
      )
  })
})

if (nrow(anno_quant_data) > 0) {

  quant_pct <- anno_quant_data %>%
    dplyr::count(cell_type, quantile, logFC_min, logFC_max, feature) %>%
    group_by(cell_type, quantile) %>%
    mutate(
      pct     = n / sum(n) * 100,
      feature = factor(feature, levels = feature_order),
      q_label = sprintf("%s\n[%.2f–%.2f]", quantile,
                        dplyr::first(logFC_min), dplyr::first(logFC_max))
    ) %>%
    filter(!is.na(feature)) %>%
    ungroup()

  p_quant <- ggplot(quant_pct, aes(x = q_label, y = pct, fill = feature)) +
    geom_col(width = 0.7) +
    geom_text(aes(label = if_else(pct >= 4, sprintf("%.0f%%", pct), "")),
              position = position_stack(vjust = 0.5),
              size = 2.8, color = "white", fontface = "bold") +
    facet_wrap(~ cell_type, nrow = 1, scales = "free_x") +
    scale_fill_brewer(palette = "Set2", name = "Feature") +
    scale_y_continuous(labels = scales::label_percent(scale = 1),
                       expand = expansion(mult = c(0, 0.02))) +
    labs(title    = "Genomic feature distribution by log2FC quantile — increased accessibility",
         subtitle = "Q1 = weakest increase → Q4 = strongest; brackets show rep.logFC range",
         x = NULL, y = "Percentage") +
    theme_minimal(base_size = 11) +
    theme(plot.title         = element_text(face = "bold"),
          strip.text         = element_text(face = "bold"),
          axis.text.x        = element_text(size = 8),
          panel.grid.major.x = element_blank(),
          panel.grid.minor   = element_blank(),
          legend.position    = "right")

  pdf(file.path(dirs$annot, "atac_feature_annotation_by_quantile.pdf"),
      width = 14, height = 5)
  print(p_quant)
  dev.off()
}

# ============================================================================
# Promoter and distal gene lists + promoter volcano
#
# All FDR-significant peaks (both gained and lost) are annotated once per
# cell type, then split into:
#   - Promoter peaks → genes with direct promoter accessibility changes
#   - Distal intergenic peaks within distal_kb of a TSS → candidate enhancers
#
# The promoter volcano is placed here because this is where gene symbols are
# available, making it the natural complement to the all-peaks volcano in 02.
# ============================================================================

fdr_thresh   <- 0.05
distal_kb    <- 50
top_n_label  <- 15
dir_colors   <- c(up = "#E41A1C", down = "#377EB8")

cat("\nAnnotating all significant peaks (gained + lost)...\n")

volcano_plots <- lapply(names(analysis), function(ct_name) {

  ct  <- analysis[[ct_name]]
  com <- as_tibble(as.data.frame(ct$merged$combined))
  reg <- ct$merged$regions

  sig_idx <- which(!is.na(com$FDR) & com$FDR <= fdr_thresh)

  if (length(sig_idx) == 0L) {
    cat(ct_name, ": no significant peaks\n")
    return(NULL)
  }

  cat(ct_name, ":", length(sig_idx), "significant peaks\n")

  peak_anno <- annotatePeak(reg[sig_idx], TxDb = txdb,
                            annoDb = anno_db, verbose = FALSE)

  anno_df <- as_tibble(as.data.frame(peak_anno)) %>%
    mutate(
      logFC     = as.numeric(com$rep.logFC[sig_idx]),
      FDR       = as.numeric(com$FDR[sig_idx]),
      direction = as.character(com$direction[sig_idx]),
      cell_type = ct_name
    )

  # --- Promoter gene list ---
  promo_df <- anno_df %>%
    dplyr::filter(str_detect(annotation, "Promoter"), !is.na(SYMBOL)) %>%
    dplyr::select(cell_type, SYMBOL, logFC, FDR, direction,
                  annotation, distanceToTSS)

  cat(sprintf("  Promoter: %d peaks (gained: %d | lost: %d)\n",
              nrow(promo_df),
              sum(promo_df$direction == "up"),
              sum(promo_df$direction == "down")))

  write_csv(promo_df,
            file.path(dirs$annot,
                      paste0("atac_promoter_genes_", ct_name, ".csv")))

  # --- Distal intergenic gene list ---
  distal_df <- anno_df %>%
    dplyr::filter(
      str_detect(annotation, "Distal Intergenic"),
      abs(distanceToTSS) <= distal_kb * 1000L,
      !is.na(SYMBOL)
    ) %>%
    dplyr::select(cell_type, SYMBOL, logFC, FDR, direction,
                  annotation, distanceToTSS)

  cat(sprintf("  Distal intergenic (<= %d kb): %d peaks (gained: %d | lost: %d)\n",
              distal_kb, nrow(distal_df),
              sum(distal_df$direction == "up"),
              sum(distal_df$direction == "down")))

  write_csv(distal_df,
            file.path(dirs$annot,
                      paste0("atac_distal_genes_", ct_name, ".csv")))

  # --- Promoter volcano ---
  if (nrow(promo_df) == 0L) return(NULL)

  top_genes <- promo_df %>%
    slice_max(abs(logFC), n = top_n_label, with_ties = FALSE)

  ggplot(promo_df, aes(x = logFC, y = -log10(FDR), color = direction)) +
    geom_point(size = 1.5, alpha = 0.8) +
    geom_hline(yintercept = -log10(fdr_thresh), linetype = "dashed",
               color = "grey40", linewidth = 0.4) +
    geom_vline(xintercept = 0, linetype = "dashed",
               color = "grey40", linewidth = 0.4) +
    geom_text_repel(data = top_genes, aes(label = SYMBOL),
                    size = 2.5, max.overlaps = 15,
                    segment.size = 0.2, show.legend = FALSE) +
    scale_color_manual(values = dir_colors,
                       labels = c(up = "Gained", down = "Lost"),
                       name = NULL) +
    labs(title    = ct_name,
         subtitle = sprintf("FDR ≤ %.2f  |  %d promoter peaks", fdr_thresh, nrow(promo_df)),
         x        = "log2FC (cTKO / WT)",
         y        = expression(-log[10](FDR))) +
    theme_classic(base_size = 11) +
    theme(plot.title      = element_text(face = "bold"),
          plot.subtitle   = element_text(size = 9, colour = "grey40"),
          legend.position = "top")
})

names(volcano_plots) <- names(analysis)
valid_plots <- Filter(Negate(is.null), volcano_plots)

if (length(valid_plots) > 0) {
  panel <- wrap_plots(valid_plots, nrow = 1) +
    plot_annotation(
      title = "Promoter accessibility — cTKO vs WT",
      theme = theme(plot.title = element_text(face = "bold", size = 13))
    )
  pdf(file.path(dirs$annot, "atac_promoter_volcano.pdf"),
      width = 5 * length(valid_plots), height = 6)
  print(panel)
  dev.off()
  cat("Promoter volcano saved.\n")
}

cat("\n=== 03_annotation.R complete ===\n")
cat("Output: ../../results/ATACseq/annotation/\n")
