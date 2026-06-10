if (rstudioapi::isAvailable())
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

source("00_config.R")
library(tximeta)
library(DESeq2)
library(ggplot2)
library(org.Mm.eg.db)

# ── DESeq2 per cell type ───────────────────────────────────────────────────────
cell_types <- unique(coldata$cell_type)

dds_list <- lapply(setNames(cell_types, cell_types), function(ct) {
  cd  <- dplyr::filter(coldata, cell_type == ct)
  se  <- tximeta::tximeta(cd)
  gse <- summarizeToGene(se)
  dds <- DESeqDataSet(gse, design = ~condition)
  DESeq(dds)
})

# ── QC plots ───────────────────────────────────────────────────────────────────
pdf(file.path(dirs$plots, "cTKO_RNAseq_QC.pdf"), width = 6, height = 5)
for (ct in names(dds_list)) {
  vst <- vst(dds_list[[ct]])
  print(plotPCA(vst, intgroup = "condition") +
    ggplot2::labs(title = ct) +
    ggplot2::theme_classic(base_size = 11))
  plotDispEsts(dds_list[[ct]], main = ct)
}
dev.off()

# ── Results: annotate, export CSV ─────────────────────────────────────────────
res_list <- lapply(names(dds_list), function(ct) {
  res <- results(dds_list[[ct]], contrast = c("condition", "cTKO", "WT"), alpha = 0.05)
  df  <- na.omit(as.data.frame(res))
  df$SYMBOL <- mapIds(
    org.Mm.eg.db,
    keys      = rownames(df),
    keytype   = "ENSEMBL",
    column    = "SYMBOL",
    multiVals = "first"
  )
  write.csv(df, file.path(dirs$data, paste0("DESeq2_", gsub(" ", "_", ct), "_cTKO_vs_WT.csv")))
  df
})
names(res_list) <- names(dds_list)

# ── Save R objects for downstream scripts ─────────────────────────────────────
saveRDS(dds_list, file.path(dirs$data, "dds_list.rds"))
saveRDS(res_list, file.path(dirs$data, "res_list.rds"))

message("Done. CSVs & RDS in ", dirs$data)
