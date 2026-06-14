#!/usr/bin/env python3
"""Stamp Picard-equivalent MusicBrainz tags onto the fixture audio files."""
from pathlib import Path
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TPE2, TRCK, TPOS, TDOR, TDRC, TXXX, UFID
from mutagen.flac import FLAC
from mutagen.oggvorbis import OggVorbis
from mutagen.oggopus import OggOpus
from mutagen.mp4 import MP4

F = Path("rust/tests/fixtures")

REC  = "aaaaaaaa-0000-0000-0000-000000000001"  # recording MBID
ALB  = "bbbbbbbb-0000-0000-0000-000000000001"  # release/album MBID
RG   = "cccccccc-0000-0000-0000-000000000001"  # release-group MBID
ART  = "dddddddd-0000-0000-0000-000000000001"  # artist MBID
AART = "dddddddd-0000-0000-0000-000000000001"  # album-artist MBID
RTRK = "eeeeeeee-0000-0000-0000-000000000001"  # release-track MBID

TITLE, ARTIST, ALBUM = "正しい街", "椎名林檎", "無罪モラトリアム"
ORIG, REISSUE = "1999-02-24", "2008-11-28"

def tag_id3(path):
    t = ID3()
    t.add(TIT2(encoding=3, text=TITLE)); t.add(TPE1(encoding=3, text=ARTIST))
    t.add(TALB(encoding=3, text=ALBUM));  t.add(TPE2(encoding=3, text=ARTIST))
    t.add(TRCK(encoding=3, text="1/10")); t.add(TPOS(encoding=3, text="1/1"))
    t.add(TDOR(encoding=3, text=ORIG));   t.add(TDRC(encoding=3, text=REISSUE))
    t.add(UFID(owner="http://musicbrainz.org", data=REC.encode()))
    for desc, val in [("MusicBrainz Album Id", ALB),
                      ("MusicBrainz Release Group Id", RG),
                      ("MusicBrainz Artist Id", ART),
                      ("MusicBrainz Album Artist Id", AART),
                      ("MusicBrainz Release Track Id", RTRK)]:
        t.add(TXXX(encoding=3, desc=desc, text=val))
    t.save(path)

def tag_vorbis(obj):
    obj["TITLE"]=TITLE; obj["ARTIST"]=ARTIST; obj["ALBUM"]=ALBUM; obj["ALBUMARTIST"]=ARTIST
    obj["TRACKNUMBER"]="1"; obj["TRACKTOTAL"]="10"; obj["DISCNUMBER"]="1"; obj["DISCTOTAL"]="1"
    obj["ORIGINALDATE"]=ORIG; obj["DATE"]=REISSUE
    obj["MUSICBRAINZ_TRACKID"]=REC; obj["MUSICBRAINZ_ALBUMID"]=ALB
    obj["MUSICBRAINZ_RELEASEGROUPID"]=RG; obj["MUSICBRAINZ_ARTISTID"]=ART
    obj["MUSICBRAINZ_ALBUMARTISTID"]=AART; obj["MUSICBRAINZ_RELEASETRACKID"]=RTRK
    obj.save()

def tag_mp4(path):
    m = MP4(path)
    m["\xa9nam"]=[TITLE]; m["\xa9ART"]=[ARTIST]; m["\xa9alb"]=[ALBUM]; m["aART"]=[ARTIST]
    m["trkn"]=[(1,10)]; m["disk"]=[(1,1)]; m["\xa9day"]=[REISSUE]
    def ff(name, val): m[f"----:com.apple.iTunes:{name}"]=[val.encode()]
    ff("MusicBrainz Track Id", REC); ff("MusicBrainz Album Id", ALB)
    ff("MusicBrainz Release Group Id", RG); ff("MusicBrainz Artist Id", ART)
    ff("MusicBrainz Album Artist Id", AART); ff("MusicBrainz Release Track Id", RTRK)
    # NB: Picard writes NO original-date atom for MP4/ALAC, so we don't either —
    # original year for these formats comes from MusicBrainz enrichment (Phase 2).
    m.save()

tag_id3(F/"sample.mp3")
tag_vorbis(FLAC(F/"sample.flac"))
tag_vorbis(OggVorbis(F/"sample.ogg"))
tag_vorbis(OggOpus(F/"sample.opus"))
tag_mp4(F/"sample.m4a")
tag_mp4(F/"sample.alac.m4a")
print("tagged 6 fixtures")
