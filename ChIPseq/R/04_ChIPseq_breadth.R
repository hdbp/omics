if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(csaw)
library(edgeR)
library(TxDb.Mmusculus.UCSC.mm10.knownGene)
library(org.Mm.eg.db)

# ============================================================================
# H3K36me2 domain breadth analysis
#
# Standard differential analysis (csaw, DiffBind, etc.) measures signal
# *intensity* within fixed windows and misses changes in domain *breadth*
# (how far the mark spreads across a gene body or genomic region).
#
# This script quantifies, per gene body:
#   breadth score = fraction of 2kb windows with logCPM above a threshold
#
# Then classifies genes by what changed:
#   intensity only | breadth only | both | neither
# ============================================================================

assay_name <- "H3K36me2"

prep     <- readRDS(file.path(dirs$data, "chip_norm_prep.rds"))
analysis <- readRDS(file.path(dirs$data, "csaw_chip_analysis_results.rds"))

ct  <- prep[[assay_name]]
res <- analysis[[assay_name]]

se      <- ct$filtered_se
meta_ip <- ct$metadata

# TMM-normalized logCPM: rows = 2kb windows, cols = samples
y      <- ct$norm$TMM$ql_large$y          # DGEList, already has TMM factors
lcpm   <- cpm(y, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 1)

wt_idx   <- which(meta_ip$condition == "WT")
ctko_idx <- which(meta_ip$condition == "cTKO")

lcpm_wt   <- rowMeans(lcpm[, wt_idx,   drop = FALSE])
lcpm_ctko <- rowMeans(lcpm[, ctko_idx, drop = FALSE])

# Breadth threshold: global median across all windows in the WT (mark-positive baseline)
breadth_thresh <- median(lcpm_wt)
cat(sprintf("Breadth threshold (WT median logCPM): %.2f\n", breadth_thresh))

# ============================================================================
# Per-gene breadth scores
# ============================================================================

gene_ranges <- genes(TxDb.Mmusculus.UCSC.mm10.knownGene)
win_ranges  <- rowRanges(se)

# Find which 2kb windows overlap each gene body
olap <- findOverlaps(gene_ranges, win_ranges, ignore.strand = TRUE)

gene_hits <- queryHits(olap)
win_hits  <- subjectHits(olap)

breadth_tbl <- tapply(seq_along(win_hits), gene_hits, function(idx) {
  w <- win_hits[idx]
  data.frame(
    n_windows      = length(w),
    breadth_wt     = mean(lcpm_wt[w]   > breadth_thresh),
    breadth_ctko   = mean(lcpm_ctko[w] > breadth_thresh),
    mean_lcpm_wt   = mean(lcpm_wt[w]),
    mean_lcpm_ctko = mean(lcpm_ctko[w])
  )
}, simplify = FALSE)

breadth_df <- do.call(rbind, breadth_tbl)
breadth_df$gene_idx <- as.integer(rownames(breadth_df))
breadth_df$entrez   <- names(gene_ranges)[breadth_df$gene_idx]
breadth_df$symbol   <- mapIds(org.Mm.eg.db, breadth_df$entrez,
                               "SYMBOL", "ENTREZID", multiVals = "first")

breadth_df$delta_breadth <- breadth_df$breadth_ctko - breadth_df$breadth_wt
breadth_df$intensity_lfc <- breadth_df$mean_lcpm_ctko - breadth_df$mean_lcpm_wt

# Filter to genes with at least 5 windows (≥10 kb gene bodies — short genes unreliable)
breadth_df <- breadth_df[breadth_df$n_windows >= 5, ]
cat("Genes with ≥5 windows:", nrow(breadth_df), "\n")

# ============================================================================
# Join with intensity results from script 02
# ============================================================================

gene_tbl_02 <- res$genes_ql$table   # from overlapResults() in script 02

breadth_df <- merge(
  breadth_df,
  gene_tbl_02[, c("entrez", "FDR", "rep.logFC", "PValue")],
  by = "entrez", all.x = TRUE
)
breadth_df$rep.logFC <- as.numeric(breadth_df$rep.logFC)
breadth_df$FDR       <- as.numeric(breadth_df$FDR)

# ============================================================================
# Classify genes: intensity change vs breadth change
# ============================================================================

fdr_thresh    <- 0.10
lfc_thresh    <- 1.0
breadth_delta <- 0.15    # ≥15 percentage-point shift in fraction of windows marked

intensity_sig <- !is.na(breadth_df$FDR) &
                 breadth_df$FDR <= fdr_thresh &
                 abs(breadth_df$rep.logFC) >= lfc_thresh

