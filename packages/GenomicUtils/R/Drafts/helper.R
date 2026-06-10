library(tidyverse)
library(Rsamtools)
library(ATACseqQC)

#' Compute 2D point density
#'
#' Computes local 2D density values for x-y points using kernel density estimation.
#'
#' @param x Numeric vector of x coordinates
#' @param y Numeric vector of y coordinates
#' @param ... Additional arguments passed to \code{MASS::kde2d}, e.g., \code{n}, \code{lims}, \code{h}
#'
#' @return Numeric vector of density values corresponding to input points
#'
#' @export
#'
#' @examples
#' \dontrun{
#' set.seed(1)
#' x <- rnorm(1000)
#' y <- rnorm(1000)
#' dens <- get_density(x, y)
#' }
get_density <- function(x, y, ...) {
  dens <- MASS::kde2d(x, y, ...)
  ix <- findInterval(x, dens$x)
  iy <- findInterval(y, dens$y)
  ii <- cbind(ix, iy)
  dens$z[ii]
}


#' Find peaks in a numeric vector
#'
#' Identifies local maxima in a numeric vector using a sliding window.
#'
#' @param x Numeric vector
#' @param m Integer window size (default: 3)
#'
#' @return Integer vector of indices corresponding to local maxima
#'
#' @export
#'
#' @examples
#' \dontrun{
#' v <- c(1, 3, 2, 5, 4, 6)
#' peaks <- find_peaks(v)
#' }
find_peaks <- function(x, m = 3) {
  shape <- diff(sign(diff(x, na.pad = FALSE)))
  pks <- sapply(which(shape < 0), FUN = function(i) {
    z <- i - m + 1
    z <- ifelse(z > 0, z, 1)
    w <- i + m + 1
    w <- ifelse(w < length(x), w, length(x))
    if (all(x[c(z:i, (i + 2):w)] <= x[i + 1])) {
      return(i + 1)
    } else {
      return(numeric(0))
    }
  })
  unlist(pks)
}


#' Fragment size distribution from BAM files
#'
#' Computes fragment length distribution from paired-end BAM files.
#'
#' @param bamFiles Character vector of BAM file paths
#' @param bamFiles.labels Character vector of BAM labels
#' @param index Optional vector of BAM file indices (default: same as bamFiles)
#'
#' @return Named list of fragment length distributions
#'
#' @export
#'
#' @examples
#' \dontrun{
#' frag_len <- frag(c("sample1.bam", "sample2.bam"), c("s1", "s2"))
#' }
frag <- function(bamFiles, bamFiles.labels, index = bamFiles) {
  opar <- par(c("fig", "mar"))
  on.exit(par(opar))

  pe <- mapply(Rsamtools::testPairedEndBam, bamFiles, index)
  if (any(!pe)) stop(paste(bamFiles[!pe], collapse = ", "), " is not Paired-End file.")

  summaryFunction <- function(seqname, seqlength, bamFile, ind, ...) {
    param <- Rsamtools::ScanBamParam(
      what = c("isize"),
      which = GenomicRanges::GRanges(seqname, IRanges::IRanges(1, seqlength)),
      flag = Rsamtools::scanBamFlag(
        isSecondaryAlignment = FALSE,
        isUnmappedQuery = FALSE,
        isNotPassingQualityControls = FALSE
      )
    )
    table(abs(unlist(sapply(Rsamtools::scanBam(bamFile, index = ind, ..., param = param), `[[`, "isize"), use.names = FALSE)))
  }

  idxstats <- unique(do.call(rbind, mapply(function(.ele, .ind) {
    Rsamtools::idxstatsBam(.ele, index = .ind)[, c("seqnames", "seqlength")]
  }, bamFiles, index, SIMPLIFY = FALSE)))

  idxstats <- idxstats[idxstats[, "seqnames"] != "*", , drop = FALSE]
  seqnames <- as.character(idxstats[, "seqnames"])
  seqlen <- checkMaxChrLength(as.numeric(idxstats[, "seqlength"]))

  fragment.len <- mapply(
    function(bamFile, ind) {
      summaryFunction(seqname = seqnames, seqlength = seqlen, bamFile, ind)
    }, bamFiles, index,
    SIMPLIFY = FALSE
  )

  names(fragment.len) <- bamFiles.labels
  fragment.len
}


#' Cap chromosome lengths to maximum allowed
#'
#' Ensures that chromosome lengths do not exceed 2^29.
#'
#' @param len Numeric vector of chromosome lengths
#'
#' @return Numeric vector with lengths capped at 2^29
#'
#' @export
checkMaxChrLength <- function(len) {
  stopifnot(is.numeric(len))
  len[len > 2^29] <- 2^29
  len
}


#' Compute total mapped reads in a BAM file
#'
#' @param bamFile Path to BAM file
#'
#' @return Numeric, total number of mapped reads
#'
#' @export
totalMapped <- function(bamFile) {
  mapped <- Rsamtools::idxstatsBam(bamFile)
  sum(mapped$mapped)
}

#' Identify Outliers in a vector
#' #'
#' @importFrom rstatix identify_outliers
