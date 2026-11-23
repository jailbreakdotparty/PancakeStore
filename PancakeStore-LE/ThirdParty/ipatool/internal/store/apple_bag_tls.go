package store

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

const (
	appleBagDialTimeout      = 5 * time.Second
	appleBagHandshakeTimeout = 8 * time.Second
	appleBagMaxIPAttempts    = 4
)

// appleBagTransport retries a TLS handshake against the other resolved IP
// addresses when one Apple edge accepts TCP but never completes TLS. The
// regular transport remains unchanged; this is deliberately scoped to the
// Store bag request that currently blocks native login.
func appleBagTransport(base *http.Transport) *http.Transport {
	transport := base.Clone()
	dialer := &net.Dialer{Timeout: appleBagDialTimeout, KeepAlive: 30 * time.Second}
	transport.DialTLSContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return dialTLSWithIPFallback(
			ctx,
			network,
			address,
			base.TLSClientConfig,
			base.ForceAttemptHTTP2,
			net.DefaultResolver.LookupIPAddr,
			dialer.DialContext,
			appleBagHandshakeTimeout,
		)
	}

	return transport
}

func isAppleBagRequest(request *http.Request) bool {
	return request != nil && request.URL != nil && request.Method == http.MethodGet &&
		strings.EqualFold(request.URL.Scheme, "https") &&
		strings.EqualFold(request.URL.Hostname(), "init.itunes.apple.com") &&
		request.URL.EscapedPath() == "/bag.xml"
}

type appleIPLookup func(context.Context, string) ([]net.IPAddr, error)
type appleContextDial func(context.Context, string, string) (net.Conn, error)

// dialTLSWithIPFallback completes TLS before returning, as required by
// http.Transport.DialTLSContext. Every address gets its own bounded handshake
// window so a stalled IPv6/IPv4 edge cannot prevent trying the other family.
func dialTLSWithIPFallback(
	ctx context.Context,
	network string,
	address string,
	baseConfig *tls.Config,
	forceHTTP2 bool,
	lookup appleIPLookup,
	dial appleContextDial,
	handshakeTimeout time.Duration,
) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("parse Apple Store address: %w", err)
	}

	var addresses []net.IPAddr
	if literal := net.ParseIP(host); literal != nil {
		addresses = []net.IPAddr{{IP: literal}}
	} else {
		fmt.Printf("[StoreHTTP] Apple bag DNS start host=%s\n", host)
		dnsStarted := time.Now()
		addresses, err = lookup(ctx, host)
		if err != nil {
			return nil, fmt.Errorf("resolve Apple Store host %s: %w", host, err)
		}
		fmt.Printf("[StoreHTTP] Apple bag DNS done elapsed=%s addresses=%d\n", time.Since(dnsStarted), len(addresses))
	}
	if len(addresses) == 0 {
		return nil, fmt.Errorf("resolve Apple Store host %s: no IP addresses", host)
	}

	addresses = interleaveIPFamilies(addresses)
	if len(addresses) > appleBagMaxIPAttempts {
		addresses = addresses[:appleBagMaxIPAttempts]
	}

	var failures []error
	for index, ipAddress := range addresses {
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		ipText := ipAddress.IP.String()
		if ipv4 := ipAddress.IP.To4(); ipv4 != nil {
			ipText = ipv4.String()
		} else if ipAddress.Zone != "" {
			ipText += "%" + ipAddress.Zone
		}
		target := net.JoinHostPort(ipText, port)
		dialNetwork := network
		if strings.HasPrefix(network, "tcp") {
			dialNetwork = "tcp6"
			if ipAddress.IP.To4() != nil {
				dialNetwork = "tcp4"
			}
		}
		fmt.Printf("[StoreHTTP] Apple bag TCP attempt %d/%d candidate=%s family=%s\n", index+1, len(addresses), ipText, ipFamily(ipAddress.IP))
		started := time.Now()
		connection, dialErr := dial(ctx, dialNetwork, target)
		if dialErr != nil {
			wrapped := fmt.Errorf("connect via %s: %w", ipFamily(ipAddress.IP), dialErr)
			failures = append(failures, wrapped)
			fmt.Printf("[StoreHTTP] Apple bag TCP failed candidate=%s elapsed=%s err=%v\n", ipText, time.Since(started), dialErr)
			continue
		}

		config := &tls.Config{}
		if baseConfig != nil {
			config = baseConfig.Clone()
		}
		if config.ServerName == "" {
			config.ServerName = host
		}
		if config.MinVersion == 0 {
			config.MinVersion = tls.VersionTLS12
		}
		if len(config.NextProtos) == 0 {
			if forceHTTP2 {
				config.NextProtos = []string{"h2", "http/1.1"}
			} else {
				config.NextProtos = []string{"http/1.1"}
			}
		}

		fmt.Printf("[StoreHTTP] Apple bag TLS start candidate=%s family=%s\n", ipText, ipFamily(ipAddress.IP))
		handshakeContext, cancel := context.WithTimeout(ctx, handshakeTimeout)
		tlsConnection := tls.Client(connection, config)
		handshakeErr := tlsConnection.HandshakeContext(handshakeContext)
		cancel()
		if handshakeErr == nil {
			fmt.Printf("[StoreHTTP] Apple bag TLS complete candidate=%s elapsed=%s protocol=%s\n", ipText, time.Since(started), tlsConnection.ConnectionState().NegotiatedProtocol)
			return tlsConnection, nil
		}

		_ = connection.Close()
		wrapped := fmt.Errorf("TLS handshake via %s: %w", ipFamily(ipAddress.IP), handshakeErr)
		failures = append(failures, wrapped)
		fmt.Printf("[StoreHTTP] Apple bag TLS failed candidate=%s elapsed=%s err=%v; trying another address when available\n", ipText, time.Since(started), handshakeErr)
	}

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	return nil, fmt.Errorf("Apple Store TLS connection failed after %d address attempts: %w", len(addresses), errors.Join(failures...))
}

func interleaveIPFamilies(addresses []net.IPAddr) []net.IPAddr {
	if len(addresses) < 2 {
		return append([]net.IPAddr(nil), addresses...)
	}

	ipv4 := make([]net.IPAddr, 0, len(addresses))
	ipv6 := make([]net.IPAddr, 0, len(addresses))
	for _, address := range addresses {
		if address.IP.To4() != nil {
			ipv4 = append(ipv4, address)
		} else {
			ipv6 = append(ipv6, address)
		}
	}

	preferIPv4 := addresses[0].IP.To4() != nil
	ordered := make([]net.IPAddr, 0, len(addresses))
	for len(ipv4) > 0 || len(ipv6) > 0 {
		if preferIPv4 {
			if len(ipv4) > 0 {
				ordered = append(ordered, ipv4[0])
				ipv4 = ipv4[1:]
			}
			if len(ipv6) > 0 {
				ordered = append(ordered, ipv6[0])
				ipv6 = ipv6[1:]
			}
		} else {
			if len(ipv6) > 0 {
				ordered = append(ordered, ipv6[0])
				ipv6 = ipv6[1:]
			}
			if len(ipv4) > 0 {
				ordered = append(ordered, ipv4[0])
				ipv4 = ipv4[1:]
			}
		}
	}

	return ordered
}

func ipFamily(ip net.IP) string {
	if ip.To4() != nil {
		return "IPv4"
	}

	return "IPv6"
}
