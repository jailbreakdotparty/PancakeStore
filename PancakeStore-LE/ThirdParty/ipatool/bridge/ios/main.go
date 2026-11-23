package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
)

type loginRequest struct {
	Email            string            `json:"email"`
	Password         string            `json:"password"`
	AuthCode         string            `json:"authCode"`
	DeviceIdentifier string            `json:"deviceIdentifier"`
	HardwareID       string            `json:"hardwareID"`
	HomeDirectory    string            `json:"homeDirectory"`
	Keychain         map[string]string `json:"keychain"`
	Cookies          []cookieRecord    `json:"cookies"`
}

type loginResponse struct {
	Success          bool              `json:"success"`
	AuthCodeRequired bool              `json:"authCodeRequired"`
	Error            string            `json:"error,omitempty"`
	Account          *appstore.Account `json:"account,omitempty"`
	Keychain         map[string]string `json:"keychain"`
	Cookies          []cookieRecord    `json:"cookies"`
	HardwareID       string            `json:"hardwareID,omitempty"`
}

type listVersionsRequest struct {
	AppID            string            `json:"appId"`
	DeviceIdentifier string            `json:"deviceIdentifier"`
	HardwareID       string            `json:"hardwareID"`
	HomeDirectory    string            `json:"homeDirectory"`
	Keychain         map[string]string `json:"keychain"`
	Cookies          []cookieRecord    `json:"cookies"`
}

type listVersionsResponse struct {
	Success                    bool              `json:"success"`
	Error                      string            `json:"error,omitempty"`
	ExternalVersionIdentifiers []string          `json:"externalVersionIdentifiers"`
	LatestExternalVersionID    string            `json:"latestExternalVersionID,omitempty"`
	Keychain                   map[string]string `json:"keychain"`
	Cookies                    []cookieRecord    `json:"cookies"`
}

type memoryKeychain struct {
	mu    sync.Mutex
	items map[string][]byte
}

func newMemoryKeychain(encoded map[string]string) *memoryKeychain {
	items := make(map[string][]byte, len(encoded))
	for key, value := range encoded {
		if data, err := base64.StdEncoding.DecodeString(value); err == nil {
			items[key] = data
		}
	}
	return &memoryKeychain{items: items}
}

func (k *memoryKeychain) Get(key string) ([]byte, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	value, ok := k.items[key]
	if !ok {
		return nil, os.ErrNotExist
	}
	return append([]byte(nil), value...), nil
}

func (k *memoryKeychain) Set(key string, data []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.items[key] = append([]byte(nil), data...)
	return nil
}

func (k *memoryKeychain) Remove(key string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.items, key)
	return nil
}

func (k *memoryKeychain) Export() map[string]string {
	k.mu.Lock()
	defer k.mu.Unlock()
	result := make(map[string]string, len(k.items))
	for key, value := range k.items {
		result[key] = base64.StdEncoding.EncodeToString(value)
	}
	return result
}

type cookieData struct {
	Name     string `json:"name"`
	Value    string `json:"value"`
	Domain   string `json:"domain"`
	Path     string `json:"path"`
	Expires  int64  `json:"expires"`
	MaxAge   int    `json:"maxAge,omitempty"`
	Secure   bool   `json:"secure,omitempty"`
	HTTPOnly bool   `json:"httpOnly,omitempty"`
}

type cookieRecord struct {
	URL     string       `json:"url"`
	Cookies []cookieData `json:"cookies"`
}

type persistentCookieJar struct {
	mu      sync.Mutex
	base    *cookiejar.Jar
	records map[string][]cookieData
}

func newPersistentCookieJar(saved []cookieRecord) *persistentCookieJar {
	base, _ := cookiejar.New(nil)
	jar := &persistentCookieJar{base: base, records: make(map[string][]cookieData)}
	for _, record := range saved {
		u, err := url.Parse(record.URL)
		if err != nil || u.Scheme != "https" || u.Host == "" {
			continue
		}
		cookies := make([]*http.Cookie, 0, len(record.Cookies))
		for _, savedCookie := range record.Cookies {
			cookie := &http.Cookie{
				Name: savedCookie.Name, Value: savedCookie.Value,
				Domain: savedCookie.Domain, Path: savedCookie.Path,
				MaxAge: savedCookie.MaxAge, Secure: savedCookie.Secure,
				HttpOnly: savedCookie.HTTPOnly,
			}
			if savedCookie.Expires > 0 {
				cookie.Expires = time.Unix(savedCookie.Expires, 0)
			}
			cookies = append(cookies, cookie)
		}
		jar.base.SetCookies(u, cookies)
		jar.records[record.URL] = append([]cookieData(nil), record.Cookies...)
	}
	return jar
}

