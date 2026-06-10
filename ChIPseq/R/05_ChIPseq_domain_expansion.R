if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(GenomicRanges)

# ============================================================================
# H3K36me2 domain expansion analysis + H3K27me3 reciprocal retreat
#
# Strategy:
#   1. Call H3K36me2 domains per condition (WT, cTKO) from csaw windows
#   2. Match overlapping domain pairs between conditions
#   3. Identify domains that expanded in cTKO (cTKO boundary > WT boundary)
#   4. Extract the expansion zones (the new territory gained in cTKO)
#   5. Ask: do those expansion zones overlap WT H3K27me3 domains?
#   6. Ask: did H3K27me3 retreat in cTKO within those expansion zones?
# ============================================================================

# ---- tuneable parameters ---------------------------------------------------
gap_width     <- 4000   # merge enriched windows within this distance into one domain
min_domain_bp <- 10000  # discard domains smaller than this
breadth_thresh_quantile <- 0.50  # windows above this quantile of WT signal = "enriched"
min_expand_bp <- 4000   # minimum extra bp on either flank to call a domain "expanded"
min_olap_frac <- 0.50   # min reciprocal overlap fraction to consider two domains matched
# ---------------------------------------------------------------------------

prep     <- readRDS(file.path(dirs$data, "chip_norm_prep.rds"))
analysis <- readRDS(file.path(dirs$data, "csaw_chip_analysis_results.rds"))

# ============================================================================
# Helper: derive per-condition domains from csaw windows
# ============================================================================

make_domains <- function(ct, condition_name, thresh_quantile, gap, min_bp) {
  y    <- ct$norm$TMM$ql_large$y
  lcpm <- cpm(y, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 1)
  idx  <- which(ct$metadata$condition == condition_name)
  mean_lcpm <- rowMeans(lcpm[, idx, drop = FALSE])

  thresh <- quantile(mean_lcpm, thresh_quantile)
  cat(sprintf("  [%s] enrichment threshold (q%.0f): %.2f logCPM\n",
              condition_name, thresh_quantile * 100, thresh))

  win_ranges <- rowRanges(ct$filtered_se)
  enriched   <- win_ranges[mean_lcpm > thresh]
  domains    <- reduce(enriched, min.gapwidth = gap)
  domains    <- domains[width(domains) >= min_bp]
  domains$condition <- condition_name
  cat(sprintf("  [%s] %d domains >= %d bp\n",
              condition_name, length(domains), min_bp))
  list(domains = domains, mean_lcpm = mean_lcpm, win_ranges = win_ranges)
}

# ============================================================================
# 1. H3K36me2 domains per condition
# ============================================================================

cat("\n=== H3K36me2 domain calling ===\n")
ct36 <- prep[["H3K36me2"]]
wt36   <- make_domains(ct36, "WT",   breadth_thresh_quantile, gap_width, min_domain_bp)
ctko36 <- make_domains(ct36, "cTKO", breadth_thresh_quantile, gap_width, min_domain_bp)

wt_domains   <- wt36$domains
ctko_domains <- ctko36$domains

# ============================================================================
# 2. Match overlapping domain pairs (reciprocal overlap >= min_olap_frac)
# ============================================================================

cat("\n=== Matching domain pairs ===\n")

olap <- findOverlaps(wt_domains, ctko_domains)
wt_q  <- queryHits(olap)
ct_q  <- subjectHits(olap)

# Reciprocal overlap fraction
isect_w  <- width(pintersect(wt_domains[wt_q], ctko_domains[ct_q]))
recip_frac <- pmin(
  isect_w / width(wt_domains[wt_q]),
  isect_w / width(ctko_domains[ct_q])
)

keep      <- recip_frac >= min_olap_frac
wt_q      <- wt_q[keep]
ct_q      <- ct_q[keep]
recip_frac <- recip_frac[keep]

# One-to-one: keep the best match per WT domain
best <- tapply(seq_along(wt_q), wt_q, function(i) i[which.max(recip_frac[i])])
sel  <- unlist(best, use.names = FALSE)
wt_q <- wt_q[sel]; ct_q <- ct_q[sel]; recip_frac <- recip_frac[sel]

cat(sprintf("Matched domain pairs: %d\n", length(wt_q)))

# ============================================================================
# 3. Compute expansion per matched pair
# ============================================================================

wt_matched   <- wt_domains[wt_q]
ctko_matched <- ctko_domains[ct_q]

left_expand  <- pmax(0L, start(wt_matched) - start(ctko_matched))
right_expand <- pmax(0L, end(ctko_matched) - end(wt_matched))
total_expand <- left_expand + right_expand
width_ratio  <- width(ctko_matched) / width(wt_matched)

