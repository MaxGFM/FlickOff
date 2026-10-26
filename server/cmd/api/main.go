package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/MaxGFM/FlickOff/server/internal/api"
)

func main() {
	logger := log.New(os.Stdout, "", log.LstdFlags|log.Lshortfile)

	// Read configuration from the environment. Failing fast here means
	// the server never starts in a half-configured state.
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		logger.Fatal("DATABASE_URL not set")
	}

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":4000"
	}

	// Optional: path to the Emscripten web build output. When set, the
	// server serves the WASM game from the same origin as the API —
	// no CORS, no separate dev server needed.
	webDir := os.Getenv("WEB_DIR")

	// Open the database. sql.Open does NOT actually connect — it just
	// validates the driver name and connection string. The first real
	// connection happens lazily on the first query, which makes startup
	// failures hard to diagnose. Pinging up front fixes that.
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		logger.Fatalf("sql.Open failed: %v", err)
	}
	defer db.Close()

	// Sensible connection pool defaults. Postgres' own max_connections is
	// the ultimate limit; staying well under it leaves room for psql
	// sessions and other clients.
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	// Verify the DB is actually reachable before claiming we're up.
	pingCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		logger.Fatalf("database ping failed: %v", err)
	}

	// Verify the JSON level files exist
	levels, err := api.LoadLevels("./assets/levels")
	if err != nil {
		logger.Fatalf("JSON Load level failed: %v", err)
	}

	// Build the API server. This is the one line where main hands the
	// dependencies (db, logger) to the application layer.
	srv := api.New(db, logger, levels, webDir)

	// Wrap the routes in an http.Server so we can configure timeouts.
	// http.ListenAndServe with no Server struct uses zero timeouts, which
	// means a slow client can hold a connection open indefinitely.
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 5 * time.Second,  // mitigates Slowloris
		ReadTimeout:       15 * time.Second, // total time to read the request
		WriteTimeout:      15 * time.Second, // total time to write the response
		IdleTimeout:       60 * time.Second, // keep-alive idle limit
	}

	// Start serving in a goroutine so main can wait for shutdown signals.
	// ListenAndServe blocks until the server stops; without a goroutine
	// we'd never reach the signal-handling code below.
	serverErr := make(chan error, 1)
	go func() {
		logger.Printf("listening on %s", addr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
		}
		close(serverErr)
	}()

	// Wait for either a server error or a shutdown signal.
	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-serverErr:
		logger.Fatalf("server error: %v", err)
	case sig := <-shutdown:
		logger.Printf("received %s, shutting down", sig)
	}

	// Graceful shutdown: stop accepting new connections, finish in-flight
	// requests up to a deadline, then exit. Without this, in-flight
	// requests get killed mid-response when the process exits.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Printf("graceful shutdown failed: %v", err)
		if err := httpServer.Close(); err != nil {
			logger.Printf("forced close failed: %v", err)
		}
	}

	logger.Print("shutdown complete")
}