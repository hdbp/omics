#' Compute FFT-based fragment size periodicity
#'
#' Computes the fragment size distribution from a BAM file,
#' applies FFT to identify periodic signals, and returns
#' the spectrum and peak periodicity.
#'
#' @param bamFile Path to BAM file.
#' @param bamFileLabel Label for the BAM file (used in plots).
#' @param min_period Minimum period to include in the spectrum (default: 2).
#' @param max_period Maximum period to include in the spectrum (default: 1000).
#'
#' @return A list with two elements:
#'   \item{data}{A data frame of period vs. strength values.}
#'   \item{peak}{A data frame containing the peak period and its strength.}
#'
#' @export
compute_periodicity <- function(bamFile, bamFileLabel, min_period = 2, max_period = 1000) {
  fragSizeDist <- data.frame(frag(bamFile, bamFileLabel))
  colnames(fragSizeDist) <- c("Var", "Freq")

  n <- length(fragSizeDist$Freq)
  strength <- Mod(fft(fragSizeDist$Freq)) / n
  periodx <- n / (1:(n - 1))
  strength <- strength[-1]

  rs <- data.frame(period = periodx, strength = strength) %>%
    dplyr::filter(period > min_period, period < max_period)

  peak <- rs %>% dplyr::filter(strength == max(strength))
  list(data = rs, peak = peak)
}

#' Extract periodicity from a single sample
#'
#' Wrapper around compute_periodicity() to either
#' return the peak period value or plot the full spectrum.
#'
#' @param bamFile Path to BAM file.
#' @param bamFileLabel Label for the BAM file.
#' @param min_period Minimum period to include in the spectrum (default: 2).
#' @param max_period Maximum period to include in the spectrum (default: 1000).
#' @param return_plot Logical. If TRUE, returns a ggplot of the spectrum (default: FALSE).
#'
#' @return Either a numeric value (peak period) or a ggplot object.
#'
#' @export
periodicity <- function(bamFile, bamFileLabel,
                        min_period = 2, max_period = 1000,
                        return_plot = FALSE) {
  res <- compute_periodicity(bamFile, bamFileLabel, min_period, max_period)

  if (!return_plot) {
    return(res$peak$period)
  }

  ggplot2::ggplot(res$data, ggplot2::aes(period, strength)) +
    ggplot2::geom_vline(xintercept = res$peak$period, linetype = 2) +
    ggplot2::geom_line(color = "red") +
    ggplot2::theme_bw() +
    ggplot2::theme(
      panel.grid = ggplot2::element_blank(),
      plot.title = ggplot2::element_text(hjust = 0.5)
    ) +
    ggplot2::annotate("text",
      x = res$peak$period, y = max(res$data$strength),
      label = round(res$peak$period)
    ) +
    ggplot2::labs(title = bamFileLabel, x = "period", y = "strength")
}

#' Compare periodicity between two BAM files
#'
#' Computes FFT-based periodicity for a control and test BAM,
#' plots both spectra, and reports the delta in peak period.
#'
#' @param bamFile.ctrl Path to control BAM file.
#' @param bamFile.test Path to test BAM file.
#' @param bamFile.ctrl.label Label for the control sample.
#' @param bamFile.test.label Label for the test sample.
#' @param min_period Minimum period to include in the spectrum (default: 2).
#' @param max_period Maximum period to include in the spectrum (default: 1000).
#'
#' @return A list with:
#'   \item{ctrl}{Peak period in the control sample.}
#'   \item{test}{Peak period in the test sample.}
#'   \item{delta}{Difference (ctrl - test).}
#'   \item{plot}{A ggplot comparing both spectra.}
#'
#' @export
periodicity_compare <- function(bamFile.ctrl, bamFile.test,
                                bamFile.ctrl.label, bamFile.test.label,
                                min_period = 2, max_period = 1000) {
  ctrl <- compute_periodicity(bamFile.ctrl, bamFile.ctrl.label, min_period, max_period)
  test <- compute_periodicity(bamFile.test, bamFile.test.label, min_period, max_period)

  ctrl$data$sample <- bamFile.ctrl.label
  test$data$sample <- bamFile.test.label
  rs2 <- rbind(ctrl$data, test$data)

  plot <- ggplot2::ggplot(rs2, ggplot2::aes(period, strength, colour = sample)) +
    ggplot2::geom_line() +
    ggplot2::geom_vline(xintercept = ctrl$peak$period, linetype = 2) +
    ggplot2::geom_vline(xintercept = test$peak$period, linetype = 2, colour = "red") +
    ggplot2::scale_colour_manual(values = c("black", "red")) +
    ggplot2::theme_bw() +
    ggplot2::theme(
      panel.grid = ggplot2::element_blank(),
      plot.title = ggplot2::element_text(hjust = 0.5)
    ) +
    ggplot2::annotate("text",
      x = ctrl$peak$period + 30, y = max(ctrl$data$strength) + 250,
      label = round(ctrl$peak$period)
    ) +
    ggplot2::annotate("text",
      x = test$peak$period - 30, y = max(test$data$strength) + 250,
      label = round(test$peak$period), colour = "red"
    ) +
    ggplot2::labs(
      title = paste(bamFile.ctrl.label, "vs", bamFile.test.label),
      x = "period", y = "strength"
    )

  list(
    ctrl = ctrl$peak$period,
    test = test$peak$period,
    delta = ctrl$peak$period - test$peak$period,
    plot = plot
  )
}