func (j *persistentCookieJar) SetCookies(u *url.URL, cookies []*http.Cookie) {
	if u == nil {
		return
	}
	j.base.SetCookies(u, cookies)
	key := u.Scheme + "://" + u.Host
	j.mu.Lock()
	defer j.mu.Unlock()
	current := make(map[string]cookieData)
	for _, c := range j.records[key] {
		current[c.Name+"\x00"+c.Path] = c
	}
	for _, c := range cookies {
		if c == nil || c.Name == "" {
			continue
		}
		item := cookieData{
			Name: c.Name, Value: c.Value, Domain: c.Domain, Path: c.Path,
			MaxAge: c.MaxAge, Secure: c.Secure, HTTPOnly: c.HttpOnly,
		}
		if !c.Expires.IsZero() {
			item.Expires = c.Expires.Unix()
		}
		current[c.Name+"\x00"+c.Path] = item
	}
	updated := make([]cookieData, 0, len(current))
	for _, item := range current {
		updated = append(updated, item)
	}
	j.records[key] = updated
}

func (j *persistentCookieJar) Cookies(u *url.URL) []*http.Cookie {
	return j.base.Cookies(u)
}

func (j *persistentCookieJar) Save() error { return nil }

func (j *persistentCookieJar) Export() []cookieRecord {
	j.mu.Lock()
	defer j.mu.Unlock()
	result := make([]cookieRecord, 0, len(j.records))
	for key, cookies := range j.records {
		result = append(result, cookieRecord{URL: key, Cookies: append([]cookieData(nil), cookies...)})
	}
	return result
}

type iosMachine struct {
	hardwareID string
	override   string
	once       sync.Once
	address    string
	addressErr error
}

func (m *iosMachine) MacAddress() (string, error) {
	m.once.Do(func() {
		m.address, m.addressErr = m.resolveMacAddress()
	})
	return m.address, m.addressErr
}

func (m *iosMachine) resolveMacAddress() (string, error) {
	if parsed, err := net.ParseMAC(m.override); err == nil && validHardwareAddress(parsed) {
		return parsed.String(), nil
	}
	// Prefer en0 if iOS exposes a real address. iOS often substitutes the
	// 02:00:00:00:00:00 placeholder; in that case use a stable app-vendor ID.
	interfaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range interfaces {
			if iface.Name == "en0" && validHardwareAddress(iface.HardwareAddr) {
				return iface.HardwareAddr.String(), nil
			}
		}
		for _, iface := range interfaces {
			if validHardwareAddress(iface.HardwareAddr) {
				return iface.HardwareAddr.String(), nil
			}
		}
	}
	address := net.HardwareAddr(m.hardwareBytes())
	if validHardwareAddress(address) {
		return address.String(), nil
	}
	return "", errors.New("iOS did not expose a usable hardware identity")
}

func (m *iosMachine) hardwareBytes() []byte {
	digest := sha256.Sum256([]byte(m.hardwareID))
	address := append([]byte(nil), digest[:6]...)
	address[0] = (address[0] & 0xfc) | 0x02 // locally administered unicast fallback
	return address
}

func validHardwareAddress(address net.HardwareAddr) bool {
	if len(address) != 6 || address[0]&1 != 0 {
		return false
	}
	// Apple commonly reports this placeholder instead of the real interface
	// MAC on iOS. It is not a useful per-device Store identity.
	if strings.EqualFold(address.String(), "02:00:00:00:00:00") {
		return false
	}
	for _, value := range address {
		if value != 0 {
			return true
		}
	}
	return false
}

func (m *iosMachine) HomeDirectory() string { return os.Getenv("HOME") }
func (m *iosMachine) ReadPassword(int) ([]byte, error) {
	return nil, errors.New("interactive password input is not available in PancakeStore")
}

var bridgeLoginMu sync.Mutex

func bridgeErrorResponse(message string, keychain map[string]string, cookies []cookieRecord) loginResponse {
	if keychain == nil {
		keychain = make(map[string]string)
	}
	if cookies == nil {
		cookies = make([]cookieRecord, 0)
	}
	return loginResponse{
		Success:          false,
		AuthCodeRequired: false,
		Error:            message,
		Keychain:         keychain,
		Cookies:          cookies,
	}
}

