#' @title Internal imports for PRO-seq metaplots
#' @name proseq_metas-imports
#' @keywords internal
#' @noRd
#' @importFrom BRGenomics tidyChromosomes
#' @importFrom Rsamtools ScanBamParam scanBamFlag
#' @importFrom GenomicAlignments readGAlignmentPairs readGAlignments granges
#' @importFrom GenomicRanges GRanges resize coverage strand seqnames trim
#' @importFrom GenomeInfoDb seqlengths
#' @importFrom IRanges IRanges Views start end width
#' @importFrom S4Vectors split
#' @importFrom tidyr pivot_longer
#' @importFrom dplyr group_by summarise mutate arrange ungroup
NULL


#' Process PRO-seq BAM files to generate strand-specific metaplots
#'
#' Defines:
#' - `proseq_meta()` — signal from full reads (paired/single).
#' - `proseq_3p_meta()` — signal from 3' ends only.
#' - `run_proseq_metaplots()` — chooses between the two.
#'
#' Fail-fast on inconsistent inputs.
#'
#' @param metadata data.frame with `bam`, `sample_name`, `condition`.
#' @param feature_center_gr GRanges of 1-bp centers to window around.
#' @param window Integer bp window half-width (default 2000).
#' @param nf Optional numeric normalization factors (length = nrow(metadata)).
#' @param nf_type One of `c("none","edgeR","deseq2")`.
#' @param strandMode Integer strand mode for paired alignments (default 2).
#' @param library One of `c("paired","single")` sequencing layout.
#' @param read_endpoint One of `c("full","three_prime")`.
#' @param smoothing_span Optional (0,1] loess span for smoothed metaplots.
#' @return List: long data, condition summary, and three ggplots.
#' @export
proseq_meta <- function(metadata, feature_center_gr, window = 2000, nf = NULL,
                        nf_type = c("none", "edgeR", "deseq2"),
                        strandMode = 2, library = c("paired", "single"),
                        smoothing_span = NULL) {
  library <- match.arg(library)
  nf_type <- match.arg(nf_type)

  if (!inherits(feature_center_gr, "GRanges")) {
    stop("`feature_center_gr` must be a GRanges.", call. = FALSE)
  }
  if (!all(c("bam", "sample_name", "condition") %in% names(metadata))) {
    stop("`metadata` must have columns: bam, sample_name, condition.", call. = FALSE)
  }
  if (!is.null(nf) && length(nf) != nrow(metadata)) {
    stop("Length of `nf` must match nrow(metadata).", call. = FALSE)
  }

  # sanitize reference loci
  feature_center_gr <- BRGenomics::tidyChromosomes(
    feature_center_gr,
    keep.X = FALSE, keep.Y = FALSE, keep.M = FALSE, keep.nonstandard = FALSE
  )
  feature_center_gr <- GenomicRanges::resize(feature_center_gr, width = 1, fix = "start")
  feature_center_gr <- GenomicRanges::resize(feature_center_gr, width = window, fix = "center")

  label_unit <- if (is.null(nf) || nf_type == "none") "RPM" else "Normalized"
  label_full <- if (is.null(nf) || nf_type == "none") {
    "Strand-specific metaplots (RPM normalized)"
  } else {
    "Strand-specific metaplots (Normalized signal)"
  }
  label_y <- if (is.null(nf) || nf_type == "none") "Signal (RPM)" else "Signal (Normalized)"

  lst <- vector("list", nrow(metadata))

  for (i in seq_len(nrow(metadata))) {
    if (identical(library, "paired")) {
      param <- Rsamtools::ScanBamParam(flag = Rsamtools::scanBamFlag(isProperPair = FALSE))
      gal <- GenomicAlignments::readGAlignmentPairs(metadata$bam[i], param = param, strandMode = strandMode)
    } else {
      gal <- GenomicAlignments::readGAlignments(metadata$bam[i])
    }

    gal <- BRGenomics::tidyChromosomes(
      gal,
      keep.X = FALSE, keep.Y = FALSE, keep.M = FALSE, keep.nonstandard = FALSE
    )

    libsize_millions <- length(gal) / 1e6
    norm_factor <- switch(nf_type,
      none = libsize_millions,
      edgeR = libsize_millions / nf[i],
      deseq2 = nf[i]
    )

    gr <- GenomicAlignments::granges(gal)
    GenomeInfoDb::seqlengths(gr) <- GenomeInfoDb::seqlengths(feature_center_gr)
    gr <- GenomicRanges::trim(gr)

    cov_plus <- GenomicRanges::coverage(gr[GenomicRanges::strand(gr) == "+"]) / norm_factor
    cov_minus <- GenomicRanges::coverage(gr[GenomicRanges::strand(gr) == "-"]) / norm_factor

    fwd <- feature_center_gr[GenomicRanges::strand(feature_center_gr) == "+"]
    rev <- feature_center_gr[GenomicRanges::strand(feature_center_gr) == "-"]

    sense_plus <- IRanges::Views(cov_plus, S4Vectors::split(fwd, GenomicRanges::seqnames(fwd)))
    antisense_plus <- IRanges::Views(cov_minus, S4Vectors::split(fwd, GenomicRanges::seqnames(fwd)))
    sense_minus <- IRanges::Views(cov_minus, S4Vectors::split(rev, GenomicRanges::seqnames(rev)))
    antisense_minus <- IRanges::Views(cov_plus, S4Vectors::split(rev, GenomicRanges::seqnames(rev)))

    m_sp <- as.matrix(sense_plus)
    m_ap <- as.matrix(antisense_plus)
    m_sm <- as.matrix(sense_minus)
    m_am <- as.matrix(antisense_minus)

    if (ncol(m_sm) > 0) {
      m_sm <- m_sm[, ncol(m_sm):1, drop = FALSE]
      m_am <- m_am[, ncol(m_am):1, drop = FALSE]
    }

    m_s <- rbind(m_sp, m_sm)
    m_as <- rbind(m_ap, m_am)

    if (ncol(m_s) == 0) {
      sig_s <- numeric(0)
      sig_as <- numeric(0)
    } else {
      sig_s <- colMeans(m_s, na.rm = TRUE)
      sig_as <- -colMeans(m_as, na.rm = TRUE)
    }

    pos <- seq(-floor(length(sig_s) / 2), ceiling(length(sig_s) / 2) - 1)

    lst[[i]] <- data.frame(
      position         = pos,
      signal_sense     = as.numeric(sig_s),
      signal_antisense = as.numeric(sig_as),
      sample_name      = metadata$sample_name[i],
      condition        = metadata$condition[i],
      stringsAsFactors = FALSE
    )
  }

  df_long <- do.call(rbind, lst) |>
    tidyr::pivot_longer(c(signal_sense, signal_antisense), names_to = "strand_type", values_to = "signal") |>
    dplyr::mutate(strand_type = ifelse(strand_type == "signal_sense", "Sense", "Antisense"))

  df_summary <- df_long |>
    dplyr::group_by(condition, position, strand_type) |>
    dplyr::summarise(signal = mean(signal, na.rm = TRUE), .groups = "drop")

  if (!is.null(smoothing_span)) {
    df_summary <- df_summary |>
      dplyr::group_by(condition, strand_type) |>
      dplyr::arrange(position, .by_group = TRUE) |>
      dplyr::mutate(signal = stats::loess(signal ~ position, span = smoothing_span)$fitted) |>
      dplyr::ungroup()
  }

  ucond <- unique(df_summary$condition)
  linetype_mapping <- stats::setNames(c("solid", "dashed", "dotted", "dotdash")[seq_along(ucond)], ucond)

  p1 <- ggplot2::ggplot(df_long, ggplot2::aes(x = position, y = signal, color = strand_type)) +
    ggplot2::geom_line() +
    ggplot2::facet_wrap(~ sample_name + condition, ncol = 3) +
    ggplot2::scale_color_manual(values = c("Sense" = "black", "Antisense" = "red")) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::labs(title = label_full, x = "Position around feature_center_gr", y = label_y) +
    ggplot2::theme_minimal()

  p2 <- ggplot2::ggplot(df_summary, ggplot2::aes(x = position, y = signal, color = strand_type)) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::facet_wrap(~condition, ncol = 2) +
    ggplot2::scale_color_manual(values = c("Sense" = "black", "Antisense" = "red")) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::geom_vline(xintercept = 0, linetype = "dashed", color = "red") +
    ggplot2::labs(
      title = paste("Average strand-specific signal per condition (", label_unit, ")", sep = ""),
      x = "Position around feature_center_gr", y = label_y
    ) +
    ggplot2::theme_minimal()

  p3 <- ggplot2::ggplot(df_summary, ggplot2::aes(x = position, y = signal, color = strand_type, linetype = condition)) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::scale_color_manual(values = c("Sense" = "black", "Antisense" = "red")) +
    ggplot2::scale_linetype_manual(values = linetype_mapping) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::labs(
      title = paste("Overlayed strand-specific signal per condition (", label_unit, ")", sep = ""),
      x = "Position around feature_center_gr", y = label_y
    ) +
    ggplot2::theme_minimal()

  list(
    df_long = df_long, df_summary = df_summary,
    plot_sample = p1, plot_summary = p2, plot_overlay = p3
  )
}

