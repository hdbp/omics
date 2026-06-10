if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)

# ============================================================================
# H3K27me3 domain-boundary metagene — replication of Figure 3C
#
# Anchors: both boundaries (start + end) of each WT H3K27me3 domain
# Strand orientation:
#   Left boundary  (domain start): ori = +1  — interior to the right (x > 0)
#   Right boundary (domain end):   ori = -1  — flipped, interior still x > 0
# Result: x < 0 = H3K36me2 flanking territory
#         x > 0 = H3K27me3 domain interior
#
# Signal: CPM / WT genome-wide mean (library-size normalisation only;
#         no input subtraction — consistent with Willcockson et al. Fig 3C)
#
# Three overlaid panels (H3K27me3 blue | H3K36me2 red):
#   Panel 1 — WT
#   Panel 2 — cTKO
#   Panel 3 — log2FC (cTKO / WT)
# ============================================================================

prep <- readRDS(file.path(dirs$data, "chip_norm_prep.rds"))

# ---- tuneable parameters ---------------------------------------------------
gap_width               <- 4000L
min_domain_bp           <- 10000L
breadth_thresh_quantile <- 0.50
meta_half_kb            <- 10L
meta_bin_kb             <- 1L
# ---------------------------------------------------------------------------

meta_half_bp <- meta_half_kb * 1000L
meta_bin_bp  <- meta_bin_kb  * 1000L
n_bins_side  <- meta_half_kb %/% meta_bin_kb
n_bins_total <- 2L * n_bins_side
meta_pos     <- (seq_len(n_bins_total) - n_bins_side - 0.5) * meta_bin_kb

chr_sizes <- seqlengths(TxDb.Mmusculus.UCSC.mm10.knownGene)
chr_sizes <- chr_sizes[!is.na(chr_sizes)]

# ============================================================================
# 1. WT H3K27me3 domain calling
# ============================================================================

cat("\n=== Calling WT H3K27me3 domains ===\n")

ct27           <- prep[["H3K27me3"]]
y27_obj        <- ct27$norm$TMM$ql_large$y
lcpm27         <- cpm(y27_obj, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 1)
wt27_idx       <- which(ct27$metadata$condition == "WT")
mean_lcpm27_wt <- rowMeans(lcpm27[, wt27_idx, drop = FALSE])
thresh27       <- quantile(mean_lcpm27_wt, breadth_thresh_quantile)

cat(sprintf("Enrichment threshold (q%.0f): %.2f logCPM\n",
            breadth_thresh_quantile * 100, thresh27))

win27     <- rowRanges(ct27$filtered_se)
domains27 <- reduce(win27[mean_lcpm27_wt > thresh27], min.gapwidth = gap_width)
domains27 <- domains27[width(domains27) >= min_domain_bp]
cat(sprintf("WT H3K27me3 domains: %d (>= %d bp)\n", length(domains27), min_domain_bp))

# ============================================================================
# 2. Events — both boundaries of every domain, strand-oriented
# ============================================================================

d_chr  <- as.character(seqnames(domains27))
d_strt <- start(domains27)
d_end  <- end(domains27)

valid_strt <- d_chr %in% names(chr_sizes) &
              (d_strt - meta_half_bp) >= 1L &
              (d_strt + meta_half_bp) <= chr_sizes[d_chr]

valid_end  <- d_chr %in% names(chr_sizes) &
              (d_end - meta_half_bp) >= 1L &
              (d_end + meta_half_bp) <= chr_sizes[d_chr]

ev_chr <- c(d_chr[valid_strt],  d_chr[valid_end])
ev_bnd <- c(d_strt[valid_strt], d_end[valid_end])
ev_ori <- c(rep( 1L, sum(valid_strt)),   # left boundary: interior -> right
            rep(-1L, sum(valid_end)))     # right boundary: flipped -> interior right
