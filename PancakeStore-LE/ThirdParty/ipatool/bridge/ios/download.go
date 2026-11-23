package main

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"howett.net/plist"
)

type downloadRequest struct {
	AppID             string            `json:"appId"`
	ExternalVersionID string            `json:"externalVersionID"`
	OutputPath        string            `json:"outputPath"`
	DeviceIdentifier  string            `json:"deviceIdentifier"`
	HardwareID        string            `json:"hardwareID"`
	HomeDirectory     string            `json:"homeDirectory"`
	Keychain          map[string]string `json:"keychain"`
	Cookies           []cookieRecord    `json:"cookies"`
}

type downloadResponse struct {
	Success          bool              `json:"success"`
	Error            string            `json:"error,omitempty"`
	DestinationPath  string            `json:"destinationPath,omitempty"`
	BundleIdentifier string            `json:"bundleIdentifier,omitempty"`
	BundleVersion    string            `json:"bundleVersion,omitempty"`
	ShortVersion     string            `json:"shortVersion,omitempty"`
	DisplayName      string            `json:"displayName,omitempty"`
	Keychain         map[string]string `json:"keychain"`
	Cookies          []cookieRecord    `json:"cookies"`
}

type downloadedAppInfo struct {
	BundleIdentifier string `plist:"CFBundleIdentifier,omitempty"`
	BundleVersion    string `plist:"CFBundleVersion,omitempty"`
	ShortVersion     string `plist:"CFBundleShortVersionString,omitempty"`
	DisplayName      string `plist:"CFBundleDisplayName,omitempty"`
	BundleName       string `plist:"CFBundleName,omitempty"`
}

