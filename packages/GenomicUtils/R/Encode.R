#' Import a BAM file from ENCODE
#'
#' Downloads and imports a BAM file directly from the ENCODE Project given its file accession.
#'
#' @param accession Character; ENCODE file accession (e.g., "ENCFF000ABC").
#' @param paired_end Logical; whether the BAM is paired-end (default: NULL, auto-detected).
#' @param ignore.strand Logical; whether to ignore strand information (default: FALSE).
#' @param ncores Integer; number of cores to use for import (default: NULL).
#'
#' @return A \code{GAlignments} or \code{GRanges} object imported with \code{BRGenomics::import_bam()}.
#' @export
#'
#' @importFrom httr GET write_disk
#' @importFrom BRGenomics import_bam
#'
#' @examples
#' \dontrun{
#' bam <- import_encode_bam("ENCFF000ABC")
#' }
import_encode_bam <- function(accession, paired_end = NULL,
                              ignore.strand = FALSE, ncores = NULL) {
  url <- paste0("https://www.encodeproject.org/files/", accession, "/@@download/")
  destfile <- paste0(accession, ".bam")

  httr::GET(url, httr::write_disk(destfile, overwrite = TRUE))

  bam <- dir(".",
    pattern = paste0("^", accession, "\\.bam$"),
    full.names = TRUE, ignore.case = TRUE
  )
  BRGenomics::import_bam(
    bam,
    paired_end = paired_end,
    ignore.strand = ignore.strand,
    ncores = ncores
  )
}

#' Download multiple BAM files from ENCODE
#'
#' Downloads one or more BAM files by accession directly from the ENCODE Project portal.
#'
#' @param accessions Character vector of ENCODE file accessions.
#' @param dest_dir Destination directory for the downloaded BAMs (default: current directory).
#'
#' @return Character vector of normalized file paths to downloaded BAM files.
#' @export
#'
#' @importFrom httr GET write_disk
#'
#' @examples
#' \dontrun{
#' files <- download_encode_bam(
#'   c("ENCFF000ABC", "ENCFF000DEF"),
#'   dest_dir = "bam_files"
#' )
#' }
download_encode_bam <- function(accessions, dest_dir = ".") {
  if (!dir.exists(dest_dir)) dir.create(dest_dir, recursive = TRUE)

  base_url <- "https://www.encodeproject.org/"
  downloaded_files <- character(length(accessions))

  for (i in seq_along(accessions)) {
    accession <- accessions[i]
    destfile <- file.path(dest_dir, paste0(accession, ".bam"))

    if (file.exists(destfile)) {
      message("File already exists: ", destfile, " – skipping download.")
    } else {
      url <- paste0(base_url, "files/", accession, "/@@download/")
      message("Downloading ", accession, " to ", destfile, " ...")
      httr::GET(url, httr::write_disk(destfile, overwrite = TRUE))
    }

    downloaded_files[i] <- normalizePath(destfile)
  }

  downloaded_files
}

#' Import ENCODE peak file as GRanges
#'
#' Downloads a BED/peak file from ENCODE and imports it as a \code{GRanges} object.
#'
#' @param accession Character; ENCODE peak file accession (e.g., "ENCFF000XYZ").
#'
#' @return A \code{GRanges} object containing genomic coordinates (seqnames, start, end).
#' @export
#'
#' @importFrom httr GET write_disk
#' @importFrom GenomicRanges GRanges
#' @importFrom dplyr rename
#'
#' @examples
#' \dontrun{
#' peaks <- encode_peaks("ENCFF000XYZ")
#' }
encode_peaks <- function(accession) {
  url <- paste0("https://www.encodeproject.org/files/", accession, "/@@download/")
  destfile <- paste0(accession, ".gz")

  httr::GET(url, httr::write_disk(destfile, overwrite = TRUE))

  con <- gzfile(destfile, "r")
  data <- read.delim(con, header = FALSE)
  close(con)

  data %>%
    dplyr::rename(seqnames = V1, start = V2, end = V3) %>%
    GenomicRanges::GRanges()
}

#' Retrieve ENCODE experiment metadata table
#'
#' Fetches the main ENCODE experiment metadata table via \pkg{ENCODExplorer}.
#'
#' @return A \code{data.frame} containing key experiment metadata fields:
#'   accession, file_accession, file_type, target, assay, biosample_name, organism, assembly, etc.
#' @export
#'
#' @examples
#' \dontrun{
#' df <- encode_table()
#' head(df)
#' }
encode_table <- function() {
  if (!requireNamespace("ENCODExplorer", quietly = TRUE))
    stop("Package 'ENCODExplorer' is required. Install with: BiocManager::install('ENCODExplorer')")
  ENCODExplorer::get_encode_df() %>%
    dplyr::select(
      accession,
      file_accession,
      file_type,
      output_type,
      target,
      assay,
      biosample_name,
      organism,
      assembly,
      controls,
      biological_replicates,
      file_format_type
    )
}
