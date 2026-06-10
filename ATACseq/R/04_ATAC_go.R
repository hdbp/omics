if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(ChIPseeker)
library(TxDb.Mmusculus.UCSC.mm9.knownGene)
library(org.Mm.eg.db)
library(clusterProfiler)

cat("\n=== GO BP enrichment: increased-accessibility promoters ===\n")

analysis <- readRDS(file.path(dirs$data, "csaw_atac_analysis_results.rds"))

txdb    <- TxDb.Mmusculus.UCSC.mm9.knownGene
anno_db <- "org.Mm.eg.db"

# ============================================================================
# Per-cell-type GO BP enrichment
#
# Foreground: Entrez IDs of genes whose promoters overlap increased peaks.
# Universe:   Entrez IDs annotated to any merged peak in that cell type,
#             giving a chromatin-accessible background rather than the whole genome.
# ============================================================================

go_bp_results <- map(names(analysis), function(ct_name) {

  ct  <- analysis[[ct_name]]
  sel <- .select_increased(ct)

  regions_all <- ct$merged$regions
  regions_sel <- regions_all[sel$idx]

  peak_anno_sel <- annotatePeak(regions_sel, TxDb = txdb,
                                annoDb = anno_db, verbose = FALSE)
  anno_sel <- as_tibble(as.data.frame(peak_anno_sel))

  fg_ids <- anno_sel %>%
    filter(str_detect(annotation, "Promoter")) %>%
    pull(geneId) %>%
    as.character() %>%
    discard(~is.na(.x) | .x == "") %>%
    unique()

  cat(ct_name, ": promoter genes (foreground) =", length(fg_ids), "\n")
  if (length(fg_ids) < 10) {
    cat(ct_name, ": too few genes, skipping\n")
    return(NULL)
  }

  peak_anno_all <- annotatePeak(regions_all, TxDb = txdb,
                                annoDb = anno_db, verbose = FALSE)
  universe_ids  <- as_tibble(as.data.frame(peak_anno_all)) %>%
    pull(geneId) %>%
    as.character() %>%
    discard(~is.na(.x) | .x == "") %>%
    unique()

  ego <- enrichGO(
    gene          = fg_ids,
    universe      = universe_ids,
    OrgDb         = org.Mm.eg.db,
    keyType       = "ENTREZID",
    ont           = "BP",
    pAdjustMethod = "BH",
    pvalueCutoff  = 0.05,
    qvalueCutoff  = 0.2,
    readable      = TRUE
  )

  n_sig <- sum(ego@result$p.adjust < 0.05, na.rm = TRUE)
  cat(ct_name, ": significant GO BP terms =", n_sig, "\n")

  if (n_sig > 0)
    write_csv(as_tibble(ego@result),
              file.path(dirs$go, paste0("atac_go_bp_promoters_", ct_name, ".csv")))
  ego

}) %>% set_names(names(analysis))

# ============================================================================
# Dotplots — one page per cell type with significant results
# ============================================================================

go_bp_valid <- keep(go_bp_results,
                    ~!is.null(.x) && any(.x@result$p.adjust < 0.05, na.rm = TRUE))

if (length(go_bp_valid) > 0) {

  pdf(file.path(dirs$go, "atac_go_bp_promoters.pdf"), width = 10, height = 7)

  walk(names(go_bp_valid), function(ct_name) {
    p <- dotplot(go_bp_valid[[ct_name]], showCategory = 20, font.size = 9) +
      labs(
        title    = paste(ct_name, "— GO BP: increased-accessibility promoters"),
        subtitle = "cTKO vs WT; BH-corrected; universe = all peaks in cell type"
      ) +
      theme(plot.title    = element_text(face = "bold"),
            plot.subtitle = element_text(size = 9, colour = "grey40"))
    print(p)
  })

  dev.off()

} else {
  cat("No cell type had significant GO BP terms.\n")
}

cat("\n=== 04_go.R complete ===\n")
cat("Output: ../../results/ATACseq/go/\n")