n_ev   <- length(ev_bnd)
cat(sprintf("Events after edge trimming: %d  (%d starts + %d ends)\n",
            n_ev, sum(valid_strt), sum(valid_end)))

# ============================================================================
# 3. Per-window signal: three normalizations
#   (a) fold over WT mean      — cTKO / WT_mean (original)
#   (b) fold over self mean    — WT / WT_mean, cTKO / cTKO_mean
#   (c) TMM-normalized CPM     — library-size corrected absolute signal
# ============================================================================

ct36  <- prep[["H3K36me2"]]
win36 <- rowRanges(ct36$filtered_se)

compute_signals <- function(prep_ct) {
  y        <- prep_ct$norm$TMM$ql_large$y
  rpm      <- cpm(y, normalized.lib.sizes = FALSE, log = FALSE)
  norm_cpm <- cpm(y, normalized.lib.sizes = TRUE,  log = FALSE)
  wt_idx   <- which(prep_ct$metadata$condition == "WT")
  ctko_idx <- which(prep_ct$metadata$condition == "cTKO")
  gm_wt    <- mean(colMeans(rpm[, wt_idx,   drop = FALSE]))
  gm_ctko  <- mean(colMeans(rpm[, ctko_idx, drop = FALSE]))
  list(
    fe_wt   = list(wt   = rowMeans(rpm[, wt_idx,   drop = FALSE]) / gm_wt,
                   ctko = rowMeans(rpm[, ctko_idx, drop = FALSE]) / gm_wt),
    fe_self = list(wt   = rowMeans(rpm[, wt_idx,   drop = FALSE]) / gm_wt,
                   ctko = rowMeans(rpm[, ctko_idx, drop = FALSE]) / gm_ctko),
    norm    = list(wt   = rowMeans(norm_cpm[, wt_idx,   drop = FALSE]),
                   ctko = rowMeans(norm_cpm[, ctko_idx, drop = FALSE]))
  )
}

sig27 <- compute_signals(ct27)
sig36 <- compute_signals(ct36)

# ============================================================================
# 4. Single findOverlaps pass per mark -> fill metagene matrices
# ============================================================================

query_gr <- GRanges(
  seqnames = ev_chr,
  ranges   = IRanges(ev_bnd - meta_half_bp, ev_bnd + meta_half_bp - 1L)
)

hits27 <- findOverlaps(query_gr, win27, ignore.strand = TRUE)
hits36 <- findOverlaps(query_gr, win36, ignore.strand = TRUE)

fill_vals <- function(sig_vec, win_gr, qh, sh) {
  mat <- matrix(NA_real_, n_ev, n_bins_total)
  if (length(sh) == 0L) return(mat)

  wc <- (start(win_gr[sh]) + end(win_gr[sh])) / 2
  bi <- as.integer(round((wc - ev_bnd[qh]) * ev_ori[qh] / meta_bin_bp + n_bins_side + 0.5))

  ok <- bi >= 1L & bi <= n_bins_total
  if (!any(ok)) return(mat)

  qh_ok  <- qh[ok]; bi_ok <- bi[ok]; sig_ok <- sig_vec[sh[ok]]
  flat   <- (qh_ok - 1L) * n_bins_total + bi_ok
  agg    <- tapply(sig_ok, flat, mean, na.rm = TRUE)

  flat_idx <- as.integer(names(agg))
  mat[cbind((flat_idx - 1L) %/% n_bins_total + 1L,
            (flat_idx - 1L) %%  n_bins_total + 1L)] <- as.numeric(agg)
  mat
}

qh27 <- queryHits(hits27); sh27 <- subjectHits(hits27)
qh36 <- queryHits(hits36); sh36 <- subjectHits(hits36)

cat("Aggregating H3K27me3...\n")
mat27_wt        <- fill_vals(sig27$fe_wt$wt,   win27, qh27, sh27)
mat27_ctko      <- fill_vals(sig27$fe_wt$ctko, win27, qh27, sh27)
mat27_ctko_self <- fill_vals(sig27$fe_self$ctko, win27, qh27, sh27)
mat27_wt_ncpm   <- fill_vals(sig27$norm$wt,    win27, qh27, sh27)
mat27_ctko_ncpm <- fill_vals(sig27$norm$ctko,  win27, qh27, sh27)

