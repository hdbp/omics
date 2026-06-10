#' Compute Nucleosome Repeat Length (NRL) by FFT
#'
#' Performs Fast Fourier Transform (FFT) on fragment length distributions
#' from paired-end BAM files to detect nucleosome repeat periodicity and estimate
#' confidence intervals (CI). Automatically regenerates outdated BAM indexes (.bai)
#' and produces a publication-ready plot with customizable, non-overlapping NRL ± CI annotations.
#'
#' @param bamFiles Character vector of BAM file paths.
#' @param bamLabels Optional character vector of sample labels (same length as \code{bamFiles});
#'   defaults to the BAM file basenames.
#' @param min_period Numeric; minimum fragment length period to include in FFT spectrum (default: 100).
#' @param max_period Numeric; maximum fragment length period to include in FFT spectrum (default: 500).
#' @param smooth_k Integer; rolling mean window for fragment smoothing (default: 5).
#' @param plot Logical; whether to produce a ggplot overlay (default: TRUE).
#' @param colors Optional named vector of custom colors for samples, e.g. \code{c(WT="#1b9e77", H1Low="#d95f02")}.
#' @param label_spacing Numeric; vertical spacing between NRL annotations as a fraction of max signal (default: 0.05).
#'
#' @return A list with:
#' \itemize{
#'   \item \code{nrl_summary}: Tibble summarizing NRL and CI for each sample.
#'   \item \code{spectrum}: Tibble with full period–strength data for each sample.
#'   \item \code{plot}: ggplot overlay (if \code{plot = TRUE}).
#' }
#'
#' @examples
#' \dontrun{
#' bam_files <- c("WT_1.bam", "H1Low_1.bam")
#' labels <- c("WT", "H1Low")
#' fft_nrl(bam_files, bamLabels = labels, label_spacing = 0.08)
#' }
#'
#' @export
#' @importFrom Rsamtools indexBam idxstatsBam
#' @importFrom scales hue_pal
#' @importFrom ggplot2 ggplot aes geom_line geom_vline geom_text scale_color_manual labs theme_minimal theme element_text
fft_nrl <- function(
    bamFiles,
    bamLabels = basename(bamFiles),
    min_period = 100,
    max_period = 500,
    smooth_k = 5,
    plot = TRUE,
    colors = NULL,
    label_spacing = 0.05) {
  stopifnot(length(bamFiles) == length(bamLabels))

  suppressPackageStartupMessages({
    requireNamespace("dplyr")
    requireNamespace("zoo")
    requireNamespace("ggplot2")
    requireNamespace("purrr")
    requireNamespace("scales")
    requireNamespace("Rsamtools")
  })

  # --- Auto reindex if .bai outdated ----------------------------------------
  for (bf in bamFiles) {
    bai <- paste0(bf, ".bai")
    if (file.exists(bai)) {
      if (file.mtime(bai) < file.mtime(bf)) {
        message("Reindexing outdated BAM index: ", bf)
        Rsamtools::indexBam(bf)
      }
    } else {
      message("Missing BAM index detected. Indexing: ", bf)
      Rsamtools::indexBam(bf)
    }
  }

  # --- Internal worker -------------------------------------------------------
  .fft_single <- function(bamFile, label) {
    frag_df <- as.data.frame(frag(bamFiles = bamFile, bamFiles.labels = label))
    colnames(frag_df) <- c("length", "count")
    frag_df$length <- suppressWarnings(as.numeric(as.character(frag_df$length)))

    frag_df <- frag_df |>
      dplyr::filter(!is.na(length), length <= 1000) |>
      dplyr::arrange(length)

    if (nrow(frag_df) < 10) {
      return(list(nrl_summary = tibble::tibble(
        sample = label, NRL = NA, CI_low = NA, CI_high = NA, CI_width = NA
      ), spectrum = tibble::tibble(period = numeric(), strength = numeric())))
    }

    frag_df$count_smooth <- zoo::rollmean(frag_df$count, k = smooth_k, fill = NA)
    y <- frag_df$count_smooth - mean(frag_df$count_smooth, na.rm = TRUE)
    y[is.na(y)] <- 0
    n <- length(y)

    fft_res <- fft(y)
    strength <- Mod(fft_res)[1:(n / 2)] / n
    period <- n / (1:(n / 2))

    spectrum <- tibble::tibble(period, strength) |>
      dplyr::filter(period >= min_period, period <= max_period)

    peak_idx <- which(diff(sign(diff(spectrum$strength))) == -2) + 1
    peaks <- spectrum[peak_idx, , drop = FALSE] |>
      dplyr::arrange(dplyr::desc(strength))

    if (nrow(peaks) == 0) {
      return(list(nrl_summary = tibble::tibble(
        sample = label, NRL = NA, CI_low = NA, CI_high = NA, CI_width = NA
      ), spectrum = spectrum))
    }

    main_peak <- peaks[1, ]
    halfmax <- main_peak$strength / 2
    idx <- which(spectrum$strength > halfmax)
    ci <- range(spectrum$period[idx])
    ci_width <- diff(ci)

    nrl_summary <- tibble::tibble(
      sample = label,
      NRL = main_peak$period,
      CI_low = ci[1],
      CI_high = ci[2],
      CI_width = ci_width
    )

    list(nrl_summary = nrl_summary, spectrum = spectrum)
  }

  # --- Aggregate all ----------------------------------------------------------
  results <- purrr::map2(bamFiles, bamLabels, .fft_single)
  summary_tbl <- dplyr::bind_rows(purrr::map(results, "nrl_summary"))
  spectra_tbl <- dplyr::bind_rows(purrr::map2(
    results, bamLabels,
    ~ dplyr::mutate(.x$spectrum, sample = .y)
  ))

  # --- Plot -------------------------------------------------------------------
  p <- NULL
  if (plot && nrow(spectra_tbl) > 0) {
    ymax <- max(spectra_tbl$strength, na.rm = TRUE)
    summary_tbl <- summary_tbl |>
      dplyr::mutate(ypos = seq(from = ymax * (1 - label_spacing), by = -ymax * label_spacing, length.out = n()))

    if (is.null(colors)) {
      colors <- setNames(
        scales::hue_pal()(length(unique(bamLabels))),
        unique(bamLabels)
      )
    }

    p <- ggplot2::ggplot(
      spectra_tbl,
      ggplot2::aes(period, strength, color = sample)
    ) +
      ggplot2::geom_line(linewidth = 0.8) +
      ggplot2::scale_color_manual(values = colors) +
      ggplot2::geom_vline(
        data = summary_tbl,
        ggplot2::aes(xintercept = NRL, color = sample),
        linetype = "dashed"
      ) +
      ggplot2::geom_text(
        data = summary_tbl,
        ggplot2::aes(
          x = NRL,
          y = ypos,
          label = paste0(
            sample, "\nNRL=", round(NRL, 1),
            " bp [", round(CI_low, 1), "-", round(CI_high, 1), "]"
          ),
          color = sample
        ),
        hjust = -0.05, vjust = 1, size = 3.2, show.legend = FALSE
      ) +
      ggplot2::labs(
        title = "FFT-based NRL Spectrum",
        x = "Period (bp)", y = "Spectral strength"
      ) +
      ggplot2::theme_minimal(base_size = 12) +
      ggplot2::theme(
        plot.title = ggplot2::element_text(hjust = 0.5, face = "bold"),
        legend.title = ggplot2::element_blank()
      )
  }

  list(nrl_summary = summary_tbl, spectrum = spectra_tbl, plot = p)
}