func runDownload(input downloadRequest) downloadResponse {
	if input.Keychain == nil {
		input.Keychain = make(map[string]string)
	}
	if input.Cookies == nil {
		input.Cookies = make([]cookieRecord, 0)
	}

	keychain := newMemoryKeychain(input.Keychain)
	jar := newPersistentCookieJar(input.Cookies)
	response := downloadResponse{
		Keychain: keychain.Export(),
		Cookies:  jar.Export(),
	}
	outputPath := ""
	cleanupOutput := func() {
		if outputPath != "" {
			_ = os.Remove(outputPath)
			_ = os.Remove(outputPath + ".tmp")
		}
	}
	finishError := func(err error) downloadResponse {
		cleanupOutput()
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
	if strings.TrimSpace(input.ExternalVersionID) == "" {
		return finishError(errors.New("selected App Store version ID is missing"))
	}
	if strings.TrimSpace(input.OutputPath) == "" || !filepath.IsAbs(input.OutputPath) {
		return finishError(errors.New("an absolute IPA output path is required"))
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
	account := accountInfo.Account
	if account.PasswordToken == "" || account.DirectoryServicesID == "" || account.StoreFront == "" {
		return finishError(errors.New("saved native Store account is incomplete; sign in again"))
	}

	outputPath = filepath.Clean(input.OutputPath)
	if err := os.MkdirAll(filepath.Dir(outputPath), 0700); err != nil {
		return finishError(fmt.Errorf("prepare IPA output directory: %w", err))
	}
	if err := os.Remove(outputPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return finishError(fmt.Errorf("remove previous IPA: %w", err))
	}

	app := appstore.App{ID: appID}
	downloadContext, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	defer cancel()
	download := func(current appstore.Account) (appstore.DownloadOutput, error) {
		return client.Download(appstore.DownloadInput{
			Context:           downloadContext,
			Account:           current,
			App:               app,
			OutputPath:        outputPath,
			ExternalVersionID: input.ExternalVersionID,
			Platform:          appstore.PlatformIPhone,
		})
	}

	fmt.Printf("[GoBridge] downloading App Store app %d version %s through ipatool\n", appID, input.ExternalVersionID)
	packageOutput, currentAccount, err := downloadWithNativeRefresh(account, download, client.Login)
	if errors.Is(err, appstore.ErrLicenseRequired) {
		// Avoid silently purchasing paid apps. Only acquire a license when a
		// catalog lookup confirms a zero-price app.
		lookup, lookupErr := client.Lookup(appstore.LookupInput{
			Account:  currentAccount,
			AppID:    appID,
			Platform: appstore.PlatformIPhone,
		})
		if lookupErr != nil {
			return finishError(fmt.Errorf("App Store license is required, but the app price could not be verified; refusing automatic purchase: %w", lookupErr))
		}
		if lookup.App.Price != 0 {
			return finishError(errors.New("the App Store catalog did not confirm a free app; PancakeStore will not purchase paid or unverified apps"))
		}
		if lookup.App.ID != appID {
			return finishError(errors.New("the App Store catalog returned a different app ID; refusing to acquire a license"))
		}

		app = lookup.App
		fmt.Println("[GoBridge] app has no license; acquiring its free App Store license")
		currentAccount, err = purchaseWithNativeRefresh(
			currentAccount,
			func(account appstore.Account) error {
				return client.Purchase(appstore.PurchaseInput{
					Account:  account,
					App:      app,
					Platform: appstore.PlatformIPhone,
				})
			},
			client.Login,
		)
		if err != nil {
			return finishError(fmt.Errorf("acquire free App Store license: %w", err))
		}

		// Purchase can correct the account storefront. Re-read the account
		// before retrying the actual package download.
		refreshed, accountErr := client.AccountInfo()
		if accountErr != nil {
			return finishError(fmt.Errorf("refresh Store account after acquiring license: %w", accountErr))
		}
		currentAccount = refreshed.Account
		packageOutput, currentAccount, err = downloadWithNativeRefresh(currentAccount, download, client.Login)
	}
	if err != nil {
		return finishError(fmt.Errorf("download App Store package: %w", err))
	}

	if packageOutput.DestinationPath == "" {
		return finishError(errors.New("ipatool returned an empty IPA destination path"))
	}
	if err := os.Remove(packageOutput.DestinationPath + ".tmp"); err != nil && !errors.Is(err, os.ErrNotExist) {
		return finishError(fmt.Errorf("remove stale FairPlay patch file: %w", err))
	}
	if err := client.ReplicateSinf(appstore.ReplicateSinfInput{
		Sinfs:       packageOutput.Sinfs,
		PackagePath: packageOutput.DestinationPath,
	}); err != nil {
		return finishError(fmt.Errorf("prepare App Store FairPlay data (sinf): %w", err))
	}

	info, err := readDownloadedAppInfo(packageOutput.DestinationPath)
	if err != nil {
		return finishError(fmt.Errorf("read downloaded app metadata: %w", err))
	}
	if info.BundleIdentifier == "" {
		return finishError(errors.New("downloaded IPA has no CFBundleIdentifier"))
	}
	if info.BundleVersion == "" {
		info.BundleVersion = info.ShortVersion
	}
	if info.ShortVersion == "" {
		info.ShortVersion = info.BundleVersion
	}
	if info.BundleVersion == "" {
		return finishError(errors.New("downloaded IPA has no app version metadata"))
	}
	if info.DisplayName == "" {
		info.DisplayName = info.BundleName
	}
	if info.DisplayName == "" {
		info.DisplayName = info.BundleIdentifier
	}

	if _, err := os.Stat(packageOutput.DestinationPath); err != nil {
		return finishError(fmt.Errorf("verify downloaded IPA: %w", err))
	}

	response.Success = true
	response.DestinationPath = packageOutput.DestinationPath
	response.BundleIdentifier = info.BundleIdentifier
	response.BundleVersion = info.BundleVersion
	response.ShortVersion = info.ShortVersion
	response.DisplayName = info.DisplayName
	response.Keychain = keychain.Export()
	response.Cookies = jar.Export()
	fmt.Printf("[GoBridge] App Store IPA ready: bundle=%s version=%s\n", info.BundleIdentifier, info.ShortVersion)
	return response
}

func readDownloadedAppInfo(path string) (downloadedAppInfo, error) {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return downloadedAppInfo{}, fmt.Errorf("open IPA archive: %w", err)
	}
	defer reader.Close()

	for _, file := range reader.File {
		parts := strings.Split(file.Name, "/")
		if len(parts) != 3 || parts[0] != "Payload" || !strings.HasSuffix(parts[1], ".app") || parts[2] != "Info.plist" {
			continue
		}

		source, err := file.Open()
		if err != nil {
			return downloadedAppInfo{}, fmt.Errorf("open app Info.plist: %w", err)
		}
		data, readErr := io.ReadAll(source)
		closeErr := source.Close()
		if readErr != nil {
			return downloadedAppInfo{}, fmt.Errorf("read app Info.plist: %w", readErr)
		}
		if closeErr != nil {
			return downloadedAppInfo{}, fmt.Errorf("close app Info.plist: %w", closeErr)
		}

		var info downloadedAppInfo
		if _, err := plist.Unmarshal(data, &info); err != nil {
			return downloadedAppInfo{}, fmt.Errorf("decode app Info.plist: %w", err)
		}
		return info, nil
	}

	return downloadedAppInfo{}, errors.New("IPA contains no top-level Payload/*.app/Info.plist")
}
