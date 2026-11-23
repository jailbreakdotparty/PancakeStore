package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/majd/ipatool/v2/pkg/appstore"
)

func TestListVersionsWithNativeRefresh(t *testing.T) {
	original := appstore.Account{
		Email:    "apple@example.test",
		Password: "stored-password",
	}
	refreshed := appstore.Account{
		Email:               original.Email,
		Password:            original.Password,
		PasswordToken:       "fresh-token",
		DirectoryServicesID: "123456789012",
		StoreFront:          "143441-1,34",
	}

	listCalls := 0
	loginCalls := 0
	versions, err := listVersionsWithNativeRefresh(
		original,
		func(account appstore.Account) (appstore.ListVersionsOutput, error) {
			listCalls++
			if listCalls == 1 {
				return appstore.ListVersionsOutput{}, appstore.ErrPasswordTokenExpired
			}
			if account.PasswordToken != refreshed.PasswordToken {
				t.Fatalf("retry used token %q; want refreshed token", account.PasswordToken)
			}
			return appstore.ListVersionsOutput{
				ExternalVersionIdentifiers: []string{"100", "200"},
				LatestExternalVersionID:    "200",
			}, nil
		},
		func(input appstore.LoginInput) (appstore.LoginOutput, error) {
			loginCalls++
			if input.Email != original.Email || input.Password != original.Password {
				t.Fatalf("login received unexpected stored credentials")
			}
			return appstore.LoginOutput{Account: refreshed}, nil
		},
	)
	if err != nil {
		t.Fatalf("listVersionsWithNativeRefresh() error = %v", err)
	}
	if listCalls != 2 || loginCalls != 1 {
		t.Fatalf("list calls = %d, login calls = %d; want 2 and 1", listCalls, loginCalls)
	}
	if len(versions.ExternalVersionIdentifiers) != 2 || versions.LatestExternalVersionID != "200" {
		t.Fatalf("unexpected version result: %#v", versions)
	}
}

func TestListVersionsWithNativeRefreshDoesNotReauthenticateOtherErrors(t *testing.T) {
	wantErr := errors.New("temporary Store error")
	loginCalls := 0
	_, err := listVersionsWithNativeRefresh(
		appstore.Account{Email: "apple@example.test", Password: "password"},
		func(appstore.Account) (appstore.ListVersionsOutput, error) {
			return appstore.ListVersionsOutput{}, wantErr
		},
		func(appstore.LoginInput) (appstore.LoginOutput, error) {
			loginCalls++
			return appstore.LoginOutput{}, nil
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v; want original error", err)
	}
	if loginCalls != 0 {
		t.Fatalf("login calls = %d; want 0", loginCalls)
	}
}

func TestListVersionsWithNativeRefreshRequiresSavedCredentials(t *testing.T) {
	_, err := listVersionsWithNativeRefresh(
		appstore.Account{Email: "apple@example.test"},
		func(appstore.Account) (appstore.ListVersionsOutput, error) {
			return appstore.ListVersionsOutput{}, appstore.ErrPasswordTokenExpired
		},
		func(appstore.LoginInput) (appstore.LoginOutput, error) {
			t.Fatal("login must not run without a saved password")
			return appstore.LoginOutput{}, nil
		},
	)
	if !errors.Is(err, appstore.ErrPasswordTokenExpired) {
		t.Fatalf("error = %v; want ErrPasswordTokenExpired", err)
	}
	if !strings.Contains(err.Error(), "sign in again") {
		t.Fatalf("error = %q; want sign-in guidance", err)
	}
}

func TestListVersionsWithNativeRefreshReturnsLoginError(t *testing.T) {
	_, err := listVersionsWithNativeRefresh(
		appstore.Account{Email: "apple@example.test", Password: "password"},
		func(appstore.Account) (appstore.ListVersionsOutput, error) {
			return appstore.ListVersionsOutput{}, appstore.ErrPasswordTokenExpired
		},
		func(appstore.LoginInput) (appstore.LoginOutput, error) {
			return appstore.LoginOutput{}, appstore.ErrAuthCodeRequired
		},
	)
	if !errors.Is(err, appstore.ErrAuthCodeRequired) {
		t.Fatalf("error = %v; want ErrAuthCodeRequired preserved", err)
	}
}

func TestListVersionsWithNativeRefreshReturnsRetryError(t *testing.T) {
	calls := 0
	_, err := listVersionsWithNativeRefresh(
		appstore.Account{Email: "apple@example.test", Password: "password"},
		func(account appstore.Account) (appstore.ListVersionsOutput, error) {
			calls++
			return appstore.ListVersionsOutput{}, appstore.ErrPasswordTokenExpired
		},
		func(input appstore.LoginInput) (appstore.LoginOutput, error) {
			return appstore.LoginOutput{Account: appstore.Account{
				PasswordToken:       "fresh-token",
				DirectoryServicesID: "123456789012",
				StoreFront:          "143441-1,34",
			}}, nil
		},
	)
	if !errors.Is(err, appstore.ErrPasswordTokenExpired) {
		t.Fatalf("error = %v; want retry error", err)
	}
	if calls != 2 {
		t.Fatalf("list calls = %d; want 2", calls)
	}
}
