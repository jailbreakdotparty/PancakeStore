//nolint:nlreturn,wsl // Authentication steps are intentionally kept in protocol order.
package appstore

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/majd/ipatool/v2/internal/storeauth"
)

const anisetteKeychainKey = "anisette-v4"

func (t *appstore) nativeLogin(input LoginInput) (LoginOutput, error) {
	t.authStateMu.Lock()
	defer t.authStateMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	fmt.Println("[ipatool] nativeLogin: starting")
	if len(t.anisetteState) == 0 && t.keychain != nil {
		t.anisetteState, _ = t.keychain.Get(anisetteKeychainKey)
	}
	macAddress, err := t.machine.MacAddress()
	if err != nil {
		return LoginOutput{}, fmt.Errorf("get Store machine identity: %w", err)
	}
	guid, hardwareID, err := machineIdentity(macAddress)
	if err != nil {
		return LoginOutput{}, err
	}
	fmt.Println("[ipatool] nativeLogin: fetching Store bag")
	bag, err := t.bag(guid)
	if err != nil {
		fmt.Printf("[ipatool] nativeLogin: Store bag failed: %v\n", err)
		return LoginOutput{}, fmt.Errorf("get Store authentication bag: %w", err)
	}
	fmt.Println("[ipatool] nativeLogin: Store bag received")
	if len(t.anisetteState) != 0 {
		fmt.Println("[ipatool] nativeLogin: attempting cached Store AMD proof")
		proof, state, proofErr := storeauth.StoreAMDHeaders(ctx, t.anisetteState, bag.AuthEndpoint, hardwareID)
		if proofErr == nil {
			if err = t.keychain.Set(anisetteKeychainKey, state); err != nil {
				return LoginOutput{}, fmt.Errorf("save Apple authentication state: %w", err)
			}
			t.anisetteState = state
			t.authenticationHeaders = make(http.Header)
			for key, value := range proof {
				t.authenticationHeaders.Set(key, value)
			}
			defer func() { t.authenticationHeaders = nil }()

			return t.legacyLogin(input)
		}
	}
	fmt.Println("[ipatool] nativeLogin: preparing Anisette provisioning")
	headers, state, err := storeauth.AnisetteHeaders(ctx, t.authHTTP, t.anisetteState)
	if err != nil {
		return LoginOutput{}, fmt.Errorf("prepare Apple authentication: %w", err)
	}
	if t.keychain == nil {
		return LoginOutput{}, errors.New("keychain is not configured")
	}
	if err = t.keychain.Set(anisetteKeychainKey, state); err != nil {
		return LoginOutput{}, fmt.Errorf("save Apple authentication state: %w", err)
	}
	t.anisetteState = state
	t.authenticationHeaders = headers.Clone()
	defer func() { t.authenticationHeaders = nil }()

	fmt.Println("[ipatool] nativeLogin: Anisette prepared; starting Store login")
	output, err := t.legacyLogin(input)
	fmt.Println("[ipatool] nativeLogin: first Store login attempt returned")
	var action *authenticationMachineActionError
	if !errors.As(err, &action) || action.action != "RP" {
		return output, err
	}

	for _, key := range []string{"X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-RINFO"} {
		t.authenticationHeaders.Del(key)
	}

	fmt.Println("[ipatool] nativeLogin: retrying after RP action")
	output, err = t.legacyLogin(input)
	fmt.Println("[ipatool] nativeLogin: RP retry returned")
	if !errors.As(err, &action) || action.action != "SP" {
		return output, err
	}

	kbsync, err := t.generateKBSync(ctx, hardwareID, ^uint64(1))
	if err != nil {
		return LoginOutput{}, fmt.Errorf("generate Apple Store provisioning kbsync: %w", err)
	}
	fmt.Println("[ipatool] nativeLogin: completing Store provisioning")
	state, err = storeauth.ProvisionStoreAnisette(ctx, t.authHTTP, state, action.data, privateAppStoreProvisioningURL, storeAuthenticationUserAgent, kbsync, hardwareID, headers)
	if err != nil {
		return LoginOutput{}, fmt.Errorf("complete Apple Store provisioning: %w", err)
	}
	if err = t.keychain.Set(anisetteKeychainKey, state); err != nil {
		return LoginOutput{}, fmt.Errorf("save Apple authentication state: %w", err)
	}
	t.anisetteState = state
	fmt.Println("[ipatool] nativeLogin: generating Store AMD proof")
	proof, nextState, proofErr := storeauth.StoreAMDHeaders(ctx, state, bag.AuthEndpoint, hardwareID)
	if proofErr != nil {
		return LoginOutput{}, fmt.Errorf("prepare Store AMD proof: %w", proofErr)
	}
	state = nextState
	headers = make(http.Header)
	for key, value := range proof {
		headers.Set(key, value)
	}
	if err = t.keychain.Set(anisetteKeychainKey, state); err != nil {
		return LoginOutput{}, fmt.Errorf("save Store AMD state: %w", err)
	}
	t.anisetteState = state
	t.authenticationHeaders = headers.Clone()

	fmt.Println("[ipatool] nativeLogin: final Store login attempt")
	output, err = t.legacyLogin(input)
	fmt.Println("[ipatool] nativeLogin: final Store login returned")
	return output, err
}
