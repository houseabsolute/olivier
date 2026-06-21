# Bundled data

`en_words.txt` is the English word list from https://github.com/atebits/Words (`Words/en.txt`),
released under the Creative Commons CC0 1.0 Universal Public Domain Dedication. It is embedded into
the binary (`include_str!`) and used by the reading-vs-translation classifier in
`src/enrich/select.rs`. No attribution is required; recorded here for provenance.
