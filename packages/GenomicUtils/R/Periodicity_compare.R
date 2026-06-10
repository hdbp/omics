#' Compare Nucleosome Repeat Length (NRL) periodicity across multiple samples
#'
#' Wrapper around \code{\link{fft_nrl}} that compares FFT-derived nucleosome
#' repeat length spectra across multiple BAM files, automatically reindexing
#' if necessary. Produces annotated overlay plots with sample-specific colors
#' and adjustable spacing for NRL ± CI labels.
#'
#' @inheritParams fft_nrl
#' @param overlay_plot Logical; whether to return the combined ggplot overlay (default: TRUE).
#'
#' @return A list with:
#' \itemize{
#'   \item \code{summary}: Tibble summarizing estimated NRL and CI for each sample.
#'   \item \code{plot}: ggplot overlay comparing FFT spectra (if \code{overlay_plot = TRUE}).
#' }
#'
#' @examples
#' \dontrun{
#' compare_fft_nrl(
#'   bamFiles = c("WT_1.bam", "WT_2.bam", "H1Low_1.bam", "H1Low_2.bam"),
#'   bamLabels = c("WT_1", "WT_2", "H1Low_1", "H1Low_2"),
#'   label_spacing = 0.08,
#'   colors = c(WT_1 = "#1b9e77", WT_2 = "#66a61e", H1Low_1 = "#d95f02", H1Low_2 = "#7570b3")
#' )$plot
#' }
#'
#' @seealso \code{\link{fft_nrl}}
#' @export
compare_fft_nrl <- function(
    bamFiles,
    bamLabels = basename(bamFiles),
    min_period = 100,
    max_period = 500,
    smooth_k = 5,
    overlay_plot = TRUE,
    colors = NULL,
    label_spacing = 0.05) {
  stopifnot(length(bamFiles) == length(bamLabels))

  res <- fft_nrl(
    bamFiles = bamFiles,
    bamLabels = bamLabels,
    min_period = min_period,
    max_period = max_period,
    smooth_k = smooth_k,
    plot = overlay_plot,
    colors = colors,
    label_spacing = label_spacing
  )

  list(summary = res$nrl_summary, plot = res$plot)
}
