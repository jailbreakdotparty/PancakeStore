package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"

	"howett.net/plist"
)

func TestReadDownloadedAppInfo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.ipa")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entry, err := writer.Create("Payload/Example.app/Info.plist")
	if err != nil {
		t.Fatal(err)
	}
	data, err := plist.Marshal(map[string]interface{}{
		"CFBundleIdentifier":         "com.example.app",
		"CFBundleVersion":            "42",
		"CFBundleShortVersionString": "1.2.3",
		"CFBundleDisplayName":        "Example App",
	}, plist.XMLFormat)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	info, err := readDownloadedAppInfo(path)
	if err != nil {
		t.Fatalf("readDownloadedAppInfo returned error: %v", err)
	}
	if info.BundleIdentifier != "com.example.app" || info.BundleVersion != "42" || info.ShortVersion != "1.2.3" || info.DisplayName != "Example App" {
		t.Fatalf("unexpected metadata: %#v", info)
	}
}

func TestReadDownloadedAppInfoRejectsIPAWithoutApp(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty.ipa")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := readDownloadedAppInfo(path); err == nil {
		t.Fatal("expected missing app Info.plist error")
	}
}
