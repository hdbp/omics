
#' Plot average signal profiles with custom styling
#'
#' This function plots summarized signal profiles (e.g. from ChIP-seq or
#' other coverage-based assays) over a genomic window, using base R graphics.
#' It expects as input the result of a \code{profile_summarize()}-style
#' function that stores plotting arguments in \code{attr(x$data, "args")}.
#'
#' @param sig_list A list-like object containing summarized signal, typically
#'   the output of \code{profile_summarize()}. Must have a \code{$data}
#'   component and an \code{"args"} attribute containing upstream and
#'   downstream window sizes.
#' @param color Optional character vector of colors. If \code{NULL}, a default
#'   palette is used.
#' @param line_size Numeric line width passed to \code{points()} when drawing
#'   the profiles.
#' @param legend_fs Numeric scaling factor for legend text size.
#' @param axis_fs Numeric scaling factor for axis text size.
#' @param xlab,ylab Axis labels for x and y.
#' @param ymin,ymax Optional numeric values to fix the y-axis limits.
#'
#' @return A list (invisibly) containing the mean signal, color codes, x-ticks,
#'   x-labels, and y-limits used in the plot.
#' @export
profile_plot2 <- function(sig_list = NULL,
                          color = NULL,
                          line_size = 1,
                          legend_fs = 1,
                          axis_fs = 1,
                          xlab = NA,
                          ylab = NA,
                          ymin = NULL,
                          ymax = NULL) {
  if (is.null(sig_list)) {
    stop("Missing input: expecting output from profile_summarize().")
  }
  if (is.null(sig_list$data)) {
    stop("sig_list$data is missing.")
  }

  args <- attr(sig_list$data, "args")
  if (is.null(args) || length(args) < 2L) {
    stop("sig_list$data must carry an 'args' attribute with up/down values.")
  }

  up <- as.numeric(args[1])
  down <- as.numeric(args[2])
  sig_summary <- sig_list$data

  if (!is.list(sig_summary) || !length(sig_summary)) {
    stop("sig_list$data must be a non-empty list of numeric vectors.")
  }

  if (is.null(color)) {
    color <- c(
      "#2f4f4f", "#8b4513", "#228b22", "#00008b",
      "#ff0000", "#ffd700", "#7fff00", "#00ffff",
      "#ff00ff", "#6495ed", "#ffe4b5", "#ff69b4"
    )
    color <- color[seq_len(length(sig_summary))]
  }

  # Determine plot limits
  y_max <- max(unlist(lapply(sig_summary, max, na.rm = TRUE)))
  y_min <- min(unlist(lapply(sig_summary, min, na.rm = TRUE)))

  if (!is.null(ymin)) y_min <- ymin
  if (!is.null(ymax)) y_max <- ymax

  ylabs <- pretty(c(y_min, y_max), n = 5)

  x_max <- max(unlist(lapply(sig_summary, length)))
  xlabs <- c(up, 0, down)
  xticks <- c(
    0,
    as.integer(
      length(sig_summary[[1]]) /
        sum(as.numeric(xlabs[1]), as.numeric(xlabs[3])) *
        as.numeric(xlabs[1])
    ),
    length(sig_summary[[1]])
  )

  old_par <- par(no.readonly = TRUE)
  on.exit(par(old_par))

  par(mar = c(4, 4, 2, 1))
  plot(
    NA,
    xlim = c(0, x_max),
    ylim = c(min(ylabs), max(ylabs)),
    frame.plot = FALSE,
    axes = FALSE,
    xlab = NA,
    ylab = NA
  )

  abline(h = ylabs, v = pretty(xticks), col = "gray90", lty = 2)

  for (idx in seq_along(sig_summary)) {
    points(sig_summary[[idx]], type = "l", lwd = line_size, col = color[idx])
  }

  axis(side = 1, at = xticks, labels = xlabs, cex.axis = axis_fs)
  axis(side = 2, at = ylabs, las = 2, cex.axis = axis_fs)

  legend(
    x = "topright",
    legend = names(sig_summary),
    col = color,
    bty = "n",
    lty = 1,
    lwd = 1.2,
    cex = legend_fs,
    xpd = TRUE
  )

  mtext(text = xlab, side = 1, line = 2.5, cex = 1)
  mtext(text = ylab, side = 2, line = 2.5, cex = 1)

  invisible(list(
    mean_signal = sig_summary,
    color_codes = color,
    xticks      = xticks,
    xlabs       = xlabs,
    ylimits     = c(y_min, y_max)
  ))
}
