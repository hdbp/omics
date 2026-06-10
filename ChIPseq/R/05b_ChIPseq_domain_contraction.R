if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(GenomicRanges)

# ============================================================================
# H3K27me3 domain contraction analysis + H3K36me2 reciprocal gain
#
# Reciprocal of 05_ChIPseq_domain_expansion.R.
# Strategy:
#   1. Call H3K27me3 domains per condition (WT, cTKO)
#   2. Match overlapping domain pairs between conditions
#   3. Identify domains that contracted in cTKO (WT boundary > cTKO boundary)
#   4. Extract the contraction zones (territory lost in cTKO)
#   5. Ask: do those contraction zones overlap WT H3K36me2 domains?
#   6. Ask: did H3K36me2 gain in cTKO within those contraction zones?
# ============================================================================

# ---- tuneable parameters ---------------------------------------------------
gap_width               <- 4000
min_domain_bp           <- 10000
breadth_thresh_quantile <- 0.50
min_contract_bp         <- 4000
min_olap_frac           <- 0.50
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
# 1. H3K27me3 domains per condition
# ============================================================================

cat("\n=== H3K27me3 domain calling ===\n")
ct27 <- prep[["H3K27me3"]]
wt27   <- make_domains(ct27, "WT",   breadth_thresh_quantile, gap_width, min_domain_bp)
ctko27 <- make_domains(ct27, "cTKO", breadth_thresh_quantile, gap_width, min_domain_bp)

wt_domains   <- wt27$domains
ctko_domains <- ctko27$domains

# ============================================================================
# 2. Match overlapping domain pairs (reciprocal overlap >= min_olap_frac)
# ============================================================================

cat("\n=== Matching domain pairs ===\n")

olap <- findOverlaps(wt_domains, ctko_domains)
wt_q  <- queryHits(olap)
ct_q  <- subjectHits(olap)

isect_w    <- width(pintersect(wt_domains[wt_q], ctko_domains[ct_q]))
recip_frac <- pmin(
  isect_w / width(wt_domains[wt_q]),
  isect_w / width(ctko_domains[ct_q])
)

keep      <- recip_frac >= min_olap_frac
wt_q      <- wt_q[keep]
ct_q      <- ct_q[keep]
recip_frac <- recip_frac[keep]

best <- tapply(seq_along(wt_q), wt_q, function(i) i[which.max(recip_frac[i])])
sel  <- unlist(best, use.names = FALSE)
wt_q <- wt_q[sel]; ct_q <- ct_q[sel]; recip_frac <- recip_frac[sel]

cat(sprintf("Matched domain pairs: %d\n", length(wt_q)))

# ============================================================================
# 3. Compute contraction per matched pair
#    left_contract  = cTKO starts further right than WT (lost left flank)
#    right_contract = WT extends further right than cTKO (lost right flank)
# ============================================================================

wt_matched   <- wt_domains[wt_q]
ctko_matched <- ctko_domains[ct_q]

left_contract  <- pmax(0L, start(ctko_matched) - start(wt_matched))
right_contract <- pmax(0L, end(wt_matched)     - end(ctko_matched))
total_contract <- left_contract + right_contract
width_ratio    <- width(ctko_matched) / width(wt_matched)

contracted <- total_contract >= min_contract_bp

cat(sprintf("Contracted domains (>= %d bp territory lost): %d / %d\n",
            min_contract_bp, sum(contracted), length(wt_q)))
cat(sprintf("  Expanded / unchanged: %d\n", sum(!contracted)))

# ============================================================================
# 4. Build contraction zone GRanges
#    Left zone:  wt_start → ctko_start - 1  (lost left flank)
#    Right zone: ctko_end + 1 → wt_end      (lost right flank)
# ============================================================================

