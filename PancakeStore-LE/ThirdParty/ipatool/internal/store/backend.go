// Package store provides the portable, framework-backed App Store request engine.
package store

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"strings"
	"sync"
	"time"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/store/emulator"
	"github.com/majd/ipatool/v2/internal/store/profile"
	apphttp "github.com/majd/ipatool/v2/pkg/http"
)

type Backend struct {
	jar           http.CookieJar
	macAddress    func() (string, error)
	mu            sync.Mutex
	image         []byte
	bag           map[string]any
	transport     *http.Transport
	authTransport *http.Transport
	bagTransport  *http.Transport
}

type executor struct {
	backend   *Backend
	operation string
}

func New(jar http.CookieJar, macAddress func() (string, error)) *Backend {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// Apple's Store endpoints can take longer to complete TLS negotiation on
	// some iOS network paths. Go's default TLSHandshakeTimeout is only 10s;
	// keep it below the overall login request deadline but allow a slow handshake.
	transport.TLSHandshakeTimeout = 45 * time.Second
	transport.ResponseHeaderTimeout = 30 * time.Second
	transport.IdleConnTimeout = 90 * time.Second
	authTransport := transport.Clone()
	authTransport.DisableKeepAlives = true
	bagTransport := appleBagTransport(authTransport)

	return &Backend{jar: jar, macAddress: macAddress, transport: transport, authTransport: authTransport, bagTransport: bagTransport}
}

// Client shares session cookies and bag data while isolating each guest VM.
func (b *Backend) Client(operation string) apphttp.Executor {
	return &executor{backend: b, operation: operation}
}

func (e *executor) Send(request apphttp.Request, body []byte) (*http.Response, error) {
	ctx := request.Context
	if ctx == nil {
		ctx = context.Background()
	}
	// The Store emulator executes Apple framework code before it reaches the
	// HTTP transport. Applying the timeout only to http.Client leaves Unicorn
	// execution unbounded and can make the embedded login appear frozen.
	//
	// The bag-direct path is different: it returns a live *http.Response to
	// pkg/http.client, which reads and closes the response body only after this
	// method returns. A context canceled by this method's defer would therefore
	// abort a valid response while its body is being read. For bag-direct,
	// requestTransport's http.Client.Timeout owns the full request+body lifetime.
	if request.Timeout > 0 && e.operation != "bag-direct" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, request.Timeout)
		defer cancel()
	}

	if e.operation == "bag-direct" {
		direct, err := http.NewRequestWithContext(ctx, request.Method, request.URL, bytes.NewReader(body))
		if err != nil {
			return nil, fmt.Errorf("create Store request: %w", err)
		}

		for key, value := range request.Headers {
			direct.Header.Set(key, value)
		}

		if direct.Header.Get("User-Agent") == "" {
			direct.Header.Set("User-Agent", apphttp.DefaultUserAgent)
		}

		return e.backend.requestTransport(emulator.Request{Operation: "authenticate", Timeout: request.Timeout})(direct)
	}

	input := emulator.Request{URL: request.URL, Method: request.Method, Operation: e.operation, Format: string(request.ResponseFormat), Timeout: request.Timeout, Body: body, Headers: make(http.Header), NoRedirects: request.NoRedirects, Raw: request.ResponseFormat == apphttp.ResponseFormatRaw}
	for key, value := range request.Headers {
		input.Headers.Set(key, value)
	}

	if payload, ok := request.Payload.(*apphttp.XMLPayload); ok {
		input.Parameters = payload.Content
		if input.Parameters == nil {
			input.Parameters = map[string]any{}
		}
	}

	if request.ActionSigner != nil {
		input.Sign = request.ActionSigner.Sign
	}

	return e.backend.execute(ctx, input)
}

func (e *executor) Do(request *http.Request) (*http.Response, error) {
	if request == nil {
		return nil, errors.New("store request is nil")
	}

	if e.operation == "sap" {
		return e.backend.requestTransport(emulator.Request{Operation: "authenticate"})(request)
	}

	var body []byte

	var err error
	if request.Body != nil {
		body, err = io.ReadAll(io.LimitReader(request.Body, (1<<20)+1))
		_ = request.Body.Close()

		if err != nil {
			return nil, fmt.Errorf("read Store request: %w", err)
		}

		if len(body) > 1<<20 {
			return nil, errors.New("store request body exceeds limit")
		}
	}

	return e.backend.execute(request.Context(), emulator.Request{URL: request.URL.String(), Method: request.Method, Headers: request.Header.Clone(), Body: body, Operation: e.operation, Stream: e.operation == "transfer"})
}

