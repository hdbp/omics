if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
source("helper_functions/helpers.R")
library(ChIPseeker)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)
library(org.Mm.eg.db)
library(GenomicRanges)
library(edgeR)
library(ggrepel)
library(patchwork)
library(rtracklayer)

# ============================================================================
# Thresholds
# ============================================================================

atac_fdr_thresh <- 0.05
chip_fdr_thresh <- 0.05
top_n_label     <- 15

# ChIPseq (H3K27me3, H3K36me2) was performed on CD8 T cells.
# ATAC-seq covers CD4, CD8, and B-Cell. Only CD8 is a valid comparison.
atac_ct <- "CD8"

cat("\n=== ATAC-seq x H3K27me3 ChIP-seq integration (CD8) ===\n")
cat(sprintf("ATAC FDR <= %.2f  |  H3K27me3 FDR <= %.2f\n\n",
            atac_fdr_thresh, chip_fdr_thresh))

# ============================================================================
# Load upstream results
# ============================================================================

atac_analysis <- readRDS(file.path(atac_data, "csaw_atac_analysis_results.rds"))
chip_analysis <- readRDS(file.path(chip_data, "csaw_chip_analysis_results.rds"))
chip_prep     <- readRDS(file.path(chip_data, "chip_norm_prep.rds"))

txdb <- TxDb.Mmusculus.UCSC.mm10.knownGene

# H3K27me3 differential regions and normalized windows
k27_merged  <- chip_analysis[["H3K27me3"]]$merged
k27_prep    <- chip_prep[["H3K27me3"]]

# H3K27me3 logCPM per 2kb window (TMM-normalized)
y27       <- k27_prep$norm$TMM$ql_large$y
lcpm27    <- cpm(y27, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 1)
wt_idx    <- which(k27_prep$metadata$condition == "WT")
ctko_idx  <- which(k27_prep$metadata$condition == "cTKO")
win27_gr  <- rowRanges(k27_prep$filtered_se)
lfc27_win <- rowMeans(lcpm27[, ctko_idx, drop = FALSE]) -
             rowMeans(lcpm27[, wt_idx,   drop = FALSE])

# ATAC BAMs were aligned to mm9; ChIP is mm10. LiftOver ATAC peaks mm9→mm10
# (always lift older to newer) before overlap and annotation.
chain_gz   <- file.path(dirs$data, "mm9ToMm10.over.chain.gz")
chain_path <- sub("\\.gz$", "", chain_gz)
if (!file.exists(chain_path)) {
  if (!file.exists(chain_gz))
    download.file(
      "https://hgdownload.soe.ucsc.edu/goldenPath/mm9/liftOver/mm9ToMm10.over.chain.gz",
      chain_gz, mode = "wb"
    )
  system(paste("gunzip -k", shQuote(chain_gz)))
}
chain <- import.chain(chain_path)

cat("H3K27me3 windows available:", length(win27_gr), "\n")
cat("H3K27me3 differential regions:",
    nrow(k27_merged$combined), "total |",
    sum(!is.na(k27_merged$combined$FDR) & k27_merged$combined$FDR <= chip_fdr_thresh),
    "significant\n\n")

# ============================================================================
# Analysis 1 — Promoter accessibility vs H3K27me3 at the same promoters
#
# For each ATAC cell type, significant promoter peaks are annotated and
# overlapped with H3K27me3 differential merged regions. This tests whether
# changes in chromatin opening at promoters are accompanied by changes in
# H3K27me3 at the same loci, revealing a direct link between the two marks.
# ============================================================================

cat("====== ANALYSIS 1: PROMOTER ATAC vs H3K27me3 ======\n")

# H3K27me3 differential merged regions with logFC and FDR
k27_df <- as_tibble(as.data.frame(k27_merged$combined)) %>%
  mutate(k27_logFC = as.numeric(rep.logFC),
         k27_fdr   = as.numeric(FDR),
         k27_dir   = as.character(direction)) %>%
  dplyr::select(k27_logFC, k27_fdr, k27_dir)
k27_regions <- k27_merged$regions