expanded <- total_expand >= min_expand_bp

cat(sprintf("Expanded domains (>= %d bp new territory): %d / %d\n",
            min_expand_bp, sum(expanded), length(wt_q)))
cat(sprintf("  Contracted / unchanged: %d\n", sum(!expanded)))

# ============================================================================
# 4. Build expansion zone GRanges
#    For each expanded pair: extract the flanks that exceed the WT boundary
# ============================================================================

zone_list <- vector("list", sum(expanded))
j <- 1L
for (i in which(expanded)) {
  seqn  <- as.character(seqnames(wt_matched[i]))
  zones <- GRanges()

  if (left_expand[i] >= 2000L)
    zones <- c(zones, GRanges(seqnames = seqn,
                               ranges = IRanges(start(ctko_matched[i]),
                                                start(wt_matched[i]) - 1L)))
  if (right_expand[i] >= 2000L)
    zones <- c(zones, GRanges(seqnames = seqn,
                               ranges = IRanges(end(wt_matched[i]) + 1L,
                                                end(ctko_matched[i]))))
  zone_list[[j]] <- zones
  j <- j + 1L
}

all_exp_zones <- reduce(do.call(c, zone_list))
cat(sprintf("Total expansion zone bp: %s\n",
            format(sum(width(all_exp_zones)), big.mark = ",")))

# ============================================================================
# 5. H3K27me3 domains in WT
# ============================================================================

cat("\n=== H3K27me3 domain calling (WT) ===\n")
ct27  <- prep[["H3K27me3"]]
wt27  <- make_domains(ct27, "WT", breadth_thresh_quantile, gap_width, min_domain_bp)
wt27_domains <- wt27$domains

# ============================================================================
# 6. Do expansion zones overlap WT H3K27me3 domains?
# ============================================================================

cat("\n=== Expansion zones vs WT H3K27me3 ===\n")

olap_27 <- findOverlaps(all_exp_zones, wt27_domains)
n_exp_with_27 <- length(unique(queryHits(olap_27)))
frac_exp_with_27 <- n_exp_with_27 / length(all_exp_zones)

cat(sprintf("Expansion zones overlapping WT H3K27me3 domain: %d / %d (%.1f%%)\n",
            n_exp_with_27, length(all_exp_zones), frac_exp_with_27 * 100))

# Expansion zone bases covered by WT H3K27me3
exp_covered  <- intersect(all_exp_zones, wt27_domains)
pct_covered  <- sum(width(exp_covered)) / sum(width(all_exp_zones)) * 100
cat(sprintf("Expansion zone bp covered by WT H3K27me3: %.1f%%\n", pct_covered))

# ============================================================================
# 7. H3K27me3 signal change in expansion zones (WT → cTKO)
# ============================================================================

cat("\n=== H3K27me3 retreat in expansion zones ===\n")

# Get H3K27me3 logCPM per window
y27   <- ct27$norm$TMM$ql_large$y
lcpm27 <- cpm(y27, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 1)
wt27_idx   <- which(ct27$metadata$condition == "WT")
ctko27_idx <- which(ct27$metadata$condition == "cTKO")
lcpm27_wt   <- rowMeans(lcpm27[, wt27_idx,   drop = FALSE])
lcpm27_ctko <- rowMeans(lcpm27[, ctko27_idx, drop = FALSE])

win27 <- wt27$win_ranges   # 2kb windows for H3K27me3

# Windows that fall in expansion zones
in_exp <- queryHits(findOverlaps(win27, all_exp_zones))
in_exp <- unique(in_exp)

# Windows that fall in expansion zones AND overlap WT H3K27me3 domain
in_exp_and_27 <- queryHits(findOverlaps(win27[in_exp], wt27_domains))
in_exp_and_27 <- unique(in_exp[in_exp_and_27])

# Background: H3K27me3 windows NOT in expansion zones
not_exp <- setdiff(seq_along(win27), in_exp)

cat(sprintf("H3K27me3 windows in expansion zones: %d\n", length(in_exp)))
cat(sprintf("  of which also in WT H3K27me3 domain: %d\n", length(in_exp_and_27)))

lfc_in_exp    <- lcpm27_ctko[in_exp_and_27] - lcpm27_wt[in_exp_and_27]
lfc_not_exp   <- lcpm27_ctko[not_exp]       - lcpm27_wt[not_exp]

cat(sprintf("Mean H3K27me3 logFC in expansion zones: %.3f\n", mean(lfc_in_exp,  na.rm = TRUE)))
cat(sprintf("Mean H3K27me3 logFC genome-wide:        %.3f\n", mean(lfc_not_exp, na.rm = TRUE)))

