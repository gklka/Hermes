package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/util/exhttp"
	"go.mau.fi/whatsmeow"
	waStore "go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	waTypes "go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"

	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

var errNotConnected = errors.New("not connected")

// Core is the app's connection to Messenger: the Facebook (LightSpeed) socket, the end-to-end
// encrypted (WhatsApp-protocol) connection, and the store both write to.
type Core struct {
	dataDir string
	log     zerolog.Logger
	store   *Store
	wa      *sqlstore.Container

	mu           sync.Mutex
	cancel       context.CancelFunc
	cli          *messagix.Client
	e2ee         *whatsmeow.Client
	cookies      *cookies.Cookies
	account      *apiAccount
	initialTable *table.LSTable

	pendingLock sync.Mutex
	pending     map[string]pendingSend // otid → local echo

	// Requests that send or change messages run one at a time, in the order they came.
	sendQueue chan func()
}

func NewCore(dataDir string) *Core {
	logFile, err := os.OpenFile(filepath.Join(dataDir, "core.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	var log zerolog.Logger
	if err == nil {
		log = zerolog.New(logFile).With().Timestamp().Logger().Level(zerolog.DebugLevel)
	} else {
		log = zerolog.Nop()
	}
	c := &Core{
		dataDir:   dataDir,
		log:       log,
		pending:   make(map[string]pendingSend),
		sendQueue: make(chan func(), 128),
	}
	_ = os.MkdirAll(c.mediaDir(), 0o700)
	go func() {
		for fn := range c.sendQueue {
			fn()
		}
	}()
	return c
}

// mediaDir holds downloaded attachments and pictures imported from the web app.
func (c *Core) mediaDir() string {
	return filepath.Join(c.dataDir, "media")
}

// Start opens the databases, closes `ready` (so requests start being served) and connects
// if a session was saved.
func (c *Core) Start(ready chan struct{}) {
	defer close(ready)
	var err error
	c.store, err = OpenStore(filepath.Join(c.dataDir, "app.db"))
	if err != nil {
		c.log.Err(err).Msg("Failed to open app database")
		c.setState(stateLoggedOut, "Failed to open database: "+err.Error())
		return
	}
	waDB, err := sql.Open("sqlite", "file:"+filepath.Join(c.dataDir, "e2ee.db")+"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err == nil {
		c.wa = sqlstore.NewWithDB(waDB, "sqlite", waLog.Zerolog(c.log.With().Str("component", "whatsmeow-store").Logger()))
		err = c.wa.Upgrade(context.Background())
	}
	if err != nil {
		c.log.Err(err).Msg("Failed to open E2EE database")
		c.setState(stateLoggedOut, "Failed to open E2EE database: "+err.Error())
		return
	}

	if raw := c.store.Get(kvAccount); raw != "" {
		_ = json.Unmarshal([]byte(raw), &c.account)
	}
	savedCookies := c.loadCookies()
	if savedCookies == nil || !savedCookies.IsLoggedIn() {
		c.setState(stateLoggedOut, "")
		return
	}
	c.cookies = savedCookies
	c.setState(stateConnecting, "")
	go c.connectWithRetry()
}

// MARK: - State

func (c *Core) setState(state, errMsg string) {
	c.mu.Lock()
	account := c.account
	c.mu.Unlock()
	emitEvent("state", apiState{State: state, Account: account, Error: errMsg})
}

func (c *Core) selfID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.account != nil {
		return c.account.ID
	}
	if c.cookies != nil {
		return id64(c.cookies.GetUserID())
	}
	return ""
}

// currentCookies is the session's cookies, or nil when logged out.
func (c *Core) currentCookies() *cookies.Cookies {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cookies
}

func (c *Core) client() *messagix.Client {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cli
}

func (c *Core) e2eeClient() *whatsmeow.Client {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.e2ee
}

// requireClient is the Facebook connection, or errNotConnected.
func (c *Core) requireClient() (*messagix.Client, error) {
	if cli := c.client(); cli != nil {
		return cli, nil
	}
	return nil, errNotConnected
}

// requireE2EE is the end-to-end encrypted connection (with its device), or errNotConnected.
func (c *Core) requireE2EE() (*whatsmeow.Client, error) {
	if e2ee := c.e2eeClient(); e2ee != nil && e2ee.Store != nil && e2ee.Store.ID != nil {
		return e2ee, nil
	}
	return nil, errNotConnected
}

// waitForConnection waits for a connection (c.requireClient or c.requireE2EE) until the
// context ends or the user logs out: the chat shown at launch asks for its pictures and theme
// before the connections are up.
func waitForConnection[T any](ctx context.Context, c *Core, connection func() (T, error)) (T, error) {
	for {
		conn, err := connection()
		if err == nil || c.currentCookies() == nil {
			return conn, err
		}
		select {
		case <-ctx.Done():
			return conn, err
		case <-time.After(500 * time.Millisecond):
		}
	}
}

// MARK: - Cookies

func (c *Core) loadCookies() *cookies.Cookies {
	raw := c.store.Get(kvCookies)
	if raw == "" {
		return nil
	}
	ck := &cookies.Cookies{}
	if err := json.Unmarshal([]byte(raw), ck); err != nil {
		c.log.Err(err).Msg("Failed to parse saved cookies")
		return nil
	}
	ck.Platform = types.Facebook
	return ck
}

func (c *Core) saveCookies() {
	ck := c.currentCookies()
	if ck == nil {
		return
	}
	if data, err := json.Marshal(ck); err == nil {
		c.store.Set(kvCookies, string(data))
	}
}

// MARK: - Login

// Login validates browser cookies by loading the messages page, then connects.
func (c *Core) Login(ctx context.Context, values map[string]string) error {
	ck := &cookies.Cookies{Platform: types.Facebook}
	converted := make(map[cookies.MetaCookieName]string, len(values))
	for k, v := range values {
		converted[cookies.MetaCookieName(k)] = v
	}
	ck.UpdateValues(converted)
	if missing := ck.GetMissingCookieNames(); len(missing) > 0 {
		return fmt.Errorf("missing cookies: %v", missing)
	}

	cli := c.newClient(ck)
	user, tbl, err := cli.LoadMessagesPage(ctx)
	if err != nil {
		return humanizeLoginError(err)
	}
	if user.GetFBID() != ck.GetUserID() {
		return fmt.Errorf("logged in user ID mismatch")
	}

	c.disconnect()
	c.forgetAccount()
	c.mu.Lock()
	c.cookies = ck
	c.account = accountFromUser(user)
	c.mu.Unlock()
	c.saveCookies()
	c.saveAccount()
	c.attach(cli, tbl)
	return nil
}

func humanizeLoginError(err error) error {
	switch {
	case errors.Is(err, httpclient.ErrCheckpointRequired), errors.Is(err, httpclient.ErrChallengeRequired):
		return fmt.Errorf("Facebook wants you to verify this login. Open facebook.com in a browser, complete the check, then try again")
	case errors.Is(err, httpclient.ErrConsentRequired):
		return fmt.Errorf("Facebook requires you to accept new terms. Log in on facebook.com first")
	case errors.Is(err, httpclient.ErrAccountSuspended):
		return fmt.Errorf("this account is suspended")
	case errors.Is(err, httpclient.ErrTokenInvalidated):
		return fmt.Errorf("the session is no longer valid, please log in again")
	default:
		return err
	}
}

func accountFromUser(user types.UserInfo) *apiAccount {
	return &apiAccount{
		ID:        id64(user.GetFBID()),
		Name:      user.GetName(),
		AvatarURL: user.GetAvatarURL(),
	}
}

func (c *Core) saveAccount() {
	c.mu.Lock()
	account := c.account
	c.mu.Unlock()
	if data, err := json.Marshal(account); err == nil {
		c.store.Set(kvAccount, string(data))
	}
}

func (c *Core) Logout(ctx context.Context) {
	e2ee := c.e2eeClient()
	c.disconnect()
	if e2ee != nil && e2ee.Store != nil && e2ee.Store.ID != nil {
		if err := e2ee.Store.Delete(ctx); err != nil {
			c.log.Err(err).Msg("Failed to delete E2EE device")
		}
	}
	c.forgetAccount()
	c.mu.Lock()
	c.cookies = nil
	c.account = nil
	c.mu.Unlock()
	c.setState(stateLoggedOut, "")
}

// forgetAccount deletes everything of the account that was logged in (at logout, and at a
// login, which may be another account): its chats, media and in-memory caches.
func (c *Core) forgetAccount() {
	_ = c.store.Wipe()
	forgetThreadMappings()
	forgetNameLookups()
	c.pendingLock.Lock()
	c.pending = make(map[string]pendingSend)
	c.pendingLock.Unlock()
	_ = os.RemoveAll(c.mediaDir())
	_ = os.MkdirAll(c.mediaDir(), 0o700)
}

// MARK: - Connection

func (c *Core) newClient(ck *cookies.Cookies) *messagix.Client {
	log := c.log.With().Str("component", "messagix").Logger().Hook(callNotificationHook{c})
	return messagix.NewClient(ck, log, &messagix.Config{
		ClientSettings: exhttp.SensibleClientSettings,
	})
}

func (c *Core) connectWithRetry() {
	delay := time.Second
	for attempt := 1; ; attempt++ {
		ck := c.currentCookies()
		if ck == nil {
			return
		}
		cli := c.newClient(ck)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		user, tbl, err := cli.LoadMessagesPage(ctx)
		cancel()
		if err == nil {
			c.mu.Lock()
			c.account = accountFromUser(user)
			c.mu.Unlock()
			c.saveAccount()
			c.attach(cli, tbl)
			return
		}
		c.log.Err(err).Int("attempt", attempt).Msg("Failed to load messages page")
		if errors.Is(err, httpclient.ErrTokenInvalidated) || errors.Is(err, httpclient.ErrCheckpointRequired) ||
			errors.Is(err, httpclient.ErrChallengeRequired) || errors.Is(err, httpclient.ErrConsentRequired) ||
			errors.Is(err, httpclient.ErrAccountSuspended) {
			c.mu.Lock()
			c.cookies = nil
			c.mu.Unlock()
			c.store.Delete(kvCookies)
			c.setState(stateLoggedOut, humanizeLoginError(err).Error())
			return
		}
		c.setState(stateDisconnected, err.Error())
		time.Sleep(delay)
		delay = min(delay*2, 5*time.Minute)
	}
}

// attach takes ownership of a freshly loaded client and opens the socket.
func (c *Core) attach(cli *messagix.Client, initialTable *table.LSTable) {
	ctx, cancel := context.WithCancel(context.Background())
	c.mu.Lock()
	c.cancel = cancel
	c.cli = cli
	c.initialTable = initialTable
	c.mu.Unlock()

	cli.SetEventHandler(c.handleMetaEvent)
	c.setState(stateConnecting, "")
	if err := cli.Connect(ctx); err != nil {
		c.log.Err(err).Msg("Failed to connect")
		c.setState(stateDisconnected, err.Error())
		return
	}
	go c.persistCookiesPeriodically(ctx)
}

func (c *Core) persistCookiesPeriodically(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.saveCookies()
		}
	}
}

