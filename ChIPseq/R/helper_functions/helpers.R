# ============================================================================
# Shared ChIPseq helper functions
# ============================================================================

# Computes quantile normalization factors from 10 kb IP bin-level logCPM.
# Forces each sample's logCPM distribution to the same quantiles, then
# back-converts to multiplicative factors on the count scale. Used as an
# alternative to TMM when global differences between conditions are expected.
quantile_norm_factors <- function(ip_bins) {
  y_b    <- asDGEList(ip_bins)
  lcpm   <- cpm(y_b, log = TRUE, prior.count = 1)
  lcpm_q <- normalizeBetweenArrays(lcpm, method = "quantile")
  shift  <- colMeans(lcpm_q - lcpm)
  nf     <- 2^shift
  nf / exp(mean(log(nf)))
}

# Fits a QL model and merges results for a single normalized window set.
# Estimates dispersion, fits a quasi-likelihood model, tests the cTKO
# coefficient, then merges adjacent significant windows into regions via
# mergeResults (tolerance 1 kb, max region width 30 kb).
# Used in 01_ChIPseq_norm_comparison where one window size is analyzed.
fit_and_merge_single <- function(filt, design) {
  y      <- asDGEList(filt)
  y      <- estimateDisp(y, design)
  fit    <- glmQLFit(y, design, robust = TRUE)
  res_ql <- glmQLFTest(fit, coef = "conditioncTKO")
  merged <- mergeResults(filt, tab = res_ql$table, tol = 1000,
                         merge.args = list(max.width = 30000))
  list(ql_large = list(y = y, fit = fit, res = res_ql), merged = merged)
}

# Fits QL models for two window sizes (2 kb and 500 bp) and combines their
# results via mergeResultsList with equal weighting. Testing at two scales
# improves sensitivity for both broad domains and sharp peaks. Used in
# 01_ChIPseq_analysis where the dual-window strategy is applied.
fit_and_merge_dual <- function(filt_lg, filt_sm, design) {
  fit_ql_one <- function(cf) {
    y   <- asDGEList(cf)
    y   <- estimateDisp(y, design)
    fit <- glmQLFit(y, design, robust = TRUE)
    list(y = y, fit = fit, res = glmQLFTest(fit, coef = "conditioncTKO"))
  }
  ql_large <- fit_ql_one(filt_lg)
  ql_small <- fit_ql_one(filt_sm)
  merged   <- mergeResultsList(
    ranges.list = list(filt_lg, filt_sm),
    tab.list    = list(ql_large$res$table, ql_small$res$table),
    equiweight  = TRUE, tol = 100,
    merge.args  = list(max.width = 30000)
  )
  list(ql_large = ql_large, ql_small = ql_small, merged = merged)
}

# Counts reads from all Input BAM files at the exact genomic windows defined
# by the IP SummarizedExperiment, then collapses them into a single pooled
# column. Using regionCounts (not windowCounts) ensures output ranges are
# identical to rowRanges(ip_counts), which is required by
# filterWindowsControl for the IP/Input enrichment calculation.
pool_input_at <- function(ip_counts, input_paths, param, frag_ext) {
  inp <- regionCounts(input_paths, regions = rowRanges(ip_counts),
                      ext = frag_ext, param = param)
  SummarizedExperiment(
    assays    = list(counts = matrix(rowSums(assay(inp, "counts")), ncol = 1)),
    rowRanges = rowRanges(inp),
    colData   = DataFrame(totals    = sum(colData(inp)$totals),
                          bam.files = "pooled_input")
  )
}