breadth_sig   <- abs(breadth_df$delta_breadth) >= breadth_delta

breadth_df$change_class <- case_when(
  intensity_sig  & breadth_sig  ~ "Both",
  intensity_sig  & !breadth_sig ~ "Intensity only",
  !intensity_sig & breadth_sig  ~ "Breadth only",
  TRUE                           ~ "Neither"
)

cat("\nGene classification:\n")
print(table(breadth_df$change_class))

# Breadth direction among breadth-changed genes
breadth_changed <- breadth_df[breadth_sig, ]
cat("\nAmong breadth-changed genes:\n")
cat("  Gained breadth (cTKO > WT):", sum(breadth_changed$delta_breadth > 0), "\n")
cat("  Lost breadth   (cTKO < WT):", sum(breadth_changed$delta_breadth < 0), "\n")

# ============================================================================
# Plots
# ============================================================================

class_col <- c(
  "Both"           = "#9B2226",
  "Intensity only" = "#AE2012",
  "Breadth only"   = "#0077B6",
  "Neither"        = adjustcolor("grey60", alpha.f = 0.35)
)

pdf(file.path(dirs$diff, paste0("chip_breadth_", assay_name, ".pdf")),
    width = 14, height = 6)
par(mfrow = c(1, 3), mar = c(5, 5, 4, 2))

# --- Panel 1: WT breadth vs cTKO breadth per gene ---
col_vec <- class_col[breadth_df$change_class]
plot(
  breadth_df$breadth_wt, breadth_df$breadth_ctko,
  col  = col_vec, pch = 16, cex = 0.4,
  xlab = "Breadth score — WT\n(fraction of gene body windows above threshold)",
  ylab = "Breadth score — cTKO",
  main = paste(assay_name, "— Breadth per gene body")
)
abline(0, 1, col = "black", lty = 2)
legend("topleft", legend = names(class_col), col = class_col,
       pch = 16, cex = 0.75, bty = "n")

# --- Panel 2: intensity logFC vs breadth change ---
finite_mask <- is.finite(breadth_df$rep.logFC) & is.finite(breadth_df$delta_breadth)
df2 <- breadth_df[finite_mask, ]
col2 <- class_col[df2$change_class]
plot(
  df2$rep.logFC, df2$delta_breadth,
  col  = col2, pch = 16, cex = 0.4,
  xlab = "Intensity log2FC (cTKO / WT)\n[from csaw script 02]",
  ylab = "Δ Breadth (cTKO − WT)\n[fraction of gene body windows]",
  main = paste(assay_name, "— Intensity vs Breadth change")
)
abline(h = 0, v = 0, col = "grey40", lty = 2)
abline(h = c(-breadth_delta, breadth_delta), col = "steelblue", lty = 3)
abline(v = c(-lfc_thresh, lfc_thresh),       col = "firebrick",  lty = 3)

# --- Panel 3: histogram of delta breadth ---
hist(
  breadth_df$delta_breadth,
  breaks = 60, col = "steelblue", border = "white",
  xlab   = "Δ Breadth (cTKO − WT)",
  main   = paste(assay_name, "— Distribution of breadth change"),
  freq   = FALSE
)
abline(v = 0, col = "black", lty = 2, lwd = 2)
abline(v = c(-breadth_delta, breadth_delta), col = "firebrick", lty = 3)

dev.off()

# ============================================================================
# Save tables
# ============================================================================

write_csv(
  as_tibble(breadth_df) %>% arrange(delta_breadth),
  file.path(dirs$diff, paste0("chip_breadth_", assay_name, ".csv"))
)

# Breadth-only genes — the ones current pipeline missed entirely
breadth_only <- breadth_df[breadth_df$change_class == "Breadth only", ]
breadth_only <- breadth_only[order(abs(breadth_only$delta_breadth), decreasing = TRUE), ]

if (nrow(breadth_only) > 0) {
  cat("\nTop 20 breadth-only genes (missed by intensity analysis):\n")
  print(head(breadth_only[, c("symbol", "n_windows", "breadth_wt",
                               "breadth_ctko", "delta_breadth",
                               "rep.logFC", "FDR")], 20))
  write_csv(
    as_tibble(breadth_only),
    file.path(dirs$diff, paste0("chip_breadth_only_genes_", assay_name, ".csv"))
  )
}

cat("\n=== 04_ChIPseq_breadth.R complete ===\n")
cat("Outputs:\n")
cat("  Output: ../../results/ChIPseq/differential/\n")
