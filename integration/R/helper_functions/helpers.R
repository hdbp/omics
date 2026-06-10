# Annotates significant ATAC regions for a single cell type and returns a
# gene-level table filtered by genomic feature:
#
#   feature = "promoter" — keeps only peaks annotated as Promoter by ChIPseeker.
#                          Provides the most direct link between chromatin
#                          accessibility and transcriptional output.
#
#   feature = "distal"   — keeps intergenic peaks within distal_kb of a TSS.
#                          Peaks must be annotated as "Distal Intergenic" by
#                          ChIPseeker (i.e. not overlapping any gene body) AND
#                          within distal_kb of the nearest TSS. Requiring
#                          intergenic status avoids peaks that overlap another
#                          gene's intron/exon, which are more likely to regulate
#                          that gene rather than the distant one.
#
# When multiple significant peaks map to the same gene, the one with the largest
# |rep.logFC| is kept (representative peak approach, consistent with csaw).
# Returns a tibble with columns: SYMBOL, atac_logFC, atac_direction, atac_fdr.
get_atac_genes <- function(ct_name, ct, fdr_thresh,
                           feature    = c("promoter", "distal"),
                           distal_kb  = 50) {

  feature <- match.arg(feature)

  com <- as_tibble(as.data.frame(ct$merged$combined))
  reg <- ct$merged$regions

  sig_idx <- which(!is.na(com$FDR) & com$FDR <= fdr_thresh)

  if (length(sig_idx) == 0L) {
    cat(ct_name, ": no significant ATAC regions\n")
    return(tibble(SYMBOL = character(), atac_logFC = numeric(),
                  atac_direction = character(), atac_fdr = numeric()))
  }

  peak_anno <- annotatePeak(reg[sig_idx], TxDb = txdb,
                            annoDb = "org.Mm.eg.db", verbose = FALSE)

  df <- as_tibble(as.data.frame(peak_anno)) %>%
    mutate(
      atac_logFC     = as.numeric(com$rep.logFC[sig_idx]),
      atac_fdr       = as.numeric(com$FDR[sig_idx]),
      atac_direction = as.character(com$direction[sig_idx])
    )

  df <- if (feature == "promoter") {
    df %>% dplyr::filter(str_detect(annotation, "Promoter"))
  } else {
    df %>% dplyr::filter(
      str_detect(annotation, "Distal Intergenic"),
      abs(distanceToTSS) <= distal_kb * 1000L
    )
  }

  cat(ct_name, sprintf(": %d significant %s peaks\n", nrow(df), feature))

  if (nrow(df) == 0L)
    return(tibble(SYMBOL = character(), atac_logFC = numeric(),
                  atac_direction = character(), atac_fdr = numeric()))

  df %>%
    dplyr::filter(!is.na(SYMBOL)) %>%
    group_by(SYMBOL) %>%
    slice_max(abs(atac_logFC), n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    dplyr::select(SYMBOL, atac_logFC, atac_direction, atac_fdr)
}


# Runs the per-cell-type ATAC × RNA integration for a given feature type.
# Joins ATAC gene-level table with RNA DESeq2 results on SYMBOL and classifies
# each gene into a concordance category.
# Returns a named list of per-cell-type tibbles (same structure as integration_list).
run_integration <- function(atac_analysis, rna_list, shared_ct,
                            atac_fdr_thresh, rna_padj_thresh, rna_lfc_thresh,
                            feature, distal_kb = 50) {

  lapply(shared_ct, function(ct_name) {

    cat("\n", strrep("-", 50), "\n", ct_name, "\n", sep = "")

    atac_genes <- get_atac_genes(ct_name, atac_analysis[[ct_name]],
                                 atac_fdr_thresh, feature, distal_kb)

    rna_df <- as_tibble(rna_list[[ct_name]], rownames = "ensembl") %>%
      dplyr::filter(!is.na(SYMBOL), !is.na(padj)) %>%
      dplyr::select(SYMBOL, rna_log2FC = log2FoldChange, rna_padj = padj)

    full_join(atac_genes, rna_df, by = "SYMBOL") %>%
      mutate(
        atac_sig = !is.na(atac_fdr)  & atac_fdr  <= atac_fdr_thresh,
        rna_sig  = !is.na(rna_padj)  & rna_padj  <= rna_padj_thresh &
                     abs(rna_log2FC) >= rna_lfc_thresh,

        concordance = case_when(
          atac_sig & rna_sig & atac_direction == "up"   & rna_log2FC > 0 ~ "Concordant activation",
          atac_sig & rna_sig & atac_direction == "down" & rna_log2FC < 0 ~ "Concordant repression",
          atac_sig & rna_sig                                              ~ "Discordant",
          atac_sig & !rna_sig                                             ~ "ATAC only",
          !atac_sig & rna_sig                                             ~ "RNA only",
          TRUE                                                            ~ "Neither"
        ),
        cell_type = ct_name
      )
  }) %>% set_names(shared_ct)
}