cat("Aggregating H3K36me2...\n")
mat36_wt        <- fill_vals(sig36$fe_wt$wt,   win36, qh36, sh36)
mat36_ctko      <- fill_vals(sig36$fe_wt$ctko, win36, qh36, sh36)
mat36_ctko_self <- fill_vals(sig36$fe_self$ctko, win36, qh36, sh36)
mat36_wt_ncpm   <- fill_vals(sig36$norm$wt,    win36, qh36, sh36)
mat36_ctko_ncpm <- fill_vals(sig36$norm$ctko,  win36, qh36, sh36)

# ============================================================================
# 5. Summary statistics: mean +/- SE across events
# ============================================================================

meta_stat <- function(mat) {
  mn <- colMeans(mat, na.rm = TRUE)
  n  <- colSums(!is.na(mat))
  se <- apply(mat, 2, sd, na.rm = TRUE) / sqrt(pmax(n, 1L))
  list(mean = mn, se = se)
}

s27_wt        <- meta_stat(mat27_wt)
s27_ctko      <- meta_stat(mat27_ctko)
s27_ctko_self <- meta_stat(mat27_ctko_self)
s27_wt_ncpm   <- meta_stat(mat27_wt_ncpm)
s27_ctko_ncpm <- meta_stat(mat27_ctko_ncpm)

s36_wt        <- meta_stat(mat36_wt)
s36_ctko      <- meta_stat(mat36_ctko)
s36_ctko_self <- meta_stat(mat36_ctko_self)
s36_wt_ncpm   <- meta_stat(mat36_wt_ncpm)
s36_ctko_ncpm <- meta_stat(mat36_ctko_ncpm)

safe_log2 <- function(m) { r <- log2(m); r[!is.finite(r)] <- NA_real_; r }
lfc27      <- meta_stat(safe_log2(mat27_ctko)      - safe_log2(mat27_wt))
lfc36      <- meta_stat(safe_log2(mat36_ctko)      - safe_log2(mat36_wt))
lfc27_self <- meta_stat(mat27_ctko_self / mat27_wt)
lfc36_self <- meta_stat(mat36_ctko_self / mat36_wt)
lfc27_ncpm <- meta_stat(safe_log2(mat27_ctko_ncpm) - safe_log2(mat27_wt_ncpm))
lfc36_ncpm <- meta_stat(safe_log2(mat36_ctko_ncpm) - safe_log2(mat36_wt_ncpm))

# ============================================================================
# 6. Plot — ggplot2 + patchwork, dual y-axes, legend top-left
# ============================================================================

library(patchwork)

col27  <- "#AE2012"
col36  <- "#0077B6"
xticks <- seq(-meta_half_kb, meta_half_kb, by = 2)
xlab_str <- "Distance from WT H3K27me3 domain boundary (kb)\n[left = H3K36me2 | right = H3K27me3]"

pad_ylim <- function(..., frac = 0.12) {
  r <- range(unlist(list(...)), na.rm = TRUE)
  if (!all(is.finite(r)) || diff(r) == 0) return(c(0, 2))
  r + diff(r) * c(-frac, frac)
}

# Convert a meta_stat list to a tidy tibble row-set
stat_to_tbl <- function(stat, mark, condition) {
  tibble(
    pos       = meta_pos,
    mean      = stat$mean,
    se        = stat$se,
    ymin      = stat$mean - stat$se,
    ymax      = stat$mean + stat$se,
    mark      = mark,
    condition = condition,
    group     = paste(mark, condition)
  )
}

# Colour / linetype lookup keyed by group label
col_map   <- c("H3K27me3 WT" = col27, "H3K27me3 cTKO" = col27,
               "H3K36me2 WT" = col36, "H3K36me2 cTKO" = col36)