func (c *Core) disconnect() {
	c.mu.Lock()
	cli, e2ee, cancel := c.cli, c.e2ee, c.cancel
	c.cli, c.e2ee, c.cancel = nil, nil, nil
	c.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if cli != nil {
		cli.SetEventHandler(nil)
		cli.Disconnect()
	}
	if e2ee != nil {
		e2ee.Disconnect()
	}
	c.saveCookies()
}

func (c *Core) handleMetaEvent(ctx context.Context, rawEvt any) {
	switch evt := rawEvt.(type) {
	case *table.LSTable:
		c.handleTable(evt)
		if cli := c.client(); cli != nil {
			cli.PostHandlePublishResponse(evt)
		}
	case *messagix.ConnectedEvent:
		c.mu.Lock()
		initial := c.initialTable
		c.initialTable = nil
		c.mu.Unlock()
		c.setState(stateConnected, "")
		if initial != nil {
			c.handleTable(initial)
		}
		go c.connectE2EE()
		go c.backfillThreads(ctx)
		go c.lookUpAllNames()
	case *messagix.ReconnectedEvent:
		c.setState(stateConnected, "")
	case *messagix.TransientDisconnectEvent:
		msg := ""
		if evt.Err != nil {
			msg = evt.Err.Error()
		}
		c.setState(stateDisconnected, msg)
	case *messagix.PermanentErrorEvent:
		c.log.Err(evt.Err).Msg("Permanent connection error, logging out")
		// Called from messagix's connection loop, which Disconnect waits for, so don't block it.
		go c.disconnect()
		c.mu.Lock()
		c.cookies = nil
		c.mu.Unlock()
		c.store.Delete(kvCookies)
		c.setState(stateLoggedOut, "Your session expired, please log in again")
	}
}

