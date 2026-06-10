#!/usr/bin/env Rscript

if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")

library(Gviz)
library(GenomicAlignments)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)
library(edgeR)

cat("\n=== Track visualization (Gviz) ===\n")

options(ucscChromosomeNames = TRUE)

# ============================================================================
# USER SETTINGS
# ============================================================================

fdr_thresh  <- 0.10
lfc_thresh  <- 1
top_n       <- 3     # number of top windows to plot per assay/direction
binsize     <- 50
smooth_bins <- 10
frag_ext    <- 200
mapq        <- 20

bam_dir  <- "../data"
norm_dir <- dirs$diff

plot_config <- list(
  list(assay = "H3K27me3", direction = "lost"),
  list(assay = "H3K36me2", direction = "gained")
)

assays_to_plot <- c("H3K27me3", "H3K36me2")

# ============================================================================
# Sample groups
# ============================================================================

track_groups <- list(
  "H3K27me3 WT"   = c("WT_H3K27me3_rep1",   "WT_H3K27me3_rep2"),
  "H3K27me3 cTKO" = c("cTKO_H3K27me3_rep1", "cTKO_H3K27me3_rep2"),
  "H3K36me2 WT"   = c("WT_H3K36me2_rep1",   "WT_H3K36me2_rep2"),
  "H3K36me2 cTKO" = c("cTKO_H3K36me2_rep1", "cTKO_H3K36me2_rep2")
)

group_colors <- c(
  "H3K27me3 WT"   = "black",
  "H3K27me3 cTKO" = "red",
  "H3K36me2 WT"   = "gray",
  "H3K36me2 cTKO" = "lightcoral"
)

group_order <- names(group_colors)

# ============================================================================
# Setup
# ============================================================================

bam_suffix <- "_R1_trimmed.fastq.sorted.bam"
sample_ids <- unique(unlist(track_groups, use.names = FALSE))

bam_by_sample <- setNames(
  file.path(bam_dir, paste0(sample_ids, bam_suffix)),
  sample_ids
)

bam_paths <- lapply(track_groups, function(nms) bam_by_sample[nms])

norm_df <- do.call(rbind, lapply(assays_to_plot, function(a) {
  f <- file.path(norm_dir, sprintf("chip_norm_factors_%s.csv", a))
  if (!file.exists(f)) stop("Missing normalization file: ", f)
  read.csv(f, stringsAsFactors = FALSE)
}))

norm_factor <- setNames(norm_df$norm_factor, norm_df$sample)

missing_norm <- setdiff(sample_ids, names(norm_factor))
if (length(missing_norm) > 0) {
  stop("Missing norm_factor for samples:\n", paste(missing_norm, collapse = "\n"))
}

analysis <- readRDS(file.path(dirs$data, "csaw_chip_analysis_results.rds"))

dir.create(dirs$tracks, recursive = TRUE, showWarnings = FALSE)

# ============================================================================
# Helpers
# ============================================================================

smooth_signal <- function(x, k) {
  if (k <= 1L) return(x)
  s <- as.numeric(stats::filter(x, rep(1 / k, k), sides = 2))
  s[is.na(s)] <- x[is.na(s)]
  s
}

tile_region <- function(chr, from, to, binsize) {
  starts <- seq(from, to - 1L, by = binsize)
  GRanges(chr, IRanges(starts, pmin(starts + binsize - 1L, to)))
}

safe_ylim <- function(x) {
  ymax <- max(x, na.rm = TRUE)
  if (!is.finite(ymax) || ymax <= 0) return(c(0, 1))
  c(0, ymax * 1.05)
}

bam_binned_coverage <- function(sample_id, bins, frag_ext, mapq) {
  chr <- as.character(seqnames(bins))[1L]

  param <- ScanBamParam(
    which = GRanges(chr, IRanges(min(start(bins)), max(end(bins)))),
    mapqFilter = mapq,
    flag = scanBamFlag(
      isUnmappedQuery = FALSE,
      isSecondaryAlignment = FALSE,
      isSupplementaryAlignment = FALSE
    )
  )

  reads <- readGAlignments(bam_by_sample[[sample_id]], param = param)
  if (length(reads) == 0L) return(rep(0, length(bins)))

  gr <- granges(reads)
  pos <- strand(gr) != "-"
  gr <- c(
    resize(gr[pos], frag_ext, fix = "start"),
    resize(gr[!pos], frag_ext, fix = "end")
  )

  cov <- coverage(gr)
  if (!chr %in% names(cov)) return(rep(0, length(bins)))

  raw <- binnedAverage(bins, cov[chr], "score")$score
  raw * norm_factor[[sample_id]]
}

group_coverage <- function(sample_ids, bins, frag_ext, mapq) {
  scores <- lapply(sample_ids, bam_binned_coverage,
                   bins = bins, frag_ext = frag_ext, mapq = mapq)
  Reduce("+", scores) / length(scores)
}

get_top_windows <- function(assay_name, direction, n) {
  ct     <- analysis[[assay_name]]
  lfc    <- as.numeric(ct$merged$combined$rep.logFC)
  fdr    <- as.numeric(ct$merged$combined$FDR)
  is_sig <- !is.na(fdr) & fdr <= fdr_thresh & abs(lfc) >= lfc_thresh

  if (direction == "gained") {
    mask <- is_sig & lfc > 0
    ord <- order(lfc[mask], decreasing = TRUE)
  } else {
    mask <- is_sig & lfc < 0
    ord <- order(lfc[mask])
  }

  ct$merged$regions[which(mask)[ord][seq_len(min(n, sum(mask)))]]
}

