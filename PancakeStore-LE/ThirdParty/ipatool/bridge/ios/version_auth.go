package main

import (
	"errors"
	"fmt"

	"github.com/majd/ipatool/v2/pkg/appstore"
)

// listVersionsWithNativeRefresh mirrors ipatool's CLI retry behavior for the
// native bridge: if Apple rejects the saved commerce token, authenticate once
// with the credentials stored in the encrypted account keychain and retry.
// The callbacks keep this policy independently testable from the CGo bridge.
func listVersionsWithNativeRefresh(
	account appstore.Account,
	list func(appstore.Account) (appstore.ListVersionsOutput, error),
	login func(appstore.LoginInput) (appstore.LoginOutput, error),
) (appstore.ListVersionsOutput, error) {
	versions, err := list(account)
	if err == nil || !errors.Is(err, appstore.ErrPasswordTokenExpired) {
		return versions, err
	}

	if account.Email == "" || account.Password == "" {
		return appstore.ListVersionsOutput{}, fmt.Errorf(
			"%w; saved Apple credentials are unavailable for automatic refresh; sign in again",
			err,
		)
	}

	fmt.Println("[GoBridge] Apple rejected the saved Store token; refreshing native authentication")
	loginResult, loginErr := login(appstore.LoginInput{
		Email:    account.Email,
		Password: account.Password,
	})
	if loginErr != nil {
		return appstore.ListVersionsOutput{}, fmt.Errorf("refresh native Store session: %w", loginErr)
	}

	refreshed := loginResult.Account
	if refreshed.PasswordToken == "" || refreshed.DirectoryServicesID == "" || refreshed.StoreFront == "" {
		return appstore.ListVersionsOutput{}, errors.New("Apple reauthentication returned an incomplete Store account")
	}

	fmt.Println("[GoBridge] native Store authentication refreshed; retrying version lookup")
	return list(refreshed)
}
