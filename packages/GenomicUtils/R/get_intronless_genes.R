# file: R/get_intronless_genes.R

suppressPackageStartupMessages({
  if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
  for (p in c("GenomicFeatures","GenomicRanges","AnnotationDbi","GenomeInfoDb","methods")) {
    if (!requireNamespace(p, quietly = TRUE)) BiocManager::install(p, ask = FALSE, update = FALSE)
  }
  library(GenomicFeatures)
  library(GenomicRanges)
  library(AnnotationDbi)
  library(GenomeInfoDb)
  library(methods)
})

`%||%` <- function(a,b) if (!is.null(a)) a else b

.guess_orgdb <- function(txdb, orgdb) {
  if (!is.null(orgdb)) return(orgdb)
  org <- tryCatch(metadata(txdb)$Organism %||% metadata(txdb)$organism, error = function(...) NULL)
  if (is.null(org)) return(NULL)
  if (grepl("Homo sapiens", org, ignore.case = TRUE) && requireNamespace("org.Hs.eg.db", quietly = TRUE)) {
    return(get("org.Hs.eg.db", envir = asNamespace("org.Hs.eg.db")))
  }
  if (grepl("Mus musculus", org, ignore.case = TRUE) && requireNamespace("org.Mm.eg.db", quietly = TRUE)) {
    return(get("org.Mm.eg.db", envir = asNamespace("org.Mm.eg.db")))
  }
  NULL
}

.guess_keytype <- function(ids) {
  ids <- as.character(ids)
  if (all(grepl("^[0-9]+$", ids))) return("ENTREZID")
  if (all(grepl("^ENS(MUS)?G[0-9]+", ids, ignore.case = TRUE))) return("ENSEMBL")
  NA_character_
}

.try_map_symbols <- function(ids, orgdb, prefer_keytype = NA_character_, symbol_column = "SYMBOL") {
  if (is.null(orgdb)) return(rep(NA_character_, length(ids)))
  kt_avail <- tryCatch(keytypes(orgdb), error = function(...) character())
  col_avail <- tryCatch(columns(orgdb),  error = function(...) character())
  if (!(symbol_column %in% col_avail)) {
    fallback <- intersect(c("SYMBOL","GENENAME","ALIAS"), col_avail)
    symbol_column <- if (length(fallback)) fallback[1] else return(rep(NA_character_, length(ids)))
  }
  trial <- unique(na.omit(c(prefer_keytype, intersect(c("ENTREZID","ENSEMBL","SYMBOL","ALIAS"), kt_avail))))
  for (kt in trial) {
    res <- suppressMessages(AnnotationDbi::mapIds(orgdb,
                                                  keys = as.character(ids), keytype = kt, column = symbol_column, multiVals = "first"
    ))
    res <- unname(res[as.character(ids)])
    if (sum(!is.na(res)) > 0) return(res)
  }
  rep(NA_character_, length(ids))
}

