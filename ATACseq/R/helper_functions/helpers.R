# Selects significantly increased-accessibility peaks from a csaw merged result.
# Returns FDR <= 0.05 & direction == "up" if any exist; otherwise falls back to
# the top-n windows by p-value so downstream annotation steps always have input.
# Returns a list with $idx (integer indices into merged$regions) and $label
# (character string describing the selection criterion used).
.select_increased <- function(ct, top_n = 500L) {
  com   <- ct$merged$combined
  is_up <- !is.na(com$FDR) & com$FDR <= 0.05 & com$direction == "up"
  if (any(is_up)) {
    list(idx = which(is_up), label = "FDR <= 0.05, direction = up")
  } else {
    idx <- order(com$PValue)[seq_len(min(top_n, nrow(com)))]
    list(idx = idx, label = paste0("top ", length(idx), " by p-value (no FDR sig.)"))
  }
}
