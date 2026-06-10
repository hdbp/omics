#' Plot nucleosome repeat length (NRL) between two BAM files
#'
#' Computes fragment size density, smooths the signal, finds peaks,
#' calculates NRL, left-shift, and up-shift, and generates a comparative plot.
#'
#' @param bam_ctrl Path to control BAM file
#' @param bam_test Path to test BAM file
#' @param label_ctrl Label for control sample
#' @param label_test Label for test sample
#' @param plot_label Title for the plot
#'
#' @return A data.frame summarizing nrl.ctrl, nrl.test, leftshift, and upshift
#'
#' @export
#'
#' @examples
#' \dontrun{
#' nrl2("ctrl.bam", "test.bam", "Ctrl", "Test", "NRL Comparison")
#' }
nrl2 <- function(bam_ctrl, bam_test, label_ctrl, label_test, plot_label) {
  process_sample <- function(bam, label) {
    df <- data.frame(fragSizeDist(bam, label))
    colnames(df) <- c("var", "freq")

    smoothed <- data.frame(
      index = seq_along(zoo::rollmean(df$freq, 50)),
      density = zoo::rollmean(log10(df$freq), 50)
    )

    smoothed <- subset(smoothed, index > 150 & index < 600)
    peaks <- smoothed[find_peaks(smoothed$density, m = 50), ]

    list(df = df, smoothed = smoothed, peaks = peaks)
  }

  ctrl <- process_sample(bam_ctrl, label_ctrl)
  test <- process_sample(bam_test, label_test)

  nrl.ctrl <- diff(ctrl$peaks[1:2, "index"])
  nrl.test <- diff(test$peaks[1:2, "index"])
  upshift <- (test$peaks[2, "density"] - ctrl$peaks[2, "density"]) / ctrl$peaks[2, "density"] * 100
  leftshift <- nrl.ctrl - nrl.test

  summary.nrl <- data.frame(
    nrl.ctrl = paste(nrl.ctrl, "bp"),
    nrl.test = paste(nrl.test, "bp"),
    leftshift = paste(leftshift, "bp"),
    upshift = paste(round(upshift, 2), "%")
  )

  # Plot
  plot(zoo::rollmean(log10(ctrl$df$freq), 50),
    type = "l", lwd = 2, xlim = c(0, 1000), xaxt = "n",
    ylab = expression(Normalized ~ read ~ density ~ x ~ 10^-3),
    xlab = "Fragment Length (bp)"
  )
  lines(zoo::rollmean(log10(test$df$freq), 50), col = "red", lwd = 2)
  axis(1, at = seq(0, 1000, 100))
  title(main = plot_label, adj = 0)
  abline(
    v = c(ctrl$peaks[1:2, "index"], test$peaks[1:2, "index"]),
    col = c("black", "black", "red", "red")
  )
  legend("topright", legend = c(label_ctrl, label_test), col = c("black", "red"), lty = 1, lwd = 2, bty = "n")
  legend("bottomright",
    legend = c(
      paste("leftshift", leftshift, "bp"),
      paste("upshift", round(upshift), "%"),
      paste(label_ctrl, nrl.ctrl, "bp"),
      paste(label_test, nrl.test, "bp")
    ), bty = "n"
  )

  invisible(summary.nrl)
}

#' Plot NRL for a single BAM file
#'
#' Computes fragment size density, smooths the signal, finds peaks,
#' calculates NRL, and generates a plot.
#'
#' @param bam Path to BAM file
#' @param label Sample label
#' @param plot_label Title for the plot
#'
#' @return NRL value (numeric)
#'
#' @export
#'
#' @examples
#' \dontrun{
#' nrl("sample.bam", "Sample", "NRL Plot")
#' }
nrl <- function(bam, label, plot_label) {
  df <- data.frame(fragSizeDist(bam, label))
  colnames(df) <- c("var", "freq")

  smoothed <- data.frame(
    index = seq_along(zoo::rollmean(df$freq, 50)),
    density = zoo::rollmean(log10(df$freq), 50)
  )

  peaks <- smoothed[find_peaks(smoothed$density, m = 50), ]
  nrl_val <- diff(peaks[1:2, "index"])

  plot(zoo::rollmean(log10(df$freq), 50),
    type = "l", lwd = 2, xlim = c(0, 1000), xaxt = "n",
    ylab = expression(Normalized ~ read ~ density ~ x ~ 10^-3),
    xlab = "Fragment Length (bp)"
  )

  axis(1, at = seq(0, 1000, 100))
  title(main = plot_label, adj = 0)
  abline(v = peaks[1:2, "index"], col = "black")
  legend("topright", legend = label, col = "black", lty = 1, lwd = 2, bty = "n")

  invisible(nrl_val)
}