func runLogin(input loginRequest) loginResponse {
	if input.Keychain == nil {
		input.Keychain = make(map[string]string)
	}
	if input.Cookies == nil {
		input.Cookies = make([]cookieRecord, 0)
	}
	fmt.Println("[GoBridge] login request received")
	if strings.TrimSpace(input.Email) == "" || input.Password == "" {
		return bridgeErrorResponse("Apple ID and password are required", input.Keychain, input.Cookies)
	}
	if input.HomeDirectory != "" {
		_ = os.Setenv("HOME", input.HomeDirectory)
	}
	if input.DeviceIdentifier == "" {
		return bridgeErrorResponse("stable device identifier is missing", input.Keychain, input.Cookies)
	}

	mac := &iosMachine{hardwareID: input.DeviceIdentifier, override: input.HardwareID}
	address, err := mac.MacAddress()
	if err != nil {
		return bridgeErrorResponse("could not create Store machine identity: "+err.Error(), input.Keychain, input.Cookies)
	}
	if _, err = net.ParseMAC(address); err != nil {
		return bridgeErrorResponse("invalid Store machine identity", input.Keychain, input.Cookies)
	}

	fmt.Println("[GoBridge] Store machine identity prepared")
	keychain := newMemoryKeychain(input.Keychain)
	jar := newPersistentCookieJar(input.Cookies)
	store := appstore.NewAppStore(appstore.Args{
		Keychain:        keychain,
		CookieJar:       jar,
		OperatingSystem: operatingsystem.New(),
		Machine:         mac,
	})

	fmt.Println("[GoBridge] entering ipatool AppStore.Login")
	output, loginErr := store.Login(appstore.LoginInput{
		Email:    input.Email,
		Password: input.Password,
		AuthCode: input.AuthCode,
	})
	fmt.Println("[GoBridge] ipatool AppStore.Login returned")

	response := loginResponse{
		Success:          loginErr == nil,
		AuthCodeRequired: errors.Is(loginErr, appstore.ErrAuthCodeRequired),
		Keychain:         keychain.Export(),
		Cookies:          jar.Export(),
		HardwareID:       strings.ToUpper(address),
	}
	if loginErr != nil {
		// The error message contains the failing protocol stage/status only;
		// credentials, proofs, cookies and raw response bodies are not logged.
		response.Error = loginErr.Error()
		fmt.Printf("[GoBridge] Store login failed: %s\n", loginErr.Error())
		return response
	}
	fmt.Println("[GoBridge] Store login completed successfully")
	response.Account = &output.Account
	return response
}

func runListVersions(input listVersionsRequest) listVersionsResponse {
	if input.Keychain == nil {
		input.Keychain = make(map[string]string)
	}
	if input.Cookies == nil {
		input.Cookies = make([]cookieRecord, 0)
	}

	keychain := newMemoryKeychain(input.Keychain)
	jar := newPersistentCookieJar(input.Cookies)
	response := listVersionsResponse{
		ExternalVersionIdentifiers: make([]string, 0),
		Keychain:                   keychain.Export(),
		Cookies:                    jar.Export(),
	}
	finishError := func(err error) listVersionsResponse {
		response.Success = false
		response.Error = err.Error()
		response.Keychain = keychain.Export()
		response.Cookies = jar.Export()
		return response
	}

	if strings.TrimSpace(input.AppID) == "" {
		return finishError(errors.New("App Store app ID is missing"))
	}
	appID, err := strconv.ParseInt(input.AppID, 10, 64)
	if err != nil || appID <= 0 {
		return finishError(errors.New("App Store app ID must be a positive integer"))
	}
	if input.DeviceIdentifier == "" && input.HardwareID == "" {
		return finishError(errors.New("Store device identity is missing; sign in again"))
	}
	if input.HomeDirectory != "" {
		_ = os.Setenv("HOME", input.HomeDirectory)
	}

	machine := &iosMachine{hardwareID: input.DeviceIdentifier, override: input.HardwareID}
	if _, err := machine.MacAddress(); err != nil {
		return finishError(fmt.Errorf("restore Store machine identity: %w", err))
	}

	client := appstore.NewAppStore(appstore.Args{
		Keychain:        keychain,
		CookieJar:       jar,
		OperatingSystem: operatingsystem.New(),
		Machine:         machine,
	})

	accountInfo, err := client.AccountInfo()
	if err != nil {
		return finishError(fmt.Errorf("restore native Store account: %w; sign in again if the saved session is missing", err))
	}
	if accountInfo.Account.PasswordToken == "" || accountInfo.Account.DirectoryServicesID == "" || accountInfo.Account.StoreFront == "" {
		return finishError(errors.New("saved native Store account is incomplete; sign in again"))
	}

	versionContext, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	app := appstore.App{ID: appID}
	versions, err := listVersionsWithNativeRefresh(
		accountInfo.Account,
		func(account appstore.Account) (appstore.ListVersionsOutput, error) {
			return client.ListVersions(appstore.ListVersionsInput{
				Context:  versionContext,
				Account:  account,
				App:      app,
				Platform: appstore.PlatformIPhone,
			})
		},
		client.Login,
	)
	response.Keychain = keychain.Export()
	response.Cookies = jar.Export()
	if err != nil {
		response.Success = false
		response.Error = fmt.Sprintf("list App Store versions: %v", err)
		return response
	}

	response.Success = true
	response.ExternalVersionIdentifiers = versions.ExternalVersionIdentifiers
	response.LatestExternalVersionID = versions.LatestExternalVersionID
	return response
}

