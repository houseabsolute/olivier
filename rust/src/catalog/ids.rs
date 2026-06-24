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

/// True iff `s` is a syntactically valid MusicBrainz UUID (8-4-4-4-12 hex).
/// Used to reject multi-value / garbage IDs before they reach a request URL.
pub fn is_mbid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_mbid_accepts_uuid_rejects_garbage() {
        assert!(is_mbid("9e414497-23b7-4ab7-9ec6-8ea9864c9e87"));
        assert!(!is_mbid(
            "9e414497-23b7-4ab7-9ec6-8ea9864c9e87\x0042faad37-8aaa-42e4-a300-5a7dae79ed24"
        ));
        assert!(!is_mbid("not-a-uuid"));
        assert!(!is_mbid(""));
        assert!(!is_mbid("9e414497-23b7-4ab7-9ec6-8ea9864c9e8")); // 35 chars
        assert!(!is_mbid("9e414497x23b7-4ab7-9ec6-8ea9864c9e87")); // wrong separator
    }
}