wt_test <- wilcox.test(lfc_in_exp, lfc_not_exp, alternative = "less")
cat(sprintf("Wilcoxon test (expansion zones < background): p = %.2e\n", wt_test$p.value))

# ============================================================================
# 8. Plots
# ============================================================================

pdf(file.path(dirs$diff, "chip_domain_expansion.pdf"), width = 14, height = 6)
par(mfrow = c(1, 3), mar = c(5, 5, 4, 2))

# --- Panel 1: WT vs cTKO H3K36me2 domain width (matched pairs) ---
col_p1 <- ifelse(expanded, "#AE2012", adjustcolor("grey50", 0.4))
plot(
  width(wt_matched) / 1e3, width(ctko_matched) / 1e3,
  col  = col_p1, pch = 16, cex = 0.5,
  xlab = "WT domain width (kb)",
  ylab = "cTKO domain width (kb)",
  main = "H3K36me2 — matched domain widths\ncTKO vs WT",
  log  = "xy"
)
abline(0, 1, lty = 2, col = "black")
legend("topleft",
       legend = c(sprintf("Expanded (>= %d bp)", min_expand_bp), "Unchanged"),
       col    = c("#AE2012", "grey50"), pch = 16, bty = "n", cex = 0.8)

# --- Panel 2: distribution of expansion sizes ---
hist(
  total_expand[expanded] / 1e3,
  breaks = 40, col = "#AE2012", border = "white",
  xlab   = "Expansion size (kb)\n[extra territory in cTKO vs WT]",
  main   = "H3K36me2 expansion size distribution",
  freq   = FALSE
)

# --- Panel 3: H3K27me3 logFC in expansion zones vs background ---
# Density curves
d_exp <- density(lfc_in_exp[is.finite(lfc_in_exp)], adjust = 1.2)
d_bg  <- density(lfc_not_exp[is.finite(lfc_not_exp)], adjust = 1.2)
ylim  <- c(0, max(d_exp$y, d_bg$y) * 1.1)
xlim  <- range(c(d_exp$x, d_bg$x))

plot(d_bg,  col = "grey60",  lwd = 2, xlim = xlim, ylim = ylim,
     main = "H3K27me3 change (cTKO vs WT)\nin H3K36me2 expansion zones",
     xlab = "H3K27me3 log2FC (cTKO / WT)")
lines(d_exp, col = "#0077B6", lwd = 2)
abline(v = 0, lty = 2, col = "black")
legend("topleft",
       legend = c(
         sprintf("Expansion zones (n=%d)", length(lfc_in_exp)),
         sprintf("Genome-wide (n=%d)",     length(lfc_not_exp))
       ),
       col = c("#0077B6", "grey60"), lwd = 2, bty = "n", cex = 0.8)
mtext(sprintf("Wilcoxon p = %.2e", wt_test$p.value),
      side = 3, line = 0.2, cex = 0.8)

dev.off()

# ============================================================================
# 9. Save tables
# ============================================================================

domain_tbl <- data.frame(
  seqnames     = as.character(seqnames(wt_matched)),
  wt_start     = start(wt_matched),
  wt_end       = end(wt_matched),
  ctko_start   = start(ctko_matched),
  ctko_end     = end(ctko_matched),
  wt_width_kb  = width(wt_matched)   / 1e3,
  ctko_width_kb= width(ctko_matched) / 1e3,
  width_ratio  = round(width_ratio, 3),
  left_expand  = left_expand,
  right_expand = right_expand,
  total_expand = total_expand,
  expanded     = expanded,
  recip_overlap= round(recip_frac, 3)
)

write_csv(domain_tbl,
          file.path(dirs$diff, "chip_h3k36me2_domain_pairs.csv"))

exp_zone_tbl <- as.data.frame(all_exp_zones)
exp_zone_tbl$overlaps_wt_h3k27me3 <-
  countOverlaps(all_exp_zones, wt27_domains) > 0

write_csv(exp_zone_tbl,
          file.path(dirs$diff, "chip_h3k36me2_expansion_zones.csv"))

cat("\n=== 05_ChIPseq_domain_expansion.R complete ===\n")
cat("Outputs:\n")
cat("  ../../results/ChIPseq/differential/chip_domain_expansion.pdf\n")
cat("  ../../results/ChIPseq/differential/chip_h3k36me2_domain_pairs.csv\n")
cat("  ../../results/ChIPseq/differential/chip_h3k36me2_expansion_zones.csv\n")