promo_k27_list <- lapply(atac_ct, function(ct_name) {

  cat("\n---", ct_name, "---\n")

  ct  <- atac_analysis[[ct_name]]
  com <- as_tibble(as.data.frame(ct$merged$combined))
  reg <- ct$merged$regions

  # Significant ATAC peaks — liftOver mm9→mm10 to match ChIP and TxDb
  sig_idx <- which(!is.na(com$FDR) & com$FDR <= atac_fdr_thresh)
  if (length(sig_idx) == 0L) { cat("No significant ATAC peaks\n"); return(NULL) }

  lo_atac     <- liftOver(reg[sig_idx], chain)
  mapped_atac <- lengths(lo_atac) == 1L
  sig_gr_mm10 <- unlist(lo_atac[mapped_atac])
  sig_idx_lo  <- sig_idx[mapped_atac]
  if (length(sig_idx_lo) == 0L) { cat("No ATAC peaks survive liftOver\n"); return(NULL) }
  cat(sprintf("  ATAC peaks after liftOver mm9→mm10: %d / %d\n",
              length(sig_idx_lo), length(sig_idx)))

  # Annotate with ChIPseeker, keep promoter peaks only
  peak_anno <- annotatePeak(sig_gr_mm10, TxDb = txdb,
                            annoDb = "org.Mm.eg.db", verbose = FALSE)
  atac_df <- as_tibble(as.data.frame(peak_anno)) %>%
    mutate(atac_logFC = as.numeric(com$rep.logFC[sig_idx_lo]),
           atac_fdr   = as.numeric(com$FDR[sig_idx_lo]),
           atac_dir   = as.character(com$direction[sig_idx_lo]),
           peak_idx   = seq_along(sig_idx_lo)) %>%
    dplyr::filter(str_detect(annotation, "Promoter"), !is.na(SYMBOL))

  cat("Promoter ATAC peaks:", nrow(atac_df), "\n")
  if (nrow(atac_df) == 0L) return(NULL)

  atac_promo_gr <- sig_gr_mm10[atac_df$peak_idx]

  hits <- findOverlaps(atac_promo_gr, k27_regions, ignore.strand = TRUE)

  if (length(hits) == 0L) {
    cat("No overlapping H3K27me3 regions\n")
    return(NULL)
  }

  # For peaks with multiple overlapping H3K27me3 regions, keep largest |logFC|
  k27_at_atac <- k27_df[subjectHits(hits), ] %>%
    mutate(atac_peak_idx = queryHits(hits)) %>%
    group_by(atac_peak_idx) %>%
    slice_max(abs(k27_logFC), n = 1, with_ties = FALSE) %>%
    ungroup()

  merged <- atac_df[k27_at_atac$atac_peak_idx, ] %>%
    bind_cols(k27_at_atac %>% dplyr::select(-atac_peak_idx)) %>%
    mutate(
      k27_sig = !is.na(k27_fdr) & k27_fdr <= chip_fdr_thresh,
      atac_sig = TRUE,
      concordance = case_when(
        k27_sig & atac_dir == "up"   & k27_dir == "down" ~ "Derepression",
        k27_sig & atac_dir == "down" & k27_dir == "up"   ~ "Silencing",
        k27_sig & atac_dir == "up"   & k27_dir == "up"   ~ "Discordant (both gain)",
        k27_sig & atac_dir == "down" & k27_dir == "down" ~ "Discordant (both lose)",
        !k27_sig                                          ~ "ATAC only",
        TRUE                                              ~ "Other"
      ),
      cell_type = ct_name
    )

  cat("Overlapping promoters:", nrow(merged), "\n")
  print(dplyr::count(merged, concordance) %>% arrange(desc(n)))

  merged

}) %>% set_names(atac_ct)

promo_k27_combined <- bind_rows(Filter(Negate(is.null), promo_k27_list))

# --- Scatter: ATAC logFC vs H3K27me3 logFC at promoters ---
conc_colors_k27 <- c(
  "Derepression"          = "#E41A1C",
  "Silencing"             = "#377EB8",
  "Discordant (both gain)"= "#984EA3",
  "Discordant (both lose)"= "#FF7F00",
  "ATAC only"             = "grey60"
)