//export PancakeIPAToolListVersions
func PancakeIPAToolListVersions(raw *C.char) *C.char {
	if raw == nil {
		encoded, _ := json.Marshal(listVersionsResponse{Error: "empty list-versions request", ExternalVersionIdentifiers: []string{}, Keychain: map[string]string{}, Cookies: []cookieRecord{}})
		return C.CString(string(encoded))
	}
	var input listVersionsRequest
	if err := json.Unmarshal([]byte(C.GoString(raw)), &input); err != nil {
		encoded, _ := json.Marshal(listVersionsResponse{Error: "invalid list-versions request: " + err.Error(), ExternalVersionIdentifiers: []string{}, Keychain: map[string]string{}, Cookies: []cookieRecord{}})
		return C.CString(string(encoded))
	}
	bridgeLoginMu.Lock()
	defer bridgeLoginMu.Unlock()
	response := runListVersions(input)
	encoded, err := json.Marshal(response)
	if err != nil {
		fallback, _ := json.Marshal(listVersionsResponse{Error: "failed to encode list-versions result: " + err.Error(), ExternalVersionIdentifiers: []string{}, Keychain: map[string]string{}, Cookies: []cookieRecord{}})
		encoded = fallback
	}
	fmt.Printf("[GoBridge] version-list response encoded: %d bytes\n", len(encoded))
	return C.CString(string(encoded))
}

//export PancakeIPAToolDownload
func PancakeIPAToolDownload(raw *C.char) *C.char {
	if raw == nil {
		encoded, _ := json.Marshal(downloadResponse{Error: "empty download request", Keychain: map[string]string{}, Cookies: []cookieRecord{}})
		return C.CString(string(encoded))
	}
	var input downloadRequest
	if err := json.Unmarshal([]byte(C.GoString(raw)), &input); err != nil {
		encoded, _ := json.Marshal(downloadResponse{Error: "invalid download request: " + err.Error(), Keychain: map[string]string{}, Cookies: []cookieRecord{}})
		return C.CString(string(encoded))
	}
	bridgeLoginMu.Lock()
	defer bridgeLoginMu.Unlock()
	response := runDownload(input)
	encoded, err := json.Marshal(response)
	if err != nil {
		fallback, _ := json.Marshal(downloadResponse{Error: "failed to encode download result: " + err.Error(), Keychain: map[string]string{}, Cookies: []cookieRecord{}})
		encoded = fallback
	}
	fmt.Printf("[GoBridge] download response encoded: %d bytes\n", len(encoded))
	return C.CString(string(encoded))
}

//export PancakeIPAToolLogin
func PancakeIPAToolLogin(raw *C.char) *C.char {
	if raw == nil {
		encoded, _ := json.Marshal(bridgeErrorResponse("empty login request", nil, nil))
		return C.CString(string(encoded))
	}
	var input loginRequest
	if err := json.Unmarshal([]byte(C.GoString(raw)), &input); err != nil {
		encoded, _ := json.Marshal(bridgeErrorResponse("invalid bridge request: "+err.Error(), nil, nil))
		return C.CString(string(encoded))
	}
	bridgeLoginMu.Lock()
	defer bridgeLoginMu.Unlock()
	response := runLogin(input)
	encoded, err := json.Marshal(response)
	if err != nil {
		fallback, _ := json.Marshal(bridgeErrorResponse("failed to encode login result: "+err.Error(), nil, nil))
		encoded = fallback
	}
	fmt.Printf("[GoBridge] response encoded: %d bytes\n", len(encoded))
	return C.CString(string(encoded))
}

//export PancakeIPAToolFree
func PancakeIPAToolFree(value *C.char) {
	if value != nil {
		C.free(unsafe.Pointer(value))
	}
}

func main() {}
