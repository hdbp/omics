#' Fix BAM seqlevels and seqlengths using a genome reference
#'
#' This function reads an input BAM file, updates the sequence lengths
#' in the alignment object to match those in a provided reference genome,
#' and writes a new BAM file with corrected header information.
#'
#' @param bam_in Character scalar. Path to the input BAM file.
#' @param bam_out Character scalar. Path to the output BAM file to be written.
#' @param genome An object with valid sequence lengths, typically a
#'   \code{BSgenome} or other object for which \code{GenomeInfoDb::seqlengths()}
#'   is defined.
#'
#' @return Invisibly returns the path to the output BAM file.
#' @examples
#' \dontrun{
#' fix_bam_seqlengths(
#'   bam_in  = "input.bam",
#'   bam_out = "output.fixed.bam",
#'   genome  = BSgenome.Hsapiens.UCSC.hg38
#' )
#' }
#'
#' @importFrom GenomeInfoDb seqlengths seqlevels
#' @importFrom GenomicAlignments readGAlignments
#' @importFrom GenomicRanges granges
#' @importFrom rtracklayer export
#' @export
fix_bam_seqlengths <- function(bam_in, bam_out, genome) {
  if (!file.exists(bam_in)) {
    stop("Input BAM does not exist: ", bam_in)
  }

  aln <- GenomicAlignments::readGAlignments(bam_in, use.names = TRUE)
  gr <- GenomicRanges::granges(aln)

  # Correct lengths from the reference genome
  correct_lengths <- GenomeInfoDb::seqlengths(genome)

  # Restrict to common seqlevels
  common <- intersect(GenomeInfoDb::seqlevels(gr), names(correct_lengths))
  if (length(common) == 0L) {
    stop("No overlapping seqlevels between BAM and genome object.")
  }

  GenomeInfoDb::seqlengths(gr)[common] <- correct_lengths[common]

  # Rebuild alignment object by updating seqlengths via seqinfo
  GenomeInfoDb::seqlengths(aln) <- GenomeInfoDb::seqlengths(gr)

  # Ensure output directory exists
  bam_out <- path.expand(bam_out)
  out_dir <- dirname(bam_out)
  if (!dir.exists(out_dir)) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  }

  rtracklayer::export(aln, con = bam_out, format = "BAM")

  invisible(bam_out)
}