ltype_map <- c("H3K27me3 WT" = "solid",  "H3K27me3 cTKO" = "dashed",
               "H3K36me2 WT" = "solid",  "H3K36me2 cTKO" = "dashed")

# Build one dual-axis panel.
# K36 is linearly scaled into K27 axis space; sec_axis inverts the transform.
meta_panel <- function(df,
                        ylim27 = NULL, ylim36 = NULL,
                        title  = "",
                        href   = 1,
                        ylab27 = "H3K27me3",
                        ylab36 = "H3K36me2") {

  df_k27 <- filter(df, mark == "H3K27me3")
  df_k36 <- filter(df, mark == "H3K36me2")

  if (is.null(ylim27)) ylim27 <- pad_ylim(df_k27$ymin, df_k27$ymax)
  if (is.null(ylim36)) ylim36 <- pad_ylim(df_k36$ymin, df_k36$ymax)

  k   <- diff(ylim27) / diff(ylim36)
  b   <- ylim27[1] - k * ylim36[1]
  fwd <- function(x) k * x + b   # K36 original  → K27 plot space
  inv <- function(x) (x - b) / k # K27 plot space → K36 original

  df_k36_sc <- df_k36 %>%
    mutate(mean = fwd(mean), ymin = fwd(ymin), ymax = fwd(ymax))
  df_plot <- bind_rows(df_k27, df_k36_sc)

  grps  <- unique(df_plot$group)
  c_map <- col_map[grps];   names(c_map) <- grps
  l_map <- ltype_map[grps]; names(l_map) <- grps

  ggplot(df_plot, aes(x = pos, colour = group, fill = group, linetype = group)) +
    annotate("rect",
             xmin = 0, xmax = max(meta_pos),
             ymin = ylim27[1], ymax = ylim27[2],
             fill = col27, alpha = 0.06) +
    geom_vline(xintercept = 0,         colour = "grey40", linetype = "dashed",  linewidth = 0.4) +
    geom_hline(yintercept = href,      colour = col27,    linetype = "dotted",  linewidth = 0.4) +
    geom_hline(yintercept = fwd(href), colour = col36,    linetype = "dotted",  linewidth = 0.4) +
    geom_ribbon(aes(ymin = ymin, ymax = ymax), alpha = 0.18, colour = NA) +
    geom_line(aes(y = mean), linewidth = 0.7) +
    scale_colour_manual(values = c_map, name = NULL) +
    scale_fill_manual(  values = c_map, name = NULL) +
    scale_linetype_manual(values = l_map, name = NULL) +
    scale_y_continuous(
      name     = ylab27,
      limits   = ylim27,
      sec.axis = sec_axis(inv, name = ylab36)
    ) +
    scale_x_continuous(name = xlab_str, breaks = xticks) +
    labs(title = title) +
    theme_classic(base_size = 10) +
    theme(
      axis.title.y.left       = element_text(colour = col27, size = 8),
      axis.text.y.left        = element_text(colour = col27),
      axis.ticks.y.left       = element_line(colour = col27),
      axis.title.y.right      = element_text(colour = col36, size = 8),
      axis.text.y.right       = element_text(colour = col36),
      axis.ticks.y.right      = element_line(colour = col36),
      legend.position         = "inside",
      legend.position.inside  = c(0.02, 0.98),
      legend.justification    = c("left", "top"),
      legend.background       = element_blank(),
      legend.key              = element_blank(),
      legend.text             = element_text(size = 7),
      plot.title              = element_text(size = 10, face = "bold")
    )
}

# Combine panels and save
save_meta <- function(panels, file, page_title, width = 8, height = 11) {
  p <- wrap_plots(panels, ncol = 1) +
    plot_annotation(title = page_title,
                    theme = theme(plot.title = element_text(size = 11, face = "bold")))
  ggsave(file, p, width = width, height = height, device = "pdf")
  cat(sprintf("Saved: %s\n", basename(file)))
}