zone_list <- vector("list", sum(contracted))
j <- 1L
for (i in which(contracted)) {
  seqn  <- as.character(seqnames(wt_matched[i]))
  zones <- GRanges()

  if (left_contract[i] >= 2000L)
    zones <- c(zones, GRanges(seqnames = seqn,
                               ranges = IRanges(start(wt_matched[i]),
                                                start(ctko_matched[i]) - 1L)))
  if (right_contract[i] >= 2000L)
    zones <- c(zones, GRanges(seqnames = seqn,
                               ranges = IRanges(end(ctko_matched[i]) + 1L,
                                                end(wt_matched[i]))))
  zone_list[[j]] <- zones
  j <- j + 1L
}

all_con_zones <- reduce(do.call(c, zone_list))
cat(sprintf("Total contraction zone bp: %s\n",
            format(sum(width(all_con_zones)), big.mark = ",")))

# ============================================================================
# 5. H3K36me2 domains in WT
# ============================================================================

cat("\n=== H3K36me2 domain calling (WT) ===\n")
ct36  <- prep[["H3K36me2"]]
wt36  <- make_domains(ct36, "WT", breadth_thresh_quantile, gap_width, min_domain_bp)
wt36_domains <- wt36$domains

# ============================================================================
# 6. Do contraction zones overlap WT H3K36me2 domains?
# ============================================================================

cat("\n=== Contraction zones vs WT H3K36me2 ===\n")

olap_36 <- findOverlaps(all_con_zones, wt36_domains)
n_con_with_36  <- length(unique(queryHits(olap_36)))
frac_con_with_36 <- n_con_with_36 / length(all_con_zones)

cat(sprintf("Contraction zones overlapping WT H3K36me2 domain: %d / %d (%.1f%%)\n",
            n_con_with_36, length(all_con_zones), frac_con_with_36 * 100))

con_covered <- intersect(all_con_zones, wt36_domains)
pct_covered <- sum(width(con_covered)) / sum(width(all_con_zones)) * 100
cat(sprintf("Contraction zone bp covered by WT H3K36me2: %.1f%%\n", pct_covered))

# ============================================================================
# 7. H3K36me2 signal change in contraction zones (WT -> cTKO)
#    Expect positive logFC: H3K36me2 gaining where H3K27me3 retreated
# ============================================================================

cat("\n=== H3K36me2 gain in contraction zones ===\n")

y36    <- ct36$norm$TMM$ql_large$y
lcpm36 <- cpm(y36, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 1)
wt36_idx   <- which(ct36$metadata$condition == "WT")
ctko36_idx <- which(ct36$metadata$condition == "cTKO")
lcpm36_wt   <- rowMeans(lcpm36[, wt36_idx,   drop = FALSE])
lcpm36_ctko <- rowMeans(lcpm36[, ctko36_idx, drop = FALSE])

win36 <- wt36$win_ranges

in_con        <- unique(queryHits(findOverlaps(win36, all_con_zones)))
in_con_and_36 <- unique(in_con[queryHits(findOverlaps(win36[in_con], wt36_domains))])
not_con       <- setdiff(seq_along(win36), in_con)

cat(sprintf("H3K36me2 windows in contraction zones: %d\n", length(in_con)))
cat(sprintf("  of which also in WT H3K36me2 domain: %d\n", length(in_con_and_36)))

lfc_in_con  <- lcpm36_ctko[in_con_and_36] - lcpm36_wt[in_con_and_36]
lfc_not_con <- lcpm36_ctko[not_con]       - lcpm36_wt[not_con]

cat(sprintf("Mean H3K36me2 logFC in contraction zones: %.3f\n", mean(lfc_in_con,  na.rm = TRUE)))
cat(sprintf("Mean H3K36me2 logFC genome-wide:          %.3f\n", mean(lfc_not_con, na.rm = TRUE)))

wt_test <- wilcox.test(lfc_in_con, lfc_not_con, alternative = "greater")
cat(sprintf("Wilcoxon test (contraction zones > background): p = %.2e\n", wt_test$p.value))

# ============================================================================
# 8. Plots
# ============================================================================

pdf(file.path(dirs$diff, "chip_domain_contraction.pdf"), width = 14, height = 6)
par(mfrow = c(1, 3), mar = c(5, 5, 4, 2))

