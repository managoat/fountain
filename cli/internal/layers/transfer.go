package layers

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Fetch only stages ciphertext. It has no decryption key and cannot unpack or
// execute an artifact. The caller owns the wider network floor and must await
// this operation before narrowing it. origin is trusted operator configuration.
func Fetch(ctx context.Context, signedURL, origin, destination string, limits Limits) (Result, error) {
	transport := &http.Transport{
		Proxy:               nil, // Never inherit conversation proxy/session environment.
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 15 * time.Second,
		DisableCompression: true, ForceAttemptHTTP2: true,
	}
	defer transport.CloseIdleConnections()
	return fetch(ctx, signedURL, origin, destination, limits, transport)
}
func fetch(ctx context.Context, signedURL, origin, destination string, limits Limits, transport http.RoundTripper) (Result, error) {
	if !limits.valid() {
		return Result{}, ErrInvalid
	}
	u, err := url.Parse(signedURL)
	if err != nil {
		return Result{}, ErrTransfer
	}
	base, err := url.Parse(origin)
	if err != nil {
		return Result{}, ErrTransfer
	}
	if u.Scheme != "https" || base.Scheme != "https" || u.Host == "" || u.Host != base.Host || u.User != nil || base.User != nil || u.Fragment != "" || base.Fragment != "" || base.RawQuery != "" || (base.Path != "" && base.Path != "/") {
		return Result{}, ErrTransfer
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(limits.TimeoutSeconds)*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return Result{}, ErrTransfer
	}
	request.Header.Set("Accept-Encoding", "identity")
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return Result{}, ErrTransfer
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.ContentLength > limits.CipherBytes || response.ContentLength == 0 || (response.Header.Get("Content-Encoding") != "" && !strings.EqualFold(response.Header.Get("Content-Encoding"), "identity")) {
		return Result{}, ErrTransfer
	}
	result, err := publish(destination, func(w io.Writer) error {
		n, err := copyBounded(ctx, w, response.Body, limits.CipherBytes)
		if err != nil {
			return err
		}
		if n == 0 || (response.ContentLength >= 0 && n != response.ContentLength) {
			return ErrTransfer
		}
		return nil
	})
	if err != nil {
		return Result{}, ErrTransfer
	} // Never return a URL-bearing net error.
	return result, nil
}