plot_window <- function(win_gr, rank, assay_name, direction) {
  chr       <- as.character(seqnames(win_gr))
  w         <- width(win_gr)
  center    <- (start(win_gr) + end(win_gr)) %/% 2L
  reg_start <- max(1L, center - w)
  reg_end   <- center + w

  cat(sprintf("  [%02d] %s:%d-%d  (window %d bp, plot %d bp)\n",
              rank, chr, reg_start, reg_end, w, reg_end - reg_start + 1L))

  tryCatch({
    bins <- tile_region(chr, reg_start, reg_end, binsize)

    scores <- lapply(group_order, function(grp) {
      smooth_signal(group_coverage(track_groups[[grp]], bins, frag_ext, mapq),
                    smooth_bins)
    })
    names(scores) <- group_order

    ylim_k27 <- safe_ylim(unlist(scores[grep("H3K27me3", group_order)]))
    ylim_k36 <- safe_ylim(unlist(scores[grep("H3K36me2", group_order)]))

    data_tracks <- lapply(group_order, function(grp) {
      col  <- group_colors[[grp]]
      ylim <- if (grepl("H3K27me3", grp)) ylim_k27 else ylim_k36
      DataTrack(
        data = scores[[grp]],
        start = start(bins),
        end = end(bins),
        chromosome = chr,
        genome = "mm10",
        name = grp,
        col.histogram = col,
        fill.histogram = col,
        type = "histogram",
        ylim = ylim,
        background.title = "white",
        col.title = "black",
        col.axis = "black",
        fontcolor.title = "black",
        cex.title = 0.7
      )
    })

    window_track <- AnnotationTrack(
      GRanges(chr, IRanges(start(win_gr), end(win_gr))),
      genome = "mm10",
      chromosome = chr,
      name = paste0(assay_name, " ", direction),
      fill = "gold",
      col = NA,
      background.title = "white",
      col.title = "black",
      fontcolor.title = "black",
      cex.title = 0.7
    )

    all_tracks <- c(
      list(IdeogramTrack(genome = "mm10", chromosome = chr)),
      list(GenomeAxisTrack(col = "black", fontcolor = "black")),
      list(window_track),
      data_tracks,
      list(GeneRegionTrack(
        TxDb.Mmusculus.UCSC.mm10.knownGene,
        genome = "mm10",
        chromosome = chr,
        start = reg_start,
        end = reg_end,
        name = "Genes",
        showId = TRUE,
        geneSymbols = TRUE,
        collapse = TRUE,
        shape = "arrow",
        fill = "steelblue",
        col = NA,
        background.title = "white",
        col.title = "black",
        fontcolor.title = "black",
        cex.title = 0.7
      ))
    )

    track_heights <- c(0.5, 0.5, 0.3, rep(2.5, length(data_tracks)), 1.5)

    fname <- sprintf("track_%s_%s_%02d_%s_%d-%d.pdf",
                     assay_name, direction, rank, chr, reg_start, reg_end)

    pdf(file.path(dirs$tracks, fname),
        width = 10, height = sum(track_heights) * 0.75)

    plotTracks(all_tracks,
               sizes = track_heights,
               from = reg_start,
               to = reg_end,
               chromosome = chr,
               title.width = 1.8,
               background.panel = "white",
               background.title = "white")

    dev.off()
    cat("    Saved:", fname, "\n")

  }, error = function(e) message("    Warning -- ", conditionMessage(e)))
}

# ============================================================================
# Main: top differential windows
# ============================================================================

for (cfg in plot_config) {
  wins <- get_top_windows(cfg$assay, cfg$direction, top_n)
  cat(sprintf("\n--- Top %d %s %s windows ---\n",
              length(wins), cfg$assay, cfg$direction))

  if (length(wins) == 0) {
    cat("  No significant windows found -- check fdr_thresh / lfc_thresh.\n")
    next
  }

  for (i in seq_along(wins)) {
    plot_window(wins[i], i, cfg$assay, cfg$direction)
  }
}

# ============================================================================
# H3K36me2 expansion tracks
# Requires 05_ChIPseq_domain_expansion.R to have been run first.
# Selects the 2 largest expansions that overlap a WT H3K27me3 domain and
# plots all four tracks (H3K36me2 WT/cTKO + H3K27me3 WT/cTKO) together,
# annotating the WT domain boundary and the gained expansion zone.
# ============================================================================

cat("\n=== H3K36me2 expansion track plots ===\n")

expansion_file <- file.path(dirs$diff, "chip_h3k36me2_domain_pairs.csv")
exp_zones_file <- file.path(dirs$diff, "chip_h3k36me2_expansion_zones.csv")

