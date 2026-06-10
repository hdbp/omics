if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(ChIPseeker)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)
library(org.Mm.eg.db)

cat("\n=== Genomic feature annotation ===\n")

# ============================================================================
# USER SETTINGS — must match the thresholds used in 02_ChIPseq_differential.R
# ============================================================================

fdr_thresh <- 0.10   # FDR threshold for significance calls
lfc_thresh <- 1      # minimum |log2FC|; 0 = no fold-change filter

cat(sprintf("Thresholds: FDR <= %.2f  |  |logFC| >= %.2f\n",
            fdr_thresh, lfc_thresh))

analysis <- readRDS(file.path(dirs$data, "csaw_chip_analysis_results.rds"))

txdb    <- TxDb.Mmusculus.UCSC.mm10.knownGene
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

# Returns indices of significant regions for a given direction
select_direction <- function(ct, direction) {
  com <- ct$merged$combined
  which(!is.na(com$FDR) & com$FDR <= fdr_thresh &
          abs(as.numeric(com$rep.logFC)) >= lfc_thresh &
          com$direction == direction)
}

directions      <- c(gained = "up", lost = "down")
direction_color <- c(gained = "#E41A1C", lost = "#377EB8")

# ============================================================================
# Size distribution — gained and lost, per assay
# ============================================================================

cat("\nSize distributions...\n")

walk(names(analysis), function(assay_name) {

  ct <- analysis[[assay_name]]

  size_data <- map_dfr(names(directions), function(dir_label) {
    idx <- select_direction(ct, directions[[dir_label]])
    if (length(idx) == 0L) return(NULL)
    cat(assay_name, dir_label, ":", length(idx), "regions\n")
    tibble(direction = dir_label, width_bp = width(ct$merged$regions[idx]))
  })

  if (nrow(size_data) == 0L) return(invisible(NULL))

  p <- ggplot(size_data, aes(x = width_bp, fill = direction)) +
    geom_histogram(bins = 60, color = "white", linewidth = 0.2) +
    facet_wrap(~ direction, scales = "free_y") +
    scale_x_continuous(limits = c(0, NA), labels = scales::label_comma()) +
    scale_fill_manual(values = direction_color, guide = "none") +
    labs(title = paste(assay_name, "— size distribution of DB regions"),
         x = "Region width (bp)", y = "Count") +
    theme_minimal(base_size = 12) +
    theme(plot.title       = element_text(face = "bold"),
          panel.grid.minor = element_blank(),
          strip.text       = element_text(face = "bold"))

  pdf(file.path(dirs$annot, paste0("chip_size_distribution_", assay_name, ".pdf")),
      width = 10, height = 4)
  print(p)
  dev.off()

  cat("Median sizes (bp):\n")
  print(size_data %>% group_by(direction) %>%
        summarise(n = n(), median_bp = median(width_bp), max_bp = max(width_bp)))
})

# ============================================================================
# Feature annotation bar charts — gained and lost side by side, per assay
# ============================================================================

cat("\nAnnotating peaks...\n")

walk(names(analysis), function(assay_name) {

  ct <- analysis[[assay_name]]

  anno_data <- map_dfr(names(directions), function(dir_label) {
    idx <- select_direction(ct, directions[[dir_label]])
    if (length(idx) == 0L) return(NULL)
    cat(assay_name, dir_label, ": annotating", length(idx), "regions\n")

    regions_sel <- ct$merged$regions[idx]
    peak_anno   <- annotatePeak(regions_sel, TxDb = txdb, annoDb = anno_db,
                                verbose = FALSE)
    anno_df     <- as_tibble(as.data.frame(peak_anno))

    write_csv(anno_df,
              file.path(dirs$annot,
                        paste0("chip_annotated_", assay_name, "_", dir_label, ".csv")))

    anno_df %>%
      transmute(direction = dir_label,
                feature   = simplify_annotation(annotation))
  })

  if (nrow(anno_data) == 0L) return(invisible(NULL))

  feature_pct <- anno_data %>%
    dplyr::count(direction, feature) %>%
    group_by(direction) %>%
    mutate(pct     = n / sum(n) * 100,
           feature = factor(feature, levels = feature_order)) %>%
    filter(!is.na(feature)) %>%
    ungroup()

  p <- ggplot(feature_pct, aes(x = direction, y = pct, fill = feature)) +
    geom_col(width = 0.6) +
    geom_text(aes(label = if_else(pct >= 3, sprintf("%.1f%%", pct), "")),
              position = position_stack(vjust = 0.5),
              size = 3, color = "white", fontface = "bold") +
    scale_fill_brewer(palette = "Set2", name = "Feature") +
    scale_y_continuous(labels = scales::label_percent(scale = 1),
                       expand = expansion(mult = c(0, 0.02))) +
    labs(title    = paste(assay_name, "— genomic feature distribution"),
         subtitle = sprintf("FDR ≤ %.2f, |logFC| ≥ %.2f DB regions (cTKO vs WT)",
                            fdr_thresh, lfc_thresh),
         x = NULL, y = "Percentage") +
    theme_minimal(base_size = 12) +
    theme(plot.title         = element_text(face = "bold"),
          panel.grid.major.x = element_blank(),
          panel.grid.minor   = element_blank(),
          legend.position    = "right")

  pdf(file.path(dirs$annot, paste0("chip_feature_annotation_", assay_name, ".pdf")),
      width = 7, height = 5)
  print(p)
  dev.off()
})

# ============================================================================
# Feature annotation by logFC quantile — per assay, per direction
# Gained: Q1 = weakest gain → Q4 = strongest gain  (ascending logFC)
# Lost:   Q1 = weakest loss → Q4 = strongest loss   (descending logFC)
# ============================================================================