func (b *Backend) hardware(parameters map[string]any) ([]byte, error) {
	if value, ok := parameters["guid"].(string); ok {
		data, err := hex.DecodeString(value)
		if err != nil || len(data) != 6 {
			return nil, errors.New("invalid Store hardware identity")
		}

		return data, nil
	}

	if b.macAddress == nil {
		return nil, errors.New("store machine identity is not configured")
	}

	value, err := b.macAddress()
	if err != nil {
		return nil, fmt.Errorf("get Store machine identity: %w", err)
	}

	data, err := net.ParseMAC(value)
	if err != nil || len(data) != 6 {
		return nil, errors.New("invalid Store machine address")
	}

	return data, nil
}

func (b *Backend) prepare(ctx context.Context) ([]byte, profile.Data, error) {
	prepared, err := profile.Load(ctx)
	if err != nil {
		return nil, profile.Data{}, fmt.Errorf("load Store runtime: %w", err)
	}

	b.mu.Lock()
	defer b.mu.Unlock()

	if b.image == nil {
		bundle, err := assets.Load(ctx)
		if err != nil {
			return nil, profile.Data{}, fmt.Errorf("load Store runtime: %w", err)
		}

		b.image = bundle.AppleMediaServices
	}

	return b.image, prepared, nil
}

func (b *Backend) execute(ctx context.Context, input emulator.Request) (*http.Response, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("store request: %w", err)
	}

	hardware, err := b.hardware(input.Parameters)
	if err != nil {
		return nil, fmt.Errorf("store request: %w", err)
	}

	input.HardwareID = hardware
	if input.Headers == nil {
		input.Headers = make(http.Header)
	}

	if input.Headers.Get("User-Agent") == "" {
		input.Headers.Set("User-Agent", apphttp.DefaultUserAgent)

		if input.Operation == "purchase" {
			input.Headers.Set("User-Agent", "Configurator/2.18 (Macintosh; OS X 15.3.2; 24D81) AppleWebKit/0620.2.4.11.6")
		}
	}

	b.mu.Lock()
	bag := b.bag
	b.mu.Unlock()

	if input.Operation == "purchase" && bag == nil {
		response, err := b.execute(ctx, emulator.Request{URL: "https://init.itunes.apple.com/bag.xml?guid=" + strings.ToUpper(hex.EncodeToString(hardware)), Method: http.MethodGet, Operation: "bag"})
		if err != nil {
			return nil, fmt.Errorf("load purchase bag: %w", err)
		}

		_ = response.Body.Close()

		b.mu.Lock()
		bag = b.bag
		b.mu.Unlock()
	}

	input.Bag = bag

	fmt.Printf("[ipatool/store] preparing runtime for operation %s\n", input.Operation)
	image, prepared, err := b.prepare(ctx)
	if err != nil {
		return nil, fmt.Errorf("prepare Store framework: %w", err)
	}

	fmt.Printf("[ipatool/store] opening AppleMediaServices runtime for %s\n", input.Operation)
	guest, err := emulator.Open(ctx, image, prepared)
	if err != nil {
		return nil, fmt.Errorf("open Store framework: %w", err)
	}

	defer guest.Close()

	fmt.Printf("[ipatool/store] runtime ready; executing %s request\n", input.Operation)
	input.Transport = b.requestTransport(input)

	response, err := guest.Execute(input)
	fmt.Printf("[ipatool/store] %s request execution returned\n", input.Operation)
	if err != nil {
		return nil, fmt.Errorf("store request: %w", err)
	}

	if input.Stream {
		return response, nil
	}

	if strings.EqualFold(response.Header.Get("Content-Encoding"), "gzip") {
		reader, e := gzip.NewReader(response.Body)
		if e != nil {
			_ = response.Body.Close()

			return nil, errors.New("invalid compressed Store response")
		}

		data, e := io.ReadAll(io.LimitReader(reader, (32<<20)+1))
		_ = reader.Close()
		_ = response.Body.Close()

		if e != nil {
			return nil, fmt.Errorf("read compressed Store response: %w", e)
		}

		if len(data) > 32<<20 {
			return nil, errors.New("store response exceeds size limit")
		}

		response.Body = io.NopCloser(bytes.NewReader(data))
		response.Header.Del("Content-Encoding")
		response.Header.Del("Content-Length")
		response.ContentLength = int64(len(data))
	}

	if strings.Contains(input.URL, "init.itunes.apple.com/bag.xml") && response.StatusCode == http.StatusOK {
		data, e := io.ReadAll(response.Body)
		_ = response.Body.Close()

		if e != nil {
			return nil, fmt.Errorf("read Store response: %w", e)
		}

		response.Body = io.NopCloser(bytes.NewReader(data))

		var values map[string]any
		if e = apphttp.DecodePropertyList(data, &values); e == nil {
			b.mu.Lock()
			b.bag = values
			b.mu.Unlock()
		}
	}

	return response, nil
}