if (nrow(promo_k27_combined) > 0) {

  top_genes <- promo_k27_combined %>%
    dplyr::filter(concordance %in% c("Derepression", "Silencing")) %>%
    group_by(cell_type) %>%
    slice_max(abs(atac_logFC), n = top_n_label, with_ties = FALSE) %>%
    ungroup()

  p_scatter <- ggplot(promo_k27_combined,
                      aes(x = atac_logFC, y = k27_logFC, color = concordance)) +
    geom_point(size = 1.2, alpha = 0.8) +
    geom_hline(yintercept = 0, linetype = "dashed", color = "grey40", linewidth = 0.4) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "grey40", linewidth = 0.4) +
    geom_text_repel(data = top_genes, aes(label = SYMBOL),
                    size = 2.5, max.overlaps = 12,
                    segment.size = 0.2, show.legend = FALSE) +
    facet_wrap(~ cell_type, nrow = 1) +
    scale_color_manual(values = conc_colors_k27, name = NULL) +
    labs(
      title    = "Promoter accessibility vs H3K27me3 — cTKO vs WT",
      subtitle = sprintf("ATAC FDR ≤ %.2f  |  H3K27me3 FDR ≤ %.2f (●)",
                         atac_fdr_thresh, chip_fdr_thresh),
      x = "ATAC log2FC (cTKO / WT)",
      y = "H3K27me3 log2FC (cTKO / WT)"
    ) +
    theme_minimal(base_size = 11) +
    theme(plot.title       = element_text(face = "bold"),
          panel.grid.minor = element_blank(),
          strip.text       = element_text(face = "bold"),
          legend.position  = "bottom")

  p_bar <- promo_k27_combined %>%
    dplyr::filter(concordance != "ATAC only") %>%
    dplyr::count(cell_type, concordance) %>%
    mutate(cell_type = factor(cell_type, levels = atac_ct)) %>%
    ggplot(aes(x = cell_type, y = n, fill = concordance)) +
    geom_col(width = 0.6) +
    geom_text(aes(label = n), position = position_stack(vjust = 0.5),
              size = 3, color = "white", fontface = "bold") +
    scale_fill_manual(values = conc_colors_k27, name = NULL) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
    labs(title = "Promoter concordance: ATAC vs H3K27me3",
         x = NULL, y = "Peak count") +
    theme_minimal(base_size = 11) +
    theme(plot.title         = element_text(face = "bold"),
          panel.grid.major.x = element_blank(),
          panel.grid.minor   = element_blank(),
          legend.position    = "bottom")

  panel1 <- p_scatter / p_bar +
    plot_layout(heights = c(2, 1)) +
    plot_annotation(
      title = "ATAC-seq × H3K27me3 — Promoter integration",
      theme = theme(plot.title = element_text(face = "bold", size = 13))
    )

  ggsave(file.path(dirs$plots, "integration_atac_h3k27me3_promoter.pdf"),
         panel1, width = 14, height = 10)

  write_csv(promo_k27_combined,
            file.path(dirs$data, "integration_atac_h3k27me3_promoter.csv"))
  cat("\nAnalysis 1 saved.\n")
}

# ============================================================================
# Analysis 2 — H3K27me3 signal at ATAC differential peaks
#
# Uses continuous TMM-normalized H3K27me3 logCPM (not just differential
# regions) to capture the full range of H3K27me3 change at ATAC peaks.
# Per ATAC cell type, peaks are split by direction (gained/lost) and feature
# (promoter vs distal intergenic) and the H3K27me3 logFC distribution is
# compared across groups. The expected pattern is H3K27me3 loss at gained
# peaks and H3K27me3 gain at lost peaks.
# ============================================================================

cat("\n\n====== ANALYSIS 2: H3K27me3 SIGNAL AT ATAC PEAKS ======\n")