if (!file.exists(expansion_file) || !file.exists(exp_zones_file)) {
  cat("Expansion results not found -- run 05_ChIPseq_domain_expansion.R first.\n")
} else {

  domain_pairs <- read_csv(expansion_file, show_col_types = FALSE)
  exp_zones_df <- read_csv(exp_zones_file, show_col_types = FALSE)

  # Keep expanded domains that invade WT H3K27me3 territory
  candidates <- domain_pairs %>%
    filter(expanded, total_expand >= 8000) %>%
    arrange(desc(total_expand))

  # Check overlap with WT H3K27me3 expansion zones
  exp_zones_gr <- GRanges(
    seqnames = exp_zones_df$seqnames,
    ranges   = IRanges(exp_zones_df$start, exp_zones_df$end)
  )
  exp_zones_gr <- exp_zones_gr[exp_zones_df$overlaps_wt_h3k27me3]

  cand_gr <- GRanges(
    seqnames = candidates$seqnames,
    ranges   = IRanges(
      pmin(candidates$wt_start, candidates$ctko_start),
      pmax(candidates$wt_end,   candidates$ctko_end)
    )
  )

  overlaps_h3k27 <- countOverlaps(cand_gr, exp_zones_gr) > 0
  candidates     <- candidates[overlaps_h3k27, ]

  n_exp_plots <- min(2L, nrow(candidates))
  if (n_exp_plots == 0L) {
    cat("No expansion regions overlapping H3K27me3 found -- lowering filters may help.\n")
  } else {
    cat(sprintf("Plotting %d expansion region(s)\n", n_exp_plots))
  }

  plot_expansion_region <- function(pair_row, rank) {
    chr       <- pair_row$seqnames
    padding   <- max(20000L, as.integer(pair_row$total_expand * 0.5))
    reg_start <- max(1L, min(pair_row$wt_start, pair_row$ctko_start) - padding)
    reg_end   <- max(pair_row$wt_end,   pair_row$ctko_end) + padding

    cat(sprintf("  [%d] %s:%d-%d  (WT domain %d kb, cTKO domain %d kb, +%d kb)\n",
                rank, chr, reg_start, reg_end,
                round(pair_row$wt_width_kb), round(pair_row$ctko_width_kb),
                round(pair_row$total_expand / 1e3)))

    tryCatch({
      bins <- tile_region(chr, reg_start, reg_end, binsize)

      scores <- lapply(group_order, function(grp) {
        smooth_signal(group_coverage(track_groups[[grp]], bins, frag_ext, mapq),
                      smooth_bins)
      })
      names(scores) <- group_order

      ylim_k27 <- safe_ylim(unlist(scores[grep("H3K27me3", group_order)]))
      ylim_k36 <- safe_ylim(unlist(scores[grep("H3K36me2", group_order)]))

      data_tracks <- lapply(group_order, function(grp) {
        col  <- group_colors[[grp]]
        ylim <- if (grepl("H3K27me3", grp)) ylim_k27 else ylim_k36
        DataTrack(
          data = scores[[grp]], start = start(bins), end = end(bins),
          chromosome = chr, genome = "mm10", name = grp,
          col.histogram = col, fill.histogram = col,
          type = "histogram", ylim = ylim,
          background.title = "white", col.title = "black",
          col.axis = "black", fontcolor.title = "black", cex.title = 0.7
        )
      })

      # WT H3K36me2 domain boundary -- where the mark stopped in WT
      wt_domain_track <- AnnotationTrack(
        GRanges(chr, IRanges(pair_row$wt_start, pair_row$wt_end)),
        genome = "mm10", chromosome = chr,
        name = "WT domain",
        fill = adjustcolor("grey40", 0.4), col = "grey40",
        background.title = "white", col.title = "black",
        fontcolor.title = "black", cex.title = 0.7
      )

      # Expansion zone(s) -- the territory gained in cTKO
      exp_left  <- if (pair_row$left_expand  >= 2000L)
        GRanges(chr, IRanges(pair_row$ctko_start, pair_row$wt_start - 1L)) else NULL
      exp_right <- if (pair_row$right_expand >= 2000L)
        GRanges(chr, IRanges(pair_row$wt_end + 1L, pair_row$ctko_end)) else NULL
      exp_parts <- Filter(Negate(is.null), list(exp_left, exp_right))
      exp_gr    <- do.call(c, exp_parts)

      exp_zone_track <- AnnotationTrack(
        exp_gr,
        genome = "mm10", chromosome = chr,
        name = "Expansion",
        fill = adjustcolor("#AE2012", 0.35), col = "#AE2012",
        background.title = "white", col.title = "#AE2012",
        fontcolor.title = "#AE2012", cex.title = 0.7
      )

      all_tracks <- c(
        list(IdeogramTrack(genome = "mm10", chromosome = chr)),
        list(GenomeAxisTrack(col = "black", fontcolor = "black")),
        list(wt_domain_track),
        list(exp_zone_track),
        data_tracks,
        list(GeneRegionTrack(
          TxDb.Mmusculus.UCSC.mm10.knownGene,
          genome = "mm10", chromosome = chr,
          start = reg_start, end = reg_end,
          name = "Genes", showId = TRUE, geneSymbols = TRUE,
          collapse = TRUE, shape = "arrow",
          fill = "steelblue", col = NA,
          background.title = "white", col.title = "black",
          fontcolor.title = "black", cex.title = 0.7
        ))
      )

      track_heights <- c(0.5, 0.5, 0.25, 0.25, rep(2.5, length(data_tracks)), 1.5)

      fname <- sprintf("track_expansion_%02d_%s_%d-%d.pdf",
                       rank, chr, reg_start, reg_end)

      pdf(file.path(dirs$tracks, fname),
          width = 12, height = sum(track_heights) * 0.75)

      plotTracks(all_tracks,
                 sizes = track_heights,
                 from = reg_start, to = reg_end,
                 chromosome = chr,
                 title.width = 1.8,
                 background.panel = "white",
                 background.title = "white")

      dev.off()
      cat("    Saved:", fname, "\n")

    }, error = function(e) {
      message("    ERROR in plot_expansion_region: ", conditionMessage(e))
      message(paste(capture.output(traceback()), collapse = "\n"))
    })
  }

  for (i in seq_len(n_exp_plots)) {
    plot_expansion_region(candidates[i, ], i)
  }
}

# ============================================================================
# Metagene analysis: H3K36me2 expansion boundaries vs H3K27me3
#
# Each event is anchored at the WT domain boundary (x = 0):
#   x < 0 = inside the existing WT H3K36me2 domain
#   x > 0 = territory newly gained by H3K36me2 in cTKO
#
# Only boundaries where the expansion zone overlaps a WT H3K27me3 domain
# are included.
#
# Plotted as fold enrichment over each sample's own genome-wide mean CPM.
# This puts WT and cTKO on the same relative scale without any between-
# condition normalization assumption. At x > 0: WT H3K36me2 ≈ 1 (background),
# cTKO H3K36me2 > 1 (expansion); WT H3K27me3 > 1 (its domain), cTKO < WT
# (retreat). The horizontal reference is 1 (genome-wide mean).
# ============================================================================

cat("\n=== Metagene: H3K36me2 expansion vs H3K27me3 ===\n")