// MARK: - E2EE

func (c *Core) connectE2EE() {
	cli := c.client()
	if cli == nil {
		return
	}
	ck := c.currentCookies()
	if ck == nil {
		// Logged out meanwhile.
		return
	}
	ctx := context.Background()
	fbid := ck.GetUserID()

	dev := c.loadDevice(ctx, fbid)
	isNew := dev == nil
	if isNew {
		dev = c.wa.NewDevice()
	}
	cli.SetDevice(dev)
	if isNew {
		if err := cli.RegisterE2EE(ctx, fbid); err != nil {
			c.log.Err(err).Msg("Failed to register E2EE device")
			return
		}
		if err := dev.Save(ctx); err != nil {
			c.log.Err(err).Msg("Failed to save E2EE device")
			return
		}
		c.store.Set(kvWADeviceID, strconv.Itoa(int(dev.ID.Device)))
	}

	e2ee, err := cli.PrepareE2EEClient()
	if err != nil {
		c.log.Err(err).Msg("Failed to prepare E2EE client")
		return
	}
	e2ee.SynchronousAck = true
	e2ee.AddEventHandler(c.handleWAEvent)
	c.mu.Lock()
	if c.cli != cli {
		// Disconnected while we were setting up.
		c.mu.Unlock()
		return
	}
	c.e2ee = e2ee
	c.mu.Unlock()
	if err = e2ee.Connect(); err != nil {
		c.log.Err(err).Msg("Failed to connect E2EE client")
	}
}

func (c *Core) loadDevice(ctx context.Context, fbid int64) *waStore.Device {
	raw := c.store.Get(kvWADeviceID)
	if raw == "" {
		return nil
	}
	deviceID, err := strconv.Atoi(raw)
	if err != nil {
		return nil
	}
	dev, err := c.wa.GetDevice(ctx, waTypes.JID{
		User:   id64(fbid),
		Device: uint16(deviceID),
		Server: waTypes.MessengerServer,
	})
	if err != nil {
		c.log.Err(err).Msg("Failed to load E2EE device")
		return nil
	}
	return dev
}

// resetE2EE throws away the E2EE device and registers a fresh one.
func (c *Core) resetE2EE() {
	ctx := context.Background()
	c.mu.Lock()
	e2ee := c.e2ee
	c.e2ee = nil
	c.mu.Unlock()
	if e2ee != nil {
		e2ee.Disconnect()
		if e2ee.Store != nil && e2ee.Store.ID != nil {
			_ = e2ee.Store.Delete(ctx)
		}
	}
	c.store.Delete(kvWADeviceID)
	go c.connectE2EE()
}
