package main

import (
	"errors"
	"testing"

	"github.com/majd/ipatool/v2/pkg/appstore"
)

func TestDownloadWithNativeRefreshRetriesOnce(t *testing.T) {
	account := appstore.Account{Email: "user@example.com", Password: "secret", PasswordToken: "old"}
	refreshed := appstore.Account{Email: account.Email, Password: account.Password, PasswordToken: "new", DirectoryServicesID: "123", StoreFront: "143441-1,34"}
	attempts := 0
	output, finalAccount, err := downloadWithNativeRefresh(account,
		func(current appstore.Account) (appstore.DownloadOutput, error) {
			attempts++
			if attempts == 1 {
				return appstore.DownloadOutput{}, appstore.ErrPasswordTokenExpired
			}
			if current.PasswordToken != "new" {
				t.Fatalf("retry used password token %q, want refreshed token", current.PasswordToken)
			}
			return appstore.DownloadOutput{DestinationPath: "/tmp/example.ipa"}, nil
		},
		func(input appstore.LoginInput) (appstore.LoginOutput, error) {
			if input.Email != account.Email || input.Password != account.Password {
				t.Fatal("login did not use saved Apple credentials")
			}
			return appstore.LoginOutput{Account: refreshed}, nil
		})
	if err != nil {
		t.Fatalf("downloadWithNativeRefresh returned error: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("download attempted %d times, want 2", attempts)
	}
	if finalAccount.PasswordToken != "new" {
		t.Fatalf("final account token = %q, want new", finalAccount.PasswordToken)
	}
	if output.DestinationPath != "/tmp/example.ipa" {
		t.Fatalf("destination = %q", output.DestinationPath)
	}
}

func TestDownloadWithNativeRefreshDoesNotRetryUnrelatedError(t *testing.T) {
	wantErr := errors.New("network failed")
	attempts := 0
	logins := 0
	_, _, err := downloadWithNativeRefresh(appstore.Account{Email: "user@example.com", Password: "secret"},
		func(appstore.Account) (appstore.DownloadOutput, error) {
			attempts++
			return appstore.DownloadOutput{}, wantErr
		},
		func(appstore.LoginInput) (appstore.LoginOutput, error) {
			logins++
			return appstore.LoginOutput{}, nil
		})
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if attempts != 1 || logins != 0 {
		t.Fatalf("attempts=%d logins=%d, want 1 and 0", attempts, logins)
	}
}

func TestDownloadWithNativeRefreshRequiresSavedCredentials(t *testing.T) {
	_, _, err := downloadWithNativeRefresh(appstore.Account{},
		func(appstore.Account) (appstore.DownloadOutput, error) {
			return appstore.DownloadOutput{}, appstore.ErrPasswordTokenExpired
		},
		func(appstore.LoginInput) (appstore.LoginOutput, error) {
			t.Fatal("login should not run without saved credentials")
			return appstore.LoginOutput{}, nil
		})
	if err == nil {
		t.Fatal("expected missing-credentials error")
	}
}

func TestPurchaseWithNativeRefreshRetriesOnce(t *testing.T) {
	account := appstore.Account{Email: "user@example.com", Password: "secret", PasswordToken: "old"}
	refreshed := appstore.Account{Email: account.Email, Password: account.Password, PasswordToken: "new", DirectoryServicesID: "123", StoreFront: "143441-1,34"}
	attempts := 0
	finalAccount, err := purchaseWithNativeRefresh(account,
		func(current appstore.Account) error {
			attempts++
			if attempts == 1 {
				return appstore.ErrPasswordTokenExpired
			}
			if current.PasswordToken != "new" {
				t.Fatalf("purchase retry used password token %q", current.PasswordToken)
			}
			return nil
		},
		func(appstore.LoginInput) (appstore.LoginOutput, error) {
			return appstore.LoginOutput{Account: refreshed}, nil
		})
	if err != nil {
		t.Fatalf("purchaseWithNativeRefresh returned error: %v", err)
	}
	if attempts != 2 || finalAccount.PasswordToken != "new" {
		t.Fatalf("attempts=%d final token=%q", attempts, finalAccount.PasswordToken)
	}
}