if (!file.exists(expansion_file)) {
  cat("Expansion results not found -- skipping metagene.\n")
} else {

  prep <- readRDS(file.path(dirs$data, "chip_norm_prep.rds"))

  # Per-condition fold enrichment over the WT genome-wide mean.
  # Both WT and cTKO are divided by the same reference (mean CPM across all WT
  # samples), so the cTKO profile's absolute height directly reflects change
  # relative to the WT background: cTKO > WT line = gain, cTKO < WT line = loss.
  compute_fe <- function(prep_ct) {
    y   <- prep_ct$norm$TMM$ql_large$y
    rpm <- cpm(y, normalized.lib.sizes = FALSE, log = FALSE)
    wt_idx   <- which(prep_ct$metadata$condition == "WT")
    ctko_idx <- which(prep_ct$metadata$condition == "cTKO")
    gm_wt <- mean(colMeans(rpm[, wt_idx, drop = FALSE]))
    fe    <- rpm / gm_wt
    list(
      wt   = rowMeans(fe[, wt_idx,   drop = FALSE]),
      ctko = rowMeans(fe[, ctko_idx, drop = FALSE])
    )
  }

  fe36 <- compute_fe(prep[["H3K36me2"]])
  fe27 <- compute_fe(prep[["H3K27me3"]])

  win36 <- rowRanges(prep[["H3K36me2"]]$filtered_se)
  win27 <- rowRanges(prep[["H3K27me3"]]$filtered_se)

  meta_half_kb <- 50L
  meta_bin_kb  <- 1L
  meta_half_bp <- meta_half_kb * 1000L
  meta_bin_bp  <- meta_bin_kb  * 1000L
  n_bins_side  <- meta_half_kb %/% meta_bin_kb
  n_bins_total <- 2L * n_bins_side
  # bin i has centre at (i - n_bins_side - 0.5) * meta_bin_kb kb from boundary
  meta_pos     <- (seq_len(n_bins_total) - n_bins_side - 0.5) * meta_bin_kb

  chr_sizes <- seqlengths(TxDb.Mmusculus.UCSC.mm10.knownGene)
  chr_sizes <- chr_sizes[!is.na(chr_sizes)]

  # -- Build per-boundary events ---------------------------------------------
  domain_pairs_mg <- read_csv(expansion_file, show_col_types = FALSE)

  dp_exp <- domain_pairs_mg %>%
    filter(expanded, left_expand >= 2000 | right_expand >= 2000)

  # Pre-allocate event vectors (max 2 boundaries per domain pair)
  ev_chr <- character(nrow(dp_exp) * 2L)
  ev_bnd <- integer(nrow(dp_exp) * 2L)
  ev_ori <- integer(nrow(dp_exp) * 2L)
  n_ev   <- 0L

  for (k in seq_len(nrow(dp_exp))) {
    row <- dp_exp[k, ]
    chr <- row$seqnames
    if (!chr %in% names(chr_sizes)) next

    if (row$right_expand >= 2000) {
      n_ev <- n_ev + 1L
      ev_chr[n_ev] <- chr
      ev_bnd[n_ev] <- as.integer(row$wt_end)
      ev_ori[n_ev] <- 1L
    }

    if (row$left_expand >= 2000) {
      n_ev <- n_ev + 1L
      ev_chr[n_ev] <- chr
      ev_bnd[n_ev] <- as.integer(row$wt_start)
      ev_ori[n_ev] <- -1L
    }
  }

  ev_chr <- ev_chr[seq_len(n_ev)]
  ev_bnd <- ev_bnd[seq_len(n_ev)]
  ev_ori <- ev_ori[seq_len(n_ev)]

  cat(sprintf("Metagene: %d expansion boundaries\n", n_ev))

  if (n_ev == 0L) {
    cat("No events found -- skipping metagene plot.\n")
  } else {

    # Single findOverlaps pass for all events
    reg_starts <- pmax(1L, ev_bnd - meta_half_bp)
    reg_ends   <- pmin(chr_sizes[ev_chr], ev_bnd + meta_half_bp)

    query_gr <- GRanges(seqnames = ev_chr,
                         ranges   = IRanges(reg_starts, reg_ends))

    hits36 <- findOverlaps(query_gr, win36, ignore.strand = TRUE)
    hits27 <- findOverlaps(query_gr, win27, ignore.strand = TRUE)

    # Fill metagene matrix with per-bin mean signal value.
    # Closes over n_ev, n_bins_total, n_bins_side, meta_bin_bp, ev_bnd, ev_ori.
    fill_vals <- function(sig_vec, win_gr, qh, sh) {
      mat <- matrix(NA_real_, n_ev, n_bins_total)
      for (ev_i in seq_len(n_ev)) {
        bnd <- ev_bnd[ev_i]
        ori <- ev_ori[ev_i]
        sel <- sh[qh == ev_i]
        if (length(sel) == 0L) next

        wc  <- (start(win_gr[sel]) + end(win_gr[sel])) / 2
        bi  <- as.integer(round((wc - bnd) * ori / meta_bin_bp + n_bins_side + 0.5))
        ok  <- bi >= 1L & bi <= n_bins_total
        if (!any(ok)) next

        bv  <- bi[ok]; sv <- sel[ok]
        agg <- tapply(sig_vec[sv], bv, mean, na.rm = TRUE)
        mat[ev_i, as.integer(names(agg))] <- agg
      }
      mat
    }

    cat("  Aggregating H3K36me2 fold enrichment...\n")
    mat36_wt   <- fill_vals(fe36$wt,   win36, queryHits(hits36), subjectHits(hits36))
    mat36_ctko <- fill_vals(fe36$ctko, win36, queryHits(hits36), subjectHits(hits36))
    cat("  Aggregating H3K27me3 fold enrichment...\n")
    mat27_wt   <- fill_vals(fe27$wt,   win27, queryHits(hits27), subjectHits(hits27))
    mat27_ctko <- fill_vals(fe27$ctko, win27, queryHits(hits27), subjectHits(hits27))

    meta_stat <- function(mat) {
      mn <- colMeans(mat, na.rm = TRUE)
      n  <- colSums(!is.na(mat))
      se <- apply(mat, 2, sd, na.rm = TRUE) / sqrt(pmax(n, 1L))
      list(mean = mn, se = se)
    }

    s36_wt   <- meta_stat(mat36_wt);   s36_ctko <- meta_stat(mat36_ctko)
    s27_wt   <- meta_stat(mat27_wt);   s27_ctko <- meta_stat(mat27_ctko)

    # log2 fold enrichment versions (suppress -Inf from log2(0) — becomes NA)
    log2_mat <- function(m) { r <- log2(m); r[!is.finite(r)] <- NA_real_; r }
    ls36_wt   <- meta_stat(log2_mat(mat36_wt));   ls36_ctko <- meta_stat(log2_mat(mat36_ctko))
    ls27_wt   <- meta_stat(log2_mat(mat27_wt));   ls27_ctko <- meta_stat(log2_mat(mat27_ctko))

    # -- Shared drawing helpers -----------------------------------------------
    col_wt <- "grey45"
    col36  <- "#AE2012"
    col27  <- "#0077B6"

    pad_ylim <- function(..., frac = 0.12) {
      r <- range(unlist(list(...)), na.rm = TRUE)
      if (!all(is.finite(r)) || diff(r) == 0) return(c(0, 2))
      r + diff(r) * c(-frac, frac)
    }

    shade_exp <- function(ylim_v, href) {
      rect(0, ylim_v[1], max(meta_pos), ylim_v[2],
           col = adjustcolor("#AE2012", 0.07), border = NA)
      abline(v = 0,    col = "grey40", lty = 2, lwd = 1.2)
      abline(h = href, col = "black",  lty = 1, lwd = 0.8)
    }

    draw_ribbon <- function(stat, col, lty = 1) {
      mn <- stat$mean; se <- stat$se
      polygon(c(meta_pos, rev(meta_pos)),
              c(mn - se, rev(mn + se)),
              col = adjustcolor(col, 0.18), border = NA)
      lines(meta_pos, mn, col = col, lwd = 2, lty = lty)
    }

    plot_metagene <- function(s36_wt, s36_ctko, s27_wt, s27_ctko,
                               ylab, href, filename) {
      pdf(file.path(dirs$tracks, filename), width = 8, height = 8)
      par(mfrow = c(2, 1), mar = c(2, 5, 3, 2), oma = c(5, 0, 0, 0))

      ylim36 <- pad_ylim(
        s36_wt$mean - s36_wt$se, s36_wt$mean + s36_wt$se,
        s36_ctko$mean - s36_ctko$se, s36_ctko$mean + s36_ctko$se
      )
      plot(NA, xlim = range(meta_pos), ylim = ylim36, xaxt = "n",
           xlab = "", ylab = ylab,
           main = sprintf("H3K36me2 at expansion boundaries  (n = %d events)", n_ev))
      shade_exp(ylim36, href)
      draw_ribbon(s36_wt,   col_wt, lty = 2)
      draw_ribbon(s36_ctko, col36,  lty = 1)
      legend("topleft", legend = c("WT", "cTKO"), col = c(col_wt, col36),
             lwd = 2, lty = c(2, 1), bty = "n", cex = 0.85)

      ylim27 <- pad_ylim(
        s27_wt$mean - s27_wt$se, s27_wt$mean + s27_wt$se,
        s27_ctko$mean - s27_ctko$se, s27_ctko$mean + s27_ctko$se
      )
      plot(NA, xlim = range(meta_pos), ylim = ylim27, xaxt = "n",
           xlab = "", ylab = ylab,
           main = "H3K27me3 at the same boundaries")
      shade_exp(ylim27, href)
      draw_ribbon(s27_wt,   col_wt, lty = 2)
      draw_ribbon(s27_ctko, col27,  lty = 1)
      legend("topleft", legend = c("WT", "cTKO"), col = c(col_wt, col27),
             lwd = 2, lty = c(2, 1), bty = "n", cex = 0.85)

      axis(1, at = seq(-meta_half_kb, meta_half_kb, by = 10))
      mtext(
        paste0("Distance from WT boundary (kb)",
               "     [left = inside WT domain | right = expansion zone]"),
        side = 1, outer = TRUE, line = 3, cex = 0.85
      )
      dev.off()
    }

    plot_metagene(s36_wt, s36_ctko, s27_wt, s27_ctko,
                  ylab     = "Fold enrichment over genome-wide mean",
                  href     = 1,
                  filename = "metagene_expansion_fe.pdf")
    cat("Saved: metagene_expansion_fe.pdf\n")

    plot_metagene(ls36_wt, ls36_ctko, ls27_wt, ls27_ctko,
                  ylab     = "log2(fold enrichment over genome-wide mean)",
                  href     = 0,
                  filename = "metagene_expansion_log2fe.pdf")
    cat("Saved: metagene_expansion_log2fe.pdf\n")

    # Overlaid panels: both marks in the same condition on shared y-axis
    # Panel a = WT, panel b = cTKO; shared ylim makes the two directly comparable
    plot_overlay_exp <- function(s36_wt, s27_wt, s36_ctko, s27_ctko,
                                  ylab, href, filename) {
      shared_ylim <- pad_ylim(
        s36_wt$mean - s36_wt$se,     s36_wt$mean + s36_wt$se,
        s27_wt$mean - s27_wt$se,     s27_wt$mean + s27_wt$se,
        s36_ctko$mean - s36_ctko$se, s36_ctko$mean + s36_ctko$se,
        s27_ctko$mean - s27_ctko$se, s27_ctko$mean + s27_ctko$se
      )
      pdf(file.path(dirs$tracks, filename), width = 8, height = 8)
      par(mfrow = c(2, 1), mar = c(2, 5, 3, 2), oma = c(5, 0, 0, 0))

      plot(NA, xlim = range(meta_pos), ylim = shared_ylim, xaxt = "n",
           xlab = "", ylab = ylab,
           main = sprintf("WT — H3K36me2 and H3K27me3  (n = %d events)", n_ev))
      shade_exp(shared_ylim, href)
      draw_ribbon(s36_wt, col36)
      draw_ribbon(s27_wt, col27)
      legend("topleft", legend = c("H3K36me2", "H3K27me3"),
             col = c(col36, col27), lwd = 2, bty = "n", cex = 0.85)

      plot(NA, xlim = range(meta_pos), ylim = shared_ylim, xaxt = "n",
           xlab = "", ylab = ylab,
           main = "cTKO — H3K36me2 and H3K27me3")
      shade_exp(shared_ylim, href)
      draw_ribbon(s36_ctko, col36)
      draw_ribbon(s27_ctko, col27)
      legend("topleft", legend = c("H3K36me2", "H3K27me3"),
             col = c(col36, col27), lwd = 2, bty = "n", cex = 0.85)

      axis(1, at = seq(-meta_half_kb, meta_half_kb, by = 10))
      mtext(
        paste0("Distance from WT boundary (kb)",
               "     [left = inside WT domain | right = expansion zone]"),
        side = 1, outer = TRUE, line = 3, cex = 0.85
      )
      dev.off()
    }

    plot_overlay_exp(s36_wt, s27_wt, s36_ctko, s27_ctko,
                     ylab     = "Fold enrichment over genome-wide mean",
                     href     = 1,
                     filename = "metagene_expansion_fe_overlay.pdf")
    cat("Saved: metagene_expansion_fe_overlay.pdf\n")

    plot_overlay_exp(ls36_wt, ls27_wt, ls36_ctko, ls27_ctko,
                     ylab     = "log2(fold enrichment over genome-wide mean)",
                     href     = 0,
                     filename = "metagene_expansion_log2fe_overlay.pdf")
    cat("Saved: metagene_expansion_log2fe_overlay.pdf\n")
  }
}

