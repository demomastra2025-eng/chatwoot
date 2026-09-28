package server

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"

	"github.com/chatwoot/chatwoot-media-server/internal/media"
)

func (h *Handlers) scopedRecordingManifest(r *http.Request) (media.RecordingManifest, []byte, error) {
	manifest, data, err := media.LoadRecordingManifest(h.cfg.RecordingsDir, r.PathValue("id"))
	if err != nil {
		return manifest, nil, err
	}
	if r.URL.Query().Get("account_id") == "" || r.URL.Query().Get("call_id") == "" || manifest.AccountID != r.URL.Query().Get("account_id") || manifest.CallID != r.URL.Query().Get("call_id") {
		return manifest, nil, http.ErrNoLocation
	}
	return manifest, data, nil
}

func (h *Handlers) GetRecordingManifest(w http.ResponseWriter, r *http.Request) {
	_, data, err := h.scopedRecordingManifest(r)
	if err != nil {
		writeError(w, http.StatusNotFound, "recording manifest not found")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}

func (h *Handlers) GetRecordingArtifact(w http.ResponseWriter, r *http.Request) {
	manifest, _, err := h.scopedRecordingManifest(r)
	if err != nil {
		writeError(w, http.StatusNotFound, "recording manifest not found")
		return
	}
	if manifest.State != "final" {
		writeError(w, http.StatusConflict, "recording bundle not final")
		return
	}
	for _, a := range manifest.Artifacts {
		if a.ID != r.PathValue("artifact_id") {
			continue
		}
		name, err := media.RecordingArtifactFilename(a)
		if err != nil {
			break
		}
		f, err := media.OpenRecordingBundleFile(h.cfg.RecordingsDir, manifest.SessionID, name)
		if err != nil {
			break
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil || info.Size() != a.ByteSize {
			break
		}
		digest := sha256.New()
		if _, err := io.Copy(digest, f); err != nil {
			break
		}
		if hex.EncodeToString(digest.Sum(nil)) != a.SHA256 {
			break
		}
		_, _ = f.Seek(0, 0)
		contentType := "application/vnd.onelink.rtp-capture"
		if a.Format == "legacy_side_ogg" {
			contentType = "audio/ogg"
		}
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
		http.ServeContent(w, r, name, info.ModTime(), f)
		return
	}
	writeError(w, http.StatusNotFound, "recording artifact not found")
}