# ── Plot 1: fold over WT mean ────────────────────────────────────────────────

ylim27_sig <- pad_ylim(s27_wt$mean - s27_wt$se, s27_wt$mean + s27_wt$se)
ylim36_sig <- pad_ylim(s36_wt$mean - s36_wt$se, s36_wt$mean + s36_wt$se)
ylim27_lfc <- pad_ylim(lfc27$mean - lfc27$se, lfc27$mean + lfc27$se)
ylim36_lfc <- pad_ylim(lfc36$mean - lfc36$se, lfc36$mean + lfc36$se)

save_meta(
  list(
    meta_panel(
      bind_rows(stat_to_tbl(s27_wt,   "H3K27me3", "WT"),
                stat_to_tbl(s36_wt,   "H3K36me2", "WT")),
      ylim27 = ylim27_sig, ylim36 = ylim36_sig, href = 1,
      title  = sprintf("WT  (n = %d boundaries)", n_ev),
      ylab27 = "H3K27me3 (fold over WT mean)",
      ylab36 = "H3K36me2 (fold over WT mean)"
    ),
    meta_panel(
      bind_rows(stat_to_tbl(s27_ctko, "H3K27me3", "cTKO"),
                stat_to_tbl(s36_ctko, "H3K36me2", "cTKO")),
      href   = 1, title = "cTKO",          # free y-axes
      ylab27 = "H3K27me3 (fold over WT mean)",
      ylab36 = "H3K36me2 (fold over WT mean)"
    ),
    meta_panel(
      bind_rows(stat_to_tbl(lfc27, "H3K27me3", "cTKO"),
                stat_to_tbl(lfc36, "H3K36me2", "cTKO")),
      ylim27 = ylim27_lfc, ylim36 = ylim36_lfc, href = 0,
      title  = "log2FC (cTKO / WT)",
      ylab27 = "H3K27me3 log2FC",
      ylab36 = "H3K36me2 log2FC"
    )
  ),
  file        = file.path(dirs$tracks, "metagene_h3k27me3_domains.pdf"),
  page_title  = sprintf("WT H3K27me3 domain boundaries — strand oriented  (n = %d)", n_ev)
)

# ── Plot 2: self-normalized + overlay ────────────────────────────────────────

ylim27_self <- pad_ylim(s27_wt$mean - s27_wt$se, s27_wt$mean + s27_wt$se,
                        s27_ctko_self$mean - s27_ctko_self$se,
                        s27_ctko_self$mean + s27_ctko_self$se)
ylim36_self <- pad_ylim(s36_wt$mean - s36_wt$se, s36_wt$mean + s36_wt$se,
                        s36_ctko_self$mean - s36_ctko_self$se,
                        s36_ctko_self$mean + s36_ctko_self$se)

save_meta(
  list(
    meta_panel(
      bind_rows(stat_to_tbl(s27_wt,        "H3K27me3", "WT"),
                stat_to_tbl(s36_wt,        "H3K36me2", "WT")),
      ylim27 = ylim27_self, ylim36 = ylim36_self, href = 1,
      title  = sprintf("WT  (n = %d boundaries)", n_ev),
      ylab27 = "H3K27me3 (fold over WT mean)",
      ylab36 = "H3K36me2 (fold over WT mean)"
    ),
    meta_panel(
      bind_rows(stat_to_tbl(s27_ctko_self, "H3K27me3", "cTKO"),
                stat_to_tbl(s36_ctko_self, "H3K36me2", "cTKO")),
      ylim27 = ylim27_self, ylim36 = ylim36_self, href = 1,
      title  = "cTKO",
      ylab27 = "H3K27me3 (fold over cTKO mean)",
      ylab36 = "H3K36me2 (fold over cTKO mean)"
    ),
    meta_panel(
      bind_rows(stat_to_tbl(s27_wt,        "H3K27me3", "WT"),
                stat_to_tbl(s27_ctko_self, "H3K27me3", "cTKO"),
                stat_to_tbl(s36_wt,        "H3K36me2", "WT"),
                stat_to_tbl(s36_ctko_self, "H3K36me2", "cTKO")),
      ylim27 = ylim27_self, ylim36 = ylim36_self, href = 1,
      title  = "WT vs cTKO overlay  (solid = WT, dashed = cTKO)",
      ylab27 = "H3K27me3 (fold over mean)",
      ylab36 = "H3K36me2 (fold over mean)"
    )
  ),
  file        = file.path(dirs$tracks, "metagene_h3k27me3_domains_selfnorm.pdf"),
  page_title  = sprintf("Self-normalized signal at WT H3K27me3 boundaries  (n = %d)", n_ev)
)

