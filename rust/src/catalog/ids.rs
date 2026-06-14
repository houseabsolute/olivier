/// Lowercased, whitespace-collapsed key fragment for synthetic ids.
pub fn normalize(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub fn album_artist_key(mbid: Option<&str>, name: &str) -> String {
    match mbid {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => format!("synth:aa:{}", normalize(name)),
    }
}

pub fn release_group_key(mbid: Option<&str>, album_artist: &str, album: &str) -> String {
    match mbid {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => format!("synth:rg:{}|{}", normalize(album_artist), normalize(album)),
    }
}

pub fn release_key(mbid: Option<&str>, album_artist: &str, album: &str) -> String {
    match mbid {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => format!("synth:rel:{}|{}", normalize(album_artist), normalize(album)),
    }
}

/// Sort key: embedded Picard sort tag if present, else name with a leading
/// English article (A / An / The) stripped.
pub fn sort_name(name: &str, embedded_sort: Option<&str>) -> String {
    if let Some(s) = embedded_sort {
        if !s.is_empty() {
            return s.to_string();
        }
    }
    for art in ["A ", "An ", "The "] {
        if let Some(rest) = name.strip_prefix(art) {
            return rest.to_string();
        }
    }
    name.to_string()
}
