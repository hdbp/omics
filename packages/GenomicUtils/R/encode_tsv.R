# file: R/download_encode_tsv.R

#' Download and read a tabular ENCODE file by accession
#'
#' Downloads from
#' \verb{https://www.encodeproject.org/files/<accession>/@@download/}
#' into \code{dest_dir} (keeping the server-provided filename when available,
#' e.g. \verb{*.tsv.gz} or \verb{*.bed.gz}), then reads it as a tabular table.
#'
#' @param accession Character scalar ENCODE file accession, e.g. `"ENCFF000ABC"`.
#' @param dest_dir Directory to save the downloaded file. Created if missing. Default `"."`.
#' @param overwrite Logical; overwrite an existing file of the same name? Default `FALSE`.
#' @param col_names Passed to \code{readr::read_delim()}; set `TRUE` if the file has a header row.
#'   Default `FALSE` because many ENCODE files (e.g., BED) lack headers.
#' @param delim Field delimiter. Default `"\t"` (tab).
#' @param guess_max Max rows to guess column types; forwarded to readr. Default `1000`.
#' @param ... Extra arguments forwarded to \code{readr::read_delim()} (e.g., \code{col_types}, \code{comment}).
#'
#' @return A tibble (data frame) with the parsed contents.
#'
#' @details
#' Gzip is detected via the file extension (if provided by the server) or by magic bytes.
#' \code{readr} can read \code{*.gz} paths directly; no manual connection needed.
#'
#' @examples
#' \dontrun{
#' # Save under ./data and parse as headerless TSV:
#' df <- download_encode_tsv("ENCFF000ABC", dest_dir = "data", col_names = FALSE)
#'
#' # If your file has a header row:
#' df <- download_encode_tsv("ENCFF000XYZ", col_names = TRUE)
#'
#' # With explicit col_types and skipping commented lines:
#' df <- download_encode_tsv("ENCFF000XYZ", col_names = TRUE, col_types = readr::cols(), comment = "#")
#' }
#'
#' @seealso \url{https://www.encodeproject.org/help/rest-api/}
#'
#' @export
#' @importFrom httr GET write_disk stop_for_status headers timeout
#' @importFrom readr read_delim
download_encode_tsv <- function(accession,
                                dest_dir = ".",
                                overwrite = FALSE,
                                col_names = FALSE,
                                delim = "\t",
                                guess_max = 1000,
                                ...) {
  stopifnot(is.character(accession), length(accession) == 1L, nzchar(accession))
  stopifnot(is.character(dest_dir), length(dest_dir) == 1L, nzchar(dest_dir))
  stopifnot(is.logical(overwrite), length(overwrite) == 1L)
  
  url <- paste0("https://www.encodeproject.org/files/", accession, "/@@download/")
  
  if (!dir.exists(dest_dir)) dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  
  tmp <- tempfile(fileext = ".bin")
  resp <- httr::GET(url, httr::write_disk(tmp, overwrite = TRUE), httr::timeout(120))
  httr::stop_for_status(resp)
  
  # Derive filename from Content-Disposition if present
  cd <- httr::headers(resp)[["content-disposition"]]
  fname <- NULL
  if (!is.null(cd)) {
    m <- regmatches(cd, regexec('filename="?([^";]+)"?', cd))[[1]]
    if (length(m) >= 2L && nzchar(m[2])) fname <- m[2]
  }
  # Fallback filename if server didn't send one
  if (is.null(fname)) {
    # Try to infer gzip by magic header
    is_gz <- .is_gzip(tmp)
    fname <- paste0(accession, if (is_gz) ".tsv.gz" else ".tsv")
  }
  
  final_path <- file.path(dest_dir, fname)
  
  if (file.exists(final_path) && !isTRUE(overwrite)) {
    stop(sprintf("File already exists and overwrite=FALSE: %s", final_path), call. = FALSE)
  }
  
  # Move temp → final (fallback to copy if cross-device)
  ok <- tryCatch(file.rename(tmp, final_path),
                 warning = function(w) FALSE, error = function(e) FALSE)
  if (!ok) {
    file.copy(tmp, final_path, overwrite = TRUE)
    unlink(tmp)
  }
  
  # Parse with readr (handles .gz seamlessly)
  readr::read_delim(
    file = final_path,
    delim = delim,
    col_names = col_names,
    guess_max = guess_max,
    progress = interactive(),
    ...
  )
}

# ---- internal helper ----
.is_gzip <- function(path) {
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  sig <- readBin(con, what = "raw", n = 2L)
  length(sig) == 2L && identical(as.integer(sig), c(0x1f, 0x8b))
}