signal_list <- lapply(atac_ct, function(ct_name) {

  cat("\n---", ct_name, "---\n")

  ct  <- atac_analysis[[ct_name]]
  com <- as_tibble(as.data.frame(ct$merged$combined))
  reg <- ct$merged$regions

  sig_idx <- which(!is.na(com$FDR) & com$FDR <= atac_fdr_thresh)
  if (length(sig_idx) == 0L) { cat("No significant ATAC peaks\n"); return(NULL) }

  lo_atac     <- liftOver(reg[sig_idx], chain)
  mapped_atac <- lengths(lo_atac) == 1L
  sig_gr_mm10 <- unlist(lo_atac[mapped_atac])
  sig_idx_lo  <- sig_idx[mapped_atac]
  if (length(sig_idx_lo) == 0L) { cat("No ATAC peaks survive liftOver\n"); return(NULL) }
  cat(sprintf("  ATAC peaks after liftOver mm9→mm10: %d / %d\n",
              length(sig_idx_lo), length(sig_idx)))

  # Annotate peaks
  peak_anno <- annotatePeak(sig_gr_mm10, TxDb = txdb,
                            annoDb = "org.Mm.eg.db", verbose = FALSE)
  anno_df <- as_tibble(as.data.frame(peak_anno)) %>%
    mutate(
      atac_logFC = as.numeric(com$rep.logFC[sig_idx_lo]),
      direction  = as.character(com$direction[sig_idx_lo]),
      feature    = case_when(
        str_detect(annotation, "Promoter")          ~ "Promoter",
        str_detect(annotation, "Distal Intergenic") ~ "Distal intergenic",
        TRUE                                        ~ "Other"
      )
    )

  atac_sig_gr <- sig_gr_mm10

  # Find H3K27me3 2kb windows overlapping each ATAC peak
  hits <- findOverlaps(atac_sig_gr, win27_gr, ignore.strand = TRUE)
  if (length(hits) == 0L) {
    cat("No overlapping H3K27me3 windows\n")
    return(NULL)
  }

  # Mean H3K27me3 logFC per ATAC peak (average across overlapping windows)
  k27_lfc_per_peak <- tapply(
    lfc27_win[subjectHits(hits)],
    queryHits(hits),
    mean, na.rm = TRUE
  )

  peak_signal <- anno_df[as.integer(names(k27_lfc_per_peak)), ] %>%
    mutate(k27_logFC  = as.numeric(k27_lfc_per_peak),
           cell_type  = ct_name)

  cat(sprintf("ATAC peaks with H3K27me3 signal: %d / %d\n",
              nrow(peak_signal), length(sig_idx)))
  peak_signal

}) %>% set_names(atac_ct)

signal_combined <- bind_rows(Filter(Negate(is.null), signal_list))

if (nrow(signal_combined) > 0) {

  plot_df <- signal_combined %>%
    dplyr::filter(feature %in% c("Promoter", "Distal intergenic")) %>%
    mutate(
      group     = paste(feature, ifelse(direction == "up", "(Gained)", "(Lost)")),
      cell_type = factor(cell_type, levels = atac_ct),
      direction = factor(direction, levels = c("up", "down"),
                         labels = c("Gained", "Lost"))
    )

  group_colors <- c(
    "Promoter (Gained)"          = "#E41A1C",
    "Promoter (Lost)"            = "#377EB8",
    "Distal intergenic (Gained)" = "#FC8D62",
    "Distal intergenic (Lost)"   = "#8DA0CB"
  )

  p_violin <- ggplot(plot_df,
                     aes(x = group, y = k27_logFC, fill = group, color = group)) +
    geom_violin(alpha = 0.4, linewidth = 0.6, trim = TRUE) +
    geom_boxplot(width = 0.15, alpha = 0.8, outlier.size = 0.5,
                 color = "grey30", fill = "white") +
    geom_hline(yintercept = 0, linetype = "dashed",
               color = "grey40", linewidth = 0.5) +
    facet_wrap(~ cell_type, nrow = 1, scales = "free_x") +
    scale_fill_manual(values  = group_colors, guide = "none") +
    scale_color_manual(values = group_colors, guide = "none") +
    labs(
      title    = "H3K27me3 signal change at ATAC differential peaks — cTKO vs WT",
      subtitle = "Mean logFC across overlapping H3K27me3 2kb windows",
      x = NULL, y = "H3K27me3 log2FC (cTKO / WT)"
    ) +
    theme_minimal(base_size = 11) +
    theme(
      plot.title       = element_text(face = "bold"),
      panel.grid.minor = element_blank(),
      strip.text       = element_text(face = "bold"),
      axis.text.x      = element_text(angle = 30, hjust = 1, size = 9)
    )

  ggsave(file.path(dirs$plots, "integration_h3k27me3_signal_at_atac_peaks.pdf"),
         p_violin, width = 14, height = 6)

  write_csv(signal_combined,
            file.path(dirs$data, "integration_h3k27me3_signal_at_atac_peaks.csv"))
  cat("Analysis 2 saved.\n")
}