cat("\nQuantile annotation...\n")

n_quantiles <- 4

walk(names(analysis), function(assay_name) {
  ct <- analysis[[assay_name]]

  walk(names(directions), function(dir_label) {
    idx <- select_direction(ct, directions[[dir_label]])
    if (length(idx) == 0L) return(invisible(NULL))

    combined_sel <- as_tibble(as.data.frame(ct$merged$combined[idx, ])) %>%
      mutate(
        sort_fc = if (dir_label == "lost") -rep.logFC else rep.logFC,
        q       = ntile(sort_fc, n_quantiles),
        .row    = row_number()
      )
    regions_sel <- ct$merged$regions[idx]

    quant_data <- map_dfr(seq_len(n_quantiles), function(q_val) {
      sub <- filter(combined_sel, q == q_val)
      if (nrow(sub) == 0L) return(NULL)
      peak_anno <- annotatePeak(regions_sel[pull(sub, .row)], TxDb = txdb,
                                annoDb = anno_db, verbose = FALSE)
      as_tibble(as.data.frame(peak_anno)) %>%
        transmute(
          quantile  = factor(paste0("Q", q_val),
                             levels = paste0("Q", seq_len(n_quantiles))),
          logFC_min = min(pull(sub, rep.logFC), na.rm = TRUE),
          logFC_max = max(pull(sub, rep.logFC), na.rm = TRUE),
          feature   = simplify_annotation(annotation)
        )
    })

    if (nrow(quant_data) == 0L) return(invisible(NULL))

    quant_pct <- quant_data %>%
      dplyr::count(quantile, logFC_min, logFC_max, feature) %>%
      group_by(quantile) %>%
      mutate(
        pct     = n / sum(n) * 100,
        feature = factor(feature, levels = feature_order),
        q_label = sprintf("%s\n[%.2f–%.2f]", quantile,
                          dplyr::first(logFC_min), dplyr::first(logFC_max))
      ) %>%
      filter(!is.na(feature)) %>%
      ungroup()

    subtitle <- if (dir_label == "gained") {
      "Q1 = weakest gain → Q4 = strongest gain; brackets show rep.logFC range"
    } else {
      "Q1 = weakest loss → Q4 = strongest loss; brackets show rep.logFC range"
    }

    p <- ggplot(quant_pct, aes(x = q_label, y = pct, fill = feature)) +
      geom_col(width = 0.7) +
      geom_text(aes(label = if_else(pct >= 4, sprintf("%.0f%%", pct), "")),
                position = position_stack(vjust = 0.5),
                size = 2.8, color = "white", fontface = "bold") +
      scale_fill_brewer(palette = "Set2", name = "Feature") +
      scale_y_continuous(labels = scales::label_percent(scale = 1),
                         expand = expansion(mult = c(0, 0.02))) +
      labs(title    = paste(assay_name, "—", dir_label,
                            "regions by log2FC quantile"),
           subtitle = subtitle,
           x = NULL, y = "Percentage") +
      theme_minimal(base_size = 11) +
      theme(plot.title         = element_text(face = "bold"),
            axis.text.x        = element_text(size = 8),
            panel.grid.major.x = element_blank(),
            panel.grid.minor   = element_blank(),
            legend.position    = "right")

    pdf(file.path(dirs$annot,
                  paste0("chip_feature_by_quantile_", assay_name, "_", dir_label, ".pdf")),
        width = 9, height = 5)
    print(p)
    dev.off()
  })
})

# ============================================================================
# UpSet plot — pairwise and higher-order overlaps across all 4 DB sets
# Sets: H3K27me3 gained | H3K27me3 lost | H3K36me2 gained | H3K36me2 lost
# ============================================================================

cat("\nUpSet plot of region overlaps...\n")
library(ComplexHeatmap)

flat_sets <- list()
for (an in names(analysis)) {
  ct <- analysis[[an]]
  for (dl in names(directions)) {
    idx <- select_direction(ct, directions[[dl]])
    if (length(idx) > 0L)
      flat_sets[[paste(an, dl)]] <- ct$merged$regions[idx]
  }
}

cat("Region counts per set:\n")
for (nm in names(flat_sets))
  cat(sprintf("  %-30s %d\n", nm, length(flat_sets[[nm]])))

if (length(flat_sets) >= 2) {

  all_regions <- reduce(do.call(c, unname(flat_sets)))
  mat <- sapply(flat_sets, function(gr)
                  as.integer(overlapsAny(all_regions, gr)))

  set_col <- ifelse(grepl("gained", colnames(mat)),
                    direction_color["gained"],
                    direction_color["lost"])
  names(set_col) <- colnames(mat)

  m <- make_comb_mat(mat)

  pdf(file.path(dirs$annot, "chip_upset_db_regions.pdf"),
      width = 9, height = 5)
  draw(UpSet(
    m,
    comb_order       = order(comb_size(m), decreasing = TRUE),
    top_annotation   = upset_top_annotation(m, add_numbers = TRUE),
    right_annotation = upset_right_annotation(m, add_numbers = TRUE),
    row_names_gp     = gpar(col = set_col, fontsize = 10),
    pt_size          = unit(5, "mm"),
    lwd              = 2
  ))
  dev.off()
  cat("UpSet plot saved: chip_upset_db_regions.pdf\n")

} else {
  cat("Fewer than 2 non-empty sets — skipping UpSet plot.\n")
}

cat("\n=== 03_ChIPseq_annotation.R complete ===\n")
cat("Output: ../../results/ChIPseq/annotation/\n")
