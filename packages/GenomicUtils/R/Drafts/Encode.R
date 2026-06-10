library(tidyverse)
library(httr)
library(BRGenomics)
library(GenomicRanges)

#' Import BAM file from ENCODE
#'
#' Downloads and imports a BAM file from ENCODE using its accession.
#'
#' @param accession ENCODE file accession (string)
#' @param paired_end Optional, whether the BAM is paired-end (default NULL)
#' @param ignore.strand Logical, whether to ignore strand information (default FALSE)
#' @param ncores Number of cores to use for import (default NULL)
#'
#' @return A \code{GAlignments} or \code{GRanges} object from \code{BRGenomics::import_bam}
#'
#' @export
#'
#' @examples
#' \dontrun{
#' bam <- import_encode_bam("ENCFF000ABC")
#' }
import_encode_bam <- function(accession, paired_end = NULL, ignore.strand = FALSE, ncores = NULL) {
  url <- paste0("https://www.encodeproject.org/files/", accession, "/@@download/")
  destfile <- paste0(accession, ".bam")

  httr::GET(url, httr::write_disk(destfile, overwrite = TRUE))

  bam <- dir(".", pattern = paste0("^", accession, "\\.bam$"), full.names = TRUE, ignore.case = TRUE)
  BRGenomics::import_bam(bam, paired_end = paired_end, ignore.strand = ignore.strand, ncores = ncores)
}


#' Download multiple BAM files from ENCODE
#'
#' Downloads one or more BAM files from ENCODE to a local directory.
#'
#' @param accessions Character vector of ENCODE accessions
#' @param dest_dir Destination directory for downloaded BAMs (default: current directory)
#'
#' @return Character vector of full file paths to the downloaded BAM files
#'
#' @export
#'
#' @examples
#' \dontrun{
#' files <- download_encode_bam(c("ENCFF000ABC", "ENCFF000DEF"), dest_dir = "bam_files")
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


#' Import ENCODE peak file
#'
#' Downloads and imports a peak file from ENCODE as a GRanges object.
#'
#' @param accession ENCODE peak file accession (string)
#'
#' @return A \code{GRanges} object with seqnames, start, and end columns
#'
#' @export
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


#' Retrieve ENCODE experiment table
#'
#' Fetches the main experiment table from ENCODE and selects core columns.
#'
#' @return A \code{data.frame} with selected experiment metadata
#'
#' @export
#'
#' @examples
#' \dontrun{
#' df <- encode_table()
#' }
encode_table <- function() {
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
