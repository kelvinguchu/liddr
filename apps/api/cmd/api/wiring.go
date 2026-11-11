package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/config"
	"github.com/kelvinguchu/liddr/apps/api/internal/email"
	"github.com/kelvinguchu/liddr/apps/api/internal/malware"
	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/push"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/sealing"
	deliveries "github.com/kelvinguchu/liddr/apps/api/internal/send"
	"github.com/kelvinguchu/liddr/apps/api/internal/sms"
	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
	"github.com/kelvinguchu/liddr/apps/api/internal/verification"
)

func newAuth(cfg config.Config, pool *pgxpool.Pool) (*auth.Service, error) {
	box, err := sealing.New([]byte(cfg.DataKey.Reveal()))
	if err != nil {
		return nil, err
	}
	// A nil pointer in a non-nil interface would look configured, so the sender
	// stays a nil interface unless a key is present.
	var sender auth.EmailSender
	if cfg.Email.APIKey != "" {
		sender = email.New(email.Config{URL: cfg.Email.URL, APIKey: cfg.Email.APIKey.Reveal(), From: cfg.Email.From})
	}
	var google *auth.GoogleVerifier
	if len(cfg.GoogleClientIDs) > 0 {
		google = auth.NewGoogleVerifier(cfg.GoogleCertsURL, cfg.GoogleClientIDs, time.Now)
	}
	return auth.NewService(auth.Config{
		Pool: pool,
		SMS: sms.NewClient(sms.Config{
			BaseURL:   cfg.SMS.BaseURL,
			APIKey:    cfg.SMS.APIKey.Reveal(),
			ClientID:  cfg.SMS.ClientID.Reveal(),
			AccessKey: cfg.SMS.AccessKey.Reveal(),
			SenderID:  cfg.SMS.SenderID,
		}),
		HMACKey: []byte(cfg.AuthHMACKey.Reveal()),
		Box:     box,
		Email:   sender,
		Google:  google,
		Now:     time.Now,
	}), nil
}

// grantRole creates staff. It is a command so no public route can ever do it.
func grantRole(ctx context.Context, cfg config.Config, phone, role string, logger *slog.Logger) error {
	pool, err := store.OpenPool(ctx, cfg.DatabaseURL.Reveal(), cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()
	service, err := newAuth(cfg, pool)
	if err != nil {
		return err
	}
	if err := service.GrantRole(ctx, phone, auth.Role(role)); err != nil {
		return fmt.Errorf("grant role: %w", err)
	}
	logger.LogAttrs(ctx, slog.LevelInfo, "role granted", slog.String("role", role))
	return nil
}

// documentClients builds the storage and scanner clients, or nils when the
// deployment has no document storage.
func documentClients(cfg config.Config) (*storage.Client, *malware.Client, error) {
	if cfg.Documents.Bucket == "" {
		return nil, nil, nil
	}
	client, err := storage.New(storage.Config{
		Endpoint:        cfg.Documents.Endpoint,
		Bucket:          cfg.Documents.Bucket,
		AccessKeyID:     cfg.Documents.AccessKeyID.Reveal(),
		SecretAccessKey: cfg.Documents.SecretAccessKey.Reveal(),
		Now:             time.Now,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("configure document storage: %w", err)
	}
	return client, malware.New(cfg.Documents.ClamAVAddr), nil
}

func newVerification(cfg config.Config, pool *pgxpool.Pool, logger *slog.Logger) (*verification.Service, error) {
	files, scanner, err := documentClients(cfg)
	if err != nil {
		return nil, err
	}
	return verification.NewService(verification.Config{Pool: pool, Storage: files, Scanner: scanner, Now: time.Now, Logger: logger}), nil
}

func newSend(cfg config.Config, pool *pgxpool.Pool, bookings *rides.Service) (*deliveries.Service, error) {
	files, scanner, err := documentClients(cfg)
	if err != nil {
		return nil, err
	}
	return deliveries.NewService(deliveries.Config{Pool: pool, Rides: bookings, Storage: files, Scanner: scanner, Now: time.Now}), nil
}

func newNotifications(cfg config.Config, pool *pgxpool.Pool, logger *slog.Logger) (*notifications.Service, error) {
	service := notifications.Config{Pool: pool, Now: time.Now, Logger: logger}
	if cfg.Push.ProjectID != "" {
		client, err := push.New(push.Config{
			BaseURL:            cfg.Push.BaseURL,
			TokenURL:           cfg.Push.TokenURL,
			ProjectID:          cfg.Push.ProjectID,
			ServiceAccountJSON: cfg.Push.ServiceAccount.Reveal(),
			Now:                time.Now,
		})
		if err != nil {
			return nil, fmt.Errorf("configure push: %w", err)
		}
		service.Push = client
	}
	return notifications.NewService(service), nil
}

func newGateway(cfg config.Config) *payments.Client {
	return payments.NewClient(payments.Config{
		BaseURL:         cfg.Mpesa.BaseURL,
		ConsumerKey:     cfg.Mpesa.ConsumerKey.Reveal(),
		ConsumerSecret:  cfg.Mpesa.ConsumerSecret.Reveal(),
		Shortcode:       cfg.Mpesa.Shortcode,
		Passkey:         cfg.Mpesa.Passkey.Reveal(),
		TransactionType: cfg.Mpesa.TransactionType,
	}, time.Now)
}

func newSubscriptions(cfg config.Config, pool *pgxpool.Pool, logger *slog.Logger) *subscriptions.Service {
	return subscriptions.NewService(subscriptions.Config{
		Pool:            pool,
		Gateway:         newGateway(cfg),
		Now:             time.Now,
		Logger:          logger,
		CallbackBaseURL: cfg.Mpesa.CallbackBaseURL,
		CallbackToken:   cfg.Mpesa.CallbackToken.Reveal(),
		Shortcode:       cfg.Mpesa.Shortcode,
	})
}

// registerC2BURLs is a one-off setup step, so it has no HTTP surface to protect.
func registerC2BURLs(ctx context.Context, cfg config.Config, logger *slog.Logger) error {
	validation, confirmation := newSubscriptions(cfg, nil, logger).C2BURLs()
	if err := newGateway(cfg).RegisterC2BURLs(ctx, validation, confirmation); err != nil {
		return err
	}
	logger.LogAttrs(ctx, slog.LevelInfo, "c2b urls registered")
	return nil
}