# ============================================================================
# Analysis 3 — H3K27me3 metaplots at TSS of genes with changed accessibility
#
# Genes are split into two groups based on CD8 promoter ATAC direction:
#   a) Increased accessibility (gained)
#   b) Decreased accessibility (lost)
#
# For each group, H3K27me3 TMM-normalized logCPM is averaged across all
# H3K27me3 2kb windows in a ±meta_half_kb window centred at each gene's TSS.
# WT and cTKO profiles are overlaid to show whether H3K27me3 changes at TSS
# of genes with altered chromatin accessibility.
# ============================================================================

cat("\n\n====== ANALYSIS 3: H3K27me3 METAPLOTS AT TSS ======\n")

meta_half_kb  <- 5L    # kb either side of TSS
meta_bin_kb   <- 0.5   # bin size in kb (matches csaw 500bp spacing)
meta_half_bp  <- meta_half_kb * 1000L
meta_bin_bp   <- as.integer(meta_bin_kb * 1000)
n_bins_side   <- as.integer(meta_half_kb / meta_bin_kb)
n_bins_total  <- 2L * n_bins_side
meta_pos      <- (seq_len(n_bins_total) - n_bins_side - 0.5) * meta_bin_kb

# Chromosome sizes for boundary checking
chr_sizes <- seqlengths(txdb)
chr_sizes <- chr_sizes[!is.na(chr_sizes)]

# Get TSS coordinates for all mm10 genes (strand-aware)
all_genes   <- genes(txdb)
entrez_to_sym <- AnnotationDbi::select(
  org.Mm.eg.db,
  keys    = names(all_genes),
  columns = "SYMBOL",
  keytype = "ENTREZID"
)
all_genes$SYMBOL <- entrez_to_sym$SYMBOL[
  match(names(all_genes), entrez_to_sym$ENTREZID)
]
tss_gr <- promoters(all_genes, upstream = 0L, downstream = 1L)