// CloseIdleConnections releases pooled sockets without interrupting active streams.
func (b *Backend) CloseIdleConnections() {
	b.transport.CloseIdleConnections()
	b.authTransport.CloseIdleConnections()
	b.bagTransport.CloseIdleConnections()
}

// Each request owns its timeout; compatible requests share only the connection pool.
// Login keeps its existing fresh-connection policy, including framework redirects.
func (b *Backend) requestTransport(input emulator.Request) func(*http.Request) (*http.Response, error) {
	timeout := input.Timeout
	if timeout == 0 && input.Operation == "api" {
		timeout = 30 * time.Second
	}

	transport := b.transport

	if input.Operation == "authenticate" {
		transport = b.authTransport
	}

	return func(request *http.Request) (*http.Response, error) {
		selectedTransport := transport
		if input.Operation == "authenticate" && isAppleBagRequest(request) && b.bagTransport != nil {
			selectedTransport = b.bagTransport
		}
		client := &http.Client{Transport: selectedTransport, Timeout: timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		started := time.Now()
		trace := &httptrace.ClientTrace{
			DNSStart: func(info httptrace.DNSStartInfo) {
				fmt.Printf("[StoreHTTP] DNS start host=%s\n", info.Host)
			},
			DNSDone: func(info httptrace.DNSDoneInfo) {
				fmt.Printf("[StoreHTTP] DNS done elapsed=%s addrs=%d err=%v\n", time.Since(started), len(info.Addrs), info.Err)
			},
			ConnectStart: func(network, address string) {
				fmt.Printf("[StoreHTTP] connect start network=%s address=%s\n", network, address)
			},
			ConnectDone: func(network, address string, err error) {
				fmt.Printf("[StoreHTTP] connect done elapsed=%s err=%v\n", time.Since(started), err)
			},
			TLSHandshakeStart: func() {
				fmt.Printf("[StoreHTTP] TLS handshake start elapsed=%s host=%s\n", time.Since(started), request.URL.Host)
			},
			TLSHandshakeDone: func(_ tls.ConnectionState, err error) {
				fmt.Printf("[StoreHTTP] TLS handshake done elapsed=%s err=%v\n", time.Since(started), err)
			},
			GotConn: func(info httptrace.GotConnInfo) {
				fmt.Printf("[StoreHTTP] connection ready elapsed=%s reused=%t\n", time.Since(started), info.Reused)
			},
			GotFirstResponseByte: func() {
				fmt.Printf("[StoreHTTP] first response byte elapsed=%s\n", time.Since(started))
			},
		}
		request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
		if b.jar != nil && request.Header.Get("Cookie") == "" {
			for _, cookie := range b.jar.Cookies(request.URL) {
				request.AddCookie(cookie)
			}
		}

		response, err := client.Do(request)
		if err == nil && b.jar != nil {
			b.jar.SetCookies(request.URL, response.Cookies())
		}

		if err != nil {
			return nil, fmt.Errorf("store HTTP transport: %w", err)
		}

		return response, nil
	}
}
