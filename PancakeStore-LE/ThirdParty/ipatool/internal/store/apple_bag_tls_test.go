package store

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDialTLSWithIPFallbackRetriesSecondAddressAfterStalledHandshake(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer server.Close()

	host, portText, err := net.SplitHostPort(strings.TrimPrefix(server.URL, "https://"))
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}

	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())

	lookup := func(context.Context, string) ([]net.IPAddr, error) {
		return []net.IPAddr{
			{IP: net.ParseIP("127.0.0.2")}, // TCP accepts, but the peer never sends a TLS ServerHello.
			{IP: net.ParseIP(host)},
		}, nil
	}

	var attempts int
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		attempts++
		if strings.HasPrefix(address, "127.0.0.2:") {
			client, peer := net.Pipe()
			go func() {
				defer peer.Close()
				_, _ = io.Copy(io.Discard, peer)
			}()
			return client, nil
		}
		if !strings.HasSuffix(address, ":"+strconv.Itoa(port)) {
			return nil, fmt.Errorf("unexpected test address %q", address)
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", server.Listener.Addr().String())
	}

	connection, err := dialTLSWithIPFallback(
		context.Background(),
		"tcp",
		net.JoinHostPort("init.itunes.apple.com", portText),
		&tls.Config{RootCAs: roots, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS12},
		true,
		lookup,
		dial,
		30*time.Millisecond,
	)
	if err != nil {
		t.Fatalf("expected second IP to complete TLS handshake: %v", err)
	}
	defer connection.Close()

	tlsConnection, ok := connection.(*tls.Conn)
	if !ok {
		t.Fatalf("expected *tls.Conn, got %T", connection)
	}
	if !tlsConnection.ConnectionState().HandshakeComplete {
		t.Fatal("TLS handshake was not completed")
	}
	if attempts != 2 {
		t.Fatalf("expected 2 IP attempts, got %d", attempts)
	}
}

func TestIsAppleBagRequestRequiresExactHostAndPath(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want bool
	}{
		{name: "valid", url: "https://init.itunes.apple.com/bag.xml?ix=6", want: true},
		{name: "wrong host", url: "https://init.itunes.apple.com.example/bag.xml", want: false},
		{name: "wrong path", url: "https://init.itunes.apple.com/other", want: false},
		{name: "http", url: "http://init.itunes.apple.com/bag.xml", want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request, err := http.NewRequest(http.MethodGet, test.url, nil)
			if err != nil {
				t.Fatal(err)
			}
			if got := isAppleBagRequest(request); got != test.want {
				t.Fatalf("isAppleBagRequest() = %t, want %t", got, test.want)
			}
		})
	}
}

func TestAppleBagTransportIsClonedAndHasCustomDialer(t *testing.T) {
	base := &http.Transport{TLSHandshakeTimeout: 45 * time.Second, ForceAttemptHTTP2: true}
	custom := appleBagTransport(base)
	if custom == base {
		t.Fatal("expected an isolated transport clone")
	}
	if custom.DialTLSContext == nil {
		t.Fatal("expected the Apple bag transport to install its TLS fallback dialer")
	}
	if base.DialTLSContext != nil {
		t.Fatal("the shared base transport must remain unchanged")
	}
}

func TestAppleBagTransportRetainsHTTP2AndCertificateVerification(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()

	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.TLSClientConfig = &tls.Config{RootCAs: roots}
	base.ForceAttemptHTTP2 = true
	transport := appleBagTransport(base)
	defer transport.CloseIdleConnections()

	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatalf("request through Apple bag TLS transport failed: %v", err)
	}
	defer response.Body.Close()
	if response.ProtoMajor != 2 {
		t.Fatalf("expected HTTP/2 negotiation, got %s", response.Proto)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "ok" {
		t.Fatalf("unexpected response body %q", body)
	}
}