# Gene groups from Analysis 1 (CD8 promoter ATAC)
if (nrow(promo_k27_combined) == 0L) {
  cat("No promoter data from Analysis 1 — skipping metaplot.\n")
} else {

  gene_groups <- list(
    gained = promo_k27_combined %>%
      dplyr::filter(atac_dir == "up")  %>% pull(SYMBOL) %>% unique(),
    lost   = promo_k27_combined %>%
      dplyr::filter(atac_dir == "down") %>% pull(SYMBOL) %>% unique()
  )

  cat(sprintf("Genes with gained accessibility: %d\n", length(gene_groups$gained)))
  cat(sprintf("Genes with lost  accessibility: %d\n", length(gene_groups$lost)))

  # Build metagene matrix for one group
  build_meta_matrix <- function(gene_symbols) {
    tss_sel <- tss_gr[!is.na(tss_gr$SYMBOL) & tss_gr$SYMBOL %in% gene_symbols]
    tss_sel <- tss_sel[as.character(seqnames(tss_sel)) %in% names(chr_sizes)]

    # Remove TSS too close to chromosome edges
    tss_sel <- tss_sel[
      start(tss_sel) - meta_half_bp >= 1L &
      start(tss_sel) + meta_half_bp <= chr_sizes[as.character(seqnames(tss_sel))]
    ]

    n_ev <- length(tss_sel)
    cat(sprintf("  TSS with sufficient flanking region: %d / %d\n",
                n_ev, length(gene_symbols)))
    if (n_ev == 0L) return(NULL)

    query_gr <- GRanges(
      seqnames = seqnames(tss_sel),
      ranges   = IRanges(
        start(tss_sel) - meta_half_bp,
        start(tss_sel) + meta_half_bp - 1L
      )
    )

    hits <- findOverlaps(query_gr, win27_gr, ignore.strand = TRUE)

    # Strand-aware bin assignment: flip positions for minus-strand genes
    ev_strand <- as.integer(strand(tss_sel) == "-") * -2L + 1L  # +1 or -1

    mat_wt   <- matrix(NA_real_, n_ev, n_bins_total)
    mat_ctko <- matrix(NA_real_, n_ev, n_bins_total)

    for (ev_i in seq_len(n_ev)) {
      tss_pos <- start(tss_sel[ev_i])
      ori     <- ev_strand[ev_i]
      sel     <- subjectHits(hits)[queryHits(hits) == ev_i]
      if (length(sel) == 0L) next

      wc <- (start(win27_gr[sel]) + end(win27_gr[sel])) / 2
      bi <- as.integer(round((wc - tss_pos) * ori / meta_bin_bp + n_bins_side + 0.5))
      ok <- bi >= 1L & bi <= n_bins_total
      if (!any(ok)) next

      agg_wt   <- tapply(rowMeans(lcpm27[sel[ok], wt_idx,   drop = FALSE]),
                         bi[ok], mean, na.rm = TRUE)
      agg_ctko <- tapply(rowMeans(lcpm27[sel[ok], ctko_idx, drop = FALSE]),
                         bi[ok], mean, na.rm = TRUE)

      mat_wt  [ev_i, as.integer(names(agg_wt))]   <- as.numeric(agg_wt)
      mat_ctko[ev_i, as.integer(names(agg_ctko))]  <- as.numeric(agg_ctko)
    }

    list(wt = mat_wt, ctko = mat_ctko, n = n_ev)
  }

  meta_stat <- function(mat) {
    list(
      mean = colMeans(mat, na.rm = TRUE),
      se   = apply(mat, 2, sd, na.rm = TRUE) /
             sqrt(pmax(colSums(!is.na(mat)), 1L))
    )
  }

  cat("\nBuilding metagene matrix — gained accessibility genes:\n")
  mat_gained <- build_meta_matrix(gene_groups$gained)

  cat("Building metagene matrix — lost accessibility genes:\n")
  mat_lost   <- build_meta_matrix(gene_groups$lost)

  # Convert to tidy tibble for ggplot
  meta_to_tbl <- function(mat_obj, group_label) {
    if (is.null(mat_obj)) return(NULL)
    s_wt   <- meta_stat(mat_obj$wt)
    s_ctko <- meta_stat(mat_obj$ctko)
    bind_rows(
      tibble(pos = meta_pos, mean = s_wt$mean,   se = s_wt$se,
             condition = "WT",   group = group_label, n = mat_obj$n),
      tibble(pos = meta_pos, mean = s_ctko$mean, se = s_ctko$se,
             condition = "cTKO", group = group_label, n = mat_obj$n)
    )
  }

  meta_df <- bind_rows(
    meta_to_tbl(mat_gained, sprintf("Gained accessibility\n(n = %d genes)",
                                    if (!is.null(mat_gained)) mat_gained$n else 0)),
    meta_to_tbl(mat_lost,   sprintf("Lost accessibility\n(n = %d genes)",
                                    if (!is.null(mat_lost))   mat_lost$n   else 0))
  )

  if (!is.null(meta_df) && nrow(meta_df) > 0) {

    cond_colors <- c(WT = "grey45", cTKO = "#0077B6")

    p_meta <- ggplot(meta_df,
                     aes(x = pos, y = mean,
                         color = condition, fill = condition,
                         linetype = condition)) +
      geom_ribbon(aes(ymin = mean - se, ymax = mean + se),
                  alpha = 0.18, color = NA) +
      geom_line(linewidth = 0.8) +
      geom_vline(xintercept = 0, linetype = "dashed",
                 color = "grey40", linewidth = 0.5) +
      facet_wrap(~ group, nrow = 1, scales = "free_y") +
      scale_color_manual(values = cond_colors, name = NULL) +
      scale_fill_manual( values = cond_colors, name = NULL) +
      scale_linetype_manual(values = c(WT = "dashed", cTKO = "solid"), name = NULL) +
      scale_x_continuous(
        breaks = seq(-meta_half_kb, meta_half_kb, by = 1),
        labels = function(x) paste0(x, " kb")
      ) +
      labs(
        title    = "H3K27me3 signal at TSS — CD8 cTKO vs WT",
        subtitle = sprintf("Mean ± SE across genes  |  ±%d kb window  |  %g kb bins",
                           meta_half_kb, meta_bin_kb),
        x = "Distance from TSS",
        y = "H3K27me3 (TMM-norm logCPM)"
      ) +
      theme_classic(base_size = 11) +
      theme(
        plot.title      = element_text(face = "bold"),
        strip.text      = element_text(face = "bold", size = 10),
        legend.position = "top"
      )

    ggsave(file.path(dirs$plots, "integration_h3k27me3_metaplot_at_tss.pdf"),
           p_meta, width = 10, height = 5)
    cat("Metaplot saved.\n")
  }
}

cat("\n=== 02_atac_chip_integration.R complete ===\n")
cat("Output: ../../results/integration/\n")