# ============================================================================
# Metagene analysis: H3K27me3 contraction boundaries vs H3K36me2
#
# Reciprocal of the expansion metagene above.
# Each event is anchored at the cTKO H3K27me3 domain boundary (x = 0):
#   x < 0 = inside cTKO H3K27me3 domain (mark retained)
#   x > 0 = contraction zone (mark lost in cTKO vs WT)
#
# Only boundaries where the contraction zone overlaps a WT H3K36me2 domain
# are included (asking whether H3K36me2 was already present where H3K27me3
# retreated).
#
# Signal: per-condition fold enrichment over each sample's genome-wide mean.
#   H3K27me3: WT > cTKO at x > 0 (retreat)
#   H3K36me2: cTKO > WT at x > 0 (invasion)
# ============================================================================

cat("\n=== Metagene: H3K27me3 contraction vs H3K36me2 ===\n")

contraction_file <- file.path(dirs$diff, "chip_h3k27me3_domain_pairs.csv")
con_zones_file   <- file.path(dirs$diff, "chip_h3k27me3_contraction_zones.csv")

if (!file.exists(contraction_file)) {
  cat("Contraction results not found -- run 05b_ChIPseq_domain_contraction.R first.\n")
} else {

  if (!exists("prep")) prep <- readRDS(file.path(dirs$data, "chip_norm_prep.rds"))

  compute_fe_c <- function(prep_ct) {
    y   <- prep_ct$norm$TMM$ql_large$y
    rpm <- cpm(y, normalized.lib.sizes = FALSE, log = FALSE)
    wt_idx   <- which(prep_ct$metadata$condition == "WT")
    ctko_idx <- which(prep_ct$metadata$condition == "cTKO")
    gm_wt <- mean(colMeans(rpm[, wt_idx, drop = FALSE]))
    fe    <- rpm / gm_wt
    list(
      wt   = rowMeans(fe[, wt_idx,   drop = FALSE]),
      ctko = rowMeans(fe[, ctko_idx, drop = FALSE])
    )
  }

  fe27c <- compute_fe_c(prep[["H3K27me3"]])
  fe36c <- compute_fe_c(prep[["H3K36me2"]])

  win27c <- rowRanges(prep[["H3K27me3"]]$filtered_se)
  win36c <- rowRanges(prep[["H3K36me2"]]$filtered_se)

  meta_half_kb_c <- 50L
  meta_bin_kb_c  <- 1L
  meta_half_bp_c <- meta_half_kb_c * 1000L
  meta_bin_bp_c  <- meta_bin_kb_c  * 1000L
  n_bins_side_c  <- meta_half_kb_c %/% meta_bin_kb_c
  n_bins_total_c <- 2L * n_bins_side_c
  meta_pos_c     <- (seq_len(n_bins_total_c) - n_bins_side_c - 0.5) * meta_bin_kb_c

  if (!exists("chr_sizes")) {
    chr_sizes <- seqlengths(TxDb.Mmusculus.UCSC.mm10.knownGene)
    chr_sizes <- chr_sizes[!is.na(chr_sizes)]
  }

  domain_pairs_con <- read_csv(contraction_file, show_col_types = FALSE)

  dp_con <- domain_pairs_con %>%
    filter(contracted, left_contract >= 2000 | right_contract >= 2000)

  ev_chr_c <- character(nrow(dp_con) * 2L)
  ev_bnd_c <- integer(nrow(dp_con) * 2L)
  ev_ori_c <- integer(nrow(dp_con) * 2L)
  n_ev_c   <- 0L

  for (k in seq_len(nrow(dp_con))) {
    row <- dp_con[k, ]
    chr <- row$seqnames
    if (!chr %in% names(chr_sizes)) next

    # Right contraction: zone is ctko_end+1 → wt_end
    # Anchor at ctko_end (current cTKO boundary); ori=+1 → x>0 = contraction zone
    if (row$right_contract >= 2000) {
      n_ev_c <- n_ev_c + 1L
      ev_chr_c[n_ev_c] <- chr
      ev_bnd_c[n_ev_c] <- as.integer(row$ctko_end)
      ev_ori_c[n_ev_c] <- 1L
    }

    # Left contraction: zone is wt_start → ctko_start-1
    # Anchor at ctko_start; ori=-1 → x>0 = left of ctko_start = contraction zone
    if (row$left_contract >= 2000) {
      n_ev_c <- n_ev_c + 1L
      ev_chr_c[n_ev_c] <- chr
      ev_bnd_c[n_ev_c] <- as.integer(row$ctko_start)
      ev_ori_c[n_ev_c] <- -1L
    }
  }

  ev_chr_c <- ev_chr_c[seq_len(n_ev_c)]
  ev_bnd_c <- ev_bnd_c[seq_len(n_ev_c)]
  ev_ori_c <- ev_ori_c[seq_len(n_ev_c)]

  cat(sprintf("Metagene: %d contraction boundaries\n", n_ev_c))

  if (n_ev_c == 0L) {
    cat("No events found -- skipping contraction metagene plot.\n")
  } else {

    reg_starts_c <- pmax(1L, ev_bnd_c - meta_half_bp_c)
    reg_ends_c   <- pmin(chr_sizes[ev_chr_c], ev_bnd_c + meta_half_bp_c)

    query_gr_c <- GRanges(seqnames = ev_chr_c,
                           ranges   = IRanges(reg_starts_c, reg_ends_c))

    hits27c <- findOverlaps(query_gr_c, win27c, ignore.strand = TRUE)
    hits36c <- findOverlaps(query_gr_c, win36c, ignore.strand = TRUE)

    fill_vals_c <- function(sig_vec, win_gr, qh, sh) {
      mat <- matrix(NA_real_, n_ev_c, n_bins_total_c)
      for (ev_i in seq_len(n_ev_c)) {
        bnd <- ev_bnd_c[ev_i]
        ori <- ev_ori_c[ev_i]
        sel <- sh[qh == ev_i]
        if (length(sel) == 0L) next

        wc  <- (start(win_gr[sel]) + end(win_gr[sel])) / 2
        bi  <- as.integer(round((wc - bnd) * ori / meta_bin_bp_c + n_bins_side_c + 0.5))
        ok  <- bi >= 1L & bi <= n_bins_total_c
        if (!any(ok)) next

        bv  <- bi[ok]; sv <- sel[ok]
        agg <- tapply(sig_vec[sv], bv, mean, na.rm = TRUE)
        mat[ev_i, as.integer(names(agg))] <- agg
      }
      mat
    }

    cat("  Aggregating H3K27me3 fold enrichment...\n")
    mat27c_wt   <- fill_vals_c(fe27c$wt,   win27c, queryHits(hits27c), subjectHits(hits27c))
    mat27c_ctko <- fill_vals_c(fe27c$ctko, win27c, queryHits(hits27c), subjectHits(hits27c))
    cat("  Aggregating H3K36me2 fold enrichment...\n")
    mat36c_wt   <- fill_vals_c(fe36c$wt,   win36c, queryHits(hits36c), subjectHits(hits36c))
    mat36c_ctko <- fill_vals_c(fe36c$ctko, win36c, queryHits(hits36c), subjectHits(hits36c))

    meta_stat_c <- function(mat) {
      mn <- colMeans(mat, na.rm = TRUE)
      n  <- colSums(!is.na(mat))
      se <- apply(mat, 2, sd, na.rm = TRUE) / sqrt(pmax(n, 1L))
      list(mean = mn, se = se)
    }

    s27c_wt   <- meta_stat_c(mat27c_wt);   s27c_ctko <- meta_stat_c(mat27c_ctko)
    s36c_wt   <- meta_stat_c(mat36c_wt);   s36c_ctko <- meta_stat_c(mat36c_ctko)

    log2_mat_c <- function(m) { r <- log2(m); r[!is.finite(r)] <- NA_real_; r }
    ls27c_wt   <- meta_stat_c(log2_mat_c(mat27c_wt));   ls27c_ctko <- meta_stat_c(log2_mat_c(mat27c_ctko))
    ls36c_wt   <- meta_stat_c(log2_mat_c(mat36c_wt));   ls36c_ctko <- meta_stat_c(log2_mat_c(mat36c_ctko))

    col_wt_c <- "grey45"
    col27_c  <- "#0077B6"
    col36_c  <- "#AE2012"

    pad_ylim_c <- function(..., frac = 0.12) {
      r <- range(unlist(list(...)), na.rm = TRUE)
      if (!all(is.finite(r)) || diff(r) == 0) return(c(0, 2))
      r + diff(r) * c(-frac, frac)
    }

    shade_con <- function(ylim_v, href) {
      rect(0, ylim_v[1], max(meta_pos_c), ylim_v[2],
           col = adjustcolor("#0077B6", 0.07), border = NA)
      abline(v = 0,    col = "grey40", lty = 2, lwd = 1.2)
      abline(h = href, col = "black",  lty = 1, lwd = 0.8)
    }

    draw_ribbon_c <- function(stat, col, lty = 1) {
      mn <- stat$mean; se <- stat$se
      polygon(c(meta_pos_c, rev(meta_pos_c)),
              c(mn - se, rev(mn + se)),
              col = adjustcolor(col, 0.18), border = NA)
      lines(meta_pos_c, mn, col = col, lwd = 2, lty = lty)
    }

    plot_metagene_con <- function(s27_wt, s27_ctko, s36_wt, s36_ctko,
                                   ylab, href, filename) {
      pdf(file.path(dirs$tracks, filename), width = 8, height = 8)
      par(mfrow = c(2, 1), mar = c(2, 5, 3, 2), oma = c(5, 0, 0, 0))

      ylim27 <- pad_ylim_c(
        s27_wt$mean - s27_wt$se, s27_wt$mean + s27_wt$se,
        s27_ctko$mean - s27_ctko$se, s27_ctko$mean + s27_ctko$se
      )
      plot(NA, xlim = range(meta_pos_c), ylim = ylim27, xaxt = "n",
           xlab = "", ylab = ylab,
           main = sprintf("H3K27me3 at contraction boundaries  (n = %d events)", n_ev_c))
      shade_con(ylim27, href)
      draw_ribbon_c(s27_wt,   col_wt_c, lty = 2)
      draw_ribbon_c(s27_ctko, col27_c,  lty = 1)
      legend("topleft", legend = c("WT", "cTKO"), col = c(col_wt_c, col27_c),
             lwd = 2, lty = c(2, 1), bty = "n", cex = 0.85)

      ylim36 <- pad_ylim_c(
        s36_wt$mean - s36_wt$se, s36_wt$mean + s36_wt$se,
        s36_ctko$mean - s36_ctko$se, s36_ctko$mean + s36_ctko$se
      )
      plot(NA, xlim = range(meta_pos_c), ylim = ylim36, xaxt = "n",
           xlab = "", ylab = ylab,
           main = "H3K36me2 at the same boundaries")
      shade_con(ylim36, href)
      draw_ribbon_c(s36_wt,   col_wt_c, lty = 2)
      draw_ribbon_c(s36_ctko, col36_c,  lty = 1)
      legend("topleft", legend = c("WT", "cTKO"), col = c(col_wt_c, col36_c),
             lwd = 2, lty = c(2, 1), bty = "n", cex = 0.85)

      axis(1, at = seq(-meta_half_kb_c, meta_half_kb_c, by = 10))
      mtext(
        paste0("Distance from cTKO boundary (kb)",
               "     [left = inside cTKO domain | right = contraction zone]"),
        side = 1, outer = TRUE, line = 3, cex = 0.85
      )
      dev.off()
    }

    plot_metagene_con(s27c_wt, s27c_ctko, s36c_wt, s36c_ctko,
                      ylab     = "Fold enrichment over genome-wide mean",
                      href     = 1,
                      filename = "metagene_contraction_fe.pdf")
    cat("Saved: metagene_contraction_fe.pdf\n")

    plot_metagene_con(ls27c_wt, ls27c_ctko, ls36c_wt, ls36c_ctko,
                      ylab     = "log2(fold enrichment over genome-wide mean)",
                      href     = 0,
                      filename = "metagene_contraction_log2fe.pdf")
    cat("Saved: metagene_contraction_log2fe.pdf\n")

    # Overlaid panels: both marks in the same condition on shared y-axis
    plot_overlay_con <- function(s27_wt, s36_wt, s27_ctko, s36_ctko,
                                  ylab, href, filename) {
      shared_ylim <- pad_ylim_c(
        s27_wt$mean - s27_wt$se,     s27_wt$mean + s27_wt$se,
        s36_wt$mean - s36_wt$se,     s36_wt$mean + s36_wt$se,
        s27_ctko$mean - s27_ctko$se, s27_ctko$mean + s27_ctko$se,
        s36_ctko$mean - s36_ctko$se, s36_ctko$mean + s36_ctko$se
      )
      pdf(file.path(dirs$tracks, filename), width = 8, height = 8)
      par(mfrow = c(2, 1), mar = c(2, 5, 3, 2), oma = c(5, 0, 0, 0))

      plot(NA, xlim = range(meta_pos_c), ylim = shared_ylim, xaxt = "n",
           xlab = "", ylab = ylab,
           main = sprintf("WT — H3K27me3 and H3K36me2  (n = %d events)", n_ev_c))
      shade_con(shared_ylim, href)
      draw_ribbon_c(s27_wt, col27_c)
      draw_ribbon_c(s36_wt, col36_c)
      legend("topleft", legend = c("H3K27me3", "H3K36me2"),
             col = c(col27_c, col36_c), lwd = 2, bty = "n", cex = 0.85)

      plot(NA, xlim = range(meta_pos_c), ylim = shared_ylim, xaxt = "n",
           xlab = "", ylab = ylab,
           main = "cTKO — H3K27me3 and H3K36me2")
      shade_con(shared_ylim, href)
      draw_ribbon_c(s27_ctko, col27_c)
      draw_ribbon_c(s36_ctko, col36_c)
      legend("topleft", legend = c("H3K27me3", "H3K36me2"),
             col = c(col27_c, col36_c), lwd = 2, bty = "n", cex = 0.85)

      axis(1, at = seq(-meta_half_kb_c, meta_half_kb_c, by = 10))
      mtext(
        paste0("Distance from cTKO boundary (kb)",
               "     [left = inside cTKO domain | right = contraction zone]"),
        side = 1, outer = TRUE, line = 3, cex = 0.85
      )
      dev.off()
    }

    plot_overlay_con(s27c_wt, s36c_wt, s27c_ctko, s36c_ctko,
                     ylab     = "Fold enrichment over genome-wide mean",
                     href     = 1,
                     filename = "metagene_contraction_fe_overlay.pdf")
    cat("Saved: metagene_contraction_fe_overlay.pdf\n")

    plot_overlay_con(ls27c_wt, ls36c_wt, ls27c_ctko, ls36c_ctko,
                     ylab     = "log2(fold enrichment over genome-wide mean)",
                     href     = 0,
                     filename = "metagene_contraction_log2fe_overlay.pdf")
    cat("Saved: metagene_contraction_log2fe_overlay.pdf\n")
  }
}

cat("\n=== 06_ChIPseq_visualization.R complete ===\n")
cat("Output: ../../results/ChIPseq/tracks/\n")