#' PRO-seq metaplot using only 3' ends of reads
#'
#' @inheritParams proseq_meta
#' @export
proseq_3p_meta <- function(metadata, feature_center_gr, window = 2000, smoothing_span = NULL) {
  if (!all(c("bam", "sample_name", "condition") %in% names(metadata))) {
    stop("`metadata` must have columns: bam, sample_name, condition.", call. = FALSE)
  }
  feature_center_gr <- BRGenomics::tidyChromosomes(
    feature_center_gr,
    keep.X = FALSE, keep.Y = FALSE, keep.M = FALSE, keep.nonstandard = FALSE
  )
  feature_center_gr <- GenomicRanges::resize(feature_center_gr, width = 1, fix = "start")
  feature_center_gr <- GenomicRanges::resize(feature_center_gr, width = window, fix = "center")

  lst <- vector("list", nrow(metadata))

  for (i in seq_len(nrow(metadata))) {
    param <- Rsamtools::ScanBamParam(flag = Rsamtools::scanBamFlag(isProperPair = FALSE))
    gal <- GenomicAlignments::readGAlignmentPairs(metadata$bam[i], param = param, strandMode = 2)
    gal <- BRGenomics::tidyChromosomes(
      gal,
      keep.X = FALSE, keep.Y = FALSE, keep.M = FALSE, keep.nonstandard = FALSE
    )
    libsize_millions <- length(gal) / 1e6

    base_gr <- GenomicAlignments::granges(gal)
    gr <- GenomicRanges::GRanges(
      seqnames = GenomicRanges::seqnames(base_gr),
      ranges   = IRanges::IRanges(start = GenomicRanges::end(base_gr), end = GenomicRanges::end(base_gr)),
      strand   = GenomicRanges::strand(base_gr)
    )
    GenomeInfoDb::seqlengths(gr) <- GenomeInfoDb::seqlengths(feature_center_gr)
    gr <- GenomicRanges::trim(gr)

    cov_plus <- GenomicRanges::coverage(gr[GenomicRanges::strand(gr) == "+"]) / libsize_millions
    cov_minus <- GenomicRanges::coverage(gr[GenomicRanges::strand(gr) == "-"]) / libsize_millions

    fwd <- feature_center_gr[GenomicRanges::strand(feature_center_gr) == "+"]
    rev <- feature_center_gr[GenomicRanges::strand(feature_center_gr) == "-"]

    sense_plus <- IRanges::Views(cov_plus, S4Vectors::split(fwd, GenomicRanges::seqnames(fwd)))
    antisense_plus <- IRanges::Views(cov_minus, S4Vectors::split(fwd, GenomicRanges::seqnames(fwd)))
    sense_minus <- IRanges::Views(cov_minus, S4Vectors::split(rev, GenomicRanges::seqnames(rev)))
    antisense_minus <- IRanges::Views(cov_plus, S4Vectors::split(rev, GenomicRanges::seqnames(rev)))

    m_sp <- as.matrix(sense_plus)
    m_ap <- as.matrix(antisense_plus)
    m_sm <- as.matrix(sense_minus)
    m_am <- as.matrix(antisense_minus)

    if (ncol(m_sm) > 0) {
      m_sm <- m_sm[, ncol(m_sm):1, drop = FALSE]
      m_am <- m_am[, ncol(m_am):1, drop = FALSE]
    }

    m_s <- rbind(m_sp, m_sm)
    m_as <- rbind(m_ap, m_am)

    if (ncol(m_s) == 0) {
      sig_s <- numeric(0)
      sig_as <- numeric(0)
    } else {
      sig_s <- colMeans(m_s, na.rm = TRUE)
      sig_as <- -colMeans(m_as, na.rm = TRUE)
    }

    pos <- seq(-floor(length(sig_s) / 2), ceiling(length(sig_s) / 2) - 1)

    lst[[i]] <- data.frame(
      position         = pos,
      signal_sense     = as.numeric(sig_s),
      signal_antisense = as.numeric(sig_as),
      sample_name      = metadata$sample_name[i],
      condition        = metadata$condition[i],
      stringsAsFactors = FALSE
    )
  }

  df_long <- do.call(rbind, lst) |>
    tidyr::pivot_longer(c(signal_sense, signal_antisense), names_to = "strand_type", values_to = "signal") |>
    dplyr::mutate(strand_type = ifelse(strand_type == "signal_sense", "Sense", "Antisense"))

  df_summary <- df_long |>
    dplyr::group_by(condition, position, strand_type) |>
    dplyr::summarise(signal = mean(signal, na.rm = TRUE), .groups = "drop")

  if (!is.null(smoothing_span)) {
    df_summary <- df_summary |>
      dplyr::group_by(condition, strand_type) |>
      dplyr::arrange(position, .by_group = TRUE) |>
      dplyr::mutate(signal = stats::loess(signal ~ position, span = smoothing_span)$fitted) |>
      dplyr::ungroup()
  }

  ucond <- unique(df_summary$condition)
  linetype_mapping <- stats::setNames(c("solid", "dashed", "dotted", "dotdash")[seq_along(ucond)], ucond)

  p1 <- ggplot2::ggplot(df_long, ggplot2::aes(x = position, y = signal, color = strand_type)) +
    ggplot2::geom_line() +
    ggplot2::facet_wrap(~ sample_name + condition, ncol = 3) +
    ggplot2::scale_color_manual(values = c("Sense" = "black", "Antisense" = "red")) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::labs(
      title = "Strand-specific metaplots (RPM normalized)",
      x = "Position around feature_center_gr", y = "Signal"
    ) +
    ggplot2::theme_minimal()

  p2 <- ggplot2::ggplot(df_summary, ggplot2::aes(x = position, y = signal, color = strand_type)) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::facet_wrap(~condition, ncol = 2) +
    ggplot2::scale_color_manual(values = c("Sense" = "black", "Antisense" = "red")) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::geom_vline(xintercept = 0, linetype = "dashed", color = "red") +
    ggplot2::labs(
      title = "Average strand-specific signal per condition",
      x = "Position around feature_center_gr", y = "Signal (RPM)"
    ) +
    ggplot2::theme_minimal()

  p3 <- ggplot2::ggplot(df_summary, ggplot2::aes(x = position, y = signal, color = strand_type, linetype = condition)) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::scale_color_manual(values = c("Sense" = "black", "Antisense" = "red")) +
    ggplot2::scale_linetype_manual(values = linetype_mapping) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::labs(
      title = "Overlayed strand-specific signal per condition",
      x = "Position around feature_center_gr", y = "Signal (RPM)"
    ) +
    ggplot2::theme_minimal()

  list(
    df_long = df_long, df_summary = df_summary,
    plot_sample = p1, plot_summary = p2, plot_overlay = p3
  )
}

#' Wrapper to run PRO-seq metaplot analysis
#'
#' Chooses between full-read and 3'-end modes.
#' @inheritParams proseq_meta
#' @export
run_proseq_metaplots <- function(metadata, feature_center_gr, window = 2000,
                                 nf = NULL, nf_type = c("none", "edgeR", "deseq2"),
                                 strandMode = 2, library = c("paired", "single"),
                                 read_endpoint = c("full", "three_prime"),
                                 smoothing_span = NULL) {
  read_endpoint <- match.arg(read_endpoint)
  if (identical(read_endpoint, "full")) {
    message("Running full-read PRO-seq metaplot...")
    proseq_meta(metadata, feature_center_gr, window, nf, nf_type, strandMode, library, smoothing_span)
  } else {
    message("Running 3'-end PRO-seq metaplot...")
    proseq_3p_meta(metadata, feature_center_gr, window, smoothing_span)
  }
}