#' Calculate NRL from a BAM file
#'
#' Returns the NRL value (distance between first two peaks)
#'
#' @param bam Path to BAM file
#'
#' @return NRL value (numeric)
#'
#' @export
calc_nrl <- function(bam) {
  sample <- frag(bam, "")
  sample <- data.frame(sample)
  colnames(sample) <- c("var", "freq")

  smooth <- data.frame(
    index = seq_along(zoo::rollmean(sample$freq, 50)),
    density = zoo::rollmean(log10(sample$freq), 50)
  )

  max_peaks <- smooth[find_peaks(smooth$density, m = 50), ] %>% dplyr::filter(index > 100)
  nrl <- max_peaks[2, 1] - max_peaks[1, 1]
  return(nrl)
}

#' Plot NRL from a BAM file
#'
#' Computes NRL and plots the fragment density with peaks.
#'
#' @param bam Path to BAM file
#' @param label Sample label
#' @param plot_label Plot title
#'
#' @return NRL value (numeric)
#'
#' @export
plot_nrl <- function(bam, label, plot_label) {
  sample <- frag(bam, label)
  sample <- data.frame(sample)
  colnames(sample) <- c("var", "freq")

  smooth <- data.frame(
    index = seq_along(zoo::rollmean(sample$freq, 50)),
    density = zoo::rollmean(log10(sample$freq), 50)
  )

  max_peaks <- smooth[find_peaks(smooth$density, m = 50), ] %>% dplyr::filter(index > 100)
  nrl <- max_peaks[2, 1] - max_peaks[1, 1]

  plot(zoo::rollmean(log10(sample$freq), 50),
    type = "l", lwd = 2, xlim = c(0, 1000), xaxt = "n",
    ylab = expression(Normalized ~ read ~ density ~ x ~ 10^-3),
    xlab = "Fragment Length (bp)"
  )
  axis(1, at = seq(0, 1000, 100))
  title(main = plot_label, adj = 0)
  abline(v = max_peaks[1:2, "index"], col = "black")
  legend("topright", legend = c(plot_label, paste("NRL =", nrl, "bp")), col = "black", lty = 1, lwd = 2, bty = "n")

  invisible(nrl)
}

#' Compare NRL between control and test BAM files
#'
#' Computes and plots fragment density for control and test samples with NRL comparison
#'
#' @param bam_ctrl Path to control BAM
#' @param bam_test Path to test BAM
#' @param label_ctrl Label for control sample
#' @param label_test Label for test sample
#' @param plot_label Title for the plot
#'
#' @return None (plots to graphics device)
#'
#' @export
plot_nrl_compare <- function(bam_ctrl, bam_test, label_ctrl, label_test, plot_label) {
  ctrl <- frag(bam_ctrl, label_ctrl)
  ctrl <- data.frame(ctrl)
  colnames(ctrl) <- c("var", "freq")
  test <- frag(bam_test, label_test)
  test <- data.frame(test)
  colnames(test) <- c("var", "freq")

  smooth.ctrl <- data.frame(
    index = seq_along(zoo::rollmean(ctrl$freq, 50)),
    density = zoo::rollmean(log10(ctrl$freq), 50)
  )
  smooth.ctrl <- smooth.ctrl[smooth.ctrl$index > 150 & smooth.ctrl$index < 600, ]
  max.ctrl <- smooth.ctrl[find_peaks(smooth.ctrl$density, m = 50), ]
  nrl.ctrl <- max.ctrl[2, 1] - max.ctrl[1, 1]

  smooth.test <- data.frame(
    index = seq_along(zoo::rollmean(test$freq, 50)),
    density = zoo::rollmean(log10(test$freq), 50)
  )
  smooth.test <- smooth.test[smooth.test$index > 150 & smooth.test$index < 600, ]
  max.test <- smooth.test[find_peaks(smooth.test$density, m = 50), ]
  nrl.test <- max.test[2, 1] - max.test[1, 1]

  upshift <- (max.test[2, 2] - max.ctrl[2, 2]) / max.ctrl[2, 2] * 100
  leftshift <- nrl.ctrl - nrl.test

  plot(zoo::rollmean(log10(ctrl$freq), 50),
    type = "l", lwd = 2, xlim = c(0, 1000), xaxt = "n",
    ylab = expression(Normalized ~ read ~ density ~ x ~ 10^-3),
    xlab = "Fragment Length (bp)"
  )
  lines(zoo::rollmean(log10(test$freq), 50), col = "red", lwd = 2)
  axis(1, at = seq(0, 1000, 100))
  title(main = plot_label, adj = 0)
  abline(
    v = c(max.ctrl[1, 1], max.ctrl[2, 1], max.test[1, 1], max.test[2, 1]),
    col = c("black", "black", "red", "red")
  )
  legend("topright", legend = c(label_ctrl, label_test), col = c("black", "red"), lty = 1, lwd = 2, bty = "n")
  legend("bottomright",
    legend = c(
      paste("leftshift", leftshift, "bp"),
      paste("upshift", round(upshift), "%"),
      paste(label_ctrl, nrl.ctrl, "bp"),
      paste(label_test, nrl.test, "bp")
    ),
    bty = "n"
  )
}