# --- Panel 1: WT vs cTKO H3K27me3 domain width (matched pairs) ---
col_p1 <- ifelse(contracted, "#0077B6", adjustcolor("grey50", 0.4))
plot(
  width(wt_matched) / 1e3, width(ctko_matched) / 1e3,
  col  = col_p1, pch = 16, cex = 0.5,
  xlab = "WT domain width (kb)",
  ylab = "cTKO domain width (kb)",
  main = "H3K27me3 — matched domain widths\ncTKO vs WT",
  log  = "xy"
)
abline(0, 1, lty = 2, col = "black")
legend("topleft",
       legend = c(sprintf("Contracted (>= %d bp)", min_contract_bp), "Unchanged"),
       col    = c("#0077B6", "grey50"), pch = 16, bty = "n", cex = 0.8)

# --- Panel 2: distribution of contraction sizes ---
hist(
  total_contract[contracted] / 1e3,
  breaks = 40, col = "#0077B6", border = "white",
  xlab   = "Contraction size (kb)\n[territory lost in cTKO vs WT]",
  main   = "H3K27me3 contraction size distribution",
  freq   = FALSE
)

# --- Panel 3: H3K36me2 logFC in contraction zones vs background ---
d_con <- density(lfc_in_con[is.finite(lfc_in_con)],   adjust = 1.2)
d_bg  <- density(lfc_not_con[is.finite(lfc_not_con)], adjust = 1.2)
ylim  <- c(0, max(d_con$y, d_bg$y) * 1.1)
xlim  <- range(c(d_con$x, d_bg$x))

plot(d_bg,  col = "grey60", lwd = 2, xlim = xlim, ylim = ylim,
     main = "H3K36me2 change (cTKO vs WT)\nin H3K27me3 contraction zones",
     xlab = "H3K36me2 log2FC (cTKO / WT)")
lines(d_con, col = "#AE2012", lwd = 2)
abline(v = 0, lty = 2, col = "black")
legend("topleft",
       legend = c(
         sprintf("Contraction zones (n=%d)", length(lfc_in_con)),
         sprintf("Genome-wide (n=%d)",       length(lfc_not_con))
       ),
       col = c("#AE2012", "grey60"), lwd = 2, bty = "n", cex = 0.8)
mtext(sprintf("Wilcoxon p = %.2e", wt_test$p.value),
      side = 3, line = 0.2, cex = 0.8)

dev.off()

# ============================================================================
# 9. Save tables
# ============================================================================

domain_tbl <- data.frame(
  seqnames       = as.character(seqnames(wt_matched)),
  wt_start       = start(wt_matched),
  wt_end         = end(wt_matched),
  ctko_start     = start(ctko_matched),
  ctko_end       = end(ctko_matched),
  wt_width_kb    = width(wt_matched)   / 1e3,
  ctko_width_kb  = width(ctko_matched) / 1e3,
  width_ratio    = round(width_ratio, 3),
  left_contract  = left_contract,
  right_contract = right_contract,
  total_contract = total_contract,
  contracted     = contracted,
  recip_overlap  = round(recip_frac, 3)
)

write_csv(domain_tbl,
          file.path(dirs$diff, "chip_h3k27me3_domain_pairs.csv"))

con_zone_tbl <- as.data.frame(all_con_zones)
con_zone_tbl$overlaps_wt_h3k36me2 <-
  countOverlaps(all_con_zones, wt36_domains) > 0

write_csv(con_zone_tbl,
          file.path(dirs$diff, "chip_h3k27me3_contraction_zones.csv"))

cat("\n=== 05b_ChIPseq_domain_contraction.R complete ===\n")
cat("Outputs:\n")
cat("  ../../results/ChIPseq/differential/chip_domain_contraction.pdf\n")
cat("  ../../results/ChIPseq/differential/chip_h3k27me3_domain_pairs.csv\n")
cat("  ../../results/ChIPseq/differential/chip_h3k27me3_contraction_zones.csv\n")