#' Intronless genes from any TxDb (strict/lenient)
#' @param txdb TxDb object.
#' @param criterion "strict" (all transcripts single-exon) or "lenient".
#' @param keep_standard_chroms Logical.
#' @param seqstyle NULL or "UCSC"/"NCBI"/"Ensembl".
#' @param orgdb Optional OrgDb; if NULL, auto-guess for human/mouse.
#' @param id_keytype Preferred OrgDb keytype that matches TxDb GENEID; if NULL, auto-guess.
#' @param symbol_column OrgDb column to use as symbol.
#' @param single_strand_genes_only Passed to genes(); default TRUE.
#' @param quiet Suppress genes() message about dropped genes. Default TRUE.
#' @return GRanges with gene_id, symbol, n_tx, criterion.
get_intronless_genes <- function(txdb,
                                 criterion = c("strict","lenient"),
                                 keep_standard_chroms = TRUE,
                                 seqstyle = NULL,
                                 orgdb = NULL,
                                 id_keytype = NULL,
                                 symbol_column = "SYMBOL",
                                 single_strand_genes_only = TRUE,
                                 quiet = TRUE) {
  stopifnot(inherits(txdb, "TxDb"))
  criterion <- match.arg(criterion)
  
  genes_fun <- function() GenomicFeatures::genes(txdb, single.strand.genes.only = single_strand_genes_only)
  genes_gr <- if (quiet) suppressMessages(genes_fun()) else genes_fun()
  if (keep_standard_chroms) {
    genes_gr <- GenomeInfoDb::keepStandardChromosomes(genes_gr, pruning.mode = "coarse")
  }
  if (!is.null(seqstyle)) {
    try(GenomeInfoDb::seqlevelsStyle(genes_gr) <- seqstyle, silent = TRUE)
  }
  genes_gr$gene_id <- names(genes_gr)
  
  exons_by_tx <- GenomicFeatures::exonsBy(txdb, by = "tx")
  exon_counts <- lengths(exons_by_tx)
  txids <- names(exon_counts)
  
  map <- suppressMessages(AnnotationDbi::select(txdb, keys = txids, keytype = "TXID", columns = "GENEID"))
  map <- map[!is.na(map$TXID) & !is.na(map$GENEID), , drop = FALSE]
  map$TXID <- as.character(map$TXID)
  map$GENEID <- as.character(map$GENEID)
  map$exon_count <- as.integer(exon_counts[map$TXID])
  map <- map[!is.na(map$exon_count), , drop = FALSE]
  if (!nrow(map)) stop("No TXID↔GENEID mappings with exon counts; check TxDb contents.")
  
  sp <- split(map$exon_count, map$GENEID)
  min_exons <- vapply(sp, min, integer(1))
  max_exons <- vapply(sp, max, integer(1))
  n_tx      <- vapply(sp, length, integer(1))
  agg <- data.frame(GENEID = names(min_exons),
                    min_exons = unname(min_exons),
                    max_exons = unname(max_exons),
                    n_tx = unname(n_tx),
                    row.names = NULL, check.names = FALSE)
  
  keep_ids <- if (criterion == "strict") agg$GENEID[agg$max_exons == 1L] else agg$GENEID[agg$min_exons == 1L]
  keep_ids <- intersect(keep_ids, genes_gr$gene_id)
  
  gr <- genes_gr[match(keep_ids, genes_gr$gene_id)]
  gr$criterion <- criterion
  gr$n_tx <- agg$n_tx[match(gr$gene_id, agg$GENEID)]
  
  odb <- .guess_orgdb(txdb, orgdb)
  # validate orgdb class using methods::is; no AnnotationDbi::is
  if (!is.null(odb)) {
    ok <- tryCatch(methods::is(odb, "OrgDb") || methods::is(odb, "AnnotationDb"), error = function(...) FALSE)
    if (!ok) stop("`orgdb` must be an OrgDb; e.g., org.Hs.eg.db.")
  }
  pref_kt <- if (is.null(id_keytype)) .guess_keytype(gr$gene_id) else id_keytype
  gr$symbol <- .try_map_symbols(gr$gene_id, odb, prefer_keytype = pref_kt, symbol_column = symbol_column)
  
  if (!is.null(seqstyle)) {
    try(GenomeInfoDb::seqlevelsStyle(gr) <- seqstyle, silent = TRUE)
  }
  gr <- sort(gr)
  names(gr) <- ifelse(is.na(gr$symbol) | gr$symbol == "", gr$gene_id, gr$symbol)
  gr
}

# --- Example (your call) ---
# library(TxDb.Hsapiens.UCSC.hg38.knownGene); library(org.Hs.eg.db)
# intronless_genes <- get_intronless_genes(
#   txdb = TxDb.Hsapiens.UCSC.hg38.knownGene,
#   criterion = "strict",
#   keep_standard_chroms = TRUE,
#   seqstyle = "UCSC",
#   orgdb = org.Hs.eg.db,
#   id_keytype = "ENTREZID",
#   symbol_column = "SYMBOL",
#   single_strand_genes_only = TRUE,
#   quiet = TRUE
# )
# length(intronless_genes); head(intronless_genes)