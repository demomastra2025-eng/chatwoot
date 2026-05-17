package config

import "testing"

func TestLoadRequiresAuthTokenAndCallbackURL(t *testing.T) {
	t.Setenv("MEDIA_SERVER_AUTH_TOKEN", "")
	t.Setenv("AUTH_TOKEN", "")
	t.Setenv("RAILS_CALLBACK_URL", "http://rails:3000")

	if _, err := Load(); err == nil {
		t.Fatal("expected missing auth token to fail config load")
	}

	t.Setenv("MEDIA_SERVER_AUTH_TOKEN", "secret")
	t.Setenv("RAILS_CALLBACK_URL", "")
	if _, err := Load(); err == nil {
		t.Fatal("expected missing Rails callback URL to fail config load")
	}
}

func TestLoadDefaultsToAllInterfacesForHTTPBindAddress(t *testing.T) {
	t.Setenv("MEDIA_SERVER_AUTH_TOKEN", "secret")
	t.Setenv("RAILS_CALLBACK_URL", "http://rails:3000")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("expected config to load: %v", err)
	}
	if cfg.HTTPBindAddress != "" {
		t.Fatalf("expected empty HTTP bind address by default, got %q", cfg.HTTPBindAddress)
	}
}

func TestLoadSupportsMediaServerPrefixedSettings(t *testing.T) {
	t.Setenv("MEDIA_SERVER_AUTH_TOKEN", "secret")
	t.Setenv("AUTH_TOKEN", "legacy")
	t.Setenv("RAILS_CALLBACK_URL", "http://rails:3000/")
	t.Setenv("HTTP_BIND_ADDRESS", "127.0.0.1")
	t.Setenv("MEDIA_SERVER_AUDIO_DIR", "/safe-audio")
	t.Setenv("MEDIA_SERVER_CALLBACK_TIMEOUT", "3")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("expected config to load: %v", err)
	}
	if cfg.AuthToken != "secret" {
		t.Fatalf("expected MEDIA_SERVER_AUTH_TOKEN to win, got %q", cfg.AuthToken)
	}
	if cfg.RailsCallbackURL != "http://rails:3000" {
		t.Fatalf("expected trimmed callback URL, got %q", cfg.RailsCallbackURL)
	}
	if cfg.HTTPBindAddress != "127.0.0.1" {
		t.Fatalf("expected HTTP bind address, got %q", cfg.HTTPBindAddress)
	}
	if cfg.AudioDir != "/safe-audio" {
		t.Fatalf("expected prefixed audio dir, got %q", cfg.AudioDir)
	}
	if cfg.CallbackTimeout.Seconds() != 3 {
		t.Fatalf("expected callback timeout 3s, got %s", cfg.CallbackTimeout)
	}
}