# ── Plot 3: TMM-normalized CPM ───────────────────────────────────────────────

ylim27_ncpm <- pad_ylim(s27_wt_ncpm$mean - s27_wt_ncpm$se, s27_wt_ncpm$mean + s27_wt_ncpm$se,
                        s27_ctko_ncpm$mean - s27_ctko_ncpm$se, s27_ctko_ncpm$mean + s27_ctko_ncpm$se)
ylim36_ncpm <- pad_ylim(s36_wt_ncpm$mean - s36_wt_ncpm$se, s36_wt_ncpm$mean + s36_wt_ncpm$se,
                        s36_ctko_ncpm$mean - s36_ctko_ncpm$se, s36_ctko_ncpm$mean + s36_ctko_ncpm$se)
ylim27_nlfc <- pad_ylim(lfc27_ncpm$mean - lfc27_ncpm$se, lfc27_ncpm$mean + lfc27_ncpm$se)
ylim36_nlfc <- pad_ylim(lfc36_ncpm$mean - lfc36_ncpm$se, lfc36_ncpm$mean + lfc36_ncpm$se)

save_meta(
  list(
    meta_panel(
      bind_rows(stat_to_tbl(s27_wt_ncpm,   "H3K27me3", "WT"),
                stat_to_tbl(s36_wt_ncpm,   "H3K36me2", "WT")),
      ylim27 = ylim27_ncpm, ylim36 = ylim36_ncpm, href = 1,
      title  = sprintf("WT  (n = %d boundaries)", n_ev),
      ylab27 = "H3K27me3 (TMM-norm CPM)",
      ylab36 = "H3K36me2 (TMM-norm CPM)"
    ),
    meta_panel(
      bind_rows(stat_to_tbl(s27_ctko_ncpm, "H3K27me3", "cTKO"),
                stat_to_tbl(s36_ctko_ncpm, "H3K36me2", "cTKO")),
      ylim27 = ylim27_ncpm, ylim36 = ylim36_ncpm, href = 1,
      title  = "cTKO",
      ylab27 = "H3K27me3 (TMM-norm CPM)",
      ylab36 = "H3K36me2 (TMM-norm CPM)"
    ),
    meta_panel(
      bind_rows(stat_to_tbl(lfc27_ncpm, "H3K27me3", "cTKO"),
                stat_to_tbl(lfc36_ncpm, "H3K36me2", "cTKO")),
      ylim27 = ylim27_nlfc, ylim36 = ylim36_nlfc, href = 0,
      title  = "log2FC (cTKO / WT)",
      ylab27 = "H3K27me3 log2FC",
      ylab36 = "H3K36me2 log2FC"
    )
  ),
  file        = file.path(dirs$tracks, "metagene_h3k27me3_domains_normsig.pdf"),
  page_title  = sprintf("TMM-normalized signal at WT H3K27me3 boundaries  (n = %d)", n_ev)
)

cat("\n=== 07_ChIPseq_metagene_h3k27me3.R complete ===\n")
cat("Output: ../../results/ChIPseq/tracks/metagene_h3k27me3_domains*.pdf\n")
